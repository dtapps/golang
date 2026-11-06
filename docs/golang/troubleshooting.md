# 排错

## 先定位是哪一步

四条流水线各自输出：

```text
golang：解析基座 → 解析工具版本 → 登录 → buildx 自检 → 构建 golang
       → 派生单平台标签 → 冒烟 golang → 提升标签 → 元数据

fnpack：解析版本 → 登录 → buildx 自检 → 等待基础镜像 → 构建 fnpack
       → 派生单平台标签 → 冒烟 fnpack → 提升标签 → 元数据

wails3：解析版本（含 wails3 版本）→ 登录 → buildx 自检 → 等待基础镜像 → 构建 wails3
       → 派生单平台标签 → 冒烟 wails3 → 提升标签 → 元数据

wails2：解析版本（含 wails2 版本）→ 登录 → buildx 自检 → 等待基础镜像 → 构建 wails2
       → 派生单平台标签 → 冒烟 wails2 → 提升标签 → 元数据
```

日志里最后一次出现的「构建 …」「等待 …」或「冒烟测试 …」就是失败点。变体作业失败时先确认对应版本的 golang 作业是否成功。

## 常见症状

### `exec format error`（arm64 阶段）

原因：在 amd64 runner 上构建 arm64，没有 QEMU/binfmt。

- GitHub：确认 workflow 里有 `docker/setup-qemu-action@v3`（`platforms: arm64`）。
- CNB：确认 `services: docker` 已启用；CNB 的 docker 服务自带多架构支持。

### `no space left on device`

基础镜像与两平台构建缓存较大。GitHub 侧已有「释放磁盘空间」步骤；如果仍然不够：

- 确认该步骤没有删错目录；
- 不要在同一个 runner 上同时跑其他重构建；
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

原因：CNB 制品库不支持把镜像清单当 blob 读；`imagetools create` 在同仓库打标签时仍要走 blob copy，`copy sha256:... unexpected EOF` 在 `0.000s` 稳定复现，与基座几点构建、四条定时任务错开多久都无关。**重试无效**（3 次全挂已实测）。

处置：

- CNB 侧三份脚本改用 Registry V2 API：`registry_auth()` 复用 `docker login` 凭证换 Bearer token，`put_manifest()` 把源清单 `GET` 下来、原文 `PUT` 到新 tag。层 blob 本就在同一仓库，全程不触发复制，digest 不变；PUT 后校验 `Docker-Content-Digest`，不一致即失败。
- 派生标签因此是单平台 manifest 原文（不再是包一层的 OCI index），`docker pull --platform` 行为不变。
- GitHub 侧 GHCR 无此限制，保留 `create_tag_with_retry` 兜瞬时抖动；两侧实现不同、标签结果一致，别把 CNB 侧改回 `imagetools create`。
- 提升标签前读基座 digest 也加了 3 次重试 + 告警，避免读失败被当成「基座未对齐」静默跳过。
- 排障：`docker buildx imagetools inspect <镜像>:<版本>` 与 `...:<版本>-linux-amd64`；PUT 失败时日志会打印源引用与 `Content-Type`。

### 下载 404（UPX / nfpm / Node.js）

1. 确认版本号 ARG 对应的文件确实存在。
2. 用 [mirrors.md](mirrors.md) 的 `curl -sI` 验证原站与镜像站。
3. CNB 上如果原站可访问、DaoCloud 404，可能是代理尚未同步；临时改成直连验证。
4. 两侧 Dockerfile 的版本 ARG 必须同步。

### fnpack / wails3 找不到基础镜像

症状：`基础镜像 <registry>/<repo>:<go 版本> 不存在`。

- 变体镜像必须 `FROM` 同版本的 golang 基础镜像，不会自己安装工具链。
- CNB：确认 00:05 的 `build-golang` 定时任务成功；03:05 的 fnpack、06:05 的 wails3 才有基础可用。
- GitHub：确认 16:35 UTC 的 `build-golang` 定时任务成功；19:35 UTC 的 fnpack、22:35 UTC 的 wails3 才有基础可用。手动触发前先跑一次 build-golang。
- 刚推完基础镜像就手动跑变体时，脚本会最多等 5 分钟，仍然失败说明基础镜像确实没推上去。

