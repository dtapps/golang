# go-gui-build：在 GitHub Actions 里构建 GUI 应用

> [`action.yml`](../action.yml)（仓库根目录）的使用文档： 一个 composite action，Linux runner 上复用本仓库的 GUI 变体镜像（`docker run`）， macOS / Windows 上走原生 runner（检查 Go + 安装 CLI），把 Go GUI 应用的构建与打包 编排成一条流水线，产物上传为 artifact。本页只讲怎么用：输入契约、命令解析、七个 framework 各自的完整示例，以及一份可直接抄的三平台 workflow。 镜像里装了什么见 [golang/dockerfile.md](golang/dockerfile.md)， 标签与 digest 见 [golang/images-and-tags.md](golang/images-and-tags.md)。

## 为什么有它

要解决的问题：CI 工作流里到处手写「装 wails3 / wails2 / fyne / gogio / mygo / fnpack」 ——每个应用仓库重复一遍，版本各不相同、装法各不相同，漂移了也看不出来。

- **Linux**：环境来自镜像，CLI（wails3 / wails / fyne / gogio / mygo / fnpack）已经装好， 工作流**零安装**，只执行构建命令。
- **macOS / Windows**：Docker 只能跑 Linux 容器，GitHub 的 windows / macos runner 起不了 这个镜像；也没有 macOS / Windows 版镜像，也不能用交叉编译代替（产物未签名、不可打包）。 所以原生上「装 CLI」省不掉——但由 action 用固定 pin 统一装，应用仓库的 workflow 仍然不用写安装步骤。
- 两条路径共用同一份 build 命令串和同一套产物上传规则，同一个应用在三平台的行为一致。

## 它做什么、不做什么

| 做                                                            | 不做                                                                                                |
|---------------------------------------------------------------|-----------------------------------------------------------------------------------------------------|
| 按 `framework` 选镜像变体、拼默认命令                         | 不安装任何系统依赖、不动软件源——依赖清单只存在于 Dockerfile；**也不装 Go**（有就用，缺失/太旧报错） |
| Linux：`docker run` 在变体镜像内构建                          | 不做「全 Linux 交叉编译发版」：交叉产出的 macOS 二进制未签名，不适合发布链路                        |
| macOS / Windows：原生执行**同一份**命令串，产物可签名、可打包 | 不处理 GHCR 登录（公开镜像无需登录；私有才由调用方登录）                                            |
| `package=true` 时把打包命令串进 build，产物按 `bin-dir` 上传  | 不做 macOS 公证 / Windows signtool（需要证书 secrets，调用方后续步骤）                              |
| 镜像引用支持 tag 与 digest                                    | 不做 docker-in-docker 交叉编译（`wails3 task setup:docker` / fyne-cross 是调用方扩展点）            |

只做这一个通用 action，不做七个、不造合并镜像；只服务 GitHub 侧（默认 ghcr.io）， CNB / GitLab 各自维护自己的调用胶水（见 [github.md](github.md) 的「三份独立实现」）。

## 快速开始：第三方应用仓库怎么用

这是给「别人」用的：action 在本仓库**根目录**（`action.yml`），你的应用仓库 **一行 `uses:` 直接引用**，不需要拷贝任何文件。引用名就是标准短名 `owner/repo@ref`（和 `actions/checkout@v4` 同一种形态）。本仓库是 Public， 任何人可引用。七个 framework 的可直接抄的示例文件在 [`.github/examples/go-gui-build/`](../../.github/examples/go-gui-build/)。

在**你的应用仓库**的 workflow 里：

```yaml
name: build
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: dtapps/golang@main          # 版本 tag 亦可
        with:
          framework: wails3
          image-tag: 'latest'             # latest 或 1.27.3 这类固定版本
          bin-dir: build/bin
```

四个容易搞混的点：

| 问题                   | 答案                                                                                                                             |
|------------------------|----------------------------------------------------------------------------------------------------------------------------------|
| 要 `docker login` 吗？ | **公开镜像不需要**。只有镜像仓库私有时才要（见「私有 GHCR」），并给 job 加 `permissions: packages: read`                         |
| 要 checkout 吗？       | 示例里没有：action 只负责构建，检出代码属于你的 workflow；从零写 workflow 时先加一步 `actions/checkout`                          |
| `uses:` 指向谁？       | 指向**本仓库**（`dtapps/golang`）。`uses: ./` 只在本仓库内自测时用；拷到你的仓库后必须换成 `dtapps/golang@main`（版本 tag 亦可） |
| 版本能写 `latest` 吗？ | 镜像 tag 可以（`image-tag: latest`）；**action 的 git ref 不能**（仓库没有 `latest` 分支/tag），用 `main` / 版本 tag             |

