#!/bin/sh
# ===================================================================
# GitLab CI 专用（build-golang 作业）：多架构
# （linux/amd64 + linux/arm64）构建并推送 golang 基础镜像到 GitLab Container Registry：
#
#   ${CI_REGISTRY_IMAGE}  → golang（不含 fnpack）
#
# fnpack 镜像是独立的 ${CI_REGISTRY_IMAGE}/fnpack，由 build-fnpack 作业
# 负责：它 FROM 本作业推好的 <go 版本> 标签，只追加一个 fnpack 二进制。
# 四个作业各自对应一个镜像地址。
#
# 这是 GitLab 侧独立实现，与 .cnb/scripts/build-golang.sh、.github/scripts/build-golang.sh 各自维护、不互相引用。
# 三侧的标签规则、冒烟断言必须保持一致；平台胶水（变量来源、镜像源、元数据落地）
# 各自维护。
#
# 环境变量（默认从 GitLab CI 预定义变量派生，显式传同名变量可覆盖）：
#   REGISTRY_TOKEN 必填，docker login 密码（GitLab CI 里取 CI_REGISTRY_PASSWORD）
#   IMAGE          默认 CI_REGISTRY_IMAGE
#   REGISTRY_USER  默认 CI_REGISTRY_USER
#   REVISION       默认 CI_COMMIT_SHA
#   IMAGE_SOURCE   默认 ${CI_PROJECT_URL}
#   version        选填，Go 版本：留空 = Dockerfile 的 GO_VERSION；
#                  也可填 1.27 / 1.27.3
#
# 镜像源：Go / APT / npm / GitHub Release / nodejs.org 全走官方默认；CNB 侧才用国内镜像。
#
# 设计约束：
#   1. 基座跟随上游：Dockerfile 的 GO_VERSION 默认 1（golang:1-trixie 浮动标签，
#      自动跟随最新稳定 Go），手动触发可以钉版本；
#      实际 Go 版本由脚本解析后写进标签与 OCI label。
#   2. 先推 <go 版本>，冒烟通过后才提升 latest / <minor>。
#   3. 必须 source 执行：export 只在当前 shell 生效。
#   4. 层缓存 = 先解析版本、再按版本构建：
#      buildx 的层缓存按 build-arg 的值算缓存键。如果每天都传字符串 latest，
#      缓存键永远不变，层会一直命中第一次构建的产物，工具再也不升级。
#      所以构建前先在基础镜像里把 latest 解析成 v1.31.1 这种具体版本号，
#      再以 --build-arg 传入：上游没发新版就全命中（只拉基座 + 冒烟），
#      发新版才重建对应那一层。缓存本身走 <镜像>:buildcache（跨 runner）。
#      CACHE=off 可关闭缓存并强制全量重建。
#
# 依赖：docker buildx（由 .gitlab-ci.yml 的 before_script 创建 docker-container builder）、jq 可选（体积精确求和）。
# ===================================================================

set -eu

# ---------- 常量 ----------
DOCKERFILE_GOLANG=".gitlab/docker/Dockerfile.golang"
PLATFORMS="linux/amd64,linux/arm64"
EPOCH_DATE="1970-01-01T00:00:00Z"
# 1 MiB：正常构建镜像不可能低于此值，低于说明拿到的不是镜像清单
MIN_IMAGE_BYTES=1048576
ANNOTATION_FILE=".gitlab/annotation.json"
# 层缓存写到 <镜像>:buildcache，mode=min 只导出最终镜像里已有的层。
# 本 Dockerfile 是单阶段构建、每一层都在最终镜像里，所以 min 就够用，
# 而且不会产生没人引用的孤儿 blob；将来改成多阶段构建要换成 max。
CACHE_REF_SUFFIX="buildcache"
CACHE_MODE="min"

# ---------- 输出助手 ----------
info() { printf '  %s\n' "$*"; }
warn() { printf '警告: %s\n' "$*" >&2; }
# die 已经把原因打出来了，cleanup 里就不要再补一句「静默退出」
DIED=""
die() {
  DIED=yes
  printf '错误: %s\n' "$*" >&2
  exit 1
}

