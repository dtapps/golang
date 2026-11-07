# 分册索引

| 文档                                     | 内容                                                                 |
|------------------------------------------|----------------------------------------------------------------------|
| [README.md](README.md)                   | 一页速查：镜像里有什么、地址、怎么拉                                 |
| [dockerfile.md](dockerfile.md)           | 基座 Dockerfile 逐段解析、版本变量、镜像源开关                       |
| [images-and-tags.md](images-and-tags.md) | 镜像地址、标签契约、digest 固定方式                                  |
| [build.md](build.md)                     | 本地构建、多架构构建、CI 构建流程                                    |
| [ci-pipeline.md](ci-pipeline.md)         | CNB / GitHub / GitLab 的事件矩阵、按钮、冒烟断言、元数据             |
| [mirrors.md](mirrors.md)                 | GitHub / GitLab 与 CNB 的下载源差异、各依赖的镜像顺序                |
| [getting-started.md](getting-started.md) | 在 Go 项目、前端项目、FnOS 打包里的用法                              |
| [maintenance.md](maintenance.md)         | Go / 工具 / fnpack / wails3 / wails2 / fyne 版本升级与每日构建的含义 |
| [troubleshooting.md](troubleshooting.md) | 常见失败与排查步骤                                                   |

fnpack 镜像的专属分册（`.fpk` 打包、`Dockerfile.fnpack` 解析、`fnpack_*` 元数据与徽章）在 [../fnpack/index.md](../fnpack/index.md)；wails3 镜像的专属分册（版本策略、容器内编译、`wails3_*` 元数据）在 [../wails3/README.md](../wails3/README.md)；wails2 镜像的专属分册（版本策略、`-tags webkit2_41`、容器内编译、`wails2_*` 元数据）在 [../wails2/README.md](../wails2/README.md)；fyne 镜像的专属分册（OpenGL/X11/Wayland 依赖、版本策略、容器内编译、`fyne_*` 元数据）在 [../fyne/README.md](../fyne/README.md)。本目录的分册各镜像合写，变体专属机制以各自的目录为准。

## 事实来源

| 事实                     | 来源                                                                                                                                                                                                                                   |
|--------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 镜像里装什么             | `.cnb/docker/Dockerfile.golang`、`.cnb/docker/Dockerfile.fnpack`、`.cnb/docker/Dockerfile.wails3`、`.cnb/docker/Dockerfile.wails2`、`.cnb/docker/Dockerfile.fyne`（GitHub / GitLab 侧同名文件在 `.github/docker/`、`.gitlab/docker/`） |
| 版本号                   | Dockerfile 里的 `ARG`（三个平台各一份）                                                                                                                                                                                                |
| 标签怎么打、什么时候提升 | `.cnb/scripts/`、`.github/scripts/`、`.gitlab/scripts/` 下各自的 `build-{golang,fnpack,wails3,wails2,fyne}.sh`                                                                                                                         |
| 谁触发                   | `.cnb.yml`、`.cnb/workflows/`、`.github/workflows/`、`.gitlab-ci.yml` + `.gitlab/workflows/`、`.cnb/web_trigger.yml`                                                                                                                   |
| 构建元数据               | `.cnb/annotation*.json`、`.github/annotation*.json`、`.gitlab/annotation*.json`（CI 生成，不入库）                                                                                                                                     |

## 维护约定

- 改镜像内容时，`.cnb/docker/`、`.github/docker/` 与 `.gitlab/docker/` 三份 Dockerfile 都要改。
- 改标签规则或冒烟断言时，三侧对应的 `build-golang.sh` / `build-fnpack.sh` / `build-wails3.sh` / `build-wails2.sh` / `build-fyne.sh` 都要改。
- 只改平台胶水（变量来源、镜像源、元数据落地）时，各改各的。
- 文档与实现冲突时，以 Dockerfile 和脚本为准，并回头修文档。
