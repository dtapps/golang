# 文档索引

本仓库只做一件事：构建两个 Golang 构建环境镜像。两套流水线（CNB / GitHub Actions）各自发布到自己的制品库，镜像内容与标签规则保持一致。

| 镜像                     | 地址示例                       | 说明                             |
|--------------------------|--------------------------------|----------------------------------|
| Golang 构建环境          | `ghcr.io/dtapps/golang`        | Go + UPX + nfpm + Node + Go 工具 |
| Golang 构建环境 + fnpack | `ghcr.io/dtapps/golang/fnpack` | 上面的镜像 + `fnpack`            |

## 先看哪一篇

| 你要做的事                         | 看这里                                                         |
|------------------------------------|----------------------------------------------------------------|
| 拉镜像、在项目里用                 | [golang/getting-started.md](golang/getting-started.md)         |
| 给 FnOS 打 `.fpk` 包               | [fnpack/getting-started.md](fnpack/getting-started.md)         |
| 本地构建、手动触发 CI              | [golang/build.md](golang/build.md)                             |
| 看镜像里装了什么、为什么这么分层   | [golang/dockerfile.md](golang/dockerfile.md)                   |
| 看 fnpack 是怎么装进镜像的         | [fnpack/dockerfile.md](fnpack/dockerfile.md)                   |
| 查标签、digest、两个镜像的对应关系 | [golang/images-and-tags.md](golang/images-and-tags.md)         |
| 改 CI 事件、按钮、冒烟断言         | [golang/ci-pipeline.md](golang/ci-pipeline.md)                 |
| 国内/海外镜像源与下载地址          | [golang/mirrors.md](golang/mirrors.md)                         |
| 升级 Go、工具、fnpack 版本         | [golang/maintenance.md](golang/maintenance.md)                 |
| 构建失败排查                       | [golang/troubleshooting.md](golang/troubleshooting.md)         |
| 构建缓存是怎么实现的               | [cache-implementation.md](cache-implementation.md)             |
| 查徽章、元数据键、`unknown` 排查   | [fnpack/metadata-and-badges.md](fnpack/metadata-and-badges.md) |
| CNB 平台层（变量、地址、元数据）   | [cnb.md](cnb.md)                                               |
| GitHub Actions / GHCR 平台层       | [github.md](github.md)                                         |

## 事实来源

- 镜像内容：`.cnb/docker/Dockerfile.golang`、`.cnb/docker/Dockerfile.fnpack`（GitHub 侧同名文件在 `.github/docker/`）。
- 标签与发布顺序：每个平台两个脚本，`build-golang.sh` 先发基座，`build-fnpack.sh` 等基座镜像就绪后再构建。
  - CNB：`.cnb/scripts/build-golang.sh`、`.cnb/scripts/build-fnpack.sh`
  - GitHub：`.github/scripts/build-golang.sh`、`.github/scripts/build-fnpack.sh`
- 触发器：每个平台按镜像拆成两个 workflow。
  - CNB：`.cnb.yml`（cron）、`.cnb/workflows/build-golang.yml`、`.cnb/workflows/build-fnpack.yml`、`.cnb/web_trigger.yml`
  - GitHub：`.github/workflows/build-golang.yml`、`.github/workflows/build-fnpack.yml`（各自定时触发）
- 文档与脚本冲突时，以脚本和 Dockerfile 为准，并回头修文档。