# ---------- manifest / 体积助手 ----------
# 取某平台「镜像清单」的 digest。必须定位到镜像清单本身：
# manifest list / index 没有 layers 字段，对它求体积只会得到几 KB 的假值。
# 函数体用子 shell（( )）而非 local：POSIX sh 没有 local。
manifest_digest_for() (
  ref=$1
  arch=$2
  digest=""
  if command -v jq >/dev/null 2>&1; then
    digest="$(docker buildx imagetools inspect "${ref}" \
      --format '{{json .Manifest.Manifests}}' 2>/dev/null \
      | jq -r --arg a "${arch}" \
        '.[]? | select((.platform.os // "") == "linux" and (.platform.architecture // "") == $a) | .digest' \
      | head -n 1 || true)"
  fi
  if [ -z "${digest}" ]; then
    digest="$(docker buildx imagetools inspect "${ref}" --format \
      "{{range \$m := .Manifest.Manifests}}{{with \$m.Platform}}{{if and (eq .OS \"linux\") (eq .Architecture \"${arch}\")}}{{\$m.Digest}}{{end}}{{end}}{{end}}" \
      2>/dev/null | tr -d '\n' || true)"
  fi
  printf '%s\n' "${digest}"
)

# 单平台压缩体积（字节）。只对镜像清单求和：layers 之和 + config。
# 解析失败输出 -1（不输出假的小数字）。
image_size_bytes() (
  ref=$1
  arch=$2
  bytes=""
  digest="$(manifest_digest_for "${ref}" "${arch}")"
  if [ -z "${digest}" ]; then
    printf '警告: 未取到 linux/%s 的清单 digest，体积记为 unknown\n' "${arch}" >&2
    printf '%s\n' "-1"
    return 0
  fi
  raw="$(docker buildx imagetools inspect "${ref%@*}@${digest}" --raw 2>/dev/null || true)"
  case "${raw}" in
    *'"layers"'*) : ;;
    *)
      printf '警告: linux/%s 取到的不是镜像清单（无 layers 字段），体积记为 unknown\n' "${arch}" >&2
      printf '%s\n' "-1"
      return 0
      ;;
  esac
  if command -v jq >/dev/null 2>&1; then
    bytes="$(printf '%s' "${raw}" \
      | jq -r '(([.layers[].size] | add) // 0) + (.config.size // 0)' 2>/dev/null || true)"
  fi
  case "${bytes:-}" in
    '' | *[!0-9]*)
      bytes="$(printf '%s' "${raw}" \
        | grep -o '"size":[[:space:]]*[0-9]\+' | grep -o '[0-9]\+' \
        | awk '{s+=$1} END{print s+0}' || true)"
      # grep 一条都没匹配到时上面的赋值会失败（pipefail），这里兜底成 0
      case "${bytes:-}" in
        '' | *[!0-9]*) bytes=0 ;;
      esac
      ;;
  esac
  if [ "${bytes:-0}" -lt "${MIN_IMAGE_BYTES}" ]; then
    printf '警告: linux/%s 体积解析结果异常（%s 字节），记为 unknown\n' "${arch}" "${bytes:-0}" >&2
    printf '%s\n' "-1"
    return 0
  fi
  printf '%s\n' "${bytes}"
)

image_size_mb() (
  bytes="$(image_size_bytes "$1" "$2")"
  awk -v b="${bytes:--1}" \
    'BEGIN{ if (b < 0) print "unknown"; else printf "%.1fMB", b/1048576 }'
)

# ---------- 解析型 helper 的统一纪律 ----------
# GitLab Runner 生成的包装脚本是 `set -eo pipefail`（GitHub Actions 默认的
# `bash -e` 没有 pipefail），而这些 helper 里的 grep「匹配不到」是正常情况：
# 例如 GitLab 侧 Dockerfile 本来就没有 GOPROXY= 这一行。可在 pipefail 下，
# `grep（退出 1） | head | sed` 整条 pipeline 就是 1，赋值语句跟着是 1，
# set -e 会在没有任何输出的情况下直接干掉整个作业——日志停在上一行，无从排查。
# 因此每个 helper 末尾都写 || true：匹配不到 = 空值，交给调用方用 [ -n ] 判断。

# 从 Dockerfile 读取 ARG 的默认值
read_arg() (
  name=$1
  file=$2
  sed -n "s/^ARG ${name}=//p" "${file}" | head -n 1 \
    | sed 's/[[:space:]]*#.*//' | tr -d '[:space:]' || true
)

