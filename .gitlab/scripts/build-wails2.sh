#!/bin/sh
# ===================================================================
# GitLab CI 专用（build-wails2 作业）：多架构
# （linux/amd64 + linux/arm64）构建并推送 wails2 镜像到 GitLab Container Registry：
#
#   ${CI_REGISTRY_IMAGE}/wails2  → golang + GTK3/WebKit2GTK 4.1 + wails CLI
#
# 本脚本不构建基础镜像：它要求 ${CI_REGISTRY_IMAGE}:<go 版本> 已经由
# build-golang 作业推好，直接 FROM 那个 manifest list，只追加
# GTK3/WebKit2GTK 开发包与 wails CLI（命令名是 wails，不是 wails2）。
# 这样各变体镜像的 Go 工具链完全一致。
#
# 触发方式（见 build-wails2.yml）：
#   schedule          → 每天 01:35 UTC 跑
#   web → 手动 Run pipeline，需要基础镜像标签已存在（脚本会等待并给出提示）
#                       可传 version / wails2_version 覆盖默认版本
#
# 这是 GitLab 侧独立实现，与 .cnb/scripts/build-wails2.sh、.github/scripts/build-wails2.sh 各自维护、不互相引用。
# 标签规则、冒烟断言与 CNB / GitHub 侧保持一致。
#
# 环境变量（默认从 GitLab CI 预定义变量派生，显式传同名变量可覆盖）：
#   REGISTRY_TOKEN 必填，docker login 密码（GitLab CI 里取 CI_REGISTRY_PASSWORD）
#   IMAGE          默认 CI_REGISTRY_IMAGE
#   REGISTRY_USER  默认 CI_REGISTRY_USER
#   REVISION       默认 CI_COMMIT_SHA
#   IMAGE_SOURCE   默认 ${CI_PROJECT_URL}
#   version        选填，Go 版本：留空 = Dockerfile 的 GO_VERSION；
#                  也可填 1.27 / 1.27.3
#   wails2_version 选填，wails2 版本：留空 / latest = 解析上游最新稳定 tag
#                  （如 v2.17.1）；也可填 v2.17.1 / 2.17.1
#
# 版本解析为什么要先做：层缓存按 build-arg 的值算缓存键。每天都传字符串
# latest，缓存键永远不变，go install 那一层会一直命中第一次的产物，wails2
# 再也不升级。所以构建前先在基础镜像里用 go list 把 latest 解析成 v2.17.1，
# 再以 --build-arg 传入：上游没发新版就全命中，发新版才重建那一层。
#
# 依赖：docker buildx（由 .gitlab-ci.yml 的 before_script 创建 docker-container builder）、jq 可选（体积精确求和）。
# ===================================================================

set -eu

# ---------- 常量 ----------
DOCKERFILE_GOLANG=".gitlab/docker/Dockerfile.golang"
DOCKERFILE_WAILS2=".gitlab/docker/Dockerfile.wails2"
PLATFORMS="linux/amd64,linux/arm64"
EPOCH_DATE="1970-01-01T00:00:00Z"
# 1 MiB：正常构建镜像不可能低于此值，低于说明拿到的不是镜像清单
MIN_IMAGE_BYTES=1048576
ANNOTATION_FILE=".gitlab/annotation-wails2.json"
# 基础镜像由另一个作业产出，等待它出现在 registry（5 分钟）
BASE_WAIT_ATTEMPTS=20
BASE_WAIT_SECONDS=15
# 层缓存写到 <镜像>:buildcache，mode=min 只导出最终镜像里已有的层（单阶段构建够用）
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

# 解析型 helper 一律以 || true 收尾：GitLab Runner 的包装脚本是 set -eo pipefail，
# grep 匹配不到（例如 Dockerfile 里没有这个变量）时整条 pipeline 返回 1，
# set -e 会在没有任何输出的情况下直接杀掉作业。
# 从 Dockerfile 读取 ARG 的默认值
read_arg() (
  name=$1
  file=$2
  sed -n "s/^ARG ${name}=//p" "${file}" | head -n 1 \
    | sed 's/[[:space:]]*#.*//' | tr -d '[:space:]' || true
)

