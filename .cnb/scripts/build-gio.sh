#!/bin/sh
# ===================================================================
# CNB 专用（build-gio 流水线）：多架构（linux/amd64 + linux/arm64）
# 构建并推送 gio 镜像：
#
#   <registry>/<repo>/gio  → golang + EGL/GLES/X11/Wayland/Vulkan 开发包
#                            + 无头运行库 + gogio CLI
#
# 本脚本不构建基础镜像：它要求 <registry>/<repo>:<go 版本> 已由 build-golang
# 流水线推好，直接 FROM 那个 manifest list，只追加 cgo 依赖、无头运行库与
# gogio CLI。定时任务给 build-golang 留了十八小时（00:05 → 18:05）。
#
# CNB 侧独立实现，与 .github/scripts/build-gio.sh 各自维护、不互相引用。
# 标签规则、冒烟断言与 GitHub 侧保持一致。
#
# 变体名叫 gio，CLI 却叫 gogio，两者不要混：
#   go install gioui.org/cmd/gogio   ← 装出来的二进制是 gogio
# gogio 是「打包」工具（android / ios / tvos / js / windows / macos），没有
# linux 目标，也没有 version 子命令；Linux 桌面程序就是普通 go build + cgo。
# 所以本镜像的重点不是 gogio 这个二进制，而是 cgo 依赖齐全——Dockerfile 第 3
# 步用真实编译 + 链接来证明，冒烟测试再确认一遍依赖没在运行时被清掉。
#
# 与 GitHub 侧的差异：
#   1. 镜像名从 CNB_DOCKER_REGISTRY + CNB_REPO_SLUG_LOWERCASE 派生；
#   2. 版本解析走基座 Dockerfile 里的 GOPROXY（CNB 侧多源回退）；
#   3. 元数据写 .cnb/annotation-gio.json，并通过 ##[set-output] 输出变量；
#   4. 多一层自检：脚本被 imports 改写时立刻停下。
#
# 环境变量（cron 与按钮都由 CNB 注入 CNB_*）：
#   version          选填，Go 版本：留空 = Dockerfile 的 GO_VERSION
#   gio_version      选填，gogio CLI 版本（模块 gioui.org/cmd）：
#                    留空 / latest = 解析上游最新稳定 tag；也可填 v0.10.3 / 0.10.3
#   CACHE            on（默认）/ off（关闭层缓存并强制全量重建）
#
# 版本解析为什么要先做：层缓存按 build-arg 的值算缓存键。每天都传字符串
# latest，缓存键永远不变，go install 那一层会一直命中第一次的产物，
# gogio 再也不升级。所以构建前先在基础镜像里用 go list 把 latest 解析成 v0.10.3，
# 再以 --build-arg 传入：上游没发新版就全命中，发新版才重建那一层。
#
# 依赖：docker buildx（CNB services: docker 自带）、jq 可选（体积精确求和）。
# ===================================================================

set -eu

# ---------- 常量 ----------
# 路径写死，不从环境变量读：imports 处理曾把 ${...} 改写成带引号的字面量。
DOCKERFILE_GOLANG=".cnb/docker/Dockerfile.golang"
DOCKERFILE_GIO=".cnb/docker/Dockerfile.gio"
PLATFORMS="linux/amd64,linux/arm64"
EPOCH_DATE="1970-01-01T00:00:00Z"
MIN_IMAGE_BYTES=1048576
ANNOTATION_FILE=".cnb/annotation-gio.json"
# 基础镜像由另一条流水线产出，等待它出现在 registry（5 分钟）
BASE_WAIT_ATTEMPTS=20
BASE_WAIT_SECONDS=15
# 层缓存写到 <镜像>:buildcache，mode=min 只导出最终镜像里已有的层（单阶段构建够用）
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

