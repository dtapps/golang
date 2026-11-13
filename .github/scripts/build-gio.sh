#!/bin/sh
# ===================================================================
# GitHub Actions 专用（build-gio 工作流）：多架构
# （linux/amd64 + linux/arm64）构建并推送 gio 镜像到 GHCR：
#
#   ghcr.io/<owner>/<repo>/gio  → golang + EGL/GLES/X11/Wayland/Vulkan 开发包
#                                 + 无头运行库 + gogio CLI
#
# 本脚本不构建基础镜像：它要求 ghcr.io/<owner>/<repo>:<go 版本> 已经由
# build-golang 工作流推好，直接 FROM 那个 manifest list，只追加 cgo 依赖、
# 无头运行库与 gogio CLI。这样七个镜像的 Go 工具链完全一致。
#
# 触发方式（见 build-gio.yml）：
#   schedule          → 每天固定时间跑（比 build-mygo 晚 3 小时）
#   workflow_dispatch → 手动跑，需要基础镜像标签已存在（脚本会等待并给出提示）
#                       可传 version / gio_version 覆盖默认版本
#
# 这是 GitHub 侧独立实现，与 .cnb/scripts/build-gio.sh 各自维护、不互相引用。
# 标签规则、冒烟断言与 CNB 侧保持一致。
#
# 变体名叫 gio，CLI 却叫 gogio，两者不要混：
#   go install gioui.org/cmd/gogio   ← 装出来的二进制是 gogio
# gogio 是「打包」工具（android / ios / tvos / js / windows / macos），没有
# linux 目标，也没有 version 子命令；Linux 桌面程序就是普通 go build + cgo。
# 所以本镜像的重点不是 gogio 这个二进制，而是 cgo 依赖齐全——Dockerfile 第 3
# 步用真实编译 + 链接来证明，冒烟测试再确认一遍依赖没在运行时被清掉。
#
# 环境变量（默认从 GitHub Actions 内置变量派生，显式传同名变量可覆盖）：
#   REGISTRY_TOKEN   必填，docker login 密码（workflow 里传 secrets.GITHUB_TOKEN）
#   IMAGE            默认 ghcr.io + GITHUB_REPOSITORY（转小写）
#   REGISTRY_USER    默认 GITHUB_ACTOR
#   REVISION         默认 GITHUB_SHA
#   IMAGE_SOURCE     默认 https://github.com/<GITHUB_REPOSITORY>
#   version          选填，Go 版本：留空 = Dockerfile 的 GO_VERSION；
#                    也可填 1.27 / 1.27.3
#   gio_version      选填，gogio CLI 版本（模块 gioui.org/cmd）：
#                    留空 / latest = 解析上游最新稳定 tag；也可填 v0.10.3 / 0.10.3
#
# 版本解析为什么要先做：层缓存按 build-arg 的值算缓存键。每天都传字符串
# latest，缓存键永远不变，go install 那一层会一直命中第一次的产物，
# gio 再也不升级。所以构建前先在基础镜像里用 go list 把 latest 解析成 v0.10.3，
# 再以 --build-arg 传入：上游没发新版就全命中，发新版才重建那一层。
#
# 注意 gioui.org/cmd（gogio CLI）与 gioui.org（库）是两个模块、tag 不保证同步
# （库到 v0.10.3 时 cmd 可能还停在 v0.10.0）。本镜像只装 cmd，库由使用者在自己的
# 项目里 go get，所以这里只解析 cmd 一个版本。
#
# 依赖：docker buildx（setup-buildx-action 提供）、jq 可选（体积精确求和）。
# ===================================================================

set -eu

# ---------- 常量 ----------
DOCKERFILE_GOLANG=".github/docker/Dockerfile.golang"
DOCKERFILE_GIO=".github/docker/Dockerfile.gio"
PLATFORMS="linux/amd64,linux/arm64"
EPOCH_DATE="1970-01-01T00:00:00Z"
# 1 MiB：正常构建镜像不可能低于此值，低于说明拿到的不是镜像清单
MIN_IMAGE_BYTES=1048576
ANNOTATION_FILE=".github/annotation-gio.json"
# 基础镜像由另一个工作流产出，等待它出现在 registry（5 分钟）
BASE_WAIT_ATTEMPTS=20
BASE_WAIT_SECONDS=15
# 层缓存写到 <镜像>:buildcache，mode=min 只导出最终镜像里已有的层（单阶段构建够用）
CACHE_REF_SUFFIX="buildcache"
CACHE_MODE="min"