# 从 Dockerfile 的 ENV 行读变量值：解析 wails2 版本和构建必须走同一个 GOPROXY
# （GitLab 侧 Dockerfile 不设 GOPROXY，这里会得到空值 = 用 Go 默认代理）
read_env() (
  name=$1
  file=$2
  grep -E "^[[:space:]]*${name}=" "${file}" | head -n 1 \
    | sed "s/.*${name}=//" | sed 's/[[:space:]\\]*$//' || true
)

# 2.17.1 → v2.17.1；v2.17.1 原样返回
normalize_tag() (
  case "$1" in
    v*) printf '%s\n' "$1" ;;
    *) printf 'v%s\n' "$1" ;;
  esac
)

# 在基础镜像里解析 wails2 的最新稳定版本。
# 放在容器里跑：不依赖 runner 装了 go / curl，模块路径与 tag 对应关系也交给 go
# （wails 的 v2 模块在仓库 v2/ 子目录，go list 会给出正确的 vX.Y.Z）。
resolve_wails2_latest() {
  set -- --rm -i --platform linux/amd64
  if [ -n "${DOCKERFILE_GOPROXY}" ]; then
    set -- "$@" -e "GOPROXY=${DOCKERFILE_GOPROXY}"
  fi
  docker run "$@" "golang:${GO_REF}" sh -s <<'RESOLVE_EOF'
set -eu
go list -m -f '{{.Version}}' github.com/wailsapp/wails/v2@latest
RESOLVE_EOF
}

# ---------- 0. 环境检查与默认值 ----------
REGISTRY_TOKEN="${REGISTRY_TOKEN:-${CI_REGISTRY_PASSWORD:-}}"
: "${REGISTRY_TOKEN:?缺少环境变量 REGISTRY_TOKEN（GitLab CI 里用 CI_REGISTRY_PASSWORD，或显式传入）}"

version="${version:-}"
wails2_version="${wails2_version:-}"
# CACHE=off：关闭层缓存并强制全量重建
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

WAILS2_IMAGE="${IMAGE}/wails2"

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
echo "🔧 构建多架构 Golang + wails2 镜像（GitLab Container Registry）"
echo "=============================="

# ---------- 1. version 校验 ----------
case "$version" in
  '' | latest) : ;;
  *)
    printf '%s' "${version}" | grep -Eq '^[0-9]+\.[0-9]+(\.[0-9]+)?$' \
      || die "version 只接受 1.27 / 1.27.3，收到：${version}"
    ;;
esac
# wails2_version 留空 / latest：解析上游最新稳定 tag；
# 也可以钉具体 tag，允许预发布后缀。
case "$wails2_version" in
  '' | latest) : ;;
  *)
    printf '%s' "${wails2_version}" | grep -Eq '^v?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$' \
      || die "wails2_version 只接受版本号（如 v2.17.1 / 2.17.1），收到：${wails2_version}"
    ;;
esac

# ---------- 2. 基座引用 ----------
[ -f "$DOCKERFILE_GOLANG" ] \
  || die "找不到 ${DOCKERFILE_GOLANG}（当前目录 $(pwd)）：请在仓库根目录执行本脚本"
[ -f "$DOCKERFILE_WAILS2" ] \
  || die "找不到 ${DOCKERFILE_WAILS2}（当前目录 $(pwd)）：请在仓库根目录执行本脚本"
GO_VERSION="$(read_arg GO_VERSION "$DOCKERFILE_GOLANG")"
DEBIAN_VERSION="$(read_arg DEBIAN_VERSION "$DOCKERFILE_GOLANG")"
[ -n "${GO_VERSION}" ] || die "无法从 ${DOCKERFILE_GOLANG} 解析 ARG GO_VERSION"
[ -n "${DEBIAN_VERSION}" ] || die "无法从 ${DOCKERFILE_GOLANG} 解析 ARG DEBIAN_VERSION"
if [ -n "$version" ]; then
  GO_VERSION="$version"
  info "version 入参 ${version}"
fi
GO_REF="${GO_VERSION}-${DEBIAN_VERSION}"

WAILS2_VERSION_DEFAULT="$(read_arg WAILS2_VERSION "$DOCKERFILE_WAILS2")"
[ -n "${WAILS2_VERSION_DEFAULT}" ] || die "无法从 ${DOCKERFILE_WAILS2} 解析 ARG WAILS2_VERSION"

