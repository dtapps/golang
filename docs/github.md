# GitHub Actions 与 GHCR

> 和 [CNB 流水线](cnb.md) 对称的一篇：讲 GitHub 侧的目录、触发方式、镜像地址、变量契约与已知差异。

## 设计前提：两份副本，各自演进

GitHub 侧不 `source` CNB 的脚本，也不与 CNB 共用 Dockerfile：

| 职责       | CNB 侧                                               | GitHub 侧                                               |
|------------|------------------------------------------------------|---------------------------------------------------------|
| Dockerfile | `.cnb/docker/Dockerfile.golang`、`Dockerfile.fnpack` | `.github/docker/Dockerfile.golang`、`Dockerfile.fnpack` |
| 构建脚本   | `.cnb/scripts/build-golang.sh`、`build-fnpack.sh`    | `.github/scripts/build-golang.sh`、`build-fnpack.sh`    |
| 流水线     | `.cnb.yml` + `.cnb/workflows/`                       | `.github/workflows/`                                    |
| 元数据     | `.cnb/annotation{,-fnpack}.json`                     | `.github/annotation{,-fnpack}.json`                     |

复制而不是共用的原因：两侧的标签规则、冒烟断言是同构的，但平台胶水完全不同——CNB 读 `CNB_*` 变量、用 `##[set-output]`、写 commit annotation；GitHub 读 Actions 上下文、写 Step Summary/artifact、用 QEMU + buildx。共用意味着任何一侧改平台细节都要考虑另一侧。

代价只有一条，且是硬性规则：**改镜像内容、标签规则、冒烟断言时，两份都要改**（见 [CONTRIBUTING](../CONTRIBUTING.md)）。只改平台胶水时各改各的。

## 镜像地址

| 镜像                     | GHCR 地址                      | 对应 CNB 地址                         |
|--------------------------|--------------------------------|---------------------------------------|
| Golang 构建环境          | `ghcr.io/dtapps/golang`        | `docker.cnb.cool/dtapp/golang`        |
| Golang 构建环境 + fnpack | `ghcr.io/dtapps/golang/fnpack` | `docker.cnb.cool/dtapp/golang/fnpack` |

脚本从 Actions 内置变量派生，不写死：

| 变量            | 来源                                      | 作用                  |
|-----------------|-------------------------------------------|-----------------------|
| `IMAGE`         | `ghcr.io` + `GITHUB_REPOSITORY`（转小写） | golang 镜像全名       |
| `FNPACK_IMAGE`  | `IMAGE` + `/fnpack`                       | fnpack 镜像全名       |
| `REGISTRY_USER` | `GITHUB_ACTOR`                            | `docker login` 用户名 |
| `REVISION`      | `GITHUB_SHA`                              | OCI `revision`        |
| `IMAGE_SOURCE`  | `https://github.com/<GITHUB_REPOSITORY>`  | OCI `source` / `url`  |

fork 后自动推到 `ghcr.io/<你的账号>/golang`，rename 仓库也不需要改代码。

## Workflow 结构

每个镜像一个 workflow，分别对应一个 GHCR 地址。

### `build-golang.yml`

- 触发：`schedule` / `workflow_dispatch` / `push` 到 `main` / `pull_request`
- `build` 作业：检出 → 释放磁盘 → QEMU → buildx → `source .github/scripts/build-golang.sh` → Step Summary → artifact
- `validate-golang` 作业（PR）：检出 → 构建 `golang:pr`（amd64）→ 冒烟
- 超时：构建 180 分钟，校验 120 分钟

### `build-fnpack.yml`

- 触发：
  - `workflow_run`：`build-golang` 在 `main` 上成功后自动接着跑
  - `workflow_dispatch`：手动，要求对应版本的基础镜像已存在
  - `push` / `pull_request`：改到 fnpack 的 Dockerfile / 脚本 / workflow
- `build` 作业：检出（`workflow_run` 时用触发那次 build-golang 的 commit）→ 释放磁盘 → QEMU → buildx → `source .github/scripts/build-fnpack.sh` → Step Summary → artifact
- `validate-fnpack` 作业（PR）：构建 `golang:pr` → 构建 `golang-fnpack:pr`（`GOLANG_IMAGE=golang:pr`）→ 冒烟
- 不登录、不推送（PR 校验）
- 刻意不初始化 buildx 做 PR 校验：fnpack 镜像 `FROM` 本地刚构建的 `golang:pr`，docker-container builder 看不到宿主 Docker 镜像库；这里用本机 `docker build`
- 超时：构建 90 分钟，校验 120 分钟

`build-fnpack` 启动后会最多等 5 分钟，让 `build-golang` 刚推送的 `<go 版本>` 标签在 registry 里可读；仍然不存在就报错退出，不会自己重复安装一遍工具链。

## 变量契约

workflow 只显式传两个变量：

```yaml
env:
  REGISTRY_TOKEN: ${{ secrets.GITHUB_TOKEN }}
  version: ${{ inputs.version }}
```

其余由脚本从 Actions 内置变量派生。`GITHUB_TOKEN` 不会自动进环境变量，所以必须显式从 secrets 传。

权限：

```yaml
permissions:
  contents: read
  packages: write
```

## 与 CNB 的差异

| 维度          | CNB                                               | GitHub                                        |
|---------------|---------------------------------------------------|-----------------------------------------------|
| 镜像名来源    | `CNB_DOCKER_REGISTRY` + `CNB_REPO_SLUG_LOWERCASE` | `ghcr.io` + `GITHUB_REPOSITORY`               |
| 登录          | `CNB_TOKEN_USER_NAME` / `CNB_TOKEN`               | `GITHUB_ACTOR` / `GITHUB_TOKEN`               |
| 定时任务      | golang 00:05、fnpack 01:05 Asia/Shanghai          | golang 16:35 UTC，fnpack 由 workflow_run 接力 |
| 多架构        | docker 服务自带                                   | `setup-qemu-action` + `setup-buildx-action`   |
| GitHub 下载源 | `https://files.m.daocloud.io`                     | 直连 `github.com` / `nodejs.org`              |
| 元数据        | commit annotation                                 | Step Summary + artifact                       |
| PR 路径过滤   | 脚本内 `git diff` 判断                            | workflow `paths:`                             |
| 磁盘准备      | 无                                                | 删除预装 SDK，释放空间                        |

## 标签契约

与 CNB 完全一致：

```text
<go 版本>                 1.27.3
<major.minor>             1.27
latest                    latest
<go 版本>-linux-amd64     1.27.3-linux-amd64
<go 版本>-linux-arm64     1.27.3-linux-arm64
```

两个镜像使用同一组标签。golang 的 `latest` / `<major.minor>` 在自身冒烟通过后提升；fnpack 只在基础镜像对应标签也指向本次版本时才提升。

## 固定产物

```bash
docker pull ghcr.io/dtapps/golang@sha256:<golang_digest>
docker pull ghcr.io/dtapps/golang/fnpack@sha256:<fnpack_digest>
```

golang 的 digest 在 `golang-annotation` artifact / Step Summary 里；fnpack 的 digest 在 `fnpack-annotation` artifact / Step Summary 里。

## 常见问题

- **GHCR 推送 403**：检查 `packages: write` 与仓库 Settings → Actions 权限。
- **大写仓库名**：GHCR 要求包名小写，脚本会提前拦截。
- **arm64 构建报 exec format error**：检查 `setup-qemu-action` 是否在 buildx 之前。
- **磁盘不足**：确认「释放磁盘空间」步骤存在；不要在同一 runner 上并行跑其他重构建。