### `@` 后面填什么（ref）

| ref                                 | 适用             | 说明                                       |
|-------------------------------------|------------------|--------------------------------------------|
| `main`                              | 尝鲜 / 内部      | 跟随仓库最新，不用打标签就能用             |
| `go-gui-build-v1`（版本 tag，推荐） | 生产             | 发版式引用，升级时改版本号；打标签后即可用 |
| commit SHA                          | 生产（严格复现） | 钉死唯一提交，升级需手动换 SHA             |

给本仓库打标签（发布 action 版本）：

```sh
git tag go-gui-build-v1
git push origin go-gui-build-v1
```

（git 命令请自行执行。）action 的 ref 与 `image-tag` 建议同一批一起升级， 避免两套版本各自漂移。

## 输入

必填：

| 输入        | 说明                                                                                                                                   |
|-------------|----------------------------------------------------------------------------------------------------------------------------------------|
| `framework` | 镜像变体与默认命令选择器：`wails3` \| `wails2` \| `fyne` \| `gio` \| `golang` \| `fnpack` \| `mygo`。不在枚举内打印 `::error::` 并退出 |

选填：

| 输入                | 默认                    | 说明                                                                                                                                                                                               |
|---------------------|-------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `image-tag`         | `latest`                | 镜像标签（如 `1.27.3` / `1.27` / `latest`；也接受 digest）：仅**构建模式**的 Linux 分支用，setup-only 不需要                                                                                       |
| `image-registry`    | `ghcr.io/dtapps/golang` | 镜像仓库根命名空间；变体路径由 framework 派生（见「镜像引用」）                                                                                                                                    |
| `working-directory` | `.`                     | `go.mod` / `Taskfile.yml` 所在目录，相对仓库根；绝对路径直接报错                                                                                                                                   |
| `build-command`     | 空                      | 覆盖默认 build 命令（多条命令可 `&&` 串联）                                                                                                                                                        |
| `install-command`   | 空                      | **覆盖**默认 CLI 安装命令；仅原生分支执行                                                                                                                                                          |
| `tools`             | 空                      | 额外工具，逗号分隔的**枚举**：`task`（go-task，走通用安装器 `scripts/install-tool.sh`：二进制优先、`go install` 兜底）、`nsis`（仅 Windows，执行 `scripts/install-nsis.ps1`）；七个 framework 通用 |
| `nsis-version`      | `latest`                | NSIS 版本（`tools` 含 `nsis` 时使用，仅 Windows）：`latest` 用 SourceForge RSS 解析最新（约 1 秒），解析失败回退 `3.13`                                                                            |
| `cache`             | `false`                 | 是否缓存已装的二进制：CLI（framework + `tools`）与 Windows 的 NSIS；开启后第二次起跳过安装 / 下载，默认关闭                                                                                        |
| `package-command`   | 空                      | 覆盖默认打包命令                                                                                                                                                                                   |
| `package`           | `false`                 | 是否追加打包命令（`true` / `false`，其他值报错）                                                                                                                                                   |
| `setup-only`        | `false`                 | 只装环境不构建：所有平台 `go install` CLI 并导出 `PATH` 给后续步骤，**不需要 Docker**；Linux 需自备 GUI 系统库                                                                                     |
| `bin-dir`           | `bin`                   | 产物目录（相对 `working-directory`），随 artifact 上传                                                                                                                                             |
| `artifact-name`     | 空                      | artifact 名称；留空 = `<framework>-<OS>`（如 `wails3-Linux`、`wails3-macOS`）                                                                                                                      |
| `native-shell`      | `bash`                  | 原生分支 run 步骤的 shell；Windows 上命令需要 PowerShell 时设 `pwsh`                                                                                                                               |
| `container-shell`   | `/bin/bash -lc`         | Linux 容器内执行命令的 shell（含参数）；alpine 系传 `/bin/sh -c`，镜像有自定义 ENTRYPOINT 时按需调整                                                                                               |

## 命令解析

action 第一步按 framework 生成三组命令，**Linux 与原生分支共用同一份解析结果**， case 不写两遍：

