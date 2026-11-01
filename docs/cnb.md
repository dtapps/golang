# CNB 流水线（平台层）

> 和 [GitHub Actions 与 GHCR](github.md) 对称的一篇：讲 CNB 侧怎么触发、镜像地址从哪来、元数据怎么落地、与 GitHub 侧差在哪。

## 目录与职责

| 路径                          | 职责                                                                     |
|-------------------------------|--------------------------------------------------------------------------|
| `.cnb.yml`                    | `include` 列表 + `main` 上的三条每日定时任务（golang / fnpack / wails3） |
| `.cnb/workflows/`             | 构建、扫描、评审、文档生成、知识库                                       |
| `.cnb/docker/`                | CNB 侧的 Dockerfile（golang / fnpack / wails3）                          |
| `.cnb/scripts/`               | CNB 侧的构建脚本（golang / fnpack / wails3 各一份）                      |
| `.cnb/web_trigger.yml`        | 手动按钮、权限、输入项                                                   |
| `.cnb/annotation.json`        | golang 构建元数据（`.gitignore` 已排除），由 annotation 插件读取         |
| `.cnb/annotation-fnpack.json` | fnpack 构建元数据（`.gitignore` 已排除）                                 |
| `.cnb/annotation-wails3.json` | wails3 构建元数据（`.gitignore` 已排除）                                 |
| `.cnb/security/`              | 代码扫描配置                                                             |

GitHub 侧有一份对应的实现（`.github/`），两边不互相引用，见文末「跨平台同步」。

## 镜像地址不是写死的

