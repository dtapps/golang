# Dockerfile 解析

三个平台各有一份实现，安装步骤与工具版本一致；镜像源按平台不同（GitHub / GitLab 用默认/直连，CNB 用腾讯云与 DaoCloud，并额外给 Go module 配了多源回退），这是三份文件的主要差异：

| 镜像   | CNB 侧                          | GitHub 侧                          | GitLab 侧                          |
|--------|---------------------------------|------------------------------------|------------------------------------|
| golang | `.cnb/docker/Dockerfile.golang` | `.github/docker/Dockerfile.golang` | `.gitlab/docker/Dockerfile.golang` |
| fnpack | `.cnb/docker/Dockerfile.fnpack` | `.github/docker/Dockerfile.fnpack` | `.gitlab/docker/Dockerfile.fnpack` |
| wails3 | `.cnb/docker/Dockerfile.wails3` | `.github/docker/Dockerfile.wails3` | `.gitlab/docker/Dockerfile.wails3` |
| wails2 | `.cnb/docker/Dockerfile.wails2` | `.github/docker/Dockerfile.wails2` | `.gitlab/docker/Dockerfile.wails2` |
| fyne   | `.cnb/docker/Dockerfile.fyne`   | `.github/docker/Dockerfile.fyne`   | `.gitlab/docker/Dockerfile.fyne`   |
| mygo   | `.cnb/docker/Dockerfile.mygo`   | `.github/docker/Dockerfile.mygo`   | `.gitlab/docker/Dockerfile.mygo`   |
| gio    | `.cnb/docker/Dockerfile.gio`    | `.github/docker/Dockerfile.gio`    | `.gitlab/docker/Dockerfile.gio`    |

## 1. golang 镜像

### 基座与元数据

```dockerfile
ARG GO_VERSION=1
ARG DEBIAN_VERSION=trixie
FROM golang:${GO_VERSION}-${DEBIAN_VERSION}
```

`GO_VERSION` 默认 `1`，即 `golang:1-trixie` 浮动标签，每次构建自动跟随最新稳定 Go（跨 minor 与大版本）；需要钉版本时填 `1.27` 或 `1.27.3`。实际 Go 版本由构建脚本解析后写进镜像标签。

构建阶段重新声明的 ARG：

| ARG              | 来源                  | 用途                                            |
|------------------|-----------------------|-------------------------------------------------|
| `GO_VERSION`     | 构建脚本 / 默认值     | 基座 Go 版本（默认 `1` = 浮动标签自动跟随最新） |
| `DEBIAN_VERSION` | 默认值                | 基座 Debian 代号（`trixie`）                    |
| `IMAGE_VERSION`  | 脚本                  | OCI `version`，等于解析出的 Go 版本             |
| `VCS_REF`        | 脚本                  | OCI `revision`                                  |
| `BUILD_DATE`     | 脚本                  | OCI `created`，取最后一次提交时间               |
| `BASE_DIGEST`    | 脚本                  | 上游 `golang:<版本>-<代号>` 的 digest           |
| `IMAGE_SOURCE`   | 脚本                  | OCI `source` / `url`                            |
| `GITHUB_MIRROR`  | CNB 脚本（仅 CNB 侧） | GitHub Release 下载前缀（含 releases.atom）     |
| `NODE_MIRROR`    | CNB 脚本（仅 CNB 侧） | nodejs.org 下载前缀                             |

### 镜像源开关

只有 CNB 侧声明 `GITHUB_MIRROR` / `NODE_MIRROR`，GitHub / GitLab 侧都没有这两个参数；为空时直连官方站，非空时按「代理站 + 域名」拼下载地址：

```sh
if [ -n "${GITHUB_MIRROR}" ]; then
  GH="${GITHUB_MIRROR%/}/github.com"
else
  GH="https://github.com"
fi
if [ -n "${NODE_MIRROR}" ]; then NODE_BASE="${NODE_MIRROR%/}/nodejs.org/dist"; else NODE_BASE="https://nodejs.org/dist"; fi
```

- GitHub / GitLab 侧：没有这两个参数，固定直连 `https://github.com` 与 `https://nodejs.org/dist`。
- CNB 侧：传 `https://files.m.daocloud.io`，实际下载走 `https://files.m.daocloud.io/github.com/...` 与 `https://files.m.daocloud.io/nodejs.org/...`（UPX 取版本用的 `releases.atom` 也在 `github.com` 路径下，同样被镜像）。

