# 镜像构建缓存实现说明

> 讲清本仓库为什么这么改、改了哪几处、代码长什么样。实现在 `.cnb/`、`.github/` 与 `.gitlab/` 三侧，代码片段摘自这几处。

## 一句话原理

buildx 的层缓存键 = **父层 digest + 指令文本 + 所有 build-arg 的值**。

所以只要 Dockerfile 写的是 `ARG SQLC_VERSION=latest`、脚本每天也传 `latest`，缓存键就**永远不变**，那一层会一直命中第一次构建的产物——缓存「生效」了，但工具再也不会升级。

解法：**构建前先把 `latest` 解析成具体版本号（`v1.31.1`），再以 `--build-arg` 传进去。**

| 情况                 | 缓存键 | 结果                             |
|----------------------|--------|----------------------------------|
| 上游没发新版         | 不变   | 全部命中，只剩拉基座 + 冒烟      |
| 上游发了新版         | 变了   | 只重建该工具所在的那一层         |
| 基础镜像 digest 变了 | 变了   | apt 之后的层全部重建（符合预期） |

「每天跟最新」的语义不变：解析动作每天照做。

## 改造点一：`LABEL` 移到文件最后

`org.opencontainers.image.created` / `revision` / `version` 每次构建都变。放在文件开头，会让它后面**所有层**（apt、Node、`go install`）的缓存键跟着每次提交一起变，缓存直接失效。

```dockerfile
# ... 所有 RUN 都在前面 ...

# 元数据放最后：这些值每次都变，放前面会让后续层缓存全部失效
LABEL org.opencontainers.image.source="${IMAGE_SOURCE}" \
    org.opencontainers.image.url="${IMAGE_SOURCE}" \
    org.opencontainers.image.revision="${VCS_REF}" \
    org.opencontainers.image.created="${BUILD_DATE}" \
    org.opencontainers.image.version="${IMAGE_VERSION}" \
    org.opencontainers.image.base.digest="${BASE_DIGEST}"

CMD ["bash"]
```

## 改造点二：按工具拆层

原来一层里 `go install` 十几个工具，任何一个发版都要重装全部。拆开后某个工具发版只重建它那一层。

```dockerfile
# 组 1：nfpm + sqlc
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    go install github.com/goreleaser/nfpm/v2/cmd/nfpm@${NFPM_VERSION} \
    && go install github.com/sqlc-dev/sqlc/cmd/sqlc@${SQLC_VERSION}

# 组 2：ent / entc
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    go install entgo.io/ent/cmd/ent@${ENT_VERSION} \
    && go install entgo.io/ent/cmd/entc@${ENT_VERSION}

# 组 3：golangci-lint + govulncheck
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@${GOLANGCI_LINT_VERSION} \
    && go install golang.org/x/vuln/cmd/govulncheck@${GOVULNCHECK_VERSION}

# 组 4：格式化工具
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    go install mvdan.cc/sh/v3/cmd/shfmt@${SHFMT_VERSION} \
    && go install github.com/reteps/dockerfmt@${DOCKERFMT_VERSION} \
    && go install github.com/google/yamlfmt/cmd/yamlfmt@${YAMLFMT_VERSION} \
    && go install github.com/itchyny/gojq/cmd/gojq@${GOJQ_VERSION}

# 组 5：剩余工具
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    go install github.com/wasilibs/go-sql-formatter/v15/cmd/sql-formatter@${GOSQLFORMATTER_VERSION} \
    && go install gotest.tools/gotestsum@${GOTESTSUM_VERSION} \
    && go install github.com/Kunde21/markdownfmt/v3/cmd/markdownfmt@${MARKDOWNFMT_VERSION} \
    && go install github.com/boumenot/gocover-cobertura@${GOCOVER_COBERTURA_VERSION}
```

同时**删掉**原来的 `rm -rf /go/pkg/mod /root/.cache/go-build`：`--mount=type=cache` 的目录本来就不进镜像层，留着只会把缓存删掉，反而变慢。

`ARG` 默认值仍保留 `latest`。裸 `docker build`（不经过 CI）时没有解析步骤，Dockerfile 里原有的「`= latest` 就在构建时自己解析」逻辑保持不动，行为不变。

## 改造点三：登记「版本变量 → Go 模块路径」

`go list -m` 要的是**模块路径**，`go install` 写的是**包路径**，两者不能混用（`github.com/goreleaser/nfpm/v2` 能解析，`.../v2/cmd/nfpm` 会报 `no matching versions`）。所以单独维护一张表：

