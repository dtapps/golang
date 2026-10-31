# 安全说明

本仓库是一个自建镜像仓库，目前包含两个镜像：

- `golang`：基于官方 `golang:1.27.3-trixie`，增加 UPX、nfpm、Node.js/pnpm 与常用 Go 工具。
- `golang/fnpack`：在上面的镜像上加一个 `fnpack` 二进制。

两者都没有业务代码，也没有自研二进制。

## 支持范围

| 标签                            | 说明                                           |
|---------------------------------|------------------------------------------------|
| `<go 版本>`（如 `1.27.3`）      | 版本标签：每次构建推送，同名标签每天可能被覆盖 |
| `<major.minor>`（如 `1.27`）    | 该 minor 的最新一次成功构建                    |
| `latest`                        | 最近一次成功构建                               |
| `<go 版本>-linux-{amd64,arm64}` | 单平台标签，从同一份 manifest 派生             |

两个镜像的标签合同相同，但更新是分两步的：先构建并发布 `golang`，再以它为基座构建 `golang/fnpack`。`fnpack` 的 `<major.minor>` / `latest` 只有在 `golang` 的同一标签已经指向本次版本时才会提升，因此不会出现「fnpack 已更新、基座还是旧版」的错位。

固定产物请用 annotation 里的 digest，而不是标签：

```bash
docker pull ghcr.io/dtapps/golang@sha256:<golang_digest>
docker pull ghcr.io/dtapps/golang/fnpack@sha256:<fnpack_digest>
```

## 补丁节奏

- 每天自动重建一次，分两段：`golang`（CNB 00:05、GitHub 16:35 UTC）构建完成后，再构建 `golang/fnpack`。CNB 侧固定错开一小时（01:05），GitHub 侧由 `build-golang` 成功后通过 `workflow_run` 触发。
- 每次重建都会重新拉取上游基座、重新下载依赖，因此上游重新推送同一 tag 时的安全修复能进入镜像。
- Go 版本由 Dockerfile 的 `GO_VERSION` 钉住；不会自动跨 minor 升级，需要手动改版本或手动触发时填 `version`。
- 工具版本（UPX、nfpm、Node、pnpm、九个 Go 工具、fnpack）同样在 Dockerfile 里钉住，升级需要提交变更。

## 信任面

| 来源                                 | 用途                                      |
|--------------------------------------|-------------------------------------------|
| Docker Hub `golang:1.27.3-trixie`    | 基础镜像                                  |
| `github.com` / `files.m.daocloud.io` | UPX、nfpm 的 GitHub Release               |
| `nodejs.org` / `files.m.daocloud.io` | Node.js 官方 tar.xz                       |
| `static2.fnnas.com`                  | fnpack 二进制                             |
| `mirrors.cloud.tencent.com`          | Debian APT、Go module proxy、npm registry |
| `cnbcool/annotations:latest`         | 写 commit 元数据的 CI 插件                |

GitHub 侧直连官方站；CNB 侧的 GitHub Release 与 nodejs.org 走 DaoCloud 代理。代理站本身也是供应链的一部分。

## 可复现性

- 同一 digest = 同一份产物（按 `@sha256:...` 拉取）。
- 每次构建都能回查，元数据按镜像分开写：
  - `golang`：`.cnb/annotation.json` / `.github/annotation.json`，含 `golang_digest`、`base_image`、`base_digest`、`built_at`。
  - `golang/fnpack`：`.cnb/annotation-fnpack.json` / `.github/annotation-fnpack.json`，含 `fnpack_digest`、`fnpack_base_image`、`fnpack_base_digest`、`built_at`。
- 标签会随重建前移，不能作为固定点；也不承诺「同样的命令每次都产出相同的字节」。
- 构建默认不启用层缓存，每日任务会真的重新拉取依赖。

## 已知取舍

- **以 root 运行**：作为构建环境，不创建非 root 用户；生产运行镜像请自行降权。
- **镜像体积较大**：包含完整 Go 工具链、Node.js 与 Debian 构建依赖，换取「进容器即可构建」。没有按需拆分。
- **`GOINSECURE=go.dtapp.net`**：只关闭该域名的 TLS 校验，不代替私有模块认证。需要认证时自行配置 `GOPRIVATE` / `.netrc`。
- **CI 插件未固定版本**：`imports` 指向组织仓库 `main`，`cnbcool/annotations` 用 `:latest`，这两处无法在本仓库内固定。发现行为变化时先看流水线日志。
- **fnpack 无签名校验**：直接下载官方站二进制并 `chmod +x`，未做 checksum/signature 校验；如需更强保证，请在 Dockerfile 里增加校验步骤。

## 报告漏洞

敏感问题请邮件联系维护者 `li.gc@icloud.com`（与 git 提交记录中的作者邮箱一致），标题前缀 `[security] dtapp/golang`。在修复发布前请不要公开细节。

如果是上游依赖（Go、Debian 包、Node、fnpack 等）的 CVE：

- 上游已修复：重新触发构建即可；
- 本镜像未跟上上游：开 issue 提醒，附上上游公告链接。