### wails3 冒烟报 `pkg:gtk4` / `pkg:webkitgtk-6.0`

- 说明镜像里 `pkg-config --exists gtk4` 或 `webkitgtk-6.0` 失败。先看 Dockerfile 的 apt 那层日志：装包成功时同一层就会断言，失败会直接停在那里。
- 本地验证：`docker run --rm golang-wails3:local sh -c 'pkg-config --list-all | grep -E "gtk4|webkitgtk"'`。
- 上层镜像如果自己 `purge` 掉了 `libgtk-4-dev` / `libwebkitgtk-6.0-dev`，也会命中这个断言。

### wails3 版本回退成 `latest`

症状：日志里出现「无法解析 wails3 最新版本…回退 latest」，元数据 `wails3_version` 是 `latest`。

- 解析用 `go list -m github.com/wailsapp/wails/v3@latest`，走基座 Dockerfile 的 `GOPROXY`。CNB 侧是腾讯云镜像，同步有延迟时会失败；等下一次定时任务，或手动触发并显式填 `wails3_version`。
- 回退不会阻断构建，但层缓存会失效（缓存键永远等于 `latest`），且冒烟只验证 `wails3` 可执行、不比对版本。

### wails3 冒烟报 `wails3-version(...)`

冒烟用 `go version -m <wails3 二进制>` 读内嵌模块版本，与本次目标版本不一致时报这个。常见原因：

- `go install` 装成了别的版本：检查 `--build-arg WAILS3_VERSION` 与日志里的「wails3_version …」是否一致；
- 手动填了预发布 tag（如 `v3.0.0-beta.34`），但 GOPROXY 上没有对应版本、`go install` 落到了别的 tag：本地用相同 `GOPROXY` 复现 `go install ...@<tag>`；
- 想放宽断言时改两份 `build-wails3.sh` 的冒烟段，别只改一侧。

### fnpack 下载失败

- 地址格式：`https://static2.fnnas.com/fnpack/fnpack-<版本>-linux-<arch>`。
- 先用 `curl -sI` 验证两个文件都存在：amd64 是 `-linux-amd64`，ARM 是 `-linux-arm`（不是 `arm64`）。
- fnpack 镜像层用 `curl -fsSL`，HTTP 非 2xx 会直接失败；日志里会带 URL。

### `fnpack --help` 返回非 0

构建层里是 `fnpack --help >/dev/null 2>&1 || true`，不会因此失败。冒烟只检查 `command -v fnpack` 与可执行位。

### `docker login` 失败

- GitHub：workflow 必须传 `REGISTRY_TOKEN: ${{ secrets.GITHUB_TOKEN }}`，并给 `packages: write`。
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

- 检查 `GOPROXY` 是否可达（CNB 镜像为腾讯云，GitHub 镜像为 Go 默认代理）。
- 私有模块需要自行配置 `GOPRIVATE` / 认证，镜像不预置私有源设置。
- 某个工具版本与 Go 版本不兼容时，先在本机用相同 Go 版本复现。

### `npm install -g pnpm` 失败

- 检查 `NODE_URL` 是否可下载。
- CNB 侧 npm registry 用腾讯云，上游同步延迟时可临时改回官方；GitHub 侧用官方默认 `registry.npmjs.org`，无需改动。
- Node 版本与 pnpm 版本不兼容时，同步调整 `NODE_VERSION` / `PNPM_VERSION`。

### 脚本被 imports 改写

症状：`sed: can't read "${DOCKERFILE...}"` 或自检直接报「脚本被外部改写」。

原因：把 `build-golang.sh` / `build-fnpack.sh` / `build-wails3.sh` 放进了 CNB 的 `imports`。把它从 `imports` 移除，改用 `source` 执行。

## 本地复现 CI

```bash
# 语法
sh -n .cnb/scripts/build-golang.sh
sh -n .cnb/scripts/build-fnpack.sh
sh -n .cnb/scripts/build-wails3.sh
sh -n .github/scripts/build-golang.sh
sh -n .github/scripts/build-fnpack.sh
sh -n .github/scripts/build-wails3.sh

# ShellCheck
shellcheck -s sh -S warning .cnb/scripts/*.sh .github/scripts/*.sh

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
