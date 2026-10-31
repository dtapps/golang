#!/bin/sh
# ===================================================================
# CNB 专用（build-fnpack 流水线）：多架构（linux/amd64 + linux/arm64）
# 构建并推送 fnpack 镜像：
#
#   <registry>/<repo>/fnpack  → golang + fnpack
#
# 本脚本不构建基础镜像：它要求 <registry>/<repo>:<go 版本> 已由 build-golang
# 流水线推好，直接 FROM 那个 manifest list，只追加一个 fnpack 二进制。
# 定时任务给 build-golang 留了三小时（00:05 → 03:05），正常情况下基础镜像已就绪。
#
# CNB 侧独立实现，与 .github/scripts/build-fnpack.sh 各自维护、不互相引用。
# 标签规则、冒烟断言与 GitHub 侧保持一致。
#
# 与 GitHub 侧的差异：
#   1. 镜像名从 CNB_DOCKER_REGISTRY + CNB_REPO_SLUG_LOWERCASE 派生；
#   2. 元数据写 .cnb/annotation-fnpack.json，并通过 ##[set-output] 输出变量；
#   3. 多一层自检：脚本被 imports 改写时立刻停下。
#
# fnpack 从 https://static2.fnnas.com 下载，不经过 GitHub Release，
# 因此不需要 GITHUB_MIRROR / NODE_MIRROR，也不走 DaoCloud 镜像。
#
# 依赖：docker buildx（CNB services: docker 自带）、jq 可选（体积精确求和）。
# ===================================================================

set -eu

# ---------- 常量 ----------
# 路径写死，不从环境变量读：imports 处理曾把 ${...} 改写成带引号的字面量。
DOCKERFILE_GOLANG=".cnb/docker/Dockerfile.golang"
DOCKERFILE_FNPACK=".cnb/docker/Dockerfile.fnpack"
PLATFORMS="linux/amd64,linux/arm64"
EPOCH_DATE="1970-01-01T00:00:00Z"
MIN_IMAGE_BYTES=1048576
ANNOTATION_FILE=".cnb/annotation-fnpack.json"
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
FNPACK_IMAGE="${IMAGE}/fnpack"
IMAGE_SOURCE="${CNB_REPO_URL_HTTPS}"

# cron 不传 version / fnpack_version
version="${version:-}"
fnpack_version="${fnpack_version:-}"
# CACHE=off：关闭层缓存并强制全量重建
CACHE="${CACHE:-on}"
case "${CACHE}" in
  on | off) : ;;
  *) die "CACHE 只接受 on / off，收到：${CACHE}" ;;
esac

echo "=============================="
echo "🔧 构建多架构 Golang + fnpack 镜像"
echo "=============================="

# ---------- 1. version 校验 ----------
case "$version" in
  '' | latest) : ;;
  *)
    printf '%s' "${version}" | grep -Eq '^[0-9]+\.[0-9]+(\.[0-9]+)?$' \
      || die "version 只接受 1.27 / 1.27.3，收到：${version}"
    ;;
esac
# fnpack_version 留空 / latest：使用 Dockerfile 的默认值（当前 1.2.3），
# 因为上游 static2.fnnas.com 没有可查询 latest 的接口，暂时把它当作最新版本。
case "$fnpack_version" in
  '' | latest) : ;;
  *)
    printf '%s' "${fnpack_version}" | grep -Eq '^[0-9]+(\.[0-9]+)+$' \
      || die "fnpack_version 只接受版本号（如 1.2.3），收到：${fnpack_version}"
    ;;
esac

# ---------- 2. 基座引用 ----------
[ -f "$DOCKERFILE_GOLANG" ] \
  || die "找不到 ${DOCKERFILE_GOLANG}（当前目录 $(pwd)）：请在仓库根目录执行本脚本"
[ -f "$DOCKERFILE_FNPACK" ] \
  || die "找不到 ${DOCKERFILE_FNPACK}（当前目录 $(pwd)）：请在仓库根目录执行本脚本"
GO_VERSION="$(read_arg GO_VERSION "$DOCKERFILE_GOLANG")"
DEBIAN_VERSION="$(read_arg DEBIAN_VERSION "$DOCKERFILE_GOLANG")"
[ -n "${GO_VERSION}" ] || die "无法从 ${DOCKERFILE_GOLANG} 解析 ARG GO_VERSION"
[ -n "${DEBIAN_VERSION}" ] || die "无法从 ${DOCKERFILE_GOLANG} 解析 ARG DEBIAN_VERSION"
if [ -n "$version" ]; then
  GO_VERSION="$version"
  info "version 入参 ${version}"
fi
GO_REF="${GO_VERSION}-${DEBIAN_VERSION}"

