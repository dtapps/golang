# 维护

## 日常构建

- CNB：每天 00:05（Asia/Shanghai）构建 golang 基础镜像，03:05 构建 fnpack 镜像，06:05 构建 wails3，12:05 构建 fyne，15:05 构建 mygo，18:05 构建 gio（09:05 的 wails2 定时已停用，见下）。
- GitHub：每天 16:05 UTC（北京 00:05）构建 golang 基础镜像，19:05 UTC（北京 03:05）构建 fnpack 镜像，22:05 UTC（北京 06:05）构建 wails3，04:05 UTC（北京 12:05）构建 fyne，07:05 UTC（北京 15:05）构建 mygo，10:05 UTC（北京 18:05）构建 gio（01:05 UTC 的 wails2 定时已停用）。
- GitLab：用 UI / API 里的 Pipeline schedules 触发，建议与 GitHub 对齐：16:05 UTC golang、19:05 UTC fnpack、22:05 UTC wails3、04:05 UTC fyne、07:05 UTC mygo、10:05 UTC gio，每个 schedule 用 `TARGET` 变量选镜像，见 [gitlab.md](../gitlab.md)（wails2 那条已停用）。

> **wails2 不再每天跟踪上游**：wails2 是旧版（Wails v2），仓库已有新版 wails3 镜像；旧版上游发版少、现有 v2 项目一般钉住版本，新旧两版并存时没必要每天跟踪旧版上游重建，因此三侧的 wails2 定时构建都停用，改为**按需手动触发**。CNB / GitHub 的 cron 已在 `.cnb.yml` 与 `.github/workflows/build-wails2.yml` 里注释停用；GitLab 的 cron 在 UI / API 里，需把 `TARGET=wails2` 那条 Pipeline schedule 设为 inactive（或删除）。已推送的 `.../wails2` 镜像、三份 `Dockerfile.wails2` 与三份 `build-wails2.sh` 全部保留，需要新版本时手动触发即可（CNB 自定义按钮 / GitHub `workflow_dispatch` / GitLab Run pipeline 填 `TARGET=wails2`）。 两个注意点：① 若 GitLab 只建了一条不带 `TARGET` 的全量 schedule，`.gitlab/workflows/build-wails2.yml` 的 rules 是 `$TARGET == "" || $TARGET == "wails2"`，wails2 仍会被构建，这种部署方式要排除它得收紧 rules；② wails3 用的是 GTK4/WebKitGTK 6.0 + `wails3` CLI，wails2 用的是 GTK3/WebKit2GTK 4.1 + `wails` CLI（构建还要 `-tags webkit2_41`），两者不通用，编译 Wails v2 项目仍需要 wails2 镜像，所以只停定时、不删镜像定义。

`GO_VERSION` 默认是 `1`（`golang:1-trixie` 浮动标签），上游发布新 Go 后下一次构建会自动跟随；想钉版本时手动填 `version`，或直接改三份 Dockerfile 的 `GO_VERSION`。定时构建还会重新解析上游各工具的最新版本：版本变了才重建对应那一层，没变就全命中缓存（只拉基座、跑冒烟）。上游重新推送同一 tag 的基座（安全修复）时，digest 一变，apt 之后的层会全部重建，同样能吃到更新。

需要一次干净的全量重建时，手动触发并设 `CACHE=off`（或本地 `CACHE=off source .cnb/scripts/build-golang.sh`、`.github/scripts/build-golang.sh`、`.gitlab/scripts/build-golang.sh`）。

## 升级 Go 版本

1. 同步修改三份 Dockerfile 的 `GO_VERSION`：
   - `.cnb/docker/Dockerfile.golang`
   - `.github/docker/Dockerfile.golang`
   - `.gitlab/docker/Dockerfile.golang`
2. 如果 Debian 代号也变（如 `trixie` → `forky`），同时改 `DEBIAN_VERSION`，三份都改。
3. 本地构建验证：

   ```bash
   docker build -f .github/docker/Dockerfile.golang -t golang:test .
   docker run --rm golang:test go version
   ```

4. 提交后由 CI 构建；也可以手动触发并填 `version` 先验证，不急着改默认值。

> 只想跟随补丁、不改默认值：手动触发时填 `1.27`，脚本会解析成实际补丁版本（如 `1.27.4`）并打标签。

## 升级工具版本

在**三份** `Dockerfile.golang` 里改对应的 `ARG`：

