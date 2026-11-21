# Golang 构建环境 + viva 镜像

[![定时构建](https://cnb.cool/dtapp/golang/-/badge/git/latest/ci/status/crontab)](https://cnb.cool/dtapp/golang/-/pipeline) [![流水线配置](https://cnb.cool/dtapp/golang/-/badge/git/latest/ci/pipeline-as-code)](https://cnb.cool/dtapp/golang/-/blob/main/.cnb.yml) [![漏洞扫描](https://cnb.cool/dtapp/golang/-/badge/security/vulnerability/full/latest)](https://cnb.cool/dtapp/golang/-/security) ![基础镜像](https://img.shields.io/badge/base-golang-00ADD8?logo=go&logoColor=white) ![viva](https://img.shields.io/badge/viva-CLI-blue) ![架构](https://img.shields.io/badge/arch-amd64%20%7C%20arm64-informational) ![viva 版本](https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/viva_version) ![镜像大小](https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/viva_size) ![arm64 大小](https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/viva_size_arm64) ![镜像摘要](https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/viva_digest_short) ![镜像版本](https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/image_version)

在 [Golang 构建环境镜像](../golang/README.md) 之上做两件事：装运行 [viva](https://github.com/vivaui/viva) 桌面程序所需的系统依赖（XCB、Vulkan、Pango / Cairo / fontconfig，以及可选 `vivagtk` 壳层的 GTK3 / WebKit2GTK 4.1，外加无头运行库），再 `go install` 一份 `viva` CLI。

> **viva 用 [purego](https://github.com/ebitengine/purego) 在运行期 `dlopen` 系统库，Linux 默认后端是 XCB + Vulkan，纯 Go 就能编译，不需要 cgo**。带 `vivagtk` build tag 时改走 GTK3 壳层，内嵌 WebView 用 WebKit2GTK 4.1。所以镜像的重点不是编译器，而是 **XCB / Vulkan 与可选 GTK3 壳层这套运行库齐全**：Dockerfile 第 1 层用 `pkg-config --exists`、`ldconfig -p` 与 Vulkan ICD 检查逐个断言，缺一个就构建失败。`-dev` 包同时保留，方便使用者项目自己写 cgo 绑定。

> **本目录的分工**：viva 镜像 = 基座镜像 + XCB/Vulkan/Pango/Cairo 与 GTK3/WebKit2GTK 4.1 运行与开发包 + 无头运行库 + `viva` CLI，所以这里只收 viva 专属的内容（版本策略、构建用法、元数据）。构建、CI、标签、镜像源、维护、排错等共用机制都在 [`docs/golang/`](../golang/index.md)，不在这里重复。文档与实现冲突时，以三份 `Dockerfile.viva` 与三份 `build-viva.sh` 为准。

## 镜像里有什么

- 基座：本仓库构建的 Golang 构建环境镜像（CI 按 `<go 版本>` 钉住当天刚推好的那份；Dockerfile 默认基座是官方 `golang:1-trixie`，只用于不依赖私有仓库的本地构建）
- 继承基座全部内容：Go 工具链、UPX、nfpm、Node.js + npm + pnpm、sqlc / ent / golangci-lint / govulncheck / shfmt / dockerfmt / yamlfmt / gojq / sql-formatter / gotestsum / markdownfmt / gocover-cobertura / gcov2lcov / task、gh / cnb、wixl、git / curl / make / jq / zip / unzip / pkg-config、`TZ=Asia/Shanghai` 与 `C.UTF-8`
- 新增系统包：`pkg-config`、`gcc`、`libx11-dev`、`libx11-xcb-dev`、`libxcb1-dev`、`libxcb-randr0-dev`、`libxcb-sync-dev`、`libxcb-cursor-dev`、`libxkbcommon-dev`、`libxkbcommon-x11-dev`、`libvulkan-dev`、`libfontconfig1-dev`、`libglib2.0-dev`、`libpango1.0-dev`、`libcairo2-dev`、`libgdk-pixbuf-2.0-dev`、`libgtk-3-dev`、`libwebkit2gtk-4.1-dev`，以及无头运行环境 `xvfb`、`xauth`、`dbus-x11`、`libgl1-mesa-dri`、`libglx-mesa0`、`libegl-mesa0`、`mesa-vulkan-drivers`、`shared-mime-info`、`adwaita-icon-theme`、`fonts-dejavu-core`
- 新增 CLI：`/go/bin/viva`（`GOPATH=/go`，已在 `PATH` 里；`go install github.com/vivaui/viva/cmd/viva@<VIVA_VERSION>`）

为什么是这一组包：

- XCB 后端在运行期 `dlopen` 的是 `libxcb.so.1` / `libxcb-randr.so.0` / `libxcb-sync.so.1` / `libxcb-cursor.so.0`、`libX11.so.6` / `libX11-xcb.so.1`、`libxkbcommon.so.0` / `libxkbcommon-x11.so.0`，这是**运行期硬依赖**，缺一个程序就起不来。`libxcb*-dev` 同时提供头文件与 `.pc`，方便使用者写 cgo 绑定。
- `libvulkan-dev` 提供 `vulkan/vulkan.h` 与加载器 `libvulkan.so.1`；`mesa-vulkan-drivers` 提供真正的 ICD 驱动（CI 里可用 lavapipe 软件 Vulkan）。只有加载器没有 ICD 时 `vulkaninfo` / 程序都会报找不到设备，所以镜像额外断言 `/usr/share/vulkan/icd.d/*.json` 存在。
- 文本渲染与主题：`libfontconfig1-dev`、`libpango1.0-dev`、`libcairo2-dev`、`libgdk-pixbuf-2.0-dev` 带进 fontconfig / Pango / Cairo / GdkPixbuf，GTK3 壳层与 `vivagtk` 内嵌 WebView 还要 `libgtk-3-dev` + `libwebkit2gtk-4.1-dev`（`webkit2gtk-4.1` 是 GTK3 线的新版 ABI；4.0 是旧 ABI，别混）。
- 无头包（Xvfb + mesa + DRI 驱动 + 字体）让 GUI 冒烟在没有显示器的 CI 里也能跑；`shared-mime-info` 与 `adwaita-icon-theme` 是 GTK3 程序启动时的常见运行依赖。
- 这些 `-dev` 包既是编译依赖也是运行依赖（`-dev` 会把运行库一起装上），必须留在镜像里，不能在构建末尾卸载。

装完立刻断言一遍 `.pc`、运行库与 Vulkan ICD：

```sh
pkg-config --exists xcb
pkg-config --exists xcb-randr
pkg-config --exists xcb-sync
pkg-config --exists xcb-cursor
pkg-config --exists x11
pkg-config --exists x11-xcb
pkg-config --exists xkbcommon
pkg-config --exists xkbcommon-x11
pkg-config --exists vulkan
pkg-config --exists fontconfig
pkg-config --exists glib-2.0
pkg-config --exists gobject-2.0
pkg-config --exists gio-2.0
pkg-config --exists pango
pkg-config --exists pangocairo
pkg-config --exists cairo
pkg-config --exists gdk-pixbuf-2.0
pkg-config --exists gtk+-3.0
pkg-config --exists webkit2gtk-4.1
ldconfig -p | grep -q 'libxcb\.so\.1'
ldconfig -p | grep -q 'libxcb-randr\.so\.0'
ldconfig -p | grep -q 'libxcb-sync\.so\.1'
ldconfig -p | grep -q 'libxcb-cursor\.so\.0'
ldconfig -p | grep -q 'libX11\.so\.6'
ldconfig -p | grep -q 'libX11-xcb\.so\.1'
ldconfig -p | grep -q 'libxkbcommon\.so\.0'
ldconfig -p | grep -q 'libxkbcommon-x11\.so\.0'
ldconfig -p | grep -q 'libvulkan\.so\.1'
ldconfig -p | grep -q 'libfontconfig\.so\.1'
ldconfig -p | grep -q 'libpango-1\.0\.so\.0'
ldconfig -p | grep -q 'libpangocairo-1\.0\.so\.0'
ldconfig -p | grep -q 'libcairo\.so\.2'
ldconfig -p | grep -q 'libgtk-3\.so\.0'
ldconfig -p | grep -q 'libgdk-3\.so\.0'
ldconfig -p | grep -q 'libwebkit2gtk-4\.1\.so\.0'
ldconfig -p | grep -q 'libjavascriptcoregtk-4\.1\.so\.0'
find /usr/share/vulkan/icd.d -name '*.json' -print -quit
```

这一步不能省：purego 在运行期找不到库时会直接 panic，比编译失败更难查；放在构建期断言就能把问题挡在镜像里。

## viva 版本策略

镜像里只装一个上游二进制，因此只有**一条版本线**，对应一个 `ARG`：

| 变量           | 模块                     | 装的东西                                                                 | 默认值   |
|----------------|--------------------------|--------------------------------------------------------------------------|----------|
| `VIVA_VERSION` | `github.com/vivaui/viva` | `viva` CLI：`go install github.com/vivaui/viva/cmd/viva@${VIVA_VERSION}` | `latest` |

上游有版本 tag（当前最新稳定版如 `v0.6.4`）。默认 `latest`，三级兜底：

| 场景                           | 行为                                                                                                               |
|--------------------------------|--------------------------------------------------------------------------------------------------------------------|
| CI 定时任务 / 手动触发留空     | 脚本在构建前用 `go list -m github.com/vivaui/viva@latest` 解析最新稳定 tag（如 `v0.6.4`），再以 `--build-arg` 传入 |
| 手动触发填版本                 | 按填的版本装：`v0.6.4` / `0.6.4`（自动补 `v`）都可以；预发布如 `v0.7.0-rc1` 也接受                                 |
| 裸 `docker build`（不经过 CI） | `@latest` 交给 `go install` 自己解析                                                                               |

为什么要先在 CI 里解析成具体版本：buildx 的层缓存按 build-arg 的**值**算缓存键。每天都传字符串 `latest`，缓存键永远不变，`go install` 那层会一直命中第一次的产物，viva 再也不升级。解析成 `v0.6.4` 之后，上游没发新版就全命中，发新版才重建那一层。

解析失败（GOPROXY 网络问题）时脚本会 `警告` 并回退 `latest`，本次构建由 Dockerfile 在构建时解析（镜像仍然可用，只是层缓存不生效、元数据里的 `viva_version` 会记成 `latest`）。

**解析到的版本会写进元数据 `viva_version`，但不占标签**——标签里的版本是 Go 版本，与基座同名标签一一对应。

### 两个容易踩的坑

- **`webkit2gtk-4.1` 不是 `webkit2gtk-4.0`**。GTK3 线从 WebKitGTK 2.40 起把 4.0 ABI 迁到 4.1，pkg-config 名、头文件目录、共享库名（`libwebkit2gtk-4.1.so.0`）全变了。`vivagtk` 壳层要的是 4.1；装 4.0 会链接不上。
- **默认后端是 XCB + Vulkan，不是 GTK**。纯 Go 程序不经过 GTK，容器里没有 X 时用 Xvfb；需要 WebView 或 GTK 原生控件时才加 `-tags vivagtk`，那才会用到 GTK3 / WebKit2GTK 4.1。

## 地址与标签

| 平台   | 地址                                     |
|--------|------------------------------------------|
| CNB    | `docker.cnb.cool/dtapp/golang/viva`      |
| GitHub | `ghcr.io/dtapps/golang/viva`             |
| GitLab | `registry.gitlab.com/dtapps/golang/viva` |

标签与基座同一套契约：`<go 版本>` / `<major.minor>` / `latest` / `<go 版本>-linux-{amd64,arm64}`。`<major.minor>` / `latest` 只在基座对应标签已指向同一 digest 时提升，所以 viva 的移动标签永远不会跑到基座前面。完整契约见 [../golang/images-and-tags.md](../golang/images-and-tags.md)。

viva 的 CLI 版本**不占标签**：要复现某一份产物请用元数据里的 `viva_digest`，要回到某个版本请手动触发并填 `viva_version`。

## 快速使用

```bash
# 看 CLI 版本（不需要显示环境）
docker run --rm ghcr.io/dtapps/golang/viva:latest viva --version
# 编译一个 viva 桌面程序（purego，不需要 cgo）
docker run --rm -v "$PWD":/src -w /src ghcr.io/dtapps/golang/viva:latest go build -o myapp .
# 带 GTK3 / WebView 壳层时加 build tag
docker run --rm -v "$PWD":/src -w /src ghcr.io/dtapps/golang/viva:latest go build -tags vivagtk -o myapp .
# 没有显示器时用镜像自带的 Xvfb 跑
docker run --rm -v "$PWD":/src -w /src ghcr.io/dtapps/golang/viva:latest xvfb-run -a ./myapp
```

作为 CI 的基础镜像：

```dockerfile
FROM ghcr.io/dtapps/golang/viva:latest
# 已含 XCB / Vulkan、Pango / Cairo / fontconfig、GTK3 / WebKit2GTK 4.1 与无头运行库、viva CLI
```

用 `latest` / `<major.minor>` 时拿到的是当天构建；要固定产物就把元数据里的 `viva_digest` 拿来用：

```bash
docker pull ghcr.io/dtapps/golang/viva@sha256:<viva_digest>
```

GUI 需要显示环境：容器里没有显示器时用镜像自带的 `Xvfb`（`xvfb-run -a <程序>`）或自己挂 X11 socket。XCB 后端要 `DISPLAY` 指到 X 服务；Vulkan 没有 GPU 时 mesa 的 lavapipe 会接管（只支持软件渲染，性能有限）。

## 怎么构建

- CNB：`.cnb/workflows/build-viva.yml`，每天 10:05 由该文件内的 crontab 定时触发，排在 nsgo（09:05）之后 1 小时；距基座已过十小时，脚本按常规等基座 5 分钟。也可用「打包 Golang + viva 镜像（多架构）」按钮手动触发，可填 `version` / `viva_version`。
- GitHub：`.github/workflows/build-viva.yml`，每天 02:05 UTC（北京 10:05）定时触发，排在 build-nsgo（01:05 UTC）之后 1 小时；手动触发同样可填 `version` / `viva_version`。
- GitLab：`.gitlab/workflows/build-viva.yml`，在 UI / API 建 `TARGET=viva` 的 schedule 定时触发（建议 cron `5 2 * * *` UTC / `5 10 * * *` 北京，排在 nsgo 之后 1 小时）；手动 Run pipeline 时填 `TARGET=viva`，可再填 `VERSION` / `VIVA_VERSION`，见 [../gitlab.md](../gitlab.md)。

脚本先等 `golang:<go 版本>` 就绪（最多 20 × 15 秒，即 5 分钟），再从它构建、派生单平台标签、跑冒烟、提升移动标签。冒烟断言：

- `go version` 与基座一致；`go` / `node` / `npm` / `pnpm` / `sqlc` / `golangci-lint` / `zip` / `unzip` / `pkg-config` / `gcc` / `Xvfb` / `viva` 都在
- 上面那 19 个 `.pc` 逐个 `pkg-config --exists` 都成立
- `ldconfig -p` 能查到 `libxcb.so.1` / `libxcb-randr.so.0` / `libvulkan.so.1` / `libgtk-3.so.0` / `libwebkit2gtk-4.1.so.0` 等 21 个运行库（purego 运行期 `dlopen` 的库，编译期装了不等于运行期能加载）
- `/usr/share/vulkan/icd.d` 下至少有一个 `*.json`（Vulkan 加载器能找到 ICD 驱动）
- `viva` 可执行，且 `go version -m <viva 二进制>` 里的 `github.com/vivaui/viva` 模块版本等于本次目标版本（回退 `latest` 时只验证可执行）；`viva --version` 能打出输出
- 基座里不该出现的 `fnpack` / `wails3` / `wails` / `fyne` / `mygo` / `bun` / `gogio` / `nsgo` 依旧不存在

任何一步失败都会停在原地：`latest` / `<major.minor>` 不动。

## 元数据与徽章

CNB 侧写 `.cnb/annotation-viva.json`，GitHub 侧写 `.github/annotation-viva.json`，GitLab 侧写 `.gitlab/annotation-viva.json`（都不入库）。

| 键                  | 含义                                                                   |
|---------------------|------------------------------------------------------------------------|
| `viva_image`        | viva 镜像全名                                                          |
| `viva_digest`       | viva manifest list digest                                              |
| `viva_digest_short` | 前 12 位 digest（只用于核对）                                          |
| `viva_size`         | amd64 压缩体积                                                         |
| `viva_size_arm64`   | arm64 压缩体积                                                         |
| `viva_version`      | 本次安装的 viva CLI 版本（模块 `github.com/vivaui/viva`，如 `v0.6.4`） |
| `image_version`     | 解析出的 Go 版本（与 `<go 版本>` 标签一致）                            |
| `golang_version`    | 同上                                                                   |
| `viva_base_image`   | 本次使用的基础镜像引用                                                 |
| `viva_base_digest`  | 基础镜像 digest                                                        |
| `apt_versions`      | apt 装的系统包版本（`包=版本`，缺包标 `absent`；清单取自 Dockerfile）  |
| `built_at`          | 本次构建时间                                                           |
| `source_date`       | 最后一次提交时间                                                       |

徽章全部从 CNB commit annotation 取值，地址模板：

```text
https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/{key}
```

本页顶部那排徽章对应的 key：

| 徽章       | key                 | 说明                                 |
|------------|---------------------|--------------------------------------|
| viva 版本  | `viva_version`      | 如 `v0.6.4`；回退解析时显示 `latest` |
| 镜像大小   | `viva_size`         | amd64 压缩体积                       |
| arm64 大小 | `viva_size_arm64`   | arm64 压缩体积                       |
| 镜像摘要   | `viva_digest_short` | 前 12 位，只用于核对，不能用于 pull  |
| 镜像版本   | `image_version`     | Go 版本，与 `<go 版本>` 标签一致     |

直接贴到自己 README 里可用（把 `{key}` 换成上表的值）：

```markdown
![viva 版本](https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/viva_version)
![镜像大小](https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/viva_size)
![镜像摘要](https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/viva_digest_short)
```

几个使用注意：

- `commit/latest` 是「最新提交」这一维度，与镜像标签 `latest` 同名但无关。
- `type: ADD` 对同一 commit 是覆盖语义：同名 key 只保留最后一次构建。要长期锁定某次产物，记下当时的 `viva_digest` 并按 digest 拉取。
- 徽章显示灰色 `unknown` 通常意味着：这次构建失败（`cnbcool/annotations` 那步没跑）、key 从未写入，或体积解析拿到了非镜像清单（日志里会有「体积解析失败」警告）。
- GitHub 侧不写 commit 注解：同样的 JSON 写进 Step Summary，并上传 artifact `viva-annotation`（保留 30 天）。GitLab 侧同样不写 commit 注解，JSON 作为 job artifact 保留 30 天。跨平台核对以 artifact 为准。

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

注意 viva 与 wails2 / mygo 都装 GTK3 与 WebKit2GTK 4.1，但用途**不同**：wails2 / mygo 的 GTK3 是应用本身的窗口后端，必需；viva 默认走 XCB + Vulkan，GTK3 / WebKit2GTK 只在 `vivagtk` build tag 下用到。反过来，viva 的 XCB / Vulkan 运行库在 wails2 / mygo 里也没有，所以两者不能互相替代。
