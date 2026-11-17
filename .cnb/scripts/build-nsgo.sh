#!/bin/sh
# ===================================================================
# CNB 专用（build-nsgo 流水线）：多架构（linux/amd64 + linux/arm64）
# 构建并推送 nsgo 镜像：
#
#   <registry>/<repo>/nsgo  → golang + GTK4/WebKitGTK 6.0/Pango/Cairo/
#                            GStreamer 运行与开发包 + 无头运行库 + nsgo CLI
#
# 本脚本不构建基础镜像：它要求 <registry>/<repo>:<go 版本> 已由 build-golang
# 流水线推好，直接 FROM 那个 manifest list，只追加 nsgo 的运行依赖、无头运行库与
# nsgo CLI。定时任务排在 gio 之后 1 小时（09:05），比基座 00:05 晚九小时。
#
# CNB 侧独立实现，与 .github/scripts/build-nsgo.sh 各自维护、不互相引用。
# 标签规则、冒烟断言与 GitHub 侧保持一致。
#
# nsgo 在 Linux 上走 GTK4 后端，用 purego 在运行期 dlopen 系统库，不需要 cgo；
# 镜像的重点是 GTK4 / WebKitGTK 6.0 / GStreamer 这套运行库齐全，Dockerfile 用
# pkg-config + ldconfig + gst-inspect 断言，冒烟测试再确认一遍没被清掉。
# 上游旧地址 github.com/oneo-me/nsgo 会重定向到 github.com/nsgo-dev/nsgo，
# Go 模块路径用后者。
#
# 与 GitHub 侧的差异：
#   1. 镜像名从 CNB_DOCKER_REGISTRY + CNB_REPO_SLUG_LOWERCASE 派生；
#   2. 版本解析走基座 Dockerfile 里的 GOPROXY（CNB 侧多源回退）；
#   3. 元数据写 .cnb/annotation-nsgo.json，并通过 ##[set-output] 输出变量；
#   4. 多一层自检：脚本被 imports 改写时立刻停下。
#
# 环境变量（cron 与按钮都由 CNB 注入 CNB_*）：
#   version          选填，Go 版本：留空 = Dockerfile 的 GO_VERSION
#   nsgo_version     选填，nsgo CLI 版本（模块 github.com/nsgo-dev/nsgo）：
#                    留空 / latest = 解析上游最新版本；也可填 v0.1.0 / 0.1.0 /
#                    伪版本 v0.0.0-20251115000000-abcdef123456
#   CACHE            on（默认）/ off（关闭层缓存并强制全量重建）
#
# 版本解析为什么要先做：层缓存按 build-arg 的值算缓存键。每天都传字符串
# latest，缓存键永远不变，go install 那一层会一直命中第一次的产物，
# nsgo 再也不升级。所以构建前先在基础镜像里用 go list 把 latest 解析成具体版本，
# 再以 --build-arg 传入：上游没发新版就全命中，发新版才重建那一层。
# 上游目前没有发 tag，go list 会给出伪版本；解析不到时回退 latest，交给
# Dockerfile 在构建时解析（镜像仍可用，只是层缓存与元数据版本不精确）。
#
# 依赖：docker buildx（CNB services: docker 自带）、jq 可选（体积精确求和）。
# ===================================================================

set -eu

# ---------- 常量 ----------
# 路径写死，不从环境变量读：imports 处理曾把 ${...} 改写成带引号的字面量。
DOCKERFILE_GOLANG=".cnb/docker/Dockerfile.golang"
DOCKERFILE_NSGO=".cnb/docker/Dockerfile.nsgo"
PLATFORMS="linux/amd64,linux/arm64"
EPOCH_DATE="1970-01-01T00:00:00Z"
MIN_IMAGE_BYTES=1048576
ANNOTATION_FILE=".cnb/annotation-nsgo.json"
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

# 从 Dockerfile 的 ENV 行读变量值：解析 nsgo 版本和构建必须走同一个 GOPROXY
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