FNPACK_VERSION_DEFAULT="$(read_arg FNPACK_VERSION "$DOCKERFILE_FNPACK")"
[ -n "${FNPACK_VERSION_DEFAULT}" ] || die "无法从 ${DOCKERFILE_FNPACK} 解析 ARG FNPACK_VERSION"
case "${fnpack_version}" in
  '' | latest)
    FNPACK_VERSION="${FNPACK_VERSION_DEFAULT}"
    info "fnpack_version 留空：使用 Dockerfile 默认 ${FNPACK_VERSION}（暂作为最新版本）"
    ;;
  *)
    FNPACK_VERSION="${fnpack_version}"
    info "fnpack_version 入参 ${fnpack_version}"
    ;;
esac

# ---------- 3. 解析实际 Go 版本 ----------
info "解析基座 golang:${GO_REF} 的实际版本"
GO_REAL="$(docker run --rm --platform linux/amd64 "golang:${GO_REF}" go version 2>/dev/null \
  | sed -n 's/^go version go\([0-9][0-9.]*\) .*/\1/p' || true)"
printf '%s' "${GO_REAL}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
  || die "无法解析 golang:${GO_REF} 的 Go 版本（得到：${GO_REAL:-空}），检查 Docker 服务与网络"
MINOR="$(printf '%s' "${GO_REAL}" | cut -d. -f1,2)"

# ---------- 4. 时间戳与标签 ----------
BUILD_DATE="$(git log -1 --format=%cI 2>/dev/null || true)"
[ -n "${BUILD_DATE}" ] || BUILD_DATE="${EPOCH_DATE}"
STAMP="${GO_REAL}"
VCS_REF="${CNB_COMMIT:-unknown}"
BUILT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

info "IMAGE          ${IMAGE}"
info "FNPACK_IMAGE   ${FNPACK_IMAGE}"
info "GO_REF         golang:${GO_REF}"
info "GO_REAL        ${GO_REAL}"
info "MINOR          ${MINOR}"
info "STAMP          ${STAMP}"
info "FNPACK         ${FNPACK_VERSION}"
info "SOURCE         ${IMAGE_SOURCE}"
info "BUILD_DATE     ${BUILD_DATE}"
info "VCS_REF        ${VCS_REF}"

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
# 定时任务里 build-golang 先跑（00:05），fnpack 后跑（03:05）；
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
  || die "基础镜像 ${IMAGE}:${STAMP} 不存在：先运行 build-golang 流水线，fnpack 镜像必须基于它构建"

BASE_INDEX_DIGEST="$(docker buildx imagetools inspect "${IMAGE}:${STAMP}" \
  --format '{{.Manifest.Digest}}' 2>/dev/null || true)"
[ -n "${BASE_INDEX_DIGEST}" ] || die "无法读取 ${IMAGE}:${STAMP} 的 index digest"

# ---------- 8. 构建并推送 fnpack 镜像 ----------
# 基础镜像 digest 没变时（golang 镜像当天全命中），这一层也全命中，构建接近瞬时。
CACHE_REF="${FNPACK_IMAGE}:${CACHE_REF_SUFFIX}"
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
    -t "${FNPACK_IMAGE}:${STAMP}" \
    --platform "${PLATFORMS}" \
    --build-arg "GOLANG_IMAGE=${IMAGE}:${STAMP}" \
    --build-arg "FNPACK_VERSION=${FNPACK_VERSION}" \
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
  set -- "$@" --provenance=mode=min --sbom=false -f "${DOCKERFILE_FNPACK}" --push .
  docker buildx build "$@"
)

info "构建 ${FNPACK_IMAGE}:${STAMP}（${PLATFORMS}）"
if [ "${CACHE}" = "off" ]; then
  build_image off || die "fnpack 镜像 docker buildx build 失败（CACHE=off）"
elif ! build_image on; then
  # 有的 registry 不接受 buildx 的缓存清单，缓存导出在镜像推完之后才报错。
  warn "带缓存的构建失败：可能是 registry 不支持 buildx 缓存清单，去掉缓存重试一次"
  build_image plain || die "fnpack 镜像 docker buildx build 失败"
fi

# ---------- 9. 从同一 manifest 派生单平台标签 ----------
for arch in amd64 arm64; do
  digest="$(manifest_digest_for "${FNPACK_IMAGE}:${STAMP}" "${arch}")"
  [ -n "${digest}" ] || die "未在 ${FNPACK_IMAGE}:${STAMP} 中找到 linux/${arch} 条目"
  docker buildx imagetools create -t "${FNPACK_IMAGE}:${STAMP}-linux-${arch}" \
    "${FNPACK_IMAGE}@${digest}" \
    || die "派生 ${STAMP}-linux-${arch} 失败"
  info "派生 ${FNPACK_IMAGE}:${STAMP}-linux-${arch} ← ${digest}"
done

# ---------- 10. 冒烟测试（amd64） ----------
docker pull --platform linux/amd64 "${FNPACK_IMAGE}:${STAMP}" \
  || die "拉取 ${FNPACK_IMAGE}:${STAMP} 失败，latest 未提升"
