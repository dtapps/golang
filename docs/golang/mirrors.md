# 镜像源

## 一张表

| 依赖                        | GitHub Actions                   | CNB                                          |
|-----------------------------|----------------------------------|----------------------------------------------|
| GitHub Release（UPX、nfpm） | 直连 `github.com`                | `https://files.m.daocloud.io/github.com/...` |
| Node.js 官方 tar.xz         | 直连 `nodejs.org`                | `https://files.m.daocloud.io/nodejs.org/...` |
| fnpack                      | 直连 `static2.fnnas.com`         | 直连 `static2.fnnas.com`                     |
| Debian APT                  | `mirrors.cloud.tencent.com`      | `mirrors.cloud.tencent.com`                  |
| Go module                   | `mirrors.cloud.tencent.com/go/`  | `mirrors.cloud.tencent.com/go/`              |
| npm / pnpm registry         | `mirrors.cloud.tencent.com/npm/` | `mirrors.cloud.tencent.com/npm/`             |

## 开关

Dockerfile 里有两个构建参数：

```dockerfile
ARG GITHUB_MIRROR=""
ARG NODE_MIRROR=""
```

为空时直连官方站；非空时按「代理站 + 域名」拼接：

```sh
GH="${GITHUB_MIRROR%/}/github.com"          # github.com
NODE_BASE="${NODE_MIRROR%/}/nodejs.org/dist" # nodejs.org
```

基础镜像构建脚本的传参：

| 平台   | 构建脚本                          | 是否传镜像参数                   |
|--------|-----------------------------------|----------------------------------|
| CNB    | `.cnb/scripts/build-golang.sh`    | 传 `https://files.m.daocloud.io` |
| GitHub | `.github/scripts/build-golang.sh` | 不传（直连）                     |

fnpack 镜像只从 `https://static2.fnnas.com` 下载二进制，两个平台的 `build-fnpack.sh` 都不传镜像参数。

CNB 的 PR 校验 workflow 也会传：

```bash
docker buildx build \
  --build-arg GITHUB_MIRROR=https://files.m.daocloud.io \
  --build-arg NODE_MIRROR=https://files.m.daocloud.io \
  ...
```

## 为什么 GitHub 侧不传

GitHub hosted runner 在海外，直连 `github.com` / `nodejs.org` 比绕道 DaoCloud 更快、更少一个故障点。CNB runner 在国内，直连 GitHub 容易超时，所以走 DaoCloud。

## 验证下载地址

```bash
# UPX
curl -sI https://files.m.daocloud.io/github.com/upx/upx/releases/download/v5.2.1/upx-5.2.1-amd64_linux.tar.xz | head -1

# nfpm
curl -sI https://files.m.daocloud.io/github.com/goreleaser/nfpm/releases/download/v2.48.0/nfpm_2.48.0_Linux_x86_64.tar.gz | head -1

# Node.js
curl -sI https://files.m.daocloud.io/nodejs.org/dist/v26.12.1/node-v26.12.1-linux-x64.tar.xz | head -1

# fnpack
curl -sI https://static2.fnnas.com/fnpack/fnpack-1.2.3-linux-amd64 | head -1
```

返回 `200` 即地址可用。换版本时把 URL 里的版本号一起改掉。

## 注意

- DaoCloud 是第三方代理，域名规则是 `<代理前缀>/<原域名>/<原路径>`。
- APT / Go / npm 使用腾讯云镜像，两侧相同，没有单独开关。
- fnpack 没有做镜像，直接访问 `static2.fnnas.com`；该站本身在国内，通常不需要代理。
- 如果 DaoCloud 某个路径 404，先用上面的 `curl` 验证原站是否仍提供该文件（可能只是版本号写错）。