# 从 Dockerfile 的 ENV 行读变量值：解析 gio 版本和构建必须走同一个 GOPROXY
# （CNB 侧基座是 Go module 多源回退，解析也要走同一份 GOPROXY，否则 proxy.golang.org 连不上）
read_env() (
  name=$1
  file=$2
  grep -E "^[[:space:]]*${name}=" "${file}" | head -n 1 \
    | sed "s/.*${name}=//" | sed 's/[[:space:]\\]*$//'
)

# 0.8.1 → v0.8.1；v0.8.1 原样返回
normalize_tag() (
  case "$1" in
    v*) printf '%s\n' "$1" ;;
    *) printf 'v%s\n' "$1" ;;
  esac
)

# 在基础镜像里解析 gogio CLI（模块 gioui.org/cmd）的最新稳定版本。
# 放在容器里跑：不依赖 runner 装了 go / curl，tag 与模块版本的对应关系也交给 go。
# 注意模块路径是 gioui.org/cmd，不是 gioui.org——后者是库，版本号各自独立演进
# （例如库到了 v0.10.3 时 cmd 可能还停在 v0.10.0），两个都要单独解析。
resolve_gio_latest() {
  set -- --rm -i --platform linux/amd64
  if [ -n "${DOCKERFILE_GOPROXY}" ]; then
    set -- "$@" -e "GOPROXY=${DOCKERFILE_GOPROXY}"
  fi
  docker run "$@" "golang:${GO_REF}" sh -s <<'RESOLVE_EOF'
set -eu
go list -m -f '{{.Version}}' gioui.org/cmd@latest
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
GIO_IMAGE="${IMAGE}/gio"
IMAGE_SOURCE="${CNB_REPO_URL_HTTPS}"

# cron 不传 version / gio_version
version="${version:-}"
gio_version="${gio_version:-}"
# CACHE=off：关闭层缓存并强制全量重建
CACHE="${CACHE:-on}"
case "${CACHE}" in
  on | off) : ;;
  *) die "CACHE 只接受 on / off，收到：${CACHE}" ;;
esac

echo "=============================="
echo "🔧 构建多架构 Golang + gio 镜像"
echo "=============================="

# ---------- 1. version 校验 ----------
case "$version" in
  '' | latest) : ;;
  *)
    printf '%s' "${version}" | grep -Eq '^[0-9]+\.[0-9]+(\.[0-9]+)?$' \
      || die "version 只接受 1.27 / 1.27.3，收到：${version}"
    ;;
esac
# gio_version 留空 / latest：解析上游最新稳定 tag；
# 也可以钉具体 tag，允许预发布后缀（v0.10.4-rc1）。
validate_gio_version() (
  case "$2" in
    '' | latest) : ;;
    *)
      printf '%s' "$2" | grep -Eq '^v?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$' \
        || die "$1 只接受版本号（如 v0.10.3 / 0.10.3 / v0.10.4-rc1），收到：$2"
      ;;
  esac
)
validate_gio_version gio_version "${gio_version}"

# ---------- 2. 基座引用 ----------
[ -f "$DOCKERFILE_GOLANG" ] \
  || die "找不到 ${DOCKERFILE_GOLANG}（当前目录 $(pwd)）：请在仓库根目录执行本脚本"
[ -f "$DOCKERFILE_GIO" ] \
  || die "找不到 ${DOCKERFILE_GIO}（当前目录 $(pwd)）：请在仓库根目录执行本脚本"
GO_VERSION="$(read_arg GO_VERSION "$DOCKERFILE_GOLANG")"
DEBIAN_VERSION="$(read_arg DEBIAN_VERSION "$DOCKERFILE_GOLANG")"
[ -n "${GO_VERSION}" ] || die "无法从 ${DOCKERFILE_GOLANG} 解析 ARG GO_VERSION"
[ -n "${DEBIAN_VERSION}" ] || die "无法从 ${DOCKERFILE_GOLANG} 解析 ARG DEBIAN_VERSION"
if [ -n "$version" ]; then
  GO_VERSION="$version"
  info "version 入参 ${version}"
