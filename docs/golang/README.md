# Golang 构建环境镜像

[![定时构建](https://cnb.cool/dtapp/golang/-/badge/git/latest/ci/status/crontab)](https://cnb.cool/dtapp/golang/-/pipeline) [![流水线配置](https://cnb.cool/dtapp/golang/-/badge/git/latest/ci/pipeline-as-code)](https://cnb.cool/dtapp/golang/-/blob/main/.cnb.yml) [![漏洞扫描](https://cnb.cool/dtapp/golang/-/badge/security/vulnerability/full/latest)](https://cnb.cool/dtapp/golang/-/security) ![基础镜像](https://img.shields.io/badge/base-golang-00ADD8?logo=go&logoColor=white) ![架构](https://img.shields.io/badge/arch-amd64%20%7C%20arm64-informational) ![镜像大小](https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/golang_size) ![arm64 大小](https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/golang_size_arm64) ![镜像摘要](https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/golang_digest_short) ![镜像版本](https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/image_version)

十个镜像共用一套 Go 工具链，区别只在于各自多装的 CLI：

| 镜像            | 额外内容                                                         | 典型用途                                       |
|-----------------|------------------------------------------------------------------|------------------------------------------------|
| `golang`        | 无                                                               | Go 编译、golangci-lint、前端依赖、deb/rpm 打包 |
| `golang/fnpack` | `fnpack`                                                         | 在上一行的基础上给 FnOS 打 `.fpk` 包           |
| `golang/wails3` | GTK4/WebKitGTK 开发包 + `wails3` CLI                             | 在容器里编译 Wails v3 桌面应用                 |
| `golang/wails2` | GTK3/WebKit2GTK 4.1 开发包 + `wails` CLI                         | 在容器里编译 Wails v2 桌面应用                 |
| `golang/fyne`   | OpenGL/X11/Wayland 开发包 + `fyne` CLI                           | 在容器里编译 Fyne 桌面应用                     |
| `golang/mygo`   | GTK3/WebKitGTK 4.1 开发包 + 无头运行库 + `mygo` CLI + `bun`      | 在容器里编译 MyGo 桌面应用                     |
| `golang/gio`    | EGL/GLES、X11、Wayland、Vulkan 开发包 + 无头运行库 + `gogio` CLI | 在容器里用 cgo 编译 Gio 桌面应用               |
| `golang/nsgo`   | GTK4/WebKitGTK 6.0/GStreamer 开发包 + 无头运行库 + `nsgo` CLI    | 在容器里编译 nsgo 桌面应用                     |
| `golang/viva`   | XCB/Vulkan、GTK3/WebKit2GTK 4.1 开发包 + 无头运行库 + `viva` CLI | 在容器里编译 viva 桌面应用                     |

## 镜像里有什么

- 基座：`golang:1-trixie`（Debian trixie，自动跟随最新稳定 Go）
- 下载与打包工具：UPX、nfpm；另有 `wixl` / `wixl-data`（msitools），在 Linux 上直接编译 Windows MSI
- Node.js 26 + npm + pnpm 12
- Go 工具：sqlc、ent/entc、golangci-lint、govulncheck、shfmt、dockerfmt、yamlfmt、gojq、sql-formatter、gotestsum、markdownfmt、gocover-cobertura、gcov2lcov、task（go-task）
- 平台 CLI：GitHub CLI（`gh`）与 CNB CLI（`cnb`），均装官方二进制；`CNB_API_ENDPOINT` 默认公有云端点
- 基础命令：git、curl、make、jq、zip/unzip、pkg-config
- 时区与语言：`TZ=Asia/Shanghai`、`LANG=C.UTF-8`、`LC_ALL=C.UTF-8`，并装了 `tzdata`（容器内 `date` 显示 CST，构建日志与产物时间戳统一北京时间）

`golang/fnpack` 只多一个 `/usr/local/bin/fnpack`；`golang/wails3` 多 GTK4/WebKitGTK 6.0 开发包与 `/go/bin/wails3`；`golang/wails2` 多 GTK3/WebKit2GTK 4.1 开发包与 `/go/bin/wails`；`golang/fyne` 多 OpenGL/X11/Wayland 开发包与 `/go/bin/fyne`；`golang/mygo` 多 GTK3/WebKitGTK 4.1 开发包、无头运行库（Xvfb + mesa + 字体）、`/go/bin/mygo` 与 `bun`；`golang/gio` 多 EGL/GLES、X11、Wayland、Vulkan 开发包、无头运行库（Xvfb + mesa + DRI 驱动 + 字体）与 `/go/bin/gogio`；`golang/nsgo` 多 GTK4/WebKitGTK 6.0/Pango/Cairo/GStreamer 开发包、无头运行库与 `/go/bin/nsgo`；`golang/viva` 多 XCB/Vulkan/Pango/Cairo 与 GTK3/WebKit2GTK 4.1 开发包、无头运行库与 `/go/bin/viva`。八者都完全继承 `golang` 的其余内容（含 `zip`/`unzip`/`pkg-config`）。

> gio 变体的 CLI 叫 `gogio`（模块 `gioui.org/cmd`），镜像里**没有** `gio` 这个二进制。`gogio` 是打包工具（android / ios / tvos / js / windows / macos），没有 linux 目标，也没有 `version` 子命令；Linux 桌面程序就是普通 `go build` + cgo，镜像的价值在 cgo 依赖齐全。

## 地址与标签

| 平台   | golang                              | golang/fnpack                              | golang/wails3                              | golang/wails2                              | golang/fyne                              | golang/mygo                              | golang/gio                              | golang/nsgo                              | golang/viva                              |
|--------|-------------------------------------|--------------------------------------------|--------------------------------------------|--------------------------------------------|------------------------------------------|------------------------------------------|-----------------------------------------|------------------------------------------|------------------------------------------|
| CNB    | `docker.cnb.cool/dtapp/golang`      | `docker.cnb.cool/dtapp/golang/fnpack`      | `docker.cnb.cool/dtapp/golang/wails3`      | `docker.cnb.cool/dtapp/golang/wails2`      | `docker.cnb.cool/dtapp/golang/fyne`      | `docker.cnb.cool/dtapp/golang/mygo`      | `docker.cnb.cool/dtapp/golang/gio`      | `docker.cnb.cool/dtapp/golang/nsgo`      | `docker.cnb.cool/dtapp/golang/viva`      |
| GitHub | `ghcr.io/dtapps/golang`             | `ghcr.io/dtapps/golang/fnpack`             | `ghcr.io/dtapps/golang/wails3`             | `ghcr.io/dtapps/golang/wails2`             | `ghcr.io/dtapps/golang/fyne`             | `ghcr.io/dtapps/golang/mygo`             | `ghcr.io/dtapps/golang/gio`             | `ghcr.io/dtapps/golang/nsgo`             | `ghcr.io/dtapps/golang/viva`             |
| GitLab | `registry.gitlab.com/dtapps/golang` | `registry.gitlab.com/dtapps/golang/fnpack` | `registry.gitlab.com/dtapps/golang/wails3` | `registry.gitlab.com/dtapps/golang/wails2` | `registry.gitlab.com/dtapps/golang/fyne` | `registry.gitlab.com/dtapps/golang/mygo` | `registry.gitlab.com/dtapps/golang/gio` | `registry.gitlab.com/dtapps/golang/nsgo` | `registry.gitlab.com/dtapps/golang/viva` |

十个镜像使用同一组标签：`1.27.3`、`1.27`、`latest`、`1.27.3-linux-amd64`、`1.27.3-linux-arm64`。完整契约见 [images-and-tags.md](images-and-tags.md)。

## 快速拉取

```bash
docker run --rm -it ghcr.io/dtapps/golang:latest bash
docker run --rm ghcr.io/dtapps/golang/fnpack:latest fnpack --help
docker run --rm ghcr.io/dtapps/golang/wails3:latest wails3 version
docker run --rm ghcr.io/dtapps/golang/wails2:latest wails version
docker run --rm ghcr.io/dtapps/golang/fyne:latest fyne version
docker run --rm ghcr.io/dtapps/golang/mygo:latest mygo version
docker run --rm ghcr.io/dtapps/golang/gio:latest gogio 2>&1 | head -5   # gogio 没有 version 子命令
docker run --rm ghcr.io/dtapps/golang/nsgo:latest nsgo --help
docker run --rm ghcr.io/dtapps/golang/viva:latest viva --version
# GitLab Registry 同标签
docker run --rm -it registry.gitlab.com/dtapps/golang:latest bash
```

## 怎么构建

```bash
make format && make lint-shell   # 提交前
```

CI 按平台和镜像拆开，每个镜像一条流水线：

- CNB：`.cnb/workflows/build-{golang,fnpack,wails3,wails2,fyne,mygo,gio,nsgo,viva,asuka}.yml`，每日由各 workflow 内的 crontab 先后触发（00:05 golang、03:05 fnpack，之后依次 04:05 wails3、06:05 fyne、07:05 mygo、08:05 gio、09:05 nsgo、10:05 viva、11:05 asuka）。
- GitHub：`.github/workflows/build-{golang,fnpack,wails3,wails2,fyne,mygo,gio,nsgo,viva,asuka}.yml`，各自按定时任务触发（16:05 UTC golang、19:05 UTC fnpack，之后依次 20:05 wails3、22:05 fyne、23:05 mygo、00:05 gio、01:05 nsgo、02:05 viva UTC）。
- GitLab：`.gitlab/workflows/build-{golang,fnpack,wails3,wails2,fyne,mygo,gio,nsgo,viva,asuka}.yml`，由 Pipeline schedules 触发（与 GitHub 同样的时间表），`TARGET` 选镜像；wails2 那条暂时停用。

本地构建见 [build.md](build.md)，事件矩阵见 [ci-pipeline.md](ci-pipeline.md)。

## 文档

- [index.md](index.md)：全部分册索引
- [dockerfile.md](dockerfile.md)：逐段解析基座 Dockerfile
- [images-and-tags.md](images-and-tags.md)：地址、标签、digest
- [build.md](build.md)：本地与 CI 构建
- [ci-pipeline.md](ci-pipeline.md)：触发、按钮、冒烟、元数据
- [mirrors.md](mirrors.md)：GitHub / CNB 的下载源差异
- [getting-started.md](getting-started.md)：常见用法
- [maintenance.md](maintenance.md)：版本升级与日常维护
- [troubleshooting.md](troubleshooting.md)：排错手册

fnpack 镜像的专属分册（`.fpk` 打包用法、`Dockerfile.fnpack` 解析、`fnpack_*` 元数据与徽章）在 [../fnpack/](../fnpack/index.md)；wails3 镜像的专属分册（版本策略、容器内编译用法、`wails3_*` 元数据）在 [../wails3/README.md](../wails3/README.md)；wails2 镜像的专属分册（版本策略、`-tags webkit2_41`、容器内编译、`wails2_*` 元数据）在 [../wails2/README.md](../wails2/README.md)；fyne 镜像的专属分册（OpenGL/X11/Wayland 依赖、版本策略、容器内编译、`fyne_*` 元数据）在 [../fyne/README.md](../fyne/README.md)；mygo 镜像的专属分册（GTK3/WebKitGTK 4.1 依赖、版本策略、容器内编译、`mygo_*` 与 `bun_version` 元数据）在 [../mygo/README.md](../mygo/README.md)；gio 镜像的专属分册（cgo 依赖、`gogio` 与 `gio` 的区别、版本策略、容器内编译、`gio_*` 元数据）在 [../gio/README.md](../gio/README.md)；nsgo 镜像的专属分册（GTK4/WebKitGTK 6.0/GStreamer 依赖、伪版本策略、容器内编译、`nsgo_*` 元数据）在 [../nsgo/README.md](../nsgo/README.md)；viva 镜像的专属分册（XCB/Vulkan 与 `vivagtk` 壳层、版本策略、容器内编译、`viva_*` 元数据）在 [../viva/README.md](../viva/README.md)。徽章里的 annotation key 与 `unknown` 的含义见 [../fnpack/metadata-and-badges.md](../fnpack/metadata-and-badges.md)（golang 侧的键在 [images-and-tags.md](images-and-tags.md) 的「固定某一份产物」）。
