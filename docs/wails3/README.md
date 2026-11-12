# Golang 构建环境 + wails3 镜像

[![定时构建](https://cnb.cool/dtapp/golang/-/badge/git/latest/ci/status/crontab)](https://cnb.cool/dtapp/golang/-/pipeline) [![流水线配置](https://cnb.cool/dtapp/golang/-/badge/git/latest/ci/pipeline-as-code)](https://cnb.cool/dtapp/golang/-/blob/main/.cnb.yml) [![漏洞扫描](https://cnb.cool/dtapp/golang/-/badge/security/vulnerability/full/latest)](https://cnb.cool/dtapp/golang/-/security) ![基础镜像](https://img.shields.io/badge/base-golang-00ADD8?logo=go&logoColor=white) ![wails3](https://img.shields.io/badge/wails3-v3-blue) ![架构](https://img.shields.io/badge/arch-amd64%20%7C%20arm64-informational) ![wails3 版本](https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/wails3_version) ![镜像大小](https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/wails3_size) ![arm64 大小](https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/wails3_size_arm64) ![镜像摘要](https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/wails3_digest_short) ![镜像版本](https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/image_version)

在 [Golang 构建环境镜像](../golang/README.md) 之上做两件事：装 GTK4 / WebKitGTK 6.0 开发包，再 `go install` 一份 `wails3` CLI。用于在 CI / 容器里编译 [Wails v3](https://github.com/wailsapp/wails) 桌面应用（Linux 侧 webview 走 GTK4 + WebKitGTK 6.0）。

> **本目录的分工**：wails3 镜像 = 基座镜像 + GTK4/WebKitGTK + `wails3` 二进制，所以这里只收 wails3 专属的内容（版本策略、构建用法、元数据）。构建、CI、标签、镜像源、维护、排错等共用机制都在 [`docs/golang/`](../golang/index.md)，不在这里重复。文档与实现冲突时，以三份 `Dockerfile.wails3` 与三份 `build-wails3.sh` 为准。

## 镜像里有什么

- 基座：本仓库构建的 Golang 构建环境镜像（CI 按 `<go 版本>` 钉住当天刚推好的那份；Dockerfile 默认基座是官方 `golang:1-trixie`，只用于不依赖私有仓库的本地构建）
- 继承基座全部内容：Go 工具链、UPX、nfpm、Node.js + npm + pnpm、sqlc / ent / golangci-lint / govulncheck / shfmt / dockerfmt / yamlfmt / gojq / sql-formatter / gotestsum / markdownfmt / gocover-cobertura / gcov2lcov、wixl、git / curl / make / jq / zip / unzip / pkg-config、`TZ=Asia/Shanghai` 与 `C.UTF-8`
- 新增：`libgtk-4-dev`、`libwebkitgtk-6.0-dev`，以及 `/go/bin/wails3`（`GOPATH=/go`，已在 `PATH` 里）。`pkg-config` 在基座里已装，这里再声明一次只是为了 `FROM` 上游 `golang` 单独构建本文件时也自洽（apt 幂等）

`wails3` 的 `go install` 以及后续 `wails3 build` / `go build` / `go test` 都要 pkg-config 找到 `gtk4.pc` 与 `webkitgtk-6.0.pc`，所以这些开发包必须留在镜像里、不做卸载——它们是这个镜像的用途本身。Dockerfile 装完立刻断言一次：

```dockerfile
pkg-config --exists gtk4
pkg-config --exists webkitgtk-6.0
```

## wails3 版本策略

`WAILS3_VERSION` 的默认值是 `latest`，不钉死某个 tag（历史上写过 `v3.0.0`，需要手动改才能升级）。三级兜底：

| 场景                           | 行为                                                                                                                     |
|--------------------------------|--------------------------------------------------------------------------------------------------------------------------|
| CI 定时任务 / 手动触发留空     | 脚本在构建前用 `go list -m github.com/wailsapp/wails/v3@latest` 解析最新稳定 tag（如 `v3.1.0`），再以 `--build-arg` 传入 |
| 手动触发填 `wails3_version`    | 按填的版本装：`v3.1.0` / `3.1.0`（自动补 `v`）/ `v3.0.0-beta.34` 都可以                                                  |
| 裸 `docker build`（不经过 CI） | `@latest` 交给 `go install` 自己解析                                                                                     |

为什么要先在 CI 里解析成具体版本：buildx 的层缓存按 build-arg 的**值**算缓存键。每天都传字符串 `latest`，缓存键永远不变，编译 `wails3` 的那一层会一直命中第一次的产物，wails3 再也不升级。解析成 `v3.1.0` 之后，上游没发新版就全命中，发新版才重建那一层。

解析失败（GOPROXY 网络问题）时脚本会 `警告` 并回退 `latest`，本次构建由 Dockerfile 在构建时解析（镜像仍然可用，只是层缓存不生效、元数据里的 `wails3_version` 会记成 `latest`）。

**解析到的版本会写进元数据 `wails3_version`，但不占标签**——标签里的版本是 Go 版本，与基座同名标签一一对应。

## 地址与标签

| 平台   | 地址                                       |
|--------|--------------------------------------------|
| CNB    | `docker.cnb.cool/dtapp/golang/wails3`      |
| GitHub | `ghcr.io/dtapps/golang/wails3`             |
| GitLab | `registry.gitlab.com/dtapps/golang/wails3` |

标签与基座同一套契约：`<go 版本>` / `<major.minor>` / `latest` / `<go 版本>-linux-{amd64,arm64}`。`<major.minor>` / `latest` 只在基座对应标签已指向同一 digest 时提升，所以 wails3 的移动标签永远不会跑到基座前面。完整契约见 [../golang/images-and-tags.md](../golang/images-and-tags.md)。

wails3 自身的版本**不占标签**（上游按周发版，标签数量会失控）：要复现某一份产物请用元数据里的 `wails3_digest`，要回到某个 wails3 版本请手动触发并填 `wails3_version`。

## 快速使用

```bash
docker run --rm ghcr.io/dtapps/golang/wails3:latest wails3 version
docker run --rm -v "$PWD":/src -w /src ghcr.io/dtapps/golang/wails3:latest wails3 build
```

作为 CI 的基础镜像：

```dockerfile
FROM ghcr.io/dtapps/golang/wails3:latest
# 已含 GTK4 / WebKitGTK 6.0 开发包与 wails3 CLI
```

用 `latest` / `<major.minor>` 时拿到的是当天构建；要固定产物就把元数据里的 `wails3_digest` 拿来用：

```bash
docker pull ghcr.io/dtapps/golang/wails3@sha256:<wails3_digest>
```

`wails3 dev` 需要真实显示环境（容器里要自己准备 X11/Wayland），这个镜像只保证**构建**可用。

## 怎么构建

- CNB：`.cnb/workflows/build-wails3.yml`，每天 06:05 由 `.cnb.yml` 定时触发（基座 00:05、fnpack 03:05 之后）；也可用「打包 Golang + wails3 镜像（多架构）」按钮手动触发，可填 `version` / `wails3_version`。
- GitHub：`.github/workflows/build-wails3.yml`，每天 22:05 UTC（北京 06:05）定时触发（基座 16:05 UTC、fnpack 19:05 UTC 之后）；手动触发同样可填 `version` / `wails3_version`。
- GitLab：`.gitlab/workflows/build-wails3.yml`，在 UI / API 建 `TARGET=wails3` 的 schedule 定时触发（基座先构建）；手动 Run pipeline 时填 `TARGET=wails3`，可再填 `VERSION` / `WAILS3_VERSION`，见 [../gitlab.md](../gitlab.md)。

脚本先等 `golang:<go 版本>` 就绪（等不到直接失败），再从它构建、派生单平台标签、跑冒烟、提升移动标签。冒烟断言：

- `go version` 与基座一致；`go` / `node` / `pnpm` / `sqlc` / `golangci-lint` / `zip` / `unzip` / `pkg-config` 都在
- `pkg-config --exists gtk4` 与 `pkg-config --exists webkitgtk-6.0` 都成立
- `wails3` 可执行，且 `go version -m <wails3 二进制>` 里的 `mod github.com/wailsapp/wails/v3` 版本等于本次目标版本（回退 `latest` 时只验证可执行；读模块信息比解析 `wails3 version` 的输出格式可靠）
- 基座里不该出现的 `fnpack` 依旧不存在

任何一步失败都会停在原地：`latest` / `<major.minor>` 不动。

## 元数据与徽章

CNB 侧写 `.cnb/annotation-wails3.json`，GitHub 侧写 `.github/annotation-wails3.json`，GitLab 侧写 `.gitlab/annotation-wails3.json`（都不入库）。

| 键                   | 含义                                                                  |
|----------------------|-----------------------------------------------------------------------|
| `wails3_image`       | wails3 镜像全名                                                       |
| `wails3_digest`      | wails3 manifest list digest                                           |
| `wails3_size`        | amd64 压缩体积                                                        |
| `wails3_size_arm64`  | arm64 压缩体积                                                        |
| `wails3_version`     | 本次安装的 wails3 CLI 版本（如 `v3.1.0`）                             |
| `image_version`      | 解析出的 Go 版本（与 `<go 版本>` 标签一致）                           |
| `golang_version`     | 同上                                                                  |
| `wails3_base_image`  | 本次使用的基础镜像引用                                                |
| `wails3_base_digest` | 基础镜像 digest                                                       |
| `apt_versions`       | apt 装的系统包版本（`包=版本`，缺包标 `absent`；清单取自 Dockerfile） |
| `built_at`           | 本次构建时间                                                          |
| `source_date`        | 最后一次提交时间                                                      |
| `revision`           | 提交 SHA                                                              |

徽章全部从 CNB commit annotation 取值，地址模板：

```text
https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/{key}
```

本页顶部那排徽章对应的 key：

| 徽章        | key                   | 说明                                 |
|-------------|-----------------------|--------------------------------------|
| wails3 版本 | `wails3_version`      | 如 `v3.1.0`；回退解析时显示 `latest` |
| 镜像大小    | `wails3_size`         | amd64 压缩体积                       |
| arm64 大小  | `wails3_size_arm64`   | arm64 压缩体积                       |
| 镜像摘要    | `wails3_digest_short` | 前 12 位，只用于核对，不能用于 pull  |
| 镜像版本    | `image_version`       | Go 版本，与 `<go 版本>` 标签一致     |

直接贴到自己 README 里可用（把 `{key}` 换成上表的值）：

```markdown
![wails3 版本](https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/wails3_version)
![镜像大小](https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/wails3_size)
![镜像摘要](https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/wails3_digest_short)
```

几个使用注意：

- `commit/latest` 是「最新提交」这一维度，与镜像标签 `latest` 同名但无关。
- `type: ADD` 对同一 commit 是覆盖语义：同名 key 只保留最后一次构建。要长期锁定某次产物，记下当时的 `wails3_digest` 并按 digest 拉取。
- 徽章显示灰色 `unknown` 通常意味着：这次构建失败（`cnbcool/annotations` 那步没跑）、key 从未写入，或体积解析拿到了非镜像清单（日志里会有「体积解析失败」警告）。
- GitHub 侧不写 commit 注解：同样的 JSON 写进 Step Summary，并上传 artifact `wails3-annotation`（保留 30 天）。GitLab 侧同样不写 commit 注解，JSON 作为 job artifact 保留 30 天。跨平台核对以 artifact 为准。

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

fnpack、wails3、wails2、fyne、mygo 与 gio 是六个**平级**的变体，互不包含：需要打包 `.fpk` 用 `fnpack`，需要编译 Wails v3 应用用 `wails3`，编译 Wails v2 应用用 `wails2`，编译 Fyne 桌面应用用 `fyne`，编译 MyGo 桌面应用用 `mygo`，用 cgo 编译 Gio 桌面应用用 `gio`；都要就在自己 Dockerfile 里 `FROM golang:latest` 再各装一个。
