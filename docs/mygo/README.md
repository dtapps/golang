# Golang 构建环境 + mygo 镜像

[![定时构建](https://cnb.cool/dtapp/golang/-/badge/git/latest/ci/status/crontab)](https://cnb.cool/dtapp/golang/-/pipeline) [![流水线配置](https://cnb.cool/dtapp/golang/-/badge/git/latest/ci/pipeline-as-code)](https://cnb.cool/dtapp/golang/-/blob/main/.cnb.yml) [![漏洞扫描](https://cnb.cool/dtapp/golang/-/badge/security/vulnerability/full/latest)](https://cnb.cool/dtapp/golang/-/security) ![基础镜像](https://img.shields.io/badge/base-golang-00ADD8?logo=go&logoColor=white) ![mygo](https://img.shields.io/badge/mygo-v0.8.1-blue) ![架构](https://img.shields.io/badge/arch-amd64%20%7C%20arm64-informational) ![mygo 版本](https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/mygo_version) ![镜像大小](https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/mygo_size) ![arm64 大小](https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/mygo_size_arm64) ![镜像摘要](https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/mygo_digest_short) ![镜像版本](https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/image_version)

在 [Golang 构建环境镜像](../golang/README.md) 之上做三件事：装编译 / 运行 [MyGo](https://github.com/egoist/mygo) 应用所需的系统依赖（GTK3 + WebKitGTK 4.1 开发包与无头运行库），再 `go install` 一份 `mygo` CLI，最后用 npm 装上前端模板要用的 `bun`。用于在 CI / 容器里编译 MyGo 桌面应用。

> **本目录的分工**：mygo 镜像 = 基座镜像 + GTK3/WebKitGTK 4.1 开发包与无头运行库 + `mygo` CLI + `bun`，所以这里只收 mygo 专属的内容（版本策略、构建用法、元数据）。构建、CI、标签、镜像源、维护、排错等共用机制都在 [`docs/golang/`](../golang/index.md)，不在这里重复。文档与实现冲突时，以三份 `Dockerfile.mygo` 与三份 `build-mygo.sh` 为准。

## 镜像里有什么

- 基座：本仓库构建的 Golang 构建环境镜像（CI 按 `<go 版本>` 钉住当天刚推好的那份；Dockerfile 默认基座是官方 `golang:1-trixie`，只用于不依赖私有仓库的本地构建）
- 继承基座全部内容：Go 工具链、UPX、nfpm、Node.js + npm + pnpm、sqlc / ent / golangci-lint / govulncheck / shfmt / dockerfmt / yamlfmt / gojq / sql-formatter / gotestsum / markdownfmt / gocover-cobertura / gcov2lcov / task、wixl、git / curl / make / jq / zip / unzip / pkg-config、`TZ=Asia/Shanghai` 与 `C.UTF-8`
- 新增系统包：`pkg-config`、`gcc`、`libgtk-3-dev`、`libwebkit2gtk-4.1-dev`、`libayatana-appindicator3-dev`、`libgl1-mesa-dev`、`xorg-dev`、`libwayland-dev`、`libxkbcommon-dev`，以及无头运行环境 `xvfb`、`xauth`、`dbus-x11`、`libgl1`、`libgl1-mesa-dri`、`libglx-mesa0`、`libegl-mesa0`、`fonts-dejavu-core`，以及 WebKit TLS / 图标 / 系统功能 / 文字渲染包 `libnss3`、`libnspr4`、`glib-networking`、`librsvg2-common`、`libgdk-pixbuf-2.0-dev`、`adwaita-icon-theme`、`libsecret-1-dev`、`libnotify-dev`、`libdbus-1-dev`、`libharfbuzz-dev`、`libpango1.0-dev`
- 新增 CLI：`/go/bin/mygo`（`GOPATH=/go`，已在 `PATH` 里）与 `bun`（`npm install -g bun@<BUN_VERSION>`）

为什么是这一组包：

- mygo 的 Linux 后端是**纯 Go、不带 cgo**：它用 `github.com/ebitengine/purego` 在运行期 `dlopen` GTK3 / WebKitGTK，所以镜像里必须有运行库本体——`libgtk-3.so.0`、`libwebkit2gtk-4.1.so.0`、`libayatana-appindicator3.so.1`，缺了 `mygo doctor` 直接报错。
- `-dev` 包同时提供 `.pc` 文件与头文件，并顺带把上面的运行库装上：用户应用可能自己带 cgo 绑定，编译期要能解析 `gtk+-3.0` / `webkit2gtk-4.1` 等 `.pc`。一份包同时满足编译与运行。
- 无头包（Xvfb + mesa + 字体）让 GUI 冒烟在没有显示器的 CI 里也能跑，与上游 mygo 的 CI 装的是同一组包。

装完立刻断言一遍 `.pc` 与运行库：

```sh
pkg-config --exists gtk+-3.0
pkg-config --exists webkit2gtk-4.1
pkg-config --exists gl
pkg-config --exists x11
pkg-config --exists xrandr
pkg-config --exists xcursor
pkg-config --exists xinerama
pkg-config --exists xi
pkg-config --exists xxf86vm
pkg-config --exists wayland-client
pkg-config --exists xkbcommon
ldconfig -p | grep -q 'libgtk-3\.so\.0'
ldconfig -p | grep -q 'libwebkit2gtk-4\.1\.so'
ldconfig -p | grep -q 'libayatana-appindicator3\.so\.1'
```

这一步不能省：缺包会让镜像构建直接失败，而不是推迟到使用者手里才以 `dlopen` 失败的形式暴露。

## mygo 版本策略

镜像里的 mygo 就一条命令装出来的：

```dockerfile
go install github.com/egoist/mygo/cmd/mygo@${MYGO_VERSION}
```

`MYGO_VERSION` 指的是这条命令的版本，当前最新稳定 tag 是 `v0.8.1`。默认值 `latest`，不钉死某个 tag。三级兜底：

| 场景                           | 行为                                                                                                               |
|--------------------------------|--------------------------------------------------------------------------------------------------------------------|
| CI 定时任务 / 手动触发留空     | 脚本在构建前用 `go list -m github.com/egoist/mygo@latest` 解析最新稳定 tag（如 `v0.8.1`），再以 `--build-arg` 传入 |
| 手动触发填 `mygo_version`      | 按填的版本装：`v0.8.1` / `0.8.1`（自动补 `v`）都可以                                                               |
| 裸 `docker build`（不经过 CI） | `@latest` 交给 `go install` 自己解析                                                                               |

为什么要先在 CI 里解析成具体版本：buildx 的层缓存按 build-arg 的**值**算缓存键。每天都传字符串 `latest`，缓存键永远不变，编译 `mygo` 的那一层会一直命中第一次的产物，mygo 再也不升级。解析成 `v0.8.1` 之后，上游没发新版就全命中，发新版才重建那一层。

解析失败（GOPROXY 网络问题）时脚本会 `警告` 并回退 `latest`，本次构建由 Dockerfile 在构建时解析（镜像仍然可用，只是层缓存不生效、元数据里的 `mygo_version` 会记成 `latest`）。

**解析到的版本会写进元数据 `mygo_version`，但不占标签**——标签里的版本是 Go 版本，与基座同名标签一一对应。

### bun 版本策略

`bun` 单独走一条版本线：Dockerfile 里 `ARG BUN_VERSION=latest`，安装命令是 `npm install -g bun@${BUN_VERSION}`。CI 构建前用 `npm view bun version`（在基座镜像里问 npm，源与安装时同一个）解析最新稳定版（如 `1.4.4`）再传 `--build-arg`，解析失败同样回退 `latest`。装到的版本写进元数据 `bun_version`，也不占标签。

### 两个容易踩的坑

- **依赖是 GTK3 + WebKitGTK 4.1，不是 GTK4 / WebKitGTK 6.0**。后者是 `wails3` 镜像的那一套；mygo 与 `wails2` 用同一组运行库，但 mygo 编译不需要 `-tags webkit2_41`（它运行期 dlopen，不做 cgo 链接）。
- **`bun` 不是 mygo 的硬依赖**。mygo 自己只用到 `go`；`bun` 是 `mygo init` 默认 Web 前端模板的 `DevCommand` / `BuildCommand`（`bun run ...`）需要的，装它是为了让默认模板开箱即用。`bun_version` 是 npm 上 `bun` 包的版本，与 mygo 版本互不相干。

## 地址与标签

| 平台   | 地址                                     |
|--------|------------------------------------------|
| CNB    | `docker.cnb.cool/dtapp/golang/mygo`      |
| GitHub | `ghcr.io/dtapps/golang/mygo`             |
| GitLab | `registry.gitlab.com/dtapps/golang/mygo` |

标签与基座同一套契约：`<go 版本>` / `<major.minor>` / `latest` / `<go 版本>-linux-{amd64,arm64}`。`<major.minor>` / `latest` 只在基座对应标签已指向同一 digest 时提升，所以 mygo 的移动标签永远不会跑到基座前面。完整契约见 [../golang/images-and-tags.md](../golang/images-and-tags.md)。

mygo 与 bun 自身的版本**不占标签**：要复现某一份产物请用元数据里的 `mygo_digest`，要回到某个 mygo 版本请手动触发并填 `mygo_version`。

## 快速使用

```bash
docker run --rm ghcr.io/dtapps/golang/mygo:latest mygo version
docker run --rm ghcr.io/dtapps/golang/mygo:latest mygo doctor
docker run --rm -v "$PWD":/src -w /src ghcr.io/dtapps/golang/mygo:latest mygo build
```

作为 CI 的基础镜像：

```dockerfile
FROM ghcr.io/dtapps/golang/mygo:latest
# 已含 GTK3 / WebKitGTK 4.1 开发包、无头运行库、mygo CLI 与 bun
```

用 `latest` / `<major.minor>` 时拿到的是当天构建；要固定产物就把元数据里的 `mygo_digest` 拿来用：

```bash
docker pull ghcr.io/dtapps/golang/mygo@sha256:<mygo_digest>
```

`mygo doctor` 是上游自带的自检命令：硬性项查 `go`、GTK3 与 WebKitGTK（项目没声明 `linux.webview: false` 时查），`bun` 与 `makensis` / `osslsigncode` / `gh` / `codesign` 只列为可选。GUI 冒烟需要显示环境，容器里没有显示器时用镜像自带的 `Xvfb` 起一个。跨平台交叉编译（Windows / macOS / 移动端）不在本镜像范围内。

## 怎么构建

- CNB：`.cnb/workflows/build-mygo.yml`，每天 15:05 由 `.cnb.yml` 定时触发（基座 00:05、fnpack 03:05、wails3 06:05、fyne 12:05 之后）；也可用「打包 Golang + mygo 镜像（多架构）」按钮手动触发，可填 `version` / `mygo_version` / `bun_version`。
- GitHub：`.github/workflows/build-mygo.yml`，每天 07:05 UTC（北京 15:05）定时触发（基座 16:05 UTC、fnpack 19:05 UTC、wails3 22:05 UTC、fyne 04:05 UTC 之后）；手动触发同样可填 `version` / `mygo_version` / `bun_version`。
- GitLab：`.gitlab/workflows/build-mygo.yml`，在 UI / API 建 `TARGET=mygo` 的 schedule 定时触发（基座先构建）；手动 Run pipeline 时填 `TARGET=mygo`，可再填 `VERSION` / `MYGO_VERSION` / `BUN_VERSION`，见 [../gitlab.md](../gitlab.md)。

脚本先等 `golang:<go 版本>` 就绪（最多 20 × 15 秒，等不到直接失败），再从它构建、派生单平台标签、跑冒烟、提升移动标签。冒烟断言：

- `go version` 与基座一致；`go` / `node` / `npm` / `pnpm` / `bun` / `sqlc` / `golangci-lint` / `zip` / `unzip` / `pkg-config` / `Xvfb` 都在
- `pkg-config --exists` 对 `gtk+-3.0` / `webkit2gtk-4.1` / `gl` / `x11` / `xrandr` / `xcursor` / `xinerama` / `xi` / `xxf86vm` / `wayland-client` / `xkbcommon` 全部成立
- `ldconfig -p` 能查到 `libgtk-3.so.0` / `libwebkit2gtk-4.1.so.0` / `libayatana-appindicator3.so.1` / `libglib-2.0.so.0`（运行期 dlopen 的库，编译期装了不等于运行期能加载）
- `mygo` 可执行，且 `go version -m <mygo 二进制>` 里的 `github.com/egoist/mygo` 版本等于本次目标版本（回退 `latest` 时只验证可执行）
- `mygo doctor` 能跑通，输出里能 grep 到 `gtk` 与 `webkit`
- `bun --version` 等于本次目标版本（回退 `latest` 时只验证可执行）
- 基座里不该出现的 `fnpack` / `wails3` / `wails` / `fyne` 依旧不存在

任何一步失败都会停在原地：`latest` / `<major.minor>` 不动。

## 元数据与徽章

CNB 侧写 `.cnb/annotation-mygo.json`，GitHub 侧写 `.github/annotation-mygo.json`，GitLab 侧写 `.gitlab/annotation-mygo.json`（都不入库）。

| 键                  | 含义                                                                  |
|---------------------|-----------------------------------------------------------------------|
| `mygo_image`        | mygo 镜像全名                                                         |
| `mygo_digest`       | mygo manifest list digest                                             |
| `mygo_digest_short` | 前 12 位 digest（只用于核对）                                         |
| `mygo_size`         | amd64 压缩体积                                                        |
| `mygo_size_arm64`   | arm64 压缩体积                                                        |
| `mygo_version`      | 本次安装的 mygo CLI 版本（如 `v0.8.1`）                               |
| `bun_version`       | 本次安装的 bun 版本（如 `1.4.4`）                                     |
| `image_version`     | 解析出的 Go 版本（与 `<go 版本>` 标签一致）                           |
| `golang_version`    | 同上                                                                  |
| `mygo_base_image`   | 本次使用的基础镜像引用                                                |
| `mygo_base_digest`  | 基础镜像 digest                                                       |
| `apt_versions`      | apt 装的系统包版本（`包=版本`，缺包标 `absent`；清单取自 Dockerfile） |
| `built_at`          | 本次构建时间                                                          |
| `source_date`       | 最后一次提交时间                                                      |

徽章全部从 CNB commit annotation 取值，地址模板：

```text
https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/{key}
```

本页顶部那排徽章对应的 key：

| 徽章       | key                 | 说明                                 |
|------------|---------------------|--------------------------------------|
| mygo 版本  | `mygo_version`      | 如 `v0.8.1`；回退解析时显示 `latest` |
| 镜像大小   | `mygo_size`         | amd64 压缩体积                       |
| arm64 大小 | `mygo_size_arm64`   | arm64 压缩体积                       |
| 镜像摘要   | `mygo_digest_short` | 前 12 位，只用于核对，不能用于 pull  |
| 镜像版本   | `image_version`     | Go 版本，与 `<go 版本>` 标签一致     |

直接贴到自己 README 里可用（把 `{key}` 换成上表的值）：

```markdown
![mygo 版本](https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/mygo_version)
![镜像大小](https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/mygo_size)
![镜像摘要](https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/mygo_digest_short)
```

几个使用注意：

- `commit/latest` 是「最新提交」这一维度，与镜像标签 `latest` 同名但无关。
- `type: ADD` 对同一 commit 是覆盖语义：同名 key 只保留最后一次构建。要长期锁定某次产物，记下当时的 `mygo_digest` 并按 digest 拉取。
- 徽章显示灰色 `unknown` 通常意味着：这次构建失败（`cnbcool/annotations` 那步没跑）、key 从未写入，或体积解析拿到了非镜像清单（日志里会有「体积解析失败」警告）。
- GitHub 侧不写 commit 注解：同样的 JSON 写进 Step Summary，并上传 artifact `mygo-annotation`（保留 30 天）。GitLab 侧同样不写 commit 注解，JSON 作为 job artifact 保留 30 天。跨平台核对以 artifact 为准。

## 七个镜像的关系

同一 `<go 版本>` 下：

```text
golang:1.27.3        = 基座 + 全部工具链
golang/fnpack:1.27.3 = golang:1.27.3 + fnpack
golang/wails3:1.27.3 = golang:1.27.3 + GTK4/WebKitGTK + wails3
golang/wails2:1.27.3 = golang:1.27.3 + GTK3/WebKit2GTK 4.1 + wails
golang/fyne:1.27.3   = golang:1.27.3 + OpenGL/X11/Wayland + fyne
golang/mygo:1.27.3   = golang:1.27.3 + GTK3/WebKitGTK 4.1 + 无头运行库 + mygo + bun
golang/gio:1.27.3    = golang:1.27.3 + EGL/GLES/X11/Wayland/Vulkan 开发包 + 无头运行库 + gogio
```

fnpack、wails3、wails2、fyne、mygo 与 gio 是六个**平级**的变体，互不包含：需要打包 `.fpk` 用 `fnpack`，编译 Wails v3 应用用 `wails3`，编译 Wails v2 应用用 `wails2`，编译 Fyne 应用用 `fyne`，编译 MyGo 应用用 `mygo`，用 cgo 编译 Gio 应用用 `gio`；都要就在自己 Dockerfile 里 `FROM golang:latest` 再各装一个。

注意 mygo 与 wails2 的 GTK3 / WebKitGTK 4.1 运行库是同一套，但两者 CLI 不同、编译方式也不同：wails2 要开 cgo 并加 `-tags webkit2_41`，mygo 纯 Go、运行期 dlopen。所以不能用 wails2 镜像替代 mygo 镜像。

gio 与本镜像都用无头运行库（Xvfb + mesa + 字体），但图形栈完全不同：mygo 走 GTK3 + WebKitGTK 4.1（纯 Go、运行期 `dlopen`），gio 走 EGL/GLES + X11/Wayland + Vulkan（cgo 编译期链接）。两个镜像不能互相替代。
