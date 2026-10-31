# 构建

## 本地构建

### golang 镜像

```bash
# 默认基座 golang:1-trixie（自动跟随最新稳定 Go，工具默认 latest）
docker build -f .github/docker/Dockerfile.golang -t golang:local .

# 钉住某个 Go 版本
docker build -f .github/docker/Dockerfile.golang \
  --build-arg GO_VERSION=1.27.3 \
  -t golang:local .

# 国内网络：用 CNB 侧，GitHub Release 与 nodejs.org 走 DaoCloud
docker build -f .cnb/docker/Dockerfile.golang \
  --build-arg GITHUB_MIRROR=https://files.m.daocloud.io \
  --build-arg NODE_MIRROR=https://files.m.daocloud.io \
  -t golang:local .
```

### fnpack 镜像

fnpack 镜像要继承上一步的工具链，`GOLANG_IMAGE` 必须指向刚构建的 golang 镜像：

```bash
docker build -f .github/docker/Dockerfile.fnpack \
  --build-arg GOLANG_IMAGE=golang:local \
  -t golang-fnpack:local .
```

不传 `GOLANG_IMAGE` 时默认 `golang:1-trixie`，只会得到「上游基座 + fnpack」，没有本仓库预装的工具链。

### 快速验证

```bash
docker run --rm golang:local sh -c '
  go version
  node -v
  pnpm -v
  sqlc version
  golangci-lint version
  upx --version
  nfpm --version
'

docker run --rm golang-fnpack:local sh -c '
  go version
  fnpack --help
'
```

## 多架构构建

```bash
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -f .github/docker/Dockerfile.golang \
  -t golang:local-multi \
  --push .   # 多架构只能推 registry 或 --load 单平台
```

arm64 在 amd64 机器上依赖 QEMU/binfmt；GitHub workflow 用 `docker/setup-qemu-action`，CNB 的 docker 服务自带多架构支持。

## CI 构建流程

两个镜像由两个脚本分别发布。基础镜像先跑，fnpack 镜像再 `FROM` 它。

基础镜像（`.cnb/scripts/build-golang.sh` / `.github/scripts/build-golang.sh`）：

1. 解析 Dockerfile 的 `GO_VERSION` / `DEBIAN_VERSION`，可选被 `version` 输入覆盖。
2. 起一次性容器执行 `go version`，得到实际版本（如 `1.27.3`）。
3. 读取上游 `golang:<版本>-<代号>` 的 index digest。
4. 一次多架构构建并推送 `golang:<go 版本>`（工具版本默认 latest，构建时自动解析）。
5. 派生 `<go 版本>-linux-{amd64,arm64}`。
6. amd64 冒烟（工具链齐全、版本命令可执行、fnpack 不存在）。
7. 校验 OCI `version` 标签。
8. 提升 `<major.minor>` 与 `latest`。
9. 写 golang 元数据。

fnpack 镜像（`.cnb/scripts/build-fnpack.sh` / `.github/scripts/build-fnpack.sh`）：

1. 从同一份 Dockerfile.golang 解析 `GO_VERSION` / `DEBIAN_VERSION`，得到同一个 `<go 版本>` 标签（两侧解析的是同一个上游浮动引用 `golang:1-trixie`；若上游恰好在两条流水线之间发了新版，fnpack 会因找不到对应标签而安全失败，次日自动对齐）。
2. 等 `golang:<go 版本>` 在 registry 出现（两侧都靠错开的定时任务保证）。
3. 读取基础镜像的 index digest。
4. 构建并推送 `golang/fnpack:<go 版本>`（`GOLANG_IMAGE` 指向基础镜像标签）。
5. 派生 fnpack 的单平台标签。
6. amd64 冒烟（fnpack 存在且可执行、工具链继承成功）。
7. 校验 OCI `version` 标签。
8. 只有基础镜像的 `<major.minor>` / `latest` 也指向本次版本时，才提升 fnpack 的对应标签。
9. 写 fnpack 元数据。

### 冒烟断言

golang 镜像：

- `go version` 与解析出的版本一致
- 以下命令都存在：`go node npm pnpm git curl make jq upx nfpm sqlc ent entc golangci-lint govulncheck shfmt dockerfmt yamlfmt gojq sql-formatter gotestsum markdownfmt`
- 以下工具的版本命令能实际执行（`--version` / `version` / `-v` 任一成功，防 latest 升级装进坏二进制）：`node npm pnpm upx nfpm sqlc golangci-lint gojq shfmt gotestsum`
- `fnpack` **不存在**

fnpack 镜像：

- `go version` 与解析出的版本一致
- `fnpack` 在 `PATH` 里且可执行
- `go node pnpm sqlc golangci-lint` 仍然存在（证明继承成功）

### 缓存

两侧都**不启用**层缓存。镜像内容以「每次重新拉上游、重新下载依赖」为准，避免每日定时任务一直命中旧缓存。

## 手动触发

| 平台   | 镜像   | 入口                                                      | 输入                            |
|--------|--------|-----------------------------------------------------------|---------------------------------|
| CNB    | golang | 仓库页面按钮「打包 Golang 镜像」                          | `version`：留空 / 1.27 / 1.27.3 |
| CNB    | fnpack | 仓库页面按钮「打包 Golang + fnpack 镜像」                 | 同上                            |
| GitHub | golang | Actions → build-golang → Run workflow                     | 同上                            |
| GitHub | fnpack | Actions → build-fnpack → Run workflow（需基础镜像已存在） | 同上                            |

留空表示使用 Dockerfile 的默认值：`golang:1-trixie` 自动跟随最新稳定 Go。填 `1.27` 会跟随该 minor 的最新补丁，填 `1.27.3` 精确到补丁版本。标签里的版本始终是解析后的实际版本。