# 从 Dockerfile 的 ENV 行读变量值：解析和构建必须走同一个 GOPROXY
# （GitLab 侧 Dockerfile 不设 GOPROXY，这里会得到空值 = 用 Go 默认代理）
read_env() (
  name=$1
  file=$2
  grep -E "^[[:space:]]*${name}=" "${file}" | head -n 1 \
    | sed "s/.*${name}=//" | sed 's/[[:space:]\\]*$//' || true
)

# GitLab 侧不设 npm 镜像：Dockerfile 里的 npm / pnpm 用官方默认源，
# 解析 pnpm 版本也用同一个源，保证「解析到的版本」和「实际装的版本」一致。
NPM_REGISTRY="https://registry.npmjs.org/"

# ---------- 工具版本解析 ----------
# go list -m 要的是模块路径，Dockerfile 里 go install 写的是包路径，所以单独登记。
# 新增 Go 工具时这里和 Dockerfile 都要改，下面的自检会拦住漏登记。
GO_TOOL_MODULES="
NFPM_VERSION=github.com/goreleaser/nfpm/v2
SQLC_VERSION=github.com/sqlc-dev/sqlc
ENT_VERSION=entgo.io/ent
GOLANGCI_LINT_VERSION=github.com/golangci/golangci-lint/v2
GOVULNCHECK_VERSION=golang.org/x/vuln
SHFMT_VERSION=mvdan.cc/sh/v3
DOCKERFMT_VERSION=github.com/reteps/dockerfmt
YAMLFMT_VERSION=github.com/google/yamlfmt
GOJQ_VERSION=github.com/itchyny/gojq
GOSQLFORMATTER_VERSION=github.com/wasilibs/go-sql-formatter/v15
GOTESTSUM_VERSION=gotest.tools/gotestsum
MARKDOWNFMT_VERSION=github.com/Kunde21/markdownfmt/v3
GOCOVER_COBERTURA_VERSION=github.com/boumenot/gocover-cobertura
"

# 从 Dockerfile 提取 go install 用到的版本变量（去重、排序）
# 不假设 go install 后面直接跟包路径：中间可能有 -v 之类的 flag，也可能带引号
dockerfile_tool_vars() (
  grep -o 'go install[^@;]*@\${[A-Z_][A-Z0-9_]*}' "$1" \
    | sed -n 's/.*@\${\([A-Z_][A-Z0-9_]*\)}/\1/p' | sort -u || true
)

# 取解析结果：resolved_versions 是 KEY=VALUE 的换行列表
version_value() (
  printf '%s\n' "${resolved_versions}" | sed -n "s/^${1}=//p" | head -n 1 || true
)

# 在基础镜像里解析最新版本，输出 KEY=VALUE。
# 放在容器里跑：不依赖 runner 装了 go / curl / jq，模块路径转义也交给 go。
resolve_versions() {
  # GitLab 侧直连 github.com / nodejs.org，镜像前缀留空
  set -- --rm -i --platform linux/amd64 \
    -e "GO_TOOL_MODULES=${GO_TOOL_MODULES}" \
    -e "GITHUB_MIRROR=" \
    -e "NODE_MIRROR=" \
    -e "NPM_REGISTRY=${NPM_REGISTRY}"
  if [ -n "${DOCKERFILE_GOPROXY}" ]; then
    set -- "$@" -e "GOPROXY=${DOCKERFILE_GOPROXY}"
  fi
  docker run "$@" "golang:${GO_REF}" sh -s <<'RESOLVE_EOF'
set -eu

# Go 工具：模块路径 → GOPROXY 上的最新 tag
for pair in ${GO_TOOL_MODULES}; do
  var="${pair%%=*}"
  mod="${pair#*=}"
  ver="$(go list -m -f '{{.Version}}' "${mod}@latest")"
  case "${ver}" in
  v[0-9]*) : ;;
  *) echo "无法解析 ${var}（${mod}@latest → ${ver:-空}）" >&2; exit 1 ;;
  esac
  printf '%s=%s\n' "${var}" "${ver}"
done

# UPX：releases.atom 第一个稳定 tag
if [ -n "${GITHUB_MIRROR:-}" ]; then GH="${GITHUB_MIRROR%/}/github.com"; else GH="https://github.com"; fi
upx_tag="$(curl -fsSL "${GH}/upx/upx/releases.atom" \
  | grep -oE 'releases/tag/v[0-9]+\.[0-9]+\.[0-9]+"' | head -n 1 \
  | sed 's|.*/tag/||; s|"||')"
