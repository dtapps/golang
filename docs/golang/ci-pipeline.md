# CI 流水线

每个镜像在每个平台上都有自己的 workflow / 流水线，互不合并：

| 镜像            | CNB                               | GitHub Actions     | GitLab CI                            |
|-----------------|-----------------------------------|--------------------|--------------------------------------|
| `golang`        | `.cnb/workflows/build-golang.yml` | `build-golang.yml` | `.gitlab/workflows/build-golang.yml` |
| `golang/fnpack` | `.cnb/workflows/build-fnpack.yml` | `build-fnpack.yml` | `.gitlab/workflows/build-fnpack.yml` |
| `golang/wails3` | `.cnb/workflows/build-wails3.yml` | `build-wails3.yml` | `.gitlab/workflows/build-wails3.yml` |
| `golang/wails2` | `.cnb/workflows/build-wails2.yml` | `build-wails2.yml` | `.gitlab/workflows/build-wails2.yml` |
| `golang/fyne`   | `.cnb/workflows/build-fyne.yml`   | `build-fyne.yml`   | `.gitlab/workflows/build-fyne.yml`   |
| `golang/mygo`   | `.cnb/workflows/build-mygo.yml`   | `build-mygo.yml`   | `.gitlab/workflows/build-mygo.yml`   |

fnpack / wails3 / wails2 / fyne / mygo 镜像都 `FROM` 同版本的 golang 基础镜像，所以顺序是「先基础镜像、后五个变体」，五个变体彼此独立。

## 事件矩阵

### CNB

| 事件                                | 定义位置                                                            | 产物 / 行为                                                    |
|-------------------------------------|---------------------------------------------------------------------|----------------------------------------------------------------|
| `'crontab: 5 0 * * *'`              | `.cnb.yml` 的 `main`                                                | 每天 00:05 构建 golang 基础镜像；不传 version                  |
| `'crontab: 5 3 * * *'`              | `.cnb.yml` 的 `main`                                                | 每天 03:05 构建 fnpack 镜像；使用 00:05 产出的基础镜像         |
| `'crontab: 5 6 * * *'`              | `.cnb.yml` 的 `main`                                                | 每天 06:05 构建 wails3 镜像；使用 00:05 产出的基础镜像         |
| `'crontab: 5 9 * * *'`              | `.cnb.yml` 的 `main`                                                | 每天 09:05 构建 wails2 镜像；使用 00:05 产出的基础镜像         |
| `'crontab: 5 12 * * *'`             | `.cnb.yml` 的 `main`                                                | 每天 12:05 构建 fyne 镜像；使用 00:05 产出的基础镜像           |
| `'crontab: 5 15 * * *'`             | `.cnb.yml` 的 `main`                                                | 每天 15:05 构建 mygo 镜像；使用 00:05 产出的基础镜像           |
| `web_trigger_build_golang`          | `.cnb/workflows/build-golang.yml`                                   | 手动构建 golang，可传 `version`                                |
| `web_trigger_build_fnpack`          | `.cnb/workflows/build-fnpack.yml`                                   | 手动构建 fnpack，可传 `version` / `fnpack_version`             |
| `web_trigger_build_wails3`          | `.cnb/workflows/build-wails3.yml`                                   | 手动构建 wails3，可传 `version` / `wails3_version`             |
| `web_trigger_build_wails2`          | `.cnb/workflows/build-wails2.yml`                                   | 手动构建 wails2，可传 `version` / `wails2_version`             |
| `web_trigger_build_fyne`            | `.cnb/workflows/build-fyne.yml`                                     | 手动构建 fyne，可传 `version` / `fyne_version`                 |
| `web_trigger_build_mygo`            | `.cnb/workflows/build-mygo.yml`                                     | 手动构建 mygo，可传 `version` / `mygo_version` / `bun_version` |
| `push`                              | `.cnb/workflows/{sca,knowledge-base}.yml`                           | SCA 报告、知识库索引                                           |
| `pull_request`                      | `.cnb/workflows/{code-review,cnb-sechook,code-security-config}.yml` | PR 评论、敏感信息统计、配置校验                                |
| `tag_push` / `web_trigger_codewiki` | `.cnb/workflows/codewiki.yml`                                       | Code Wiki                                                      |

六条定时任务各错开三小时：03:05 的 fnpack、06:05 的 wails3、09:05 的 wails2、12:05 的 fyne、15:05 的 mygo 都要求 00:05 推好的 `<go 版本>` 标签已经存在。

