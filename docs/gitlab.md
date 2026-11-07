# GitLab CI 与 GitLab Container Registry

> 和 [CNB 流水线](cnb.md)、[GitHub Actions](github.md) 对称的一篇：讲 GitLab 侧的目录、 触发方式、镜像地址、变量契约与已知差异。

## 设计前提：三份独立实现，各自演进

GitLab 侧不 `source` CNB / GitHub 的脚本，也不与它们共用 Dockerfile：

| 职责       | CNB 侧                                                                                         | GitHub 侧                                                                                         | GitLab 侧                                                                                         |
|------------|------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------|
| Dockerfile | `.cnb/docker/Dockerfile.golang`、`Dockerfile.fnpack`、`Dockerfile.wails3`、`Dockerfile.wails2` | `.github/docker/Dockerfile.golang`、`Dockerfile.fnpack`、`Dockerfile.wails3`、`Dockerfile.wails2` | `.gitlab/docker/Dockerfile.golang`、`Dockerfile.fnpack`、`Dockerfile.wails3`、`Dockerfile.wails2` |
| 构建脚本   | `.cnb/scripts/build-golang.sh`、`build-fnpack.sh`、`build-wails3.sh`、`build-wails2.sh`        | `.github/scripts/build-golang.sh`、`build-fnpack.sh`、`build-wails3.sh`、`build-wails2.sh`        | `.gitlab/scripts/build-golang.sh`、`build-fnpack.sh`、`build-wails3.sh`、`build-wails2.sh`        |
| 流水线     | `.cnb.yml` + `.cnb/workflows/`                                                                 | `.github/workflows/`                                                                              | `.gitlab-ci.yml` + `.gitlab/workflows/`                                                           |
| 元数据     | `.cnb/annotation{,-fnpack,-wails3,-wails2}.json`                                               | `.github/annotation{,-fnpack,-wails3,-wails2}.json`                                               | `.gitlab/annotation{,-fnpack,-wails3,-wails2}.json`（job artifacts）                              |

三侧独立而不是共用的原因：标签规则、冒烟断言是同构的，但平台胶水完全不同——CNB 读 `CNB_*` 变量、用 `##[set-output]`、写 commit annotation；GitHub 读 Actions 上下文、写 Step Summary / artifact、用 QEMU + buildx；GitLab 读 `CI_*` 变量、用 job artifacts、 同样用 QEMU + buildx。

代价只有一条，且是硬性规则：**改镜像内容、标签规则、冒烟断言时，三份都要改**（见 [CONTRIBUTING](../CONTRIBUTING.md)）。只改平台胶水时各改各的。

## 镜像地址

GitLab 侧不写死地址，全部从 `CI_REGISTRY_IMAGE` 派生。本仓库在 `gitlab.com/dtapps/golang`，镜像地址就是 `registry.gitlab.com/dtapps/golang`（仓库地址前面加 `registry.` 主机名）：

| 镜像                     | GitLab 地址                                | 对应 GitHub 地址               |
|--------------------------|--------------------------------------------|--------------------------------|
| Golang 构建环境          | `registry.gitlab.com/dtapps/golang`        | `ghcr.io/dtapps/golang`        |
| Golang 构建环境 + fnpack | `registry.gitlab.com/dtapps/golang/fnpack` | `ghcr.io/dtapps/golang/fnpack` |
| Golang 构建环境 + wails3 | `registry.gitlab.com/dtapps/golang/wails3` | `ghcr.io/dtapps/golang/wails3` |
| Golang 构建环境 + wails2 | `registry.gitlab.com/dtapps/golang/wails2` | `ghcr.io/dtapps/golang/wails2` |

`CI_REGISTRY_IMAGE` 由 GitLab 自动给出，值形如 `registry.gitlab.com/<group>/<project>`（本仓库即 `registry.gitlab.com/dtapps/golang`）。 fork 或改名后自动跟着变，不需要改脚本。

## 变量来源