case "${upx_tag}" in
v[0-9]*) printf 'UPX_VERSION=%s\n' "${upx_tag#v}" ;;
*) echo "无法解析 UPX 版本（得到：${upx_tag:-空}）" >&2; exit 1 ;;
esac

# Node.js：dist/index.json 第一个非预发布版本
if [ -n "${NODE_MIRROR:-}" ]; then NODE_BASE="${NODE_MIRROR%/}/nodejs.org/dist"; else NODE_BASE="https://nodejs.org/dist"; fi
node_tag="$(curl -fsSL "${NODE_BASE}/index.json" \
  | grep -oE '"version"[[:space:]]*:[[:space:]]*"v[0-9][^"]*"' \
  | sed 's/.*"\(v[0-9][^"]*\)"$/\1/' \
  | grep -v -- '-' | head -n 1)"
case "${node_tag}" in
v[0-9]*) printf 'NODE_VERSION=%s\n' "${node_tag#v}" ;;
*) echo "无法解析 Node.js 版本（得到：${node_tag:-空}）" >&2; exit 1 ;;
esac

# pnpm：npm registry 的 pnpm@latest
pnpm_ver="$(curl -fsSL "${NPM_REGISTRY%/}/pnpm/latest" \
  | grep -oE '"version"[[:space:]]*:[[:space:]]*"[0-9][^"]*"' | head -n 1 \
  | sed 's/.*"\([0-9][^"]*\)"$/\1/')"
case "${pnpm_ver}" in
[0-9]*) printf 'PNPM_VERSION=%s\n' "${pnpm_ver}" ;;
*) echo "无法解析 pnpm 版本（得到：${pnpm_ver:-空}）" >&2; exit 1 ;;
esac
RESOLVE_EOF
}

# ---------- 0. 环境检查与默认值 ----------
REGISTRY_TOKEN="${REGISTRY_TOKEN:-${CI_REGISTRY_PASSWORD:-}}"
: "${REGISTRY_TOKEN:?缺少环境变量 REGISTRY_TOKEN（GitLab CI 里用 CI_REGISTRY_PASSWORD，或显式传入）}"

version="${version:-}"
# CACHE=off：关闭层缓存并强制全量重建（怀疑缓存脏了、或 registry 不接受缓存清单时用）
CACHE="${CACHE:-on}"
case "${CACHE}" in
  on | off) : ;;
  *) die "CACHE 只接受 on / off，收到：${CACHE}" ;;
esac
REGISTRY_USER="${REGISTRY_USER:-${CI_REGISTRY_USER:-}}"
REVISION="${REVISION:-${CI_COMMIT_SHA:-unknown}}"
IMAGE_SOURCE="${IMAGE_SOURCE:-${CI_PROJECT_URL:-}}"

[ -n "${REGISTRY_USER}" ] || die "无法确定 REGISTRY_USER：请在 GitLab CI 里运行（CI_REGISTRY_USER 自动可用），或显式传 REGISTRY_USER"

if [ -z "${IMAGE:-}" ]; then
  [ -n "${CI_REGISTRY_IMAGE:-}" ] || die "无法确定 IMAGE：请在 GitLab CI 里运行（CI_REGISTRY_IMAGE 自动可用），或显式传 IMAGE=registry.example.com/<group>/<project>"
  IMAGE="${CI_REGISTRY_IMAGE}"
fi
case "${IMAGE}" in
  *//* | */) die "IMAGE 含空路径段：${IMAGE}" ;;
