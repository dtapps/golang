# 排错

## 先定位是哪一步

七条流水线各自输出：

```text
golang：解析基座 → 解析工具版本 → 登录 → buildx 自检 → 构建 golang
       → 派生单平台标签 → 冒烟 golang → 提升标签 → 元数据

fnpack：解析版本 → 登录 → buildx 自检 → 等待基础镜像 → 构建 fnpack
       → 派生单平台标签 → 冒烟 fnpack → 提升标签 → 元数据

wails3：解析版本（含 wails3 版本）→ 登录 → buildx 自检 → 等待基础镜像 → 构建 wails3
       → 派生单平台标签 → 冒烟 wails3 → 提升标签 → 元数据

wails2：解析版本（含 wails2 版本）→ 登录 → buildx 自检 → 等待基础镜像 → 构建 wails2
       → 派生单平台标签 → 冒烟 wails2 → 提升标签 → 元数据

fyne：解析版本（含 fyne 版本）→ 登录 → buildx 自检 → 等待基础镜像 → 构建 fyne
     → 派生单平台标签 → 冒烟 fyne → 提升标签 → 元数据

mygo：解析版本（含 mygo 版本与 bun 版本）→ 登录 → buildx 自检 → 等待基础镜像 → 构建 mygo
     → 派生单平台标签 → 冒烟 mygo → 提升标签 → 元数据

gio：解析版本（含 gogio CLI 版本与 gioui.org 库版本）→ 登录 → buildx 自检 → 等待基础镜像 → 构建 gio
    → 派生单平台标签 → 冒烟 gio → 提升标签 → 元数据
```

日志里最后一次出现的「构建 …」「等待 …」或「冒烟测试 …」就是失败点。变体作业失败时先确认对应版本的 golang 作业是否成功。

## 常见症状

### `exec format error`（arm64 阶段）

原因：在 amd64 runner 上构建 arm64，没有 QEMU/binfmt。

- GitHub：确认 workflow 里有 `docker/setup-qemu-action@v3`（`platforms: arm64`）。
- GitLab：确认 `.gitlab-ci.yml` 的 `before_script` 里，`tonistiigi/binfmt --install amd64,arm64` 没有失败，且 runner 允许 privileged 容器。
- CNB：确认 `services: docker` 已启用；CNB 的 docker 服务自带多架构支持。

### `no space left on device`

基础镜像与多架构构建缓存较大。GitHub 侧已有「释放磁盘空间」步骤；GitLab 侧的 dind 与 buildx 缓存都在 runner 自己的磁盘上，更容易满。如果仍然不够：

- 确认 GitHub 的「释放磁盘空间」步骤没有删错目录；
- 不要在同一个 runner 上同时跑其他重构建；
- GitLab 侧给 runner 留足磁盘，或把七个镜像拆到不同 runner / schedule；
- 本地构建时先 `docker buildx prune -af`。

### 容器内时间不是北京时间

症状：`date +%z` 不是 `+0800`，冒烟报 `tz(...)` 失败。

- 确认 `Dockerfile.golang` 里两处都在：`ENV TZ=Asia/Shanghai` 与 apt 段的 `tzdata` + `ln -snf /usr/share/zoneinfo/$TZ /etc/localtime`。
- 只改 `TZ` 不够：`/etc/localtime` 决定没有 `TZ` 时的默认时区，两者要一致（Dockerfile 里就是一起设的）。
- 自己 `FROM` 本镜像时如果覆盖了 `TZ`，记得同样重建 `/etc/localtime`；挂载宿主 `/etc/localtime` 则以挂载为准。
- 二进制/日志里的时间是构建时写入的，改了时区只影响之后新构建的产物。

### 工具版本没跟着升级

症状：上游发了新版，镜像里的工具还是旧版本。

1. 先看构建日志里的「工具版本解析结果」，确认解析到的是不是新版本；解析失败会打警告并回退 `latest`。
2. 解析到的版本没变：上游索引（Go proxy / npm / GitHub Release）还没同步，等下一次定时任务。
3. 版本变了但层没重建：`CACHE=off` 跑一次全量重建；仍然不对就检查 `--build-arg` 是否真的传进了 Dockerfile。

### 带缓存的构建失败 / 多出一个 `buildcache` 标签

