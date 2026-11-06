# GitHub Actions 与 GHCR

> 和 [CNB 流水线](cnb.md) 对称的一篇：讲 GitHub 侧的目录、触发方式、镜像地址、变量契约与已知差异。

## 设计前提：两份独立实现，各自演进

GitHub 侧不 `source` CNB 的脚本，也不与 CNB 共用 Dockerfile：

| 职责       | CNB 侧                                                                    | GitHub 侧                                                                    |
|------------|---------------------------------------------------------------------------|------------------------------------------------------------------------------|
| Dockerfile | `.cnb/docker/Dockerfile.golang`、`Dockerfile.fnpack`、`Dockerfile.wails3` | `.github/docker/Dockerfile.golang`、`Dockerfile.fnpack`、`Dockerfile.wails3` |
| 构建脚本   | `.cnb/scripts/build-golang.sh`、`build-fnpack.sh`、`build-wails3.sh`      | `.github/scripts/build-golang.sh`、`build-fnpack.sh`、`build-wails3.sh`      |
| 流水线     | `.cnb.yml` + `.cnb/workflows/`                                            | `.github/workflows/`                                                         |
| 元数据     | `.cnb/annotation{,-fnpack,-wails3}.json`                                  | `.github/annotation{,-fnpack,-wails3}.json`                                  |

各自独立而不是共用的原因：两侧的标签规则、冒烟断言是同构的，但平台胶水完全不同——CNB 读 `CNB_*` 变量、用 `##[set-output]`、写 commit annotation；GitHub 读 Actions 上下文、写 Step Summary/artifact、用 QEMU + buildx。共用意味着任何一侧改平台细节都要考虑另一侧。

代价只有一条，且是硬性规则：**改镜像内容、标签规则、冒烟断言时，两份都要改**（见 [CONTRIBUTING](../CONTRIBUTING.md)）。只改平台胶水时各改各的。

## 镜像地址

| 镜像                     | GHCR 地址                      | 对应 CNB 地址                         |
|--------------------------|--------------------------------|---------------------------------------|
| Golang 构建环境          | `ghcr.io/dtapps/golang`        | `docker.cnb.cool/dtapp/golang`        |
| Golang 构建环境 + fnpack | `ghcr.io/dtapps/golang/fnpack` | `docker.cnb.cool/dtapp/golang/fnpack` |
| Golang 构建环境 + wails3 | `ghcr.io/dtapps/golang/wails3` | `docker.cnb.cool/dtapp/golang/wails3` |

脚本从 Actions 内置变量派生，不写死：

| 变量            | 来源                                      | 作用                  |
|-----------------|-------------------------------------------|-----------------------|
| `IMAGE`         | `ghcr.io` + `GITHUB_REPOSITORY`（转小写） | golang 镜像全名       |
| `FNPACK_IMAGE`  | `IMAGE` + `/fnpack`                       | fnpack 镜像全名       |
| `WAILS3_IMAGE`  | `IMAGE` + `/wails3`                       | wails3 镜像全名       |
| `REGISTRY_USER` | `GITHUB_ACTOR`                            | `docker login` 用户名 |
| `REVISION`      | `GITHUB_SHA`                              | OCI `revision`        |
| `IMAGE_SOURCE`  | `https://github.com/<GITHUB_REPOSITORY>`  | OCI `source` / `url`  |

fork 后自动推到 `ghcr.io/<你的账号>/golang`，rename 仓库也不需要改代码。

## Workflow 结构

每个镜像一个 workflow，分别对应一个 GHCR 地址。

### `build-golang.yml`

- 触发：`schedule` / `workflow_dispatch`
- `build` 作业：检出 → 释放磁盘 → QEMU → buildx → `source .github/scripts/build-golang.sh` → Step Summary → artifact
- 超时：180 分钟

### `build-fnpack.yml`

- 触发：
  - `schedule`：每天 19:35 UTC（北京 03:35），比 `build-golang` 晚 3 小时
  - `workflow_dispatch`：手动，要求对应版本的基础镜像已存在；可填 `version` / `fnpack_version`
- `build` 作业：检出 → 释放磁盘 → QEMU → buildx → `source .github/scripts/build-fnpack.sh` → Step Summary → artifact
- 超时：90 分钟

