# 镜像与标签

## 地址

脚本不写死地址，全部从平台内置变量派生：

| 平台   | golang                                              | golang/fnpack      | golang/wails3      |
|--------|-----------------------------------------------------|--------------------|--------------------|
| CNB    | `${CNB_DOCKER_REGISTRY}/${CNB_REPO_SLUG_LOWERCASE}` | 上一列 + `/fnpack` | 上一列 + `/wails3` |
| GitHub | `ghcr.io/${GITHUB_REPOSITORY}`（小写）              | 上一列 + `/fnpack` | 上一列 + `/wails3` |

本仓库当前的实际值：

```text
docker.cnb.cool/dtapp/golang
docker.cnb.cool/dtapp/golang/fnpack
docker.cnb.cool/dtapp/golang/wails3
ghcr.io/dtapps/golang
ghcr.io/dtapps/golang/fnpack
ghcr.io/dtapps/golang/wails3
```

fork 或改名后自动跟着变，不需要改脚本。

## 标签契约

三个镜像使用同一组标签，标签里的版本是**解析出来的实际 Go 版本**（不是 Dockerfile 里写的引用）。fnpack / wails3 自身的 CLI 版本不占标签，只记录在元数据里。

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
```

## 发布顺序

三个镜像由三条流水线分别发布：

1. golang：构建并推送 `golang:<go 版本>` → 派生单平台标签 → 冒烟 → 提升 `golang:<major.minor>` / `golang:latest`。
2. fnpack：等 `golang:<go 版本>` 存在 → 从它构建并推送 `golang/fnpack:<go 版本>` → 派生单平台标签 → 冒烟 → 提升 fnpack 的移动标签。
3. wails3：同上，但产物是 `golang/wails3:<go 版本>`（多装 GTK4/WebKitGTK 与 wails3 CLI）。

fnpack / wails3 的 `<major.minor>` / `latest` 只在基础镜像的对应标签也已指向本次版本时才提升。所以它们的 `latest` 不会跑到基础镜像前面，也不会出现「只有变体成功」的错位。失败时 `<go 版本>` 标签可能已经指向坏产物，但它不是移动标签，下游按 `latest` / `<major.minor>` 拉取不受影响。

调度上，CNB 先跑 00:05 的 golang、再跑 03:05 的 fnpack、最后 06:05 的 wails3；GitHub 先跑 16:35 UTC 的 golang、再跑 19:35 UTC 的 fnpack、最后 22:35 UTC 的 wails3。

## 固定某一份产物

标签每天可能被同名覆盖，不能当固定点。要固定产物，用元数据里的 digest：

```bash
docker pull ghcr.io/dtapps/golang@sha256:<golang_digest>
docker pull ghcr.io/dtapps/golang/fnpack@sha256:<fnpack_digest>
docker pull ghcr.io/dtapps/golang/wails3@sha256:<wails3_digest>
```

构建元数据由三条流水线分别写入：

- golang：`.cnb/annotation.json` / `.github/annotation.json`
- fnpack：`.cnb/annotation-fnpack.json` / `.github/annotation-fnpack.json`
- wails3：`.cnb/annotation-wails3.json` / `.github/annotation-wails3.json`

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
| `image_version`      | 解析出的 Go 版本（与 `<go 版本>` 标签一致） |
| `golang_version`     | 同上                                        |
| `base_image`         | golang 元数据：上游 `golang:<版本>-<代号>`  |
| `base_digest`        | golang 元数据：上游基座 digest              |
| `fnpack_base_image`  | fnpack 元数据：本次使用的基础镜像引用       |
| `fnpack_base_digest` | fnpack 元数据：基础镜像 digest              |
| `wails3_base_image`  | wails3 元数据：本次使用的基础镜像引用       |
| `wails3_base_digest` | wails3 元数据：基础镜像 digest              |
| `built_at`           | 本次构建时间                                |
| `source_date`        | 最后一次提交时间                            |
| `revision`           | 提交 SHA                                    |

CNB 侧从 `/-/badge/annotation/commit/latest/{key}` 读取；GitHub 侧写进 Step Summary 并上传 artifact（`golang-annotation` / `fnpack-annotation` / `wails3-annotation`）。

## 三个镜像的对应关系

同一 `<go 版本>` 下：

```text
golang:1.27.3        = 基座 + 全部工具链
golang/fnpack:1.27.3 = golang:1.27.3 + fnpack
golang/wails3:1.27.3 = golang:1.27.3 + GTK4/WebKitGTK + wails3
```

两个变体镜像的 `image_version` 与基础镜像相同；fnpack / wails3 自身的版本只记录在 `fnpack_version` / `wails3_version`，不单独占标签。fnpack 与 wails3 是平级变体，互不包含。
