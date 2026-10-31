# 排错

## 先定位是哪一步

两条流水线各自输出：

```text
golang：解析基座 → 解析工具版本 → 登录 → buildx 自检 → 构建 golang
       → 派生单平台标签 → 冒烟 golang → 提升标签 → 元数据

fnpack：解析版本 → 登录 → buildx 自检 → 等待基础镜像 → 构建 fnpack
       → 派生单平台标签 → 冒烟 fnpack → 提升标签 → 元数据
```

日志里最后一次出现的「构建 …」「等待 …」或「冒烟测试 …」就是失败点。fnpack 作业失败时先确认对应版本的 golang 作业是否成功。

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

### 工具版本没跟着升级

症状：上游发了新版，镜像里的工具还是旧版本。

1. 先看构建日志里的「工具版本解析结果」，确认解析到的是不是新版本；解析失败会打警告并回退 `latest`。
2. 解析到的版本没变：上游索引（Go proxy / npm / GitHub Release）还没同步，等下一次定时任务。
3. 版本变了但层没重建：`CACHE=off` 跑一次全量重建；仍然不对就检查 `--build-arg` 是否真的传进了 Dockerfile。

### 带缓存的构建失败 / 多出一个 `buildcache` 标签

- 缓存写到 `<镜像>:buildcache`，仓库页面多出这个标签属正常现象。
- 有的 registry 不接受 buildx 的缓存清单（未知 media type / 权限），而缓存导出发生在镜像推完之后，会表现为「构建成功但步骤失败」。脚本会自动去掉缓存重试一次，日志里会先出现「带缓存的构建失败」警告。
- 想长期不用缓存：设 `CACHE=off`。

### 下载 404（UPX / nfpm / Node.js）

1. 确认版本号 ARG 对应的文件确实存在。
2. 用 [mirrors.md](mirrors.md) 的 `curl -sI` 验证原站与镜像站。
3. CNB 上如果原站可访问、DaoCloud 404，可能是代理尚未同步；临时改成直连验证。
4. 两侧 Dockerfile 的版本 ARG 必须同步。

### fnpack 找不到基础镜像

症状：`基础镜像 <registry>/<repo>:<go 版本> 不存在`。

- fnpack 镜像必须 `FROM` 同版本的 golang 基础镜像，不会自己安装工具链。
- CNB：确认 00:05 的 `build-golang` 定时任务成功；03:05 的 fnpack 才有基础可用。
- GitHub：确认 16:35 UTC 的 `build-golang` 定时任务成功；19:35 UTC 的 fnpack 才有基础可用。手动触发前先跑一次 build-golang。
- 刚推完基础镜像就手动跑 fnpack 时，脚本会最多等 5 分钟，仍然失败说明基础镜像确实没推上去。

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
- npm registry 默认腾讯云；如果上游同步延迟，临时改回官方 registry 验证。
- Node 版本与 pnpm 版本不兼容时，同步调整 `NODE_VERSION` / `PNPM_VERSION`。

### 脚本被 imports 改写

症状：`sed: can't read "${DOCKERFILE...}"` 或自检直接报「脚本被外部改写」。

原因：把 `build-golang.sh` / `build-fnpack.sh` 放进了 CNB 的 `imports`。把它从 `imports` 移除，改用 `source` 执行。

## 本地复现 CI

```bash
# 语法
sh -n .cnb/scripts/build-golang.sh
sh -n .cnb/scripts/build-fnpack.sh
sh -n .github/scripts/build-golang.sh
sh -n .github/scripts/build-fnpack.sh

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
