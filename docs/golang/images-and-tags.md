# 镜像与标签

## 地址

脚本不写死地址，全部从平台内置变量派生：

| 平台   | golang                                              | golang/fnpack      | golang/wails3      | golang/wails2      | golang/fyne      | golang/mygo      | golang/gio      |
|--------|-----------------------------------------------------|--------------------|--------------------|--------------------|------------------|------------------|-----------------|
| CNB    | `${CNB_DOCKER_REGISTRY}/${CNB_REPO_SLUG_LOWERCASE}` | 上一列 + `/fnpack` | 上一列 + `/wails3` | 上一列 + `/wails2` | 上一列 + `/fyne` | 上一列 + `/mygo` | 上一列 + `/gio` |
| GitHub | `ghcr.io/${GITHUB_REPOSITORY}`（小写）              | 上一列 + `/fnpack` | 上一列 + `/wails3` | 上一列 + `/wails2` | 上一列 + `/fyne` | 上一列 + `/mygo` | 上一列 + `/gio` |
| GitLab | `${CI_REGISTRY_IMAGE}`                              | 上一列 + `/fnpack` | 上一列 + `/wails3` | 上一列 + `/wails2` | 上一列 + `/fyne` | 上一列 + `/mygo` | 上一列 + `/gio` |

本仓库当前的实际值：

```text
docker.cnb.cool/dtapp/golang
docker.cnb.cool/dtapp/golang/fnpack
docker.cnb.cool/dtapp/golang/wails3
docker.cnb.cool/dtapp/golang/wails2
docker.cnb.cool/dtapp/golang/fyne
docker.cnb.cool/dtapp/golang/mygo
docker.cnb.cool/dtapp/golang/gio
ghcr.io/dtapps/golang
ghcr.io/dtapps/golang/fnpack
ghcr.io/dtapps/golang/wails3
ghcr.io/dtapps/golang/wails2
ghcr.io/dtapps/golang/fyne
ghcr.io/dtapps/golang/mygo
ghcr.io/dtapps/golang/gio
registry.gitlab.com/dtapps/golang
registry.gitlab.com/dtapps/golang/fnpack
registry.gitlab.com/dtapps/golang/wails3
registry.gitlab.com/dtapps/golang/wails2
registry.gitlab.com/dtapps/golang/fyne
registry.gitlab.com/dtapps/golang/mygo
registry.gitlab.com/dtapps/golang/gio
```

fork 或改名后自动跟着变，不需要改脚本。

## 标签契约

七个镜像使用同一组标签，标签里的版本是**解析出来的实际 Go 版本**（不是 Dockerfile 里写的引用）。fnpack / wails3 / wails2 / fyne / mygo / gio 自身的 CLI 版本不占标签，只记录在元数据里（mygo 镜像里的 `bun` 版本同样只记在 `bun_version`；gio 的 `gogio` CLI 版本记在 `gio_version`）。

| 标签                       | 含义                                    | 是否移动 |
|----------------------------|-----------------------------------------|----------|
| `<go 版本>`，如 `1.27.3`   | 本次构建的 Go 版本，构建阶段直接推送    | 同名覆盖 |
| `<major.minor>`，如 `1.27` | 该 minor 的最新一次成功构建             | 移动     |
| `latest`                   | 最近一次成功构建                        | 移动     |
| `<go 版本>-linux-amd64`    | 从同一份 manifest list 派生的单平台标签 | 同名覆盖 |
| `<go 版本>-linux-arm64`    | 同上                                    | 同名覆盖 |

示例：

```text
ghcr.io/dtapps/golang:1.27.3
ghcr.io/dtapps/golang:1.27
ghcr.io/dtapps/golang:latest
ghcr.io/dtapps/golang:1.27.3-linux-amd64
ghcr.io/dtapps/golang/fnpack:1.27.3
ghcr.io/dtapps/golang/fnpack:1.27
ghcr.io/dtapps/golang/fnpack:latest
ghcr.io/dtapps/golang/fnpack:1.27.3-linux-arm64
ghcr.io/dtapps/golang/wails3:1.27.3
ghcr.io/dtapps/golang/wails3:1.27
ghcr.io/dtapps/golang/wails3:latest
ghcr.io/dtapps/golang/wails3:1.27.3-linux-arm64
ghcr.io/dtapps/golang/fyne:1.27.3
ghcr.io/dtapps/golang/fyne:1.27
ghcr.io/dtapps/golang/fyne:latest
ghcr.io/dtapps/golang/fyne:1.27.3-linux-arm64
ghcr.io/dtapps/golang/mygo:1.27.3
ghcr.io/dtapps/golang/mygo:1.27
ghcr.io/dtapps/golang/mygo:latest
ghcr.io/dtapps/golang/mygo:1.27.3-linux-arm64
ghcr.io/dtapps/golang/gio:1.27.3
ghcr.io/dtapps/golang/gio:1.27
ghcr.io/dtapps/golang/gio:latest
ghcr.io/dtapps/golang/gio:1.27.3-linux-arm64
```

