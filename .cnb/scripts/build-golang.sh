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
# 这是 .github/scripts/build-golang.sh 的 CNB 侧副本，有意复制、不互相引用。
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
#   1. 基座跟随上游：Dockerfile 的 GO_VERSION 默认 1.27.3，手动触发可以钉版本；
#      实际 Go 版本由脚本解析后写进标签与 OCI label。
#   2. 先推 <go 版本>，冒烟通过后才提升 latest / <minor>。
#   3. 必须 source 执行：##[set-output] 与 export 只在当前 shell 生效。
#   4. 不启用 registry cache：每日 cron 要真的重新拉取上游与安装依赖。
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

# ---------- 输出助手 ----------
info() { printf '  %s\n' "$*"; }
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
IMAGE_SOURCE="${CNB_REPO_URL_HTTPS}"

# cron 不传 version
version="${version:-}"

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
info "构建 ${IMAGE}:${STAMP}（${PLATFORMS}）"
docker buildx build \
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
  --build-arg "BASE_DIGEST=${BASE_DIGEST}" \
  --provenance=mode=min \
  --sbom=false \
  -f "${DOCKERFILE_GOLANG}" \
  --push . \
  || die "golang 镜像 docker buildx build 失败"

GOLANG_INDEX_DIGEST="$(docker buildx imagetools inspect "${IMAGE}:${STAMP}" \
  --format '{{.Manifest.Digest}}' 2>/dev/null || true)"
[ -n "${GOLANG_INDEX_DIGEST}" ] || die "无法读取 ${IMAGE}:${STAMP} 的 index digest"

# ---------- 8. 从同一 manifest 派生单平台标签 ----------
derive_arch_tags() {
  img=$1
  for arch in amd64 arm64; do
    digest="$(manifest_digest_for "${img}:${STAMP}" "${arch}")"
    [ -n "${digest}" ] || die "未在 ${img}:${STAMP} 中找到 linux/${arch} 条目"
    docker buildx imagetools create -t "${img}:${STAMP}-linux-${arch}" "${img}@${digest}" \
      || die "派生 ${STAMP}-linux-${arch} 失败"
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
    for b in go node npm pnpm git curl make jq upx nfpm sqlc golangci-lint \
      govulncheck shfmt dockerfmt yamlfmt gojq sql-formatter markdownfmt; do
      command -v "$b" >/dev/null 2>&1 || fail="$fail bin:$b"
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
  docker buildx imagetools create -t "${IMAGE}:${tag}" "${IMAGE}:${STAMP}" \
    || die "提升 ${IMAGE}:${tag} 失败"
  info "提升 ${IMAGE}:${tag} → ${STAMP}"
done

# ---------- 11. 汇总元数据 ----------
GOLANG_DIGEST_SHORT="$(printf '%s' "${GOLANG_INDEX_DIGEST#sha256:}" | cut -c1-12)"
GOLANG_SIZE_AMD64="$(image_size_mb "${IMAGE}:${STAMP}" amd64)"
GOLANG_SIZE_ARM64="$(image_size_mb "${IMAGE}:${STAMP}" arm64)"

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
  "built_at": "${BUILT_AT}",
  "source_date": "${BUILD_DATE}"
}
EOF

info "golang  digest ${GOLANG_INDEX_DIGEST}"
info "golang  size   amd64 ${GOLANG_SIZE_AMD64} / arm64 ${GOLANG_SIZE_ARM64}"
info "元数据         ${ANNOTATION_FILE}"

echo "=============================="
echo "🎉 构建完成 ${IMAGE}:${STAMP}"
echo "=============================="