esac
case "${IMAGE}" in
  */*/*) : ;;
  *) die "IMAGE 必须形如 registry.example.com/<group>/<project>，收到：${IMAGE}" ;;
esac
case "${IMAGE_SOURCE}" in
  *://*) : ;;
  *) die "无法确定 IMAGE_SOURCE（得到：${IMAGE_SOURCE:-空}）：请在 GitLab CI 里运行，或显式传 IMAGE_SOURCE=https://gitlab.com/<group>/<project>" ;;
esac

REGISTRY="${IMAGE%%/*}"
case "${REGISTRY}" in
  *.* | localhost) : ;;
  *) die "IMAGE 必须带 registry 前缀（如 registry.example.com/<group>/<project>），收到：${IMAGE}" ;;
esac
case "${IMAGE}" in
  *[A-Z]*) die "IMAGE 不能含大写字母：${IMAGE}" ;;
esac

# 凭证只在本次构建内有效：结束时删掉登录态
HOMEDIR="${HOME:-/root}"
cleanup() {
  rc=$?
  rm -f "$HOMEDIR/.docker/config.json"
  # set -e + pipefail 的退出不带任何输出，作业日志会停在上一行让人无从下手。
  # die 已经打过原因的就不再重复，这里只补「静默退出」这一种。
  if [ "${rc}" -ne 0 ] && [ -z "${DIED}" ]; then
    printf '错误: 脚本静默退出（exit=%s）：某条命令在 set -e + pipefail 下返回了非 0。用 sh -x 或 CI_DEBUG_TRACE=true 定位具体行\n' "${rc}" >&2
  fi
}
trap cleanup EXIT

echo "=============================="
echo "🔧 构建多架构 Golang 镜像（GitLab Container Registry）"
echo "=============================="

# ---------- 1. version 校验 ----------
case "$version" in
  '' | latest) : ;;
  *)
    printf '%s' "${version}" | grep -Eq '^[0-9]+\.[0-9]+(\.[0-9]+)?$' \
      || die "version 只接受 1.27 / 1.27.3，收到：${version}"
    ;;
esac

# ---------- 2. 基座引用 ----------
[ -f "$DOCKERFILE_GOLANG" ] \
  || die "找不到 ${DOCKERFILE_GOLANG}（当前目录 $(pwd)）：请在仓库根目录执行本脚本"
GO_VERSION="$(read_arg GO_VERSION "$DOCKERFILE_GOLANG")"
DEBIAN_VERSION="$(read_arg DEBIAN_VERSION "$DOCKERFILE_GOLANG")"
[ -n "${GO_VERSION}" ] || die "无法从 ${DOCKERFILE_GOLANG} 解析 ARG GO_VERSION"
[ -n "${DEBIAN_VERSION}" ] || die "无法从 ${DOCKERFILE_GOLANG} 解析 ARG DEBIAN_VERSION"
if [ -n "$version" ]; then
  GO_VERSION="$version"
  info "version 入参 ${version}"
fi
GO_REF="${GO_VERSION}-${DEBIAN_VERSION}"

# ---------- 3. 解析基座的实际 Go 版本与 digest ----------
# 拉取单独做一次。docker run 里的拉取发生在命令替换中，既看不到进度，进程被
# 信号杀掉时连输出都一起消失；显式 pull 能把进度和错误留在日志里，还能重试。
info "拉取基座 golang:${GO_REF}（linux/amd64）"
pull_try=0
until docker pull --platform linux/amd64 "golang:${GO_REF}"; do
  pull_try=$((pull_try + 1))
  [ "${pull_try}" -lt 3 ] || die "拉取 golang:${GO_REF} 失败（已重试 3 次），原因见上方 docker 输出"
  warn "拉取 golang:${GO_REF} 失败，10 秒后重试（${pull_try}/3）"
  sleep 10
done

info "解析基座 golang:${GO_REF} 的实际版本"
# 探针输出先落文件再打印：被信号杀掉时命令替换里的内容会一起丢掉，日志只剩上一行。
GO_LOG_FILE="/tmp/golang-go-version.$$"
probe_rc=0
docker run --rm --platform linux/amd64 "golang:${GO_REF}" go version \
  >"${GO_LOG_FILE}" 2>&1 || probe_rc=$?
if [ -s "${GO_LOG_FILE}" ]; then
  sed 's/^/    /' "${GO_LOG_FILE}"
fi
GO_REAL="$(sed -n 's/^go version go\([0-9][0-9.]*\) .*/\1/p' "${GO_LOG_FILE}")"
rm -f "${GO_LOG_FILE}"
if [ "${probe_rc}" -ne 0 ] \
  || ! printf '%s' "${GO_REAL}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  die "无法解析 golang:${GO_REF} 的 Go 版本（docker run 退出码 ${probe_rc}），检查 Docker 服务与网络"
fi
BASE_DIGEST="$(docker buildx imagetools inspect "golang:${GO_REF}" \
  --format '{{.Manifest.Digest}}' 2>/dev/null || true)"
[ -n "${BASE_DIGEST}" ] || BASE_DIGEST="unknown"
# 滚动 minor 固定取 major.minor（1.27.3 → 1.27）
MINOR="$(printf '%s' "${GO_REAL}" | cut -d. -f1,2)"

