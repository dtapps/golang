# Dockerfile 解析

两个平台各有一份实现，安装步骤与工具版本一致；镜像源按平台不同（GitHub 用默认/直连，CNB 用腾讯云与 DaoCloud），这是两份文件的主要差异：

| 镜像   | CNB 侧                          | GitHub 侧                          |
|--------|---------------------------------|------------------------------------|
| golang | `.cnb/docker/Dockerfile.golang` | `.github/docker/Dockerfile.golang` |
| fnpack | `.cnb/docker/Dockerfile.fnpack` | `.github/docker/Dockerfile.fnpack` |

## 1. golang 镜像

### 基座与元数据

```dockerfile
ARG GO_VERSION=1
ARG DEBIAN_VERSION=trixie
FROM golang:${GO_VERSION}-${DEBIAN_VERSION}
```

`GO_VERSION` 默认 `1`，即 `golang:1-trixie` 浮动标签，每次构建自动跟随最新稳定 Go（跨 minor 与大版本）；需要钉版本时填 `1.27` 或 `1.27.3`。实际 Go 版本由构建脚本解析后写进镜像标签。

构建阶段重新声明的 ARG：

| ARG              | 来源                  | 用途                                            |
|------------------|-----------------------|-------------------------------------------------|
| `GO_VERSION`     | 构建脚本 / 默认值     | 基座 Go 版本（默认 `1` = 浮动标签自动跟随最新） |
| `DEBIAN_VERSION` | 默认值                | 基座 Debian 代号（`trixie`）                    |
| `IMAGE_VERSION`  | 脚本                  | OCI `version`，等于解析出的 Go 版本             |
| `VCS_REF`        | 脚本                  | OCI `revision`                                  |
| `BUILD_DATE`     | 脚本                  | OCI `created`，取最后一次提交时间               |
| `BASE_DIGEST`    | 脚本                  | 上游 `golang:<版本>-<代号>` 的 digest           |
| `IMAGE_SOURCE`   | 脚本                  | OCI `source` / `url`                            |
| `GITHUB_MIRROR`  | CNB 脚本（仅 CNB 侧） | GitHub Release 下载前缀（含 releases.atom）     |
| `NODE_MIRROR`    | CNB 脚本（仅 CNB 侧） | nodejs.org 下载前缀                             |

### 镜像源开关

只有 CNB 侧声明 `GITHUB_MIRROR` / `NODE_MIRROR`；为空时直连官方站，非空时按「代理站 + 域名」拼下载地址：

```sh
if [ -n "${GITHUB_MIRROR}" ]; then
  GH="${GITHUB_MIRROR%/}/github.com"
else
  GH="https://github.com"
fi
if [ -n "${NODE_MIRROR}" ]; then NODE_BASE="${NODE_MIRROR%/}/nodejs.org/dist"; else NODE_BASE="https://nodejs.org/dist"; fi
```

- GitHub 侧：没有这两个参数，固定直连 `https://github.com` 与 `https://nodejs.org/dist`。
- CNB 侧：传 `https://files.m.daocloud.io`，实际下载走 `https://files.m.daocloud.io/github.com/...` 与 `https://files.m.daocloud.io/nodejs.org/...`（UPX 取版本用的 `releases.atom` 也在 `github.com` 路径下，同样被镜像）。

### 安装顺序

1. **Go 环境变量**：CNB 侧 `GOPROXY` 指向腾讯云，GitHub 侧不设置（用 Go 默认代理）；`GOPATH=/go`，`PATH` 加入 `/go/bin`。
2. **基础包**：wget、xz-utils、ca-certificates、curl、gnupg、git、make、jq（jq 同时用于版本解析）。
3. **UPX**：`UPX_VERSION=latest` 时从 `releases.atom` 取第一个稳定 tag（grep 锚定 href 行尾引号，天然跳过 `-beta` / `-rc` 预发布；不走 api.github.com，免认证且无限速），再按 `uname -m` 选 amd64/arm64 下载 tar.xz，装到 `/usr/local/bin/upx`。
4. **Node.js**：`NODE_VERSION=latest` 时从 `dist/index.json` 取第一个非预发布版本（过滤 `-alpha` / `-rc`），下载官方 tar.xz 解压到 `/usr/local`；npm / pnpm 使用腾讯云 registry，`pnpm config set ignore-scripts false`。
5. **Go 工具链（含 nfpm）**：同一层内 `go install` 全部工具（nfpm 用 `github.com/goreleaser/nfpm/v2/cmd/nfpm`），然后删掉 `/root/.cache/go-build` 与 `/go/pkg/mod`。
6. **清理**：purge wget / xz-utils，清 APT 缓存与 `/tmp`。