```sh
GO_TOOL_MODULES="
NFPM_VERSION=github.com/goreleaser/nfpm/v2
SQLC_VERSION=github.com/sqlc-dev/sqlc
ENT_VERSION=entgo.io/ent
GOLANGCI_LINT_VERSION=github.com/golangci/golangci-lint/v2
GOVULNCHECK_VERSION=golang.org/x/vuln
SHFMT_VERSION=mvdan.cc/sh/v3
DOCKERFMT_VERSION=github.com/reteps/dockerfmt
YAMLFMT_VERSION=github.com/google/yamlfmt
GOJQ_VERSION=github.com/itchyny/gojq
GOSQLFORMATTER_VERSION=github.com/wasilibs/go-sql-formatter/v15
GOTESTSUM_VERSION=gotest.tools/gotestsum
MARKDOWNFMT_VERSION=github.com/Kunde21/markdownfmt/v3
GOCOVER_COBERTURA_VERSION=github.com/boumenot/gocover-cobertura
"
```

关键设计：**从 Dockerfile 自动提取版本变量，漏登记就报错**，以后加工具不会忘记同步这张表。

```sh
# 从 Dockerfile 提取所有 go install 用到的版本变量（去重、排序）
dockerfile_tool_vars() (
  sed -n 's/.*go install [^@[:space:]]*@\${\([A-Z_][A-Z0-9_]*\)}.*/\1/p' "$1" | sort -u
)

# 自检：Dockerfile 里的 go install 版本变量必须在 GO_TOOL_MODULES 里登记
missing_modules=""
for var in $(dockerfile_tool_vars "$DOCKERFILE"); do
  printf '%s\n' "${GO_TOOL_MODULES}" | grep -q "^${var}=" \
    || missing_modules="${missing_modules} ${var}"
done
[ -z "${missing_modules}" ] \
  || die "这些版本变量没在 GO_TOOL_MODULES 里登记模块路径：${missing_modules}"
```

## 改造点四：在基础镜像里解析版本

不要把解析写在 runner 上：runner 可能没装 go / curl / jq，还要自己处理模块路径转义。直接在基础镜像容器里跑，环境天然一致。

```sh
# 取解析结果：resolved_versions 是 KEY=VALUE 的换行列表
version_value() (
  printf '%s\n' "${resolved_versions}" | sed -n "s/^${1}=//p" | head -n 1
)

resolve_versions() {
  set -- --rm -i --platform linux/amd64 \
    -e "GO_TOOL_MODULES=${GO_TOOL_MODULES}" \
    -e "GITHUB_MIRROR=${MIRROR}" \
    -e "NODE_MIRROR=${MIRROR}" \
    -e "NPM_REGISTRY=${NPM_REGISTRY}"
  if [ -n "${DOCKERFILE_GOPROXY}" ]; then
    set -- "$@" -e "GOPROXY=${DOCKERFILE_GOPROXY}"
  fi
  docker run "$@" "golang:${GO_REF}" sh -s <<'RESOLVE_EOF'
set -eu

# Go 工具：模块路径 → GOPROXY 上的最新 tag
for pair in ${GO_TOOL_MODULES}; do
  var="${pair%%=*}"
  mod="${pair#*=}"
  ver="$(go list -m -f '{{.Version}}' "${mod}@latest")"
  case "${ver}" in
  v[0-9]*) : ;;
  *) echo "无法解析 ${var}（${mod}@latest → ${ver:-空}）" >&2; exit 1 ;;
  esac
  printf '%s=%s\n' "${var}" "${ver}"
done

# 非 Go 工具：各自的上游索引。
# UPX：releases.atom 第一个稳定 tag（不走 api.github.com：免认证、无限速）
if [ -n "${GITHUB_MIRROR:-}" ]; then GH="${GITHUB_MIRROR%/}/github.com"; else GH="https://github.com"; fi
upx_tag="$(curl -fsSL "${GH}/upx/upx/releases.atom" \
  | grep -oE 'releases/tag/v[0-9]+\.[0-9]+\.[0-9]+"' | head -n 1 \
  | sed 's|.*/tag/||; s|"||')"
case "${upx_tag}" in
v[0-9]*) printf 'UPX_VERSION=%s\n' "${upx_tag#v}" ;;
*) echo "无法解析 UPX 版本（得到：${upx_tag:-空}）" >&2; exit 1 ;;
esac

# Node.js：dist/index.json 第一个非预发布版本（过滤 -alpha / -rc）
if [ -n "${NODE_MIRROR:-}" ]; then NODE_BASE="${NODE_MIRROR%/}/nodejs.org/dist"; else NODE_BASE="https://nodejs.org/dist"; fi
node_tag="$(curl -fsSL "${NODE_BASE}/index.json" \
  | grep -oE '"version"[[:space:]]*:[[:space:]]*"v[0-9][^"]*"' \
  | sed 's/.*"\(v[0-9][^"]*\)"$/\1/' \
  | grep -v -- '-' | head -n 1)"
case "${node_tag}" in
v[0-9]*) printf 'NODE_VERSION=%s\n' "${node_tag#v}" ;;
*) echo "无法解析 Node.js 版本（得到：${node_tag:-空}）" >&2; exit 1 ;;
esac

# pnpm：npm registry 的 pnpm@latest
pnpm_ver="$(curl -fsSL "${NPM_REGISTRY%/}/pnpm/latest" \
  | grep -oE '"version"[[:space:]]*:[[:space:]]*"[0-9][^"]*"' | head -n 1 \
  | sed 's/.*"\([0-9][^"]*\)"$/\1/')"
case "${pnpm_ver}" in
[0-9]*) printf 'PNPM_VERSION=%s\n' "${pnpm_ver}" ;;
*) echo "无法解析 pnpm 版本（得到：${pnpm_ver:-空}）" >&2; exit 1 ;;
esac
RESOLVE_EOF
}
```