# ---------- 3.1 解析工具版本（层缓存的前提） ----------
# 把 latest 变成具体版本号再传给 Dockerfile，缓存键才会跟着版本走。
# 解析失败不阻断构建：回退 latest，由 Dockerfile 在构建时自行解析（缓存不生效）。
DOCKERFILE_GOPROXY="$(read_env GOPROXY "$DOCKERFILE_GOLANG")"
TOOL_VARS="$(dockerfile_tool_vars "$DOCKERFILE_GOLANG") UPX_VERSION NODE_VERSION PNPM_VERSION"

# 自检：Dockerfile 里出现的 go install 版本变量都要在 GO_TOOL_MODULES 里登记
missing_modules=""
for var in $(dockerfile_tool_vars "$DOCKERFILE_GOLANG"); do
  printf '%s\n' "${GO_TOOL_MODULES}" | grep -q "^${var}=" \
    || missing_modules="${missing_modules} ${var}"
done
[ -z "${missing_modules}" ] \
  || die "这些 go install 版本变量没在 GO_TOOL_MODULES 里登记模块路径：${missing_modules}"

info "解析工具最新版本（容器内 go list / curl）"
resolved_versions=""
if resolved_versions="$(resolve_versions)"; then
  info "工具版本解析结果："
  printf '%s\n' "${resolved_versions}" | sed 's/^/    /'
else
  resolved_versions=""
  warn "工具版本解析失败，回退 latest：本次由 Dockerfile 在构建时解析，层缓存不生效"
fi

# ---------- 4. 时间戳与标签 ----------
BUILD_DATE="${CI_COMMIT_TIMESTAMP:-$(git log -1 --format=%cI 2>/dev/null || true)}"
[ -n "${BUILD_DATE}" ] || BUILD_DATE="${EPOCH_DATE}"
# 标签就是 Go 版本号，不加日期：同名标签每天重建会覆盖
STAMP="${GO_REAL}"
VCS_REF="${REVISION}"
BUILT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

info "IMAGE        ${IMAGE}"
info "GO_REF       golang:${GO_REF}"
info "GO_REAL      ${GO_REAL}"
info "BASE_DIGEST  ${BASE_DIGEST}"
info "MINOR        ${MINOR}"
info "STAMP        ${STAMP}"
info "SOURCE       ${IMAGE_SOURCE}"
info "BUILD_DATE   ${BUILD_DATE}"
info "VCS_REF      ${VCS_REF}"

# ---------- 5. 登录 ----------
info "登录 ${REGISTRY}"
printf '%s' "${REGISTRY_TOKEN}" \
  | docker login -u "${REGISTRY_USER}" --password-stdin "${REGISTRY}" \
  || die "docker login 失败"

# ---------- 6. buildx 自检 ----------
docker buildx version || die "docker buildx 不可用"
docker buildx inspect >/dev/null || die "buildx builder 不可用"

# ---------- 7. 构建并推送 golang 基础镜像 ----------
# 层缓存走 registry（<镜像>:buildcache），跨 runner 共享：
#   命中   → apt / Node / go install 整段跳过，只剩拉基座、冒烟、推 manifest；
#   未命中 → 只重建版本变了的那一层。
CACHE_REF="${IMAGE}:${CACHE_REF_SUFFIX}"
CACHE_FROM_READY=""
if [ "${CACHE}" = "on" ]; then
  if docker buildx imagetools inspect "${CACHE_REF}" >/dev/null 2>&1; then
    CACHE_FROM_READY=yes
    info "缓存源 ${CACHE_REF} 可读，本次尝试命中"
  else
    info "缓存源 ${CACHE_REF} 还不存在，本次只写不读"
  fi
fi

build_image() (
  mode=$1
  set -- \
    -t "${IMAGE}:${STAMP}" \
    --platform "${PLATFORMS}" \
    --build-arg "GO_VERSION=${GO_VERSION}" \
    --build-arg "DEBIAN_VERSION=${DEBIAN_VERSION}" \
    --build-arg "IMAGE_VERSION=${STAMP}" \
    --build-arg "IMAGE_SOURCE=${IMAGE_SOURCE}" \
    --build-arg "VCS_REF=${VCS_REF}" \
    --build-arg "BUILD_DATE=${BUILD_DATE}" \
    --build-arg "BASE_DIGEST=${BASE_DIGEST}"
  for var in ${TOOL_VARS}; do
    val="$(version_value "${var}")"
    [ -n "${val}" ] || val="latest"
    set -- "$@" --build-arg "${var}=${val}"
  done
  case "${mode}" in
    on)
      if [ -n "${CACHE_FROM_READY}" ]; then
        set -- "$@" --cache-from "type=registry,ref=${CACHE_REF}"
      fi
      set -- "$@" --cache-to "type=registry,ref=${CACHE_REF},mode=${CACHE_MODE}"
      ;;
    off) set -- "$@" --no-cache ;;
    *) : ;;
  esac
  set -- "$@" --provenance=mode=min --sbom=false -f "${DOCKERFILE_GOLANG}" --push .
  docker buildx build "$@"
)