# ---------- 输出助手 ----------
info() { printf '  %s\n' "$*"; }
warn() { printf '警告: %s\n' "$*" >&2; }
die() {
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

# 从 Dockerfile 读取 ARG 的默认值
read_arg() (
  name=$1
  file=$2
  sed -n "s/^ARG ${name}=//p" "${file}" | head -n 1 \
    | sed 's/[[:space:]]*#.*//' | tr -d '[:space:]'
)

# 从 Dockerfile 的 ENV 行读变量值：解析 gio 版本和构建必须走同一个 GOPROXY
# （GitHub 侧 Dockerfile 不设 GOPROXY，这里会得到空值 = 用 Go 默认代理）
read_env() (
  name=$1
  file=$2
  grep -E "^[[:space:]]*${name}=" "${file}" | head -n 1 \
    | sed "s/.*${name}=//" | sed 's/[[:space:]\\]*$//'
)

# 0.10.3 → v0.10.3；v0.10.3 原样返回
normalize_tag() (
  case "$1" in
    v*) printf '%s\n' "$1" ;;
    *) printf 'v%s\n' "$1" ;;
  esac
)

# 在基础镜像里解析 gogio CLI（模块 gioui.org/cmd）的最新稳定版本。
# 放在容器里跑：不依赖 runner 装了 go / curl，tag 与模块版本的对应关系也交给 go。
# 注意模块路径是 gioui.org/cmd，不是 gioui.org——后者是库，两个都要单独解析。
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

# $1=入参值，$2=Dockerfile 默认值，$3=解析函数，$4=变量名（仅用于日志）
# 函数体用子 shell：日志走 stderr，stdout 只留给解析结果，调用点直接赋值。
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

# ---------- 0. 环境检查与默认值 ----------
: "${REGISTRY_TOKEN:?缺少环境变量 REGISTRY_TOKEN（workflow 里传 secrets.GITHUB_TOKEN）}"

version="${version:-}"
gio_version="${gio_version:-}"
# CACHE=off：关闭层缓存并强制全量重建
CACHE="${CACHE:-on}"
case "${CACHE}" in
  on | off) : ;;
  *) die "CACHE 只接受 on / off，收到：${CACHE}" ;;
esac
_slug="$(printf '%s' "${GITHUB_REPOSITORY:-}" | tr '[:upper:]' '[:lower:]')"
REGISTRY_USER="${REGISTRY_USER:-${GITHUB_ACTOR:-}}"
REVISION="${REVISION:-${GITHUB_SHA:-unknown}}"
IMAGE_SOURCE="${IMAGE_SOURCE:-https://github.com/${GITHUB_REPOSITORY:-}}"

[ -n "${REGISTRY_USER}" ] || die "无法确定 REGISTRY_USER：请在 GitHub Actions 里运行（GITHUB_ACTOR 自动可用），或显式传 REGISTRY_USER"

if [ -z "${IMAGE:-}" ]; then
  [ -n "${_slug}" ] || die "无法确定 IMAGE：请在 GitHub Actions 里运行（GITHUB_REPOSITORY 自动可用），或显式传 IMAGE=ghcr.io/<owner>/<repo>"
  IMAGE="ghcr.io/${_slug}"
fi
case "${IMAGE}" in
  *//* | */) die "IMAGE 含空路径段：${IMAGE}" ;;