### 安装顺序

1. **环境变量**：Go 侧 CNB 的 `GOPROXY` 为 `https://mirrors.cloud.tencent.com/go/|https://goproxy.cn|https://goproxy.io|direct`（`|` 分隔，5xx / 超时也会回退下一源，完整说明见 [mirrors.md](mirrors.md)）、GitHub / GitLab 不设置（用默认代理）；`GOPATH=/go`，`PATH` 加入 `/go/bin`。另有 `TZ=Asia/Shanghai`、`LANG=C.UTF-8`、`LC_ALL=C.UTF-8`：容器内统一北京时间与 UTF-8，构建日志、`go build` 产物里的时间戳才对得上。
2. **基础包**：wget、xz-utils（`tar -Jf` 解压 UPX / Node 的 `.tar.xz`）、zstd（`tar --zstd` 处理 `.tar.zst`，当前无调用，先预留）、ca-certificates、curl、gnupg、git、make、build-essential / libc6-dev（显式钉住 gcc / g++ / make / libc6-dev 这套 cgo 工具链，不依赖上游 golang 镜像的内部实现；libc6-dev 与元包重复，显式声明、apt 幂等）、jq（jq 同时用于版本解析）、zip、unzip、pkg-config（打包/解压/cgo）、dpkg-dev（`dpkg-buildpackage` / `dpkg-architecture` 等从源码构建 `.deb` 的工具，nfpm 不需要，先预留）、fakeroot / desktop-file-utils（`debuild` / `dpkg-buildpackage -rfakeroot` 与 `.desktop` 校验注册，先预留）、file / patchelf / chrpath / lintian / rpm（打包工具：ELF 修正、rpath 调整、`.deb` 规范检查与 RPM 打包），以及 **tzdata**——配合上面的 `TZ`：装完 `ln -snf /usr/share/zoneinfo/$TZ /etc/localtime`、写 `/etc/timezone`，再 `date` 打一行日志确认（构建日志里应看到 `CST`）。同一层还装 **wixl / wixl-data**（msitools）：在 Linux 上直接编译 Windows MSI 安装包，不必依赖 Windows 端的 WiX；装完 `wixl --version` 打一行日志确认。包清单统一放在 `apt_packages` 变量里，装完再 `dpkg-query -W ${apt_packages}` 打印每个 deb 的实际版本（输出「包名<TAB>版本」）——各变体镜像的 apt 安装块同理，日志里就能直接核对版本，不用进容器查。
3. **UPX**：`UPX_VERSION=latest` 时从 `releases.atom` 取第一个稳定 tag（grep 锚定 href 行尾引号，天然跳过 `-beta` / `-rc` 预发布；不走 api.github.com，免认证且无限速），再按 `uname -m` 选 amd64/arm64 下载 tar.xz，装到 `/usr/local/bin/upx`。
4. **Node.js**：`NODE_VERSION=latest` 时从 `dist/index.json` 取第一个非预发布版本（过滤 `-alpha` / `-rc`），下载官方 tar.xz 解压到 `/usr/local`；GitHub / GitLab 侧不配置 registry（npm / pnpm 用官方默认 `registry.npmjs.org`），CNB 侧才用腾讯云；三侧都设 `pnpm config set ignore-scripts false`。
5. **Go 工具链（含 nfpm）**：按职责分成 5 层（打包与代码生成 nfpm+sqlc / 实体生成 ent+entc / 质量与安全 golangci-lint+govulncheck / 格式化与数据处理 shfmt+dockerfmt+yamlfmt+gojq+markdownfmt+sql-formatter / 测试与覆盖率报告 gotestsum+gocover-cobertura+gcov2lcov）。**有官方二进制的先下载二进制**（`install-tool`），失败才回退 `go install -v`（见下一节）；每层都挂 BuildKit 缓存目录：
   - `--mount=type=cache,target=/go/pkg/mod`：模块缓存
   - `--mount=type=cache,target=/root/.cache/go-build`：编译缓存

   缓存挂载不进镜像层，所以不再需要「同一层内 `rm -rf /go/pkg/mod`」那种清理；拆层是为了让某个工具发版时只重建它自己那一层。`-v` 只是让日志可读，不影响产物；`build-golang.sh` 的 `dockerfile_tool_vars` 用 `grep -o 'go install[^@;]*@${VAR}'` 提取版本变量，所以这里在 `go install` 与包路径之间再加别的 flag 也不会漏检。