- 缓存写到 `<镜像>:buildcache`，仓库页面多出这个标签属正常现象。
- 有的 registry 不接受 buildx 的缓存清单（未知 media type / 权限），而缓存导出发生在镜像推完之后，会表现为「构建成功但步骤失败」。脚本会自动去掉缓存重试一次，日志里会先出现「带缓存的构建失败」警告。
- 想长期不用缓存：设 `CACHE=off`。

### 派生标签报 `unexpected EOF`

症状：`--push` 已经成功，紧接着出现

```text
[internal] pushing ... copying sha256:... ... unexpected EOF
错误: 派生 <版本>-linux-amd64 失败
```

之后的冒烟、`latest` / `<major.minor>` 提升都没执行。

原因：CNB 制品库不支持把镜像清单当 blob 读；`imagetools create` 在同仓库打标签时仍要走 blob copy，`copy sha256:... unexpected EOF` 在 `0.000s` 稳定复现，与基座几点构建、七条定时任务错开多久都无关。**重试无效**（3 次全挂已实测）。

处置：

- CNB 侧三份脚本改用 Registry V2 API：`registry_auth()` 复用 `docker login` 凭证换 Bearer token，`put_manifest()` 把源清单 `GET` 下来、原文 `PUT` 到新 tag。层 blob 本就在同一仓库，全程不触发复制，digest 不变；PUT 后校验 `Docker-Content-Digest`，不一致即失败。
- 派生标签因此是单平台 manifest 原文（不再是包一层的 OCI index），`docker pull --platform` 行为不变。
- GitHub / GitLab 侧的 GHCR / GitLab Registry 无此限制，保留 `create_tag_with_retry` 兜瞬时抖动；CNB 侧实现不同、标签结果一致，别把 CNB 侧改回 `imagetools create`。
- 提升标签前读基座 digest 也加了 3 次重试 + 告警，避免读失败被当成「基座未对齐」静默跳过。
- 排障：`docker buildx imagetools inspect <镜像>:<版本>` 与 `...:<版本>-linux-amd64`；PUT 失败时日志会打印源引用与 `Content-Type`。

### 下载 404（UPX / nfpm / Node.js）

1. 确认版本号 ARG 对应的文件确实存在。
2. 用 [mirrors.md](mirrors.md) 的 `curl -sI` 验证原站与镜像站。
3. CNB 上如果原站可访问、DaoCloud 404，可能是代理尚未同步；临时改成直连验证。
4. 三侧 Dockerfile 的版本 ARG 必须同步。

### fnpack / wails3 / wails2 / fyne / mygo / gio 找不到基础镜像

症状：`基础镜像 <registry>/<repo>:<go 版本> 不存在`。

- 变体镜像必须 `FROM` 同版本的 golang 基础镜像，不会自己安装工具链。
- CNB：确认 00:05 的 `build-golang` 定时任务成功；03:05 的 fnpack、06:05 的 wails3、09:05 的 wails2、12:05 的 fyne、15:05 的 mygo、18:05 的 gio 才有基础可用。
- GitHub：确认 16:05 UTC 的 `build-golang` 定时任务成功；19:05 UTC 的 fnpack、22:05 UTC 的 wails3、01:05 UTC 的 wails2、04:05 UTC 的 fyne、07:05 UTC 的 mygo、10:05 UTC 的 gio 才有基础可用。手动触发前先跑一次 build-golang。
- GitLab：确认 `TARGET=golang` 的 schedule 或手动流水线成功；其余六个 `TARGET` 的 schedule 才有基础可用。手动触发变体前先跑一次 `TARGET=golang`。
- 刚推完基础镜像就手动跑变体时，脚本会最多等 5 分钟，仍然失败说明基础镜像确实没推上去。

### wails3 冒烟报 `pkg:gtk4` / `pkg:webkitgtk-6.0`

- 说明镜像里 `pkg-config --exists gtk4` 或 `webkitgtk-6.0` 失败。先看 Dockerfile 的 apt 那层日志：装包成功时同一层就会断言，失败会直接停在那里。
- 本地验证：`docker run --rm golang-wails3:local sh -c 'pkg-config --list-all | grep -E "gtk4|webkitgtk"'`。
- 上层镜像如果自己 `purge` 掉了 `libgtk-4-dev` / `libwebkitgtk-6.0-dev`，也会命中这个断言。

### wails3 版本回退成 `latest`

症状：日志里出现「无法解析 wails3 最新版本…回退 latest」，元数据 `wails3_version` 是 `latest`。