### GitHub Actions

| 工作流         | 事件                                           | 行为                                                                            |
|----------------|------------------------------------------------|---------------------------------------------------------------------------------|
| `build-golang` | `schedule` 每天 `5 16 * * *` UTC（北京 00:05） | 构建并推送 golang 基础镜像                                                      |
| `build-golang` | `workflow_dispatch`                            | 手动构建，可传 `version`                                                        |
| `build-fnpack` | `schedule` 每天 `5 19 * * *` UTC（北京 03:05） | 构建并推送 fnpack（要求基础镜像已存在）                                         |
| `build-fnpack` | `workflow_dispatch`                            | 手动构建，可传 `version` / `fnpack_version`（要求基础镜像已存在）               |
| `build-wails3` | `schedule` 每天 `5 22 * * *` UTC（北京 06:05） | 构建并推送 wails3（要求基础镜像已存在）                                         |
| `build-wails3` | `workflow_dispatch`                            | 手动构建，可传 `version` / `wails3_version`（要求基础镜像已存在）               |
| `build-wails2` | `schedule` 每天 `5 1 * * *` UTC（北京 09:05）  | 构建并推送 wails2（要求基础镜像已存在）                                         |
| `build-wails2` | `workflow_dispatch`                            | 手动构建，可传 `version` / `wails2_version`（要求基础镜像已存在）               |
| `build-fyne`   | `schedule` 每天 `5 4 * * *` UTC（北京 12:05）  | 构建并推送 fyne（要求基础镜像已存在）                                           |
| `build-fyne`   | `workflow_dispatch`                            | 手动构建，可传 `version` / `fyne_version`（要求基础镜像已存在）                 |
| `build-mygo`   | `schedule` 每天 `5 7 * * *` UTC（北京 15:05）  | 构建并推送 mygo（要求基础镜像已存在）                                           |
| `build-mygo`   | `workflow_dispatch`                            | 手动构建，可传 `version` / `mygo_version` / `bun_version`（要求基础镜像已存在） |

GitHub 也按错开的定时任务跑：16:05 UTC 的 golang、19:05 UTC 的 fnpack、22:05 UTC 的 wails3、01:05 UTC 的 wails2、04:05 UTC 的 fyne、07:05 UTC 的 mygo，每步之间留 3 小时给基础镜像构建；各变体 workflow 还会等基础镜像标签出现最多 5 分钟。