> CNB 侧会在安装基础包之前把 APT 源换成 `mirrors.cloud.tencent.com`；GitHub 侧不换源。

> 清理必须与安装同层：跨层 `rm` 只会产生 whiteout，旧层数据仍会随镜像分发。

### 版本变量

所有工具 ARG 默认 `latest`，构建时自动解析最新版；出现问题时用 `--build-arg`（或改默认值）钉回具体版本：

| ARG                      | 默认值   | 对应工具                  | latest 的解析渠道                           |
|--------------------------|----------|---------------------------|---------------------------------------------|
| `UPX_VERSION`            | `latest` | UPX                       | `releases.atom` 第一个稳定 tag              |
| `NODE_VERSION`           | `latest` | Node.js                   | `dist/index.json` 第一个非预发布版本        |
| `NFPM_VERSION`           | `latest` | nfpm                      | `go install @latest`（钉版本格式 `vX.Y.Z`） |
| `PNPM_VERSION`           | `latest` | pnpm                      | npm registry 的 `pnpm@latest`               |
| `SQLC_VERSION`           | `latest` | sqlc                      | `go install @latest`                        |
| `ENT_VERSION`            | `latest` | ent / entc                | 同上                                        |
| `GOLANGCI_LINT_VERSION`  | `latest` | golangci-lint             | 同上                                        |
| `GOVULNCHECK_VERSION`    | `latest` | govulncheck               | 同上                                        |
| `SHFMT_VERSION`          | `latest` | shfmt                     | 同上                                        |
| `DOCKERFMT_VERSION`      | `latest` | dockerfmt                 | 同上                                        |
| `YAMLFMT_VERSION`        | `latest` | yamlfmt                   | 同上                                        |
| `GOJQ_VERSION`           | `latest` | gojq                      | 同上                                        |
| `GOSQLFORMATTER_VERSION` | `latest` | wasilibs/go-sql-formatter | 同上                                        |
| `GOTESTSUM_VERSION`      | `latest` | gotestsum                 | 同上                                        |
| `MARKDOWNFMT_VERSION`    | `latest` | markdownfmt               | 同上                                        |

`go install @latest` 走模块路径解析：各工具的模块路径带 `/v2`、`/v3` 等后缀，latest 不会自动跨 major；major 升级需要改 Dockerfile 里的模块路径。

## 2. fnpack 镜像

```dockerfile
ARG GOLANG_IMAGE=golang:1-trixie
FROM ${GOLANG_IMAGE}
```

- CI 里 `GOLANG_IMAGE` 是上一步刚推好的 `<registry>/<repo>:<go 版本>`，所以 fnpack 镜像只多一层。
- 单独构建本文件时默认用上游 `golang:1-trixie`，此时镜像里**没有**本仓库预装的 UPX / nfpm / Node / Go 工具，只用于验证 fnpack 下载本身。
- fnpack 版本由 `ARG FNPACK_VERSION` 控制，下载地址如下（`<arch>` 为 `amd64` 或 `arm`，ARM 用 `arm` 而不是 `arm64`）：

```text
https://static2.fnnas.com/fnpack/fnpack-<版本>-linux-<arch>
```

- 安装后用 `fnpack --help` 做一次执行探测（部分版本 `--help` 返回非 0，故失败不阻断构建）。
- OCI `base.name` 记录 `GOLANG_IMAGE`，`base.digest` 记录基础镜像的 index digest。

## 3. 改哪个文件

| 要改的东西         | 改哪里                                                              |
|--------------------|---------------------------------------------------------------------|
| Go 基座版本        | 两份 `Dockerfile.golang` 的 `GO_VERSION`（默认 `1` = 自动跟随最新） |
| 某个工具版本       | 两份 `Dockerfile.golang` 的对应 `ARG`（默认 `latest` = 自动追新）   |
| fnpack 版本        | 两份 `Dockerfile.fnpack` 的 `FNPACK_VERSION`                        |
| 下载源             | 构建脚本的 `MIRROR` / 构建参数                                      |
| 标签规则、冒烟断言 | 两份 `build-golang.sh` + 两份 `build-fnpack.sh`                     |