# ---------- 3. 解析实际 Go 版本 ----------
info "解析基座 golang:${GO_REF} 的实际版本"
GO_REAL="$(docker run --rm --platform linux/amd64 "golang:${GO_REF}" go version 2>/dev/null \
  | sed -n 's/^go version go\([0-9][0-9.]*\) .*/\1/p' || true)"
printf '%s' "${GO_REAL}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
  || die "无法解析 golang:${GO_REF} 的 Go 版本（得到：${GO_REAL:-空}），检查 Docker 服务与网络"
# 滚动 minor 固定取 major.minor（1.27.3 → 1.27）
MINOR="$(printf '%s' "${GO_REAL}" | cut -d. -f1,2)"

# ---------- 3.1 解析 wails2 版本（层缓存的前提） ----------
DOCKERFILE_GOPROXY="$(read_env GOPROXY "$DOCKERFILE_GOLANG")"
case "$wails2_version" in
  '' | latest)
    # Dockerfile 默认值可能本身就是一个具体 tag（本地改过默认值时尊重它）
    if [ "${WAILS2_VERSION_DEFAULT}" != "latest" ]; then
      WAILS2_VERSION="$(normalize_tag "${WAILS2_VERSION_DEFAULT}")"
      info "wails2_version 留空：使用 Dockerfile 默认 ${WAILS2_VERSION}"
    else
      WAILS2_LATEST="$(resolve_wails2_latest 2>/dev/null \
        | tr -d '[:space:]' || true)"
      if printf '%s' "${WAILS2_LATEST}" | grep -Eq '^v2\.[0-9]+\.[0-9]+$'; then
        WAILS2_VERSION="${WAILS2_LATEST}"
        info "wails2_version 留空：解析到上游最新稳定版 ${WAILS2_VERSION}"
      else
        WAILS2_VERSION="latest"
        warn "无法解析 wails2 最新版本（得到：${WAILS2_LATEST:-空}），回退 latest：本次由 Dockerfile 在构建时解析，层缓存不生效"
      fi
    fi
    ;;
  *)
    WAILS2_VERSION="$(normalize_tag "$wails2_version")"
    info "wails2_version 入参 ${WAILS2_VERSION}"
    ;;
esac

# ---------- 4. 时间戳与标签 ----------
BUILD_DATE="${CI_COMMIT_TIMESTAMP:-$(git log -1 --format=%cI 2>/dev/null || true)}"
[ -n "${BUILD_DATE}" ] || BUILD_DATE="${EPOCH_DATE}"
# 标签就是 Go 版本号，不加日期：同名标签每天重建会覆盖。
# wails2 自身的版本不占标签，只记录在元数据 wails2_version 里。
STAMP="${GO_REAL}"
VCS_REF="${REVISION}"
BUILT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

info "IMAGE          ${IMAGE}"
info "WAILS2_IMAGE   ${WAILS2_IMAGE}"
info "GO_REF         golang:${GO_REF}"
info "GO_REAL        ${GO_REAL}"
info "MINOR          ${MINOR}"
info "STAMP          ${STAMP}"
info "WAILS2         ${WAILS2_VERSION}"
info "SOURCE         ${IMAGE_SOURCE}"
info "BUILD_DATE     ${BUILD_DATE}"
info "VCS_REF        ${VCS_REF}"

# ---------- 5. 登录 ----------
info "登录 ${REGISTRY}"
printf '%s' "${REGISTRY_TOKEN}" \
  | docker login -u "${REGISTRY_USER}" --password-stdin "${REGISTRY}" \
  || die "docker login 失败"

# ---------- 6. buildx 自检 ----------
docker buildx version || die "docker buildx 不可用"
docker buildx inspect >/dev/null || die "buildx builder 不可用"