| 工具              | ARG                         |
|-------------------|-----------------------------|
| UPX               | `UPX_VERSION`               |
| nfpm              | `NFPM_VERSION`              |
| Node.js           | `NODE_VERSION`              |
| pnpm              | `PNPM_VERSION`              |
| sqlc              | `SQLC_VERSION`              |
| ent / entc        | `ENT_VERSION`               |
| golangci-lint     | `GOLANGCI_LINT_VERSION`     |
| govulncheck       | `GOVULNCHECK_VERSION`       |
| shfmt             | `SHFMT_VERSION`             |
| dockerfmt         | `DOCKERFMT_VERSION`         |
| yamlfmt           | `YAMLFMT_VERSION`           |
| gojq              | `GOJQ_VERSION`              |
| sql-formatter     | `GOSQLFORMATTER_VERSION`    |
| gotestsum         | `GOTESTSUM_VERSION`         |
| markdownfmt       | `MARKDOWNFMT_VERSION`       |
| gocover-cobertura | `GOCOVER_COBERTURA_VERSION` |
| gcov2lcov         | `GCOV2LCOV_VERSION`         |
| task（go-task）   | `TASK_VERSION`              |

升级后本地构建一次，确认对应二进制仍可执行；CI 冒烟只检查「命令存在」，不检查版本号。

## 升级 fnpack

改三份 `Dockerfile.fnpack` 的 `FNPACK_VERSION`：

- `.cnb/docker/Dockerfile.fnpack`
- `.github/docker/Dockerfile.fnpack`
- `.gitlab/docker/Dockerfile.fnpack`

