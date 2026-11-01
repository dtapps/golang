# Dockerfile 解析

两个平台各有一份实现，安装步骤与工具版本一致；镜像源按平台不同（GitHub 用默认/直连，CNB 用腾讯云与 DaoCloud），这是两份文件的主要差异：

| 镜像   | CNB 侧                          | GitHub 侧                          |
|--------|---------------------------------|------------------------------------|
| golang | `.cnb/docker/Dockerfile.golang` | `.github/docker/Dockerfile.golang` |
| fnpack | `.cnb/docker/Dockerfile.fnpack` | `.github/docker/Dockerfile.fnpack` |
| wails3 | `.cnb/docker/Dockerfile.wails3` | `.github/docker/Dockerfile.wails3` |

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

1. **环境变量**：Go 侧 CNB 的 `GOPROXY` 指向腾讯云、GitHub 不设置（用默认代理）；`GOPATH=/go`，`PATH` 加入 `/go/bin`。另有 `TZ=Asia/Shanghai`、`LANG=C.UTF-8`、`LC_ALL=C.UTF-8`：容器内统一北京时间与 UTF-8，构建日志、`go build` 产物里的时间戳才对得上。
2. **基础包**：wget、xz-utils、ca-certificates、curl、gnupg、git、make、jq（jq 同时用于版本解析）、zip、unzip、pkg-config（打包/解压/cgo），以及 **tzdata**——配合上面的 `TZ`：装完 `ln -snf /usr/share/zoneinfo/$TZ /etc/localtime`、写 `/etc/timezone`，再 `date` 打一行日志确认（构建日志里应看到 `CST`）。
3. **UPX**：`UPX_VERSION=latest` 时从 `releases.atom` 取第一个稳定 tag（grep 锚定 href 行尾引号，天然跳过 `-beta` / `-rc` 预发布；不走 api.github.com，免认证且无限速），再按 `uname -m` 选 amd64/arm64 下载 tar.xz，装到 `/usr/local/bin/upx`。
4. **Node.js**：`NODE_VERSION=latest` 时从 `dist/index.json` 取第一个非预发布版本（过滤 `-alpha` / `-rc`），下载官方 tar.xz 解压到 `/usr/local`；npm / pnpm 使用腾讯云 registry，`pnpm config set ignore-scripts false`。
5. **Go 工具链（含 nfpm）**：按工具分成 5 层 `go install -v`（nfpm+sqlc / ent+entc / golangci-lint+govulncheck / shfmt+dockerfmt+yamlfmt+gojq / sql-formatter+gotestsum+markdownfmt），`-v` 会打印每个被编译的包，CI 日志里能直接看出卡在哪个工具、哪个包上；每层都挂 BuildKit 缓存目录：
   - `--mount=type=cache,target=/go/pkg/mod`：模块缓存
   - `--mount=type=cache,target=/root/.cache/go-build`：编译缓存

   缓存挂载不进镜像层，所以不再需要「同一层内 `rm -rf /go/pkg/mod`」那种清理；拆层是为了让某个工具发版时只重建它自己那一层。`-v` 只是让日志可读，不影响产物；`build-golang.sh` 的 `dockerfile_tool_vars` 用 `grep -o 'go install[^@;]*@${VAR}'` 提取版本变量，所以这里在 `go install` 与包路径之间再加别的 flag 也不会漏检。
6. **清理**：purge wget / xz-utils，清 APT 缓存与 `/tmp`。
7. **OCI 元数据标签**：放在文件最后。`BUILD_DATE` / `VCS_REF` / `IMAGE_VERSION` 每次都变，放前面会让 apt、Node、`go install` 这些层的缓存键跟着每次提交一起变。

> CNB 侧会在安装基础包之前把 APT 源换成 `mirrors.cloud.tencent.com`；GitHub 侧不换源。

> 清理必须与安装同层：跨层 `rm` 只会产生 whiteout，旧层数据仍会随镜像分发。

### 版本变量

所有工具 `ARG` 默认 `latest`，但 **CI 不会把 `latest` 传进来**：两份 `build-golang.sh` 会先在基础镜像里把 `latest` 解析成具体版本号（如 `v1.31.1`），再以 `--build-arg` 传入。

原因是层缓存按 build-arg 的「值」算缓存键：每天都传字符串 `latest`，缓存键永远不变，层会一直命中第一次构建的产物，工具就再也不会升级。解析后传具体版本号，才能做到「没发新版全命中、发新版只重建那一层」。

`latest` 默认值只用于不经过 CI 的裸 `docker build`，此时由 Dockerfile 在构建时自行解析（行为和以前一致，只是没有缓存收益）。出现问题时用 `--build-arg`（或改默认值）钉回具体版本：

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

## 3. wails3 镜像

```dockerfile
ARG GOLANG_IMAGE=golang:1-trixie
FROM ${GOLANG_IMAGE}
```

- 与 fnpack 同构：`GOLANG_IMAGE` 由 CI 指向上一步刚推好的 `<registry>/<repo>:<go 版本>`，只多两层（apt 装 GTK4/WebKitGTK + `go install` wails3）。
- apt 与 `GOPROXY` 都继承基座镜像：CNB 侧的 `Dockerfile.golang` 已换成腾讯云源，所以这个文件里没有 `GITHUB_MIRROR` / `NODE_MIRROR` 开关。
- 安装的开发包：`zip`、`unzip`、`pkg-config`、`libgtk-4-dev`、`libwebkitgtk-6.0-dev`；装完立刻 `pkg-config --exists gtk4` 与 `webkitgtk-6.0` 断言，避免把问题推迟到使用者手里（这两层**不能**在最后 purge，它们就是镜像的用途）。
- wails3 版本由 `ARG WAILS3_VERSION` 控制，默认 `latest`（不再钉死某个 tag）；CI 会先解析成 `v3.1.0` 这种具体版本再传进来。安装命令：

```dockerfile
go install "github.com/wailsapp/wails/v3/cmd/wails3@${WAILS3_VERSION}"
```

- `wails3` 落在 `${GOPATH}/bin`（`/go/bin`，已在 `PATH` 中），`test -x` + `wails3 version` 做安装验证。
- `--mount=type=cache` 挂模块与编译缓存：`go install` 要编译整个 CLI，冷缓存下这一层是耗时大头。

## 4. 改哪个文件

| 要改的东西         | 改哪里                                                                                       |
|--------------------|----------------------------------------------------------------------------------------------|
| Go 基座版本        | 两份 `Dockerfile.golang` 的 `GO_VERSION`（默认 `1` = 自动跟随最新）                          |
| 某个工具版本       | 两份 `Dockerfile.golang` 的对应 `ARG`（默认 `latest` = 自动追新）                            |
| fnpack 版本        | 两份 `Dockerfile.fnpack` 的 `FNPACK_VERSION`（默认值，可被手动触发的 `fnpack_version` 覆盖） |
| wails3 版本        | 两份 `Dockerfile.wails3` 的 `WAILS3_VERSION`（默认 `latest`，可被 `wails3_version` 覆盖）    |
| 下载源             | 构建脚本的 `MIRROR` / 构建参数                                                               |
| 标签规则、冒烟断言 | 两份 `build-golang.sh` + 两份 `build-fnpack.sh` + 两份 `build-wails3.sh`                     |
