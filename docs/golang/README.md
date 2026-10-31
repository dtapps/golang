# Golang 构建环境镜像

两个镜像共用一套工具链，区别只有一个二进制：

| 镜像            | 包含 fnpack | 典型用途                                       |
|-----------------|-------------|------------------------------------------------|
| `golang`        | 否          | Go 编译、golangci-lint、前端依赖、deb/rpm 打包 |
| `golang/fnpack` | 是          | 在上一行的基础上给 FnOS 打 `.fpk` 包           |

## 镜像里有什么

- 基座：`golang:1-trixie`（Debian trixie，自动跟随最新稳定 Go）
- 下载与打包工具：UPX、nfpm
- Node.js 26 + npm + pnpm 12
- Go 工具：sqlc、ent/entc、golangci-lint、govulncheck、shfmt、dockerfmt、yamlfmt、gojq、sql-formatter、gotestsum、markdownfmt
- 基础命令：git、curl、make、jq
- 时区：沿用基座默认（未强制设置 TZ）

`golang/fnpack` 只多一个 `/usr/local/bin/fnpack`，其余完全继承 `golang`。

## 地址与标签

| 平台   | golang                         | golang/fnpack                         |
|--------|--------------------------------|---------------------------------------|
| CNB    | `docker.cnb.cool/dtapp/golang` | `docker.cnb.cool/dtapp/golang/fnpack` |
| GitHub | `ghcr.io/dtapps/golang`        | `ghcr.io/dtapps/golang/fnpack`        |

两个镜像使用同一组标签：`1.27.3`、`1.27`、`latest`、`1.27.3-linux-amd64`、`1.27.3-linux-arm64`。完整契约见 [images-and-tags.md](images-and-tags.md)。

## 快速拉取

```bash
docker run --rm -it ghcr.io/dtapps/golang:latest bash
docker run --rm ghcr.io/dtapps/golang/fnpack:latest fnpack --help
```

## 怎么构建

```bash
make format && make lint-shell   # 提交前
```

CI 按平台和镜像拆开，每个镜像一条流水线：

- CNB：`.cnb/workflows/build-golang.yml`、`.cnb/workflows/build-fnpack.yml`，每日由 `.cnb.yml` 的定时任务先后触发。
- GitHub：`.github/workflows/build-golang.yml`、`.github/workflows/build-fnpack.yml`，两者各自按定时任务触发（16:35 UTC 与 19:35 UTC）。

本地构建见 [build.md](build.md)，事件矩阵见 [ci-pipeline.md](ci-pipeline.md)。

## 文档

- [index.md](index.md)：全部分册索引
- [dockerfile.md](dockerfile.md)：逐段解析两个 Dockerfile
- [images-and-tags.md](images-and-tags.md)：地址、标签、digest
- [build.md](build.md)：本地与 CI 构建
- [ci-pipeline.md](ci-pipeline.md)：触发、按钮、冒烟、元数据
- [mirrors.md](mirrors.md)：GitHub / CNB 的下载源差异
- [getting-started.md](getting-started.md)：常见用法
- [maintenance.md](maintenance.md)：版本升级与日常维护
- [troubleshooting.md](troubleshooting.md)：排错手册
