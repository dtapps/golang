# Golang 构建环境 + fnpack 镜像

[![定时构建](https://cnb.cool/dtapp/golang/-/badge/git/latest/ci/status/crontab)](https://cnb.cool/dtapp/golang/-/pipeline) [![流水线配置](https://cnb.cool/dtapp/golang/-/badge/git/latest/ci/pipeline-as-code)](https://cnb.cool/dtapp/golang/-/blob/main/.cnb.yml) [![漏洞扫描](https://cnb.cool/dtapp/golang/-/badge/security/vulnerability/full/latest)](https://cnb.cool/dtapp/golang/-/security) ![基础镜像](https://img.shields.io/badge/base-golang-00ADD8?logo=go&logoColor=white) ![fnpack](https://img.shields.io/badge/fnpack-FnOS%20.fpk-blue) ![架构](https://img.shields.io/badge/arch-amd64%20%7C%20arm64-informational) ![fnpack 版本](https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/fnpack_version) ![镜像大小](https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/fnpack_size) ![arm64 大小](https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/fnpack_size_arm64) ![镜像摘要](https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/fnpack_digest_short) ![镜像版本](https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/image_version)

在 [Golang 构建环境镜像](../golang/README.md) 之上只加一个 `fnpack` 二进制，用于给 FnOS 打 `.fpk` 包。除 fnpack 外，镜像内容与基座完全一致：同一套工具链、同一组标签、同一天构建。

> **本目录的分工**：fnpack 镜像 = 基座镜像 + 一个二进制，所以这里只收 fnpack 专属的分册（打包用法、Dockerfile、元数据与徽章）。构建、CI、标签、镜像源、维护、排错等共用机制都在 [`docs/golang/`](../golang/index.md)，不在这里重复。文档与实现冲突时，以两份 `Dockerfile.fnpack` 与两份 `build-fnpack.sh` 为准。

## 镜像里有什么

- 基座：本仓库构建的 Golang 构建环境镜像（CI 按 `<go 版本>` 钉住当天刚推好的那份；Dockerfile 的默认基座是官方 `golang:1-trixie`，只用于不依赖私有仓库的本地构建）
- 继承基座全部内容：Go 工具链、UPX、nfpm、Node.js + npm + pnpm、sqlc / ent / golangci-lint / govulncheck / shfmt / dockerfmt / yamlfmt / gojq / sql-formatter / gotestsum / markdownfmt、git / curl / make / jq
- 唯一新增：`/usr/local/bin/fnpack`——从 `static2.fnnas.com` 下载的 FnOS 官方打包 CLI，版本默认取 `FNPACK_VERSION`（当前 `1.2.3`，上游没有 latest 接口，暂作为最新版本），手动触发时可用 `fnpack_version` 覆盖

## 地址与标签

| 平台   | 地址                                  |
|--------|---------------------------------------|
| CNB    | `docker.cnb.cool/dtapp/golang/fnpack` |
| GitHub | `ghcr.io/dtapps/golang/fnpack`        |

标签与基座同一套契约：`<go 版本>` / `<major.minor>` / `latest` / `<go 版本>-linux-{amd64,arm64}`。标签里的版本是 **Go 版本**（与基座同名标签一致）；fnpack 自身的版本不占标签，只记录在元数据 `fnpack_version` 里。

`<major.minor>` / `latest` 只在基座对应标签已指向同一 digest 时提升，所以 fnpack 的移动标签永远不会跑到基座前面。完整契约见 [../golang/images-and-tags.md](../golang/images-and-tags.md)。

## 快速拉取

```bash
docker run --rm docker.cnb.cool/dtapp/golang/fnpack:latest fnpack --help
docker run --rm ghcr.io/dtapps/golang/fnpack:latest fnpack --help
```

`.fpk` 打包的具体用法见 [getting-started.md](getting-started.md)。

## 怎么构建

- CNB：`.cnb/workflows/build-fnpack.yml`，每天 03:05 由 `.cnb.yml` 定时触发（基座 00:05 先构建）；也可用「打包 Golang + fnpack 镜像（多架构）」按钮手动触发，可填 `version` / `fnpack_version`。
- GitHub：`.github/workflows/build-fnpack.yml`，每天 19:35 UTC（北京 03:35）定时触发（基座 16:35 UTC 先构建）；手动触发时可填 `version` / `fnpack_version`。

构建脚本先等 `golang:<go 版本>` 就绪（等不到直接失败），再从它构建、跑冒烟（检查 fnpack 与基座工具链都在）、提升移动标签。事件矩阵与冒烟断言见 [../golang/ci-pipeline.md](../golang/ci-pipeline.md)，发布顺序见 [../golang/images-and-tags.md](../golang/images-and-tags.md)。

## 文档

- [index.md](index.md)：本目录分册索引与事实来源
- [getting-started.md](getting-started.md)：fnpack 与 `.fpk` 打包用法
- [dockerfile.md](dockerfile.md)：`Dockerfile.fnpack` 逐段解析
- [metadata-and-badges.md](metadata-and-badges.md)：`fnpack_*` 元数据键与徽章
- [../golang/index.md](../golang/index.md)：基座镜像与共用机制的文档入口