# 在基础镜像里解析 nsgo（模块 github.com/nsgo-dev/nsgo）的最新版本。
# 放在容器里跑：不依赖 runner 装了 go / curl，tag 与模块版本的对应关系也交给 go。
# 上游没有发 tag 时 go list 给出伪版本，同样接受。
resolve_nsgo_latest() {
  set -- --rm -i --platform linux/amd64
  if [ -n "${DOCKERFILE_GOPROXY}" ]; then
    set -- "$@" -e "GOPROXY=${DOCKERFILE_GOPROXY}"
  fi
  docker run "$@" "golang:${GO_REF}" sh -s <<'RESOLVE_EOF'
set -eu
go list -m -f '{{.Version}}' github.com/nsgo-dev/nsgo@latest
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
NSGO_IMAGE="${IMAGE}/nsgo"
IMAGE_SOURCE="${CNB_REPO_URL_HTTPS}"

# cron 不传 version / nsgo_version
version="${version:-}"
nsgo_version="${nsgo_version:-}"
# CACHE=off：关闭层缓存并强制全量重建
CACHE="${CACHE:-on}"
case "${CACHE}" in
  on | off) : ;;
  *) die "CACHE 只接受 on / off，收到：${CACHE}" ;;
esac

echo "=============================="
echo "🔧 构建多架构 Golang + nsgo 镜像"
echo "=============================="

# ---------- 1. version 校验 ----------
case "$version" in
  '' | latest) : ;;
  *)
    printf '%s' "${version}" | grep -Eq '^[0-9]+\.[0-9]+(\.[0-9]+)?$' \
      || die "version 只接受 1.27 / 1.27.3，收到：${version}"
    ;;
esac
# nsgo_version 留空 / latest：解析上游最新版本；
# 也可以钉具体 tag 或伪版本（上游还没发 tag），允许预发布后缀（v0.10.4-rc1）。
validate_nsgo_version() (
  case "$2" in
    '' | latest) : ;;
    *)
      printf '%s' "$2" | grep -Eq '^v?[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.+-]+)?$' \
        || die "$1 只接受版本号（如 v0.1.0 / 0.1.0 / v0.2.0-rc1 / v0.0.0-20251115000000-abcdef123456），收到：$2"
      ;;
  esac
)
validate_nsgo_version nsgo_version "${nsgo_version}"

# ---------- 2. 基座引用 ----------
[ -f "$DOCKERFILE_GOLANG" ] \
  || die "找不到 ${DOCKERFILE_GOLANG}（当前目录 $(pwd)）：请在仓库根目录执行本脚本"
[ -f "$DOCKERFILE_NSGO" ] \
  || die "找不到 ${DOCKERFILE_NSGO}（当前目录 $(pwd)）：请在仓库根目录执行本脚本"
GO_VERSION="$(read_arg GO_VERSION "$DOCKERFILE_GOLANG")"
DEBIAN_VERSION="$(read_arg DEBIAN_VERSION "$DOCKERFILE_GOLANG")"
[ -n "${GO_VERSION}" ] || die "无法从 ${DOCKERFILE_GOLANG} 解析 ARG GO_VERSION"
[ -n "${DEBIAN_VERSION}" ] || die "无法从 ${DOCKERFILE_GOLANG} 解析 ARG DEBIAN_VERSION"
if [ -n "$version" ]; then
  GO_VERSION="$version"
  info "version 入参 ${version}"
fi
GO_REF="${GO_VERSION}-${DEBIAN_VERSION}"

NSGO_VERSION_DEFAULT="$(read_arg NSGO_VERSION "$DOCKERFILE_NSGO")"
[ -n "${NSGO_VERSION_DEFAULT}" ] || die "无法从 ${DOCKERFILE_NSGO} 解析 ARG NSGO_VERSION"

# ---------- 3. 解析实际 Go 版本 ----------
info "解析基座 golang:${GO_REF} 的实际版本"
GO_REAL="$(docker run --rm --platform linux/amd64 "golang:${GO_REF}" go version 2>/dev/null \
  | sed -n 's/^go version go\([0-9][0-9.]*\) .*/\1/p' || true)"
printf '%s' "${GO_REAL}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
  || die "无法解析 golang:${GO_REF} 的 Go 版本（得到：${GO_REAL:-空}），检查 Docker 服务与网络"
MINOR="$(printf '%s' "${GO_REAL}" | cut -d. -f1,2)"