| 变量             | 来源                   | 作用                  |
|------------------|------------------------|-----------------------|
| `IMAGE`          | `CI_REGISTRY_IMAGE`    | golang 镜像全名       |
| `FNPACK_IMAGE`   | `IMAGE` + `/fnpack`    | fnpack 镜像全名       |
| `WAILS3_IMAGE`   | `IMAGE` + `/wails3`    | wails3 镜像全名       |
| `WAILS2_IMAGE`   | `IMAGE` + `/wails2`    | wails2 镜像全名       |
| `REGISTRY_USER`  | `CI_REGISTRY_USER`     | `docker login` 用户名 |
| `REGISTRY_TOKEN` | `CI_REGISTRY_PASSWORD` | `docker login` 密码   |
| `REVISION`       | `CI_COMMIT_SHA`        | OCI `revision`        |
| `IMAGE_SOURCE`   | `CI_PROJECT_URL`       | OCI `source` / `url`  |

这些值都由 GitLab 预定义变量派生，不需要在项目 CI/CD Variables 里配。脚本里仍保留同名 环境变量覆盖入口，本地调试时可以显式传入。

## 流水线结构

根 `.gitlab-ci.yml` 只放全局配置，四个镜像各自一个 include 文件：

```text
.gitlab-ci.yml
├── workflow / stages / variables / default
├── .gitlab/workflows/build-golang.yml   stage: golang
├── .gitlab/workflows/build-fnpack.yml   stage: variants
├── .gitlab/workflows/build-wails3.yml   stage: variants
└── .gitlab/workflows/build-wails2.yml   stage: variants
```

- `golang` 在前，`variants` 在后。一次 Run pipeline 构建全部四个镜像时，变体作业会等 基础镜像作业成功后才开始；只重建某个变体时，`golang` 作业被 `rules` 过滤掉， `variants` 直接开始（脚本仍会最多等 5 分钟基础镜像标签）。
- 三个变体在同一 stage 内并行，各自有自己的 `docker:dind`，互不干扰。

### 触发：定时与手动

GitLab 的 cron 不在 YAML 里，定时任务要建在 **CI/CD → Schedules**（或 API）里。 时间以 CNB 的 Asia/Shanghai 定时为准，与 GitHub 的 `schedule` 同刻，各平台换算如下：

> GitLab 的 Pipeline schedule 创建时可选 cron 时区。**推荐把时区选成 `Asia/Shanghai`，直接照抄下表的 cron，零换算**；若用默认 `UTC`，则按右侧 UTC 一列填。

| 镜像   | 建议 cron（Asia/Shanghai） | 对应 UTC（cron 选 UTC 时用） | 变量            | 对应 GitHub |
|--------|----------------------------|------------------------------|-----------------|-------------|
| golang | `5 0 * * *`  （00:05）     | `5 16 * * *`（16:05 UTC）    | `TARGET=golang` | 16:05 UTC   |
| fnpack | `5 3 * * *`  （03:05）     | `5 19 * * *`（19:05 UTC）    | `TARGET=fnpack` | 19:05 UTC   |
| wails3 | `5 6 * * *`  （06:05）     | `5 22 * * *`（22:05 UTC）    | `TARGET=wails3` | 22:05 UTC   |
| wails2 | `5 9 * * *`  （09:05）     | `5 1 * * *`（01:05 UTC）     | `TARGET=wails2` | 01:05 UTC   |

也可以只建一条每天一次的 schedule，不填 `TARGET`——四个镜像会按 `golang → variants` 的顺序在一条流水线里全部构建。这样总时长更长，但配置更少。

手动发布：**CI/CD → Pipelines → Run pipeline**，在表单里填：

| 变量             | 说明                                                                | 对应 GitHub 输入 |
|------------------|---------------------------------------------------------------------|------------------|
| `TARGET`         | 留空 = 四个都构建；也可填 `golang` / `fnpack` / `wails3` / `wails2` | —                |
| `VERSION`        | Go 版本；留空 = Dockerfile 的 `GO_VERSION`；可填 `1.27` / `1.27.3`  | `version`        |
| `FNPACK_VERSION` | fnpack 版本；留空 = Dockerfile 的 `FNPACK_VERSION`（当前 `1.2.3`）  | `fnpack_version` |
| `WAILS3_VERSION` | wails3 版本；留空 = 解析上游最新稳定 tag                            | `wails3_version` |
| `WAILS2_VERSION` | wails2 版本；留空 = 解析上游最新稳定 tag                            | `wails2_version` |
| `CACHE`          | `on` / `off`；`off` = 关闭 buildx 层缓存并强制全量重建              | —                |