版本号以 [fnpack 官方文档](https://developer.fnnas.com/docs/cli/fnpack/) 为准。下载地址格式：

```text
https://static2.fnnas.com/fnpack/fnpack-<版本>-linux-<arch>
```

`<arch>` 为 `amd64` 或 `arm`（ARM 用 `arm`，不是 `arm64`）。升级后三个文件都要先用 `curl -sI` 确认对应产物存在。

想先验证某个版本时，可以手动触发 CNB / GitHub / GitLab 各自的 `build-fnpack` 并填 `fnpack_version`，确认产物可用后再改三份 Dockerfile 的默认值；不填则使用 Dockerfile 里的默认版本（当前 `1.2.3`，上游暂无 latest 查询接口，暂作为最新版本）。

## 升级 wails3

**通常什么都不用做**：三份 `Dockerfile.wails3` 的 `WAILS3_VERSION` 默认是 `latest`，每次定时构建都会先用 `go list -m github.com/wailsapp/wails/v3@latest` 解析上游最新稳定 tag，再 `go install` 那个具体版本。上游发了新版，第二天（CNB 06:05 / GitHub 22:05 UTC / GitLab 22:05 UTC）自动进镜像，版本号会写进元数据 `wails3_version` 与徽章。

需要人工介入的两种情况：

1. **想钉住某个版本**（复现、回滚、或 latest 解析出的版本有问题）：手动触发 `build-wails3` 工作流并填 `wails3_version`（`v3.1.0` / `3.1.0` / `v3.0.0-beta.34` 都接受）。这只影响本次构建，不改默认值。
2. **想长期钉住**：把三份 `Dockerfile.wails3` 的 `WAILS3_VERSION` 改成具体 tag（如 `v3.1.0`）。脚本遇到「Dockerfile 默认值不是 `latest`」时会尊重它、跳过网络解析——恢复追新时把默认值改回 `latest`。

wails3 版本**不占标签**：`golang/wails3:<go 版本>` 永远是「该 Go 版本下最近一次成功构建」，换了 wails3 版本标签会被同名覆盖。回查某次构建装的是哪个 wails3，看元数据 `wails3_version`；固定产物用 `wails3_digest`。

## 升级 wails2

**通常什么都不用做**：三份 `Dockerfile.wails2` 的 `WAILS2_VERSION` 默认是 `latest`，每次手动构建都会先用 `go list -m github.com/wailsapp/wails/v2@latest` 解析上游最新稳定 tag，再 `go install` 那个具体版本。上游发了新版不会自动进镜像（定时已停用，见「日常构建」）；需要时手动触发一次，解析出的版本号会写进元数据 `wails2_version` 与徽章。

需要人工介入的两种情况与 wails3 相同：手动触发 `build-wails2` 并填 `wails2_version`（`v2.17.1` / `2.17.1` 都接受），或把三份 `Dockerfile.wails2` 的 `WAILS2_VERSION` 改成具体 tag。wails2 版本同样不占标签，复现某次产物请用元数据里的 `wails2_digest`。

## 升级 fyne

**通常什么都不用做**：三份 `Dockerfile.fyne` 的 `FYNE_VERSION` 默认是 `latest`，每次定时构建都会先用 `go list -m fyne.io/tools@latest` 解析上游最新稳定 tag，再 `go install` 那个具体版本。上游发了新版，第二天（CNB 12:05 / GitHub 04:05 UTC / GitLab 04:05 UTC）自动进镜像，版本号会写进元数据 `fyne_version` 与徽章。

> fyne CLI 的模块是 `fyne.io/tools`。上游把 `v1.26.0` / `v1.26.1` 标了 retract（误发），解析结果里出现它们时不要当成新版本。

需要人工介入的两种情况与 wails3 相同：手动触发 `build-fyne` 并填 `fyne_version`（`v1.7.4` / `1.7.4` 都接受），或把三份 `Dockerfile.fyne` 的 `FYNE_VERSION` 改成具体 tag。fyne 版本同样不占标签，复现某次产物请用元数据里的 `fyne_digest`。

升级 OpenGL/X11/Wayland 依赖时改三份 `Dockerfile.fyne` 的 apt 列表，并同步 `pkg-config --exists` 断言（`gl` / `x11` / `xrandr` / `xcursor` / `xinerama` / `xi` / `xxf86vm` / `wayland-client` / `xkbcommon`），三份 `build-fyne.sh` 的冒烟段也要跟着改。

## 升级 mygo

mygo 镜像里有两条独立的版本线，升级方式与 fyne 相同：手动触发 `build-mygo` 并填 `mygo_version`（`v0.8.1` / `0.8.1` 都接受）与/或 `bun_version`（`1.4.4`），或把三份 `Dockerfile.mygo` 的 `MYGO_VERSION` / `BUN_VERSION` 改成具体版本。两者都不占标签，复现某次产物请用元数据里的 `mygo_digest`。

- 看上游发了什么版本：

  ```bash
  go list -m -f '{{.Version}}' github.com/egoist/mygo@latest   # mygo CLI
  npm view bun version                                         # bun
  ```

- 升级 GTK3 / WebKitGTK 4.1 或无头运行库依赖时改三份 `Dockerfile.mygo` 的 apt 列表，并同步 `pkg-config --exists` 断言（`gtk+-3.0` / `webkit2gtk-4.1` 加 `gl` / `x11` / `xrandr` / `xcursor` / `xinerama` / `xi` / `xxf86vm` / `wayland-client` / `xkbcommon`）与 `ldconfig -p` 断言（`libgtk-3.so.0` / `libwebkit2gtk-4.1.so` / `libayatana-appindicator3.so.1`），三份 `build-mygo.sh` 的冒烟段也要跟着改。
- 上游 mygo 换 Linux 后端（例如从 GTK3 换到 GTK4）时，apt 列表、`.pc` 断言、冒烟里 `mygo doctor` 的 grep 关键字都要一起改，并同步 [../mygo/README.md](../mygo/README.md) 里「镜像里有什么」的说明。
- `bun` 是可选依赖：只有 `mygo init` 默认 Web 前端模板需要它。上游若改了默认模板的命令（不再用 `bun`），可以评估是否还装 `bun`。

## 升级 gio

gio 镜像里只有一条版本线，升级方式与 mygo 相同：手动触发 `build-gio` 并填 `gio_version`（gogio CLI，模块 `gioui.org/cmd`，`v0.10.3` / `0.10.3` 都接受），或把三份 `Dockerfile.gio` 的 `GIO_VERSION` 改成具体版本。它不占标签，复现某次产物请用元数据里的 `gio_digest`。

- 看上游发了什么版本：

  ```bash
  go list -m -f '{{.Version}}' gioui.org/cmd@latest   # gogio CLI
  go list -m -f '{{.Version}}' gioui.org@latest       # gioui.org 库
  ```

- 升级 cgo 依赖（EGL/GLES、X11、Wayland、Vulkan）或无头运行库时改三份 `Dockerfile.gio` 的 apt 列表，并同步 `pkg-config --exists` 断言（`egl` / `glesv2` / `wayland-client` / `wayland-cursor` / `wayland-egl` / `x11` / `x11-xcb` / `xkbcommon` / `xkbcommon-x11` / `xcursor` / `xfixes` / `xrandr` / `xinerama` / `xi` / `xxf86vm` / `libffi` / `vulkan`）与 `ldconfig -p` 断言（`libEGL.so.1` / `libGL.so.1` / `libvulkan.so.1` / `libwayland-client.so.0` / `libxkbcommon.so.0` / `libX11.so.6`），三份 `build-gio.sh` 的冒烟段也要跟着改。
- 上游 `gioui.org` 增删后端（例如新增/移除某个 `.pc` 依赖）时，apt 列表与 `.pc` 断言都要一起改，并同步 [../gio/README.md](../gio/README.md) 里「镜像里有什么」的说明。
- 注意变体名与 CLI 名不一致：变体叫 gio，CLI 叫 `gogio`。`gogio` 没有 `version` 子命令，验证版本只能用 `go version -m "$(command -v gogio)"` 读 `gioui.org/cmd` 模块版本；它也没有 linux 打包目标。

## 新增工具

1. 在三份 `Dockerfile.golang` 里加 `ARG` 与安装命令。有官方 Release 二进制的，写成 `install-tool <名> "${VAR}" || go install -v <包路径>@${VAR}`，并在三份 `install-tool.sh` 的表里加一行（工具名 = 解压后的二进制名、仓库、资产命名）。
2. 在三份 `build-golang.sh` 的冒烟命令列表里加上二进制名。
3. 如果是 Go 工具：在三份 `build-golang.sh` 的 `GO_TOOL_MODULES` 里登记「版本变量 → 模块路径」。漏登记时脚本会在构建前直接报错（`go list -m` 要模块路径，Dockerfile 里写的是包路径）。
4. 如果工具也应该在 fnpack 镜像里被检查，同步三份 `build-fnpack.sh` 的继承断言。
5. 更新 [dockerfile.md](dockerfile.md) 的版本表。
6. 如果工具是 GitHub Release 下载，CNB 侧必须支持 `GITHUB_MIRROR`（走 DaoCloud）；GitHub / GitLab 侧直接写死官方地址。走 `curl` 自己解析版本的，记得同时改三份脚本里的解析逻辑（`resolve_versions`）。

用 apt 装系统包（`-dev` 库、无头运行库等）时**不用**改脚本：`apt_versions` 会从该镜像对应的 Dockerfile 自动提取 `apt-get install` 那段，版本在镜像里用 `dpkg-query` 取；只需把包名写进 Dockerfile 的 apt 列表（以及必要的 `pkg-config --exists` 断言）。

## 同步检查清单

改镜像内容后：

- [ ] `.cnb/docker/`、`.github/docker/`、`.gitlab/docker/` 下的七个 Dockerfile 内容一致（镜像源差异除外）
- [ ] 三份 `build-golang.sh` 的标签规则、冒烟断言一致
- [ ] 三份 `build-golang.sh` 的 `GO_TOOL_MODULES` 覆盖 Dockerfile 里所有 `go install` 版本变量（脚本会自检）
- [ ] 三份 `install-tool.sh` 内容一致，且表里的资产命名与各仓库实际 release 对得上（新增工具时用 `curl -I` 验证过 URL）
- [ ] 三份 `build-fnpack.sh` 的标签规则、基础镜像检查、冒烟断言一致
- [ ] 三份 `build-wails3.sh` / `build-wails2.sh` / `build-fyne.sh` / `build-mygo.sh` / `build-gio.sh` 的标签规则、基础镜像检查、冒烟断言一致
- [ ] GitLab 的定时任务与 `TARGET` 变量仍指向七个镜像
- [ ] `make format` 通过
- [ ] `make lint-shell` 通过

## 标签与制品库

- `<go 版本>` 每天可能被同名覆盖，不是固定点。
- golang 的 `latest` / `<major.minor>` 在自身冒烟通过后提升。
- fnpack / wails3 / wails2 / fyne / mygo / gio 的 `latest` / `<major.minor>` 只在基础镜像对应标签也指向本次版本时提升。
- 固定产物请用 annotation 里的 digest。
- GHCR / CNB / GitLab Container Registry 可能有保留策略，长期归档请自行保存 digest 或复制到别处。