| framework        | build            | install（仅原生执行）                                     | package          |
|------------------|------------------|-----------------------------------------------------------|------------------|
| `wails3`         | `wails3 build`   | `go install …/v3/cmd/wails3@<pin>`                        | `wails3 package` |
| `wails2`         | `wails build`    | `go install github.com/wailsapp/wails/v2/cmd/wails@<pin>` | `wails package`  |
| `fyne`           | `go build ./...` | `go install fyne.io/tools/cmd/fyne@<pin>`                 | `fyne package`   |
| `mygo`           | `go build ./...` | `go install github.com/egoist/mygo/cmd/mygo@<pin>`        | 空               |
| `fnpack`         | `go build ./...` | 下载官方二进制（linux / darwin / windows）                | 空               |
| `gio` / `golang` | `go build ./...` | 空                                                        | 空               |

覆盖与追加规则：

1. 三个 `*-command` 输入**非空时**覆盖对应默认值；
2. `tools` 是**枚举**（逗号分隔，支持 `task` / `nsis`）：`task` 走通用安装器 `scripts/install-tool.sh <tool> <pin>`（**先下载官方预编译二进制，失败才 `go install`**；追加在默认安装之后，Linux 容器构建时通过只读挂载在容器内先执行）；`nsis` 走 `scripts/install-nsis.ps1`（专用 Windows 步骤 `Install NSIS`，非 Windows 只打 warning）；非法值报 `::error::`；新增工具只需在 `install-tool.sh` 的工具表里加一段；
3. `package=true` 且 package 命令非空时，把 build 与 package 用 `&&` 串成一条命令执行；
4. `package=true` 但无 package 命令（如 `golang`）：跳过打包并打 `::notice::`。

默认假设镜像里已装好对应 CLI（这是镜像的职责）。镜像缺 CLI 时：Linux 侧把 `go install …` 串进 `build-command`，或在镜像侧补齐；原生侧用 `install-command`。

### CLI 版本 pin 点

默认全部跟 `latest`；要可复现就在 workflow 用同名 env 钉具体 tag（如 job 级 `env: WAILS3_CLI_PIN: v3.1.0`）：

| 变量             | 默认     | 说明                                    |
|------------------|----------|-----------------------------------------|
| `WAILS3_CLI_PIN` | `latest` | wails3 CLI                              |
| `WAILS2_CLI_PIN` | `latest` | wails2 CLI                              |
| `FYNE_CLI_PIN`   | `latest` | fyne CLI（`fyne.io/tools/cmd/fyne`）    |
| `MYGO_CLI_PIN`   | `latest` | mygo CLI                                |
| `TASK_CLI_PIN`   | `latest` | `tools: task` 时安装的 go-task          |
| `FNPACK_CLI_PIN` | `1.2.3`  | **例外**：官方下载 URL 必须带具体版本号 |

有 `latest` 时缓存键按 ISO 周换，所以不会被缓存永远冻在第一次装到的版本上。

> fyne 的 install 走 `fyne.io/tools/cmd/fyne`：旧路径 `fyne.io/fyne/v2/cmd/fyne` 已迁出，只剩弃用提示桩，装出来执行不了 `fyne package`。与镜像 `Dockerfile.fyne` 保持一致。

## 七个 framework 怎么用

七个变体 = `golang` 基座 + `fnpack` / `wails3` / `wails2` / `fyne` / `mygo` / `gio` 六个变体。`uses:` 和参数结构完全一样，只换 `framework`（和构建模式的命令覆盖 / `bin-dir`）； `uses` 里的 `@main` 是 git ref（版本 tag 亦可）。

两种用法：

- **setup-only（示例默认）**：只装 CLI，后续步骤自己跑命令，不需要 Docker；
- **构建模式（不传 setup-only）**：action 内构建 / 打包 / 上传，命令默认值见下表。

