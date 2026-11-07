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

### fyne 镜像

fyne 镜像同样继承上一步的工具链，`GOLANG_IMAGE` 必须指向刚构建的 golang 镜像：

```bash
docker build -f .github/docker/Dockerfile.fyne \
  --build-arg GOLANG_IMAGE=golang:local \
  -t golang-fyne:local .
```

不传 `GOLANG_IMAGE` 时默认 `golang:1-trixie`，只会得到「上游基座 + OpenGL/X11/Wayland 开发包 + fyne」，没有本仓库预装的工具链。

### mygo 镜像

mygo 镜像同样继承上一步的工具链，`GOLANG_IMAGE` 必须指向刚构建的 golang 镜像：

```bash
docker build -f .github/docker/Dockerfile.mygo \
  --build-arg GOLANG_IMAGE=golang:local \
  -t golang-mygo:local .
```

不传 `GOLANG_IMAGE` 时默认 `golang:1-trixie`，只会得到「上游基座 + GTK3/WebKitGTK 4.1 开发包 + 无头运行库 + mygo + bun」，没有本仓库预装的工具链。`MYGO_VERSION` / `BUN_VERSION` 同样默认 `latest`，需要钉版本时用 `--build-arg` 传入（如 `MYGO_VERSION=v0.8.1`、`BUN_VERSION=1.4.4`）。

### gio 镜像

gio 镜像同样继承上一步的工具链，`GOLANG_IMAGE` 必须指向刚构建的 golang 镜像：

```bash
docker build -f .github/docker/Dockerfile.gio \
  --build-arg GOLANG_IMAGE=golang:local \
  -t golang-gio:local .
```

不传 `GOLANG_IMAGE` 时默认 `golang:1-trixie`，只会得到「上游基座 + EGL/GLES、X11、Wayland、Vulkan 开发包 + 无头运行库 + gogio」，没有本仓库预装的工具链。`GIO_VERSION` 同样默认 `latest`，需要钉版本时用 `--build-arg` 传入（如 `GIO_VERSION=v0.10.3`）。

> 变体名叫 gio，CLI 却叫 `gogio`（模块 `gioui.org/cmd`），镜像里没有 `gio` 二进制。`gogio` 是打包工具（android / ios / tvos / js / windows / macos），没有 linux 目标，也没有 `version` 子命令；Linux 桌面程序就是普通 `go build` + cgo。这个镜像的重点是把 cgo 需要的 EGL/GLES、X11、Wayland、Vulkan 开发包装齐（Dockerfile 第 1 层用 `pkg-config` 逐个断言 `.pc` 存在）。

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

docker run --rm golang-fyne:local sh -c '
  go version
  pkg-config --exists gl && pkg-config --exists x11 && pkg-config --exists wayland-client
  fyne version
'

docker run --rm golang-mygo:local sh -c '
  go version
  pkg-config --exists gtk+-3.0 && pkg-config --exists webkit2gtk-4.1
  mygo version
  mygo doctor
  bun --version
'

docker run --rm golang-gio:local sh -c '
  go version
  pkg-config --exists egl && pkg-config --exists x11 && pkg-config --exists vulkan
  gcc --version | head -1
  gogio 2>&1 | head -5   # 没有 version 子命令，无参数会打 usage 到 stderr
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

arm64 在 amd64 机器上依赖 QEMU/binfmt；GitHub workflow 用 `docker/setup-qemu-action`，GitLab job 在 `before_script` 里跑 `tonistiigi/binfmt`，CNB 的 docker 服务自带多架构支持。

## CI 构建流程

七个镜像由七个脚本分别发布。基础镜像先跑，fnpack / wails3 / wails2 / fyne / mygo / gio 再各自 `FROM` 它。

基础镜像（`.cnb/scripts/build-golang.sh` / `.github/scripts/build-golang.sh` / `.gitlab/scripts/build-golang.sh`）：

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

fnpack 镜像（`.cnb/scripts/build-fnpack.sh` / `.github/scripts/build-fnpack.sh` / `.gitlab/scripts/build-fnpack.sh`）：

