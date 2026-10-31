# 贡献指南

本仓库只做一件事：构建两个自建镜像——`golang`（不含 fnpack）与 `golang/fnpack`，由 CNB 与 GitHub Actions 两套流水线分别推送到 CNB 制品库与 GHCR。两个平台各维护一份 Dockerfile 与构建脚本（`.cnb/` 与 `.github/`，各自维护、不互相引用）。它没有应用代码、没有测试用例，所以「贡献」通常意味着改 Dockerfile、改构建脚本，或修文档。

## 文件地图

| 文件                                 | 职责                               | 注意事项                   |
|--------------------------------------|------------------------------------|----------------------------|
| `.cnb/docker/Dockerfile.golang`      | CNB 侧：基座、工具链、镜像源开关   | 与 `.github/` 同名文件同步 |
| `.cnb/docker/Dockerfile.fnpack`      | CNB 侧：在 golang 镜像上加 fnpack  | 与 `.github/` 同名文件同步 |
| `.github/docker/Dockerfile.golang`   | GitHub 侧：同上                    | 与 `.cnb/` 同名文件同步    |
| `.github/docker/Dockerfile.fnpack`   | GitHub 侧：同上                    | 与 `.cnb/` 同名文件同步    |
| `.cnb/scripts/build-golang.sh`       | CNB 侧：构建并发布 golang 基础镜像 | POSIX `sh`；失败要显式退出 |
| `.cnb/scripts/build-fnpack.sh`       | CNB 侧：基于基础镜像发布 fnpack    | 与 GitHub 侧标签/冒烟同步  |
| `.github/scripts/build-golang.sh`    | GitHub 侧：同上                    | 与 CNB 侧标签/冒烟同步     |
| `.github/scripts/build-fnpack.sh`    | GitHub 侧：同上                    | 与 CNB 侧标签/冒烟同步     |
| `.cnb/workflows/build-golang.yml`    | CNB 触发器（golang）               | 按钮事件                   |
| `.cnb/workflows/build-fnpack.yml`    | CNB 触发器（fnpack）               | 依赖基础镜像已推送         |
| `.github/workflows/build-golang.yml` | GitHub 触发器（golang）            | QEMU、Step Summary         |
| `.github/workflows/build-fnpack.yml` | GitHub 触发器（fnpack）            | 独立定时                   |
| `.cnb.yml`、`.cnb/web_trigger.yml`   | CNB 定时任务、两个构建按钮         | 事件名必须与 workflow 一致 |

## 本地验证

```bash
# 1. 语法与静态检查
sh -n .cnb/scripts/build-golang.sh
sh -n .cnb/scripts/build-fnpack.sh
sh -n .github/scripts/build-golang.sh
sh -n .github/scripts/build-fnpack.sh
shellcheck -s sh -S warning .cnb/scripts/*.sh .github/scripts/*.sh

# 2. 构建两个镜像
docker build -f .github/docker/Dockerfile.golang -t golang:local .
docker build -f .github/docker/Dockerfile.fnpack \
  --build-arg GOLANG_IMAGE=golang:local -t golang-fnpack:local .

# 3. 冒烟
docker run --rm golang:local sh -c 'go version; node -v; pnpm -v; sqlc version; gotestsum --version; upx --version; nfpm --version; command -v ent entc'
docker run --rm golang-fnpack:local sh -c 'go version; fnpack --help'
```

GitHub runner 在海外，直连官方下载源；CNB 走 DaoCloud。国内网络本地构建时用 CNB 的 Dockerfile：

```bash
docker build -f .cnb/docker/Dockerfile.golang \
  --build-arg GITHUB_MIRROR=https://files.m.daocloud.io \
  --build-arg NODE_MIRROR=https://files.m.daocloud.io \
  -t golang:local .
```

## 硬性规则

- **两份实现必须同步**。改镜像内容、版本 ARG、标签规则、冒烟断言时，`.cnb/` 与 `.github/` 都要改。只改平台胶水（变量来源、镜像源、元数据落地）时各改各的。
- **标签是对外契约**。只有 `<go 版本>`、`<major.minor>`、`latest`，以及 `<go 版本>-linux-{amd64,arm64}`。不要新增带日期或其他语义的标签；改名或删除标签要先在文档里写清兼容流程。
- **移动标签只在冒烟通过后提升**。golang 在自己的冒烟通过后提升；fnpack 还要等基础镜像的对应标签也指向本次版本。不要为了「先发出去」提前移动标签。
- **fnpack 镜像必须 FROM 本次构建的 golang 镜像**，保证两个镜像工具链一致。不要复制一份完整的 Dockerfile 重新装一遍。
- **两个镜像的 workflow 分开**。golang 与 fnpack 各一个 workflow / 构建脚本，不要合并回一条流水线。
- **不加不必要的工具**。新增工具要说明解决什么场景、增加多少体积，并同步两边 Dockerfile、两边冒烟列表和 `docs/golang/dockerfile.md`。
- **CNB 侧的 GitHub Release 下载必须支持 `GITHUB_MIRROR`**。CNB 依赖 DaoCloud 镜像，CNB 侧直接写死 `github.com` 会让构建失败；GitHub 侧则直接写死官方地址。
- **不要把构建脚本放进 CNB 的 `imports`**：imports 会改写 `${...}`。用 `source` 执行。
- **不要在仓库里写凭证**。CNB 凭证在 imports 的 `dtapp/envs`；GitHub 用 `secrets.GITHUB_TOKEN`。

## PR 检查清单

- [ ] 两份 Dockerfile 的安装内容一致；镜像源差异（`GOPROXY`、APT、`GITHUB_MIRROR` / `NODE_MIRROR`）符合平台约定
- [ ] 两份 `build-golang.sh` 的标签规则、冒烟断言一致
- [ ] 两份 `build-fnpack.sh` 的标签规则、基础镜像检查、冒烟断言一致
- [ ] `sh -n` 与 `shellcheck` 通过
- [ ] 本地构建两个镜像成功
- [ ] golang 镜像里 `fnpack` 不存在；fnpack 镜像里存在
- [ ] 没有把 `.cnb/annotation*.json` / `.github/annotation*.json` 提交进去
- [ ] 文档同步更新（至少 `docs/golang/` 下相关页）

## 提交信息

用一句话说明「为什么」而不是「改了什么」，例如：

```text
升级 golangci-lint 到 v2.16.0，修复 Go 1.27 下的误报
```

## 许可

提交即表示同意以 [MIT](LICENSE) 许可发布。
