#!/bin/sh
# ===================================================================
# CNB 专用（build-golang 流水线）：多架构（linux/amd64 + linux/arm64）
# 构建并推送 golang 基础镜像：
#
#   <registry>/<repo>  → golang（不含 fnpack）
#
# fnpack 镜像是独立的 <registry>/<repo>/fnpack，由 build-fnpack 流水线负责：
# 它 FROM 本流水线推好的 <go 版本> 标签，只追加一个 fnpack 二进制。
# 两个流水线各自对应一个镜像地址。
#
# CNB 侧独立实现，与 .github/scripts/build-golang.sh 各自维护、不互相引用。
# 两侧的标签规则、冒烟断言必须保持一致；平台胶水（变量来源、镜像源、元数据落地）
# 各自维护。
#
# 与 GitHub 侧的差异：
#   1. 镜像名从 CNB_DOCKER_REGISTRY + CNB_REPO_SLUG_LOWERCASE 派生；
#   2. GitHub Release / nodejs.org 下载走 https://files.m.daocloud.io；
#   3. 元数据写 .cnb/annotation.json，并通过 ##[set-output] 输出变量；
#   4. 多一层自检：脚本被 imports 改写时立刻停下。
#
# 设计约束（与 GitHub 侧一致）：
#   1. 基座跟随上游：Dockerfile 的 GO_VERSION 默认 1（golang:1-trixie 浮动标签，
#      自动跟随最新稳定 Go），手动触发可以钉版本；
#      实际 Go 版本由脚本解析后写进标签与 OCI label。
#   2. 先推 <go 版本>，冒烟通过后才提升 latest / <minor>。
#   3. 必须 source 执行：##[set-output] 与 export 只在当前 shell 生效。
#   4. 层缓存 = 先解析版本、再按版本构建：
#      buildx 的层缓存按 build-arg 的值算缓存键。如果每天都传字符串 latest，
#      缓存键永远不变，层会一直命中第一次构建的产物，工具再也不升级。
#      所以构建前先在基础镜像里把 latest 解析成 v1.31.1 这种具体版本号，
#      再以 --build-arg 传入：上游没发新版就全命中（只拉基座 + 冒烟），
#      发新版才重建对应那一层。缓存本身走 <镜像>:buildcache（跨节点）。
#      CACHE=off 可关闭缓存并强制全量重建。
#
# 依赖：docker buildx（CNB services: docker 自带）、jq 可选（体积精确求和）。
# ===================================================================

set -eu

# ---------- 常量 ----------
# 路径写死，不从环境变量读：imports 处理曾把 ${...} 改写成带引号的字面量。
DOCKERFILE_GOLANG=".cnb/docker/Dockerfile.golang"
PLATFORMS="linux/amd64,linux/arm64"
EPOCH_DATE="1970-01-01T00:00:00Z"
MIN_IMAGE_BYTES=1048576
ANNOTATION_FILE=".cnb/annotation.json"
# CNB 在国内，GitHub Release 与 nodejs.org 走 DaoCloud 镜像。
MIRROR="https://files.m.daocloud.io"
# 层缓存写到 <镜像>:buildcache，mode=min 只导出最终镜像里已有的层。
# 本 Dockerfile 是单阶段构建、每一层都在最终镜像里，所以 min 就够用，
# 而且不会产生没人引用的孤儿 blob；将来改成多阶段构建要换成 max。
CACHE_REF_SUFFIX="buildcache"
CACHE_MODE="min"
# ---------- 输出助手 ----------
info() { printf '  %s\n' "$*"; }
warn() { printf '警告: %s\n' "$*" >&2; }
_selfcheck=ok
die() {
  printf '错误: %s\n' "$*" >&2
  exit 1
}

# ---------- 自检：脚本必须原样到达 runner ----------
case "${_selfcheck:-missing}" in
  ok) : ;;
  *) die '脚本被外部改写：${...} 没有正常展开（检查 .cnb.yml 的 imports 是否又引入了本脚本）' ;;
esac

# ---------- manifest / 体积助手 ----------
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
        | awk '{s+=$1} END{print s+0}')"
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

read_arg() (
  name=$1
  file=$2
  sed -n "s/^ARG ${name}=//p" "${file}" | head -n 1 \
    | sed 's/[[:space:]]*#.*//' | tr -d '[:space:]'
)