fi
GO_REF="${GO_VERSION}-${DEBIAN_VERSION}"

GIO_VERSION_DEFAULT="$(read_arg GIO_VERSION "$DOCKERFILE_GIO")"
[ -n "${GIO_VERSION_DEFAULT}" ] || die "无法从 ${DOCKERFILE_GIO} 解析 ARG GIO_VERSION"

# ---------- 3. 解析实际 Go 版本 ----------
info "解析基座 golang:${GO_REF} 的实际版本"
GO_REAL="$(docker run --rm --platform linux/amd64 "golang:${GO_REF}" go version 2>/dev/null \
  | sed -n 's/^go version go\([0-9][0-9.]*\) .*/\1/p' || true)"
printf '%s' "${GO_REAL}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
  || die "无法解析 golang:${GO_REF} 的 Go 版本（得到：${GO_REAL:-空}），检查 Docker 服务与网络"
MINOR="$(printf '%s' "${GO_REAL}" | cut -d. -f1,2)"

# ---------- 3.1 解析 gogio 版本（层缓存的前提） ----------
# gioui.org/cmd（gogio CLI）与 gioui.org（库）的 tag 不保证同步；本镜像只装 cmd，
# 库由使用者在自己的项目里 go get，所以这里只解析 cmd。
DOCKERFILE_GOPROXY="$(read_env GOPROXY "$DOCKERFILE_GOLANG")"

# $1=入参值，$2=Dockerfile 默认值，$3=解析函数，$4=变量名（仅用于日志）
resolve_version() (
  _in=$1
  _default=$2
  _resolver=$3
  _label=$4
  case "${_in}" in
    '' | latest)
      # Dockerfile 默认值可能本身就是一个具体 tag（本地改过默认值时尊重它）
      if [ "${_default}" != "latest" ]; then
        normalize_tag "${_default}"
        return 0
      fi
      _got="$(${_resolver} 2>/dev/null | tr -d '[:space:]' || true)"
      if printf '%s' "${_got}" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
        info "${_label} 留空：解析到上游最新稳定版 ${_got}" >&2
        printf '%s\n' "${_got}"
        return 0
      fi
      warn "无法解析 ${_label} 最新版本（得到：${_got:-空}），回退 latest：本次由 Dockerfile 在构建时解析，层缓存不生效" >&2
      printf '%s\n' "latest"
      ;;
    *)
      _v="$(normalize_tag "${_in}")"
      info "${_label} 入参 ${_v}" >&2
      printf '%s\n' "${_v}"
      ;;
  esac
)

GIO_VERSION="$(resolve_version "${gio_version}" "${GIO_VERSION_DEFAULT}" resolve_gio_latest gio_version)"

# ---------- 4. 时间戳与标签 ----------
BUILD_DATE="$(git log -1 --format=%cI 2>/dev/null || true)"
[ -n "${BUILD_DATE}" ] || BUILD_DATE="${EPOCH_DATE}"
# 标签就是 Go 版本号，不加日期：同名标签每天重建会覆盖。
# gogio 的版本不占标签，只记录在元数据 gio_version 里。
STAMP="${GO_REAL}"
VCS_REF="${CNB_COMMIT:-unknown}"
BUILT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

info "IMAGE        ${IMAGE}"
info "GIO_IMAGE    ${GIO_IMAGE}"
info "GO_REF       golang:${GO_REF}"
info "GO_REAL      ${GO_REAL}"
info "MINOR        ${MINOR}"
info "STAMP        ${STAMP}"
info "GIO          ${GIO_VERSION}"
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

# ---------- 7. 等基础镜像就绪 ----------
# 定时任务里 build-golang 先跑（00:05），gio 后跑（18:05）；
# 手动触发时要求基础镜像已经存在。
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
  || die "基础镜像 ${IMAGE}:${STAMP} 不存在：先运行 build-golang 流水线，gio 镜像必须基于它构建"