## 发布顺序

七个镜像由七条流水线分别发布：

1. golang：构建并推送 `golang:<go 版本>` → 派生单平台标签 → 冒烟 → 提升 `golang:<major.minor>` / `golang:latest`。
2. fnpack：等 `golang:<go 版本>` 存在 → 从它构建并推送 `golang/fnpack:<go 版本>` → 派生单平台标签 → 冒烟 → 提升 fnpack 的移动标签。
3. wails3：同上，但产物是 `golang/wails3:<go 版本>`（多装 GTK4/WebKitGTK 与 wails3 CLI）。
4. wails2：同上，但产物是 `golang/wails2:<go 版本>`（多装 GTK3/WebKit2GTK 4.1 与 wails CLI）。
5. fyne：同上，但产物是 `golang/fyne:<go 版本>`（多装 OpenGL/X11/Wayland 开发包与 fyne CLI）。
6. mygo：同上，但产物是 `golang/mygo:<go 版本>`（多装 GTK3/WebKitGTK 4.1 开发包、无头运行库、mygo CLI 与 bun）。
7. gio：同上，但产物是 `golang/gio:<go 版本>`（多装 EGL/GLES、X11、Wayland、Vulkan 开发包、无头运行库与 gogio CLI）。

fnpack / wails3 / wails2 / fyne / mygo / gio 的 `<major.minor>` / `latest` 只在基础镜像的对应标签也已指向本次版本时才提升。所以它们的 `latest` 不会跑到基础镜像前面，也不会出现「只有变体成功」的错位。失败时 `<go 版本>` 标签可能已经指向坏产物，但它不是移动标签，下游按 `latest` / `<major.minor>` 拉取不受影响。

调度上，CNB 依次跑 00:05 的 golang、03:05 的 fnpack、06:05 的 wails3、09:05 的 wails2、12:05 的 fyne、15:05 的 mygo、18:05 的 gio；GitHub 依次跑 16:05 UTC 的 golang、19:05 UTC 的 fnpack、22:05 UTC 的 wails3、01:05 UTC 的 wails2、04:05 UTC 的 fyne、07:05 UTC 的 mygo、10:05 UTC 的 gio；GitLab 用 Pipeline schedules 配同样的时间，变量 `TARGET` 分别指向七个镜像，也可以一条 schedule 不填 `TARGET` 一次构建全部。

## 固定某一份产物

标签每天可能被同名覆盖，不能当固定点。要固定产物，用元数据里的 digest：

```bash
docker pull ghcr.io/dtapps/golang@sha256:<golang_digest>
docker pull ghcr.io/dtapps/golang/fnpack@sha256:<fnpack_digest>
docker pull ghcr.io/dtapps/golang/wails3@sha256:<wails3_digest>
docker pull ghcr.io/dtapps/golang/wails2@sha256:<wails2_digest>
docker pull ghcr.io/dtapps/golang/fyne@sha256:<fyne_digest>
docker pull ghcr.io/dtapps/golang/mygo@sha256:<mygo_digest>
docker pull ghcr.io/dtapps/golang/gio@sha256:<gio_digest>
```

构建元数据由七条流水线分别写入：

