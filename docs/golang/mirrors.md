# 镜像源

## 一张表

| 依赖                               | GitHub Actions / GitLab CI      | CNB                                                    |
|------------------------------------|---------------------------------|--------------------------------------------------------|
| GitHub Release（UPX）              | 直连 `github.com`               | `https://files.m.daocloud.io/github.com/...`           |
| GitHub Release Atom（UPX 版本号）  | 直连 `github.com`               | `https://files.m.daocloud.io/github.com/...`（同域名） |
| Node.js 官方 tar.xz 与版本索引     | 直连 `nodejs.org`               | `https://files.m.daocloud.io/nodejs.org/...`           |
| nfpm 与各 Go 工具（`go install`）  | Go module（`proxy.golang.org`） | 腾讯 → goproxy.cn → goproxy.io → direct（见下文）      |
| fnpack                             | 直连 `static2.fnnas.com`        | 直连 `static2.fnnas.com`                               |
| wails3（`go install` 与版本解析）  | Go module（`proxy.golang.org`） | 腾讯 → goproxy.cn → goproxy.io → direct（见下文）      |
| wails2（`go install` 与版本解析）  | Go module（`proxy.golang.org`） | 腾讯 → goproxy.cn → goproxy.io → direct（见下文）      |
| fyne（`go install` 与版本解析）    | Go module（`proxy.golang.org`） | 腾讯 → goproxy.cn → goproxy.io → direct（见下文）      |
| mygo（`go install` 与版本解析）    | Go module（`proxy.golang.org`） | 腾讯 → goproxy.cn → goproxy.io → direct（见下文）      |
| gio（`go install` 与版本解析）     | Go module（`proxy.golang.org`） | 腾讯 → goproxy.cn → goproxy.io → direct（见下文）      |
| bun（`npm install -g` 与版本解析） | npm 官方 `registry.npmjs.org`   | `mirrors.cloud.tencent.com/npm/`                       |
| Debian APT                         | 默认 `deb.debian.org`           | `mirrors.cloud.tencent.com`                            |
| npm / pnpm registry                | 默认 `registry.npmjs.org`       | `mirrors.cloud.tencent.com/npm/`                       |

## 开关

CNB 的 Dockerfile 里有两个构建参数（GitHub / GitLab 侧没有，直接写死官方地址）：

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
| GitLab | `.gitlab/scripts/build-golang.sh` | 无参数（Dockerfile 直连）        |

fnpack 镜像只从 `https://static2.fnnas.com` 下载二进制，三个平台的 `build-fnpack.sh` 都不传镜像参数。

wails3 / wails2 / fyne / mygo / gio 镜像不新增开关：`go install` 与版本解析（`go list -m`）都走基座镜像的 `GOPROXY`，CNB 侧 `Dockerfile.golang` 已配成 Go module 多源回退，子镜像自动继承；GitHub / GitLab 侧用 Go 默认代理。三侧的 `build-wails3.sh` / `build-wails2.sh` / `build-fyne.sh` / `build-mygo.sh` / `build-gio.sh` 只把 `GOPROXY` 读出来传给解析用的一次性容器，保证「解析到的版本」和「实际安装的版本」用同一份 `GOPROXY` 配置。

mygo 的 `bun` 走 npm：`npm install -g` 与版本解析（`npm view bun version`）都用基座镜像的 npm registry，CNB 侧即腾讯云、GitHub / GitLab 侧即官方默认，两边天然一致，`build-mygo.sh` 不需要额外传源参数。

fyne 的 apt 开发包（OpenGL/X11/Wayland）、mygo 的 apt 开发包（GTK3/WebKitGTK 4.1 与无头运行库）与 gio 的 apt 开发包（EGL/GLES、X11、Wayland、Vulkan 与无头运行库）都不单独配源：继承基座镜像的 APT 配置，CNB 侧即腾讯云，GitHub / GitLab 侧即 `deb.debian.org`。

## 为什么 GitHub / GitLab 侧不传

GitHub hosted runner 与 GitLab.com 的 runner 都在海外，直连 `github.com` / `nodejs.org` 比绕道 DaoCloud 更快、更少一个故障点；npm / pnpm 同理用官方默认 `registry.npmjs.org`，APT 用 `deb.debian.org`，Go module 用 `proxy.golang.org`，都不设镜像。CNB runner 在国内，直连 GitHub 容易超时，所以走 DaoCloud，APT / npm 换腾讯云，Go module 用腾讯 + `goproxy.cn` + `goproxy.io` 多源回退（见下节）。

> 自建 GitLab runner 如果部署在国内，也可以按 CNB 的方式加镜像参数；但 GitLab 侧脚本目前不读 `GITHUB_MIRROR` / `NODE_MIRROR`，需要连同 Dockerfile 与脚本一起改。

## Go module proxy

- CNB 镜像（`.cnb/docker/Dockerfile.golang`）：

  ```dockerfile
  GOPROXY=https://mirrors.cloud.tencent.com/go/|https://goproxy.cn|https://goproxy.io|direct
  ```

  依次尝试腾讯源 → `goproxy.cn` → `goproxy.io` → `direct`（直连 VCS）。腾讯源偶发 `500 Internal Server Error` 时自动切下一源，不用等镜像恢复。
- **分隔符必须是 `|`，不要改回 `,`**：Go 的规则是「`,` 仅在 404 / 410 时回退下一源，`|` 在 5xx / 超时等任意错误时都回退」。实测首源恒定返回 500 时，逗号写法直接失败、竖线写法成功回退到 `goproxy.cn`。构建脚本从 Dockerfile 读出该值后以 `-e "GOPROXY=..."` 传入一次性解析容器，`|` 已被引号包住；改值时保持引号。
- `500` 不是「源没同步」：Go module proxy 按需回源，镜像站没有预同步列表，500 是镜像站后端临时故障。排障时分别 `curl` 三个源的同一个 `.mod`，对比哪个源异常（命令见下节）。
- GitHub / GitLab 镜像：不设置 `GOPROXY`，使用 Go 默认的 `https://proxy.golang.org,direct`。

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

# Go module proxy 三个源：同一模块的 .mod 应都返回 200，哪个返回 500 就是哪个源故障
for p in https://mirrors.cloud.tencent.com/go/ https://goproxy.cn https://goproxy.io; do
  curl -sS -o /dev/null -w "$p %{http_code}\n" "${p}github.com/qiniu/go-sdk/v7/@v/v7.30.0.mod"
done
```

返回 `200`（或前两条命令输出版本号）即地址可用。

## 注意

- DaoCloud 是第三方代理，域名规则是 `<代理前缀>/<原域名>/<原路径>`。
- npm registry 只有 CNB 侧用腾讯云，GitHub / GitLab 侧用官方默认 `registry.npmjs.org`；APT 同理用 `deb.debian.org`，GitHub / GitLab 侧的 Go module 用 `proxy.golang.org`。
- 改 `GOPROXY` 只改 CNB 侧的 `Dockerfile.golang`：GitHub / GitLab 侧刻意不设这一行，脚本 `read_env` 读不到值就不传 `-e GOPROXY=...`，一次性解析容器用 Go 默认代理。
- 三侧 `build-*.sh` 都从 Dockerfile 读出 `GOPROXY` 再原样传给解析容器，值里可以带 `|`；后续若拆成 shell 变量再拼接，务必保持引号，否则 `|` 会被引擎当成管道符。
- fnpack 没有做镜像，直接访问 `static2.fnnas.com`；该站本身在国内，通常不需要代理。
- 如果 DaoCloud 某个路径 404，先用上面的 `curl` 验证原站是否仍提供该文件（可能只是版本号写错）。