调用处：解析失败只警告、不阻断（回退 `latest`，本次缓存不生效但构建仍正确）。

```sh
DOCKERFILE_GOPROXY="$(read_env GOPROXY "$DOCKERFILE")"
NPM_REGISTRY="$(read_npm_registry "$DOCKERFILE")"
TOOL_VARS="$(dockerfile_tool_vars "$DOCKERFILE") UPX_VERSION NODE_VERSION PNPM_VERSION"

resolved_versions=""
if resolved_versions="$(resolve_versions)"; then
  info "工具版本解析结果："
  printf '%s\n' "${resolved_versions}" | sed 's/^/    /'
else
  resolved_versions=""
  warn "工具版本解析失败，回退 latest：本次由 Dockerfile 在构建时解析，层缓存不生效"
fi
```

`read_env` / `read_npm_registry` 的作用是**让解析和构建走同一个源**。否则解析走官方 registry、构建走镜像站，两边看到的版本可能不一致，缓存键和实际产物对不上。

```sh
read_env() (
  name=$1
  file=$2
  grep -E "^[[:space:]]*${name}=" "${file}" | head -n 1 \
    | sed "s/.*${name}=//" | sed 's/[[:space:]\\]*$//'
)

read_npm_registry() (
  grep -o 'npm config set registry [^;]*' "$1" | head -n 1 \
    | sed 's/^npm config set registry //'
)
```

## 改造点五：把构建包成函数

```sh
CACHE_REF_SUFFIX="buildcache"
CACHE_MODE="min"

CACHE_REF="${IMAGE}:${CACHE_REF_SUFFIX}"
CACHE_FROM_READY=""
if [ "${CACHE}" = "on" ]; then
  if docker buildx imagetools inspect "${CACHE_REF}" >/dev/null 2>&1; then
    CACHE_FROM_READY=yes
    info "缓存源 ${CACHE_REF} 可读，本次尝试命中"
  else
    info "缓存源 ${CACHE_REF} 还不存在，本次只写不读"
  fi
fi

build_image() (
  mode=$1
  set -- \
    -t "${IMAGE}:${STAMP}" \
    --platform "${PLATFORMS}" \
    --build-arg "GO_VERSION=${GO_VERSION}" \
    --build-arg "IMAGE_VERSION=${STAMP}" \
    --build-arg "IMAGE_SOURCE=${IMAGE_SOURCE}" \
    --build-arg "VCS_REF=${VCS_REF}" \
    --build-arg "BUILD_DATE=${BUILD_DATE}" \
    --build-arg "BASE_DIGEST=${BASE_DIGEST}"
  # 逐个传入解析出的工具版本
  for var in ${TOOL_VARS}; do
    val="$(version_value "${var}")"
    [ -n "${val}" ] || val="latest"
    set -- "$@" --build-arg "${var}=${val}"
  done
  case "${mode}" in
    on)
      if [ -n "${CACHE_FROM_READY}" ]; then
        set -- "$@" --cache-from "type=registry,ref=${CACHE_REF}"
      fi
      set -- "$@" --cache-to "type=registry,ref=${CACHE_REF},mode=${CACHE_MODE}"
      ;;
    off) set -- "$@" --no-cache ;;
    *) : ;;
  esac
  set -- "$@" --provenance=mode=min --sbom=false -f "${DOCKERFILE}" --push .
  docker buildx build "$@"
)

if [ "${CACHE}" = "off" ]; then
  build_image off || die "docker buildx build 失败（CACHE=off）"
elif ! build_image on; then
  # 有的 registry 不接受 buildx 缓存清单，且缓存导出是在镜像推完之后才报错。
  # 去掉缓存重试一次，别让当天的构建白跑。
  warn "带缓存的构建失败：可能是 registry 不支持 buildx 缓存清单，去掉缓存重试一次"
  build_image plain || die "docker buildx build 失败"
fi
```