# ---------- 3.1 解析 nsgo 版本（层缓存的前提） ----------
# 解析 github.com/nsgo-dev/nsgo@latest（上游没发 tag 时得到伪版本），
# 用与 Dockerfile 相同的 GOPROXY 再 go install，保证解析与安装一致。
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
      if printf '%s' "${_got}" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.+-]+)?$'; then
        info "${_label} 留空：解析到上游最新版本 ${_got}" >&2
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

NSGO_VERSION="$(resolve_version "${nsgo_version}" "${NSGO_VERSION_DEFAULT}" resolve_nsgo_latest nsgo_version)"

# ---------- 4. 时间戳与标签 ----------
BUILD_DATE="$(git log -1 --format=%cI 2>/dev/null || true)"
[ -n "${BUILD_DATE}" ] || BUILD_DATE="${EPOCH_DATE}"
# 标签就是 Go 版本号，不加日期：同名标签每天重建会覆盖。
# nsgo 的版本不占标签，只记录在元数据 nsgo_version 里。
STAMP="${GO_REAL}"
VCS_REF="${CNB_COMMIT:-unknown}"
BUILT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

info "IMAGE        ${IMAGE}"
info "NSGO_IMAGE    ${NSGO_IMAGE}"
info "GO_REF       golang:${GO_REF}"
info "GO_REAL      ${GO_REAL}"
info "MINOR        ${MINOR}"
info "STAMP        ${STAMP}"
info "NSGO          ${NSGO_VERSION}"
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
# 定时任务里 build-golang 先跑（00:05），nsgo 后跑（09:05）；
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
  || die "基础镜像 ${IMAGE}:${STAMP} 不存在：先运行 build-golang 流水线，nsgo 镜像必须基于它构建"

BASE_INDEX_DIGEST="$(docker buildx imagetools inspect "${IMAGE}:${STAMP}" \
  --format '{{.Manifest.Digest}}' 2>/dev/null || true)"
[ -n "${BASE_INDEX_DIGEST}" ] || die "无法读取 ${IMAGE}:${STAMP} 的 index digest"

# ---------- 8. 构建并推送 nsgo 镜像 ----------
# 基础镜像 digest 没变、nsgo 版本也没变时，apt / go install 两层全命中。
CACHE_REF="${NSGO_IMAGE}:${CACHE_REF_SUFFIX}"
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
    -t "${NSGO_IMAGE}:${STAMP}" \
    --platform "${PLATFORMS}" \
    --build-arg "GOLANG_IMAGE=${IMAGE}:${STAMP}" \
    --build-arg "NSGO_VERSION=${NSGO_VERSION}" \
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
  set -- "$@" --provenance=mode=min --sbom=false -f "${DOCKERFILE_NSGO}" --push .
  docker buildx build "$@"
)

info "构建 ${NSGO_IMAGE}:${STAMP}（${PLATFORMS}）"
if [ "${CACHE}" = "off" ]; then
  build_image off || die "nsgo 镜像 docker buildx build 失败（CACHE=off）"
elif ! build_image on; then
  # 有的 registry 不接受 buildx 的缓存清单，缓存导出在镜像推完之后才报错。
  warn "带缓存的构建失败：可能是 registry 不支持 buildx 缓存清单，去掉缓存重试一次"
  build_image plain || die "nsgo 镜像 docker buildx build 失败"
fi

# ---------- 直接挂 manifest（绕开 imagetools create 的 blob 复制） ----------
# CNB 制品库不支持把镜像清单当 blob 读，copy ... unexpected EOF 稳定复现、重试无效。
# 源与目标同仓库时把清单原文 PUT 到新 tag：层 blob 已在制品库里，不触发复制。
REG_HOST="${IMAGE%%/*}"
REPO_PATH="${NSGO_IMAGE#*/}"
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
  digest="$(manifest_digest_for "${NSGO_IMAGE}:${STAMP}" "${arch}")"
  [ -n "${digest}" ] || die "未在 ${NSGO_IMAGE}:${STAMP} 中找到 linux/${arch} 条目"
  put_manifest "${STAMP}-linux-${arch}" "${digest}" \
    || die "派生 ${STAMP}-linux-${arch} 失败（Registry API PUT）"
  info "派生 ${NSGO_IMAGE}:${STAMP}-linux-${arch} ← ${digest}"