6. **清理**：保留 `wget` / `xz-utils` 等基础工具，不做 purge；末尾一层统一 `apt-get autoremove` / `apt-get clean`，并清掉 `/var/lib/apt/lists/*`、`/tmp`、`/root/.npm`。
7. **OCI 元数据标签**：放在文件最后。`BUILD_DATE` / `VCS_REF` / `IMAGE_VERSION` 每次都变，放前面会让 apt、Node、`go install` 这些层的缓存键跟着每次提交一起变。

> 所有 `echo` 都带 `[${TARGETPLATFORM:-unknown}]` 前缀（BuildKit 自动提供的目标平台，需要在 stage 里 `ARG TARGETPLATFORM` 声明才能进 `RUN` 的环境）：`buildx` 多架构构建时同一个 `RUN` 会按 `linux/amd64`、`linux/arm64` 各跑一遍，日志里连着出现两遍「--- UPX 安装的 ---」是正常的，前缀能直接看出当前是哪一架构、不是重复安装。用旧版非 BuildKit 的 `docker build` 时显示 `unknown`。

> CNB 侧会在安装基础包之前把 APT 源换成 `mirrors.cloud.tencent.com`；GitHub / GitLab 侧不换源。

> 清理必须与安装同层：跨层 `rm` 只会产生 whiteout，旧层数据仍会随镜像分发；末尾那一层只是对各安装层已清过的缓存再兜一次底，不承担卸载。

### 按类别补齐的系统包

各镜像在核心开发包之外，还按下表统一补齐了打包、无头测试、运行期与桌面集成相关系统包（三侧 `Dockerfile.*` 的 `apt_packages` 清单一致；`gio` 的无头测试包原本已具备，不重复添加）：

| 类别        | 包名                                                           | 适用镜像                            |
|-------------|----------------------------------------------------------------|-------------------------------------|
| 打包工具    | `file` `patchelf` `chrpath` `lintian` `rpm`                    | Golang 基础                         |
| CI 无头测试 | `xvfb` `xauth` `dbus-x11`                                      | Fyne / Gio / Mygo / Wails2 / Wails3 |
| GL 运行时   | `libgl1` `libgl1-mesa-dri` `libglx-mesa0` `libegl-mesa0`       | Fyne / Mygo / Wails2 / Wails3       |
| WebKit TLS  | `libnss3` `libnspr4` `glib-networking`                         | Mygo / Wails2 / Wails3              |
| 图标 / 图片 | `librsvg2-common` `libgdk-pixbuf-2.0-dev` `adwaita-icon-theme` | Mygo / Wails2 / Wails3              |
| 字体        | `fonts-dejavu-core`                                            | Fyne / Mygo / Wails2 / Wails3       |
| 系统功能    | `libsecret-1-dev` `libnotify-dev` `libdbus-1-dev`              | Mygo / Wails2 / Wails3              |
| 文字渲染    | `libharfbuzz-dev` `libpango1.0-dev`                            | Mygo / Wails2 / Wails3              |

### 二进制优先，go install 兜底

`go install` 每次都要编译，慢且吃 CPU。有官方 Release 二进制的工具改成**先下载**，拿不到再回退编译：

```dockerfile
COPY --chmod=0755 .cnb/docker/install-tool.sh /usr/local/bin/install-tool
...
    install-tool nfpm "${NFPM_VERSION}" \
    || go install -v github.com/goreleaser/nfpm/v2/cmd/nfpm@${NFPM_VERSION};
```

`install-tool` 的行为：

- 只认具体版本号：传 `latest`（解析失败时的兜底）直接返回非 0，交给 `go install @latest` 自己解析；
- 按 `uname -m` 选 amd64 / arm64；
- 下载顺序 **DaoCloud 镜像（`GITHUB_MIRROR`）→ `https://github.com`**，任一次成功即停；两次都失败才返回非 0。GitHub / GitLab 侧没有 `GITHUB_MIRROR`，直接走官方源；
- 解包支持两种形态：`tar.gz`（含嵌套目录，如 golangci-lint 的 `golangci-lint-2.x-linux-amd64/`）和裸二进制（shfmt）；解压后按工具名在目录树里找可执行文件；
- 装到 `/usr/local/bin`，`go install` 装到 `/go/bin`，两者都在 `PATH` 里，冒烟断言不用改。