esac
case "${IMAGE}" in
  */*/*) : ;;
  *) die "IMAGE 必须形如 ghcr.io/<owner>/<repo>，收到：${IMAGE}" ;;
esac
case "${IMAGE_SOURCE}" in
  *://*) : ;;
  *) die "无法确定 IMAGE_SOURCE（得到：${IMAGE_SOURCE:-空}）：请在 GitHub Actions 里运行，或显式传 IMAGE_SOURCE=https://github.com/<owner>/<repo>" ;;
esac

REGISTRY="${IMAGE%%/*}"
case "${REGISTRY}" in
  *.* | localhost) : ;;
  *) die "IMAGE 必须带 registry 前缀（如 ghcr.io/<owner>/<repo>），收到：${IMAGE}" ;;
esac
case "${IMAGE}" in
  *[[:upper:]]*) die "IMAGE 不能含大写字母：${IMAGE}" ;;
esac

GIO_IMAGE="${IMAGE}/gio"

# 凭证只在本次构建内有效：结束时删掉登录态
HOMEDIR="${HOME:-/root}"
cleanup() { rm -f "$HOMEDIR/.docker/config.json"; }
trap cleanup EXIT

echo "=============================="
echo "🔧 构建多架构 Golang + gio 镜像（GHCR）"
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
# 两个变量同一套规则，抽成函数：不用 eval 拼变量名（POSIX sh 里既难读又容易漏引号）。
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
# 滚动 minor 固定取 major.minor（1.27.3 → 1.27）
MINOR="$(printf '%s' "${GO_REAL}" | cut -d. -f1,2)"

# ---------- 3.1 解析 gogio 版本（层缓存的前提） ----------
# gioui.org/cmd（gogio CLI）与 gioui.org（库）的 tag 不保证同步；本镜像只装 cmd，
# 库由使用者在自己的项目里 go get，所以这里只解析 cmd。
DOCKERFILE_GOPROXY="$(read_env GOPROXY "$DOCKERFILE_GOLANG")"

GIO_VERSION="$(resolve_version "${gio_version}" "${GIO_VERSION_DEFAULT}" resolve_gio_latest gio_version)"

# ---------- 4. 时间戳与标签 ----------
BUILD_DATE="$(git log -1 --format=%cI 2>/dev/null || true)"
[ -n "${BUILD_DATE}" ] || BUILD_DATE="${EPOCH_DATE}"
# 标签就是 Go 版本号，不加日期：同名标签每天重建会覆盖。
# gogio 的版本不占标签，只记录在元数据 gio_version 里。
STAMP="${GO_REAL}"
VCS_REF="${REVISION}"
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
  || die "基础镜像 ${IMAGE}:${STAMP} 不存在：先运行 build-golang 工作流（或等它的定时任务完成），gio 镜像必须基于它构建"

BASE_INDEX_DIGEST="$(docker buildx imagetools inspect "${IMAGE}:${STAMP}" \
  --format '{{.Manifest.Digest}}' 2>/dev/null || true)"
[ -n "${BASE_INDEX_DIGEST}" ] || die "无法读取 ${IMAGE}:${STAMP} 的 index digest"

# ---------- 8. 构建并推送 gio 镜像 ----------
# FROM build-golang 推好的 manifest list：每个平台解析到对应架构的 golang 镜像。
# 基础镜像 digest 没变、gogio 版本也没变时，apt 与 go install 两层全命中。
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
  digest="$(manifest_digest_for "${GIO_IMAGE}:${STAMP}" "${arch}")"
  [ -n "${digest}" ] || die "未在 ${GIO_IMAGE}:${STAMP} 中找到 linux/${arch} 条目"
  create_tag_with_retry "${GIO_IMAGE}:${STAMP}-linux-${arch}" "${GIO_IMAGE}@${digest}" \
    || die "派生 ${STAMP}-linux-${arch} 失败（已重试 3 次）"
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

# 镜像已 pull 到本地，直接读 config 里的 label
label_version="$(docker image inspect \
  --format '{{index .Config.Labels "org.opencontainers.image.version"}}' \
  "${GIO_IMAGE}:${STAMP}" 2>/dev/null || true)"
[ "${label_version}" = "${STAMP}" ] \
  || die "gio OCI label 校验失败：org.opencontainers.image.version=${label_version:-<空>}，期望 ${STAMP}"

# ---------- 11. 提升可变标签（冒烟通过、且基础镜像的移动标签已就位） ----------
# 先确认 golang:<tag> 也指向本次 <go 版本>，避免 gio 的 latest 跑到基础镜像前面。
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
  create_tag_with_retry "${GIO_IMAGE}:${tag}" "${GIO_IMAGE}:${STAMP}" \
    || die "提升 ${GIO_IMAGE}:${tag} 失败（已重试 3 次）"
  info "提升 ${GIO_IMAGE}:${tag} → ${STAMP}"
done

# ---------- 12. 汇总元数据 ----------
GIO_INDEX_DIGEST="$(docker buildx imagetools inspect "${GIO_IMAGE}:${STAMP}" \
  --format '{{.Manifest.Digest}}' 2>/dev/null || true)"
GIO_DIGEST_SHORT="$(printf '%s' "${GIO_INDEX_DIGEST#sha256:}" | cut -c1-12)"
GIO_SIZE_AMD64="$(image_size_mb "${GIO_IMAGE}:${STAMP}" amd64)"
GIO_SIZE_ARM64="$(image_size_mb "${GIO_IMAGE}:${STAMP}" arm64)"

mkdir -p "$(dirname "${ANNOTATION_FILE}")"
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
  "source_date": "${BUILD_DATE}",
  "revision": "${VCS_REF}"
}
EOF

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    printf 'image_version=%s\n' "${STAMP}"
    printf 'gio_digest=%s\n' "${GIO_INDEX_DIGEST:-unknown}"
    printf 'gio_version=%s\n' "${GIO_VERSION}"
    printf 'golang_version=%s\n' "${GO_REAL}"
  } >>"${GITHUB_OUTPUT}"
fi

info "gio   digest ${GIO_INDEX_DIGEST:-unknown}"
info "gio   size   amd64 ${GIO_SIZE_AMD64} / arm64 ${GIO_SIZE_ARM64}"
info "base  digest ${BASE_INDEX_DIGEST}"
info "元数据         ${ANNOTATION_FILE}"

echo "=============================="
echo "🎉 构建完成 ${GIO_IMAGE}:${STAMP}（gogio ${GIO_VERSION}）"
echo "=============================="
