# CI 流水线

每个镜像在每个平台上都有自己的 workflow / 流水线，互不合并：

| 镜像            | CNB                               | GitHub Actions     |
|-----------------|-----------------------------------|--------------------|
| `golang`        | `.cnb/workflows/build-golang.yml` | `build-golang.yml` |
| `golang/fnpack` | `.cnb/workflows/build-fnpack.yml` | `build-fnpack.yml` |
| `golang/wails3` | `.cnb/workflows/build-wails3.yml` | `build-wails3.yml` |

fnpack / wails3 镜像都 `FROM` 同版本的 golang 基础镜像，所以顺序是「先基础镜像、后两个变体」，两个变体彼此独立。

## 事件矩阵

### CNB

| 事件                                | 定义位置                                                            | 产物 / 行为                                            |
|-------------------------------------|---------------------------------------------------------------------|--------------------------------------------------------|
| `'crontab: 5 0 * * *'`              | `.cnb.yml` 的 `main`                                                | 每天 00:05 构建 golang 基础镜像；不传 version          |
| `'crontab: 5 3 * * *'`              | `.cnb.yml` 的 `main`                                                | 每天 03:05 构建 fnpack 镜像；使用 00:05 产出的基础镜像 |
| `'crontab: 5 6 * * *'`              | `.cnb.yml` 的 `main`                                                | 每天 06:05 构建 wails3 镜像；使用 00:05 产出的基础镜像 |
| `web_trigger_build_golang`          | `.cnb/workflows/build-golang.yml`                                   | 手动构建 golang，可传 `version`                        |
| `web_trigger_build_fnpack`          | `.cnb/workflows/build-fnpack.yml`                                   | 手动构建 fnpack，可传 `version` / `fnpack_version`     |
| `web_trigger_build_wails3`          | `.cnb/workflows/build-wails3.yml`                                   | 手动构建 wails3，可传 `version` / `wails3_version`     |
| `push`                              | `.cnb/workflows/{sca,knowledge-base}.yml`                           | SCA 报告、知识库索引                                   |
| `pull_request`                      | `.cnb/workflows/{code-review,cnb-sechook,code-security-config}.yml` | PR 评论、敏感信息统计、配置校验                        |
| `tag_push` / `web_trigger_codewiki` | `.cnb/workflows/codewiki.yml`                                       | Code Wiki                                              |

三条定时任务各错开三小时：03:05 的 fnpack、06:05 的 wails3 都要求 00:05 推好的 `<go 版本>` 标签已经存在。

### GitHub Actions

| 工作流         | 事件                                            | 行为                                                              |
|----------------|-------------------------------------------------|-------------------------------------------------------------------|
| `build-golang` | `schedule` 每天 `35 16 * * *` UTC（北京 00:35） | 构建并推送 golang 基础镜像                                        |
| `build-golang` | `workflow_dispatch`                             | 手动构建，可传 `version`                                          |
| `build-fnpack` | `schedule` 每天 `35 19 * * *` UTC（北京 03:35） | 构建并推送 fnpack（要求基础镜像已存在）                           |
| `build-fnpack` | `workflow_dispatch`                             | 手动构建，可传 `version` / `fnpack_version`（要求基础镜像已存在） |
| `build-wails3` | `schedule` 每天 `35 22 * * *` UTC（北京 06:35） | 构建并推送 wails3（要求基础镜像已存在）                           |
| `build-wails3` | `workflow_dispatch`                             | 手动构建，可传 `version` / `wails3_version`（要求基础镜像已存在） |

GitHub 也按错开的定时任务跑：16:35 UTC 的 golang、19:35 UTC 的 fnpack、22:35 UTC 的 wails3，每步之间留 3 小时给基础镜像构建；`build-fnpack` / `build-wails3` 还会等基础镜像标签出现最多 5 分钟。