各仓库资产命名互不相同，`install-tool.sh` 里按工具列了一张表（升级版本不用改它，新增工具要加一行）：

| 工具          | 仓库                      | 资产名（`<ver>` 不含前缀 v）                     |
|---------------|---------------------------|--------------------------------------------------|
| nfpm          | goreleaser/nfpm           | `nfpm_<ver>_Linux_{arm64,x86_64}.tar.gz`         |
| sqlc          | sqlc-dev/sqlc             | `sqlc_<ver>_linux_{arm64,amd64}.tar.gz`          |
| golangci-lint | golangci/golangci-lint    | `golangci-lint-<ver>-linux-{arm64,amd64}.tar.gz` |
| shfmt         | mvdan/sh                  | `shfmt_v<ver>_linux_{arm64,amd64}`（裸二进制）   |
| dockerfmt     | reteps/dockerfmt          | `dockerfmt-v<ver>-linux-{arm64,amd64}.tar.gz`    |
| yamlfmt       | google/yamlfmt            | `yamlfmt_<ver>_Linux_{arm64,x86_64}.tar.gz`      |
| gojq          | itchyny/gojq              | `gojq_v<ver>_linux_{arm64,amd64}.tar.gz`         |
| sql-formatter | wasilibs/go-sql-formatter | `sql-formatter_<ver>_linux_{arm64,amd64}.tar.gz` |
| gotestsum     | gotestyourself/gotestsum  | `gotestsum_<ver>_linux_{arm64,amd64}.tar.gz`     |
| gcov2lcov     | jandelgado/gcov2lcov      | `gcov2lcov_<ver>_linux_{arm64,amd64}.tar.gz`     |

没有官方二进制、只能 `go install` 的（都已核实 latest release 资产数为 0）：`ent` / `entc`、`govulncheck`、`markdownfmt`、`gocover-cobertura`，以及变体镜像里的 `wails`（wailsapp/wails v2）、`wails3`（v3）、`fyne`（fyne-io/tools）、`gogio`（gioui/gio）、`mygo`（egoist/mygo）。

三份 `install-tool.sh`（`.cnb/`、`.github/`、`.gitlab/` 各一份）内容必须一致，由 `make format-shell` / `make lint-shell` 一并检查。

### 版本变量

所有工具 `ARG` 默认 `latest`，但 **CI 不会把 `latest` 传进来**：三份 `build-golang.sh` 会先在基础镜像里把 `latest` 解析成具体版本号（如 `v1.31.1`），再以 `--build-arg` 传入。

原因是层缓存按 build-arg 的「值」算缓存键：每天都传字符串 `latest`，缓存键永远不变，层会一直命中第一次构建的产物，工具就再也不会升级。解析后传具体版本号，才能做到「没发新版全命中、发新版只重建那一层」。

`latest` 默认值只用于不经过 CI 的裸 `docker build`，此时由 Dockerfile 在构建时自行解析（行为和以前一致，只是没有缓存收益）。出现问题时用 `--build-arg`（或改默认值）钉回具体版本：

| ARG                         | 默认值   | 对应工具                  | latest 的解析渠道                           |
|-----------------------------|----------|---------------------------|---------------------------------------------|
| `UPX_VERSION`               | `latest` | UPX                       | `releases.atom` 第一个稳定 tag              |
| `NODE_VERSION`              | `latest` | Node.js                   | `dist/index.json` 第一个非预发布版本        |
| `NFPM_VERSION`              | `latest` | nfpm                      | `go install @latest`（钉版本格式 `vX.Y.Z`） |
| `PNPM_VERSION`              | `latest` | pnpm                      | npm registry 的 `pnpm@latest`               |
| `SQLC_VERSION`              | `latest` | sqlc                      | `go install @latest`                        |
| `ENT_VERSION`               | `latest` | ent / entc                | 同上                                        |
| `GOLANGCI_LINT_VERSION`     | `latest` | golangci-lint             | 同上                                        |
| `GOVULNCHECK_VERSION`       | `latest` | govulncheck               | 同上                                        |
| `SHFMT_VERSION`             | `latest` | shfmt                     | 同上                                        |
| `DOCKERFMT_VERSION`         | `latest` | dockerfmt                 | 同上                                        |
| `YAMLFMT_VERSION`           | `latest` | yamlfmt                   | 同上                                        |
| `GOJQ_VERSION`              | `latest` | gojq                      | 同上                                        |
| `GOSQLFORMATTER_VERSION`    | `latest` | wasilibs/go-sql-formatter | 同上                                        |
| `GOTESTSUM_VERSION`         | `latest` | gotestsum                 | 同上                                        |
| `MARKDOWNFMT_VERSION`       | `latest` | markdownfmt               | 同上                                        |
| `GOCOVER_COBERTURA_VERSION` | `latest` | gocover-cobertura         | `go install @latest`                        |
| `GCOV2LCOV_VERSION`         | `latest` | gcov2lcov                 | `go install @latest`                        |