- golang：`.cnb/annotation.json` / `.github/annotation.json` / `.gitlab/annotation.json`
- fnpack：`.cnb/annotation-fnpack.json` / `.github/annotation-fnpack.json` / `.gitlab/annotation-fnpack.json`
- wails3：`.cnb/annotation-wails3.json` / `.github/annotation-wails3.json` / `.gitlab/annotation-wails3.json`
- wails2：`.cnb/annotation-wails2.json` / `.github/annotation-wails2.json` / `.gitlab/annotation-wails2.json`
- fyne：`.cnb/annotation-fyne.json` / `.github/annotation-fyne.json` / `.gitlab/annotation-fyne.json`
- mygo：`.cnb/annotation-mygo.json` / `.github/annotation-mygo.json` / `.gitlab/annotation-mygo.json`
- gio：`.cnb/annotation-gio.json` / `.github/annotation-gio.json` / `.gitlab/annotation-gio.json`

| 键                   | 含义                                        |
|----------------------|---------------------------------------------|
| `golang_image`       | golang 镜像全名                             |
| `golang_digest`      | golang manifest list digest                 |
| `golang_size`        | amd64 压缩体积                              |
| `golang_size_arm64`  | arm64 压缩体积                              |
| `fnpack_image`       | fnpack 镜像全名                             |
| `fnpack_digest`      | fnpack manifest list digest                 |
| `fnpack_size`        | amd64 压缩体积                              |
| `fnpack_size_arm64`  | arm64 压缩体积                              |
| `fnpack_version`     | 本次安装的 fnpack 版本                      |
| `wails3_image`       | wails3 镜像全名                             |
| `wails3_digest`      | wails3 manifest list digest                 |
| `wails3_size`        | amd64 压缩体积                              |
| `wails3_size_arm64`  | arm64 压缩体积                              |
| `wails3_version`     | 本次安装的 wails3 CLI 版本（如 `v3.1.0`）   |
| `fyne_image`         | fyne 镜像全名                               |
| `fyne_digest`        | fyne manifest list digest                   |
| `fyne_digest_short`  | fyne digest 前 12 位（徽章用）              |
| `fyne_size`          | amd64 压缩体积                              |
| `fyne_size_arm64`    | arm64 压缩体积                              |
| `fyne_version`       | 本次安装的 fyne CLI 版本（如 `v1.7.4`）     |
| `mygo_image`         | mygo 镜像全名                               |
| `mygo_digest`        | mygo manifest list digest                   |
| `mygo_digest_short`  | mygo digest 前 12 位（徽章用）              |
| `mygo_size`          | amd64 压缩体积                              |
| `mygo_size_arm64`    | arm64 压缩体积                              |
| `mygo_version`       | 本次安装的 mygo CLI 版本（如 `v0.8.1`）     |
| `bun_version`        | 本次安装的 bun 版本（如 `1.4.4`）           |
| `gio_image`          | gio 镜像全名                                |
| `gio_digest`         | gio manifest list digest                    |
| `gio_digest_short`   | gio digest 前 12 位（徽章用）               |
| `gio_size`           | amd64 压缩体积                              |
| `gio_size_arm64`     | arm64 压缩体积                              |
| `gio_version`        | 本次安装的 gogio CLI 版本（如 `v0.10.3`）   |
| `image_version`      | 解析出的 Go 版本（与 `<go 版本>` 标签一致） |
| `golang_version`     | 同上                                        |
| `base_image`         | golang 元数据：上游 `golang:<版本>-<代号>`  |
| `base_digest`        | golang 元数据：上游基座 digest              |
| `fnpack_base_image`  | fnpack 元数据：本次使用的基础镜像引用       |
| `fnpack_base_digest` | fnpack 元数据：基础镜像 digest              |
| `wails3_base_image`  | wails3 元数据：本次使用的基础镜像引用       |
| `wails3_base_digest` | wails3 元数据：基础镜像 digest              |
| `fyne_base_image`    | fyne 元数据：本次使用的基础镜像引用         |
| `fyne_base_digest`   | fyne 元数据：基础镜像 digest                |
| `mygo_base_image`    | mygo 元数据：本次使用的基础镜像引用         |
| `mygo_base_digest`   | mygo 元数据：基础镜像 digest                |
| `gio_base_image`     | gio 元数据：本次使用的基础镜像引用          |
| `gio_base_digest`    | gio 元数据：基础镜像 digest                 |
| `built_at`           | 本次构建时间                                |
| `source_date`        | 最后一次提交时间                            |
| `revision`           | 提交 SHA                                    |