同一 workflow、同一分支的多次触发会串行排队：不取消正在运行的旧 run，最多 100 个 `pending` 按 FIFO 等待；三个 workflow 之间不互斥，它们的先后仍只靠上面的定时错开保证。配置与约束见 [GitHub Actions 与 GHCR — 并发与排队](../github.md#并发与排队)。

## 按钮、权限与输入（CNB）

`.cnb/web_trigger.yml` 定义手动入口：

| 按钮                                | event                      | 权限                       | 输入                                                              |
|-------------------------------------|----------------------------|----------------------------|-------------------------------------------------------------------|
| 打包 Golang 镜像（多架构）          | `web_trigger_build_golang` | owner / master / developer | `version`：留空 / 1.27 / 1.27.3                                   |
| 打包 Golang + fnpack 镜像（多架构） | `web_trigger_build_fnpack` | owner / master / developer | `version`：同上；`fnpack_version`：留空 / 1.2.3                   |
| 打包 Golang + wails3 镜像（多架构） | `web_trigger_build_wails3` | owner / master / developer | `version`：同上；`wails3_version`：留空 / v3.1.0 / v3.0.0-beta.34 |
| 生成 Code Wiki                      | `web_trigger_codewiki`     | owner / master / developer | 无                                                                |

`event` 必须与 workflow 文件里的事件键逐字一致，否则按钮点下去不会产生流水线。`fnpack_version` 留空表示使用 Dockerfile 的 `FNPACK_VERSION`（当前 `1.2.3`，上游没有 latest 查询接口，暂作为最新版本）；`wails3_version` 留空表示先解析上游最新稳定 tag（`go list -m github.com/wailsapp/wails/v3@latest`，如 `v3.1.0`），解析失败才回退 Dockerfile 的 `WAILS3_VERSION=latest`。

## imports 的坑

CNB workflow 用远程 import 引入组织仓库的环境变量：

```yaml
imports:
  - https://cnb.cool/dtapp/envs/-/blob/main/docker.yml
```

**不要把构建脚本放进 imports**：imports 会对被引入的文件做变量处理，脚本里的 `${...}` 会被改写成带引号的字面量。脚本由 `source .cnb/scripts/build-*.sh` 直接执行即可。脚本里还保留了一段自检探针，被改写时会立刻停下并报错。

## 构建阶段

CNB 的 `build-golang` 作业：

1. `source .cnb/scripts/build-golang.sh`：构建、派生、冒烟、提升标签、写 `.cnb/annotation.json`。
2. `cnbcool/annotations` 插件把元数据写成 commit annotation。

CNB 的 `build-fnpack` 作业：

1. 登录并等待 `<registry>/<repo>:<go 版本>` 存在。
2. `source .cnb/scripts/build-fnpack.sh`：`FROM` 基础镜像构建、派生、冒烟、提升 fnpack 标签、写 `.cnb/annotation-fnpack.json`。
3. 同样由 `cnbcool/annotations` 写入 commit annotation。

CNB 的 `build-wails3` 作业同样三步，只是脚本换成 `build-wails3.sh`、元数据换成 `.cnb/annotation-wails3.json`；脚本会先把 `wails3_version` 解析成具体 tag（`go list -m github.com/wailsapp/wails/v3@latest`，走基座 Dockerfile 里的 GOPROXY），再 `--build-arg` 传给 Dockerfile。

GitHub 的三个 `build` 作业结构类似：释放磁盘 → QEMU → buildx → `source .github/scripts/build-*.sh` → Step Summary + artifact（`golang-annotation` / `fnpack-annotation` / `wails3-annotation`）。

## 标签提升顺序

golang 流水线：

```text
构建 golang:<版本>（push）
派生 golang:<版本>-linux-{amd64,arm64}
冒烟 golang
校验 OCI version 标签
提升 golang:<major.minor> 与 golang:latest
写元数据
```

fnpack 流水线：

```text
等待 golang:<版本> 存在
构建 golang/fnpack:<版本>（push，FROM golang:<版本>）
派生 golang/fnpack:<版本>-linux-{amd64,arm64}
冒烟 fnpack
校验 OCI version 标签
只有 golang:<tag> 也指向本次 <版本> 时，才提升 fnpack:<tag>
写元数据
```

wails3 流水线与 fnpack 同构（等待基座 → 构建 → 派生 → 冒烟 → 受基座约束地提升移动标签 → 写元数据），冒烟额外断言 `pkg-config --exists gtk4` / `webkitgtk-6.0`，并用 `go version -m` 校验二进制里的 `github.com/wailsapp/wails/v3` 模块版本等于目标版本。

任何一步失败都会停在原地：该镜像的 `latest` / `<major.minor>` 不会动。fnpack / wails3 的移动标签额外受基础镜像约束，不会跑到基础镜像前面。

## 镜像源差异

| 平台   | GitHub Release / nodejs.org      | fnpack                              | wails3                               |
|--------|----------------------------------|-------------------------------------|--------------------------------------|
| CNB    | `https://files.m.daocloud.io`    | `https://static2.fnnas.com`（直连） | 走基座的 GOPROXY（腾讯云）           |
| GitHub | 直连 `github.com` / `nodejs.org` | `https://static2.fnnas.com`（直连） | 走基座的 GOPROXY（proxy.golang.org） |

wails3 用 `go install` 装，和基座里的 Go 工具同一条路：CNB 侧基座 `Dockerfile.golang` 已把 `GOPROXY` 设成腾讯云，子镜像继承；版本解析也读同一个 `GOPROXY`，两边一致才不会出现「解析到一个版本、装成另一个」。