1. 从同一份 Dockerfile.golang 解析 `GO_VERSION` / `DEBIAN_VERSION`，得到同一个 `<go 版本>` 标签（两侧解析的是同一个上游浮动引用 `golang:1-trixie`；若上游恰好在两条流水线之间发了新版，fnpack 会因找不到对应标签而安全失败，次日自动对齐）。
2. 等 `golang:<go 版本>` 在 registry 出现（两侧都靠错开的定时任务保证）。
3. 读取基础镜像的 index digest。
4. 构建并推送 `golang/fnpack:<go 版本>`（`GOLANG_IMAGE` 指向基础镜像标签）。
5. 派生 fnpack 的单平台标签。
6. amd64 冒烟（fnpack 存在且可执行、工具链继承成功）。
7. 校验 OCI `version` 标签。
8. 只有基础镜像的 `<major.minor>` / `latest` 也指向本次版本时，才提升 fnpack 的对应标签。
9. 写 fnpack 元数据。

wails3 镜像（`.cnb/scripts/build-wails3.sh` / `.github/scripts/build-wails3.sh` / `.gitlab/scripts/build-wails3.sh`）：

1. 解析同一个 `<go 版本>` 标签。
2. 确定 `WAILS3_VERSION`：输入优先；留空时先用 `go list -m github.com/wailsapp/wails/v3@latest` 解析最新稳定 tag（走基座 Dockerfile 的 `GOPROXY`），解析不到才回退 `latest` 交给 `go install`。
3. 等 `golang:<go 版本>` 在 registry 出现，并读取它的 index digest。
4. 构建并推送 `golang/wails3:<go 版本>`（`GOLANG_IMAGE` 指向基础镜像标签，`WAILS3_VERSION` 以 `--build-arg` 传入）。
5. 派生 wails3 的单平台标签。
6. amd64 冒烟（见下）。
7. 校验 OCI `version` 标签。
8. 只有基础镜像的 `<major.minor>` / `latest` 也指向本次版本时，才提升 wails3 的对应标签。
9. 写 wails3 元数据（含 `wails3_version`）。

wails2 镜像（`.cnb/scripts/build-wails2.sh` / `.github/scripts/build-wails2.sh` / `.gitlab/scripts/build-wails2.sh`）与 wails3 同构：解析 `WAILS2_VERSION`（`go list -m github.com/wailsapp/wails/v2@latest`）→ 等基座 → 构建推送 `golang/wails2:<go 版本>` → 派生单平台标签 → 冒烟 → 受基座约束地提升移动标签 → 写元数据。

fyne 镜像（`.cnb/scripts/build-fyne.sh` / `.github/scripts/build-fyne.sh` / `.gitlab/scripts/build-fyne.sh`）同样与 wails3 同构：

1. 解析同一个 `<go 版本>` 标签。
2. 确定 `FYNE_VERSION`：输入优先；留空时先用 `go list -m fyne.io/tools@latest` 解析最新稳定 tag（走基座 Dockerfile 的 `GOPROXY`），解析不到才回退 `latest` 交给 `go install`。
3. 等 `golang:<go 版本>` 在 registry 出现，并读取它的 index digest。
4. 构建并推送 `golang/fyne:<go 版本>`（`GOLANG_IMAGE` 指向基础镜像标签，`FYNE_VERSION` 以 `--build-arg` 传入）。
5. 派生 fyne 的单平台标签。
6. amd64 冒烟（见下）。
7. 校验 OCI `version` 标签。
8. 只有基础镜像的 `<major.minor>` / `latest` 也指向本次版本时，才提升 fyne 的对应标签。
9. 写 fyne 元数据（含 `fyne_version`）。

mygo 镜像（`.cnb/scripts/build-mygo.sh` / `.github/scripts/build-mygo.sh` / `.gitlab/scripts/build-mygo.sh`）与 fyne 同构，只是多解析一个版本：

