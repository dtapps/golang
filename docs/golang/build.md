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

三个镜像由三个脚本分别发布。基础镜像先跑，fnpack / wails3 再各自 `FROM` 它。

基础镜像（`.cnb/scripts/build-golang.sh` / `.github/scripts/build-golang.sh`）：

1. 解析 Dockerfile 的 `GO_VERSION` / `DEBIAN_VERSION`，可选被 `version` 输入覆盖。
2. 起一次性容器执行 `go version`，得到实际版本（如 `1.27.3`）。
3. 读取上游 `golang:<版本>-<代号>` 的 index digest。
4. 再起一次性容器解析工具版本：Go 工具走 `go list -m`（模块路径见脚本里的 `GO_TOOL_MODULES`），UPX / Node.js / pnpm 走各自的上游索引，得到 `v1.31.1` 这种具体版本号。解析失败会回退 `latest` 并打警告，不阻断构建。
5. 一次多架构构建并推送 `golang:<go 版本>`，工具版本以 `--build-arg` 传入。
6. 派生 `<go 版本>-linux-{amd64,arm64}`。
7. amd64 冒烟（工具链齐全、版本命令可执行、fnpack 不存在）。
8. 校验 OCI `version` 标签。
9. 提升 `<major.minor>` 与 `latest`。
10. 写 golang 元数据（含 `tools`：本次各工具的实际版本）。

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

wails3 镜像（`.cnb/scripts/build-wails3.sh` / `.github/scripts/build-wails3.sh`）：

1. 解析同一个 `<go 版本>` 标签。
2. 确定 `WAILS3_VERSION`：输入优先；留空时先用 `go list -m github.com/wailsapp/wails/v3@latest` 解析最新稳定 tag（走基座 Dockerfile 的 `GOPROXY`），解析不到才回退 `latest` 交给 `go install`。
3. 等 `golang:<go 版本>` 在 registry 出现，并读取它的 index digest。
4. 构建并推送 `golang/wails3:<go 版本>`（`GOLANG_IMAGE` 指向基础镜像标签，`WAILS3_VERSION` 以 `--build-arg` 传入）。
5. 派生 wails3 的单平台标签。
6. amd64 冒烟（见下）。
7. 校验 OCI `version` 标签。
8. 只有基础镜像的 `<major.minor>` / `latest` 也指向本次版本时，才提升 wails3 的对应标签。
9. 写 wails3 元数据（含 `wails3_version`）。

### 冒烟断言

golang 镜像：

- `go version` 与解析出的版本一致
- 以下命令都存在：`go node npm pnpm git curl make jq zip unzip pkg-config upx nfpm sqlc ent entc golangci-lint govulncheck shfmt dockerfmt yamlfmt gojq sql-formatter gotestsum markdownfmt`
- `date +%z` 为 `+0800`（`TZ=Asia/Shanghai` 生效、`tzdata` 到位）
- 以下工具的版本命令能实际执行（`--version` / `version` / `-v` 任一成功，防 latest 升级装进坏二进制）：`node npm pnpm upx nfpm sqlc golangci-lint gojq shfmt gotestsum`
- `fnpack` **不存在**

fnpack 镜像：

- `go version` 与解析出的版本一致
- `fnpack` 在 `PATH` 里且可执行
- `go node pnpm sqlc golangci-lint` 仍然存在（证明继承成功）

wails3 镜像：

- `go version` 与解析出的版本一致
- `go node pnpm sqlc golangci-lint zip unzip pkg-config` 都存在（证明继承成功，且打包/编译依赖齐全）
- `pkg-config --exists gtk4` 与 `pkg-config --exists webkitgtk-6.0` 都成立
- `wails3` 在 `PATH` 里，且 `go version -m` 读到的 `github.com/wailsapp/wails/v3` 模块版本等于本次目标版本（回退 `latest` 时只验证可执行）
- `fnpack` **不存在**

### 缓存

两侧都启用 **buildx 层缓存**，写到 `<镜像>:buildcache`（CNB 制品库 / GHCR 各一份），`mode=min`：单阶段构建，每一层都在最终镜像里，min 已覆盖整条链，而且不会产生没人引用的孤儿 blob。

工作方式：

1. 构建前先把 `latest` 解析成具体版本号（见上面第 4 步）。
2. 版本没变 → 所有层命中：apt、Node、`go install` 整段跳过，只剩拉基座、冒烟、推 manifest。
3. 某个工具发版 → 只有它所在的那一层重建（Go 工具按 5 组分层）。
4. 基座 `golang:1-trixie` 的 digest 变了 → apt 之后的层全部重建，和改造前一样。

`CACHE=off` 可关闭缓存并加 `--no-cache` 强制全量重建：

```bash
CACHE=off source .cnb/scripts/build-golang.sh
```

如果 registry 不接受 buildx 的缓存清单（未知 media type / 权限），缓存导出会在镜像推完之后报错；脚本会自动去掉缓存重试一次，所以最坏情况只是慢，不会失败。

> 冒烟测试跑在 `docker run` 的新容器里，不受缓存影响：缓存命中不会跳过冒烟，装坏的二进制仍然会被拦下。

## 手动触发

| 平台   | 镜像   | 入口                                                      | 输入                            |
|--------|--------|-----------------------------------------------------------|---------------------------------|
| CNB    | golang | 仓库页面按钮「打包 Golang 镜像」                          | `version`：留空 / 1.27 / 1.27.3 |
| CNB    | fnpack | 仓库页面按钮「打包 Golang + fnpack 镜像」                 | 同上                            |
| GitHub | golang | Actions → build-golang → Run workflow                     | 同上                            |
| GitHub | fnpack | Actions → build-fnpack → Run workflow（需基础镜像已存在） | 同上                            |

留空表示使用 Dockerfile 的默认值：`golang:1-trixie` 自动跟随最新稳定 Go。填 `1.27` 会跟随该 minor 的最新补丁，填 `1.27.3` 精确到补丁版本。标签里的版本始终是解析后的实际版本。