CNB 在构建环境里注入一组内置变量（[官方文档](https://docs.cnb.cool/zh/build/build-in-env.md)），脚本据此拼出镜像名：

| 变量                      | 用途                                        |
|---------------------------|---------------------------------------------|
| `CNB_DOCKER_REGISTRY`     | registry 主机（本仓库是 `docker.cnb.cool`） |
| `CNB_REPO_SLUG_LOWERCASE` | 仓库路径（本仓库是 `dtapp/golang`，全小写） |
| `CNB_TOKEN_USER_NAME`     | `docker login` 用户名                       |
| `CNB_TOKEN`               | `docker login` 密码                         |
| `CNB_COMMIT`              | 写进 OCI `revision` 标签                    |
| `CNB_REPO_URL_HTTPS`      | 写进 OCI `source` / `url` 标签              |

拼装规则（`.cnb/scripts/build-golang.sh` / `build-fnpack.sh` / `build-wails3.sh`）：

```sh
IMAGE="${CNB_DOCKER_REGISTRY}/${CNB_REPO_SLUG_LOWERCASE}"          # golang
FNPACK_IMAGE="${IMAGE}/fnpack"                                     # golang/fnpack
WAILS3_IMAGE="${IMAGE}/wails3"                                     # golang/wails3
```

所以文档里出现的 `docker.cnb.cool/dtapp/golang` 只是**本仓库当前的实际值**，不是脚本里写死的常量。fork 或改名后自动跟着变。

## 触发矩阵

| 事件                                | 定义位置                                                            | 产物                                               |
|-------------------------------------|---------------------------------------------------------------------|----------------------------------------------------|
| `'crontab: 5 0 * * *'`              | `.cnb.yml` 的 `main`                                                | 每天 00:05 构建 golang；不传 version               |
| `'crontab: 5 3 * * *'`              | `.cnb.yml` 的 `main`                                                | 每天 03:05 构建 fnpack（用 00:05 的基础镜像）      |
| `'crontab: 5 6 * * *'`              | `.cnb.yml` 的 `main`                                                | 每天 06:05 构建 wails3（用 00:05 的基础镜像）      |
| `web_trigger_build_golang`          | `.cnb/workflows/build-golang.yml`                                   | 手动构建 golang，可传 `version`                    |
| `web_trigger_build_fnpack`          | `.cnb/workflows/build-fnpack.yml`                                   | 手动构建 fnpack，可传 `version` / `fnpack_version` |
| `web_trigger_build_wails3`          | `.cnb/workflows/build-wails3.yml`                                   | 手动构建 wails3，可传 `version` / `wails3_version` |
| `push`                              | `.cnb/workflows/{sca,knowledge-base}.yml`                           | SCA 报告、知识库索引                               |
| `pull_request`                      | `.cnb/workflows/{code-review,cnb-sechook,code-security-config}.yml` | PR 评论、敏感信息统计、配置校验                    |
| `tag_push` / `web_trigger_codewiki` | `.cnb/workflows/codewiki.yml`                                       | Code Wiki                                          |

定时任务只在 `main` 顶层键下声明，所以只对默认分支生效；时间按 `Asia/Shanghai` 解释。

## 按钮、权限与输入

`.cnb/web_trigger.yml` 定义手动入口，`event` 必须与 workflow 文件里的事件键逐字一致：

| 按钮                                | event                      | 权限                       | 输入                                                              |
|-------------------------------------|----------------------------|----------------------------|-------------------------------------------------------------------|
| 打包 Golang 镜像（多架构）          | `web_trigger_build_golang` | owner / master / developer | `version`：留空 / 1.27 / 1.27.3                                   |
| 打包 Golang + fnpack 镜像（多架构） | `web_trigger_build_fnpack` | owner / master / developer | `version`：同上；`fnpack_version`：留空 / 1.2.3                   |
| 打包 Golang + wails3 镜像（多架构） | `web_trigger_build_wails3` | owner / master / developer | `version`：同上；`wails3_version`：留空 / v3.1.0 / v3.0.0-beta.34 |
| 生成 Code Wiki                      | `web_trigger_codewiki`     | owner / master / developer | 无                                                                |

`version` 留空表示使用 Dockerfile 的 `GO_VERSION`。fnpack / wails3 按钮都要求对应版本的基础镜像已经推送。`fnpack_version` 留空表示使用 Dockerfile 的 `FNPACK_VERSION`（当前 `1.2.3`，上游没有 latest 查询接口，暂作为最新版本）；`wails3_version` 留空表示解析上游最新稳定 tag（`go list -m github.com/wailsapp/wails/v3@latest`，例如 `v3.1.0`），解析失败时回退 `latest` 交给 `go install`。

## imports 与脚本执行

```yaml
imports:
  - https://cnb.cool/dtapp/envs/-/blob/main/docker.yml
stages:
  - name: 构建并推送多架构镜像
    script: |
      source .cnb/scripts/build-golang.sh
```

- 远程 import 是可变引用：`main` 一改 CI 行为就变，PR 里看不到，也无法审计。TODO 收敛到 `.cnb/envs/` 或钉 commit。
- **不要把构建脚本放进 imports**：imports 会对被引入文件做变量处理，脚本里的 `${...}` 会被改写成带引号的字面量。脚本自带自检探针，被改写时立刻报错。

## 元数据

构建脚本分别写 `.cnb/annotation.json`（golang）、`.cnb/annotation-fnpack.json`（fnpack）与 `.cnb/annotation-wails3.json`（wails3），再由 `cnbcool/annotations` 写成 commit 元数据。README 徽章从下面这种地址读取：

```text
https://cnb.cool/dtapp/golang/-/badge/annotation/commit/latest/{key}
```

常用 key：`image_version`、`golang_digest`、`fnpack_digest`、`fnpack_version`、`wails3_digest`、`wails3_version`、`tools`、`built_at`。

`cnbcool/annotations` 目前只发 `:latest`，构建网络内也取不到 digest，所以插件引用暂时无法固定版本。发现插件行为变化时先看流水线日志。

## 镜像源

CNB 在国内，构建脚本把 GitHub Release 与 nodejs.org 下载指向 `https://files.m.daocloud.io`：

```sh
MIRROR="https://files.m.daocloud.io"
docker buildx build \
  --build-arg GITHUB_MIRROR="${MIRROR}" \
  --build-arg NODE_MIRROR="${MIRROR}" \
  ...
```

CNB 侧 APT / Go module / npm 使用腾讯云镜像；GitHub 侧 APT 与 Go module 用默认源。详见 [golang/mirrors.md](golang/mirrors.md)。

## 缓存

CNB 文档里的**节点文件缓存**（`docker.volumes` + `copy-on-write`）缓存的是流水线容器自己的目录。本仓库的 apt 与 `go install` 都发生在 `services: docker` 的 buildkit 里，挂不进去，所以用的是 **buildx 层缓存**（`--cache-to type=registry`），跨节点共享：

```sh
--cache-from type=registry,ref=<镜像>:buildcache
--cache-to   type=registry,ref=<镜像>:buildcache,mode=min
```

层缓存要生效，前提是 build-arg 的值跟着版本走，所以脚本会先在基础镜像里把 `latest` 解析成具体版本号再传入——否则缓存键永远是 `latest`，层会一直命中旧产物。细节见 [golang/build.md](golang/build.md#缓存)。

- 缓存清单是普通镜像 manifest，仓库页面会多一个 `buildcache` 标签，属正常现象。
- `CACHE=off` 关闭缓存并强制全量重建。
- 缓存导出失败（registry 不支持该 manifest）会自动去掉缓存重试一次。

## 跨平台同步

`build-golang.sh`、`build-fnpack.sh`、`build-wails3.sh` 与 Dockerfile 在 CNB 和 GitHub 各有一份。改以下内容时两边都要改：

- 镜像里装什么、版本 ARG、清理逻辑
- 标签规则、提升顺序、冒烟断言
- 元数据 key（平台落地方式可以不同，内容应一致）

只改平台胶水时各改各的：

- CNB：`CNB_*` 变量、`imports`、`##[set-output]`、annotation 插件
- GitHub：Actions 上下文、Step Summary、artifact、QEMU / buildx 初始化