done

# ---------- 10. 冒烟测试（amd64） ----------
docker pull --platform linux/amd64 "${NSGO_IMAGE}:${STAMP}" \
  || die "拉取 ${NSGO_IMAGE}:${STAMP} 失败，latest 未提升"
info "冒烟测试 ${NSGO_IMAGE}:${STAMP}（linux/amd64）"
if ! smoke_output="$(docker run --rm --platform linux/amd64 \
  -e EXPECT_GO="${GO_REAL}" -e EXPECT_NSGO="${NSGO_VERSION}" \
  "${NSGO_IMAGE}:${STAMP}" sh -eu -c '
    fail=""
    got="$(go version | cut -d" " -f3 | sed "s/^go//")"
    [ "$got" = "$EXPECT_GO" ] || fail="$fail go-version($got)"
    # 基座工具链一个都不能少（这个镜像不是精简版，是 golang 基座 + nsgo 依赖）
    for b in go node npm pnpm sqlc golangci-lint zip unzip pkg-config gcc Xvfb \
      gst-inspect-1.0 nsgo; do
      command -v "$b" >/dev/null 2>&1 || fail="$fail bin:$b"
    done
    # nsgo 的 GTK4 / WebKitGTK 6.0 / GStreamer 运行依赖：这些 .pc 同时是使用者
    # 写 cgo 绑定时要用的编译依赖。装包时已经断言过一遍，这里再确认没被弄丢。
    for pc in gtk4 webkitgtk-6.0 glib-2.0 gobject-2.0 gio-2.0 \
      pango pangocairo cairo cairo-gobject fontconfig gdk-pixbuf-2.0 \
      gstreamer-1.0 gstreamer-app-1.0 gstreamer-video-1.0; do
      pkg-config --exists "$pc" || fail="$fail pkg:$pc"
    done
    # 运行期 nsgo 走 dlopen 加载这几个库：编译期装了不等于运行期能找到，
    # 两条路径都要验（ldconfig 缓存没建好时运行期才炸，比编译失败更难查）
    for lib in libgtk-4.so.1 libwebkitgtk-6.0.so.4 \
      libglib-2.0.so.0 libgobject-2.0.so.0 libgio-2.0.so.0 \
      libpango-1.0.so.0 libpangocairo-1.0.so.0 libcairo.so.2 \
      libfontconfig.so.1 libgdk_pixbuf-2.0.so.0 \
      libgstreamer-1.0.so.0 libgstapp-1.0.so.0 libgstvideo-1.0.so.0; do
      ldconfig -p | grep -q "$lib" || fail="$fail lib:$lib"
    done
    # 视频解码要真的可用：H.264 / AAC 靠 libav 插件，光有 libgstreamer 不够
    gst-inspect-1.0 avdec_h264 >/dev/null 2>&1 || fail="$fail gst:avdec_h264"
    gst-inspect-1.0 avdec_aac >/dev/null 2>&1 || fail="$fail gst:avdec_aac"
    # nsgo 的版本直接读二进制里嵌入的模块信息（模块路径 github.com/nsgo-dev/nsgo）。
    # 上游没有发 tag 时解析到的是伪版本，这里按解析结果精确比对。
    nsgo_mod="$(go version -m "$(command -v nsgo)" 2>/dev/null \
      | sed -n "s/^[[:space:]]*mod[[:space:]]\{1,\}github\.com\/nsgo-dev\/nsgo[[:space:]]\{1,\}\([^[:space:]]*\).*/\1/p" \
      | head -n 1)"
    if [ "$EXPECT_NSGO" != "latest" ]; then
      [ "$nsgo_mod" = "$EXPECT_NSGO" ] || fail="$fail nsgo-version(${nsgo_mod:-空})"
    fi
    # nsgo 得能跑起来（动态链接没问题）；判据是「--help 有输出」。
    nsgo_out="$(nsgo --help 2>&1 || true)"
    [ -n "$nsgo_out" ] || fail="$fail run:nsgo"
    # 这个镜像是 golang + nsgo：别的变体 CLI 不该出现
    for other in fnpack wails3 wails fyne mygo bun gogio viva asuka; do
      if command -v "$other" >/dev/null 2>&1; then fail="$fail $other-present"; fi
    done
    if [ -n "$fail" ]; then printf "FAIL%s" "$fail"; exit 1; fi
    printf "SMOKE_OK"
  ' 2>&1)"; then
  die "nsgo 镜像冒烟测试失败，latest 未提升：${smoke_output:-docker run 无输出}"
