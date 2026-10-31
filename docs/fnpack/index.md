# 文档索引：Golang + fnpack 镜像

> `docker.cnb.cool/dtapp/golang/fnpack`（GHCR：`ghcr.io/dtapps/golang/fnpack`）—— Golang 构建环境 + fnpack 镜像的说明：镜像里有什么、怎么打 `.fpk` 包、fnpack 是怎么装进去的、元数据与徽章怎么读。

同目录的 [README.md](README.md) 是一页速查。fnpack 镜像 = [Golang 构建环境镜像](../golang/README.md) + 一个 fnpack 二进制，所以本目录只收 fnpack 专属的分册；构建、CI、标签、镜像源、维护、排错等共用机制在 [../golang/index.md](../golang/index.md)，不在这里重复。

## 从哪里开始

| 你的目的                                 | 先读                                         | 再读                                                            |
|------------------------------------------|----------------------------------------------|-----------------------------------------------------------------|
| 第一次用这个镜像                         | [快速上手](getting-started.md)               | [基座快速上手](../golang/getting-started.md)                    |
| 给 FnOS 打 `.fpk` 包                     | [快速上手](getting-started.md)               | [fnpack 官方文档](https://developer.fnnas.com/docs/cli/fnpack/) |
| 想知道 fnpack 是怎么装进镜像的           | [Dockerfile 解析](dockerfile.md)             | [基座 Dockerfile 解析](../golang/dockerfile.md)                 |
| 查某次构建的 fnpack 版本 / digest / 体积 | [元数据与徽章](metadata-and-badges.md)       | [基座镜像与标签](../golang/images-and-tags.md)                  |
| 徽章显示 `unknown`、想核对元数据         | [元数据与徽章](metadata-and-badges.md)       | [CNB 平台层](../cnb.md)                                         |
| 升级 fnpack 版本                         | [基座维护手册](../golang/maintenance.md)     | [Dockerfile 解析](dockerfile.md)                                |
| 构建 / 拉取出问题                        | [基座排错手册](../golang/troubleshooting.md) | [基座 CI 流水线](../golang/ci-pipeline.md)                      |

## 文档清单

| 文档                                             | 内容                                                          | 对应实现                                       |
|--------------------------------------------------|---------------------------------------------------------------|------------------------------------------------|
| [getting-started.md](getting-started.md)         | fnpack 是什么、什么时候选这个镜像、`.fpk` 打包流程、CI 里使用 | `fnpack` 二进制 + 官方文档                     |
| [dockerfile.md](dockerfile.md)                   | `Dockerfile.fnpack` 逐段解析：基座钉住、架构映射、标签位置    | `.cnb/docker/Dockerfile.fnpack`（GitHub 同名） |
| [metadata-and-badges.md](metadata-and-badges.md) | `fnpack_*` 元数据键、写入链路、徽章地址、`unknown` 含义       | `build-fnpack.sh`、`cnbcool/annotations`       |

## 事实来源

| 事实                       | 来源                                                                                                                      |
|----------------------------|---------------------------------------------------------------------------------------------------------------------------|
| fnpack 怎么装              | `.cnb/docker/Dockerfile.fnpack`、`.github/docker/Dockerfile.fnpack`                                                       |
| fnpack 版本                | Dockerfile 的 `ARG FNPACK_VERSION`（两份各一的默认值）；手动触发可用 `fnpack_version` 覆盖，上游没有 latest 查询接口      |
| 标签、等待基座、冒烟、提升 | `.cnb/scripts/build-fnpack.sh`、`.github/scripts/build-fnpack.sh`                                                         |
| 谁触发                     | `.cnb.yml`（03:05 cron）、`.cnb/workflows/build-fnpack.yml`、`.github/workflows/build-fnpack.yml`、`.cnb/web_trigger.yml` |
| 构建元数据                 | `.cnb/annotation-fnpack.json`、`.github/annotation-fnpack.json`（CI 生成，不入库）                                        |

## 维护约定

- 改 fnpack 安装逻辑时，两份 `Dockerfile.fnpack` 都要改；改标签规则或冒烟断言时，两份 `build-fnpack.sh` 都要改，并与 `build-golang.sh` 保持一致。
- fnpack 的元数据键只在 [metadata-and-badges.md](metadata-and-badges.md) 解释，其它篇引用而不另立说法。
- 链接一律用相对路径：本目录内互链写 `xxx.md`，指向基座文档写 `../golang/xxx.md`，指向平台层写 `../cnb.md` / `../github.md`。
- 文档与实现冲突时，以 Dockerfile 和脚本为准，并回头修文档。
