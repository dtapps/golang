# Golang 构建环境镜像 + Golang + fnpack 镜像

[![定时构建](https://cnb.cool/dtapp/golang/-/badge/git/latest/ci/status/crontab)](https://cnb.cool/dtapp/golang/-/pipeline) [![流水线配置](https://cnb.cool/dtapp/golang/-/badge/git/latest/ci/pipeline-as-code)](https://cnb.cool/dtapp/golang/-/blob/main/.cnb.yml) [![漏洞扫描](https://cnb.cool/dtapp/golang/-/badge/security/vulnerability/full/latest)](https://cnb.cool/dtapp/golang/-/security) [![build-golang](https://github.com/dtapps/golang/actions/workflows/build-golang.yml/badge.svg)](https://github.com/dtapps/golang/actions/workflows/build-golang.yml) [![build-fnpack](https://github.com/dtapps/golang/actions/workflows/build-fnpack.yml/badge.svg)](https://github.com/dtapps/golang/actions/workflows/build-fnpack.yml)

本仓库用两套平台构建两个自建镜像：CNB 推送到制品库（`docker.cnb.cool/dtapp/golang`），GitHub Actions 推送到 GHCR（`ghcr.io/dtapps/golang`）。每个镜像在每套平台上都有独立的 workflow 与构建脚本（有意复制，不互相引用），标签契约保持一致；改镜像内容或标签规则时两份都要改，见 [docs/github.md](docs/github.md)。

## 两个镜像

| 镜像                           | CNB 地址                              | GitHub 地址（GHCR）            | Dockerfile（CNB / GitHub）                                           | 文档                                  |
|--------------------------------|---------------------------------------|--------------------------------|----------------------------------------------------------------------|---------------------------------------|
| Golang 构建环境（不含 fnpack） | `docker.cnb.cool/dtapp/golang`        | `ghcr.io/dtapps/golang`        | `.cnb/docker/Dockerfile.golang` / `.github/docker/Dockerfile.golang` | [docs/golang/](docs/golang/README.md) |
| Golang 构建环境 + fnpack       | `docker.cnb.cool/dtapp/golang/fnpack` | `ghcr.io/dtapps/golang/fnpack` | `.cnb/docker/Dockerfile.fnpack` / `.github/docker/Dockerfile.fnpack` | [docs/golang/](docs/golang/README.md) |

构建脚本按镜像拆分：CNB 用 `.cnb/scripts/build-golang.sh` 与 `build-fnpack.sh`，GitHub 用 `.github/scripts/build-golang.sh` 与 `build-fnpack.sh`。fnpack 镜像依赖同版本的 golang 基础镜像：先发布基础镜像，再 `FROM` 它构建 fnpack。两侧的标签名、提升规则、冒烟断言必须保持一致，平台胶水（触发器、镜像源、元数据落地）各自维护。

**镜像里有什么**

- Go 工具链（基座 `golang:1.27.3-trixie`）
- UPX、nfpm
- Node.js + npm + pnpm
- sqlc、golangci-lint、govulncheck、shfmt、dockerfmt、yamlfmt、gojq、sql-formatter、markdownfmt
- fnpack 镜像只在上面的基础上多一个 `fnpack`，两个镜像的工具链完全一致

**两个镜像怎么选**

- 只需要 Go 构建、打包 deb/rpm、前端依赖或代码检查：用 `golang`。
- 需要给 FnOS 打 `.fpk` 包：用 `golang/fnpack`。
- 两个镜像的标签完全对应：同一个 `<go 版本>` 下，`fnpack` 镜像就是基础镜像 + fnpack。

## 快速使用

```bash
# 拉 CNB 制品库或 GHCR 都行，标签规则一致
docker run --rm -it docker.cnb.cool/dtapp/golang:latest bash
docker run --rm -it ghcr.io/dtapps/golang:latest bash

# 带 fnpack 的版本
docker run --rm docker.cnb.cool/dtapp/golang/fnpack:latest fnpack --help
docker run --rm ghcr.io/dtapps/golang/fnpack:latest fnpack --help
```

作为基础镜像：

```dockerfile
FROM docker.cnb.cool/dtapp/golang:latest
# 或
FROM ghcr.io/dtapps/golang:latest
# 需要 fnpack：ghcr.io/dtapps/golang/fnpack:latest
```

## 仓库结构

```text
.cnb/
├── docker/
│   ├── Dockerfile.golang           # golang 基础镜像（不含 fnpack）
│   └── Dockerfile.fnpack           # 在 golang 镜像上加 fnpack
├── scripts/
│   ├── build-golang.sh             # CNB：构建、冒烟、发布 golang 基础镜像
│   └── build-fnpack.sh             # CNB：基于基础镜像构建、冒烟、发布 fnpack
├── workflows/                      # build-golang.yml / build-fnpack.yml / 扫描与评审
└── web_trigger.yml                 # 两个手动构建按钮（golang / fnpack）
.github/
├── docker/                         # GitHub 侧的 Dockerfile 副本
├── scripts/                        # GitHub 侧的两个构建脚本副本
├── workflows/
│   ├── build-golang.yml            # GitHub：构建并推送 golang 基础镜像
│   └── build-fnpack.yml            # GitHub：基础镜像成功后构建并推送 fnpack
├── annotation.json                 # golang 镜像元数据（CI 生成，.gitignore 已排除）
├── annotation-fnpack.json          # fnpack 镜像元数据（CI 生成，.gitignore 已排除）
└── dependabot.yml                  # GitHub Actions 依赖更新
docs/
├── golang/                         # 镜像层文档（README + 分册索引 + 分册）
├── cnb.md                          # CNB 平台层说明
└── github.md                       # GitHub Actions / GHCR 平台说明
备份/                               # 改造前的两份参考 Dockerfile
```

## 镜像源

| 平台           | GitHub Release / nodejs.org   | APT / Go module / npm |
|----------------|-------------------------------|-----------------------|
| GitHub Actions | 直连 github.com / nodejs.org  | 腾讯云镜像            |
| CNB            | `https://files.m.daocloud.io` | 腾讯云镜像            |

GitHub 侧不传 `GITHUB_MIRROR` / `NODE_MIRROR`；CNB 侧由构建脚本传入 DaoCloud 镜像。细节见 [docs/golang/mirrors.md](docs/golang/mirrors.md)。

## 约定

- 提交前跑 `make format`（yamlfmt / markdownfmt / shfmt / dockerfmt）与 `make lint-shell`；范围包含 `.cnb/` 与 `.github/` 两侧的脚本、Dockerfile 与 workflow。
- 标签是对外契约：`<go 版本>` / `<major.minor>` / `latest`，外加 `<go 版本>-linux-{amd64,arm64}`。标签每天可能被同名覆盖，固定产物请用元数据里的 digest。
- fnpack 镜像永远基于同版本的 golang 基础镜像构建；基础镜像的 `latest` / `<minor>` 没跟上时，fnpack 不会单独提升这两个标签。
- 两个平台的 Dockerfile 与脚本是两份副本（`.cnb/` 与 `.github/`）：改镜像内容、标签规则或冒烟断言时两处都要改；只改平台胶水时各改各的。平台层说明见 [docs/cnb.md](docs/cnb.md) 与 [docs/github.md](docs/github.md)。
- 安全报告走 [SECURITY.md](SECURITY.md)，贡献流程与硬性规则见 [CONTRIBUTING.md](CONTRIBUTING.md)。
- 文档入口：[docs/README.md](docs/README.md)。

## 许可

[MIT](LICENSE)