- 解析用 `go list -m github.com/wailsapp/wails/v3@latest`，走基座 Dockerfile 的 `GOPROXY`。CNB 侧按腾讯 → goproxy.cn → goproxy.io → direct 依次回退，主源 5xx / 超时会自动换源；GitHub / GitLab 侧走 `proxy.golang.org`，网络不通时同样会失败。只有全部源都失败才需等下一次定时任务，或手动触发并显式填 `wails3_version`。
- 回退不会阻断构建，但层缓存会失效（缓存键永远等于 `latest`），且冒烟只验证 `wails3` 可执行、不比对版本。

### wails3 冒烟报 `wails3-version(...)`

冒烟用 `go version -m <wails3 二进制>` 读内嵌模块版本，与本次目标版本不一致时报这个。常见原因：

- `go install` 装成了别的版本：检查 `--build-arg WAILS3_VERSION` 与日志里的「wails3_version …」是否一致；
- 手动填了预发布 tag（如 `v3.0.0-beta.34`），但 GOPROXY 上没有对应版本、`go install` 落到了别的 tag：本地用相同 `GOPROXY` 复现 `go install ...@<tag>`；
- 想放宽断言时改三份 `build-wails3.sh` 的冒烟段，别只改一侧。

### fyne 冒烟报 `pkg:gl` / `pkg:x11` / `pkg:wayland-client` 等

- 说明镜像里对应的 `.pc` 文件解析失败。先看 Dockerfile 的 apt 那层日志：装包成功时同一层就会断言 `gl` / `x11` / `xrandr` / `xcursor` / `xinerama` / `xi` / `xxf86vm` / `wayland-client` / `xkbcommon`，失败会直接停在那里。
- 本地验证：`docker run --rm golang-fyne:local sh -c 'pkg-config --list-all | grep -E "gl|x11|wayland|xkbcommon"'`。
- 上层镜像如果自己 `purge` 掉了 `libgl1-mesa-dev` / `xorg-dev` / `libwayland-dev` / `libxkbcommon-dev`，也会命中这个断言。

### fyne 版本回退成 `latest`

症状：日志里出现「无法解析 fyne 最新版本…回退 latest」，元数据 `fyne_version` 是 `latest`。

- 解析用 `go list -m fyne.io/tools@latest`，走基座 Dockerfile 的 `GOPROXY`。CNB 侧按腾讯 → goproxy.cn → goproxy.io → direct 依次回退，主源 5xx / 超时会自动换源；GitHub / GitLab 侧走 `proxy.golang.org`，网络不通时同样会失败。只有全部源都失败才需等下一次定时任务，或手动触发并显式填 `fyne_version`。
- 回退不会阻断构建，但层缓存会失效（缓存键永远等于 `latest`），且冒烟只验证 `fyne` 可执行、不比对版本。

### fyne 冒烟报 `fyne-version(...)`

冒烟用 `go version -m <fyne 二进制>` 读内嵌模块版本（`fyne.io/tools`），与本次目标版本不一致时报这个。常见原因：

- `go install` 装成了别的版本：检查 `--build-arg FYNE_VERSION` 与日志里的「fyne_version …」是否一致；
- 解析到了被 retract 的 `v1.26.0` / `v1.26.1`：这两个 tag 是上游误发并标了 retract，`go list -m fyne.io/tools@latest` 正常不会返回它们，出现时请显式填 `fyne_version`；
- 想放宽断言时改三份 `build-fyne.sh` 的冒烟段，别只改一侧。

### fyne 镜像里 `wails3` 也缺失/多余

`golang/fyne` 是 golang + fyne，不包含 wails2 / wails3。冒烟会断言 `fnpack` 与 `wails3` **不存在**；需要多个变体时请在自己的 Dockerfile 里 `FROM golang:latest` 再各装一个，不要指望某个变体镜像里带另一个。

### mygo 冒烟报 `pkg:gtk+-3.0` / `pkg:webkit2gtk-4.1`

- 说明镜像里对应的 `.pc` 文件解析失败。先看 Dockerfile 的 apt 那层日志：装包成功时同一层就会断言 `gtk+-3.0` / `webkit2gtk-4.1` 与那组 GL / X11 / Wayland 的 `.pc`，失败会直接停在那里。
- 本地验证：`docker run --rm golang-mygo:local sh -c 'pkg-config --list-all | grep -E "gtk|webkit"'`。
- 上层镜像如果自己 `purge` 掉了 `libgtk-3-dev` / `libwebkit2gtk-4.1-dev` / `libayatana-appindicator3-dev`，也会命中这个断言。