BASE_INDEX_DIGEST="$(docker buildx imagetools inspect "${IMAGE}:${STAMP}" \
  --format '{{.Manifest.Digest}}' 2>/dev/null || true)"
[ -n "${BASE_INDEX_DIGEST}" ] || die "无法读取 ${IMAGE}:${STAMP} 的 index digest"

# ---------- 8. 构建并推送 gio 镜像 ----------
# 基础镜像 digest 没变、gogio 版本也没变时，apt / go install 两层全命中。
CACHE_REF="${GIO_IMAGE}:${CACHE_REF_SUFFIX}"
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
    -t "${GIO_IMAGE}:${STAMP}" \
    --platform "${PLATFORMS}" \
    --build-arg "GOLANG_IMAGE=${IMAGE}:${STAMP}" \
    --build-arg "GIO_VERSION=${GIO_VERSION}" \
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
  set -- "$@" --provenance=mode=min --sbom=false -f "${DOCKERFILE_GIO}" --push .
  docker buildx build "$@"
)

info "构建 ${GIO_IMAGE}:${STAMP}（${PLATFORMS}）"
if [ "${CACHE}" = "off" ]; then
  build_image off || die "gio 镜像 docker buildx build 失败（CACHE=off）"
elif ! build_image on; then
  # 有的 registry 不接受 buildx 的缓存清单，缓存导出在镜像推完之后才报错。
  warn "带缓存的构建失败：可能是 registry 不支持 buildx 缓存清单，去掉缓存重试一次"
  build_image plain || die "gio 镜像 docker buildx build 失败"
fi

# ---------- 直接挂 manifest（绕开 imagetools create 的 blob 复制） ----------
# CNB 制品库不支持把镜像清单当 blob 读，copy ... unexpected EOF 稳定复现、重试无效。
# 源与目标同仓库时把清单原文 PUT 到新 tag：层 blob 已在制品库里，不触发复制。
REG_HOST="${IMAGE%%/*}"
REPO_PATH="${GIO_IMAGE#*/}"
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

# ---------- 9. 从同一 manifest 派生单平台标签 ----------
for arch in amd64 arm64; do
  digest="$(manifest_digest_for "${GIO_IMAGE}:${STAMP}" "${arch}")"
  [ -n "${digest}" ] || die "未在 ${GIO_IMAGE}:${STAMP} 中找到 linux/${arch} 条目"
  put_manifest "${STAMP}-linux-${arch}" "${digest}" \
    || die "派生 ${STAMP}-linux-${arch} 失败（Registry API PUT）"
  info "派生 ${GIO_IMAGE}:${STAMP}-linux-${arch} ← ${digest}"
done

# ---------- 10. 冒烟测试（amd64） ----------
docker pull --platform linux/amd64 "${GIO_IMAGE}:${STAMP}" \
  || die "拉取 ${GIO_IMAGE}:${STAMP} 失败，latest 未提升"