info "构建 ${IMAGE}:${STAMP}（${PLATFORMS}）"
if [ "${CACHE}" = "off" ]; then
  build_image off || die "golang 镜像 docker buildx build 失败（CACHE=off）"
elif ! build_image on; then
  # 有的 registry 不接受 buildx 的缓存清单（media type / 权限），而且缓存导出是在
  # 镜像推完之后才报错。去掉缓存重试一次，别让当天的构建白跑。
  warn "带缓存的构建失败：可能是 registry 不支持 buildx 缓存清单，去掉缓存重试一次"
  build_image plain || die "golang 镜像 docker buildx build 失败"
fi

GOLANG_INDEX_DIGEST="$(docker buildx imagetools inspect "${IMAGE}:${STAMP}" \
  --format '{{.Manifest.Digest}}' 2>/dev/null || true)"
[ -n "${GOLANG_INDEX_DIGEST}" ] || die "无法读取 ${IMAGE}:${STAMP} 的 index digest"

# ---------- imagetools create 重试包装 ----------
# imagetools create 会把源清单及其 blob 流式复制到目标 tag，registry 刚写完缓存清单
# 就回读时偶尔返回截断响应（copy ...: unexpected EOF）。这是瞬时故障，重推同一份
# manifest 是幂等的：重试 3 次、间隔 5s/10s，全失败才交给调用方 die。
create_tag_with_retry() (
  tag=$1
  src=$2
  attempt=1
  while [ "${attempt}" -le 3 ]; do
    if docker buildx imagetools create -t "${tag}" "${src}"; then
      return 0
    fi
    if [ "${attempt}" -eq 3 ]; then
      return 1
    fi
    warn "imagetools create ${tag} 第 ${attempt} 次失败，$((attempt * 5)) 秒后重试"
    sleep $((attempt * 5))
    attempt=$((attempt + 1))
  done
  return 1
)

# ---------- 8. 从同一 manifest 派生单平台标签 ----------
derive_arch_tags() {
  img=$1
  for arch in amd64 arm64; do
    digest="$(manifest_digest_for "${img}:${STAMP}" "${arch}")"
    [ -n "${digest}" ] || die "未在 ${img}:${STAMP} 中找到 linux/${arch} 条目"
    create_tag_with_retry "${img}:${STAMP}-linux-${arch}" "${img}@${digest}" \
      || die "派生 ${STAMP}-linux-${arch} 失败（已重试 3 次）"
    info "派生 ${img}:${STAMP}-linux-${arch} ← ${digest}"
  done
}

derive_arch_tags "${IMAGE}"

# ---------- 9. 冒烟测试（amd64） ----------
docker pull --platform linux/amd64 "${IMAGE}:${STAMP}" \
  || die "拉取 ${IMAGE}:${STAMP} 失败，latest 未提升"