### mygo 冒烟报 `libgtk-3.so.0` / `libwebkit2gtk-4.1.so` 找不到

mygo 的 Linux 后端不带 cgo，它在运行期用 purego `dlopen` GTK3 / WebKitGTK，所以 `.pc` 能解析**不等于**运行期能加载：

- 本地验证：`docker run --rm golang-mygo:local sh -c 'ldconfig -p | grep -E "gtk-3|webkit2gtk-4.1|ayatana-appindicator3"'`。
- 缺库通常是因为只装了 `-dev` 的间接依赖却删掉了运行库包，或上游改了 Debian 包名（如 `libwebkit2gtk-4.0` → `4.1`）：核对三份 `Dockerfile.mygo` 的 apt 列表与三份 `build-mygo.sh` 的 `ldconfig` 断言。
- 冒烟里还有 `mygo doctor` 的 `gtk` / `webkit` 关键字断言：`mygo doctor` 自己会探测这两个库，缺库时它先报错。

### mygo 版本回退成 `latest`

症状：日志里出现「无法解析 mygo 最新版本…回退 latest」，元数据 `mygo_version` 是 `latest`。

- 解析用 `go list -m github.com/egoist/mygo@latest`，走基座 Dockerfile 的 `GOPROXY`。CNB 侧按腾讯 → goproxy.cn → goproxy.io → direct 依次回退，主源 5xx / 超时会自动换源；GitHub / GitLab 侧走 `proxy.golang.org`，网络不通时同样会失败。只有全部源都失败才需等下一次定时任务，或手动触发并显式填 `mygo_version`。
- 回退不会阻断构建，但层缓存会失效（缓存键永远等于 `latest`），且冒烟只验证 `mygo` 可执行、不比对版本。

### bun 版本回退成 `latest`

症状：日志里出现「无法解析 bun 最新版本…回退 latest」，元数据 `bun_version` 是 `latest`。

- 解析用 `npm view bun version`，走基座镜像的 npm registry。CNB 侧是腾讯云镜像，上游同步延迟时会失败；GitHub / GitLab 侧走官方 `registry.npmjs.org`。等下一次定时任务，或手动触发并显式填 `bun_version`。
- 回退同样只影响层缓存与元数据，不阻断构建。

### mygo 冒烟报 `mygo-version(...)`

冒烟用 `go version -m <mygo 二进制>` 读内嵌模块版本（`github.com/egoist/mygo`），与本次目标版本不一致时报这个。常见原因：

- `go install` 装成了别的版本：检查 `--build-arg MYGO_VERSION` 与日志里的「mygo_version …」是否一致；
- 本地用相同 `GOPROXY` 复现 `go install github.com/egoist/mygo/cmd/mygo@<版本>`；
- 想放宽断言时改三份 `build-mygo.sh` 的冒烟段，别只改一侧。

### mygo 镜像里 `fyne` / `wails` 也缺失/多余

`golang/mygo` 是 golang + mygo，不包含 fnpack / wails3 / wails2 / fyne。冒烟会断言 `fnpack` / `wails3` / `wails` / `fyne` 都**不存在**。注意 mygo 与 wails2 用同一套 GTK3 / WebKitGTK 4.1 运行库，但 CLI 与编译方式不同（wails2 要 cgo + `-tags webkit2_41`，mygo 纯 Go），所以两个镜像不能互相替代。

### gio 冒烟报 `pkg:egl` / `pkg:x11` / `pkg:vulkan` 等

- 说明镜像里对应的 `.pc` 文件解析失败。先看 Dockerfile 的 apt 那层日志：装包成功时同一层就会断言 `egl` / `glesv2` / `wayland-client` / `wayland-cursor` / `wayland-egl` / `x11` / `x11-xcb` / `xkbcommon` / `xkbcommon-x11` / `xcursor` / `xfixes` / `xrandr` / `xinerama` / `xi` / `xxf86vm` / `libffi` / `vulkan`，失败会直接停在那里。
- 本地验证：`docker run --rm golang-gio:local sh -c 'pkg-config --list-all | grep -E "egl|gles|wayland|xkbcommon|vulkan|libffi"'`。
- 上层镜像如果自己 `purge` 掉了 `libegl1-mesa-dev` / `libgles2-mesa-dev` / `libx11-dev` / `libwayland-dev` / `libvulkan-dev` / `libffi-dev`，也会命中这个断言。

