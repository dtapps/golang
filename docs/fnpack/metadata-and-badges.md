# 构建元数据与徽章（fnpack）

> 每次 fnpack 构建把 fnpack 版本、两层 digest（本镜像与基座）、两个平台的体积、两个时间戳写成当前 commit 的元数据，README 徽章从这批 key 取值。golang 基座有一套对应的 `golang_*` 元数据（两套键同挂一个 commit），跨镜像的总表与 digest 固定方式见 [../golang/images-and-tags.md](../golang/images-and-tags.md)，平台层的写入与读取链路见 [../cnb.md](../cnb.md)、[../github.md](../github.md) 与 [../gitlab.md](../gitlab.md)。

## 生成的 JSON

`build-fnpack.sh` 在冒烟通过、标签提升完成后写 `.cnb/annotation-fnpack.json`：

```json
{
  "fnpack_image": "docker.cnb.cool/dtapp/golang/fnpack",
  "fnpack_digest": "sha256:...",
  "fnpack_digest_short": "前 12 位",
  "fnpack_size": "1234.5MB",
  "fnpack_size_arm64": "1230.2MB",
  "fnpack_version": "1.2.3",
  "image_version": "1.27.3",
  "golang_version": "1.27.3",
  "fnpack_base_image": "docker.cnb.cool/dtapp/golang:1.27.3",
  "fnpack_base_digest": "sha256:...",
  "built_at": "2026-11-01T01:12:00Z",
  "source_date": "2026-10-31T16:12:00+08:00"
}
```

| key                                        | 语义                                                                                                              |
|--------------------------------------------|-------------------------------------------------------------------------------------------------------------------|
| `fnpack_image`                             | fnpack 镜像全名                                                                                                   |
| `fnpack_digest`                            | 本次构建的 manifest list 摘要，`docker pull <镜像>@sha256:...` 用它                                               |
| `fnpack_digest_short`                      | 去掉 `sha256:` 后的前 12 位，只用于人工核对，不能用于 pull                                                        |
| `fnpack_size` / `fnpack_size_arm64`        | amd64 / arm64 单平台压缩体积（层之和 + config）                                                                   |
| `fnpack_version`                           | 本次实际安装的 fnpack 版本：默认取 Dockerfile 的 `ARG FNPACK_VERSION`，手动触发填了 `fnpack_version` 时以入参为准 |
| `image_version` / `golang_version`         | 解析出的 Go 版本，与 `<go 版本>` 标签一致（与基座元数据同名同值）                                                 |
| `fnpack_base_image` / `fnpack_base_digest` | 本次实际使用的基础镜像引用与 digest                                                                               |
| `built_at`                                 | 本次实际构建时刻（UTC），只进元数据、不进镜像                                                                     |
| `source_date`                              | 最后一次提交时间，同时落成镜像的 OCI `created` 标签                                                               |

两组 base 键与 golang 侧的 `base_image` / `base_digest` 名字相近、含义不同，别混：

|                     | golang 元数据                 | fnpack 元数据                       |
|---------------------|-------------------------------|-------------------------------------|
| `base_image`        | 上游 `golang:<版本>-trixie`   | ——（fnpack 用 `fnpack_base_image`） |
| `fnpack_base_image` | ——                            | 本仓库的 `golang:<go 版本>`         |
| digest 指向         | Docker Hub 的上游 golang 镜像 | 本仓库构建并推送的 golang 镜像      |

`image_version` / `golang_version` / `built_at` / `source_date` 是两个脚本都写的同名键，值相同（同一天、同一个 Go 版本），`cnbcool/annotations` 的 `type: ADD` 覆盖也无所谓；fnpack 专属信息全部走 `fnpack_` 前缀。

## 写入链路

