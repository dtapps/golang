# Golang 构建环境 + gio 镜像

[![定时构建](https://cnb.cool/dtapp/golang/-/badge/git/latest/ci/status/crontab)](https://cnb.cool/dtapp/golang/-/pipeline) [![流水线配置](https://cnb.cool/dtapp/golang/-/badge/git/latest/ci/pipeline-as-code)](https://cnb.cool/dtapp/golang/-/blob/main/.cnb.yml) [![漏洞扫描](https://cnb.cool/dtapp/golang/-/badge/security/vulnerability/full/latest)](https://cnb.cool/dtapp/golang/-/security) ![基础镜像](https://img.shields.io/badge/base-golang-00ADD8?logo=go&logoColor=white) ![gogio](https://img.shields.io/badge/gogio-v0.10.3-blue) ![架构](https://img.shields.io/badge/arch-amd64%20%7C%20arm64-informational) ![gogio 版本](https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/gio_version) ![镜像大小](https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/gio_size) ![arm64 大小](https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/gio_size_arm64) ![镜像摘要](https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/gio_digest_short) ![镜像版本](https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/image_version)

在 [Golang 构建环境镜像](../golang/README.md) 之上做三件事：装编译 [Gio](https://gioui.org) 桌面程序所需的系统依赖（EGL/GLES、X11、Wayland、Vulkan 开发包与无头运行库），再 `go install` 一份 `gogio` CLI，最后在构建期真的编译并链接一个最小 Gio 程序做校验。用于在 CI / 容器里用 cgo 编译 Gio 桌面应用。

> **变体叫 gio，CLI 叫 `gogio`，别去找 `gio` 二进制**：镜像里只有 `/go/bin/gogio`（模块 `gioui.org/cmd`），没有叫 `gio` 的命令。`gogio` 是**打包**工具，`-target` 支持 `android` / `ios` / `tvos` / `js` / `windows` / `macos`，**没有 linux 目标**，也**没有 `version` 子命令**（无参数运行只打印 usage 到 stderr 并非零退出）。Linux 桌面程序就是普通 `go build` + cgo，不需要 `gogio`。所以这个镜像的价值不在 `gogio` 这个二进制，而在 **cgo 依赖齐全**——Dockerfile 第 1 层把 EGL/GLES、X11、Wayland、Vulkan 开发包装齐，并用 `pkg-config --exists` 逐个断言 `.pc` 存在，缺一个就构建失败。

> **本目录的分工**：gio 镜像 = 基座镜像 + EGL/GLES、X11、Wayland、Vulkan 开发包与无头运行库 + `gogio` CLI，所以这里只收 gio 专属的内容（版本策略、构建用法、元数据）。构建、CI、标签、镜像源、维护、排错等共用机制都在 [`docs/golang/`](../golang/index.md)，不在这里重复。文档与实现冲突时，以三份 `Dockerfile.gio` 与三份 `build-gio.sh` 为准。

## 镜像里有什么

- 基座：本仓库构建的 Golang 构建环境镜像（CI 按 `<go 版本>` 钉住当天刚推好的那份；Dockerfile 默认基座是官方 `golang:1-trixie`，只用于不依赖私有仓库的本地构建）
- 继承基座全部内容：Go 工具链、UPX、nfpm、Node.js + npm + pnpm、sqlc / ent / golangci-lint / govulncheck / shfmt / dockerfmt / yamlfmt / gojq / sql-formatter / gotestsum / markdownfmt / gocover-cobertura / gcov2lcov / task、wixl、git / curl / make / jq / zip / unzip / pkg-config、`TZ=Asia/Shanghai` 与 `C.UTF-8`
- 新增系统包：`pkg-config`、`gcc`、`libegl1-mesa-dev`、`libgles2-mesa-dev`、`libx11-dev`、`libx11-xcb-dev`、`libxcursor-dev`、`libxfixes-dev`、`libxrandr-dev`、`libxinerama-dev`、`libxi-dev`、`libxxf86vm-dev`、`libwayland-dev`、`libxkbcommon-dev`、`libxkbcommon-x11-dev`、`libffi-dev`、`libvulkan-dev`，以及无头运行环境 `xvfb`、`xauth`、`dbus-x11`、`libgl1-mesa-dri`、`libglx-mesa0`、`libegl-mesa0`、`mesa-vulkan-drivers`、`fonts-dejavu-core`
- 新增 CLI：`/go/bin/gogio`（`GOPATH=/go`，已在 `PATH` 里；`go install gioui.org/cmd/gogio@<GIO_VERSION>`）

为什么是这一组包：

- 其中十个 `.pc`（`egl` / `wayland-egl` / `wayland-client` / `wayland-cursor` / `x11` / `x11-xcb` / `xkbcommon` / `xkbcommon-x11` / `xcursor` / `xfixes`）直接对应 gioui.org 源码里的 cgo 指令，是**编译期硬依赖**，缺一个就编不过，不是等到运行期才报错。
- 另外七个（`glesv2` / `xrandr` / `xinerama` / `xi` / `xxf86vm` / `libffi` / `vulkan`）来自官方安装文档与上游 CI：gio 自己不用 pkg-config 找它们（GLES 是运行期 `dlopen` `libGLESv2.so.3.0` / `libGLESv2.so.2`，Vulkan 只 include 头文件、运行期 `dlopen` 加载器），但使用者项目常带 X11 扩展、libffi、Vulkan 的 cgo 绑定，官方文档与上游 CI 就是这么装的，镜像照装并一并断言，省得使用者再往镜像里加包。
- 清单是三处取并集，逐项在 Debian trixie 的 amd64 与 arm64 索引里核对过：gioui.org v0.10.3 源码里的 cgo 指令（上面那十个）、官方安装文档 https://gioui.org/doc/install/linux 的 apt 列表、上游 CI（`.builds/linux.yml`）额外装的 `libxkbcommon-dev` / `libxrandr-dev` / `libxinerama-dev` / `libxi-dev` / `libxxf86vm-dev` / `mesa-vulkan-drivers` / `xvfb`。
- `libvulkan-dev` 提供 `vulkan/vulkan.h` 与加载器 `libvulkan.so.1`（gio 用 `VK_NO_PROTOTYPES` 只要头文件，函数在运行期 `dlopen` 加载器再取指针）；`mesa-vulkan-drivers` 提供真正的 ICD 驱动，没有它加载器找不到可用设备。编译期与运行期各要一样东西，两个都得装。
- 这些 `-dev` 包既是编译依赖也是运行依赖（`-dev` 会把运行库一起装上），必须留在镜像里，不能在构建末尾卸载。
- 无头包（Xvfb + mesa + DRI 驱动 + 字体）让 GUI 冒烟在没有显示器的 CI 里也能跑。

装完立刻断言一遍 `.pc` 与运行库：

```sh
pkg-config --exists egl
pkg-config --exists glesv2
pkg-config --exists wayland-client
pkg-config --exists wayland-cursor
pkg-config --exists wayland-egl
pkg-config --exists x11
pkg-config --exists x11-xcb
pkg-config --exists xkbcommon
pkg-config --exists xkbcommon-x11
pkg-config --exists xcursor
pkg-config --exists xfixes
pkg-config --exists xrandr
pkg-config --exists xinerama
pkg-config --exists xi
pkg-config --exists xxf86vm
pkg-config --exists libffi
pkg-config --exists vulkan
ldconfig -p | grep -q 'libEGL\.so\.1'
ldconfig -p | grep -q 'libGL\.so\.1'
ldconfig -p | grep -q 'libvulkan\.so\.1'
ldconfig -p | grep -q 'libwayland-client\.so\.0'
ldconfig -p | grep -q 'libxkbcommon\.so\.0'
ldconfig -p | grep -q 'libX11\.so\.6'
```

这一步不能省：缺任何一个 `.pc`（编译期）或 `-l` 库（链接期）都会让镜像构建直接失败，而不是推迟到使用者手里才以 cgo 报错的形式暴露。

## gio 版本策略

镜像里只装一个上游二进制，因此只有**一条版本线**，对应一个 `ARG`：

| 变量          | 模块            | 装的东西                                                     | 默认值   |
|---------------|-----------------|--------------------------------------------------------------|----------|
| `GIO_VERSION` | `gioui.org/cmd` | `gogio` CLI：`go install gioui.org/cmd/gogio@${GIO_VERSION}` | `latest` |

当前最新稳定 tag 是 `v0.10.3`。默认 `latest`，不钉死某个 tag。三级兜底：

| 场景                           | 行为                                                                                                       |
|--------------------------------|------------------------------------------------------------------------------------------------------------|
| CI 定时任务 / 手动触发留空     | 脚本在构建前用 `go list -m gioui.org/cmd@latest` 解析最新稳定 tag（如 `v0.10.3`），再以 `--build-arg` 传入 |
| 手动触发填版本                 | 按填的版本装：`v0.10.3` / `0.10.3`（自动补 `v`）都可以                                                     |
| 裸 `docker build`（不经过 CI） | `@latest` 交给 `go install` 自己解析                                                                       |

为什么要先在 CI 里解析成具体版本：buildx 的层缓存按 build-arg 的**值**算缓存键。每天都传字符串 `latest`，缓存键永远不变，`go install` 那层会一直命中第一次的产物，gogio 再也不升级。解析成 `v0.10.3` 之后，上游没发新版就全命中，发新版才重建那一层。

解析失败（GOPROXY 网络问题）时脚本会 `警告` 并回退 `latest`，本次构建由 Dockerfile 在构建时解析（镜像仍然可用，只是层缓存不生效、元数据里的 `gio_version` 会记成 `latest`）。

**解析到的版本会写进元数据 `gio_version`，但不占标签**——标签里的版本是 Go 版本，与基座同名标签一一对应。

### 两个容易踩的坑

- **`gioui.org/cmd` 与 `gioui.org` 是两个模块，版本各自演进**。库到了 `v0.10.3` 时 `cmd` 不一定也是 `v0.10.3`，两个 tag 没有同步保证。本镜像只装 `cmd`（`gogio`），库 `gioui.org` 由使用者在自己的项目里 `go get`，装 `gogio` 时模块路径写 `gioui.org/cmd/gogio`，别写成 `gioui.org/gogio`。
- **`gogio` 没有 `version` 子命令，也没有 linux 目标**。想确认版本只能读二进制里的模块信息（`go version -m "$(command -v gogio)"`，找 `mod gioui.org/cmd` 那一行）；想编译 Linux 桌面程序直接 `go build`，不要去找 `gogio -target=linux`（不存在这个目标）。用 `gogio` 打 android / ios / tvos / js / windows / macos 包需要对应的外部 SDK（`ANDROID_HOME` + NDK + `JAVA_HOME`、Xcode 的 `xcrun` 等），本镜像不带这些，那也不在镜像范围内。

## 地址与标签

| 平台   | 地址                                    |
|--------|-----------------------------------------|
| CNB    | `docker.cnb.cool/dtapp/golang/gio`      |
| GitHub | `ghcr.io/dtapps/golang/gio`             |
| GitLab | `registry.gitlab.com/dtapps/golang/gio` |

标签与基座同一套契约：`<go 版本>` / `<major.minor>` / `latest` / `<go 版本>-linux-{amd64,arm64}`。`<major.minor>` / `latest` 只在基座对应标签已指向同一 digest 时提升，所以 gio 的移动标签永远不会跑到基座前面。完整契约见 [../golang/images-and-tags.md](../golang/images-and-tags.md)。

gio 的 `gogio` 版本**不占标签**：要复现某一份产物请用元数据里的 `gio_digest`，要回到某个版本请手动触发并填 `gio_version`。

## 快速使用

```bash
# 镜像里没有 gio 这个二进制；gogio 没有 version 子命令，无参数运行会打 usage 到 stderr
docker run --rm ghcr.io/dtapps/golang/gio:latest gogio 2>&1 | head -5
# 编译一个 Gio 桌面程序（普通 go build + cgo，不经过 gogio）
docker run --rm -v "$PWD":/src -w /src ghcr.io/dtapps/golang/gio:latest go build -o myapp .
# 没有显示器时用镜像自带的 Xvfb 跑
docker run --rm -v "$PWD":/src -w /src ghcr.io/dtapps/golang/gio:latest xvfb-run -a ./myapp
```

作为 CI 的基础镜像：

```dockerfile
FROM ghcr.io/dtapps/golang/gio:latest
# 已含 EGL/GLES、X11、Wayland、Vulkan 开发包、无头运行库与 gogio CLI
```

用 `latest` / `<major.minor>` 时拿到的是当天构建；要固定产物就把元数据里的 `gio_digest` 拿来用：

```bash
docker pull ghcr.io/dtapps/golang/gio@sha256:<gio_digest>
```

构建标签（编译期决定链接哪个窗口后端，与镜像里装了什么无关）：

- `go build -tags nox11 .`：不编 X11 后端，只留 Wayland。
- `go build -tags nowayland .`：不编 Wayland 后端，只留 X11。
- 两个都加会一个窗口后端都不剩（启动时报 `app: no window driver available`），别这么干。默认（不加标签）是两个后端都编进去，运行期按 Wayland → X11 的顺序依次尝试连接，哪个连上就用哪个。
- `-tags novulkan` 去掉 Vulkan 渲染上下文、`-tags noopengl` 去掉 OpenGL/EGL 渲染上下文。默认两个都编进去，运行期按后端各自偏好依次尝试：Wayland 先 EGL 再 Vulkan，X11 先 Vulkan 再 EGL，一个成功就用它。两个标签都加、且两个上下文都没编进去时，窗口能开但拿不到 GPU 上下文（`wayland: no available GPU backends` / `x11: no available GPU backends`）。镜像里两套依赖都装齐，不需要为了「少装东西」而加标签。

GUI 需要显示环境：容器里没有显示器时用镜像自带的 `Xvfb`（`xvfb-run -a <程序>`）或自己挂 X11 / Wayland socket。跨平台打包（Android / iOS / tvOS / JS / Windows / macOS）不在本镜像范围内——`gogio` 能调用，但要另配对应 SDK。

## 怎么构建

- CNB：`.cnb/workflows/build-gio.yml`，每天 18:05 由 `.cnb.yml` 定时触发（基座 00:05、fnpack 03:05、wails3 06:05、fyne 12:05、mygo 15:05 之后，给基座留了十八小时）；也可用「打包 Golang + gio 镜像（多架构）」按钮手动触发，可填 `version` / `gio_version`。
- GitHub：`.github/workflows/build-gio.yml`，每天 10:05 UTC（北京 18:05）定时触发（基座 16:05 UTC、fnpack 19:05 UTC、wails3 22:05 UTC、fyne 04:05 UTC、mygo 07:05 UTC 之后）；手动触发同样可填 `version` / `gio_version`。
- GitLab：`.gitlab/workflows/build-gio.yml`，在 UI / API 建 `TARGET=gio` 的 schedule 定时触发（基座先构建）；手动 Run pipeline 时填 `TARGET=gio`，可再填 `VERSION` / `GIO_VERSION`，见 [../gitlab.md](../gitlab.md)。

脚本先等 `golang:<go 版本>` 就绪（最多 20 × 15 秒，等不到直接失败），再从它构建、派生单平台标签、跑冒烟、提升移动标签。冒烟断言：

- `go version` 与基座一致；`go` / `node` / `npm` / `pnpm` / `sqlc` / `golangci-lint` / `zip` / `unzip` / `pkg-config` / `gcc` / `Xvfb` / `gogio` 都在
- 上面那 17 个 `.pc` 逐个 `pkg-config --exists` 都成立
- `ldconfig -p` 能查到 `libEGL.so.1` / `libGL.so.1` / `libvulkan.so.1` / `libwayland-client.so.0` / `libxkbcommon.so.0` / `libX11.so.6`（运行期 `dlopen` 的库，编译期装了不等于运行期能加载）
- `gogio` 可执行，且 `go version -m <gogio 二进制>` 里的 `gioui.org/cmd` 模块版本等于本次目标版本（回退 `latest` 时只验证可执行）；无参数运行能打出 usage（判据是「有输出」而不是「退出码为 0」）
- 基座里不该出现的 `fnpack` / `wails3` / `wails` / `fyne` / `mygo` / `bun` 依旧不存在

任何一步失败都会停在原地：`latest` / `<major.minor>` 不动。

## 元数据与徽章

CNB 侧写 `.cnb/annotation-gio.json`，GitHub 侧写 `.github/annotation-gio.json`，GitLab 侧写 `.gitlab/annotation-gio.json`（都不入库）。

| 键                 | 含义                                                                  |
|--------------------|-----------------------------------------------------------------------|
| `gio_image`        | gio 镜像全名                                                          |
| `gio_digest`       | gio manifest list digest                                              |
| `gio_digest_short` | 前 12 位 digest（只用于核对）                                         |
| `gio_size`         | amd64 压缩体积                                                        |
| `gio_size_arm64`   | arm64 压缩体积                                                        |
| `gio_version`      | 本次安装的 gogio CLI 版本（模块 `gioui.org/cmd`，如 `v0.10.3`）       |
| `image_version`    | 解析出的 Go 版本（与 `<go 版本>` 标签一致）                           |
| `golang_version`   | 同上                                                                  |
| `gio_base_image`   | 本次使用的基础镜像引用                                                |
| `gio_base_digest`  | 基础镜像 digest                                                       |
| `apt_versions`     | apt 装的系统包版本（`包=版本`，缺包标 `absent`；清单取自 Dockerfile） |
| `built_at`         | 本次构建时间                                                          |
| `source_date`      | 最后一次提交时间                                                      |

徽章全部从 CNB commit annotation 取值，地址模板：

```text
https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/{key}
```

本页顶部那排徽章对应的 key：

| 徽章       | key                | 说明                                  |
|------------|--------------------|---------------------------------------|
| gogio 版本 | `gio_version`      | 如 `v0.10.3`；回退解析时显示 `latest` |
| 镜像大小   | `gio_size`         | amd64 压缩体积                        |
| arm64 大小 | `gio_size_arm64`   | arm64 压缩体积                        |
| 镜像摘要   | `gio_digest_short` | 前 12 位，只用于核对，不能用于 pull   |
| 镜像版本   | `image_version`    | Go 版本，与 `<go 版本>` 标签一致      |

直接贴到自己 README 里可用（把 `{key}` 换成上表的值）：

```markdown
![gogio 版本](https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/gio_version)
![镜像大小](https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/gio_size)
![镜像摘要](https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/gio_digest_short)
```

几个使用注意：

- `commit/latest` 是「最新提交」这一维度，与镜像标签 `latest` 同名但无关。
- `type: ADD` 对同一 commit 是覆盖语义：同名 key 只保留最后一次构建。要长期锁定某次产物，记下当时的 `gio_digest` 并按 digest 拉取。
- 徽章显示灰色 `unknown` 通常意味着：这次构建失败（`cnbcool/annotations` 那步没跑）、key 从未写入，或体积解析拿到了非镜像清单（日志里会有「体积解析失败」警告）。
- GitHub 侧不写 commit 注解：同样的 JSON 写进 Step Summary，并上传 artifact `gio-annotation`（保留 30 天）。GitLab 侧同样不写 commit 注解，JSON 作为 job artifact 保留 30 天。跨平台核对以 artifact 为准。

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

注意 gio 与 fyne 都是「自绘 + OpenGL/EGL」路线，但依赖集合**不同**：fyne 装的是 `libgl1-mesa-dev` + `xorg-dev` 元包（`x11`、`xrandr`、`xcursor`、`xinerama`、`xi`、`xxf86vm` 等由它带进来）+ `libwayland-dev` + `libxkbcommon-dev`；gio 是按 gioui.org 源码里的 cgo 指令逐条列出的精确清单，比 fyne 多 EGL/GLES（`libegl1-mesa-dev` / `libgles2-mesa-dev`）、`libxkbcommon-x11-dev`、`libffi-dev`、`libvulkan-dev`，外加整套无头运行库（Xvfb / xauth / dbus-x11 / mesa DRI 驱动 / 字体），并且多一个 `gogio` 打包工具。所以不能用 fyne 镜像替代 gio 镜像。