为什么用 `mode=min`：单阶段构建，每一层都在最终镜像里，`min` 已覆盖整条链，而且缓存清单引用的 blob 与镜像层是同一批 digest，不产生没人引用的孤儿 blob。**改成多阶段构建要换成 `mode=max`**，否则中间阶段的层不会被导出。

## 改造点六：开关

```sh
CACHE="${CACHE:-on}"
case "${CACHE}" in
on | off) : ;;
*) die "CACHE 只接受 on / off，收到：${CACHE}" ;;
esac
```

`CACHE=off source build.sh` 即全量重建，等价于改造前。

## 改造点七：元数据记录本次实际版本

方便事后回查「某天的镜像里到底是哪个版本」，也方便排查「为什么没升级」。

```sh
TOOLS_SUMMARY=""
for var in ${TOOL_VARS}; do
  val="$(version_value "${var}")"
  [ -n "${val}" ] || val="latest"
  TOOLS_SUMMARY="${TOOLS_SUMMARY}$(printf '%s' "${var%%_VERSION}" | tr '[:upper:]' '[:lower:]')=${val} "
done
# 写进 annotation：\"tools\": \"${TOOLS_SUMMARY% }\"
```

## 下游镜像（`FROM` 上一个镜像的那种）

本仓库的 `golang/fnpack` 属于这一类。要点：

- `--build-arg "GOLANG_IMAGE=${IMAGE}:${STAMP}"` 指向刚推好的上游镜像。
- 同时把上游的 **index digest** 作为 `BASE_DIGEST` 传进去并写进 `LABEL`。上游内容一变，这一层就重建。
- 上游镜像当天全命中时，下游镜像基本也全命中，构建接近瞬时。
- 缓存 ref 用**自己的** `<下游镜像>:buildcache`，不要和上游共用。

## 改动清单

本仓库这次一共动了这些地方，三侧（CNB / GitHub / GitLab）各一份：

- [X] Dockerfile：`LABEL` 整块移到文件末尾（`CMD` 之前）。
- [X] Dockerfile：`go install` 按工具分组拆成 5 个 `RUN`。
- [X] Dockerfile：每个 `go install` 的 `RUN` 加两个 cache mount：`--mount=type=cache,target=/go/pkg/mod`、`--mount=type=cache,target=/root/.cache/go-build`。
- [X] Dockerfile：删掉层内的 `rm -rf /go/pkg/mod /root/.cache/go-build`。
- [X] 脚本：加 `GO_TOOL_MODULES` 表 + `dockerfile_tool_vars` 自检。
- [X] 脚本：加 `resolve_versions()`，在基础镜像容器里跑。
- [X] 脚本：把 `docker buildx build` 包成 `build_image()`，逐个传 `--build-arg <VAR>=<解析值>`。
- [X] 脚本：加 `--cache-to/--cache-from type=registry,ref=<镜像>:buildcache,mode=min`。
- [X] 脚本：加 `CACHE=on/off` 开关与「失败去掉缓存重试」。
- [X] 脚本：annotation 加 `tools` 字段。
- [X] 每个镜像用自己的 cache ref（`golang:buildcache`、`golang/fnpack:buildcache`），不共用。
- [X] 下游镜像：`--build-arg` 包含上游镜像的 digest。
- [X] 跑格式化与 lint（`shfmt -i 2 -ci -bn -s -ln posix` + `shellcheck -s sh -S warning`）。

## 怎么验证

### 看层是否命中

```bash
docker buildx build --progress=plain ... 2>&1 | grep -E 'CACHED|RUN '
```