golang 基座还会**逐个工具**写一份版本号：key 是 Dockerfile 里 `ARG` 名的小写形式（`GOLANGCI_LINT_VERSION` → `golangci_lint_version`），覆盖全部 14 个 `go install` 版本变量加 `node_version` / `pnpm_version` / `upx_version`，共 17 个；apt 装的 `wixl` 没有 `ARG`，版本由冒烟容器里的 `dpkg-query -W` 带出，写成 `wixl_version`（取不到时为 `unknown`）。原来的单行汇总 `tools`（`upx=4.2.4 node=26.0.0 …`）保留不变，两种读法都能用：

```bash
jq -r '.golangci_lint_version' .github/annotation.json  # 单个工具
jq -r '.tools' .github/annotation.json                  # 全部（一行）
```

CNB 侧也可以直接按工具名出徽章：`https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/golangci_lint_version`。

这些值是**镜像里实际装上的版本**，不是构建前解析出来的目标版本：冒烟容器里用 `go version -m <二进制>` 读模块版本（`node -v` / `pnpm -v` / `upx --version` 读 CLI），所以即使解析失败回退 `latest`、Dockerfile 装的是「构建当天最新」，元数据里写的仍是真实版本号。只有在镜像里也读不到时才会出现 `latest`。官方二进制的 `go version -m` 常常拿不到版本（报 `(devel)`）或带构建标记（`v1.13.0+dirty`），这类值会被剔除、退回解析出来的版本号，所以元数据里不会出现 `(devel)` / `+dirty`。

七个镜像里凡是用 apt 装了系统包的（基座 + fyne / gio / mygo / wails2 / wails3），都会再写一个 `apt_versions`：`包=版本` 用空格串成一行，包清单**从该镜像对应的 Dockerfile 自动提取**（`apt-get install` 那段，改 Dockerfile 后自动跟上），版本取自镜像内的 `dpkg` 数据库。构建期装过、最后被 purge 的包（基座的 `wget` / `xz-utils`）写成 `absent`；完全没装 apt 包的镜像（fnpack）写成 `none`。传递依赖不记，只记 Dockerfile 里显式列出的那一份。

wails2 的元数据键与上表同构，前缀换成 `wails2_`：`wails2_image` / `wails2_digest` / `wails2_digest_short` / `wails2_size` / `wails2_size_arm64` / `wails2_version` / `wails2_base_image` / `wails2_base_digest`。完整说明见 [../wails2/README.md](../wails2/README.md#元数据与徽章)。fyne 的键已列在上表（前缀 `fyne_`），完整说明见 [../fyne/README.md](../fyne/README.md#元数据与徽章)；mygo 的键已列在上表（前缀 `mygo_`，另有 `bun_version`），完整说明见 [../mygo/README.md](../mygo/README.md#元数据与徽章)；gio 的键已列在上表（前缀 `gio_`），完整说明见 [../gio/README.md](../gio/README.md#元数据与徽章)。

CNB 侧从 `/-/badge/annotation/commit/latest/{key}` 读取；GitHub 侧写进 Step Summary 并上传 artifact（`golang-annotation` / `fnpack-annotation` / `wails3-annotation` / `wails2-annotation` / `fyne-annotation` / `mygo-annotation` / `gio-annotation`）；GitLab 侧写进 `.gitlab/annotation*.json`，随 job artifacts 保留 30 天。

## 七个镜像的对应关系

同一 `<go 版本>` 下：

```text
golang:1.27.3        = 基座 + 全部工具链
golang/fnpack:1.27.3 = golang:1.27.3 + fnpack
golang/wails3:1.27.3 = golang:1.27.3 + GTK4/WebKitGTK + wails3
golang/wails2:1.27.3 = golang:1.27.3 + GTK3/WebKit2GTK 4.1 + wails
golang/fyne:1.27.3   = golang:1.27.3 + OpenGL/X11/Wayland + fyne
golang/mygo:1.27.3   = golang:1.27.3 + GTK3/WebKitGTK 4.1 + 无头运行库 + mygo + bun
golang/gio:1.27.3    = golang:1.27.3 + EGL/GLES + X11 + Wayland + Vulkan + 无头运行库 + gogio
```

六个变体镜像的 `image_version` 与基础镜像相同；各自 CLI 的版本只记录在 `fnpack_version` / `wails3_version` / `wails2_version` / `fyne_version` / `mygo_version` / `bun_version` / `gio_version`，不单独占标签。fnpack、wails3、wails2、fyne、mygo 与 gio 是平级变体，互不包含。