只重建变体时，要保证对应 `<go 版本>` 的基础镜像已经存在于 registry；否则脚本等 5 分钟 后报错退出，不会自己重复装一遍工具链。

### 并发

每个作业用 `resource_group: build-<镜像>`：

- 同一个镜像的多次触发串行等待，不取消正在运行的旧流水线（与 GitHub 的 `cancel-in-progress: false` 同语义）。
- 四个 `resource_group` 各不相同，golang / fnpack / wails3 / wails2 **彼此不互斥**； 它们之间的先后顺序仍靠定时任务错开，或同一条流水线里的 stage 顺序保证。

## Runner 要求

四个作业都用 `docker:cli` + `docker:dind`，并需要：

1. **允许 privileged 容器**：`docker:dind` 本身要求 runner 的 `privileged = true`； runner 没开时 `docker info` 会一直失败，`before_script` 30 秒后报错。
2. **跨架构 QEMU**：`before_script` 分别探测 `linux/amd64` 与 `linux/arm64`； 缺哪个就用 `tonistiigi/binfmt --install <arch>` 注册（同样需要 privileged）。这样 amd64 runner 能构建 arm64，arm64 runner 也能构建 amd64。
3. **docker-container 版 buildx builder**：默认 docker 驱动不支持多架构 manifest list。 buildx 不能直接用 `DOCKER_HOST` + `DOCKER_TLS_*` 环境变量建 builder，所以 `before_script` 先用 `docker context create tls-environment` 把当前环境固化成 context， 再 `docker buildx create --driver docker-container --use tls-environment`。

GitLab.com 的共享 runner 默认不允许 privileged，因此 DinD 起不来；请使用自建 runner （Docker executor，`privileged = true`），或改用能提供 Docker socket 的 runner。若使用 socket 绑定，可删掉根文件里的 `services` 与 `DOCKER_*` 变量，其余配置不变。

## 变量契约

每个作业只把 GitLab 的 uppercase 变量映射成脚本认识的 lowercase 变量：

```yaml
# build-golang.yml
export version="${VERSION:-}"

# build-fnpack.yml
export version="${VERSION:-}"
export fnpack_version="${FNPACK_VERSION:-}"

# build-wails3.yml
export version="${VERSION:-}"
export wails3_version="${WAILS3_VERSION:-}"

# build-wails2.yml
export version="${VERSION:-}"
export wails2_version="${WAILS2_VERSION:-}"
```

其余由脚本从 `CI_*` 派生。`CI_REGISTRY_PASSWORD` 是 GitLab 自动注入的临时令牌， 不要写进项目变量。

## 标签契约

与 CNB / GitHub 完全一致：

```text
<go 版本>                 1.27.3
<major.minor>             1.27
latest                    latest
<go 版本>-linux-amd64     1.27.3-linux-amd64
<go 版本>-linux-arm64     1.27.3-linux-arm64
```

各变体镜像使用同一组标签。golang 的 `latest` / `<major.minor>` 在自身冒烟通过后提升； fnpack / wails3 / wails2 只在基础镜像对应标签也指向本次版本时才提升。

## 缓存

与 CNB / GitHub 同一套做法：buildx 层缓存写到 registry 的 `<镜像>:buildcache`， `mode=min`。GitLab 的 `cache:` 在这里是空配置——构建缓存不落在 runner 本地，换 runner 或换流水线也能命中。

工具版本在构建前解析成具体版本号再传 `--build-arg`：上游没发新版就全命中，发新版才 重建对应那一层。`CACHE=off` 可关闭缓存并强制全量重建；缓存导出失败会自动去掉缓存重试 一次。

