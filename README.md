# Golang 构建环境镜像（golang / golang+fnpack / golang+wails3 / golang+wails2 / golang+fyne / golang+mygo / golang+gio）

[![定时构建](https://cnb.cool/dtapp/golang/-/badge/git/latest/ci/status/crontab)](https://cnb.cool/dtapp/golang/-/pipeline) [![流水线配置](https://cnb.cool/dtapp/golang/-/badge/git/latest/ci/pipeline-as-code)](https://cnb.cool/dtapp/golang/-/blob/main/.cnb.yml) [![漏洞扫描](https://cnb.cool/dtapp/golang/-/badge/security/vulnerability/full/latest)](https://cnb.cool/dtapp/golang/-/security) [![CNB 访问](https://commit.cool/badge/visit/dtapp/golang)](https://cnb.cool/dtapp/golang) [![build-golang](https://github.com/dtapps/golang/actions/workflows/build-golang.yml/badge.svg)](https://github.com/dtapps/golang/actions/workflows/build-golang.yml) [![build-fnpack](https://github.com/dtapps/golang/actions/workflows/build-fnpack.yml/badge.svg)](https://github.com/dtapps/golang/actions/workflows/build-fnpack.yml) [![build-wails3](https://github.com/dtapps/golang/actions/workflows/build-wails3.yml/badge.svg)](https://github.com/dtapps/golang/actions/workflows/build-wails3.yml) [![build-wails2](https://github.com/dtapps/golang/actions/workflows/build-wails2.yml/badge.svg)](https://github.com/dtapps/golang/actions/workflows/build-wails2.yml) [![build-fyne](https://github.com/dtapps/golang/actions/workflows/build-fyne.yml/badge.svg)](https://github.com/dtapps/golang/actions/workflows/build-fyne.yml) [![build-mygo](https://github.com/dtapps/golang/actions/workflows/build-mygo.yml/badge.svg)](https://github.com/dtapps/golang/actions/workflows/build-mygo.yml) [![build-gio](https://github.com/dtapps/golang/actions/workflows/build-gio.yml/badge.svg)](https://github.com/dtapps/golang/actions/workflows/build-gio.yml) [![GitHub 访问](https://visitor-badge.laobi.icu/badge?page_id=github/dtapps/golang)](https://github.com/dtapps/golang) [![GitLab CI](https://gitlab.com/dtapps/golang/badges/main/pipeline.svg)](https://gitlab.com/dtapps/golang/-/pipelines) [![GitLab 访问](https://visitor-badge.laobi.icu/badge?page_id=gitlab/dtapps/golang)](https://gitlab.com/dtapps/golang)

[![cnb pulls (7 镜像合计)](https://commit.cool/badge/package/docker/pulls/dtapp/golang)](https://docker.cnb.cool/dtapp/golang) [![ghcr golang pulls](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fghcr-badge.elias.eu.org%2Fapi%2Fdtapps%2Fgolang&query=downloadCount&label=ghcr%20golang%20pulls&logo=docker&logoColor=white&color=2496ed)](https://github.com/dtapps/golang/pkgs/container/golang) [![ghcr fnpack pulls](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fghcr-badge.elias.eu.org%2Fapi%2Fdtapps%2Fgolang%25252Ffnpack&query=downloadCount&label=ghcr%20fnpack%20pulls&logo=docker&logoColor=white&color=2496ed)](https://github.com/dtapps/golang/pkgs/container/golang%2Ffnpack) [![ghcr wails3 pulls](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fghcr-badge.elias.eu.org%2Fapi%2Fdtapps%2Fgolang%25252Fwails3&query=downloadCount&label=ghcr%20wails3%20pulls&logo=docker&logoColor=white&color=2496ed)](https://github.com/dtapps/golang/pkgs/container/golang%2Fwails3) [![ghcr wails2 pulls](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fghcr-badge.elias.eu.org%2Fapi%2Fdtapps%2Fgolang%25252Fwails2&query=downloadCount&label=ghcr%20wails2%20pulls&logo=docker&logoColor=white&color=2496ed)](https://github.com/dtapps/golang/pkgs/container/golang%2Fwails2) [![ghcr fyne pulls](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fghcr-badge.elias.eu.org%2Fapi%2Fdtapps%2Fgolang%25252Ffyne&query=downloadCount&label=ghcr%20fyne%20pulls&logo=docker&logoColor=white&color=2496ed)](https://github.com/dtapps/golang/pkgs/container/golang%2Ffyne) [![ghcr mygo pulls](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fghcr-badge.elias.eu.org%2Fapi%2Fdtapps%2Fgolang%25252Fmygo&query=downloadCount&label=ghcr%20mygo%20pulls&logo=docker&logoColor=white&color=2496ed)](https://github.com/dtapps/golang/pkgs/container/golang%2Fmygo) [![ghcr gio pulls](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fghcr-badge.elias.eu.org%2Fapi%2Fdtapps%2Fgolang%25252Fgio&query=downloadCount&label=ghcr%20gio%20pulls&logo=docker&logoColor=white&color=2496ed)](https://github.com/dtapps/golang/pkgs/container/golang%2Fgio)

本仓库用三套平台构建七个自建镜像：CNB 推送到制品库（`docker.cnb.cool/dtapp/golang`），GitHub Actions 推送到 GHCR（`ghcr.io/dtapps/golang`），GitLab CI 推送到 GitLab Container Registry（`registry.gitlab.com/dtapps/golang`；脚本里不写死地址，用的是 GitLab 自动注入的 `CI_REGISTRY_IMAGE`，其值就是 `registry.gitlab.com/<group>/<project>`）。每个镜像在每套平台上都有独立的 workflow / job 与构建脚本（各自维护，不互相引用），标签契约保持一致；改镜像内容或标签规则时三份都要改，见 [docs/github.md](docs/github.md) 与 [docs/gitlab.md](docs/gitlab.md)。

## 七个镜像

| 镜像                           | CNB 地址                              | GitHub 地址（GHCR）            | GitLab 地址                                | Dockerfile（CNB / GitHub / GitLab）                                                                       | 文档                                  |
|--------------------------------|---------------------------------------|--------------------------------|--------------------------------------------|-----------------------------------------------------------------------------------------------------------|---------------------------------------|
| Golang 构建环境（不含 fnpack） | `docker.cnb.cool/dtapp/golang`        | `ghcr.io/dtapps/golang`        | `registry.gitlab.com/dtapps/golang`        | `.cnb/docker/Dockerfile.golang` / `.github/docker/Dockerfile.golang` / `.gitlab/docker/Dockerfile.golang` | [docs/golang/](docs/golang/README.md) |
| Golang 构建环境 + fnpack       | `docker.cnb.cool/dtapp/golang/fnpack` | `ghcr.io/dtapps/golang/fnpack` | `registry.gitlab.com/dtapps/golang/fnpack` | `.cnb/docker/Dockerfile.fnpack` / `.github/docker/Dockerfile.fnpack` / `.gitlab/docker/Dockerfile.fnpack` | [docs/fnpack/](docs/fnpack/README.md) |
| Golang 构建环境 + wails3       | `docker.cnb.cool/dtapp/golang/wails3` | `ghcr.io/dtapps/golang/wails3` | `registry.gitlab.com/dtapps/golang/wails3` | `.cnb/docker/Dockerfile.wails3` / `.github/docker/Dockerfile.wails3` / `.gitlab/docker/Dockerfile.wails3` | [docs/wails3/](docs/wails3/README.md) |
| Golang 构建环境 + wails2       | `docker.cnb.cool/dtapp/golang/wails2` | `ghcr.io/dtapps/golang/wails2` | `registry.gitlab.com/dtapps/golang/wails2` | `.cnb/docker/Dockerfile.wails2` / `.github/docker/Dockerfile.wails2` / `.gitlab/docker/Dockerfile.wails2` | [docs/wails2/](docs/wails2/README.md) |
| Golang 构建环境 + fyne         | `docker.cnb.cool/dtapp/golang/fyne`   | `ghcr.io/dtapps/golang/fyne`   | `registry.gitlab.com/dtapps/golang/fyne`   | `.cnb/docker/Dockerfile.fyne` / `.github/docker/Dockerfile.fyne` / `.gitlab/docker/Dockerfile.fyne`       | [docs/fyne/](docs/fyne/README.md)     |
| Golang 构建环境 + mygo         | `docker.cnb.cool/dtapp/golang/mygo`   | `ghcr.io/dtapps/golang/mygo`   | `registry.gitlab.com/dtapps/golang/mygo`   | `.cnb/docker/Dockerfile.mygo` / `.github/docker/Dockerfile.mygo` / `.gitlab/docker/Dockerfile.mygo`       | [docs/mygo/](docs/mygo/README.md)     |
| Golang 构建环境 + gio          | `docker.cnb.cool/dtapp/golang/gio`    | `ghcr.io/dtapps/golang/gio`    | `registry.gitlab.com/dtapps/golang/gio`    | `.cnb/docker/Dockerfile.gio` / `.github/docker/Dockerfile.gio` / `.gitlab/docker/Dockerfile.gio`          | [docs/gio/](docs/gio/README.md)       |

构建脚本按镜像拆分：CNB 用 `.cnb/scripts/build-golang.sh`、`build-fnpack.sh`、`build-wails3.sh`、`build-wails2.sh`、`build-fyne.sh`、`build-mygo.sh` 与 `build-gio.sh`，GitHub 用 `.github/scripts/` 下的同名七份，GitLab 用 `.gitlab/scripts/` 下的同名七份。六个变体都依赖同版本的 golang 基础镜像：先发布基础镜像，再 `FROM` 它构建各自的变体，彼此平级、互不包含。三侧的标签名、提升规则、冒烟断言必须保持一致，平台胶水（触发器、镜像源、元数据落地）各自维护。

**镜像里有什么**

- Go 工具链（基座 `golang:1-trixie`，自动跟随最新稳定 Go）
- UPX、nfpm、wixl（`wixl` + `wixl-data`，在 Linux 上编译 Windows MSI）
- Node.js + npm + pnpm
- sqlc、ent/entc、golangci-lint、govulncheck、shfmt、dockerfmt、yamlfmt、gojq、sql-formatter、gotestsum、markdownfmt、gocover-cobertura（都用 `go install -v`，CI 日志能看编译进度）
- 基础命令：git、curl、make、jq、zip/unzip、pkg-config
- 时区与语言：`TZ=Asia/Shanghai`、`LANG`/`LC_ALL`=`C.UTF-8`，已装 `tzdata`
- fnpack 镜像只多一个 `fnpack`；wails3 镜像多 GTK4/WebKitGTK 开发包与 `wails3` CLI；wails2 镜像多 GTK3/WebKit2GTK 4.1 开发包与 `wails` CLI；fyne 镜像多 OpenGL/X11/Wayland 开发包与 `fyne` CLI；mygo 镜像多 GTK3/WebKitGTK 4.1 开发包、无头运行库、`mygo` CLI 与 `bun`；gio 镜像多 EGL/GLES、X11、Wayland、Vulkan 开发包与无头运行库、`gogio` CLI（模块 `gioui.org/cmd`）。七个镜像的工具链完全一致

**七个镜像怎么选**

- 只需要 Go 构建、打包 deb/rpm、前端依赖或代码检查：用 `golang`。
- 需要给 FnOS 打 `.fpk` 包：用 `golang/fnpack`。
- 需要编译 Wails v3 桌面应用：用 `golang/wails3`。
- 需要编译 Wails v2 桌面应用：用 `golang/wails2`，构建时加 `-tags webkit2_41`（见 [docs/wails2/](docs/wails2/README.md)）。
- 需要编译 Fyne 桌面应用：用 `golang/fyne`，镜像里已备好 OpenGL/X11/Wayland 开发包与 `fyne` CLI（见 [docs/fyne/](docs/fyne/README.md)）。
- 需要编译 MyGo 桌面应用：用 `golang/mygo`，镜像里已备好 GTK3/WebKitGTK 4.1 开发包、无头运行库、`mygo` CLI 与 `bun`（见 [docs/mygo/](docs/mygo/README.md)）。
- 需要编译 Gio 桌面应用：用 `golang/gio`，镜像里已备好 EGL/GLES、X11、Wayland、Vulkan 开发包与无头运行库，以及打包工具 `gogio`（模块 `gioui.org/cmd`；`gogio` 没有 linux 目标，Linux 桌面程序就是普通 `go build` + cgo，见 [docs/gio/](docs/gio/README.md)）。
- 七个镜像的标签完全对应：同一个 `<go 版本>` 下，各变体就是基础镜像加各自的 CLI 与依赖。

## 快速使用

```bash
# 拉 CNB 制品库、GHCR 或 GitLab Registry 都行，标签规则一致
docker run --rm -it docker.cnb.cool/dtapp/golang:latest bash
docker run --rm -it ghcr.io/dtapps/golang:latest bash
docker run --rm -it registry.gitlab.com/dtapps/golang:latest bash

# 带 fnpack 的版本
docker run --rm docker.cnb.cool/dtapp/golang/fnpack:latest fnpack --help
docker run --rm ghcr.io/dtapps/golang/fnpack:latest fnpack --help

# 带 wails3 的版本
docker run --rm docker.cnb.cool/dtapp/golang/wails3:latest wails3 version
docker run --rm ghcr.io/dtapps/golang/wails3:latest wails3 version

# 带 wails2 的版本（构建应用时加 -tags webkit2_41）
docker run --rm docker.cnb.cool/dtapp/golang/wails2:latest wails version
docker run --rm ghcr.io/dtapps/golang/wails2:latest wails version

# 带 fyne 的版本
docker run --rm docker.cnb.cool/dtapp/golang/fyne:latest fyne version
docker run --rm ghcr.io/dtapps/golang/fyne:latest fyne version

# 带 mygo 的版本
docker run --rm docker.cnb.cool/dtapp/golang/mygo:latest mygo version
docker run --rm ghcr.io/dtapps/golang/mygo:latest mygo version

# 带 gio 的版本（gogio 没有 version 子命令，看 go version -m 里记录的模块版本）
docker run --rm docker.cnb.cool/dtapp/golang/gio:latest sh -c 'go version -m "$(command -v gogio)"'
docker run --rm ghcr.io/dtapps/golang/gio:latest sh -c 'go version -m "$(command -v gogio)"'
```

作为基础镜像：

```dockerfile
FROM docker.cnb.cool/dtapp/golang:latest
# 或
FROM ghcr.io/dtapps/golang:latest
# 需要 fnpack：ghcr.io/dtapps/golang/fnpack:latest
# 需要 wails3：ghcr.io/dtapps/golang/wails3:latest
# 需要 wails2：ghcr.io/dtapps/golang/wails2:latest
# 需要 fyne：ghcr.io/dtapps/golang/fyne:latest
# 需要 mygo：ghcr.io/dtapps/golang/mygo:latest
# 需要 gio：ghcr.io/dtapps/golang/gio:latest
```

## 仓库结构

```text
.cnb/
├── docker/
│   ├── Dockerfile.golang           # golang 基础镜像（不含 fnpack / wails3 / wails2 / fyne / mygo / gio）
│   ├── Dockerfile.fnpack           # 在 golang 镜像上加 fnpack
│   ├── Dockerfile.wails3           # 在 golang 镜像上加 GTK4/WebKitGTK + wails3
│   ├── Dockerfile.wails2           # 在 golang 镜像上加 GTK3/WebKit2GTK 4.1 + wails
│   ├── Dockerfile.fyne             # 在 golang 镜像上加 OpenGL/X11/Wayland + fyne
│   ├── Dockerfile.mygo             # 在 golang 镜像上加 GTK3/WebKitGTK 4.1 + 无头运行库 + mygo + bun
│   └── Dockerfile.gio              # 在 golang 镜像上加 EGL/GLES + X11 + Wayland + Vulkan + 无头运行库 + gogio
├── scripts/
│   ├── build-golang.sh             # CNB：构建、冒烟、发布 golang 基础镜像
│   ├── build-fnpack.sh             # CNB：基于基础镜像构建、冒烟、发布 fnpack
│   ├── build-wails3.sh             # CNB：基于基础镜像构建、冒烟、发布 wails3
│   ├── build-wails2.sh             # CNB：基于基础镜像构建、冒烟、发布 wails2
│   ├── build-fyne.sh               # CNB：基于基础镜像构建、冒烟、发布 fyne
│   ├── build-mygo.sh               # CNB：基于基础镜像构建、冒烟、发布 mygo
│   └── build-gio.sh                # CNB：基于基础镜像构建、冒烟、发布 gio
├── workflows/                      # build-{golang,fnpack,wails3,wails2,fyne,mygo,gio}.yml / 扫描与评审
└── web_trigger.yml                 # 七个手动构建按钮（golang / fnpack / wails3 / wails2 / fyne / mygo / gio）
.github/
├── docker/                         # GitHub 侧的 Dockerfile
├── scripts/                        # GitHub 侧的七份构建脚本
├── workflows/
│   ├── build-golang.yml            # GitHub：构建并推送 golang 基础镜像
│   ├── build-fnpack.yml            # GitHub：定时构建并推送 fnpack
│   ├── build-wails3.yml            # GitHub：定时构建并推送 wails3
│   ├── build-wails2.yml            # GitHub：定时构建并推送 wails2
│   ├── build-fyne.yml              # GitHub：定时构建并推送 fyne
│   ├── build-mygo.yml              # GitHub：定时构建并推送 mygo
│   └── build-gio.yml               # GitHub：定时构建并推送 gio
├── annotation.json                 # golang 镜像元数据（CI 生成，.gitignore 已排除）
├── annotation-fnpack.json          # fnpack 镜像元数据（CI 生成，.gitignore 已排除）
├── annotation-wails3.json          # wails3 镜像元数据（CI 生成，.gitignore 已排除）
├── annotation-wails2.json          # wails2 镜像元数据（CI 生成，.gitignore 已排除）
├── annotation-fyne.json            # fyne 镜像元数据（CI 生成，.gitignore 已排除）
├── annotation-mygo.json            # mygo 镜像元数据（CI 生成，.gitignore 已排除）
├── annotation-gio.json             # gio 镜像元数据（CI 生成，.gitignore 已排除）
└── dependabot.yml                  # GitHub Actions 依赖更新
.gitlab/
├── docker/                         # GitLab 侧的 Dockerfile
├── scripts/                        # GitLab 侧的七份构建脚本
├── workflows/
│   ├── build-golang.yml            # GitLab：构建并推送 golang 基础镜像
│   ├── build-fnpack.yml            # GitLab：构建并推送 fnpack
│   ├── build-wails3.yml            # GitLab：构建并推送 wails3
│   ├── build-wails2.yml            # GitLab：构建并推送 wails2
│   ├── build-fyne.yml              # GitLab：构建并推送 fyne
│   ├── build-mygo.yml              # GitLab：构建并推送 mygo
│   └── build-gio.yml               # GitLab：构建并推送 gio
└── annotation*.json                # 镜像元数据（CI 生成，.gitignore 已排除）
docs/
├── golang/                         # 镜像层文档（README + 分册索引 + 分册，七个镜像合写）
├── fnpack/                         # fnpack 专属文档（速查 + 索引 + 打包/Dockerfile/元数据徽章）
├── wails3/                         # wails3 专属文档（速查 + 版本策略 + 元数据）
├── wails2/                         # wails2 专属文档（速查 + 版本策略 + build tag + 元数据）
├── fyne/                           # fyne 专属文档（速查 + 版本策略 + 元数据）
├── mygo/                           # mygo 专属文档（速查 + 版本策略 + 元数据）
├── gio/                            # gio 专属文档（速查 + 版本策略 + cgo 依赖 + 元数据）
├── cache-implementation.md         # buildx 层缓存的实现与失效边界
├── cnb.md                          # CNB 平台层说明
├── github.md                       # GitHub Actions / GHCR 平台说明
└── gitlab.md                       # GitLab CI / GitLab Registry 平台说明
备份/                               # 改造前的两份参考 Dockerfile
```

## 镜像源

| 平台           | GitHub Release / nodejs.org   | APT                 | Go module                   | npm / pnpm                |
|----------------|-------------------------------|---------------------|-----------------------------|---------------------------|
| GitHub Actions | 直连 github.com / nodejs.org  | 默认 deb.debian.org | 默认 proxy.golang.org       | 官方 `registry.npmjs.org` |
| GitLab CI      | 直连 github.com / nodejs.org  | 默认 deb.debian.org | 默认 proxy.golang.org       | 官方 `registry.npmjs.org` |
| CNB            | `https://files.m.daocloud.io` | 腾讯云              | `mirrors.cloud.tencent.com` | 腾讯云                    |

GitHub 与 GitLab 的 Dockerfile 全部直连官方源（Go / APT / npm / 下载源都不设镜像）；CNB 的 Dockerfile 有 `GITHUB_MIRROR` / `NODE_MIRROR` 开关，由构建脚本传入 DaoCloud 镜像，并把 APT、Go module、npm 换成腾讯云。细节见 [docs/golang/mirrors.md](docs/golang/mirrors.md)。

## 约定

- 提交前跑 `make format`（yamlfmt / markdownfmt / shfmt / dockerfmt）与 `make lint-shell`；范围包含 `.cnb/`、`.github/` 与 `.gitlab/` 三侧的脚本、Dockerfile 与 workflow。
- CI 启用 buildx 层缓存（`<镜像>:buildcache`）：工具版本在构建前解析成具体版本号，上游没发新版时构建只拉基座、跑冒烟。需要一次干净的全量重建时设 `CACHE=off`，见 [docs/golang/build.md](docs/golang/build.md#缓存)。
- 标签是对外契约：`<go 版本>` / `<major.minor>` / `latest`，外加 `<go 版本>-linux-{amd64,arm64}`。标签每天可能被同名覆盖，固定产物请用元数据里的 digest。
- fnpack / wails3 / wails2 / fyne / mygo / gio 镜像永远基于同版本的 golang 基础镜像构建；基础镜像的 `latest` / `<minor>` 没跟上时，各变体都不会单独提升这两个标签。
- 变体 CLI 的版本跟随上游最新：wails3 的 `WAILS3_VERSION`、wails2 的 `WAILS2_VERSION`、fyne 的 `FYNE_VERSION`、mygo 的 `MYGO_VERSION` 与 gio 的 `GIO_VERSION` 默认都是 `latest`，CI 构建前用 `go list -m` 解析成具体 tag 再传进 `--build-arg`（层缓存才跟得上版本）；mygo 镜像里的 `bun` 走 `BUN_VERSION`，构建前用 `npm view bun version` 解析；fnpack 上游没有 latest 接口，`FNPACK_VERSION` 是具体版本号（当前 `1.2.3`）。实际安装的版本记录在元数据 `fnpack_version` / `wails3_version` / `wails2_version` / `fyne_version` / `mygo_version` / `bun_version` / `gio_version`，不占标签。
- wails2 镜像装的是 WebKit2GTK 4.1，编译应用时要加 `-tags webkit2_41`，见 [docs/wails2/](docs/wails2/README.md)。
- fyne 镜像装的是 OpenGL/X11/Wayland 开发包与 `fyne` CLI，编译应用直接 `fyne build` / `fyne package`，见 [docs/fyne/](docs/fyne/README.md)。
- mygo 镜像装的是 GTK3/WebKitGTK 4.1 开发包、无头运行库、`mygo` CLI 与 `bun`；mygo 的 Linux 后端纯 Go（运行期 `dlopen` GTK3），编译应用不需要 build tag，见 [docs/mygo/](docs/mygo/README.md)。
- gio 镜像装的是 EGL/GLES、X11、Wayland、Vulkan 开发包、无头运行库与打包工具 `gogio`（模块 `gioui.org/cmd`，不是 `gio`）；`gogio` 没有 linux 目标也没有 `version` 子命令，Linux 桌面程序就是普通 `go build` + cgo，镜像的价值在 cgo 依赖齐全（Dockerfile 里会真实编译一个最小 Gio 程序自证），见 [docs/gio/](docs/gio/README.md)。
- 三个平台的 Dockerfile 与脚本各自维护（`.cnb/`、`.github/` 与 `.gitlab/`）：改镜像内容、标签规则或冒烟断言时三处都要改；只改平台胶水时各改各的。平台层说明见 [docs/cnb.md](docs/cnb.md)、[docs/github.md](docs/github.md) 与 [docs/gitlab.md](docs/gitlab.md)。
- 安全报告走 [SECURITY.md](SECURITY.md)，贡献流程与硬性规则见 [CONTRIBUTING.md](CONTRIBUTING.md)。
- 文档入口：[docs/README.md](docs/README.md)。

## 许可

[MIT](LICENSE)