info "冒烟测试 ${GIO_IMAGE}:${STAMP}（linux/amd64）"
if ! smoke_output="$(docker run --rm --platform linux/amd64 \
  -e EXPECT_GO="${GO_REAL}" -e EXPECT_GIO="${GIO_VERSION}" \
  "${GIO_IMAGE}:${STAMP}" sh -eu -c '
    fail=""
    got="$(go version | cut -d" " -f3 | sed "s/^go//")"
    [ "$got" = "$EXPECT_GO" ] || fail="$fail go-version($got)"
    # 基座工具链一个都不能少（这个镜像不是精简版，是 golang 基座 + gio 依赖）
    for b in go node npm pnpm sqlc golangci-lint zip unzip pkg-config gcc Xvfb gogio; do
      command -v "$b" >/dev/null 2>&1 || fail="$fail bin:$b"
    done
    # gio 的 cgo 依赖：编译期靠这些 .pc 拿 --cflags，链接期靠它们拿 --libs。
    # 装包时已经断言过一遍，这里再确认一次没被后续步骤或清理动作弄丢。
    for pc in egl glesv2 wayland-client wayland-cursor wayland-egl \
      x11 x11-xcb xkbcommon xkbcommon-x11 xcursor xfixes \
      xrandr xinerama xi xxf86vm libffi vulkan; do
      pkg-config --exists "$pc" || fail="$fail pkg:$pc"
    done
    # 运行期 gio 走 dlopen 加载这几个库：编译期装了不等于运行期能找到，
    # 两条路径都要验（ldconfig 缓存没建好时运行期才炸，比编译失败更难查）
    for lib in libEGL.so.1 libGL.so.1 libvulkan.so.1 \
      libwayland-client.so.0 libxkbcommon.so.0 libX11.so.6; do
      ldconfig -p | grep -q "$lib" || fail="$fail lib:$lib"
    done
    # gogio 的版本直接读二进制里嵌入的模块信息：gogio 没有 version 子命令
    # （无参数时只打印 usage 到 stderr 并非零退出），解析它的输出不可靠。
    # 模块路径是 gioui.org/cmd，不是 gioui.org——写成后者会永远匹配不到。
    gio_mod="$(go version -m "$(command -v gogio)" 2>/dev/null \
      | sed -n "s/^[[:space:]]*mod[[:space:]]\{1,\}gioui\.org\/cmd[[:space:]]\{1,\}\([^[:space:]]*\).*/\1/p" \
      | head -n 1)"
    if [ "$EXPECT_GIO" != "latest" ]; then
      [ "$gio_mod" = "$EXPECT_GIO" ] || fail="$fail gogio-version(${gio_mod:-空})"
    fi
    # gogio 得能跑起来（动态链接没问题）。它没有 version 子命令，无参数时
    # 打印 usage 并以非零码退出，所以判据是「有输出」而不是「退出码为 0」。
    gogio_out="$(gogio 2>&1 || true)"
    [ -n "$gogio_out" ] || fail="$fail run:gogio"
    # 这个镜像是 golang + gio：别的变体 CLI 不该出现
    for other in fnpack wails3 wails fyne mygo bun; do
      if command -v "$other" >/dev/null 2>&1; then fail="$fail $other-present"; fi
    done
    if [ -n "$fail" ]; then printf "FAIL%s" "$fail"; exit 1; fi
    printf "SMOKE_OK"
  ' 2>&1)"; then
  die "gio 镜像冒烟测试失败，latest 未提升：${smoke_output:-docker run 无输出}"
fi
case "${smoke_output}" in
  *SMOKE_OK*) : ;;
  *) die "gio 镜像冒烟测试输出异常，latest 未提升：${smoke_output}" ;;
esac

# 系统包版本：包清单从本镜像对应的 Dockerfile 自动提取（改 Dockerfile 自动跟上），
# 版本取自镜像内的 dpkg 数据库；构建期装过、最后被 purge 的包显示 absent。
apt_pkgs_from_dockerfile() (
  # Dockerfile 现在把包清单收在 apt_packages 变量里（含续行）；旧写法（包名直接
  # 跟在 apt-get install 后面）作为兜底，两种布局都能取到。
  pkgs="$(sed -n '/apt_packages="/,/";/p' "$1" \
    | sed 's/apt_packages="//; s/[";]//g; s/\\//g' \
    | tr '[:space:]' '\n' \
    | grep -E '^[a-z][a-z0-9+.-]*$' \
    | grep -vxE 'export|apt-get|install|update|rm|rf|yes|no|sh|set' | sort -u)"
  if [ -z "${pkgs}" ]; then
    pkgs="$(sed -n '/apt-get install/,/;/p' "$1" \
      | sed 's/#.*//; s/\\//g; s/;//g' | tr '[:space:]' '\n' \
      | grep -E '^[a-z][a-z0-9+.-]*$' \
      | grep -vxE 'export|apt-get|install|update|rm|rf|yes|no|sh|set' | sort -u)"
  fi
  if [ -n "${pkgs}" ]; then printf '%s\n' "${pkgs}"; fi
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
APT_VERSIONS="$(apt_versions_from_image "${GIO_IMAGE}:${STAMP}" \
  "$(apt_pkgs_from_dockerfile "${DOCKERFILE_GIO}")")"