# 从 Dockerfile 的 ENV 行读变量值：解析和构建必须走同一个 GOPROXY
read_env() (
  name=$1
  file=$2
  grep -E "^[[:space:]]*${name}=" "${file}" | head -n 1 \
    | sed "s/.*${name}=//" | sed 's/[[:space:]\\]*$//'
)

# 从 Dockerfile 读 npm registry：解析 pnpm 版本要用同一个源
read_npm_registry() (
  grep -o 'npm config set registry [^;]*' "$1" | head -n 1 \
    | sed 's/^npm config set registry //'
)

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
"

# 从 Dockerfile 提取 go install 用到的版本变量（去重、排序）
# 不假设 go install 后面直接跟包路径：中间可能有 -v 之类的 flag，也可能带引号
dockerfile_tool_vars() (
  grep -o 'go install[^@;]*@\${[A-Z_][A-Z0-9_]*}' "$1" \
    | sed -n 's/.*@\${\([A-Z_][A-Z0-9_]*\)}/\1/p' | sort -u
)

# 取解析结果：resolved_versions 是 KEY=VALUE 的换行列表
version_value() (
  printf '%s\n' "${resolved_versions}" | sed -n "s/^${1}=//p" | head -n 1
)

# 在基础镜像里解析最新版本，输出 KEY=VALUE。
# 放在容器里跑：不依赖 runner 装了 go / curl / jq，模块路径转义也交给 go。
resolve_versions() {
  set -- --rm -i --platform linux/amd64 \
    -e "GO_TOOL_MODULES=${GO_TOOL_MODULES}" \
    -e "GITHUB_MIRROR=${MIRROR}" \
    -e "NODE_MIRROR=${MIRROR}" \
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

# ---------- 0. 环境检查 ----------
: "${CNB_DOCKER_REGISTRY:?缺少环境变量 CNB_DOCKER_REGISTRY}"
: "${CNB_REPO_SLUG_LOWERCASE:?缺少环境变量 CNB_REPO_SLUG_LOWERCASE}"
: "${CNB_TOKEN_USER_NAME:?缺少环境变量 CNB_TOKEN_USER_NAME}"
: "${CNB_TOKEN:?缺少环境变量 CNB_TOKEN}"
: "${CNB_REPO_URL_HTTPS:?缺少环境变量 CNB_REPO_URL_HTTPS}"

# 凭证只在本次构建内有效
HOMEDIR="${HOME:-/root}"
cleanup() { rm -f "$HOMEDIR/.docker/config.json"; }
trap cleanup EXIT

IMAGE="${CNB_DOCKER_REGISTRY}/${CNB_REPO_SLUG_LOWERCASE}"
IMAGE_SOURCE="${CNB_REPO_URL_HTTPS}"

# cron 不传 version
version="${version:-}"
# CACHE=off：关闭层缓存并强制全量重建（怀疑缓存脏了、或 registry 不接受缓存清单时用）
CACHE="${CACHE:-on}"
case "${CACHE}" in
  on | off) : ;;
  *) die "CACHE 只接受 on / off，收到：${CACHE}" ;;
esac

echo "=============================="
echo "🔧 构建多架构 Golang 镜像"
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
info "解析基座 golang:${GO_REF} 的实际版本"
GO_REAL="$(docker run --rm --platform linux/amd64 "golang:${GO_REF}" go version 2>/dev/null \
  | sed -n 's/^go version go\([0-9][0-9.]*\) .*/\1/p' || true)"
printf '%s' "${GO_REAL}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
  || die "无法解析 golang:${GO_REF} 的 Go 版本（得到：${GO_REAL:-空}），检查 Docker 服务与网络"
BASE_DIGEST="$(docker buildx imagetools inspect "golang:${GO_REF}" \
  --format '{{.Manifest.Digest}}' 2>/dev/null || true)"
[ -n "${BASE_DIGEST}" ] || BASE_DIGEST="unknown"
MINOR="$(printf '%s' "${GO_REAL}" | cut -d. -f1,2)"

# ---------- 3.1 解析工具版本（层缓存的前提） ----------
# 把 latest 变成具体版本号再传给 Dockerfile，缓存键才会跟着版本走。
# 解析失败不阻断构建：回退 latest，由 Dockerfile 在构建时自行解析（缓存不生效）。
DOCKERFILE_GOPROXY="$(read_env GOPROXY "$DOCKERFILE_GOLANG")"
NPM_REGISTRY="$(read_npm_registry "$DOCKERFILE_GOLANG")"
TOOL_VARS="$(dockerfile_tool_vars "$DOCKERFILE_GOLANG") UPX_VERSION NODE_VERSION PNPM_VERSION"