| framework | 镜像变体  | 构建模式默认命令                                                    | `bin-dir`   |
|-----------|-----------|---------------------------------------------------------------------|-------------|
| `golang`  | 根镜像    | `go build ./...` 不落盘 → `go build -o bin/app ./cmd/app`           | `bin`       |
| `fnpack`  | `/fnpack` | 同上落盘到 `dist`；打 `.fpk` 用 `fnpack build` 覆盖 package         | `dist`      |
| `wails3`  | `/wails3` | `wails3 build` / `wails3 package` 直接用                            | `build/bin` |
| `wails2`  | `/wails2` | `wails build` / `wails package` 直接用（可选 `-tags`）              | `build/bin` |
| `fyne`    | `/fyne`   | `go build ./...` 不落盘 → `go build -o bin/app ...`；`fyne package` | `bin`       |
| `gio`     | `/gio`    | `go build ./...` 不落盘 → `go build -o bin/app .`                   | `bin`       |
| `mygo`    | `/mygo`   | `go build ./...` 只做编译检查 → `mygo build`                        | 按项目      |

> 构建模式下有个共通的坑：默认 `go build ./...` 只做编译检查、不产出文件，而上传步骤是 `if-no-files-found: error`——这类 framework 必须用 `build-command` 带 `-o` 落盘， 或把 `bin-dir` 指向项目已有的产物目录。

### golang（基座镜像）

- 镜像：`ghcr.io/dtapps/golang`（根镜像，不带变体后缀）；setup-only 不拉镜像
- setup-only：只装 Go，后续自己 `go build`
- 构建模式：默认 `go build ./...` 不落盘，要用 `-o` 指定产物再配 `bin-dir` 上传
- 完整示例：[golang.yml](../../.github/examples/go-gui-build/golang.yml)

```yaml
- name: 准备环境
  uses: dtapps/golang@main
  with:
    framework: golang
    setup-only: true
- name: 构建
  run: go build -o bin/app ./cmd/app
```

### fnpack（打 .fpk）