命中时对应 `RUN` 显示 `CACHED`。第一次必然全 miss，第二次应该大部分命中。

### 看解析结果

构建日志里会有：

```text
  工具版本解析结果：
    NFPM_VERSION=v2.48.0
    SQLC_VERSION=v1.31.1
    ...
    UPX_VERSION=5.3.0
    NODE_VERSION=26.13.0
    PNPM_VERSION=12.16.1
```

如果这里回退成了 `latest`，说明解析失败，缓存不会生效（但构建仍然正确）。

### 确认标签契约没变

缓存改造**不应该**动任何标签规则。改完用这个命令对比改造前后：

```bash
git diff HEAD -- build.sh \
  | grep -E '^[-+].*(STAMP=|MINOR=|imagetools create|for tag in)'
```

输出为空 = 标签逻辑逐字节没变。

## 踩过的坑

1. **`go list -m` 用模块路径，`go install` 用包路径。** `github.com/goreleaser/nfpm/v2` 能解析，`.../v2/cmd/nfpm` 会报 `no matching versions`。必须单独维护 `GO_TOOL_MODULES` 并加自检。
2. **`LABEL` 不放最后，缓存基本白做。** `BUILD_DATE` 每次构建都变，它下面的层每天全 miss。
3. **`mode=min` 只适合单阶段构建。** 多阶段构建的中间层不在最终镜像里，`min` 导不出来，要改 `mode=max`。
4. **registry 可能不接受 cache manifest。** 表现为「镜像已经推上去了，但步骤失败」。必须加重试分支，否则当天的构建白跑。缓存清单是普通 manifest，仓库页面会多一个 `buildcache` 标签，属正常现象。
5. **探测缓存是否存在再决定加不加 `--cache-from`。** 第一次构建时 cache ref 还不存在，直接传 `--cache-from` 有些 buildx 版本会报错，先 `imagetools inspect` 探一下。
6. **不建议用 `type=gha`。** 需要额外暴露 `ACTIONS_CACHE_URL` / `ACTIONS_RUNTIME_TOKEN`（裸调 `docker buildx build` 时得自己传），且有 10GB 上限。registry 缓存与平台无关，脚本结构不用改。
7. **版本号格式不统一。** Go 工具是 `v1.31.1`（带 v），UPX 是 `5.3.0`（不带 v），Node 是 `26.13.0`。解析时按各自格式处理。
8. **JSON 返回可能带空格。** 有的 npm 镜像返回 `"version": "12.16.1"`（冒号后有空格），grep 要用 `[[:space:]]*` 容忍。
9. **跨架构共享 cache mount 是安全的。** Go 的 build cache key 里包含 `GOOS`/`GOARCH`，amd64 与 arm64 共用一个 `/root/.cache/go-build` 不会串；模块缓存同理。
10. **冒烟测试不受缓存影响，但坏二进制会被缓存固化。** 首次上线建议先跑一次 `CACHE=off` 建立可信基线，再开缓存。
11. **缓存命中不等于跳过冒烟。** 冒烟跑在 `docker run` 的新容器里，缓存只影响构建阶段。这个设计要保留，它是「`latest` 只在验证通过后才提升」的保证。
12. **上游镜像 digest 变了要能触发重建。** 基础镜像是浮动 tag（如 `golang:1-trixie`），解析出的 digest 要作为 `--build-arg BASE_DIGEST` 传进去并写进 `LABEL org.opencontainers.image.base.digest`。这样上游重新推送同一 tag（安全修复）时能正确重建，digest 也可追溯。

## 回滚

```bash
CACHE=off source ./build.sh
```

行为完全等价于改造前（全量重建、`latest` 在构建时自己解析），不需要回滚代码。

## 代码位置

| 文件                                                                | 内容                                                          |
|---------------------------------------------------------------------|---------------------------------------------------------------|
| `.cnb/docker/Dockerfile.golang`、`.github/docker/Dockerfile.golang` | LABEL 后移、5 层 `go install`、cache mount                    |
| `.cnb/scripts/build-golang.sh`、`.github/scripts/build-golang.sh`   | `GO_TOOL_MODULES`、`resolve_versions`、`build_image`、`CACHE` |
| `.cnb/scripts/build-fnpack.sh`、`.github/scripts/build-fnpack.sh`   | 下游镜像的缓存（用上游 digest 做 build-arg）                  |
| [golang/build.md](golang/build.md)                                  | 「缓存」章节，含 CI 构建 10 步流程                            |