`go install @latest` 走模块路径解析：各工具的模块路径带 `/v2`、`/v3` 等后缀，latest 不会自动跨 major；major 升级需要改 Dockerfile 里的模块路径。

## 2. fnpack 镜像

```dockerfile
ARG GOLANG_IMAGE=golang:1-trixie
FROM ${GOLANG_IMAGE}
```

- CI 里 `GOLANG_IMAGE` 是上一步刚推好的 `<registry>/<repo>:<go 版本>`，所以 fnpack 镜像只多一层。
- 单独构建本文件时默认用上游 `golang:1-trixie`，此时镜像里**没有**本仓库预装的 UPX / nfpm / Node / Go 工具，只用于验证 fnpack 下载本身。
- fnpack 版本由 `ARG FNPACK_VERSION` 控制，下载地址如下（`<arch>` 为 `amd64` 或 `arm`，ARM 用 `arm` 而不是 `arm64`）：

```text
https://static2.fnnas.com/fnpack/fnpack-<版本>-linux-<arch>
```

- 安装后用 `fnpack --help` 做一次执行探测（部分版本 `--help` 返回非 0，故失败不阻断构建）。
- OCI `base.name` 记录 `GOLANG_IMAGE`，`base.digest` 记录基础镜像的 index digest。

## 3. wails3 镜像

```dockerfile
ARG GOLANG_IMAGE=golang:1-trixie
FROM ${GOLANG_IMAGE}
```

- 与 fnpack 同构：`GOLANG_IMAGE` 由 CI 指向上一步刚推好的 `<registry>/<repo>:<go 版本>`，只多两层（apt 装 GTK4/WebKitGTK + `go install` wails3）。
- apt 与 `GOPROXY` 都继承基座镜像：CNB 侧的 `Dockerfile.golang` 已配成 Go module 多源回退（腾讯 → goproxy.cn → goproxy.io → direct），所以三个平台的这个文件里都没有 `GITHUB_MIRROR` / `NODE_MIRROR` 开关。
- 安装的开发包：`zip`、`unzip`、`pkg-config`、`libgtk-4-dev`、`libwebkitgtk-6.0-dev`、`libglib2.0-dev`、`libsoup-3.0-dev`、`libepoxy-dev`、`libgraphene-1.0-dev`、`libayatana-appindicator3-dev`（中间四个补齐 GTK4 / WebKitGTK 6.0 底层编译依赖，最后一个用于系统托盘）；装完立刻 `pkg-config --exists gtk4` / `webkitgtk-6.0` / `glib-2.0` / `libsoup-3.0` / `epoxy` / `graphene-1.0` / `ayatana-appindicator3-0.1` 断言，避免把问题推迟到使用者手里（这些包必须留在镜像里，它们就是镜像的用途）。
- wails3 版本由 `ARG WAILS3_VERSION` 控制，默认 `latest`（不再钉死某个 tag）；CI 会先解析成 `v3.1.0` 这种具体版本再传进来。安装命令：

```dockerfile
go install "github.com/wailsapp/wails/v3/cmd/wails3@${WAILS3_VERSION}"
```

- `wails3` 落在 `${GOPATH}/bin`（`/go/bin`，已在 `PATH` 中），`test -x` + `wails3 version` 做安装验证。
- `--mount=type=cache` 挂模块与编译缓存：`go install` 要编译整个 CLI，冷缓存下这一层是耗时大头。

## 4. wails2 镜像

与 wails3 同构，只换开发包与 CLI：apt 装 `libgtk-3-dev`、`libwebkit2gtk-4.1-dev`，装完 `pkg-config --exists gtk+-3.0` 与 `webkit2gtk-4.1` 断言；版本由 `ARG WAILS2_VERSION` 控制（默认 `latest`，CI 解析成 `v2.17.1` 这种具体 tag），安装命令：