info "冒烟测试 ${FNPACK_IMAGE}:${STAMP}（linux/amd64）"
if ! smoke_output="$(docker run --rm --platform linux/amd64 \
  -e EXPECT_GO="${GO_REAL}" "${FNPACK_IMAGE}:${STAMP}" sh -eu -c '
    fail=""
    got="$(go version | cut -d" " -f3 | sed "s/^go//")"
    [ "$got" = "$EXPECT_GO" ] || fail="$fail go-version($got)"
    command -v fnpack >/dev/null 2>&1 || fail="$fail bin:fnpack"
    [ -x /usr/local/bin/fnpack ] || fail="$fail exec:fnpack"
    for b in go node pnpm sqlc golangci-lint; do
      command -v "$b" >/dev/null 2>&1 || fail="$fail bin:$b"
    done
    if [ -n "$fail" ]; then printf "FAIL%s" "$fail"; exit 1; fi
    printf "SMOKE_OK"
  ' 2>&1)"; then
  die "fnpack 镜像冒烟测试失败，latest 未提升：${smoke_output:-docker run 无输出}"
fi
case "${smoke_output}" in
  *SMOKE_OK*) : ;;
  *) die "fnpack 镜像冒烟测试输出异常，latest 未提升：${smoke_output}" ;;
esac

label_version="$(docker image inspect \
  --format '{{index .Config.Labels "org.opencontainers.image.version"}}' \
  "${FNPACK_IMAGE}:${STAMP}" 2>/dev/null || true)"
[ "${label_version}" = "${STAMP}" ] \
  || die "fnpack OCI label 校验失败：org.opencontainers.image.version=${label_version:-<空>}，期望 ${STAMP}"

# ---------- 11. 提升可变标签（冒烟通过、且基础镜像的移动标签已就位） ----------
for tag in "${MINOR}" latest; do
  base_tag_digest="$(docker buildx imagetools inspect "${IMAGE}:${tag}" \
    --format '{{.Manifest.Digest}}' 2>/dev/null || true)"
  if [ "${base_tag_digest}" != "${BASE_INDEX_DIGEST}" ]; then
    info "跳过 ${FNPACK_IMAGE}:${tag}：${IMAGE}:${tag} 尚未指向 ${STAMP}"
    continue
  fi
  docker buildx imagetools create -t "${FNPACK_IMAGE}:${tag}" "${FNPACK_IMAGE}:${STAMP}" \
    || die "提升 ${FNPACK_IMAGE}:${tag} 失败"
  info "提升 ${FNPACK_IMAGE}:${tag} → ${STAMP}"
done

# ---------- 12. 汇总元数据 ----------
FNPACK_INDEX_DIGEST="$(docker buildx imagetools inspect "${FNPACK_IMAGE}:${STAMP}" \
  --format '{{.Manifest.Digest}}' 2>/dev/null || true)"
FNPACK_DIGEST_SHORT="$(printf '%s' "${FNPACK_INDEX_DIGEST#sha256:}" | cut -c1-12)"
FNPACK_SIZE_AMD64="$(image_size_mb "${FNPACK_IMAGE}:${STAMP}" amd64)"
FNPACK_SIZE_ARM64="$(image_size_mb "${FNPACK_IMAGE}:${STAMP}" arm64)"

# 向 CNB Stage Result 输出变量（必须 source 才生效）
printf '##[set-output image_version=%s]\n' "${STAMP}"
printf '##[set-output fnpack_version=%s]\n' "${FNPACK_VERSION}"
printf '##[set-output golang_version=%s]\n' "${GO_REAL}"
export IMAGE_VERSION="${STAMP}"

mkdir -p .cnb
cat >"${ANNOTATION_FILE}" <<EOF
{
  "fnpack_image": "${FNPACK_IMAGE}",
  "fnpack_digest": "${FNPACK_INDEX_DIGEST:-unknown}",
  "fnpack_digest_short": "${FNPACK_DIGEST_SHORT:-unknown}",
  "fnpack_size": "${FNPACK_SIZE_AMD64}",
  "fnpack_size_arm64": "${FNPACK_SIZE_ARM64}",
  "fnpack_version": "${FNPACK_VERSION}",
  "image_version": "${STAMP}",
  "golang_version": "${GO_REAL}",
  "fnpack_base_image": "${IMAGE}:${STAMP}",
  "fnpack_base_digest": "${BASE_INDEX_DIGEST}",
  "built_at": "${BUILT_AT}",
  "source_date": "${BUILD_DATE}"
}
EOF

info "fnpack  digest ${FNPACK_INDEX_DIGEST:-unknown}"
info "fnpack  size   amd64 ${FNPACK_SIZE_AMD64} / arm64 ${FNPACK_SIZE_ARM64}"
info "base    digest ${BASE_INDEX_DIGEST}"
info "元数据         ${ANNOTATION_FILE}"

echo "=============================="
echo "🎉 构建完成 ${FNPACK_IMAGE}:${STAMP}"
echo "=============================="