[ -n "${APT_VERSIONS}" ] || APT_VERSIONS="unknown"

label_version="$(docker image inspect \
  --format '{{index .Config.Labels "org.opencontainers.image.version"}}' \
  "${GIO_IMAGE}:${STAMP}" 2>/dev/null || true)"
[ "${label_version}" = "${STAMP}" ] \
  || die "gio OCI label 校验失败：org.opencontainers.image.version=${label_version:-<空>}，期望 ${STAMP}"

# ---------- 11. 提升可变标签（冒烟通过、且基础镜像的移动标签已就位） ----------
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
    info "跳过 ${GIO_IMAGE}:${tag}：${IMAGE}:${tag} 尚未指向 ${STAMP}"
    continue
  fi
  put_manifest "${tag}" "${STAMP}" \
    || die "提升 ${GIO_IMAGE}:${tag} 失败（Registry API PUT）"
  info "提升 ${GIO_IMAGE}:${tag} → ${STAMP}"
done

# ---------- 12. 汇总元数据 ----------
GIO_INDEX_DIGEST="$(docker buildx imagetools inspect "${GIO_IMAGE}:${STAMP}" \
  --format '{{.Manifest.Digest}}' 2>/dev/null || true)"
GIO_DIGEST_SHORT="$(printf '%s' "${GIO_INDEX_DIGEST#sha256:}" | cut -c1-12)"
GIO_SIZE_AMD64="$(image_size_mb "${GIO_IMAGE}:${STAMP}" amd64)"
GIO_SIZE_ARM64="$(image_size_mb "${GIO_IMAGE}:${STAMP}" arm64)"

# 向 CNB Stage Result 输出变量（必须 source 才生效）
printf '##[set-output image_version=%s]\n' "${STAMP}"
printf '##[set-output gio_version=%s]\n' "${GIO_VERSION}"
printf '##[set-output golang_version=%s]\n' "${GO_REAL}"
export IMAGE_VERSION="${STAMP}"

mkdir -p .cnb
cat >"${ANNOTATION_FILE}" <<EOF
{
  "gio_image": "${GIO_IMAGE}",
  "gio_digest": "${GIO_INDEX_DIGEST:-unknown}",
  "gio_digest_short": "${GIO_DIGEST_SHORT:-unknown}",
  "gio_size": "${GIO_SIZE_AMD64}",
  "gio_size_arm64": "${GIO_SIZE_ARM64}",
  "gio_version": "${GIO_VERSION}",
  "image_version": "${STAMP}",
  "golang_version": "${GO_REAL}",
  "gio_base_image": "${IMAGE}:${STAMP}",
  "gio_base_digest": "${BASE_INDEX_DIGEST}",
  "apt_versions": "${APT_VERSIONS}",
  "built_at": "${BUILT_AT}",
  "source_date": "${BUILD_DATE}"
}
EOF

info "gio   digest ${GIO_INDEX_DIGEST:-unknown}"
info "gio   size   amd64 ${GIO_SIZE_AMD64} / arm64 ${GIO_SIZE_ARM64}"
info "base  digest ${BASE_INDEX_DIGEST}"
info "元数据         ${ANNOTATION_FILE}"

echo "=============================="
echo "🎉 构建完成 ${GIO_IMAGE}:${STAMP}（gogio ${GIO_VERSION}）"
echo "=============================="