同一 workflow、同一分支的多次触发会串行排队：不取消正在运行的旧 run，最多 100 个 `pending` 按 FIFO 等待；六个 workflow 之间不互斥，它们的先后仍只靠上面的定时错开保证。配置与约束见 [GitHub Actions 与 GHCR — 并发与排队](../github.md#并发与排队)。

### GitLab CI

GitLab 的 cron 不在 YAML 里，要在 **CI/CD → Schedules**（或 API）建定时流水线，用变量 `TARGET` 选镜像：

| 镜像   | 建议 cron（UTC） | 变量            | 行为                                    |
|--------|------------------|-----------------|-----------------------------------------|
| golang | `5 16 * * *`     | `TARGET=golang` | 构建并推送 golang 基础镜像              |
| fnpack | `5 19 * * *`     | `TARGET=fnpack` | 构建并推送 fnpack（要求基础镜像已存在） |
| wails3 | `5 22 * * *`     | `TARGET=wails3` | 构建并推送 wails3（要求基础镜像已存在） |
| wails2 | `5 1 * * *`      | `TARGET=wails2` | 构建并推送 wails2（要求基础镜像已存在） |
| fyne   | `5 4 * * *`      | `TARGET=fyne`   | 构建并推送 fyne（要求基础镜像已存在）   |
| mygo   | `5 7 * * *`      | `TARGET=mygo`   | 构建并推送 mygo（要求基础镜像已存在）   |

也可以只建一条每天一次的 schedule 且不填 `TARGET`，六个镜像会在同一条流水线里按 `golang → variants` 的 stage 顺序全部构建。手动 **Run pipeline** 同理：`TARGET` 留空跑全部， 填一个值只跑那个镜像。输入映射见下表。

同一镜像的多次触发用 `resource_group: build-<镜像>` 串行等待，不取消正在运行的旧流水线； 六个 `resource_group` 互不相同，所以六个镜像之间不互斥。配置与约束见 [GitLab CI 与 GitLab Container Registry](../gitlab.md#并发)。

## 按钮、权限与输入（CNB）

`.cnb/web_trigger.yml` 定义手动入口：

| 按钮                                | event                      | 权限                       | 输入                                                                                |
|-------------------------------------|----------------------------|----------------------------|-------------------------------------------------------------------------------------|
| 打包 Golang 镜像（多架构）          | `web_trigger_build_golang` | owner / master / developer | `version`：留空 / 1.27 / 1.27.3                                                     |
| 打包 Golang + fnpack 镜像（多架构） | `web_trigger_build_fnpack` | owner / master / developer | `version`：同上；`fnpack_version`：留空 / 1.2.3                                     |
| 打包 Golang + wails3 镜像（多架构） | `web_trigger_build_wails3` | owner / master / developer | `version`：同上；`wails3_version`：留空 / v3.1.0 / v3.0.0-beta.34                   |
| 打包 Golang + wails2 镜像（多架构） | `web_trigger_build_wails2` | owner / master / developer | `version`：同上；`wails2_version`：留空 / v2.17.1 / 2.17.1                          |
| 打包 Golang + fyne 镜像（多架构）   | `web_trigger_build_fyne`   | owner / master / developer | `version`：同上；`fyne_version`：留空 / v1.7.4 / 1.7.4（CLI 版本）                  |
| 打包 Golang + mygo 镜像（多架构）   | `web_trigger_build_mygo`   | owner / master / developer | `version`：同上；`mygo_version`：留空 / v0.8.1 / 0.8.1；`bun_version`：留空 / 1.4.4 |
| 生成 Code Wiki                      | `web_trigger_codewiki`     | owner / master / developer | 无                                                                                  |

`event` 必须与 workflow 文件里的事件键逐字一致，否则按钮点下去不会产生流水线。`fnpack_version` 留空表示使用 Dockerfile 的 `FNPACK_VERSION`（当前 `1.2.3`，上游没有 latest 查询接口，暂作为最新版本）；`wails3_version` 留空表示先解析上游最新稳定 tag（`go list -m github.com/wailsapp/wails/v3@latest`，如 `v3.1.0`）；`wails2_version` 留空表示解析 `github.com/wailsapp/wails/v2@latest`（如 `v2.17.1`）；`fyne_version` 留空表示解析 `fyne.io/tools@latest`（如 `v1.7.4`；注意上游把 `v1.26.0` / `v1.26.1` 标了 retract，不要当成新版本）；`mygo_version` 留空表示解析 `github.com/egoist/mygo@latest`（如 `v0.8.1`），`bun_version` 留空表示解析 npm 上的 `bun` 最新稳定版（如 `1.4.4`）。解析失败都回退对应 Dockerfile 的 `WAILS*_VERSION` / `FYNE_VERSION` / `MYGO_VERSION` / `BUN_VERSION=latest`。

GitLab 的 **Run pipeline** 表单只暴露根 `.gitlab-ci.yml` 里带 `description` 的变量：

| 变量             | 等价 GitHub 输入 | 说明                                                                                  |
|------------------|------------------|---------------------------------------------------------------------------------------|
| `TARGET`         | —                | 留空 = 六个都构建；也可填 `golang` / `fnpack` / `wails3` / `wails2` / `fyne` / `mygo` |
| `VERSION`        | `version`        | Go 版本；留空 = Dockerfile 的 `GO_VERSION`                                            |
| `FNPACK_VERSION` | `fnpack_version` | fnpack 版本；留空 = Dockerfile 的 `FNPACK_VERSION`                                    |
| `WAILS3_VERSION` | `wails3_version` | wails3 版本；留空 = 解析上游最新稳定 tag                                              |
| `WAILS2_VERSION` | `wails2_version` | wails2 版本；留空 = 解析上游最新稳定 tag                                              |
| `FYNE_VERSION`   | `fyne_version`   | fyne CLI 版本；留空 = 解析上游最新稳定 tag                                            |
| `MYGO_VERSION`   | `mygo_version`   | mygo CLI 版本；留空 = 解析上游最新稳定 tag                                            |
| `BUN_VERSION`    | `bun_version`    | bun 版本（mygo 前端模板用）；留空 = 解析 npm 上最新稳定版                             |
| `CACHE`          | —                | `on` / `off`；`off` = 关闭 buildx 层缓存并强制全量重建                                |

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

CNB 的 `build-wails2` 与 `build-fyne` 作业结构同上，脚本与元数据分别换成 `build-wails2.sh` / `annotation-wails2.json` 与 `build-fyne.sh` / `annotation-fyne.json`；fyne 侧解析的是 `fyne.io/tools@latest`。CNB 的 `build-mygo` 作业结构相同，脚本与元数据换成 `build-mygo.sh` / `annotation-mygo.json`，脚本会解析 `github.com/egoist/mygo@latest` 与 npm 上的 `bun` 最新稳定版两个版本。

GitHub 的六个 `build` 作业结构类似：释放磁盘 → QEMU → buildx → `source .github/scripts/build-*.sh` → Step Summary + artifact（`golang-annotation` / `fnpack-annotation` / `wails3-annotation` / `wails2-annotation` / `fyne-annotation` / `mygo-annotation`）。

GitLab 的六个作业结构类似：`docker:dind` 就绪 → QEMU binfmt → `docker-container` buildx builder → `. ./.gitlab/scripts/build-*.sh` → job artifacts（`.gitlab/annotation*.json`）。

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

wails3 / wails2 / fyne / mygo 流水线与 fnpack 同构（等待基座 → 构建 → 派生 → 冒烟 → 受基座约束地提升移动标签 → 写元数据）。wails3 冒烟额外断言 `pkg-config --exists gtk4` / `webkitgtk-6.0`，并用 `go version -m` 校验二进制里的 `github.com/wailsapp/wails/v3` 模块版本等于目标版本；wails2 断言 `pkg-config --exists gtk+-3.0` / `webkit2gtk-4.1`，校验 `github.com/wailsapp/wails/v2` 模块版本；fyne 断言 `pkg-config --exists` 对 `gl` / `x11` / `xrandr` / `xcursor` / `xinerama` / `xi` / `xxf86vm` / `wayland-client` / `xkbcommon` 全部成立，校验 `fyne.io/tools` 模块版本，且断言 `fnpack` / `wails3` / `wails` 都不存在；mygo 断言 `pkg-config --exists` 对 `gtk+-3.0` / `webkit2gtk-4.1` 加上面那组 GL / X11 / Wayland 的 `.pc` 全部成立，`ldconfig -p` 能查到 `libgtk-3.so.0` / `libwebkit2gtk-4.1.so.0` / `libayatana-appindicator3.so.1` / `libglib-2.0.so.0`，`mygo doctor` 输出里能 grep 到 `gtk` 与 `webkit`，并用 `go version -m` 校验 `github.com/egoist/mygo` 模块版本、用 `bun --version` 校验 bun 版本，且断言 `fnpack` / `wails3` / `wails` / `fyne` 都不存在。

任何一步失败都会停在原地：该镜像的 `latest` / `<major.minor>` 不会动。fnpack / wails3 / wails2 / fyne / mygo 的移动标签额外受基础镜像约束，不会跑到基础镜像前面。

## 镜像源差异

| 平台   | GitHub Release / nodejs.org      | fnpack                              | wails3                               |
|--------|----------------------------------|-------------------------------------|--------------------------------------|
| CNB    | `https://files.m.daocloud.io`    | `https://static2.fnnas.com`（直连） | 走基座的 GOPROXY（腾讯云）           |
| GitHub | 直连 `github.com` / `nodejs.org` | `https://static2.fnnas.com`（直连） | 走基座的 GOPROXY（proxy.golang.org） |

wails3 / wails2 / fyne / mygo 用 `go install` 装，和基座里的 Go 工具同一条路：CNB 侧基座 `Dockerfile.golang` 已把 `GOPROXY` 设成腾讯云，子镜像继承；GitHub / GitLab 侧用 Go 默认代理。版本解析也读同一个 `GOPROXY`，保证「解析到的版本」和「装成的版本」一致。fyne 的 apt 包（OpenGL/X11/Wayland）与 mygo 的 apt 包（GTK3/WebKitGTK 4.1 与无头运行库）同样继承基座的 APT 源，三个平台都不额外加开关；mygo 的 `bun` 走 `npm install -g`，用的也是基座的 npm 源（CNB 侧腾讯云、GitHub / GitLab 侧官方默认），版本解析（`npm view bun version`）与安装同一个源。
