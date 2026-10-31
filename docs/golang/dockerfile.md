# Dockerfile 解析

两个平台各有一份完整副本，内容除注释外相同：

| 镜像   | CNB 侧                          | GitHub 侧                          |
|--------|---------------------------------|------------------------------------|
| golang | `.cnb/docker/Dockerfile.golang` | `.github/docker/Dockerfile.golang` |
| fnpack | `.cnb/docker/Dockerfile.fnpack` | `.github/docker/Dockerfile.fnpack` |

## 1. golang 镜像

### 基座与元数据

```dockerfile
ARG GO_VERSION=1.27.3
ARG DEBIAN_VERSION=trixie
FROM golang:${GO_VERSION}-${DEBIAN_VERSION}
```

构建阶段重新声明的 ARG：

| ARG              | 来源              | 用途                                  |
|------------------|-------------------|---------------------------------------|
| `GO_VERSION`     | 构建脚本 / 默认值 | 基座 Go 版本                          |
| `DEBIAN_VERSION` | 默认值            | 基座 Debian 代号（`trixie`）          |
| `IMAGE_VERSION`  | 脚本              | OCI `version`，等于解析出的 Go 版本   |
| `VCS_REF`        | 脚本              | OCI `revision`                        |
| `BUILD_DATE`     | 脚本              | OCI `created`，取最后一次提交时间     |
| `BASE_DIGEST`    | 脚本              | 上游 `golang:<版本>-<代号>` 的 digest |
| `IMAGE_SOURCE`   | 脚本              | OCI `source` / `url`                  |
| `GITHUB_MIRROR`  | CNB 脚本          | GitHub Release 下载前缀               |
| `NODE_MIRROR`    | CNB 脚本          | nodejs.org 下载前缀                   |

### 镜像源开关

`GITHUB_MIRROR` / `NODE_MIRROR` 为空时直连官方站；非空时按「代理站 + 域名」拼下载地址：

```sh
if [ -n "${GITHUB_MIRROR}" ]; then GH="${GITHUB_MIRROR%/}/github.com"; else GH="https://github.com"; fi
if [ -n "${NODE_MIRROR}" ]; then NODE_BASE="${NODE_MIRROR%/}/nodejs.org/dist"; else NODE_BASE="https://nodejs.org/dist"; fi
```

- GitHub Actions：不传，直连 `github.com` / `nodejs.org`。
- CNB：传 `https://files.m.daocloud.io`，实际下载走 `https://files.m.daocloud.io/github.com/...` 与 `https://files.m.daocloud.io/nodejs.org/...`。

### 安装顺序

1. **Go 环境变量**：`GOPROXY` 指向腾讯云，`GOPATH=/go`，`PATH` 加入 `/go/bin`。
2. **APT 换源**：`deb.debian.org` → `mirrors.cloud.tencent.com`。
3. **基础包**：wget、xz-utils、ca-certificates、curl、gnupg、git、make、jq。
4. **UPX**：按 `uname -m` 选 amd64/arm64，下载 tar.xz，装到 `/usr/local/bin/upx`。
5. **nfpm**：按架构下载 tar.gz，装到 `/usr/local/bin/nfpm`。
6. **Node.js**：下载官方 tar.xz，解压到 `/usr/local`；npm / pnpm 使用腾讯云 registry，`pnpm config set ignore-scripts false`。
7. **Go 工具链**：同一层内 `go install` 九个工具，然后删掉 `/root/.cache/go-build` 与 `/go/pkg/mod`。
8. **清理**：purge wget / xz-utils，清 APT 缓存与 `/tmp`。

> 清理必须与安装同层：跨层 `rm` 只会产生 whiteout，旧层数据仍会随镜像分发。

### 版本变量

| ARG                      | 默认值     | 对应工具                  |
|--------------------------|------------|---------------------------|
| `UPX_VERSION`            | `5.2.1`    | UPX                       |
| `NFPM_VERSION`           | `2.48.0`   | nfpm                      |
| `NODE_VERSION`           | `26.12.1`  | Node.js                   |
| `PNPM_VERSION`           | `12.16.0`  | pnpm                      |
| `SQLC_VERSION`           | `v1.31.1`  | sqlc                      |
| `GOLANGCI_LINT_VERSION`  | `v2.15.0`  | golangci-lint             |
| `GOVULNCHECK_VERSION`    | `v1.9.0`   | govulncheck               |
| `SHFMT_VERSION`          | `v3.14.1`  | shfmt                     |
| `DOCKERFMT_VERSION`      | `v0.5.4`   | dockerfmt                 |
| `YAMLFMT_VERSION`        | `v0.21.0`  | yamlfmt                   |
| `GOJQ_VERSION`           | `v0.12.19` | gojq                      |
| `GOSQLFORMATTER_VERSION` | `v15.8.2`  | wasilibs/go-sql-formatter |
| `MARKDOWNFMT_VERSION`    | `v3.1.0`   | markdownfmt               |

## 2. fnpack 镜像

```dockerfile
ARG GOLANG_IMAGE=golang:1.27.3-trixie
FROM ${GOLANG_IMAGE}
```

- CI 里 `GOLANG_IMAGE` 是上一步刚推好的 `<registry>/<repo>:<go 版本>`，所以 fnpack 镜像只多一层。
- 单独构建本文件时默认用上游 `golang:1.27.3-trixie`，此时镜像里**没有**本仓库预装的 UPX / nfpm / Node / Go 工具，只用于验证 fnpack 下载本身。
- fnpack 版本由 `ARG FNPACK_VERSION` 控制，下载地址：

```text
https://static2.fnnas.com/fnpack/fnpack-<版本>-linux-<arch>
```

- 安装后用 `fnpack --help` 做一次执行探测（部分版本 `--help` 返回非 0，故失败不阻断构建）。
- OCI `base.name` 记录 `GOLANG_IMAGE`，`base.digest` 记录基础镜像的 index digest。

## 3. 改哪个文件

| 要改的东西         | 改哪里                                          |
|--------------------|-------------------------------------------------|
| Go 基座版本        | 两份 `Dockerfile.golang` 的 `GO_VERSION`        |
| 某个工具版本       | 两份 `Dockerfile.golang` 的对应 `ARG`           |
| fnpack 版本        | 两份 `Dockerfile.fnpack` 的 `FNPACK_VERSION`    |
| 下载源             | 构建脚本的 `MIRROR` / 构建参数                  |
| 标签规则、冒烟断言 | 两份 `build-golang.sh` + 两份 `build-fnpack.sh` |
