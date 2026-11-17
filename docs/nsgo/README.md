# Golang 构建环境 + nsgo 镜像

[![定时构建](https://cnb.cool/dtapp/golang/-/badge/git/latest/ci/status/crontab)](https://cnb.cool/dtapp/golang/-/pipeline) [![流水线配置](https://cnb.cool/dtapp/golang/-/badge/git/latest/ci/pipeline-as-code)](https://cnb.cool/dtapp/golang/-/blob/main/.cnb.yml) [![漏洞扫描](https://cnb.cool/dtapp/golang/-/badge/security/vulnerability/full/latest)](https://cnb.cool/dtapp/golang/-/security) ![基础镜像](https://img.shields.io/badge/base-golang-00ADD8?logo=go&logoColor=white) ![nsgo](https://img.shields.io/badge/nsgo-CLI-blue) ![架构](https://img.shields.io/badge/arch-amd64%20%7C%20arm64-informational) ![nsgo 版本](https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/nsgo_version) ![镜像大小](https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/nsgo_size) ![arm64 大小](https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/nsgo_size_arm64) ![镜像摘要](https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/nsgo_digest_short) ![镜像版本](https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/image_version)

在 [Golang 构建环境镜像](../golang/README.md) 之上做两件事：装运行 [nsgo](https://github.com/nsgo-dev/nsgo) 桌面程序所需的系统依赖（GTK 4、WebKitGTK 6.0、Pango / Cairo、GStreamer 与无头运行库），再 `go install` 一份 `nsgo` CLI。

> **上游地址是 `github.com/nsgo-dev/nsgo`，不是 `github.com/oneo-me/nsgo`**：旧地址会 301 重定向，但 Go 模块路径以重定向后的仓库为准，写成 `oneo-me` 会解析不到。镜像里装的是 `/go/bin/nsgo`（模块 `github.com/nsgo-dev/nsgo`，命令在 `cmd/nsgo`）。

> **nsgo 在 Linux 上走 GTK4 后端，用 [purego](https://github.com/ebitengine/purego) 在运行期 `dlopen` 系统库，不需要 cgo**。所以镜像的重点不是编译器，而是 **GTK4 / WebKitGTK 6.0 / GStreamer 这套运行库齐全**：Dockerfile 第 1 层用 `pkg-config --exists`、`ldconfig -p` 与 `gst-inspect-1.0` 逐个断言，缺一个就构建失败。`-dev` 包同时保留，方便使用者项目自己写 cgo 绑定。

> **本目录的分工**：nsgo 镜像 = 基座镜像 + GTK4/WebKitGTK 6.0/Pango/Cairo/GStreamer 运行与开发包 + 无头运行库 + `nsgo` CLI，所以这里只收 nsgo 专属的内容（版本策略、构建用法、元数据）。构建、CI、标签、镜像源、维护、排错等共用机制都在 [`docs/golang/`](../golang/index.md)，不在这里重复。文档与实现冲突时，以三份 `Dockerfile.nsgo` 与三份 `build-nsgo.sh` 为准。

## 镜像里有什么

- 基座：本仓库构建的 Golang 构建环境镜像（CI 按 `<go 版本>` 钉住当天刚推好的那份；Dockerfile 默认基座是官方 `golang:1-trixie`，只用于不依赖私有仓库的本地构建）
- 继承基座全部内容：Go 工具链、UPX、nfpm、Node.js + npm + pnpm、sqlc / ent / golangci-lint / govulncheck / shfmt / dockerfmt / yamlfmt / gojq / sql-formatter / gotestsum / markdownfmt / gocover-cobertura / gcov2lcov / task、wixl、git / curl / make / jq / zip / unzip / pkg-config、`TZ=Asia/Shanghai` 与 `C.UTF-8`
- 新增系统包：`pkg-config`、`gcc`、`libgtk-4-dev`、`libwebkitgtk-6.0-dev`、`libglib2.0-dev`、`libpango1.0-dev`、`libcairo2-dev`、`libfontconfig1-dev`、`libgdk-pixbuf-2.0-dev`、`libgstreamer1.0-dev`、`libgstreamer-plugins-base1.0-dev`、`gstreamer1.0-tools`、`gstreamer1.0-plugins-base`、`gstreamer1.0-plugins-good`、`gstreamer1.0-plugins-bad`、`gstreamer1.0-plugins-ugly`、`gstreamer1.0-libav`，以及无头运行环境 `xvfb`、`xauth`、`dbus-x11`、`libgl1-mesa-dri`、`libglx-mesa0`、`libegl-mesa0`、`shared-mime-info`、`adwaita-icon-theme`、`fonts-dejavu-core`
- 新增 CLI：`/go/bin/nsgo`（`GOPATH=/go`，已在 `PATH` 里；`go install github.com/nsgo-dev/nsgo/cmd/nsgo@<NSGO_VERSION>`）

为什么是这一组包：

- `libgtk-4-dev` 是 GTK4 后端的**运行期硬依赖**（purego 直接 `dlopen` `libgtk-4.so.1`），并带进 GLib / GObject / GIO / Pango / Cairo / GdkPixbuf / fontconfig。`libwebkitgtk-6.0-dev` 提供 GTK4 版的 WebView（`libwebkitgtk-6.0.so.4`），nsgo 内嵌网页时要用；两者都是上游 CI 在 Linux runner 上装的同一组包。
- `libgstreamer1.0-dev` 与 `libgstreamer-plugins-base1.0-dev` 提供 GStreamer 的 `pkg-config` 与头文件；运行时还要 `plugins-base` / `plugins-good` / `plugins-bad` / `plugins-ugly` 与 `gstreamer1.0-libav`，否则 H.264 / AAC 这类常见编码没有解码器。镜像用 `gst-inspect-1.0 avdec_h264` / `avdec_aac` 断言 `libav` 插件真的可用——只装 `libgstreamer` 是不够的。
- `gstreamer1.0-tools` 提供 `gst-inspect-1.0`，既是构建期断言工具，也方便使用者排查插件。
- 无头包（Xvfb + mesa + DRI 驱动 + 字体）让 GUI 冒烟在没有显示器的 CI 里也能跑；`shared-mime-info` 与 `adwaita-icon-theme` 是 GTK4 程序启动时的常见运行依赖（缺了会报图标 / MIME 主题警告）。
- 这些 `-dev` 包既是编译依赖也是运行依赖（`-dev` 会把运行库一起装上），必须留在镜像里，不能在构建末尾卸载。

装完立刻断言一遍 `.pc`、运行库与 GStreamer 插件：

```sh
pkg-config --exists gtk4
pkg-config --exists webkitgtk-6.0
pkg-config --exists glib-2.0
pkg-config --exists gobject-2.0
pkg-config --exists gio-2.0
pkg-config --exists pango
pkg-config --exists pangocairo
pkg-config --exists cairo
pkg-config --exists cairo-gobject
pkg-config --exists fontconfig
pkg-config --exists gdk-pixbuf-2.0
pkg-config --exists gstreamer-1.0
pkg-config --exists gstreamer-app-1.0
pkg-config --exists gstreamer-video-1.0
ldconfig -p | grep -q 'libgtk-4\.so\.1'
ldconfig -p | grep -q 'libwebkitgtk-6\.0\.so\.4'
ldconfig -p | grep -q 'libglib-2\.0\.so\.0'
ldconfig -p | grep -q 'libgobject-2\.0\.so\.0'
ldconfig -p | grep -q 'libgio-2\.0\.so\.0'
ldconfig -p | grep -q 'libpango-1\.0\.so\.0'
ldconfig -p | grep -q 'libpangocairo-1\.0\.so\.0'
ldconfig -p | grep -q 'libcairo\.so\.2'
ldconfig -p | grep -q 'libfontconfig\.so\.1'
ldconfig -p | grep -q 'libgdk_pixbuf-2\.0\.so\.0'
ldconfig -p | grep -q 'libgstreamer-1\.0\.so\.0'
ldconfig -p | grep -q 'libgstapp-1\.0\.so\.0'
ldconfig -p | grep -q 'libgstvideo-1\.0\.so\.0'
gst-inspect-1.0 avdec_h264 >/dev/null
gst-inspect-1.0 avdec_aac >/dev/null
```

这一步不能省：purego 在运行期找不到库时会直接 panic，比编译失败更难查；放在构建期断言就能把问题挡在镜像里。

## nsgo 版本策略

镜像里只装一个上游二进制，因此只有**一条版本线**，对应一个 `ARG`：

| 变量           | 模块                       | 装的东西                                                                   | 默认值   |
|----------------|----------------------------|----------------------------------------------------------------------------|----------|
| `NSGO_VERSION` | `github.com/nsgo-dev/nsgo` | `nsgo` CLI：`go install github.com/nsgo-dev/nsgo/cmd/nsgo@${NSGO_VERSION}` | `latest` |

**上游目前没有发 tag**，`@latest` 解析得到的是伪版本（如 `v0.0.0-20251115000000-abcdef123456`）。默认 `latest`，三级兜底：

| 场景                           | 行为                                                                                                                       |
|--------------------------------|----------------------------------------------------------------------------------------------------------------------------|
| CI 定时任务 / 手动触发留空     | 脚本在构建前用 `go list -m github.com/nsgo-dev/nsgo@latest` 解析出具体版本（无 tag 时就是伪版本），再以 `--build-arg` 传入 |
| 手动触发填版本                 | 按填的版本装：`v0.1.0` / `0.1.0`（自动补 `v`）或伪版本都可以                                                               |
| 裸 `docker build`（不经过 CI） | `@latest` 交给 `go install` 自己解析                                                                                       |

为什么要先在 CI 里解析成具体版本：buildx 的层缓存按 build-arg 的**值**算缓存键。每天都传字符串 `latest`，缓存键永远不变，`go install` 那层会一直命中第一次的产物，nsgo 再也不升级。解析成伪版本之后，上游没提交新代码就全命中，有新提交才重建那一层。

解析失败（GOPROXY 网络问题）时脚本会 `警告` 并回退 `latest`，本次构建由 Dockerfile 在构建时解析（镜像仍然可用，只是层缓存不生效、元数据里的 `nsgo_version` 会记成 `latest`）。

**解析到的版本会写进元数据 `nsgo_version`，但不占标签**——标签里的版本是 Go 版本，与基座同名标签一一对应。

### 两个容易踩的坑

- **模块路径是 `github.com/nsgo-dev/nsgo`**。`github.com/oneo-me/nsgo` 只是网页重定向，`go install` / `go list` 的模块路径不跟着变；CI、Dockerfile、冒烟里的 `go version -m` 比对都用新地址。
- **上游没有 tag，不要拿 `latest` 当可复现版本**。想复现某次产物：用元数据里的 `nsgo_digest` 拉镜像，或者手动触发并填当时记录下来的伪版本。

## 地址与标签

| 平台   | 地址                                     |
|--------|------------------------------------------|
| CNB    | `docker.cnb.cool/dtapp/golang/nsgo`      |
| GitHub | `ghcr.io/dtapps/golang/nsgo`             |
| GitLab | `registry.gitlab.com/dtapps/golang/nsgo` |

标签与基座同一套契约：`<go 版本>` / `<major.minor>` / `latest` / `<go 版本>-linux-{amd64,arm64}`。`<major.minor>` / `latest` 只在基座对应标签已指向同一 digest 时提升，所以 nsgo 的移动标签永远不会跑到基座前面。完整契约见 [../golang/images-and-tags.md](../golang/images-and-tags.md)。

nsgo 的 CLI 版本**不占标签**：要复现某一份产物请用元数据里的 `nsgo_digest`，要回到某个版本请手动触发并填 `nsgo_version`。

## 快速使用

```bash
# 看 CLI 用法（不需要显示环境）
docker run --rm ghcr.io/dtapps/golang/nsgo:latest nsgo --help
# 编译一个 nsgo 桌面程序（purego，不需要 cgo）
docker run --rm -v "$PWD":/src -w /src ghcr.io/dtapps/golang/nsgo:latest go build -o myapp .
# 没有显示器时用镜像自带的 Xvfb 跑；GTK4 走 X11 后端、需要时用 cairo 软件渲染
docker run --rm -v "$PWD":/src -w /src \
  -e GDK_BACKEND=x11 -e GSK_RENDERER=cairo \
  ghcr.io/dtapps/golang/nsgo:latest xvfb-run -a ./myapp
```

作为 CI 的基础镜像：

```dockerfile
FROM ghcr.io/dtapps/golang/nsgo:latest
# 已含 GTK4 / WebKitGTK 6.0 / Pango / Cairo / GStreamer 运行与开发包、无头运行库与 nsgo CLI
```

用 `latest` / `<major.minor>` 时拿到的是当天构建；要固定产物就把元数据里的 `nsgo_digest` 拿来用：

```bash
docker pull ghcr.io/dtapps/golang/nsgo@sha256:<nsgo_digest>
```

GUI 需要显示环境：容器里没有显示器时用镜像自带的 `Xvfb`（`xvfb-run -a <程序>`）或自己挂 X11 / Wayland socket。nsgo 的 Linux 后端是 GTK4，Wayland 运行还需要宿主机 compositor；CI 里最简单的组合是 Xvfb + `GDK_BACKEND=x11`，没有 GL 时再加 `GSK_RENDERER=cairo`。

## 怎么构建

- CNB：`.cnb/workflows/build-nsgo.yml`，每天 09:05 由该文件内的 crontab 定时触发（在 gio 08:05 之后，给基座 00:05 留了九小时）；也可用「打包 Golang + nsgo 镜像（多架构）」按钮手动触发，可填 `version` / `nsgo_version`。
- GitHub：`.github/workflows/build-nsgo.yml`，每天 01:05 UTC（北京 09:05）定时触发（在 build-gio 的 00:05 UTC 之后）；手动触发同样可填 `version` / `nsgo_version`。
- GitLab：`.gitlab/workflows/build-nsgo.yml`，在 UI / API 建 `TARGET=nsgo` 的 schedule 定时触发（基座先构建）；手动 Run pipeline 时填 `TARGET=nsgo`，可再填 `VERSION` / `NSGO_VERSION`，见 [../gitlab.md](../gitlab.md)。

脚本先等 `golang:<go 版本>` 就绪（最多 20 × 15 秒，等不到直接失败），再从它构建、派生单平台标签、跑冒烟、提升移动标签。冒烟断言：

- `go version` 与基座一致；`go` / `node` / `npm` / `pnpm` / `sqlc` / `golangci-lint` / `zip` / `unzip` / `pkg-config` / `gcc` / `Xvfb` / `gst-inspect-1.0` / `nsgo` 都在
- 上面那 14 个 `.pc` 逐个 `pkg-config --exists` 都成立
- `ldconfig -p` 能查到 `libgtk-4.so.1` / `libwebkitgtk-6.0.so.4` / `libgstreamer-1.0.so.0` / `libgstapp-1.0.so.0` / `libgstvideo-1.0.so.0` 等 13 个运行库（purego 运行期 `dlopen` 的库，编译期装了不等于运行期能加载）
- `gst-inspect-1.0` 能列出 `avdec_h264` 与 `avdec_aac`（H.264 / AAC 解码真的可用）
- `nsgo` 可执行，且 `go version -m <nsgo 二进制>` 里的 `github.com/nsgo-dev/nsgo` 模块版本等于本次目标版本（回退 `latest` 时只验证可执行）；`nsgo --help` 能打出输出
- 基座里不该出现的 `fnpack` / `wails3` / `wails` / `fyne` / `mygo` / `bun` / `gogio` / `viva` 依旧不存在

任何一步失败都会停在原地：`latest` / `<major.minor>` 不动。

## 元数据与徽章

CNB 侧写 `.cnb/annotation-nsgo.json`，GitHub 侧写 `.github/annotation-nsgo.json`，GitLab 侧写 `.gitlab/annotation-nsgo.json`（都不入库）。

| 键                  | 含义                                                                           |
|---------------------|--------------------------------------------------------------------------------|
| `nsgo_image`        | nsgo 镜像全名                                                                  |
| `nsgo_digest`       | nsgo manifest list digest                                                      |
| `nsgo_digest_short` | 前 12 位 digest（只用于核对）                                                  |
| `nsgo_size`         | amd64 压缩体积                                                                 |
| `nsgo_size_arm64`   | arm64 压缩体积                                                                 |
| `nsgo_version`      | 本次安装的 nsgo CLI 版本（模块 `github.com/nsgo-dev/nsgo`，无 tag 时为伪版本） |
| `image_version`     | 解析出的 Go 版本（与 `<go 版本>` 标签一致）                                    |
| `golang_version`    | 同上                                                                           |
| `nsgo_base_image`   | 本次使用的基础镜像引用                                                         |
| `nsgo_base_digest`  | 基础镜像 digest                                                                |
| `apt_versions`      | apt 装的系统包版本（`包=版本`，缺包标 `absent`；清单取自 Dockerfile）          |
| `built_at`          | 本次构建时间                                                                   |
| `source_date`       | 最后一次提交时间                                                               |

徽章全部从 CNB commit annotation 取值，地址模板：

```text
https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/{key}
```

本页顶部那排徽章对应的 key：

| 徽章       | key                 | 说明                                          |
|------------|---------------------|-----------------------------------------------|
| nsgo 版本  | `nsgo_version`      | 伪版本或手动钉的 tag；回退解析时显示 `latest` |
| 镜像大小   | `nsgo_size`         | amd64 压缩体积                                |
| arm64 大小 | `nsgo_size_arm64`   | arm64 压缩体积                                |
| 镜像摘要   | `nsgo_digest_short` | 前 12 位，只用于核对，不能用于 pull           |
| 镜像版本   | `image_version`     | Go 版本，与 `<go 版本>` 标签一致              |

直接贴到自己 README 里可用（把 `{key}` 换成上表的值）：

```markdown
![nsgo 版本](https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/nsgo_version)
![镜像大小](https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/nsgo_size)
![镜像摘要](https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/nsgo_digest_short)
```

几个使用注意：

- `commit/latest` 是「最新提交」这一维度，与镜像标签 `latest` 同名但无关。
- `type: ADD` 对同一 commit 是覆盖语义：同名 key 只保留最后一次构建。要长期锁定某次产物，记下当时的 `nsgo_digest` 并按 digest 拉取。
- 徽章显示灰色 `unknown` 通常意味着：这次构建失败（`cnbcool/annotations` 那步没跑）、key 从未写入，或体积解析拿到了非镜像清单（日志里会有「体积解析失败」警告）。
- GitHub 侧不写 commit 注解：同样的 JSON 写进 Step Summary，并上传 artifact `nsgo-annotation`（保留 30 天）。GitLab 侧同样不写 commit 注解，JSON 作为 job artifact 保留 30 天。跨平台核对以 artifact 为准。

## 十个镜像的关系

同一 `<go 版本>` 下：

```text
golang:1.27.3        = 基座 + 全部工具链
golang/fnpack:1.27.3 = golang:1.27.3 + fnpack
golang/wails3:1.27.3 = golang:1.27.3 + GTK4/WebKitGTK + wails3
golang/wails2:1.27.3 = golang:1.27.3 + GTK3/WebKit2GTK 4.1 + wails
golang/fyne:1.27.3   = golang:1.27.3 + OpenGL/X11/Wayland + fyne
golang/mygo:1.27.3   = golang:1.27.3 + GTK3/WebKitGTK 4.1 + 无头运行库 + mygo + bun
golang/gio:1.27.3    = golang:1.27.3 + EGL/GLES/X11/Wayland/Vulkan 开发包 + 无头运行库 + gogio
golang/nsgo:1.27.3   = golang:1.27.3 + GTK4/WebKitGTK 6.0/GStreamer + 无头运行库 + nsgo
golang/viva:1.27.3   = golang:1.27.3 + XCB/Vulkan + GTK3/WebKit2GTK 4.1 + 无头运行库 + viva
```

fnpack、wails3、wails2、fyne、mygo、gio、nsgo、viva 与 asuka 是九个**平级**的变体，互不包含：需要打包 `.fpk` 用 `fnpack`，编译 Wails v3 应用用 `wails3`，编译 Wails v2 应用用 `wails2`，编译 Fyne 应用用 `fyne`，编译 MyGo 应用用 `mygo`，用 cgo 编译 Gio 应用用 `gio`，编译 nsgo 应用用 `nsgo`，编译 viva 应用用 `viva`；都要就在自己 Dockerfile 里 `FROM golang:latest` 再各装一个。

注意 nsgo 与 wails3 都用 GTK4，但依赖集合**不同**：wails3 装的是 GTK4 + WebKitGTK，面向 Wails v3 的 WebView 应用；nsgo 额外装整套 GStreamer（含 `plugins-bad` / `plugins-ugly` / `libav`）并断言 H.264 / AAC 解码，面向 nsgo 自己的渲染与媒体栈。两者不能互相替代。
