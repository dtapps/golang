# 安全说明

本仓库是一个自建镜像仓库，目前包含六个镜像：

- `golang`：基于官方 `golang:1-trixie`（自动跟随最新稳定 Go），增加 UPX、nfpm、Node.js/pnpm 与常用 Go 工具。
- `golang/fnpack`：在上面的镜像上加一个 `fnpack` 二进制。
- `golang/wails3`：在上面的镜像上加 GTK4/WebKitGTK 6.0 开发包与 `wails3` CLI（`go install` 自源码构建）。
- `golang/wails2`：在上面的镜像上加 GTK3/WebKit2GTK 4.1 开发包与 `wails` CLI（`go install` 自源码构建）。
- `golang/fyne`：在上面的镜像上加 OpenGL/X11/Wayland 开发包与 `fyne` CLI（`go install` 自源码构建）。
- `golang/mygo`：在上面的镜像上加 GTK3/WebKitGTK 4.1 开发包、无头运行库（Xvfb + mesa + 字体）、`mygo` CLI（`go install` 自源码构建）与 `bun`（npm 包）。

六者都没有业务代码，也没有自研二进制（`wails3` / `wails` / `fyne` / `mygo` 由上游源码在本仓库构建时编译）。

## 支持范围

| 标签                            | 说明                                           |
|---------------------------------|------------------------------------------------|
| `<go 版本>`（如 `1.27.3`）      | 版本标签：每次构建推送，同名标签每天可能被覆盖 |
| `<major.minor>`（如 `1.27`）    | 该 minor 的最新一次成功构建                    |
| `latest`                        | 最近一次成功构建                               |
| `<go 版本>-linux-{amd64,arm64}` | 单平台标签，从同一份 manifest 派生             |

六个镜像的标签合同相同，但更新是分两步的：先构建并发布 `golang`，再以它为基座分别构建 `golang/fnpack`、`golang/wails3`、`golang/wails2`、`golang/fyne` 与 `golang/mygo`。五个变体的 `<major.minor>` / `latest` 只有在 `golang` 的同一标签已经指向本次版本时才会提升，因此不会出现「变体已更新、基座还是旧版」的错位。

固定产物请用 annotation 里的 digest，而不是标签：

```bash
docker pull ghcr.io/dtapps/golang@sha256:<golang_digest>
docker pull ghcr.io/dtapps/golang/fnpack@sha256:<fnpack_digest>
docker pull ghcr.io/dtapps/golang/wails3@sha256:<wails3_digest>
docker pull ghcr.io/dtapps/golang/wails2@sha256:<wails2_digest>
docker pull ghcr.io/dtapps/golang/fyne@sha256:<fyne_digest>
docker pull ghcr.io/dtapps/golang/mygo@sha256:<mygo_digest>
```

## 补丁节奏

- 每天自动重建一次，分六段：`golang`（CNB 00:05、GitHub 16:05 UTC）、`golang/fnpack`（CNB 03:05、GitHub 19:05 UTC）、`golang/wails3`（CNB 06:05、GitHub 22:05 UTC）、`golang/wails2`（CNB 09:05、GitHub 01:05 UTC）、`golang/fyne`（CNB 12:05、GitHub 04:05 UTC）与 `golang/mygo`（CNB 15:05、GitHub 07:05 UTC）各自按错开的定时任务构建。
- 每次重建都会重新拉取上游基座、重新下载/重新编译依赖，因此上游重新推送同一 tag 时的安全修复能进入镜像。
- Go 基座默认 `golang:1-trixie` 浮动标签，自动跟随最新稳定 Go（跨 minor 与大版本）；手动触发填 `version` 可钉住。
- 工具版本（UPX、nfpm、Node、pnpm、各 Go 工具）默认 `latest`，构建时自动解析最新版：UPX 取 GitHub `releases.atom` 的首个稳定 tag，Node 查官方 dist 索引，nfpm 与各 Go 工具走 `go install @latest`。wails3 同理：`WAILS3_VERSION` 默认 `latest`，CI 先用 `go list -m` 解析最新稳定 tag 再 `go install`。fyne 也是同一套路：`FYNE_VERSION` 默认 `latest`，CI 先用 `go list -m fyne.io/tools@latest` 解析最新稳定 tag 再 `go install`。mygo 同样：`MYGO_VERSION` 默认 `latest`，CI 先用 `go list -m github.com/egoist/mygo@latest` 解析再 `go install`；镜像里的 `bun` 走 `BUN_VERSION`，CI 用 `npm view bun version` 解析最新稳定版再 `npm install -g`。出现问题时可用 `--build-arg`（或改 Dockerfile 默认值）钉回具体版本。

## 信任面

