#!/bin/sh
# 通用工具安装器：**优先下载官方预编译二进制**（快），下载/解压失败才回退 go install。
# 与镜像里的 install-tool 同一思路，只是目标平台和安装目录不同（$GOPATH/bin）。
#
# 用法：install-tool.sh <tool> [pin]
#   tool  见下方「工具表」，新增工具只在表里加一段
#   pin   版本号（vX.Y.Z）；latest 或空 → 解析最新 release tag
#
# 由 action.yml 调用（tools 输入）：
#   原生 / setup-only：bash "$GITHUB_ACTION_PATH/scripts/install-tool.sh" task v3.54.0
#   Linux 容器构建   ：sh /opt/go-gui-tools/install-tool.sh task v3.54.0
#   （scripts 目录以只读方式挂载到 /opt/go-gui-tools）
set -eu

tool="${1:?用法: install-tool.sh <tool> [pin]}"
pin="${2:-latest}"

# ---------- 工具表：新增工具只改这里 ----------
case "${tool}" in
  task)
    repo="go-task/task"                          # GitHub 仓库（下载二进制）
    module="github.com/go-task/task/v3/cmd/task" # go install 兜底用的包路径
    bin="task"                                   # 二进制名（Windows 自动加 .exe）
    asset='task_${os}_${arch}.${ext}'            # 资产名模板
    ;;
  *)
    echo "::error::install-tool.sh 不支持的工具：${tool}" >&2
    exit 1
    ;;
esac

gobin="$(go env GOPATH)/bin"
mkdir -p "${gobin}"

tmp=""
cleanup() { if [ -n "${tmp}" ]; then rm -rf "${tmp}"; fi; }
trap cleanup EXIT INT TERM

# ---------- latest → 最新 release tag（releases/latest 的 302，免 API 限速）----------
case "${pin}" in
  '' | latest)
    resolved="$(curl -fsSL -o /dev/null -w '%{url_effective}' \
      "https://github.com/${repo}/releases/latest" 2>/dev/null | sed 's|.*/tag/||')"
    case "${resolved}" in
      v[0-9]*) pin="${resolved}" ;;
      *) echo "::warning::无法解析 ${repo} 最新版本，直接走 go install" ;;
    esac
    ;;
esac

# ---------- 平台 / 架构 / 包格式 ----------
os="$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]')"
case "${os}" in
  linux*) os=linux ;;
  darwin*) os=darwin ;;
  mingw* | msys* | cygwin*) os=windows ;;
  *) os="" ;;
esac
arch="$(go env GOARCH 2>/dev/null || echo amd64)"
if [ "${os}" = "windows" ]; then
  ext=zip
  target="${bin}.exe"
else
  ext=tar.gz
  target="${bin}"
fi

# ---------- 1. 二进制优先 ----------
if [ -n "${os}" ] && [ -n "${pin}" ]; then
  eval "asset_name=\"${asset}\""
  url="https://github.com/${repo}/releases/download/${pin}/${asset_name}"
  tmp="$(mktemp -d)"
  echo "下载 ${repo} ${pin}（${os}/${arch}）：${url}"
  if curl -fsSL --retry 2 -o "${tmp}/pkg.${ext}" "${url}"; then
    case "${ext}" in
      zip)
        unzip -q -o "${tmp}/pkg.${ext}" -d "${tmp}" 2>/dev/null \
          || tar -xf "${tmp}/pkg.${ext}" -C "${tmp}" 2>/dev/null || true
        ;;
      *) tar -xzf "${tmp}/pkg.${ext}" -C "${tmp}" 2>/dev/null || true ;;
    esac
    for cand in "${tmp}/${bin}" "${tmp}/${bin}.exe" \
      "${tmp}"/*/"${bin}" "${tmp}"/*/"${bin}.exe"; do
      if [ -f "${cand}" ]; then
        mv "${cand}" "${gobin}/${target}"
        chmod +x "${gobin}/${target}"
        echo "${tool} ${pin} 安装完成（二进制）：${gobin}/${target}"
        exit 0
      fi
    done
    echo "::warning::二进制包已下载但没找到 ${bin}，回退 go install"
  else
    echo "::warning::二进制下载失败（${url}），回退 go install"
  fi
fi

# ---------- 2. go install 兜底 ----------
echo "go install ${module}@${pin:-latest} ..."
go install "${module}@${pin:-latest}"
echo "${tool} 安装完成（go install）：$(command -v "${bin}" || echo "未找到 ${bin}")"
