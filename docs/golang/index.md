# 分册索引

| 文档                                     | 内容                                            |
|------------------------------------------|-------------------------------------------------|
| [README.md](README.md)                   | 一页速查：镜像里有什么、地址、怎么拉            |
| [dockerfile.md](dockerfile.md)           | 两个 Dockerfile 逐段解析、版本变量、镜像源开关  |
| [images-and-tags.md](images-and-tags.md) | 镜像地址、标签契约、digest 固定方式             |
| [build.md](build.md)                     | 本地构建、多架构构建、CI 构建流程               |
| [ci-pipeline.md](ci-pipeline.md)         | CNB / GitHub 的事件矩阵、按钮、冒烟断言、元数据 |
| [mirrors.md](mirrors.md)                 | GitHub 与 CNB 的下载源差异、各依赖的镜像顺序    |
| [getting-started.md](getting-started.md) | 在 Go 项目、前端项目、FnOS 打包里的用法         |
| [maintenance.md](maintenance.md)         | Go / 工具 / fnpack 版本升级与每日构建的含义     |
| [troubleshooting.md](troubleshooting.md) | 常见失败与排查步骤                              |

## 事实来源

| 事实                     | 来源                                                                                                                          |
|--------------------------|-------------------------------------------------------------------------------------------------------------------------------|
| 镜像里装什么             | `.cnb/docker/Dockerfile.golang`、`.cnb/docker/Dockerfile.fnpack`                                                              |
| 版本号                   | Dockerfile 里的 `ARG`（两个平台各一份）                                                                                       |
| 标签怎么打、什么时候提升 | `.cnb/scripts/build-golang.sh`、`.cnb/scripts/build-fnpack.sh`、`.github/scripts/` 下同名文件                                 |
| 谁触发                   | `.cnb.yml`、`.cnb/workflows/build-{golang,fnpack}.yml`、`.github/workflows/build-{golang,fnpack}.yml`、`.cnb/web_trigger.yml` |
| 构建元数据               | `.cnb/annotation{,-fnpack}.json`、`.github/annotation{,-fnpack}.json`（CI 生成，不入库）                                      |

## 维护约定

- 改镜像内容时，`.cnb/docker/` 与 `.github/docker/` 两份 Dockerfile 都要改。
- 改标签规则或冒烟断言时，两侧对应的 `build-golang.sh` / `build-fnpack.sh` 都要改。
- 只改平台胶水（变量来源、镜像源、元数据落地）时，各改各的。
- 文档与实现冲突时，以 Dockerfile 和脚本为准，并回头修文档。