- 镜像：`ghcr.io/dtapps/golang/fnpack`
- setup-only：下载官方二进制（linux / darwin / windows，amd64 + arm64）并导出 PATH； 地址规则见 [fnpack 官方文档](https://developer.fnnas.com/docs/cli/fnpack/)
- 构建模式：Linux 镜像里编译 + `fnpack build` 打包，产物在 `dist/`
- `.fpk` 由 `fnpack build` 读项目里的打包清单产出（清单格式以 fnpack 官方文档为准）， 惯例和二进制一起放 `dist/`（见 [fnpack/getting-started.md](fnpack/getting-started.md)）
- Windows 上二进制保存为 `fnpack.exe`（官方 URL 没有 `.exe` 后缀）
- 完整示例：[fnpack.yml](../../.github/examples/go-gui-build/fnpack.yml)

```yaml
- name: 准备环境
  uses: dtapps/golang@main
  with:
    framework: fnpack
    setup-only: true
- name: 构建并打包
  run: |
    go build -trimpath -ldflags="-s -w" -o dist/app .
    fnpack build
```

### wails3

- 镜像：`ghcr.io/dtapps/golang/wails3`（GTK4 / WebKitGTK 6.0 + `wails3` CLI）
- setup-only：装 `wails3`（pin `WAILS3_CLI_PIN`）
- 构建走 Taskfile，官方两个入口：`wails3 task <name>`（CLI 内嵌 runner）或裸 `task <name>`。Linux 镜像已自带 go-task；macOS / Windows 想用裸入口就传 `tools: task`（任何 framework 都适用，版本由 `TASK_CLI_PIN` 控制）
- 后续自己 `wails3 build` / `wails3 package`，或 `task build` / `task dev` 等 Taskfile 任务
- 构建模式：默认命令同上，产物在 `build/bin`，tag 时 `package=true`
- 完整示例：[wails3.yml](../../.github/examples/go-gui-build/wails3.yml)

```yaml
- name: 准备环境
  uses: dtapps/golang@main
  with:
    framework: wails3
    setup-only: true
- name: 构建并打包
  run: |
    wails3 build
    wails3 package
```

### wails2

- 镜像：`ghcr.io/dtapps/golang/wails2`（GTK3 / WebKit2GTK 4.1 + `wails` CLI）
- setup-only：装 `wails`（pin `WAILS2_CLI_PIN`），后续自己 `wails build` / `wails package`
- 走 GTK3 旧路径时 `-tags webkit2_41` 必须显式写进命令（wails 会转成 EXTRA_TAGS 传给底层 Taskfile；action 不猜 tag）
- 完整示例：[wails2.yml](../../.github/examples/go-gui-build/wails2.yml)

```yaml
- name: 准备环境
  uses: dtapps/golang@main
  with:
    framework: wails2
    setup-only: true
- name: 构建并打包
  run: |
    wails build
    wails package
```

### fyne

- 镜像：`ghcr.io/dtapps/golang/fyne`（OpenGL / X11 / Wayland + `fyne` CLI）
- setup-only：装 `fyne`（pin `FYNE_CLI_PIN`），后续自己 `go build` / `fyne package`
- 构建模式：默认 `go build ./...`（不落盘）+ `fyne package`；`fyne package` 的产物 （`.tar.xz` / `.app` / `.exe`）落在 working-directory 根，要进 artifact 就在 `package-command` 里指定输出
- 完整示例：[fyne.yml](../../.github/examples/go-gui-build/fyne.yml)

```yaml
- name: 准备环境
  uses: dtapps/golang@main
  with:
    framework: fyne
    setup-only: true
- name: 构建并打包
  run: |
    go build -o bin/app ./cmd/app
    fyne package
```

### gio

- 镜像：`ghcr.io/dtapps/golang/gio`（EGL/GLES、X11、Wayland、Vulkan 开发包 + `gogio`）
- setup-only：装 Go（gio 没有需要安装的 CLI），后续自己 `go build`
- Linux 桌面程序就是普通 `go build` + cgo；`gogio` 是打包工具，**没有 linux 目标**， 跨平台打包要额外 SDK（不在镜像范围内）
- 构建模式：默认 `go build ./...` 不落盘 → 用 `-o`
- 完整示例：[gio.yml](../../.github/examples/go-gui-build/gio.yml)

```yaml
- name: 准备环境
  uses: dtapps/golang@main
  with:
    framework: gio
    setup-only: true
- name: 构建
  run: go build -o bin/app .
```

### mygo

- 镜像：`ghcr.io/dtapps/golang/mygo`（GTK3 / WebKitGTK 4.1 + `mygo` CLI + `bun`）
- setup-only：装 `mygo`（pin `MYGO_CLI_PIN`），后续自己 `mygo build`
- 构建模式：默认 `go build ./...` 只做编译检查，真正构建用 `build-command: mygo build`； 产物目录以 mygo 项目约定为准，用 `bin-dir` 对准
- 完整示例：[mygo.yml](../../.github/examples/go-gui-build/mygo.yml)

```yaml
- name: 准备环境
  uses: dtapps/golang@main
  with:
    framework: mygo
    setup-only: true
- name: 构建
  run: mygo build
```

## 执行流程

| 步骤                | Linux（`runner.os == 'Linux'`）                                                                                                                                        | macOS / Windows（`runner.os != 'Linux'`）                                                                                                                                                                                                                                                                                                                                                                                                         |
|---------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 1. Resolve commands | 解析 framework → build / install / package + 镜像仓库引用                                                                                                              | 同左                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| 2. 容器构建         | `docker run --rm`：`$GITHUB_WORKSPACE` 挂到 `/workspace`，`-w` = `/workspace` + working-directory，`-e CGO_ENABLED=1`，`--entrypoint` 覆盖镜像 ENTRYPOINT 后执行命令串 | —                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| 3. 原生构建         | —                                                                                                                                                                      | `Check Go`（有 Go 就继续，没有直接报错；**不安装、不校验版本**）→ `Cache CLI binaries`（`cache=true` 才跑）→ install 非空且缓存未命中才跑 → `Export CLI path` → `Cache NSIS`（仅 Windows、`tools` 含 `nsis`、`cache=true`）→ `Install NSIS`（同上条件，命中缓存则跳过下载，脚本 `scripts/install-nsis.ps1`）→ `Print CLI versions`（把实际版本打进日志）→ 在 working-directory 下执行同一份 build 命令串（shell = native-shell，`CGO_ENABLED=1`） |
| 4. artifact 计算    | 名称 = `artifact-name` 或 `<framework>-<OS>`                                                                                                                           | 同左                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| 5. 上传产物         | `actions/upload-artifact`：path = working-directory/bin-dir，`if-no-files-found: error`                                                                                | 同左                                                                                                                                                                                                                                                                                                                                                                                                                                              |

实现细节：

- Linux 用 `run: docker run`，**不是** `uses:` 直接引用镜像——后者不支持表达式拼动态 image tag，而 tag/digest 必须由输入传入。
- 容器内工作目录按 working-directory 拼接（`app` → `/workspace/app`，`.` → `/workspace`），不硬写 `/workspace`。
- `container-shell` 按空白拆 argv：首词是可执行文件、其余是参数、最后追加命令串。 例：`/bin/bash -lc` → `bash -lc '<命令>'`；自定义 ENTRYPOINT（如 tini）可传 `tini -- /bin/bash -lc`。
- Linux 分支不跑 install：环境（含 CLI 预装）是镜像的职责。

### CLI 的作用域

- **默认（构建模式）**：Linux 的 CLI 只在 action 内部那次一次性 `docker run` 里， action 结束后后续步骤没有这些命令；macOS / Windows 装在 runner 上，后续步骤可用。
- **`setup-only: true`**：所有平台都安装 CLI（`go install` 或下载官方二进制）并把 `$(go env GOPATH)/bin` 写进 `PATH`，**不跑 Docker**——后续步骤可以直接用（见下一节）。

默认构建模式下要在别的步骤用 CLI：写进 `build-command` / `package-command`， 或者自己 `docker run` 同一镜像。

### 像 setup-go 一样用（`setup-only`）

不需要 Docker：`setup-only: true` 只做「装 CLI + 导出 PATH」，不构建、不上传：

```yaml
steps:
  - name: 准备环境
    uses: dtapps/golang@main
    with:
      framework: wails3
      setup-only: true
  - name: 使用
    run: |
      wails3 build
      wails3 package
```

三个平台行为一致。**Linux 要注意系统库**：runner 上没有镜像里的 GTK/WebKit 开发包， `setup-only` 只装 CLI，wails / fyne 的**编译**仍然需要这些库——要么 runner 自带、 自己装，要么回到镜像跑构建。纯 Go 的 framework 不受影响。

示例文件：见下方「示例 workflow 文件」。

### 速度：哪些能省、哪些省不了

| 场景                        | 耗时大头                    | action 的处理                                                    |
|-----------------------------|-----------------------------|------------------------------------------------------------------|
| setup-only（三平台）        | 编译 CLI（几十秒 ~ 2 分钟） | 缓存 `~/go/bin`，键 = `framework + 全部 CLI pin`；命中就跳过安装 |
| 构建模式（macOS / Windows） | 同上 + 编译应用             | 同上                                                             |
| 构建模式（Linux）           | 拉镜像（几十秒 ~ 几分钟）   | 镜像无法跨 runner 缓存；但省掉了装系统库的时间                   |

- 缓存默认**关闭**（`cache: false`），需要加速重复构建时显式开 `cache: true`；
- 开启后缓存两类东西：`$(go env GOPATH)/bin`（framework CLI + `tools` 二进制，键 = 各 pin + tools + 周戳）与 Windows 的 NSIS 解压目录（键 = `nsis-version`，`latest` 时带周戳）；
- 开启后：改任一 CLI pin 或 `tools` 都会换缓存键，自动重新安装；
- 开启后：默认 `latest` 时缓存键带 ISO 周戳（如 `-2026-46`），每周自动刷新一次，不会永远用第一次装到的版本；全部 pin 成具体 tag 后周戳消失；
- 原生分支装完会打一段 `--- 工具版本 ---`（framework CLI + `tools` + `go` 的实际版本），用来核对 pin 与缓存内容；
- `FYNE_CLI_PIN=latest` 这类键不变，会一直复用首次装好的二进制，要升级就改 pin；
- 缓存按 `runner.os` + `runner.arch` 隔离；
- `Check Go` 只检查有没有 Go：有就继续，没有直接报错（Go 由调用方负责，比如先跑 `actions/setup-go`），不校验版本。

## 镜像引用

`image-registry` 是仓库根命名空间，变体路径由 framework 派生：

| framework | 镜像                                |
|-----------|-------------------------------------|
| `golang`  | `ghcr.io/dtapps/golang`（根镜像）   |
| 其余六个  | `ghcr.io/dtapps/golang/<framework>` |

`image-tag` 传标签（如 `1.27.3`）时拼 `:tag`；也可以直接传 digest。 `latest` / `<major.minor>` 这类可变标签会随标签提升漂移，要严格复现时再用 digest； 标签契约见 [golang/images-and-tags.md](golang/images-and-tags.md)。

## 示例 workflow 文件

七个 framework 各有一份完整、可直接抄的 workflow，放在 [`.github/examples/go-gui-build/`](../../.github/examples/go-gui-build/)（文件名 = framework）：

| 示例文件                                                     | framework | 模式       | 后续步骤                          |
|--------------------------------------------------------------|-----------|------------|-----------------------------------|
| [golang.yml](../../.github/examples/go-gui-build/golang.yml) | `golang`  | setup-only | `go build -o bin/app ./cmd/app`   |
| [fnpack.yml](../../.github/examples/go-gui-build/fnpack.yml) | `fnpack`  | setup-only | `go build …` + `fnpack build`     |
| [wails3.yml](../../.github/examples/go-gui-build/wails3.yml) | `wails3`  | setup-only | `wails3 build` / `wails3 package` |
| [wails2.yml](../../.github/examples/go-gui-build/wails2.yml) | `wails2`  | setup-only | `wails build` / `wails package`   |
| [fyne.yml](../../.github/examples/go-gui-build/fyne.yml)     | `fyne`    | setup-only | `go build …` / `fyne package`     |
| [gio.yml](../../.github/examples/go-gui-build/gio.yml)       | `gio`     | setup-only | `go build -o bin/app .`           |
| [mygo.yml](../../.github/examples/go-gui-build/mygo.yml)     | `mygo`    | setup-only | `mygo build`                      |

每个文件的公共结构：

- 七个示例统一是两个 step：**准备环境**（`setup-only: true`，装 CLI）→ **使用**（`run:` 自己跑构建 / 打包），**不需要 Docker**；
- `fnpack` 从官方地址下载二进制（linux / darwin / windows 都有），不走 `go install`；
- Linux 需要自备 GUI 系统库（GTK / WebKit / GL），action 会在 Linux 上打 warning；
- 在本仓库自测时把 `uses: dtapps/golang@main` 换成 `uses: ./`。

## 边界与注意

- **登录**：镜像公开时**不需要** `docker login`；只有私有 GHCR 才要先 `docker login`（`GITHUB_TOKEN`）并给 job 加 `permissions: packages: read`。action 内部不处理登录。
- **产物目录**：上传用 `if-no-files-found: error`。默认命令不产出文件时（`go build ./...` 只做编译检查），用 `build-command` 写进 bin-dir（如 `go build -o bin/ ./cmd/...`），或调整 `bin-dir`。
- **wails 系产物**：wails2 / wails3 的产物在 `build/bin`（Taskfile 约定，以应用仓库为准），调用时把 `bin-dir` 设为 `build/bin`。`fyne package` 的产物在工作目录根，需要时用 `package-command` 指定输出或打包后自行移动。
- **build tag**：wails2 的 `-tags webkit2_41`（GTK3/WebKit2GTK 4.1 旧路径）之类必须显式写进 `build-command`（wails 会转成 EXTRA_TAGS 传给底层 Taskfile）；action 不隐式猜 tag。
- **working-directory**：必须相对仓库根（`.`、`app`、`./app` 均可），绝对路径报错。
- **签名与公证**：macOS 公证 / Windows signtool 需要证书 secrets，作为调用方在本 action 之后的步骤。
- **交叉编译**：`wails3 task setup:docker` / fyne-cross 需要 docker-in-docker，action 不启用、不假设容器内有 docker，需要时在调用方 job 自行编排。
- **Go 由调用方负责**：action 不装 Go、不校验版本；有 Go 就用，没有直接报错。托管 runner 自带 Go，自托管 runner 记得先 `actions/setup-go`。
- **额外工具（如 `task`）**：Linux 镜像已自带 go-task，容器内直接 `task <name>` 即可；macOS / Windows（没有镜像）或 setup-only 场景想用裸 `task`，传 `tools: task`（版本由 `TASK_CLI_PIN` 控制）。

## 事实来源

- action 实现：`action.yml`（仓库根目录）
- 示例 workflow：`.github/examples/go-gui-build/{golang,fnpack,wails3,wails2,fyne,gio,mygo}.yml`
- 通用工具安装器：`scripts/install-tool.sh`（`tools: task` 等；内置工具表，二进制优先 + `go install` 兜底，新增工具在表里加一段）
- NSIS 安装脚本：`scripts/install-nsis.ps1`（`tools: nsis`，仅 Windows）
- 镜像内容与标签：`.github/docker/Dockerfile.*`、`.github/scripts/build-*.sh`（见 [golang/images-and-tags.md](golang/images-and-tags.md)）
- 文档与脚本冲突时，以脚本和 Dockerfile 为准，并回头修文档（见 [文档索引](README.md)）。
