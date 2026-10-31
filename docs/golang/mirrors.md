# 镜像源

## 一张表

| 依赖                              | GitHub Actions                   | CNB                                                    |
|-----------------------------------|----------------------------------|--------------------------------------------------------|
| GitHub Release（UPX）             | 直连 `github.com`                | `https://files.m.daocloud.io/github.com/...`           |
| GitHub Release Atom（UPX 版本号） | 直连 `github.com`                | `https://files.m.daocloud.io/github.com/...`（同域名） |
| Node.js 官方 tar.xz 与版本索引    | 直连 `nodejs.org`                | `https://files.m.daocloud.io/nodejs.org/...`           |
| nfpm 与各 Go 工具（`go install`） | Go module（`proxy.golang.org`）  | `mirrors.cloud.tencent.com/go/`                        |
| fnpack                            | 直连 `static2.fnnas.com`         | 直连 `static2.fnnas.com`                               |
| Debian APT                        | 默认 `deb.debian.org`            | `mirrors.cloud.tencent.com`                            |
| npm / pnpm registry               | `mirrors.cloud.tencent.com/npm/` | `mirrors.cloud.tencent.com/npm/`                       |

## 开关

CNB 的 Dockerfile 里有两个构建参数（GitHub 侧没有，直接写死官方地址）：

```dockerfile
ARG GITHUB_MIRROR=""
ARG NODE_MIRROR=""
```

为空时直连官方站；非空时按「代理站 + 域名」拼接：

```sh
GH="${GITHUB_MIRROR%/}/github.com"            # github.com
NODE_BASE="${NODE_MIRROR%/}/nodejs.org/dist"  # nodejs.org
```

基础镜像构建脚本的传参：

| 平台   | 构建脚本                          | 是否传镜像参数                   |
|--------|-----------------------------------|----------------------------------|
| CNB    | `.cnb/scripts/build-golang.sh`    | 传 `https://files.m.daocloud.io` |
| GitHub | `.github/scripts/build-golang.sh` | 无参数（Dockerfile 直连）        |

fnpack 镜像只从 `https://static2.fnnas.com` 下载二进制，两个平台的 `build-fnpack.sh` 都不传镜像参数。

## 为什么 GitHub 侧不传

GitHub hosted runner 在海外，直连 `github.com` / `nodejs.org` 比绕道 DaoCloud 更快、更少一个故障点。CNB runner 在国内，直连 GitHub 容易超时，所以走 DaoCloud。

## Go module proxy

- CNB 镜像：`GOPROXY=https://mirrors.cloud.tencent.com/go/,direct`。
- GitHub 镜像：不设置 `GOPROXY`，使用 Go 默认的 `https://proxy.golang.org,direct`。

## 验证下载地址

```bash
# UPX 最新版本号（releases.atom 第一个稳定 tag，返回如 v5.3.0）
curl -sL https://files.m.daocloud.io/github.com/upx/upx/releases.atom \
  | grep -oE 'releases/tag/v[0-9]+\.[0-9]+\.[0-9]+"' | head -1

# Node.js 最新稳定版（index.json 需过滤 -alpha / -rc 预发布）
curl -sL https://files.m.daocloud.io/nodejs.org/dist/index.json | jq -r '[.[] | select(.version | test("-") | not)][0].version'

# UPX / Node 的 tar.xz 下载地址（钉版本时把 URL 里的版本号一起改掉）
curl -sI https://files.m.daocloud.io/github.com/upx/upx/releases/download/v5.2.1/upx-5.2.1-amd64_linux.tar.xz | head -1
curl -sI https://files.m.daocloud.io/nodejs.org/dist/v26.12.1/node-v26.12.1-linux-x64.tar.xz | head -1

# fnpack（ARM 产物文件名是 arm，不是 arm64）
curl -sI https://static2.fnnas.com/fnpack/fnpack-1.2.3-linux-amd64 | head -1
curl -sI https://static2.fnnas.com/fnpack/fnpack-1.2.3-linux-arm | head -1
```

返回 `200`（或前两条命令输出版本号）即地址可用。

## 注意

- DaoCloud 是第三方代理，域名规则是 `<代理前缀>/<原域名>/<原路径>`。
- npm registry 两侧都用腾讯云；APT 与 Go module proxy 只有 CNB 侧用腾讯云，GitHub 侧用 Debian / Go 默认源。
- fnpack 没有做镜像，直接访问 `static2.fnnas.com`；该站本身在国内，通常不需要代理。
- 如果 DaoCloud 某个路径 404，先用上面的 `curl` 验证原站是否仍提供该文件（可能只是版本号写错）。