info "冒烟测试 ${IMAGE}:${STAMP}（linux/amd64）"
if ! smoke_output="$(docker run --rm --platform linux/amd64 \
  -e EXPECT_GO="${GO_REAL}" "${IMAGE}:${STAMP}" sh -eu -c '
    fail=""
    got="$(go version | cut -d" " -f3 | sed "s/^go//")"
    [ "$got" = "$EXPECT_GO" ] || fail="$fail go-version($got)"
    for b in go node npm pnpm git curl make jq zip unzip pkg-config upx nfpm \
      sqlc ent entc golangci-lint govulncheck shfmt dockerfmt yamlfmt gojq \
      sql-formatter gotestsum markdownfmt gocover-cobertura wixl; do
      command -v "$b" >/dev/null 2>&1 || fail="$fail bin:$b"
    done
    # 时区生效：TZ=Asia/Shanghai 下偏移必须是 +0800（tzdata 已装且 zoneinfo 可用）
    [ "$(date +%z)" = "+0800" ] || fail="$fail tz($(date +%z))"
    # 版本命令实际跑一遍：工具默认 @latest 自动追新后，只查 presence
    # 挡不住装坏的二进制。--version / version / -v 逐个兜底，
    # 输出丢弃，仅以退出码计 fail。
    for b in node npm pnpm upx nfpm sqlc golangci-lint gojq shfmt gotestsum; do
      command -v "$b" >/dev/null 2>&1 || continue
      "$b" --version >/dev/null 2>&1 \
        || "$b" version >/dev/null 2>&1 \
        || "$b" -v >/dev/null 2>&1 \
        || fail="$fail run:$b"
    done
    if command -v fnpack >/dev/null 2>&1; then fail="$fail fnpack-present"; fi
    if [ -n "$fail" ]; then printf "FAIL%s" "$fail"; exit 1; fi
    printf "SMOKE_OK"
  ' 2>&1)"; then
  die "golang 镜像冒烟测试失败，latest 未提升：${smoke_output:-docker run 无输出}"
fi
case "${smoke_output}" in
  *SMOKE_OK*) : ;;
  *) die "golang 镜像冒烟测试输出异常，latest 未提升：${smoke_output}" ;;
esac

# 镜像已 pull 到本地，直接读 config 里的 label
label_version="$(docker image inspect \
  --format '{{index .Config.Labels "org.opencontainers.image.version"}}' \
  "${IMAGE}:${STAMP}" 2>/dev/null || true)"
[ "${label_version}" = "${STAMP}" ] \
  || die "golang OCI label 校验失败：org.opencontainers.image.version=${label_version:-<空>}，期望 ${STAMP}"

# ---------- 10. 提升可变标签（冒烟通过后才动） ----------
for tag in "${MINOR}" latest; do
  create_tag_with_retry "${IMAGE}:${tag}" "${IMAGE}:${STAMP}" \
    || die "提升 ${IMAGE}:${tag} 失败（已重试 3 次）"
  info "提升 ${IMAGE}:${tag} → ${STAMP}"
done

# ---------- 11. 汇总元数据 ----------
GOLANG_DIGEST_SHORT="$(printf '%s' "${GOLANG_INDEX_DIGEST#sha256:}" | cut -c1-12)"
GOLANG_SIZE_AMD64="$(image_size_mb "${IMAGE}:${STAMP}" amd64)"
GOLANG_SIZE_ARM64="$(image_size_mb "${IMAGE}:${STAMP}" arm64)"

# 工具版本汇总成一行，方便回查「某天的镜像里到底是哪个版本」
TOOLS_SUMMARY=""
for var in ${TOOL_VARS}; do
  val="$(version_value "${var}")"
  [ -n "${val}" ] || val="latest"
  TOOLS_SUMMARY="${TOOLS_SUMMARY}$(printf '%s' "${var%%_VERSION}" | tr '[:upper:]' '[:lower:]')=${val} "
done

mkdir -p "$(dirname "${ANNOTATION_FILE}")"
cat >"${ANNOTATION_FILE}" <<EOF
{
  "image_ref": "${IMAGE}",
  "golang_image": "${IMAGE}",
  "golang_digest": "${GOLANG_INDEX_DIGEST}",
  "golang_digest_short": "${GOLANG_DIGEST_SHORT}",
  "golang_size": "${GOLANG_SIZE_AMD64}",
  "golang_size_arm64": "${GOLANG_SIZE_ARM64}",
  "image_version": "${STAMP}",
  "golang_version": "${GO_REAL}",
  "base_image": "golang:${GO_REF}",
  "base_digest": "${BASE_DIGEST}",
  "tools": "${TOOLS_SUMMARY% }",
  "built_at": "${BUILT_AT}",
  "source_date": "${BUILD_DATE}",
  "revision": "${VCS_REF}"
}
EOF

# GitLab 没有 GITHUB_OUTPUT；元数据已写入 annotation 文件，随 artifacts 保留。

info "golang  digest ${GOLANG_INDEX_DIGEST}"
info "golang  size   amd64 ${GOLANG_SIZE_AMD64} / arm64 ${GOLANG_SIZE_ARM64}"
info "工具版本       ${TOOLS_SUMMARY% }"
info "元数据         ${ANNOTATION_FILE}"

echo "=============================="
echo "🎉 构建完成 ${IMAGE}:${STAMP}"
echo "=============================="
