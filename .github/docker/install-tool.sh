#!/bin/sh
# 从 GitHub Release 下载官方二进制并装到 /usr/local/bin。
#
# 用法：install-tool <工具名> <版本>
#   版本必须是具体 tag（v2.48.0）。传 latest 或空值时直接失败，
#   由调用方回退 go install（用 @latest 让 go 自己去解析）。
#
# 退出码：0 = 二进制已就位；非 0 = 该工具没有官方二进制 / 下载解压失败，调用方回退。
#
# GITHUB_MIRROR 为空 → 直连 github.com（GitHub / GitLab 侧）
# GITHUB_MIRROR=https://files.m.daocloud.io → 走 DaoCloud 镜像（CNB 侧）
#
# 资产命名每个仓库都不一样（大小写、下划线/连字符、v 前缀、x86_64 vs amd64），
# 所以按工具列一份表；新增工具时在这里加一行，并确认「解压后二进制名 = 工具名」。
set -eu

tool=${1:?用法: install-tool <工具名> <版本>}
ver=${2:-}

case "${ver}" in
  '' | latest)
    echo "版本为 latest，跳过二进制下载：${tool}（交给 go install）" >&2
    exit 1
    ;;
esac

case "$(uname -m)" in
  x86_64)
    arch=amd64
    deb=x86_64
    ;;
  aarch64 | arm64)
    arch=arm64
    deb=arm64
    ;;
  *)
    echo "不支持的架构：$(uname -m)" >&2
    exit 1
    ;;
esac

v=${ver#v}
repo=''
file=''
kind=tar
case "${tool}" in
  nfpm)
    repo=goreleaser/nfpm
    file="nfpm_${v}_Linux_${deb}.tar.gz"
    ;;
  sqlc)
    repo=sqlc-dev/sqlc
    file="sqlc_${v}_linux_${arch}.tar.gz"
    ;;
  golangci-lint)
    repo=golangci/golangci-lint
    file="golangci-lint-${v}-linux-${arch}.tar.gz"
    ;;
  shfmt)
    repo=mvdan/sh
    file="shfmt_v${v}_linux_${arch}"
    kind=raw
    ;;
  dockerfmt)
    repo=reteps/dockerfmt
    file="dockerfmt-v${v}-linux-${arch}.tar.gz"
    ;;
  yamlfmt)
    repo=google/yamlfmt
    file="yamlfmt_${v}_Linux_${deb}.tar.gz"
    ;;
  gojq)
    repo=itchyny/gojq
    file="gojq_v${v}_linux_${arch}.tar.gz"
    ;;
  sql-formatter)
    repo=wasilibs/go-sql-formatter
    file="sql-formatter_${v}_linux_${arch}.tar.gz"
    ;;
  gotestsum)
    repo=gotestyourself/gotestsum
    file="gotestsum_${v}_linux_${arch}.tar.gz"
    ;;
  gcov2lcov)
    repo=jandelgado/gcov2lcov
    file="gcov2lcov_${v}_linux_${arch}.tar.gz"
    ;;
  *)
    echo "没有官方二进制，回退 go install：${tool}" >&2
    exit 1
    ;;
esac

# 镜像优先、官方源兜底：CNB 上 GITHUB_MIRROR 指向 DaoCloud，
# 镜像没缓存到某个资产时自动再试一次 github.com，两边都失败才回退 go install。
bases=''
if [ -n "${GITHUB_MIRROR:-}" ]; then
  bases="${GITHUB_MIRROR%/}/github.com"
fi
bases="${bases} https://github.com"

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

ok=''
for base in ${bases}; do
  url="${base}/${repo}/releases/download/${ver}/${file}"
  echo "下载 ${tool} ${ver}：${url}" >&2
  if curl -fsSL --retry 2 --retry-delay 2 --connect-timeout 20 -o "${tmp}/pkg" "${url}"; then
    ok=1
    break
  fi
done
if [ -z "${ok}" ]; then
  echo "下载失败：${tool} ${ver}" >&2
  exit 1
fi

case "${kind}" in
  raw) install -m 0755 "${tmp}/pkg" "/usr/local/bin/${tool}" ;;
  tar)
    if ! tar -xzf "${tmp}/pkg" -C "${tmp}"; then
      echo "解压失败：${tool} ${ver}" >&2
      exit 1
    fi
    # 有的仓库压缩包里带同名目录前缀（golangci-lint-2.x-linux-amd64/），find 兜住
    found="$(find "${tmp}" -type f -name "${tool}" | head -n 1)"
    if [ -z "${found}" ]; then
      echo "压缩包里找不到 ${tool}：${file}" >&2
      exit 1
    fi
    install -m 0755 "${found}" "/usr/local/bin/${tool}"
    ;;
esac

echo "二进制安装完成：${tool} ${ver}" >&2