1. 解析同一个 `<go 版本>` 标签。
2. 确定 `MYGO_VERSION` 与 `BUN_VERSION`：输入优先；留空时先用 `go list -m github.com/egoist/mygo@latest` 解析 mygo 最新稳定 tag、用 `npm view bun version` 解析 bun 最新稳定版（都走基座镜像的 GOPROXY / npm 源），解析不到才各自回退 `latest`。
3. 等 `golang:<go 版本>` 在 registry 出现，并读取它的 index digest。
4. 构建并推送 `golang/mygo:<go 版本>`（`GOLANG_IMAGE` 指向基础镜像标签，`MYGO_VERSION` / `BUN_VERSION` 以 `--build-arg` 传入）。
5. 派生 mygo 的单平台标签。
6. amd64 冒烟（见下）。
7. 校验 OCI `version` 标签。
8. 只有基础镜像的 `<major.minor>` / `latest` 也指向本次版本时，才提升 mygo 的对应标签。
9. 写 mygo 元数据（含 `mygo_version` / `bun_version`）。

gio 镜像（`.cnb/scripts/build-gio.sh` / `.github/scripts/build-gio.sh` / `.gitlab/scripts/build-gio.sh`）与 mygo 同构，同样在构建前解析版本：

1. 解析同一个 `<go 版本>` 标签。
2. 确定 `GIO_VERSION`：输入优先；留空时先用 `go list -m gioui.org/cmd@latest` 解析 gogio CLI 最新稳定 tag（走基座镜像的 GOPROXY），解析不到才回退 `latest`。
3. 等 `golang:<go 版本>` 在 registry 出现，并读取它的 index digest。
4. 构建并推送 `golang/gio:<go 版本>`（`GOLANG_IMAGE` 指向基础镜像标签，`GIO_VERSION` 以 `--build-arg` 传入）。
5. 派生 gio 的单平台标签。
6. amd64 冒烟（见下）。
7. 校验 OCI `version` 标签。
8. 只有基础镜像的 `<major.minor>` / `latest` 也指向本次版本时，才提升 gio 的对应标签。
9. 写 gio 元数据（含 `gio_version`）。

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

wails2 镜像：

- `go version` 与解析出的版本一致
- `go node pnpm sqlc golangci-lint zip unzip pkg-config` 都存在（证明继承成功）
- `pkg-config --exists gtk+-3.0` 与 `pkg-config --exists webkit2gtk-4.1` 都成立
- `wails` 在 `PATH` 里，且 `go version -m` 读到的 `github.com/wailsapp/wails/v2` 模块版本等于本次目标版本
- `fnpack` **不存在**

fyne 镜像：

- `go version` 与解析出的版本一致
- `go node pnpm sqlc golangci-lint zip unzip pkg-config` 都存在（证明继承成功，且编译/打包依赖齐全）
- `pkg-config --exists` 对 `gl` / `x11` / `xrandr` / `xcursor` / `xinerama` / `xi` / `xxf86vm` / `wayland-client` / `xkbcommon` 全部成立
- `fyne` 在 `PATH` 里，且 `go version -m` 读到的 `fyne.io/tools` 模块版本等于本次目标版本（回退 `latest` 时只验证可执行）
- `fnpack` 与 `wails3` 都**不存在**（这是 golang + fyne，不是别的变体）

mygo 镜像：

- `go version` 与解析出的版本一致
- `go node npm pnpm bun sqlc golangci-lint zip unzip pkg-config Xvfb` 都存在（证明继承成功，且编译/无头运行依赖齐全）
- `pkg-config --exists` 对 `gtk+-3.0` / `webkit2gtk-4.1` / `gl` / `x11` / `xrandr` / `xcursor` / `xinerama` / `xi` / `xxf86vm` / `wayland-client` / `xkbcommon` 全部成立
- `ldconfig -p` 能查到 `libgtk-3.so.0` / `libwebkit2gtk-4.1.so.0` / `libayatana-appindicator3.so.1` / `libglib-2.0.so.0`（运行期 `dlopen` 的库，编译期装了不等于运行期能加载）
- `mygo` 在 `PATH` 里，且 `go version -m` 读到的 `github.com/egoist/mygo` 模块版本等于本次目标版本（回退 `latest` 时只验证可执行）
- `mygo doctor` 能跑通，输出里能 grep 到 `gtk` 与 `webkit`
- `bun --version` 等于本次目标版本（回退 `latest` 时只验证可执行）
- `fnpack` / `wails3` / `wails` / `fyne` 都**不存在**（这是 golang + mygo，不是别的变体）

gio 镜像：