```dockerfile
go install "github.com/wailsapp/wails/v2/cmd/wails@${WAILS2_VERSION}"
```

`wails` 落在 `${GOPATH}/bin`。注意 trixie 已移除 `libwebkit2gtk-4.0-dev`，所以用 Wails v2 编译应用时要带 `-tags webkit2_41`，细节见 [../wails2/README.md](../wails2/README.md)。

## 5. fyne 镜像

```dockerfile
ARG GOLANG_IMAGE=golang:1-trixie
FROM ${GOLANG_IMAGE}
```

- 与 wails3 同构：`GOLANG_IMAGE` 由 CI 指向上一步刚推好的 `<registry>/<repo>:<go 版本>`，只多两层（apt 装 OpenGL/X11/Wayland 开发包 + `go install` fyne）。
- apt 与 `GOPROXY` 都继承基座镜像：CNB 侧的 `Dockerfile.golang` 已配成 Go module 多源回退（腾讯 → goproxy.cn → goproxy.io → direct），所以三个平台的这个文件里都没有 `GITHUB_MIRROR` / `NODE_MIRROR` 开关。
- 安装的开发包照搬官方文档给 Debian / Ubuntu / Raspberry Pi OS 的那一条（`golang` 除外，基座已是 Go 镜像）：`gcc`、`libgl1-mesa-dev`、`xorg-dev`、`libwayland-dev`、`libxkbcommon-dev`。装完立刻断言以下 `.pc` 都能解析，避免问题以 cgo 报错的形式推迟到使用者手里：

  ```sh
  pkg-config --exists gl
  pkg-config --exists x11
  pkg-config --exists xrandr
  pkg-config --exists xcursor
  pkg-config --exists xinerama
  pkg-config --exists xi
  pkg-config --exists xxf86vm
  pkg-config --exists wayland-client
  pkg-config --exists xkbcommon
  ```

  这些包是镜像的用途本身，必须留在镜像里：编译 Fyne 应用要开 cgo 并链接 GL / X11 / Wayland。
- fyne **CLI** 版本由 `ARG FYNE_VERSION` 控制，默认 `latest`（不再钉死某个 tag）；CI 会先解析成 `v1.7.4` 这种具体版本再传进来。安装命令：

  ```dockerfile
  go install -v "fyne.io/tools/cmd/fyne@${FYNE_VERSION}"
  ```

- 注意上游把 `fyne.io/tools` 的 `v1.26.0` / `v1.26.1` 标了 retract（误发），不要当成新版本。
- `fyne` 落在 `${GOPATH}/bin`（`/go/bin`，已在 `PATH` 中），`test -x` + `fyne version` 做安装验证。
- `--mount=type=cache` 挂模块与编译缓存：`go install` 要编译整个 CLI，冷缓存下这一层是耗时大头。

## 6. mygo 镜像

```dockerfile
ARG GOLANG_IMAGE=golang:1-trixie
FROM ${GOLANG_IMAGE}
```

- 与 fyne 同构：`GOLANG_IMAGE` 由 CI 指向上一步刚推好的 `<registry>/<repo>:<go 版本>`，多三层（apt 装 GTK3/WebKitGTK 4.1 开发包与无头运行库 → `go install` mygo → npm 装 bun）。
- apt 与 `GOPROXY` 都继承基座镜像：CNB 侧的 `Dockerfile.golang` 已配成 Go module 多源回退（腾讯 → goproxy.cn → goproxy.io → direct），所以三个平台的这个文件里都没有 `GITHUB_MIRROR` / `NODE_MIRROR` 开关。
- 安装的包分两组：
  - 编译 / 运行库：`pkg-config`、`gcc`、`libgtk-3-dev`、`libwebkit2gtk-4.1-dev`、`libayatana-appindicator3-dev`、`libgl1-mesa-dev`、`xorg-dev`、`libwayland-dev`、`libxkbcommon-dev`
  - 无头运行环境：`xvfb`、`xauth`、`dbus-x11`、`libgl1`、`libgl1-mesa-dri`、`libglx-mesa0`、`libegl-mesa0`、`fonts-dejavu-core`（与上游 mygo 的 CI 同一组包）

  装完立刻断言 `.pc` 与运行库都在：

  ```sh
  pkg-config --exists gtk+-3.0
  pkg-config --exists webkit2gtk-4.1
  pkg-config --exists gl
  pkg-config --exists x11
  pkg-config --exists xrandr
  pkg-config --exists xcursor
  pkg-config --exists xinerama
  pkg-config --exists xi
  pkg-config --exists xxf86vm
  pkg-config --exists wayland-client
  pkg-config --exists xkbcommon
  ldconfig -p | grep -q 'libgtk-3\.so\.0'
  ldconfig -p | grep -q 'libwebkit2gtk-4\.1\.so'
  ldconfig -p | grep -q 'libayatana-appindicator3\.so\.1'
  ```

  与 fyne / wails 的区别在于：mygo 的 Linux 后端是**纯 Go、不带 cgo**，它用 `github.com/ebitengine/purego` 在运行期 `dlopen` GTK3 / WebKitGTK。所以 `-dev` 包在这里有两个作用——(a) 顺带装上运行期要加载的 `.so`，(b) 用户应用若自带 cgo 绑定，编译期能解析 `.pc` 与头文件。这些包是镜像的用途本身，必须留在镜像里。
