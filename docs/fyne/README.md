# Golang 构建环境 + fyne 镜像

[![定时构建](https://cnb.cool/dtapp/golang/-/badge/git/latest/ci/status/crontab)](https://cnb.cool/dtapp/golang/-/pipeline) [![流水线配置](https://cnb.cool/dtapp/golang/-/badge/git/latest/ci/pipeline-as-code)](https://cnb.cool/dtapp/golang/-/blob/main/.cnb.yml) [![漏洞扫描](https://cnb.cool/dtapp/golang/-/badge/security/vulnerability/full/latest)](https://cnb.cool/dtapp/golang/-/security) ![基础镜像](https://img.shields.io/badge/base-golang-00ADD8?logo=go&logoColor=white) ![fyne](https://img.shields.io/badge/fyne-v1.7.4-blue) ![架构](https://img.shields.io/badge/arch-amd64%20%7C%20arm64-informational) ![fyne 版本](https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/fyne_version) ![镜像大小](https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/fyne_size) ![arm64 大小](https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/fyne_size_arm64) ![镜像摘要](https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/fyne_digest_short) ![镜像版本](https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/image_version)

在 [Golang 构建环境镜像](../golang/README.md) 之上做两件事：装编译 [Fyne](https://fyne.io) 应用所需的系统依赖（`gcc` + GL / X11 / Wayland 开发包），再 `go install` 一份 `fyne` CLI。用于在 CI / 容器里编译 Fyne 桌面应用。

> **本目录的分工**：fyne 镜像 = 基座镜像 + GL/X11/Wayland 开发包 + `fyne` 二进制，所以这里只收 fyne 专属的内容（版本策略、构建用法、元数据）。构建、CI、标签、镜像源、维护、排错等共用机制都在 [`docs/golang/`](../golang/index.md)，不在这里重复。文档与实现冲突时，以三份 `Dockerfile.fyne` 与三份 `build-fyne.sh` 为准。

## 镜像里有什么

- 基座：本仓库构建的 Golang 构建环境镜像（CI 按 `<go 版本>` 钉住当天刚推好的那份；Dockerfile 默认基座是官方 `golang:1-trixie`，只用于不依赖私有仓库的本地构建）
- 继承基座全部内容：Go 工具链、UPX、nfpm、Node.js + npm + pnpm、sqlc / ent / golangci-lint / govulncheck / shfmt / dockerfmt / yamlfmt / gojq / sql-formatter / gotestsum / markdownfmt、git / curl / make / jq / zip / unzip / pkg-config、`TZ=Asia/Shanghai` 与 `C.UTF-8`
- 新增：`gcc`、`libgl1-mesa-dev`、`xorg-dev`、`libwayland-dev`、`libxkbcommon-dev`，以及 `/go/bin/fyne`（`GOPATH=/go`，已在 `PATH` 里）。`pkg-config` 在基座里已装，这里再声明一次只是为了 `FROM` 上游 `golang` 单独构建本文件时也自洽（apt 幂等）

这五个包来自 Fyne 官方文档给 Debian / Ubuntu / Raspberry Pi OS 的那一条，只去掉 `golang`（基座已是 Go 镜像）：

```sh
# 官方原文
sudo apt-get install golang gcc libgl1-mesa-dev xorg-dev libwayland-dev libxkbcommon-dev
# 本镜像实际安装
apt-get install gcc libgl1-mesa-dev xorg-dev libwayland-dev libxkbcommon-dev
```

它们是**编译 Fyne 应用**用的：应用要开 cgo 并链接 GL / X11 / Wayland，所以不能像基座镜像那样在最后 purge。装完立刻断言一遍 `pkg-config` 能解析全部 `.pc`：

```dockerfile
pkg-config --exists gl
pkg-config --exists x11
pkg-config --exists xrandr
pkg-config --exists xcursor
pkg-config --exists xinerama
pkg-config --exists xi
pkg-config --exists xxf86vm
pkg-config --exists wayland-client
pkg-config --exists xkbcommon
```

这一步不能省：头文件缺失会让镜像构建直接失败，而不是推迟到使用者手里才以 cgo 报错的形式暴露。

## fyne 版本策略

镜像里的 fyne 就一条命令装出来的：

```dockerfile
go install fyne.io/tools/cmd/fyne@${FYNE_VERSION}
```

`FYNE_VERSION` 指的是这条命令的版本，当前最新稳定 tag 是 `v1.7.4`。默认值 `latest`，不钉死某个 tag。三级兜底：

| 场景                           | 行为                                                                                                      |
|--------------------------------|-----------------------------------------------------------------------------------------------------------|
| CI 定时任务 / 手动触发留空     | 脚本在构建前用 `go list -m fyne.io/tools@latest` 解析最新稳定 tag（如 `v1.7.4`），再以 `--build-arg` 传入 |
| 手动触发填 `fyne_version`      | 按填的版本装：`v1.7.4` / `1.7.4`（自动补 `v`）都可以                                                      |
| 裸 `docker build`（不经过 CI） | `@latest` 交给 `go install` 自己解析                                                                      |

为什么要先在 CI 里解析成具体版本：buildx 的层缓存按 build-arg 的**值**算缓存键。每天都传字符串 `latest`，缓存键永远不变，编译 `fyne` 的那一层会一直命中第一次的产物，fyne 再也不升级。解析成 `v1.7.4` 之后，上游没发新版就全命中，发新版才重建那一层。

解析失败（GOPROXY 网络问题）时脚本会 `警告` 并回退 `latest`，本次构建由 Dockerfile 在构建时解析（镜像仍然可用，只是层缓存不生效、元数据里的 `fyne_version` 会记成 `latest`）。

**解析到的版本会写进元数据 `fyne_version`，但不占标签**——标签里的版本是 Go 版本，与基座同名标签一一对应。

### 两个容易踩的坑

- **`fyne.io/tools` 有 retract**。上游把 `v1.26.0` / `v1.26.1` 标成了 `retract`（误发，不是新版本，也不是「1.26 比 1.7 新」）。`go list` 会跳过它们，所以不要照着这两个数字「升级」Dockerfile 默认值。
- **别填 `v2.x`**。`fyne.io/tools` 只有 1.x，没有 v2 系列；`v2.8.2` 是另一个模块（`fyne.io/fyne/v2`，应用自己 `go.mod` 里引的那个），填进 `FYNE_VERSION` 会直接拉不到。老路径 `fyne.io/fyne/v2/cmd/fyne` 也已废弃，运行时打印「migrated to fyne.io/tools/cmd/fyne」。

## 地址与标签

| 平台   | 地址                                     |
|--------|------------------------------------------|
| CNB    | `docker.cnb.cool/dtapp/golang/fyne`      |
| GitHub | `ghcr.io/dtapps/golang/fyne`             |
| GitLab | `registry.gitlab.com/dtapps/golang/fyne` |

标签与基座同一套契约：`<go 版本>` / `<major.minor>` / `latest` / `<go 版本>-linux-{amd64,arm64}`。`<major.minor>` / `latest` 只在基座对应标签已指向同一 digest 时提升，所以 fyne 的移动标签永远不会跑到基座前面。完整契约见 [../golang/images-and-tags.md](../golang/images-and-tags.md)。

fyne 自身的版本**不占标签**：要复现某一份产物请用元数据里的 `fyne_digest`，要回到某个 fyne 版本请手动触发并填 `fyne_version`。

## 快速使用

```bash
docker run --rm ghcr.io/dtapps/golang/fyne:latest fyne version
docker run --rm -v "$PWD":/src -w /src ghcr.io/dtapps/golang/fyne:latest fyne build
```

作为 CI 的基础镜像：

```dockerfile
FROM ghcr.io/dtapps/golang/fyne:latest
# 已含 OpenGL / X11 / Wayland 开发包与 fyne CLI
```

用 `latest` / `<major.minor>` 时拿到的是当天构建；要固定产物就把元数据里的 `fyne_digest` 拿来用：

```bash
docker pull ghcr.io/dtapps/golang/fyne@sha256:<fyne_digest>
```

`fyne serve` / 运行打包出来的应用需要真实显示环境（容器里要自己准备 X11/Wayland），这个镜像只保证**构建**可用。跨平台交叉编译（Windows / macOS / 移动端）不在本镜像范围内，那是上游 [fyne-cross](https://github.com/fyne-io/fyne-cross) 的事。

## 怎么构建

- CNB：`.cnb/workflows/build-fyne.yml`，每天 12:05 由 `.cnb.yml` 定时触发（基座 00:05、fnpack 03:05、wails3 06:05、wails2 09:05 之后）；也可用「打包 Golang + fyne 镜像（多架构）」按钮手动触发，可填 `version` / `fyne_version`。
- GitHub：`.github/workflows/build-fyne.yml`，每天 04:05 UTC（北京 12:05）定时触发（基座 16:05 UTC、fnpack 19:05 UTC、wails3 22:05 UTC、wails2 01:05 UTC 之后）；手动触发同样可填 `version` / `fyne_version`。
- GitLab：`.gitlab/workflows/build-fyne.yml`，在 UI / API 建 `TARGET=fyne` 的 schedule 定时触发（基座先构建）；手动 Run pipeline 时填 `TARGET=fyne`，可再填 `VERSION` / `FYNE_VERSION`，见 [../gitlab.md](../gitlab.md)。

脚本先等 `golang:<go 版本>` 就绪（等不到直接失败），再从它构建、派生单平台标签、跑冒烟、提升移动标签。冒烟断言：

- `go version` 与基座一致；`go` / `node` / `pnpm` / `sqlc` / `golangci-lint` / `zip` / `unzip` / `pkg-config` 都在
- 上面那 10 个 `.pc` 文件逐个 `pkg-config --exists` 都成立
- `fyne` 可执行，且 `go version -m <fyne 二进制>` 里的 `mod fyne.io/tools` 版本等于本次目标版本（回退 `latest` 时只验证可执行；读模块信息比解析 `fyne version` 的输出格式可靠）
- 基座里不该出现的 `fnpack` / `wails3` / `wails` 依旧不存在

任何一步失败都会停在原地：`latest` / `<major.minor>` 不动。

## 元数据与徽章

CNB 侧写 `.cnb/annotation-fyne.json`，GitHub 侧写 `.github/annotation-fyne.json`，GitLab 侧写 `.gitlab/annotation-fyne.json`（都不入库）。

| 键                  | 含义                                        |
|---------------------|---------------------------------------------|
| `fyne_image`        | fyne 镜像全名                               |
| `fyne_digest`       | fyne manifest list digest                   |
| `fyne_digest_short` | 前 12 位 digest（只用于核对）               |
| `fyne_size`         | amd64 压缩体积                              |
| `fyne_size_arm64`   | arm64 压缩体积                              |
| `fyne_version`      | 本次安装的 fyne CLI 版本（如 `v1.7.4`）     |
| `image_version`     | 解析出的 Go 版本（与 `<go 版本>` 标签一致） |
| `golang_version`    | 同上                                        |
| `fyne_base_image`   | 本次使用的基础镜像引用                      |
| `fyne_base_digest`  | 基础镜像 digest                             |
| `built_at`          | 本次构建时间                                |
| `source_date`       | 最后一次提交时间                            |

徽章全部从 CNB commit annotation 取值，地址模板：

```text
https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/{key}
```

本页顶部那排徽章对应的 key：

| 徽章       | key                 | 说明                                 |
|------------|---------------------|--------------------------------------|
| fyne 版本  | `fyne_version`      | 如 `v1.7.4`；回退解析时显示 `latest` |
| 镜像大小   | `fyne_size`         | amd64 压缩体积                       |
| arm64 大小 | `fyne_size_arm64`   | arm64 压缩体积                       |
| 镜像摘要   | `fyne_digest_short` | 前 12 位，只用于核对，不能用于 pull  |
| 镜像版本   | `image_version`     | Go 版本，与 `<go 版本>` 标签一致     |

直接贴到自己 README 里可用（把 `{key}` 换成上表的值）：

```markdown
![fyne 版本](https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/fyne_version)
![镜像大小](https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/fyne_size)
![镜像摘要](https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/fyne_digest_short)
```

几个使用注意：

- `commit/latest` 是「最新提交」这一维度，与镜像标签 `latest` 同名但无关。
- `type: ADD` 对同一 commit 是覆盖语义：同名 key 只保留最后一次构建。要长期锁定某次产物，记下当时的 `fyne_digest` 并按 digest 拉取。
- 徽章显示灰色 `unknown` 通常意味着：这次构建失败（`cnbcool/annotations` 那步没跑）、key 从未写入，或体积解析拿到了非镜像清单（日志里会有「体积解析失败」警告）。
- GitHub 侧不写 commit 注解：同样的 JSON 写进 Step Summary，并上传 artifact `fyne-annotation`（保留 30 天）。GitLab 侧同样不写 commit 注解，JSON 作为 job artifact 保留 30 天。跨平台核对以 artifact 为准。

## 五个镜像的关系

同一 `<go 版本>` 下：

```text
golang:1.27.3        = 基座 + 全部工具链
golang/fnpack:1.27.3 = golang:1.27.3 + fnpack
golang/wails3:1.27.3 = golang:1.27.3 + GTK4/WebKitGTK + wails3
golang/wails2:1.27.3 = golang:1.27.3 + GTK3/WebKit2GTK 4.1 + wails
golang/fyne:1.27.3   = golang:1.27.3 + GL/X11/Wayland + fyne
```

fnpack、wails3、wails2 与 fyne 是四个**平级**的变体，互不包含：需要打包 `.fpk` 用 `fnpack`，编译 Wails v3 应用用 `wails3`，编译 Wails v2 应用用 `wails2`，编译 Fyne 应用用 `fyne`；都要就在自己 Dockerfile 里 `FROM golang:latest` 再各装一个。

注意 wails 与 fyne 的图形依赖**不重叠**：wails 走 GTK + WebKitGTK（webview），fyne 走 OpenGL + X11/Wayland（自绘）。所以不能用 wails3 镜像替代 fyne 镜像。