- `go version` 与解析出的版本一致
- `go node npm pnpm sqlc golangci-lint gogio gcc pkg-config Xvfb` 都存在（证明继承成功，且 cgo 编译/无头运行依赖齐全）
- `pkg-config --exists` 对 `egl` / `glesv2` / `wayland-client` / `wayland-cursor` / `wayland-egl` / `x11` / `x11-xcb` / `xkbcommon` / `xkbcommon-x11` / `xcursor` / `xfixes` / `xrandr` / `xinerama` / `xi` / `xxf86vm` / `libffi` / `vulkan` 全部成立
- `ldconfig -p` 能查到 `libEGL.so.1` / `libGL.so.1` / `libvulkan.so.1` / `libwayland-client.so.0` / `libxkbcommon.so.0` / `libX11.so.6`
- `gogio` 在 `PATH` 里，且 `go version -m "$(command -v gogio)"` 读到的 `gioui.org/cmd` 模块版本等于本次目标版本（回退 `latest` 时只验证可执行）；`gogio` **没有 `version` 子命令**，无参数运行会打 usage 到 stderr 且非零退出，脚本里必须 `|| true`
- `fnpack` / `wails3` / `wails` / `fyne` / `mygo` / `bun` 都**不存在**（这是 golang + gio，不是别的变体）

### 缓存

三侧都启用 **buildx 层缓存**，写到 `<镜像>:buildcache`（CNB 制品库 / GHCR / GitLab Registry 各一份），`mode=min`：单阶段构建，每一层都在最终镜像里，min 已覆盖整条链，而且不会产生没人引用的孤儿 blob。

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

| 平台   | 镜像   | 入口                                                      | 输入                                  |
|--------|--------|-----------------------------------------------------------|---------------------------------------|
| CNB    | golang | 仓库页面按钮「打包 Golang 镜像」                          | `version`：留空 / 1.27 / 1.27.3       |
| CNB    | fnpack | 仓库页面按钮「打包 Golang + fnpack 镜像」                 | 同上                                  |
| CNB    | fyne   | 仓库页面按钮「打包 Golang + fyne 镜像」                   | 同上 + `fyne_version`                 |
| CNB    | mygo   | 仓库页面按钮「打包 Golang + mygo 镜像」                   | 同上 + `mygo_version` / `bun_version` |
| CNB    | gio    | 仓库页面按钮「打包 Golang + gio 镜像」                    | 同上 + `gio_version`                  |
| GitHub | golang | Actions → build-golang → Run workflow                     | 同上                                  |
| GitHub | fnpack | Actions → build-fnpack → Run workflow（需基础镜像已存在） | 同上                                  |
| GitHub | fyne   | Actions → build-fyne → Run workflow（需基础镜像已存在）   | 同上 + `fyne_version`                 |
| GitHub | mygo   | Actions → build-mygo → Run workflow（需基础镜像已存在）   | 同上 + `mygo_version` / `bun_version` |
| GitHub | gio    | Actions → build-gio → Run workflow（需基础镜像已存在）    | 同上 + `gio_version`                  |
| GitLab | 任意   | CI/CD → Pipelines → Run pipeline                          | `TARGET` 选镜像；`VERSION` 同上       |
| GitLab | golang | 定时 schedule，`TARGET=golang`                            | `VERSION`：留空 / 1.27 / 1.27.3       |
| GitLab | fnpack | 定时 schedule，`TARGET=fnpack`（需基础镜像已存在）        | 同上 + `FNPACK_VERSION`               |
| GitLab | fyne   | 定时 schedule，`TARGET=fyne`（需基础镜像已存在）          | 同上 + `FYNE_VERSION`                 |
| GitLab | mygo   | 定时 schedule，`TARGET=mygo`（需基础镜像已存在）          | 同上 + `MYGO_VERSION` / `BUN_VERSION` |
| GitLab | gio    | 定时 schedule，`TARGET=gio`（需基础镜像已存在）           | 同上 + `GIO_VERSION`                  |

留空表示使用 Dockerfile 的默认值：`golang:1-trixie` 自动跟随最新稳定 Go。填 `1.27` 会跟随该 minor 的最新补丁，填 `1.27.3` 精确到补丁版本。标签里的版本始终是解析后的实际版本。
