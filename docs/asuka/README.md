# Golang 构建环境 + asuka 镜像

[![定时构建](https://cnb.cool/dtapp/golang/-/badge/git/latest/ci/status/crontab)](https://cnb.cool/dtapp/golang/-/pipeline) [![流水线配置](https://cnb.cool/dtapp/golang/-/badge/git/latest/ci/pipeline-as-code)](https://cnb.cool/dtapp/golang/-/blob/main/.cnb.yml) ![基础镜像](https://img.shields.io/badge/base-golang-00ADD8?logo=go&logoColor=white) ![asuka](https://img.shields.io/badge/asuka-CLI-blue) ![架构](https://img.shields.io/badge/arch-amd64%20%7C%20arm64-informational) ![asuka 版本](https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/asuka_version) ![镜像大小](https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/asuka_size) ![arm64 大小](https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/asuka_size_arm64) ![镜像摘要](https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/asuka_digest_short) ![镜像版本](https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/image_version)

在 [Golang 构建环境镜像](../golang/README.md) 之上做两件事：装编译 [asuka](https://github.com/egoist/asuka) Linux 桌面应用所需的系统依赖（GTK 4、libadwaita，外加无头运行库），再 `go install` 一份 `asuka` CLI。

> **asuka 是实验性的 Go 跨平台应用框架**：一次写 Go，分别用 UIKit / Android Views / AppKit / Win32 / GTK 4 + libadwaita / WebAssembly 渲染各平台原生控件。Linux 桌面目标用 GTK 4 + libadwaita，所以镜像的重点是 **GTK 4 / libadwaita 的开发与运行库齐全**：Dockerfile 第 1 层用 `pkg-config --exists` 逐个断言，缺一个就构建失败；`-dev` 包同时保留，使用者项目自己写 cgo 绑定时也能用。

> **本目录的分工**：asuka 镜像 = 基座镜像 + GTK4/libadwaita 开发包 + 无头运行库 + `asuka` CLI，所以这里只收 asuka 专属的内容（版本策略、构建用法、元数据）。构建、CI、标签、镜像源、维护、排错等共用机制都在 [`docs/golang/`](../golang/index.md)，不在这里重复。文档与实现冲突时，以三份 `Dockerfile.asuka` 与三份 `build-asuka.sh` 为准。

## 镜像里有什么

- 基座：本仓库构建的 Golang 构建环境镜像（CI 按 `<go 版本>` 钉住当天刚推好的那份；Dockerfile 默认基座是官方 `golang:1-trixie`，只用于不依赖私有仓库的本地构建）
- 继承基座全部内容：Go 工具链、UPX、nfpm、Node.js + npm + pnpm、sqlc / ent / golangci-lint / govulncheck / shfmt / dockerfmt / yamlfmt / gojq / sql-formatter / gotestsum / markdownfmt / gocover-cobertura / gcov2lcov / task、wixl、git / curl / make / jq / zip / unzip / pkg-config、`TZ=Asia/Shanghai` 与 `C.UTF-8`
- 新增系统包：`libgtk-4-dev`、`libadwaita-1-dev`、`libglib2.0-dev`、`libpango1.0-dev`、`libcairo2-dev`、`libfontconfig1-dev`、`libgdk-pixbuf-2.0-dev`、`libgraphene-1.0-dev`、`libepoxy-dev`，以及无头运行环境 `xvfb`、`xauth`、`dbus-x11`、`libgl1-mesa-dri`、`libglx-mesa0`、`libegl-mesa0`、`shared-mime-info`、`adwaita-icon-theme`、`fonts-dejavu-core`
- 新增 CLI：`/go/bin/asuka`（`GOPATH=/go`，已在 `PATH` 里；`go install github.com/egoist/asuka/cmd/asuka@${ASUKA_VERSION}`）

为什么是这一组包：

- 上游要求 Linux 桌面构建环境有 **GTK >= 4.14 与 libadwaita >= 1.5**，Debian trixie 的 `libgtk-4-dev` / `libadwaita-1-dev` 满足；`pkg-config --exists gtk4`、`pkg-config --exists libadwaita-1` 在构建期就直接断言，避免 cgo 报错推迟到使用者。
- `libglib2.0-dev` / `libpango1.0-dev` / `libcairo2-dev` / `libgraphene-1.0-dev` / `libepoxy-dev` 是 GTK4 / libadwaita 的底层编译依赖，显式声明以保证 `.pc` 可解析。
- 无头包（Xvfb + mesa + 字体）让 GUI 在没有显示器的 CI 里也能跑；`shared-mime-info` 与 `adwaita-icon-theme` 是 GTK4 程序启动时的常见运行依赖。
- 这些 `-dev` 包既是编译依赖也是运行依赖（`-dev` 会把运行库一起装上），必须留在镜像里，不能在构建末尾卸载。

## asuka 版本策略

镜像里只装一个上游二进制，因此只有**一条版本线**，对应一个 `ARG`：

| 变量            | 模块                      | 装的东西                                                                     | 默认值   |
|-----------------|---------------------------|------------------------------------------------------------------------------|----------|
| `ASUKA_VERSION` | `github.com/egoist/asuka` | `asuka` CLI：`go install github.com/egoist/asuka/cmd/asuka@${ASUKA_VERSION}` | `latest` |

上游有版本 tag（当前最新稳定版如 `v0.1.1`）。默认 `latest`，三级兜底：

| 场景                           | 行为                                                                                                                |
|--------------------------------|---------------------------------------------------------------------------------------------------------------------|
| CI 定时任务 / 手动触发留空     | 脚本在构建前用 `go list -m github.com/egoist/asuka@latest` 解析最新稳定 tag（如 `v0.1.1`），再以 `--build-arg` 传入 |
| 手动触发填版本                 | 按填的版本装：`v0.1.1` / `0.1.1`（自动补 `v`）都可以                                                                |
| 裸 `docker build`（不经过 CI） | `@latest` 交给 `go install` 自己解析                                                                                |

为什么要先在 CI 里解析成具体版本：buildx 的层缓存按 build-arg 的**值**算缓存键。每天都传字符串 `latest`，缓存键永远不变，`go install` 那层会一直命中第一次的产物，asuka 再也不升级。解析成 `v0.1.1` 之后，上游没发新版就全命中，发新版才重建那一层。

解析失败（GOPROXY 网络问题）时脚本会 `警告` 并回退 `latest`，本次构建由 Dockerfile 在构建时解析（镜像仍然可用，只是层缓存不生效、元数据里的 `asuka_version` 会记成 `latest`）。

**解析到的版本会写进元数据 `asuka_version`，但不占标签**——标签里的版本是 Go 版本，与基座同名标签一一对应。

> asuka 是 pre-1.0 的实验项目，上游 API 可能频繁变化；**没有 `--version` / `version` 子命令**，冒烟用 `asuka --help`（打印 usage、退出码 0）验证 CLI 可运行，版本直接从 `go version -m` 的内嵌模块信息读取。

## 地址与标签

| 平台   | 地址                                      |
|--------|-------------------------------------------|
| CNB    | `docker.cnb.cool/dtapp/golang/asuka`      |
| GitHub | `ghcr.io/dtapps/golang/asuka`             |
| GitLab | `registry.gitlab.com/dtapps/golang/asuka` |

标签与基座同一套契约：`<go 版本>` / `<major.minor>` / `latest` / `<go 版本>-linux-{amd64,arm64}`。`<major.minor>` / `latest` 只在基座对应标签已指向同一 digest 时提升，所以 asuka 的移动标签永远不会跑到基座前面。完整契约见 [../golang/images-and-tags.md](../golang/images-and-tags.md)。

asuka 的 CLI 版本**不占标签**：要复现某一份产物请用元数据里的 `asuka_digest`，要回到某个版本请手动触发并填 `asuka_version`。

## 快速使用

```bash
# 验证 CLI 能跑（asuka 没有 version 子命令）
docker run --rm ghcr.io/dtapps/golang/asuka:latest asuka --help

# 从模块信息读实际装上的 asuka 版本
docker run --rm ghcr.io/dtapps/golang/asuka:latest sh -c 'go version -m "$(command -v asuka)" | grep "^[[:space:]]*mod"'

# 在容器里编译一个 asuka Linux 桌面应用
docker run --rm -v "$PWD":/src -w /src ghcr.io/dtapps/golang/asuka:latest asuka build -p linux

# 没有显示器时用镜像自带的 Xvfb 跑开发模式
docker run --rm -v "$PWD":/src -w /src ghcr.io/dtapps/golang/asuka:latest xvfb-run -a asuka dev -p linux
```

## CI 触发

- CNB：`.cnb/workflows/build-asuka.yml`，每天 **11:05** 由该文件内的 `crontab: 5 11 * * *` 定时触发，排在 viva（10:05）之后 1 小时；也可用「打包 Golang + asuka 镜像（多架构）」按钮手动触发，可填 `version` / `asuka_version`。
- GitHub：`.github/workflows/build-asuka.yml`，每天 **03:05 UTC（北京 11:05）** 定时触发，对应 cron `5 3 * * *`，排在 build-viva（02:05 UTC）之后 1 小时；手动触发同样可填 `version` / `asuka_version`。
- GitLab：`.gitlab/workflows/build-asuka.yml` 由根 `.gitlab-ci.yml` include；建议 schedule 变量 `TARGET=asuka`，cron 选 `Asia/Shanghai` 时填 `5 11 * * *`，选 UTC 时填 `5 3 * * *`（GitLab 的 cron 建在 UI / API，不写在 YAML 里）。

## 元数据与徽章

CI 把本次产物信息写到 `.cnb/annotation-asuka.json` / `.github/annotation-asuka.json` / `.gitlab/annotation-asuka.json`：

| key                  | 含义                              |
|----------------------|-----------------------------------|
| `asuka_image`        | 完整镜像地址                      |
| `asuka_digest`       | 多架构清单 digest                 |
| `asuka_digest_short` | digest 前 12 位，徽章用           |
| `asuka_size`         | linux/amd64 镜像体积              |
| `asuka_size_arm64`   | linux/arm64 镜像体积              |
| `asuka_version`      | 本次装上的 asuka 版本（不占标签） |
| `image_version`      | Go 版本（与基座同名标签一致）     |
| `golang_version`     | 基座实际 Go 版本                  |
| `asuka_base_image`   | 作为基座的基础镜像引用            |
| `asuka_base_digest`  | 基座清单 digest                   |
| `apt_versions`       | 新增 apt 包的实际版本             |
| `built_at`           | 构建完成时间                      |
| `source_date`        | 源码最后提交时间                  |

任何一步失败都会停在原地，`latest` / `<major.minor>` 不会提升；排错见 [golang/troubleshooting.md](../golang/troubleshooting.md)。

## 九个镜像的关系

fnpack、wails3、wails2、fyne、mygo、gio、nsgo、viva 与 asuka 是九个**平级**的变体，互不包含：需要打包 `.fpk` 用 `fnpack`，需要编译 Wails v3 应用用 `wails3`，编译 Wails v2 应用用 `wails2`，编译 Fyne 桌面应用用 `fyne`，编译 MyGo 桌面应用用 `mygo`，用 cgo 编译 Gio 桌面应用用 `gio`，编译 nsgo 应用用 `nsgo`，编译 viva 应用用 `viva`，编译 asuka 应用用 `asuka`；都要就在自己 Dockerfile 里 `FROM golang:latest` 再各装一个。