# ---------- 7. 等基础镜像就绪 ----------
# 定时任务里基础镜像已在 3 小时前推好；手动触发时要求它已经存在。
# registry 偶有延迟，因此仍轮询几分钟。
attempt=0
while [ "${attempt}" -lt "${BASE_WAIT_ATTEMPTS}" ]; do
  if docker buildx imagetools inspect "${IMAGE}:${STAMP}" >/dev/null 2>&1; then
    break
  fi
  attempt=$((attempt + 1))
  info "等待基础镜像 ${IMAGE}:${STAMP}（${attempt}/${BASE_WAIT_ATTEMPTS}）"
  sleep "${BASE_WAIT_SECONDS}"
done
docker buildx imagetools inspect "${IMAGE}:${STAMP}" >/dev/null 2>&1 \
  || die "基础镜像 ${IMAGE}:${STAMP} 不存在：先运行 build-golang 作业（或等它的定时任务完成），wails2 镜像必须基于它构建"

BASE_INDEX_DIGEST="$(docker buildx imagetools inspect "${IMAGE}:${STAMP}" \
  --format '{{.Manifest.Digest}}' 2>/dev/null || true)"
[ -n "${BASE_INDEX_DIGEST}" ] || die "无法读取 ${IMAGE}:${STAMP} 的 index digest"

# ---------- 8. 构建并推送 wails2 镜像 ----------
# FROM build-golang 推好的 manifest list：每个平台解析到对应架构的 golang 镜像。
# 基础镜像 digest 没变、wails2 版本没变时，Go 编译那一层也全命中。
CACHE_REF="${WAILS2_IMAGE}:${CACHE_REF_SUFFIX}"
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
    -t "${WAILS2_IMAGE}:${STAMP}" \
    --platform "${PLATFORMS}" \
    --build-arg "GOLANG_IMAGE=${IMAGE}:${STAMP}" \
    --build-arg "WAILS2_VERSION=${WAILS2_VERSION}" \
    --build-arg "IMAGE_VERSION=${STAMP}" \
    --build-arg "IMAGE_SOURCE=${IMAGE_SOURCE}" \
    --build-arg "VCS_REF=${VCS_REF}" \
    --build-arg "BUILD_DATE=${BUILD_DATE}" \
    --build-arg "BASE_DIGEST=${BASE_INDEX_DIGEST}"
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
  set -- "$@" --provenance=mode=min --sbom=false -f "${DOCKERFILE_WAILS2}" --push .
  docker buildx build "$@"
)

info "构建 ${WAILS2_IMAGE}:${STAMP}（${PLATFORMS}）"
if [ "${CACHE}" = "off" ]; then
  build_image off || die "wails2 镜像 docker buildx build 失败（CACHE=off）"
elif ! build_image on; then
  # 有的 registry 不接受 buildx 的缓存清单，缓存导出在镜像推完之后才报错。
  warn "带缓存的构建失败：可能是 registry 不支持 buildx 缓存清单，去掉缓存重试一次"
  build_image plain || die "wails2 镜像 docker buildx build 失败"
fi

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

# ---------- 9. 从同一 manifest 派生单平台标签 ----------
for arch in amd64 arm64; do
  digest="$(manifest_digest_for "${WAILS2_IMAGE}:${STAMP}" "${arch}")"
  [ -n "${digest}" ] || die "未在 ${WAILS2_IMAGE}:${STAMP} 中找到 linux/${arch} 条目"
  create_tag_with_retry "${WAILS2_IMAGE}:${STAMP}-linux-${arch}" "${WAILS2_IMAGE}@${digest}" \
    || die "派生 ${STAMP}-linux-${arch} 失败（已重试 3 次）"
  info "派生 ${WAILS2_IMAGE}:${STAMP}-linux-${arch} ← ${digest}"
done

# ---------- 10. 冒烟测试（amd64） ----------
docker pull --platform linux/amd64 "${WAILS2_IMAGE}:${STAMP}" \
  || die "拉取 ${WAILS2_IMAGE}:${STAMP} 失败，latest 未提升"
