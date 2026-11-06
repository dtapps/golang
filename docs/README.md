# 文档索引

本仓库只做一件事：构建四个 Golang 构建环境镜像。三套流水线（CNB / GitHub Actions / GitLab CI）各自发布到自己的制品库，镜像内容与标签规则保持一致。

| 镜像                     | 地址示例（GitHub / GitLab）                                                 | 说明                                           |
|--------------------------|-----------------------------------------------------------------------------|------------------------------------------------|
| Golang 构建环境          | `ghcr.io/dtapps/golang` / `registry.gitlab.com/dtapps/golang`               | Go + UPX + nfpm + Node + Go 工具               |
| Golang 构建环境 + fnpack | `ghcr.io/dtapps/golang/fnpack` / `registry.gitlab.com/dtapps/golang/fnpack` | 上面的镜像 + `fnpack`                          |
| Golang 构建环境 + wails3 | `ghcr.io/dtapps/golang/wails3` / `registry.gitlab.com/dtapps/golang/wails3` | 上面的镜像 + GTK4/WebKitGTK + `wails3` CLI     |
| Golang 构建环境 + wails2 | `ghcr.io/dtapps/golang/wails2` / `registry.gitlab.com/dtapps/golang/wails2` | 上面的镜像 + GTK3/WebKit2GTK 4.1 + `wails` CLI |

## 先看哪一篇

| 你要做的事                        | 看这里                                                                                                                                |
|-----------------------------------|---------------------------------------------------------------------------------------------------------------------------------------|
| 拉镜像、在项目里用                | [golang/getting-started.md](golang/getting-started.md)                                                                                |
| 给 FnOS 打 `.fpk` 包              | [fnpack/getting-started.md](fnpack/getting-started.md)                                                                                |
| 在容器里编译 Wails v3 应用        | [wails3/README.md](wails3/README.md)                                                                                                  |
| 在容器里编译 Wails v2 应用        | [wails2/README.md](wails2/README.md)                                                                                                  |
| 本地构建、手动触发 CI             | [golang/build.md](golang/build.md)                                                                                                    |
| 看镜像里装了什么、为什么这么分层  | [golang/dockerfile.md](golang/dockerfile.md)                                                                                          |
| 看 fnpack 是怎么装进镜像的        | [fnpack/dockerfile.md](fnpack/dockerfile.md)                                                                                          |
| 看 wails3 版本策略（latest 解析） | [wails3/README.md](wails3/README.md#wails3-版本策略)                                                                                  |
| 看 wails2 版本策略与 build tag    | [wails2/README.md](wails2/README.md#wails2-版本策略)、[构建 v2 应用时的 build tag](wails2/README.md#构建-wails-v2-应用时的-build-tag) |
| 查标签、digest、各镜像的对应关系  | [golang/images-and-tags.md](golang/images-and-tags.md)                                                                                |
| 改 CI 事件、按钮、冒烟断言        | [golang/ci-pipeline.md](golang/ci-pipeline.md)                                                                                        |
| 国内/海外镜像源与下载地址         | [golang/mirrors.md](golang/mirrors.md)                                                                                                |
| 升级 Go、工具、fnpack 版本        | [golang/maintenance.md](golang/maintenance.md)                                                                                        |
| 构建失败排查                      | [golang/troubleshooting.md](golang/troubleshooting.md)                                                                                |
| 构建缓存是怎么实现的              | [cache-implementation.md](cache-implementation.md)                                                                                    |
| 查徽章、元数据键、`unknown` 排查  | [fnpack/metadata-and-badges.md](fnpack/metadata-and-badges.md)、[wails3/README.md](wails3/README.md#元数据与徽章)                     |
| CNB 平台层（变量、地址、元数据）  | [cnb.md](cnb.md)                                                                                                                      |
| GitHub Actions / GHCR 平台层      | [github.md](github.md)                                                                                                                |
| GitLab CI / Registry 平台层       | [gitlab.md](gitlab.md)                                                                                                                |

## 事实来源

- 镜像内容：`.cnb/docker/Dockerfile.golang`、`.cnb/docker/Dockerfile.fnpack`、`.cnb/docker/Dockerfile.wails3`、`.cnb/docker/Dockerfile.wails2`（GitHub 侧同名文件在 `.github/docker/`，GitLab 侧在 `.gitlab/docker/`）。
- 标签与发布顺序：每个平台四个脚本，`build-golang.sh` 先发基座，`build-fnpack.sh` / `build-wails3.sh` / `build-wails2.sh` 等基座镜像就绪后再各自构建。
  - CNB：`.cnb/scripts/build-golang.sh`、`.cnb/scripts/build-fnpack.sh`、`.cnb/scripts/build-wails3.sh`、`.cnb/scripts/build-wails2.sh`
  - GitHub：`.github/scripts/build-golang.sh`、`.github/scripts/build-fnpack.sh`、`.github/scripts/build-wails3.sh`、`.github/scripts/build-wails2.sh`
  - GitLab：`.gitlab/scripts/build-golang.sh`、`.gitlab/scripts/build-fnpack.sh`、`.gitlab/scripts/build-wails3.sh`、`.gitlab/scripts/build-wails2.sh`
- 触发器：每个平台按镜像拆成四个 workflow。
  - CNB：`.cnb.yml`（cron）、`.cnb/workflows/build-{golang,fnpack,wails3,wails2}.yml`、`.cnb/web_trigger.yml`
  - GitHub：`.github/workflows/build-{golang,fnpack,wails3,wails2}.yml`（各自定时触发）
  - GitLab：`.gitlab-ci.yml`（全局配置、schedules）+ `.gitlab/workflows/build-{golang,fnpack,wails3,wails2}.yml`
- 文档与脚本冲突时，以脚本和 Dockerfile 为准，并回头修文档。