# 自检：Dockerfile 里出现的 go install 版本变量都要在 GO_TOOL_MODULES 里登记
missing_modules=""
for var in $(dockerfile_tool_vars "$DOCKERFILE_GOLANG"); do
  printf '%s\n' "${GO_TOOL_MODULES}" | grep -q "^${var}=" \
    || missing_modules="${missing_modules} ${var}"
done
[ -z "${missing_modules}" ] \
  || die "这些 go install 版本变量没在 GO_TOOL_MODULES 里登记模块路径：${missing_modules}"

resolved_versions=""
if resolved_versions="$(resolve_versions)"; then
  info "工具版本解析结果："
  printf '%s\n' "${resolved_versions}" | sed 's/^/    /'
else
  resolved_versions=""
  warn "工具版本解析失败，回退 latest：本次由 Dockerfile 在构建时解析，层缓存不生效"
fi

# ---------- 4. 时间戳与标签 ----------
BUILD_DATE="$(git log -1 --format=%cI 2>/dev/null || true)"
[ -n "${BUILD_DATE}" ] || BUILD_DATE="${EPOCH_DATE}"
STAMP="${GO_REAL}"
VCS_REF="${CNB_COMMIT:-unknown}"
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
info "登录 ${CNB_DOCKER_REGISTRY}"
printf '%s' "${CNB_TOKEN}" \
  | docker login -u "${CNB_TOKEN_USER_NAME}" --password-stdin "${CNB_DOCKER_REGISTRY}" \
  || die "docker login 失败"

# ---------- 6. buildx 自检 ----------
# CNB 的 services: docker 已内置可做多架构的 builder，不要再 create
# --driver docker-container：受限容器里拉不起嵌套 buildkitd，会 bootstrap 失败。
docker buildx version || die "docker buildx 不可用"
docker buildx inspect >/dev/null || die "buildx builder 不可用"

# ---------- 7. 构建并推送 golang 基础镜像 ----------
# 层缓存走 registry（<镜像>:buildcache），跨节点共享：
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
    --build-arg "GITHUB_MIRROR=${MIRROR}" \
    --build-arg "NODE_MIRROR=${MIRROR}" \
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

# ---------- 直接挂 manifest（绕开 imagetools create 的 blob 复制） ----------
# CNB 制品库不支持把镜像清单当 blob 读，copy ... unexpected EOF 稳定复现、重试无效。
# 源与目标同仓库时把清单原文 PUT 到新 tag：层 blob 已在制品库里，不触发复制。
REG_HOST="${IMAGE%%/*}"
REPO_PATH="${IMAGE#*/}"
OCI_ACCEPT="application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json"