### gio 版本回退成 `latest`

症状：日志里出现「无法解析 gio 最新版本…回退 latest」，元数据 `gio_version` 是 `latest`。

- 解析用 `go list -m gioui.org/cmd@latest`（gogio CLI），走基座 Dockerfile 的 `GOPROXY`。CNB 侧按腾讯 → goproxy.cn → goproxy.io → direct 依次回退，主源 5xx / 超时会自动换源；GitHub / GitLab 侧走 `proxy.golang.org`，网络不通时同样会失败。只有全部源都失败才需等下一次定时任务，或手动触发并显式填 `gio_version`。
- 回退不会阻断构建，但层缓存会失效（缓存键永远等于 `latest`），且冒烟只验证 `gogio` 可执行、不比对版本。

### gio 冒烟报 `gogio-version(...)`

冒烟用 `go version -m "$(command -v gogio)"` 读内嵌模块版本（`gioui.org/cmd`），与本次目标版本不一致时报这个。注意 `gogio` **没有 `version` 子命令**，不能像别的变体那样跑 `gogio version`；无参数运行会把 usage 打到 stderr 并以非零退出，脚本里必须带 `|| true`。常见原因：

- `go install` 装成了别的版本：检查 `--build-arg GIO_VERSION` 与日志里的「gio_version …」是否一致；
- 本地用相同 `GOPROXY` 复现 `go install gioui.org/cmd/gogio@<版本>`；
- 想放宽断言时改三份 `build-gio.sh` 的冒烟段，别只改一侧。

### gio 镜像里没有 `gio` 二进制

这不是故障：变体名叫 gio，CLI 却叫 `gogio`（模块 `gioui.org/cmd`），镜像里只有 `/go/bin/gogio`。而且 `gogio` 是打包工具，目标平台是 android / ios / tvos / js / windows / macos，**没有 linux 目标**——Linux 桌面程序就是普通 `go build` + cgo，不需要它。`gogio` 也没有 `version` 子命令，查版本只能用 `go version -m "$(command -v gogio)"`。

### gio 镜像里 `mygo` / `bun` 也缺失/多余

`golang/gio` 是 golang + gio，不包含 fnpack / wails3 / wails2 / fyne / mygo。冒烟会断言 `fnpack` / `wails3` / `wails` / `fyne` / `mygo` / `bun` 都**不存在**。注意 gio 与 fyne 都装 OpenGL/X11/Wayland 开发包，但 gio 还要 EGL/GLES、Vulkan、libffi 与 `xfixes`，所以两个镜像不能互相替代。

### fnpack 下载失败

- 地址格式：`https://static2.fnnas.com/fnpack/fnpack-<版本>-linux-<arch>`。
- 先用 `curl -sI` 验证两个文件都存在：amd64 是 `-linux-amd64`，ARM 是 `-linux-arm`（不是 `arm64`）。
- fnpack 镜像层用 `curl -fsSL`，HTTP 非 2xx 会直接失败；日志里会带 URL。

### `fnpack --help` 返回非 0

构建层里是 `fnpack --help >/dev/null 2>&1 || true`，不会因此失败。冒烟只检查 `command -v fnpack` 与可执行位。

### `docker login` 失败

- GitHub：workflow 必须传 `REGISTRY_TOKEN: ${{ secrets.GITHUB_TOKEN }}`，并给 `packages: write`。
- GitLab：确认使用的是 GitLab 自动注入的 `CI_REGISTRY_USER` / `CI_REGISTRY_PASSWORD`，没有被同名项目变量覆盖；job 还必须能访问 `CI_REGISTRY_IMAGE`。
- CNB：确认 `imports` 引用的 `docker.yml` 正常，`CNB_TOKEN` / `CNB_TOKEN_USER_NAME` 存在。

### 推送 GHCR 报 denied

- 包名必须小写；脚本已把小写化并提前拦截大写。
- 仓库 Settings → Actions → Workflow permissions 需要允许写 packages，或 workflow 显式声明 `packages: write`。

### OCI label 校验失败

脚本会读 `org.opencontainers.image.version` 并与解析出的 Go 版本比较。失败通常意味着：

- Dockerfile 没有把 `IMAGE_VERSION` 写进 LABEL；
- 构建脚本传的 `--build-arg IMAGE_VERSION` 与 `STAMP` 不一致；
- 拉到的不是本次构建的镜像（先确认 digest）。