- mygo **CLI** 版本由 `ARG MYGO_VERSION` 控制，默认 `latest`；CI 会先解析成 `v0.8.1` 这种具体版本再传进来。安装命令：

  ```dockerfile
  go install -v "github.com/egoist/mygo/cmd/mygo@${MYGO_VERSION}"
  ```

- `bun` 版本由 `ARG BUN_VERSION` 控制，默认 `latest`；CI 会先从 npm 解析成 `1.4.4` 这种具体版本再传进来。安装命令：

  ```dockerfile
  npm install -g --no-fund --no-audit "bun@${BUN_VERSION}"
  ```

  bun 对 mygo 自己是可选的，但 `mygo init` 默认 Web 前端模板的 `DevCommand` / `BuildCommand` 就是 `bun run ...`，装它是为了让默认模板开箱即用。走 npm 装是因为基座把 `wget` 清掉了、`GITHUB_MIRROR` 也只对基座自身生效，下载 GitHub Release 不可行。
- `mygo` 落在 `${GOPATH}/bin`（`/go/bin`，已在 `PATH` 中），`test -x` + `mygo version` 做安装验证。
- 两个 `--mount=type=cache` 分别挂 Go 模块 / 编译缓存与 npm 缓存：冷缓存下这两层是耗时大头。
- OCI 元数据标签放在最后：`BUILD_DATE` / `VCS_REF` / `IMAGE_VERSION` 每次构建都变，放前面会让 apt、`go install`、npm 三层的缓存键跟着每次提交一起失效。

## 7. gio 镜像

```dockerfile
ARG GOLANG_IMAGE=golang:1-trixie
FROM ${GOLANG_IMAGE}
```

- 与 fyne / mygo 同构：`GOLANG_IMAGE` 由 CI 指向上一步刚推好的 `<registry>/<repo>:<go 版本>`，多三层（apt 装 EGL/GLES、X11、Wayland、Vulkan 开发包与无头运行库 → `go install` gogio → 真实编译一个最小 Gio 程序做校验）。
- apt 与 `GOPROXY` 都继承基座镜像：CNB 侧的 `Dockerfile.golang` 已配成 Go module 多源回退（腾讯 → goproxy.cn → goproxy.io → direct），所以三个平台的这个文件里都没有 `GITHUB_MIRROR` / `NODE_MIRROR` 开关。
- **变体名叫 gio，CLI 却叫 `gogio`**（模块 `gioui.org/cmd`），镜像里没有 `gio` 这个二进制。`gogio` 是打包工具（android / ios / tvos / js / windows / macos），**没有 linux 目标**，也**没有 `version` 子命令**；Linux 桌面程序就是普通 `go build` + cgo。所以这个镜像的重点不是 `gogio` 本身，而是 cgo 依赖齐全。
- 安装的包分两组：
  - 编译 / 运行库：`pkg-config`、`gcc`、`libegl1-mesa-dev`、`libgles2-mesa-dev`、`libx11-dev`、`libx11-xcb-dev`、`libxcursor-dev`、`libxfixes-dev`、`libxrandr-dev`、`libxinerama-dev`、`libxi-dev`、`libxxf86vm-dev`、`libwayland-dev`、`libxkbcommon-dev`、`libxkbcommon-x11-dev`、`libffi-dev`、`libvulkan-dev`
  - 无头运行环境：`xvfb`、`xauth`、`dbus-x11`、`libgl1-mesa-dri`、`libglx-mesa0`、`libegl-mesa0`、`mesa-vulkan-drivers`、`fonts-dejavu-core`

  装完立刻断言 `.pc` 与运行库都在：

  ```sh
  pkg-config --exists egl
  pkg-config --exists glesv2
  pkg-config --exists wayland-client
  pkg-config --exists wayland-cursor
  pkg-config --exists wayland-egl
  pkg-config --exists x11
  pkg-config --exists x11-xcb
  pkg-config --exists xkbcommon
  pkg-config --exists xkbcommon-x11
  pkg-config --exists xcursor
  pkg-config --exists xfixes
  pkg-config --exists xrandr
  pkg-config --exists xinerama
  pkg-config --exists xi
  pkg-config --exists xxf86vm
  pkg-config --exists libffi
  pkg-config --exists vulkan
  ldconfig -p | grep -q 'libEGL\.so\.1'
  ldconfig -p | grep -q 'libGL\.so\.1'
  ldconfig -p | grep -q 'libvulkan\.so\.1'
  ldconfig -p | grep -q 'libwayland-client\.so\.0'
  ldconfig -p | grep -q 'libxkbcommon\.so\.0'
  ldconfig -p | grep -q 'libX11\.so\.6'
  ```

  这些 `-dev` 包既是编译依赖也是运行依赖（`-dev` 会把运行库一起装上），是镜像的用途本身，必须留在镜像里。