# /v2/ 的 Www-Authenticate 给出 Bearer realm/service，用 docker login 的同一组凭证换 token。
registry_auth() (
  basic="$(printf '%s:%s' "${CNB_TOKEN_USER_NAME}" "${CNB_TOKEN}" | base64 | tr -d '\n')"
  challenge="$(curl -sS -D - -o /dev/null "https://${REG_HOST}/v2/" 2>/dev/null \
    | tr -d '\r' | grep -i '^www-authenticate:' | tail -n 1 || true)"
  realm="$(printf '%s' "${challenge}" | sed -n 's/.*realm="\([^"]*\)".*/\1/p')"
  service="$(printf '%s' "${challenge}" | sed -n 's/.*service="\([^"]*\)".*/\1/p')"
  if [ -z "${realm}" ]; then
    printf 'Authorization: Basic %s\n' "${basic}"
    return 0
  fi
  token="$(curl -sS -H "Authorization: Basic ${basic}" \
    "${realm}?service=${service}&scope=repository:${REPO_PATH}:pull,push" \
    | sed -n 's/.*"token":"\([^"]*\)".*/\1/p' | tr -d '\n' || true)"
  [ -n "${token}" ] || return 1
  printf 'Authorization: Bearer %s\n' "${token}"
)

# $1=目标 tag，$2=源清单引用（tag 或 sha256:digest）；成功时打印写入的 digest。
put_manifest() (
  tag=$1
  src=$2
  body="$(mktemp)"
  hdr="$(mktemp)"
  put_hdr="$(mktemp)"
  auth="$(registry_auth)" || {
    rm -f "${body}" "${hdr}" "${put_hdr}"
    return 1
  }
  if ! curl -fsS -D "${hdr}" -o "${body}" -H "${auth}" -H "Accept: ${OCI_ACCEPT}" \
    "https://${REG_HOST}/v2/${REPO_PATH}/manifests/${src}"; then
    warn "读取源清单 ${src} 失败"
    rm -f "${body}" "${hdr}" "${put_hdr}"
    return 1
  fi
  media="$(tr -d '\r' <"${hdr}" \
    | sed -n 's/^[Cc]ontent-[Tt]ype:[[:space:]]*\([^;[:space:]]*\).*/\1/p' | tail -n 1)"
  want="$(tr -d '\r' <"${hdr}" \
    | sed -n 's/^[Dd]ocker-[Cc]ontent-[Dd]igest:[[:space:]]*\([^[:space:]]*\).*/\1/p' | tail -n 1)"
  [ -n "${media}" ] || media="application/vnd.oci.image.manifest.v1+json"
  if ! curl -fsS -X PUT -D "${put_hdr}" -o /dev/null \
    -H "${auth}" -H "Content-Type: ${media}" --data-binary "@${body}" \
    "https://${REG_HOST}/v2/${REPO_PATH}/manifests/${tag}"; then
    warn "PUT ${tag} 失败（源 ${src}，Content-Type ${media}）"
    rm -f "${body}" "${hdr}" "${put_hdr}"
    return 1
  fi
  got="$(tr -d '\r' <"${put_hdr}" \
    | sed -n 's/^[Dd]ocker-[Cc]ontent-[Dd]igest:[[:space:]]*\([^[:space:]]*\).*/\1/p' | tail -n 1)"
  if [ -n "${want}" ] && [ -n "${got}" ] && [ "${want}" != "${got}" ]; then
    warn "PUT ${tag} 后 digest 不一致：${want} → ${got}"
    rm -f "${body}" "${hdr}" "${put_hdr}"
    return 1
  fi
  printf '%s\n' "${want:-unknown}"
  rm -f "${body}" "${hdr}" "${put_hdr}"
)

# ---------- 8. 从同一 manifest 派生单平台标签 ----------
derive_arch_tags() {
  img=$1
  for arch in amd64 arm64; do
    digest="$(manifest_digest_for "${img}:${STAMP}" "${arch}")"
    [ -n "${digest}" ] || die "未在 ${img}:${STAMP} 中找到 linux/${arch} 条目"
    put_manifest "${STAMP}-linux-${arch}" "${digest}" \
      || die "派生 ${STAMP}-linux-${arch} 失败（Registry API PUT）"
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
      sql-formatter gotestsum markdownfmt; do
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

label_version="$(docker image inspect \
  --format '{{index .Config.Labels "org.opencontainers.image.version"}}' \
  "${IMAGE}:${STAMP}" 2>/dev/null || true)"
[ "${label_version}" = "${STAMP}" ] \
  || die "golang OCI label 校验失败：org.opencontainers.image.version=${label_version:-<空>}，期望 ${STAMP}"

# ---------- 10. 提升可变标签（冒烟通过后才动） ----------
for tag in "${MINOR}" latest; do
  put_manifest "${tag}" "${STAMP}" \
    || die "提升 ${IMAGE}:${tag} 失败（Registry API PUT）"
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

# 向 CNB Stage Result 输出变量（必须 source 才生效）
printf '##[set-output image_version=%s]\n' "${STAMP}"
printf '##[set-output golang_version=%s]\n' "${GO_REAL}"
export IMAGE_VERSION="${STAMP}"

mkdir -p .cnb
cat >"${ANNOTATION_FILE}" <<EOF
{
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
  "source_date": "${BUILD_DATE}"
}
EOF

info "golang  digest ${GOLANG_INDEX_DIGEST}"
info "golang  size   amd64 ${GOLANG_SIZE_AMD64} / arm64 ${GOLANG_SIZE_ARM64}"
info "工具版本       ${TOOLS_SUMMARY% }"
info "元数据         ${ANNOTATION_FILE}"

echo "=============================="
echo "🎉 构建完成 ${IMAGE}:${STAMP}"
echo "=============================="