### `go install` 失败

- 检查 `GOPROXY` 是否可达（CNB 镜像为腾讯云，GitHub / GitLab 镜像为 Go 默认代理）。
- 私有模块需要自行配置 `GOPRIVATE` / 认证，镜像不预置私有源设置。
- 某个工具版本与 Go 版本不兼容时，先在本机用相同 Go 版本复现。

### `npm install -g pnpm` 失败

- 检查 `NODE_URL` 是否可下载。
- CNB 侧 npm registry 用腾讯云，上游同步延迟时可临时改回官方；GitHub / GitLab 侧用官方默认 `registry.npmjs.org`，无需改动。
- Node 版本与 pnpm 版本不兼容时，同步调整 `NODE_VERSION` / `PNPM_VERSION`。

### 脚本被 imports 改写

症状：`sed: can't read "${DOCKERFILE...}"` 或自检直接报「脚本被外部改写」。

原因：把 `build-golang.sh` / `build-fnpack.sh` / `build-wails3.sh` / `build-wails2.sh` / `build-fyne.sh` / `build-mygo.sh` / `build-gio.sh` 放进了 CNB 的 `imports`。把它从 `imports` 移除，改用 `source` 执行。

## 本地复现 CI

```bash
# 语法
sh -n .cnb/scripts/build-golang.sh
sh -n .cnb/scripts/build-fnpack.sh
sh -n .cnb/scripts/build-wails3.sh
sh -n .cnb/scripts/build-wails2.sh
sh -n .cnb/scripts/build-fyne.sh
sh -n .cnb/scripts/build-mygo.sh
sh -n .cnb/scripts/build-gio.sh
sh -n .github/scripts/build-golang.sh
sh -n .github/scripts/build-fnpack.sh
sh -n .github/scripts/build-wails3.sh
sh -n .github/scripts/build-wails2.sh
sh -n .github/scripts/build-fyne.sh
sh -n .github/scripts/build-mygo.sh
sh -n .github/scripts/build-gio.sh
sh -n .gitlab/scripts/build-golang.sh
sh -n .gitlab/scripts/build-fnpack.sh
sh -n .gitlab/scripts/build-wails3.sh
sh -n .gitlab/scripts/build-wails2.sh
sh -n .gitlab/scripts/build-fyne.sh
sh -n .gitlab/scripts/build-mygo.sh
sh -n .gitlab/scripts/build-gio.sh

# ShellCheck
shellcheck -s sh -S warning .cnb/scripts/*.sh .github/scripts/*.sh .gitlab/scripts/*.sh

# 构建（CNB 镜像源）
docker build -f .cnb/docker/Dockerfile.golang \
  --build-arg GITHUB_MIRROR=https://files.m.daocloud.io \
  --build-arg NODE_MIRROR=https://files.m.daocloud.io \
  -t golang:local .
docker build -f .cnb/docker/Dockerfile.fnpack \
  --build-arg GOLANG_IMAGE=golang:local \
  -t golang-fnpack:local .
docker build -f .cnb/docker/Dockerfile.wails3 \
  --build-arg GOLANG_IMAGE=golang:local \
  -t golang-wails3:local .
docker build -f .cnb/docker/Dockerfile.wails2 \
  --build-arg GOLANG_IMAGE=golang:local \
  -t golang-wails2:local .
docker build -f .cnb/docker/Dockerfile.fyne \
  --build-arg GOLANG_IMAGE=golang:local \
  -t golang-fyne:local .
docker build -f .cnb/docker/Dockerfile.mygo \
  --build-arg GOLANG_IMAGE=golang:local \
  -t golang-mygo:local .
docker build -f .cnb/docker/Dockerfile.gio \
  --build-arg GOLANG_IMAGE=golang:local \
  -t golang-gio:local .

# 构建（GitLab / GitHub 侧：直连官方源）
docker build -f .gitlab/docker/Dockerfile.golang -t golang:local .
docker build -f .gitlab/docker/Dockerfile.fnpack \
  --build-arg GOLANG_IMAGE=golang:local \
  -t golang-fnpack:local .
```

## 还是不行

收集这些信息再排查：

```bash
docker version
docker buildx version
docker buildx inspect
docker buildx imagetools inspect <镜像>:<标签>
docker image inspect <镜像>:<标签> | jq '.[0].Config.Labels'
```

以及构建日志中失败步骤前后的完整输出。
