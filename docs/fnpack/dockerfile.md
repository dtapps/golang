# Dockerfile.fnpack 解析

三个平台各一份：`.cnb/docker/Dockerfile.fnpack`、`.github/docker/Dockerfile.fnpack` 与 `.gitlab/docker/Dockerfile.fnpack`，内容一致、各自维护。整个文件只做两件事——下载 fnpack、打 OCI 标签，其余全部继承基座；基座镜像的 Dockerfile（工具链、镜像源、层拆分）见 [../golang/dockerfile.md](../golang/dockerfile.md)。

## 基座

```dockerfile
ARG GOLANG_IMAGE=golang:1-trixie
FROM ${GOLANG_IMAGE}
ARG GOLANG_IMAGE
```

- CI 里 `GOLANG_IMAGE` 由构建脚本传成上一步刚推好的 `<golang 镜像>:<go 版本>`，所以 fnpack 产物 = 基座 + 一层。
- 默认值 `golang:1-trixie` 只用于脱离本仓库的裸构建；此时镜像里**没有**本仓库预装的 UPX / nfpm / Node / Go 工具链，只够验证 fnpack 下载本身。
- `FROM` 之后重新声明 `ARG GOLANG_IMAGE`，是为了让下面的 `org.opencontainers.image.base.name` 标签能引用它的实际值。
- 其余 build-arg（`FNPACK_VERSION` / `IMAGE_VERSION` / `VCS_REF` / `BUILD_DATE` / `BASE_DIGEST` / `IMAGE_SOURCE`）与基座镜像同名同义，由构建脚本传入。

## fnpack 安装层

```dockerfile
RUN set -eux; \
    ARCH="$(uname -m)"; \
    case "$ARCH" in \
    x86_64) FNPACK_ARCH="amd64" ;; \
    aarch64) FNPACK_ARCH="arm" ;; \
    *) echo "不支持的架构: $ARCH" >&2; exit 1 ;; \
    esac; \
    FNPACK_URL="https://static2.fnnas.com/fnpack/fnpack-${FNPACK_VERSION}-linux-${FNPACK_ARCH}"; \
    curl -fsSL -o /usr/local/bin/fnpack "${FNPACK_URL}"; \
    chmod +x /usr/local/bin/fnpack; \
    test -x /usr/local/bin/fnpack; \
    fnpack --help >/dev/null 2>&1 || true
```

逐点看：

- **下载地址**：`https://static2.fnnas.com/fnpack/fnpack-<版本>-linux-<arch>`，直连官方站，不走 GitHub Release，所以三个平台都没有镜像前缀开关（对比基座镜像的 `GITHUB_MIRROR` / `NODE_MIRROR`）。
- **架构映射是这里唯一的坑**：fnpack 上游的 ARM 产物文件名是 `arm`，**不是** `arm64`；而 `uname -m` 在 arm64 上返回 `aarch64`，必须映射成 `arm` 才能拼出正确的 URL。amd64 是平凡的 `x86_64` → `amd64`。映射错了会 404，构建直接失败。
- **安装即校验**：`chmod +x` → `test -x` → 跑一次 `fnpack --help`。部分版本的 `--help` 返回非 0，所以加了 `|| true`——这一步只验证「二进制能执行」，不校验退出码；更完整的断言在构建脚本的冒烟测试里（检查 `fnpack` 存在且可执行、Go 版本一致、基座工具链齐全）。
- **缓存友好**：这一层只依赖 `GOLANG_IMAGE` 与 `FNPACK_VERSION` 两个 build-arg。基座 digest 没变、fnpack 版本没升时，层缓存全命中，构建接近瞬时；机制见 [../cache-implementation.md](../cache-implementation.md)。

## 版本：默认值 + 手动覆盖

`FNPACK_VERSION` 与基座镜像里其它工具 ARG 的行为**不同**：

| 对比项   | 基座工具（UPX、nfpm、Go 工具…）   | fnpack                           |
|----------|-----------------------------------|----------------------------------|
| 默认值   | `latest`，CI 解析成具体版本再传回 | 写死的语义版本（当前 `1.2.3`）   |
| 自动追新 | 是（每日构建重新解析）            | 否，上游没有可查询 latest 的接口 |
| 手动覆盖 | 手动触发时传 `version`            | 手动触发时传 `fnpack_version`    |
| 原因     | 上游有可查询的版本渠道            | 下载地址不支持 latest 语义       |

脚本先用 `read_arg` 从 `Dockerfile.fnpack` 读出 `FNPACK_VERSION` 作为默认值：定时任务、以及手动触发时留空的 `fnpack_version`，都用这个值（当前 `1.2.3`，暂作为最新版本）。手动填了 `fnpack_version`（如 `1.2.3`）就直接覆盖，原样传给 `--build-arg`，不经转换。升级默认版本仍要改三份 Dockerfile，流程见 [../golang/maintenance.md](../golang/maintenance.md) 的「升级 fnpack」：先 `curl -sI` 确认对应产物存在。

## OCI 标签

```dockerfile
LABEL org.opencontainers.image.source="${IMAGE_SOURCE}" \
    ...
    org.opencontainers.image.base.name="${GOLANG_IMAGE}" \
    org.opencontainers.image.base.digest="${BASE_DIGEST}"
```

- 标签放在文件**最后**，与基座镜像同样的理由：`BUILD_DATE` / `VCS_REF` / `IMAGE_VERSION` 每次构建都变，放前面会让 fnpack 下载层的缓存键跟着每次提交一起变。
- `base.name` 记录本次实际使用的基座引用，`base.digest` 记录其 index digest——脚本用 `imagetools inspect` 读出后传入，与元数据的 `fnpack_base_image` / `fnpack_base_digest` 同源，可互相核对。
- `org.opencontainers.image.version` 等于解析出的 Go 版本（与基座一致），冒烟测试会校验这个标签。
- `CMD ["bash"]`，与基座一致。