### `build-wails3.yml`

- 触发：
  - `schedule`：每天 22:35 UTC（北京 06:35），比 `build-fnpack` 再晚 3 小时
  - `workflow_dispatch`：手动，要求对应版本的基础镜像已存在；可填 `version` / `wails3_version`
- `build` 作业：检出 → 释放磁盘 → QEMU → buildx → `source .github/scripts/build-wails3.sh` → Step Summary → artifact
- 超时：120 分钟（`go install` 要按 amd64 + arm64 各编译一遍 wails3 CLI，arm64 那趟走 QEMU）

`wails3_version` 留空时脚本先 `go list -m github.com/wailsapp/wails/v3@latest` 解析最新稳定 tag（如 `v3.1.0`）再传进 `--build-arg`；解析失败回退 `latest`，由 Dockerfile 在构建时解析（层缓存随之失效）。策略细节见 [wails3/README.md](wails3/README.md#wails3-版本策略)。

`build-fnpack` / `build-wails3` 启动后都会最多等 5 分钟，让 `<go 版本>` 标签在 registry 里可读；仍然不存在就报错退出，不会自己重复安装一遍工具链。

## 并发与排队

三个 workflow 的 `concurrency` 同构（以 `build-golang` 为例）：

```yaml
concurrency:
  group: build-golang-${{ github.ref }}
  cancel-in-progress: false
  queue: max
```

- `group`：`build-<镜像>-${{ github.ref }}`，按分支隔离；三个 workflow 的 group 各不相同，**彼此不互斥**。
- `cancel-in-progress: false`：新触发的 run 进入 `pending` 等待，不取消正在运行的旧 run。
- `queue: max`：同一 group 最多 100 个 `pending`，按进入等待的先后 FIFO 依次执行；只有队列满时溢出的新 run 才会被取消。

`queue` 默认是 `single`（只留 1 个 pending，后来的 run 顶掉早先的 pending），这正是「连续触发时旧运行被取消」的来源；`max` 是 GitHub 2026-05 起支持的值。两条约束：

- `queue: max` 不能与 `cancel-in-progress: true` 组合，否则 workflow 校验失败。
- 排队只发生在「同一个 workflow、同一个分支」的多次触发之间。三个镜像的先后顺序仍只靠定时任务错开 3 小时保证；手动同时触发三个 workflow 时会并行，fnpack / wails3 依旧靠脚本里那 5 分钟等基础镜像标签。

参考：[GitHub Docs — Control the concurrency of workflows and jobs](https://docs.github.com/en/actions/writing-workflows/choosing-what-your-workflow-does/control-the-concurrency-of-workflows-and-jobs)。

## 变量契约

workflow 只显式传四类变量：

```yaml
# build-fnpack.yml
env:
  REGISTRY_TOKEN: ${{ secrets.GITHUB_TOKEN }}
  version: ${{ inputs.version }}
  fnpack_version: ${{ inputs.fnpack_version }}

# build-wails3.yml
env:
  REGISTRY_TOKEN: ${{ secrets.GITHUB_TOKEN }}
  version: ${{ inputs.version }}
  wails3_version: ${{ inputs.wails3_version }}
```

其余由脚本从 Actions 内置变量派生。`GITHUB_TOKEN` 不会自动进环境变量，所以必须显式从 secrets 传。`fnpack_version` 留空时，脚本回退到 Dockerfile 的 `FNPACK_VERSION`（当前 `1.2.3`，上游没有 latest 查询接口，暂作为最新版本）；`wails3_version` 留空时脚本解析上游最新稳定 tag，解析不到才回退 Dockerfile 的 `WAILS3_VERSION`（默认 `latest`）。

权限：

三个 workflow 的 `permissions` 相同：

```yaml
permissions:
  contents: read
  packages: write
```

显式声明 `permissions:` 后，未列出的权限一律不授予。`secrets.GITHUB_TOKEN` 经 `REGISTRY_TOKEN` 传给构建脚本，用于 `docker login` 和 GHCR 读写。

- `contents: read`：`actions/checkout` 检出源码。
- `packages: write`：脚本对 GHCR 的三类写操作：
  1. `docker buildx build --push` 推多架构 manifest list；
  2. `--cache-to type=registry` 写 `<镜像>:buildcache` 缓存清单；
  3. `docker buildx imagetools create` 派生 `<版本>-linux-{amd64,arm64}`，冒烟通过后提升 `<major.minor>` / `latest`。

  `write` 隐含 `read`：fnpack / wails3 还要 `imagetools inspect` 读基座 manifest digest。

不需要 `id-token: write` / `attestations: write`（`--provenance=mode=min` 由 buildx 本地生成），也不需要 `actions: read`（`queue: max` 是平台层能力，`upload-artifact` 走 `ACTIONS_RUNTIME_TOKEN`）。

> 降成 `packages: read` 会在首次 `--push` 时被拒，排查见 [构建失败排查](golang/troubleshooting.md#推送-ghcr-报-denied)。

## 与 CNB 的差异

| 维度          | CNB                                                    | GitHub                                       |
|---------------|--------------------------------------------------------|----------------------------------------------|
| 镜像名来源    | `CNB_DOCKER_REGISTRY` + `CNB_REPO_SLUG_LOWERCASE`      | `ghcr.io` + `GITHUB_REPOSITORY`              |
| 登录          | `CNB_TOKEN_USER_NAME` / `CNB_TOKEN`                    | `GITHUB_ACTOR` / `GITHUB_TOKEN`              |
| 定时任务      | golang 00:05、fnpack 03:05、wails3 06:05 Asia/Shanghai | golang 16:35、fnpack 19:35、wails3 22:35 UTC |
| 多架构        | docker 服务自带                                        | `setup-qemu-action` + `setup-buildx-action`  |
| GitHub 下载源 | `https://files.m.daocloud.io`                          | 直连 `github.com` / `nodejs.org`             |
| 元数据        | commit annotation                                      | Step Summary + artifact                      |
| 磁盘准备      | 无                                                     | 删除预装 SDK，释放空间                       |

## 标签契约

与 CNB 完全一致：

```text
<go 版本>                 1.27.3
<major.minor>             1.27
latest                    latest
<go 版本>-linux-amd64     1.27.3-linux-amd64
<go 版本>-linux-arm64     1.27.3-linux-arm64
```

三个镜像使用同一组标签。golang 的 `latest` / `<major.minor>` 在自身冒烟通过后提升；fnpack / wails3 只在基础镜像对应标签也指向本次版本时才提升。

## 缓存

与 CNB 侧同一套做法：buildx 层缓存写到 GHCR 的 `<镜像>:buildcache`，`mode=min`。

- 没有用 `type=gha`：它需要 `ACTIONS_CACHE_URL` / `ACTIONS_RUNTIME_TOKEN`（脚本裸调 `docker buildx build` 时得自己暴露），且有 10GB 上限，这个镜像的缓存很容易顶到；registry 缓存和 CNB 侧对称，脚本结构不用改。
- `mode=min` 只导出最终镜像里已有的层，缓存清单引用的 blob 与镜像层是同一批 digest，所以存储增量很小。GHCR 不会自动回收无人引用的 blob：工具升级后旧层会留在包里，长期需要偶尔清理。
- `CACHE=off` 关闭缓存并强制全量重建；缓存导出失败会自动去掉缓存重试一次。

```yaml
env:
  CACHE: off   # 可选：需要一次干净的全量构建时加
```

细节见 [golang/build.md](golang/build.md#缓存)。

## 固定产物

```bash
docker pull ghcr.io/dtapps/golang@sha256:<golang_digest>
docker pull ghcr.io/dtapps/golang/fnpack@sha256:<fnpack_digest>
docker pull ghcr.io/dtapps/golang/wails3@sha256:<wails3_digest>
```

golang 的 digest 在 `golang-annotation` artifact / Step Summary 里；fnpack 的在 `fnpack-annotation` 里；wails3 的在 `wails3-annotation` 里。

## 常见问题

- **GHCR 推送 403**：检查 `packages: write` 与仓库 Settings → Actions 权限。
- **大写仓库名**：GHCR 要求包名小写，脚本会提前拦截。
- **arm64 构建报 exec format error**：检查 `setup-qemu-action` 是否在 buildx 之前。
- **磁盘不足**：确认「释放磁盘空间」步骤存在；不要在同一 runner 上并行跑其他重构建。