- gogio **CLI** 版本由 `ARG GIO_VERSION` 控制（模块 `gioui.org/cmd`），默认 `latest`；CI 会先解析成 `v0.10.3` 这种具体版本再传进来。安装命令：

  ```dockerfile
  go install -v "gioui.org/cmd/gogio@${GIO_VERSION}"
  ```

- `gogio` 落在 `${GOPATH}/bin`（`/go/bin`，已在 `PATH` 中），`test -x` 做安装验证；**不要**用 `gogio version` 验证（没有这个子命令），无参数运行会打 usage 到 stderr 且非零退出。
- `--mount=type=cache` 挂 Go 模块与编译缓存：冷缓存下 `go install` 是耗时大头。
- OCI 元数据标签放在最后：`BUILD_DATE` / `VCS_REF` / `IMAGE_VERSION` 每次构建都变，放前面会让 apt 与 `go install` 两层的缓存键跟着每次提交一起失效。

## 8. 改哪个文件

| 要改的东西         | 改哪里                                                                                                                                                                |
|--------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Go 基座版本        | 三份 `Dockerfile.golang` 的 `GO_VERSION`（默认 `1` = 自动跟随最新）                                                                                                   |
| 某个工具版本       | 三份 `Dockerfile.golang` 的对应 `ARG`（默认 `latest` = 自动追新）                                                                                                     |
| fnpack 版本        | 三份 `Dockerfile.fnpack` 的 `FNPACK_VERSION`（默认值，可被手动触发的 `fnpack_version` 覆盖）                                                                          |
| wails3 版本        | 三份 `Dockerfile.wails3` 的 `WAILS3_VERSION`（默认 `latest`，可被 `wails3_version` 覆盖）                                                                             |
| wails2 版本        | 三份 `Dockerfile.wails2` 的 `WAILS2_VERSION`（默认 `latest`，可被 `wails2_version` 覆盖）                                                                             |
| fyne 版本          | 三份 `Dockerfile.fyne` 的 `FYNE_VERSION`（默认 `latest`，可被 `fyne_version` 覆盖）                                                                                   |
| mygo 版本          | 三份 `Dockerfile.mygo` 的 `MYGO_VERSION`（默认 `latest`，可被 `mygo_version` 覆盖）                                                                                   |
| bun 版本           | 三份 `Dockerfile.mygo` 的 `BUN_VERSION`（默认 `latest`，可被 `bun_version` 覆盖）                                                                                     |
| gogio 版本         | 三份 `Dockerfile.gio` 的 `GIO_VERSION`（默认 `latest`，可被 `gio_version` 覆盖）                                                                                      |
| 下载源             | 构建脚本的 `MIRROR` / 构建参数                                                                                                                                        |
| 标签规则、冒烟断言 | 三份 `build-golang.sh` + 三份 `build-fnpack.sh` + 三份 `build-wails3.sh` + 三份 `build-wails2.sh` + 三份 `build-fyne.sh` + 三份 `build-mygo.sh` + 三份 `build-gio.sh` |