```text
build-fnpack.sh
  ├─ 等基座 golang:<go 版本> 就绪，读其 index digest → fnpack_base_digest
  ├─ 构建 + 冒烟 + 提升   产出 <go 版本>、-linux-{amd64,arm64}、<minor>（条件提升）、latest（条件提升）
  ├─ imagetools inspect   取 fnpack 镜像的 index digest
  ├─ 逐平台取镜像清单     算压缩体积（含 config）
  └─ 写 .cnb/annotation-fnpack.json
          │
          ▼
stages 第二步：image: cnbcool/annotations:latest
  settings: type: ADD / fromJsonFile: .cnb/annotation-fnpack.json
          │
          ▼
当前 commit 的元数据  ←  /-/badge/annotation/commit/latest/{key}
```

GitHub 侧不写 commit 注解：同样的 JSON 写进 Step Summary，并上传 artifact（`fnpack-annotation`，保留 30 天）。GitLab 侧同样不写 commit 注解，JSON 作为 job artifact 留在 `.gitlab/annotation-fnpack.json`（保留 30 天）。CNB 的徽章地址在 GitHub / GitLab 侧没有对应物，跨平台核对元数据以 artifact 为准。

体积算法与 golang 侧一致：先按平台从版本标签的 index 里挑出该平台的镜像清单 digest，再对清单原文求和（只认含 `layers` 的清单）。清单 digest 取不到、取到的不是镜像清单、或求和小于经验下界，三种情况都输出 `unknown` 并往构建日志打一行警告；徽章上的灰色 `unknown` 也可能是这个 key 从未被写入过——排查顺序：

1. 这次构建是否成功，`cnbcool/annotations` 那一步有没有跑；
2. Commit → 元数据页面里 `fnpack_*` 键是否存在；
3. 构建日志里有没有「体积解析失败」或「取到的不是镜像清单」的警告行。

## 徽章

[`docs/fnpack/README.md`](README.md) 与 [`docs/golang/README.md`](../golang/README.md) 的徽章从下面这条地址取值：

```text
https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/{key}
```

| 徽章        | key                   |
|-------------|-----------------------|
| fnpack 版本 | `fnpack_version`      |
| 镜像大小    | `fnpack_size`         |
| arm64 大小  | `fnpack_size_arm64`   |
| 镜像摘要    | `fnpack_digest_short` |
| 镜像版本    | `image_version`       |

路径里的 `commit/latest` 指最新提交这一维度，与镜像标签 `latest` 同名但无关。`type: ADD` 对同一 commit 是覆盖语义：同名 key 只保留最后一次构建的结果，没有归档——要长期锁定某次产物，记下当时的 `fnpack_digest`，按 digest 拉取。

## 本地复现查询

```bash
IMAGE=docker.cnb.cool/dtapp/golang/fnpack
STAMP=1.27.3

# 版本标签（多架构 index）的 digest，对照元数据里的 fnpack_digest
docker buildx imagetools inspect "${IMAGE}:${STAMP}" --format '{{.Manifest.Digest}}'

# 基座 index digest，对照 fnpack_base_digest
docker buildx imagetools inspect "docker.cnb.cool/dtapp/golang:${STAMP}" --format '{{.Manifest.Digest}}'

# amd64 平台清单的层体积合计，换算后对照 fnpack_size
PLATFORM_DIGEST=$(docker buildx imagetools inspect "${IMAGE}:${STAMP}" --format \
  '{{range .Manifest.Manifests}}{{if and (eq .Platform.OS "linux") (eq .Platform.Architecture "amd64")}}{{.Digest}}{{end}}{{end}}')
docker buildx imagetools inspect "${IMAGE}@${PLATFORM_DIGEST}" --raw \
  | grep -o '"size":[[:space:]]*[0-9]\+' | grep -o '[0-9]\+' \
  | awk '{s+=$1} END{printf "%.1fMB\n", (s+0)/1048576}'
```

第 3 步必须用平台清单 digest，把 index 本身丢进 `--raw` 没有 `layers`，求和只有几 KB，不能当体积用。

## 相关文档

- [基座镜像与标签](../golang/images-and-tags.md)——两套键的总表、digest 固定
- [CNB 平台层](../cnb.md)——注解插件、徽章地址来源
- [GitHub](../github.md) / [GitLab](../gitlab.md)——Step Summary / job artifact 的写入与读取方式
- [Dockerfile.fnpack 解析](dockerfile.md)——`fnpack_version` 的来源