info "冒烟测试 ${WAILS2_IMAGE}:${STAMP}（linux/amd64）"
if ! smoke_output="$(docker run --rm --platform linux/amd64 \
  -e EXPECT_GO="${GO_REAL}" -e EXPECT_WAILS2="${WAILS2_VERSION}" \
  "${WAILS2_IMAGE}:${STAMP}" sh -eu -c '
    fail=""
    got="$(go version | cut -d" " -f3 | sed "s/^go//")"
    [ "$got" = "$EXPECT_GO" ] || fail="$fail go-version($got)"
    for b in go node pnpm sqlc golangci-lint zip unzip pkg-config; do
      command -v "$b" >/dev/null 2>&1 || fail="$fail bin:$b"
    done
    # wails build 依赖这两个 .pc 文件，装包时断言过，这里再确认一次没被清理掉
    pkg-config --exists gtk+-3.0 || fail="$fail pkg:gtk+-3.0"
    pkg-config --exists webkit2gtk-4.1 || fail="$fail pkg:webkit2gtk-4.1"
    command -v wails >/dev/null 2>&1 || fail="$fail bin:wails"
    # 版本直接读二进制里嵌入的模块信息：比解析 `wails version` 的输出格式可靠。
    # 缺了这一行说明 go install 装成了别的模块/版本。
    wails_mod="$(go version -m "$(command -v wails)" 2>/dev/null \
      | sed -n "s/^[[:space:]]*mod[[:space:]]\{1,\}github\.com\/wailsapp\/wails\/v2[[:space:]]\{1,\}\([^[:space:]]*\).*/\1/p" \
      | head -n 1)"
    if [ "$EXPECT_WAILS2" != "latest" ]; then
      [ "$wails_mod" = "$EXPECT_WAILS2" ] || fail="$fail wails2-version(${wails_mod:-空})"
    fi
    # 版本命令能跑通（部分版本没有 version 子命令，逐个兜底）
    wails version >/dev/null 2>&1 \
      || wails --version >/dev/null 2>&1 \
      || wails --help >/dev/null 2>&1 \
      || fail="$fail run:wails"
    # 基座里不该出现 fnpack：这个镜像是 golang + wails2，不是 fnpack 变体
    if command -v fnpack >/dev/null 2>&1; then fail="$fail fnpack-present"; fi
    if [ -n "$fail" ]; then printf "FAIL%s" "$fail"; exit 1; fi
    printf "SMOKE_OK"
  ' 2>&1)"; then
  die "wails2 镜像冒烟测试失败，latest 未提升：${smoke_output:-docker run 无输出}"
fi
case "${smoke_output}" in
  *SMOKE_OK*) : ;;
  *) die "wails2 镜像冒烟测试输出异常，latest 未提升：${smoke_output}" ;;
esac

# 系统包版本：包清单从本镜像对应的 Dockerfile 自动提取（改 Dockerfile 自动跟上），
# 版本取自镜像内的 dpkg 数据库；构建期装过、最后被 purge 的包显示 absent。
apt_pkgs_from_dockerfile() (
  sed -n '/apt-get install/,/;/p' "$1" \
    | sed 's/#.*//; s/\\//g; s/;//g' | tr '[:space:]' '\n' \
    | grep -E '^[a-z][a-z0-9+.-]*$' \
    | grep -vxE 'export|apt-get|install|update|rm|rf|yes|no|sh' | sort -u
)
apt_versions_from_image() (
  img=$1
  pkgs=$2
  [ -n "${pkgs}" ] || {
    printf 'none'
    return 0
  }
  # shellcheck disable=SC2086  # 包名按空白拆成多个位置参数
  docker run --rm --platform linux/amd64 "${img}" \
    sh -c 'for p in "$@"; do v="$(dpkg-query -W -f="\${Version}" "$p" 2>/dev/null || true)"; printf "%s=%s " "$p" "${v:-absent}"; done' \
    sh ${pkgs} 2>/dev/null | sed 's/[[:space:]]*$//' || true
)
APT_VERSIONS="$(apt_versions_from_image "${WAILS2_IMAGE}:${STAMP}" \
  "$(apt_pkgs_from_dockerfile "${DOCKERFILE_WAILS2}")")"
[ -n "${APT_VERSIONS}" ] || APT_VERSIONS="unknown"

# 镜像已 pull 到本地，直接读 config 里的 label
label_version="$(docker image inspect \
  --format '{{index .Config.Labels "org.opencontainers.image.version"}}' \
  "${WAILS2_IMAGE}:${STAMP}" 2>/dev/null || true)"