## 元数据

四个脚本分别写：

```text
.gitlab/annotation.json
.gitlab/annotation-fnpack.json
.gitlab/annotation-wails3.json
.gitlab/annotation-wails2.json
```

每个 job 用 `artifacts:paths` 保留 30 天；构建失败时也会尽量保留（`when: always`）。 GitLab 没有 GitHub Step Summary 那种专门的运行摘要，元数据同时会打印在 job 日志里。

## 与 GitHub 的差异

| 维度       | GitHub                                      | GitLab                                               |
|------------|---------------------------------------------|------------------------------------------------------|
| 镜像名来源 | `ghcr.io` + `GITHUB_REPOSITORY`             | `CI_REGISTRY_IMAGE`                                  |
| 登录       | `GITHUB_ACTOR` / `GITHUB_TOKEN`             | `CI_REGISTRY_USER` / `CI_REGISTRY_PASSWORD`          |
| 定时任务   | YAML 里的 `schedule.cron`                   | UI / API 里的 Pipeline schedules，用 `TARGET` 选镜像 |
| 手动触发   | `workflow_dispatch`                         | Run pipeline（`CI_PIPELINE_SOURCE == "web"`）        |
| 多架构     | `setup-qemu-action` + `setup-buildx-action` | `before_script` 里装 QEMU + `docker buildx create`   |
| 并发       | `concurrency.group` + `queue: max`          | `resource_group`                                     |
| 元数据     | Step Summary + artifact                     | job artifacts                                        |
| 磁盘准备   | 删除预装 SDK，释放空间                      | 不需要（dind 用的是 runner 自己的磁盘）              |

## 常见问题

- **日志停在某一行、一行错误都没有就 `exit code 1`**：GitLab Runner 生成的包装脚本是 `set -eo pipefail`（GitHub Actions 默认的 `bash -e` 没有 pipefail）。脚本里凡是 `grep ... | head ...` 这种「匹配不到也算正常」的 pipeline，在 pipefail 下整条返回 1，赋值语句跟着返回 1，`set -e` 会在无任何输出的情况下直接杀掉作业——最典型的就是读 Dockerfile 的 `GOPROXY=`，而 GitLab 侧 Dockerfile 本来就没有这一行。解析型 helper 一律以 `|| true` 收尾（匹配不到 = 空值），`cleanup` 里也补了「脚本静默退出」的提示，看到它就说明又冒出一条没兜住的 pipeline。
- **`docker info` 30 秒超时**：runner 没开 privileged，或 `docker:dind` 服务没起来。 先看 job 日志里 dind service 的输出。
- **`could not create a builder instance with TLS data loaded from environment`**：`before_script` 少了把 dind 的 TLS 环境固化成 docker context 这一步。 buildx 不接受直接从 `DOCKER_HOST` / `DOCKER_TLS_*` 建 builder，先 `docker context create tls-environment`， 再把 context 作为 `docker buildx create` 的 endpoint。后面那句 `failed to find instance` 是同一原因导致的连带报错。
- **`exec format error` / 跨架构构建失败**：QEMU binfmt 没注册成功。确认 `tonistiigi/binfmt --install amd64,arm64` 能跑（需要 privileged），或让 runner 预装 binfmt。
- **`no space left on device`**：dind 的磁盘在 runner 上，基础镜像 + 四个变体同时构建时 容易满；给 runner 留足空间，或把四个镜像拆到不同 schedule / runner。
- **`manifest unknown`**：变体作业找不到基础镜像 `<go 版本>`。先跑 `TARGET=golang`， 或等定时任务里的 golang 作业完成。
- **推送 403**：确认 `CI_REGISTRY_PASSWORD` 没有被项目变量覆盖成只读 token； GitLab 自动注入的 `CI_JOB_TOKEN` / `CI_REGISTRY_PASSWORD` 才有写权限。
- **镜像里没有最新工具**：检查 `<镜像>:buildcache` 是否存在、`CACHE` 是否为 `off`； 上游没发新版时全命中缓存是预期行为。