| 来源                                      | 用途                                                                                              |
|-------------------------------------------|---------------------------------------------------------------------------------------------------|
| Docker Hub `golang:1-trixie`              | 基础镜像                                                                                          |
| `github.com` / `files.m.daocloud.io`      | 解析 UPX 最新版本号（`releases.atom`）与下载 GitHub Release                                       |
| `nodejs.org` / `files.m.daocloud.io`      | Node.js 官方 tar.xz 与版本索引（index.json）                                                      |
| `static2.fnnas.com`                       | fnpack 二进制                                                                                     |
| `github.com/wailsapp/wails`（经 GOPROXY） | wails3 CLI 源码（`go install`）                                                                   |
| `fyne.io/tools`（经 GOPROXY）             | fyne CLI 源码（`go install fyne.io/tools/cmd/fyne`）                                              |
| `github.com/egoist/mygo`（经 GOPROXY）    | mygo CLI 源码（`go install github.com/egoist/mygo/cmd/mygo`）                                     |
| npm `bun` 包（经 npm registry）           | mygo 镜像里的 `bun` 运行时（`npm install -g bun`）                                                |
| `mirrors.cloud.tencent.com`               | npm registry、Go module proxy（nfpm 与各 Go 工具、wails3、fyne、mygo、bun）；Debian APT 仅 CNB 侧 |
| `cnbcool/annotations:latest`              | 写 commit 元数据的 CI 插件                                                                        |

GitHub 侧直连官方站，APT 与 Go module 用默认源；CNB 侧的 GitHub Release / `releases.atom` 与 nodejs.org 走 DaoCloud 代理，APT 与 Go module 走腾讯云。代理站本身也是供应链的一部分。

## 可复现性

- 同一 digest = 同一份产物（按 `@sha256:...` 拉取）。
- 每次构建都能回查，元数据按镜像分开写：
  - `golang`：`.cnb/annotation.json` / `.github/annotation.json`，含 `golang_digest`、`base_image`、`base_digest`、`built_at`。
  - `golang/fnpack`：`.cnb/annotation-fnpack.json` / `.github/annotation-fnpack.json`，含 `fnpack_digest`、`fnpack_version`、`fnpack_base_image`、`fnpack_base_digest`、`built_at`。
  - `golang/wails3`：`.cnb/annotation-wails3.json` / `.github/annotation-wails3.json`，含 `wails3_digest`、`wails3_version`、`wails3_base_image`、`wails3_base_digest`、`built_at`。
  - `golang/wails2`：`.cnb/annotation-wails2.json` / `.github/annotation-wails2.json`，含 `wails2_digest`、`wails2_version`、`wails2_base_image`、`wails2_base_digest`、`built_at`。
  - `golang/fyne`：`.cnb/annotation-fyne.json` / `.github/annotation-fyne.json`，含 `fyne_digest`、`fyne_version`、`fyne_base_image`、`fyne_base_digest`、`built_at`。
  - `golang/mygo`：`.cnb/annotation-mygo.json` / `.github/annotation-mygo.json`，含 `mygo_digest`、`mygo_version`、`bun_version`、`mygo_base_image`、`mygo_base_digest`、`built_at`。
- 标签会随重建前移，不能作为固定点；也不承诺「同样的命令每次都产出相同的字节」。
- 构建启用 buildx 层缓存（`<镜像>:buildcache`），但缓存键跟着「解析出的工具版本 + 基座 digest」走：上游没发新版才命中，发新版或基座 digest 变化都会重建对应层。需要一次干净的全量重建时设 `CACHE=off`。

## 已知取舍

- **工具自动追最新**：默认 `latest` 意味着上游发版当天就进入镜像，且各 Go 工具的 major 升级虽被模块路径（`/v2`、`/v3`）天然隔离，minor 仍可能引入行为变化。冒烟测试只保证工具可执行、不保证行为不变；出问题按上面的说明钉回版本。
- **以 root 运行**：作为构建环境，不创建非 root 用户；生产运行镜像请自行降权。
- **镜像体积较大**：包含完整 Go 工具链、Node.js 与 Debian 构建依赖，换取「进容器即可构建」。没有按需拆分。
- **CI 插件未固定版本**：`imports` 指向组织仓库 `main`，`cnbcool/annotations` 用 `:latest`，这两处无法在本仓库内固定。发现行为变化时先看流水线日志。
- **fnpack 无签名校验**：直接下载官方站二进制并 `chmod +x`，未做 checksum/signature 校验；如需更强保证，请在 Dockerfile 里增加校验步骤。
- **`bun` 是 npm 包**：mygo 镜像通过 `npm install -g bun@<版本>` 安装，信任链与其它 npm 依赖相同（上游 `oven-sh/bun` 的 npm 发布物），同样不做 checksum/signature 校验。它只是 mygo 默认前端模板的构建工具，不需要时可以自建镜像时去掉。

## 报告漏洞

敏感问题请邮件联系维护者 `li.gc@icloud.com`（与 git 提交记录中的作者邮箱一致），标题前缀 `[security] dtapp/golang`。在修复发布前请不要公开细节。

如果是上游依赖（Go、Debian 包、Node、fnpack、wails3 / wails2 / fyne / mygo CLI、`bun` 等）的 CVE：

- 上游已修复：重新触发构建即可；
- 本镜像未跟上上游：开 issue 提醒，附上上游公告链接。