fi
case "${smoke_output}" in
  *SMOKE_OK*) : ;;
  *) die "nsgo 镜像冒烟测试输出异常，latest 未提升：${smoke_output}" ;;
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
APT_VERSIONS="$(apt_versions_from_image "${NSGO_IMAGE}:${STAMP}" \
  "$(apt_pkgs_from_dockerfile "${DOCKERFILE_NSGO}")")"
[ -n "${APT_VERSIONS}" ] || APT_VERSIONS="unknown"

label_version="$(docker image inspect \
  --format '{{index .Config.Labels "org.opencontainers.image.version"}}' \
  "${NSGO_IMAGE}:${STAMP}" 2>/dev/null || true)"
[ "${label_version}" = "${STAMP}" ] \
  || die "nsgo OCI label 校验失败：org.opencontainers.image.version=${label_version:-<空>}，期望 ${STAMP}"

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
    info "跳过 ${NSGO_IMAGE}:${tag}：${IMAGE}:${tag} 尚未指向 ${STAMP}"
    continue
  fi
  put_manifest "${tag}" "${STAMP}" \
    || die "提升 ${NSGO_IMAGE}:${tag} 失败（Registry API PUT）"
  info "提升 ${NSGO_IMAGE}:${tag} → ${STAMP}"
done

# ---------- 12. 汇总元数据 ----------
NSGO_INDEX_DIGEST="$(docker buildx imagetools inspect "${NSGO_IMAGE}:${STAMP}" \
  --format '{{.Manifest.Digest}}' 2>/dev/null || true)"
NSGO_DIGEST_SHORT="$(printf '%s' "${NSGO_INDEX_DIGEST#sha256:}" | cut -c1-12)"
NSGO_SIZE_AMD64="$(image_size_mb "${NSGO_IMAGE}:${STAMP}" amd64)"
NSGO_SIZE_ARM64="$(image_size_mb "${NSGO_IMAGE}:${STAMP}" arm64)"

# 向 CNB Stage Result 输出变量（必须 source 才生效）
printf '##[set-output image_version=%s]\n' "${STAMP}"
printf '##[set-output nsgo_version=%s]\n' "${NSGO_VERSION}"
printf '##[set-output golang_version=%s]\n' "${GO_REAL}"
export IMAGE_VERSION="${STAMP}"

mkdir -p .cnb
cat >"${ANNOTATION_FILE}" <<EOF
{
  "nsgo_image": "${NSGO_IMAGE}",
  "nsgo_digest": "${NSGO_INDEX_DIGEST:-unknown}",
  "nsgo_digest_short": "${NSGO_DIGEST_SHORT:-unknown}",
  "nsgo_size": "${NSGO_SIZE_AMD64}",
  "nsgo_size_arm64": "${NSGO_SIZE_ARM64}",
  "nsgo_version": "${NSGO_VERSION}",
  "image_version": "${STAMP}",
  "golang_version": "${GO_REAL}",
  "nsgo_base_image": "${IMAGE}:${STAMP}",
  "nsgo_base_digest": "${BASE_INDEX_DIGEST}",
  "apt_versions": "${APT_VERSIONS}",
  "built_at": "${BUILT_AT}",
  "source_date": "${BUILD_DATE}"
}
EOF

info "nsgo   digest ${NSGO_INDEX_DIGEST:-unknown}"
info "nsgo   size   amd64 ${NSGO_SIZE_AMD64} / arm64 ${NSGO_SIZE_ARM64}"
info "base  digest ${BASE_INDEX_DIGEST}"
info "元数据         ${ANNOTATION_FILE}"

echo "=============================="
echo "🎉 构建完成 ${NSGO_IMAGE}:${STAMP}（nsgo ${NSGO_VERSION}）"
echo "=============================="