[ "${label_version}" = "${STAMP}" ] \
  || die "wails2 OCI label 校验失败：org.opencontainers.image.version=${label_version:-<空>}，期望 ${STAMP}"

# ---------- 11. 提升可变标签（冒烟通过、且基础镜像的移动标签已就位） ----------
# 先确认 golang:<tag> 也指向本次 <go 版本>，避免 wails2 的 latest 跑到基础镜像前面。
for tag in "${MINOR}" latest; do
  # inspect 读失败不能当成「基座未对齐」静默跳过：重试 3 次仍读不到时打明确告警。
  base_tag_digest=""
  inspect_n=1
  while [ "${inspect_n}" -le 3 ]; do
    if base_tag_digest="$(docker buildx imagetools inspect "${IMAGE}:${tag}" \
      --format '{{.Manifest.Digest}}' 2>/dev/null)"; then
      break
    fi
    if [ "${inspect_n}" -eq 3 ]; then
      warn "读取 ${IMAGE}:${tag} 失败（已重试 3 次）：无法确认基座是否对齐，跳过提升"
      break
    fi
    warn "读取 ${IMAGE}:${tag} 第 ${inspect_n} 次失败，$((inspect_n * 5)) 秒后重试"
    sleep $((inspect_n * 5))
    inspect_n=$((inspect_n + 1))
  done
  if [ "${base_tag_digest}" != "${BASE_INDEX_DIGEST}" ]; then
    info "跳过 ${WAILS2_IMAGE}:${tag}：${IMAGE}:${tag} 尚未指向 ${STAMP}"
    continue
  fi
  create_tag_with_retry "${WAILS2_IMAGE}:${tag}" "${WAILS2_IMAGE}:${STAMP}" \
    || die "提升 ${WAILS2_IMAGE}:${tag} 失败（已重试 3 次）"
  info "提升 ${WAILS2_IMAGE}:${tag} → ${STAMP}"
done

# ---------- 12. 汇总元数据 ----------
WAILS2_INDEX_DIGEST="$(docker buildx imagetools inspect "${WAILS2_IMAGE}:${STAMP}" \
  --format '{{.Manifest.Digest}}' 2>/dev/null || true)"
WAILS2_DIGEST_SHORT="$(printf '%s' "${WAILS2_INDEX_DIGEST#sha256:}" | cut -c1-12)"
WAILS2_SIZE_AMD64="$(image_size_mb "${WAILS2_IMAGE}:${STAMP}" amd64)"
WAILS2_SIZE_ARM64="$(image_size_mb "${WAILS2_IMAGE}:${STAMP}" arm64)"

mkdir -p "$(dirname "${ANNOTATION_FILE}")"
cat >"${ANNOTATION_FILE}" <<EOF
{
  "wails2_image": "${WAILS2_IMAGE}",
  "wails2_digest": "${WAILS2_INDEX_DIGEST:-unknown}",
  "wails2_digest_short": "${WAILS2_DIGEST_SHORT:-unknown}",
  "wails2_size": "${WAILS2_SIZE_AMD64}",
  "wails2_size_arm64": "${WAILS2_SIZE_ARM64}",
  "wails2_version": "${WAILS2_VERSION}",
  "image_version": "${STAMP}",
  "golang_version": "${GO_REAL}",
  "wails2_base_image": "${IMAGE}:${STAMP}",
  "wails2_base_digest": "${BASE_INDEX_DIGEST}",
  "apt_versions": "${APT_VERSIONS}",
  "built_at": "${BUILT_AT}",
  "source_date": "${BUILD_DATE}",
  "revision": "${VCS_REF}"
}
EOF

# GitLab 没有 GITHUB_OUTPUT；元数据已写入 annotation 文件，随 artifacts 保留。

info "wails2  digest ${WAILS2_INDEX_DIGEST:-unknown}"
info "wails2  size   amd64 ${WAILS2_SIZE_AMD64} / arm64 ${WAILS2_SIZE_ARM64}"
info "base    digest ${BASE_INDEX_DIGEST}"
info "元数据         ${ANNOTATION_FILE}"

echo "=============================="
echo "🎉 构建完成 ${WAILS2_IMAGE}:${STAMP}（wails2 ${WAILS2_VERSION}）"
echo "=============================="
