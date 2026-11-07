# 贡献指南

本仓库只做一件事：构建七个自建镜像——`golang`（不含变体 CLI）、`golang/fnpack`、`golang/wails3`、`golang/wails2`、`golang/fyne`、`golang/mygo` 与 `golang/gio`，由 CNB、GitHub Actions 与 GitLab CI 三套流水线分别推送到 CNB 制品库、GHCR 与 GitLab Container Registry。三个平台各维护一份 Dockerfile 与构建脚本（`.cnb/`、`.github/` 与 `.gitlab/`，各自维护、不互相引用）。它没有应用代码、没有测试用例，所以「贡献」通常意味着改 Dockerfile、改构建脚本，或修文档。

## 文件地图

| 文件                                 | 职责                               | 注意事项                               |
|--------------------------------------|------------------------------------|----------------------------------------|
| `.cnb/docker/Dockerfile.golang`      | CNB 侧：基座、工具链、镜像源开关   | 与 `.github/`、`.gitlab/` 同名文件同步 |
| `.cnb/docker/Dockerfile.fnpack`      | CNB 侧：在 golang 镜像上加 fnpack  | 与 `.github/`、`.gitlab/` 同名文件同步 |
| `.cnb/docker/Dockerfile.wails3`      | CNB 侧：在 golang 镜像上加 wails3  | 与 `.github/`、`.gitlab/` 同名文件同步 |
| `.cnb/docker/Dockerfile.wails2`      | CNB 侧：在 golang 镜像上加 wails2  | 与 `.github/`、`.gitlab/` 同名文件同步 |
| `.cnb/docker/Dockerfile.fyne`        | CNB 侧：在 golang 镜像上加 fyne    | 与 `.github/`、`.gitlab/` 同名文件同步 |
| `.cnb/docker/Dockerfile.mygo`        | CNB 侧：在 golang 镜像上加 mygo    | 与 `.github/`、`.gitlab/` 同名文件同步 |
| `.cnb/docker/Dockerfile.gio`         | CNB 侧：在 golang 镜像上加 gio     | 与 `.github/`、`.gitlab/` 同名文件同步 |
| `.github/docker/Dockerfile.golang`   | GitHub 侧：同上                    | 与 `.cnb/`、`.gitlab/` 同步            |
| `.github/docker/Dockerfile.fnpack`   | GitHub 侧：同上                    | 与 `.cnb/`、`.gitlab/` 同步            |
| `.github/docker/Dockerfile.wails3`   | GitHub 侧：同上                    | 与 `.cnb/`、`.gitlab/` 同步            |
| `.github/docker/Dockerfile.wails2`   | GitHub 侧：同上                    | 与 `.cnb/`、`.gitlab/` 同步            |
| `.github/docker/Dockerfile.fyne`     | GitHub 侧：同上                    | 与 `.cnb/`、`.gitlab/` 同步            |
| `.github/docker/Dockerfile.mygo`     | GitHub 侧：同上                    | 与 `.cnb/`、`.gitlab/` 同步            |
| `.github/docker/Dockerfile.gio`      | GitHub 侧：同上                    | 与 `.cnb/`、`.gitlab/` 同步            |
| `.gitlab/docker/Dockerfile.golang`   | GitLab 侧：同上                    | 与 `.cnb/`、`.github/` 同步            |
| `.gitlab/docker/Dockerfile.fnpack`   | GitLab 侧：同上                    | 与 `.cnb/`、`.github/` 同步            |
| `.gitlab/docker/Dockerfile.wails3`   | GitLab 侧：同上                    | 与 `.cnb/`、`.github/` 同步            |
| `.gitlab/docker/Dockerfile.wails2`   | GitLab 侧：同上                    | 与 `.cnb/`、`.github/` 同步            |
| `.gitlab/docker/Dockerfile.fyne`     | GitLab 侧：同上                    | 与 `.cnb/`、`.github/` 同步            |
| `.gitlab/docker/Dockerfile.mygo`     | GitLab 侧：同上                    | 与 `.cnb/`、`.github/` 同步            |
| `.gitlab/docker/Dockerfile.gio`      | GitLab 侧：同上                    | 与 `.cnb/`、`.github/` 同步            |
| `.cnb/scripts/build-golang.sh`       | CNB 侧：构建并发布 golang 基础镜像 | POSIX `sh`；失败要显式退出             |
| `.cnb/scripts/build-fnpack.sh`       | CNB 侧：基于基础镜像发布 fnpack    | 与另外两侧标签/冒烟同步                |
| `.cnb/scripts/build-wails3.sh`       | CNB 侧：基于基础镜像发布 wails3    | 与另外两侧标签/冒烟同步                |
| `.cnb/scripts/build-wails2.sh`       | CNB 侧：基于基础镜像发布 wails2    | 与另外两侧标签/冒烟同步                |
| `.cnb/scripts/build-fyne.sh`         | CNB 侧：基于基础镜像发布 fyne      | 与另外两侧标签/冒烟同步                |
| `.cnb/scripts/build-mygo.sh`         | CNB 侧：基于基础镜像发布 mygo      | 与另外两侧标签/冒烟同步                |
| `.cnb/scripts/build-gio.sh`          | CNB 侧：基于基础镜像发布 gio       | 与另外两侧标签/冒烟同步                |
| `.github/scripts/build-golang.sh`    | GitHub 侧：同上                    | 与另外两侧标签/冒烟同步                |
| `.github/scripts/build-fnpack.sh`    | GitHub 侧：同上                    | 与另外两侧标签/冒烟同步                |
| `.github/scripts/build-wails3.sh`    | GitHub 侧：同上                    | 与另外两侧标签/冒烟同步                |
| `.github/scripts/build-wails2.sh`    | GitHub 侧：同上                    | 与另外两侧标签/冒烟同步                |
| `.github/scripts/build-fyne.sh`      | GitHub 侧：同上                    | 与另外两侧标签/冒烟同步                |
| `.github/scripts/build-mygo.sh`      | GitHub 侧：同上                    | 与另外两侧标签/冒烟同步                |
| `.github/scripts/build-gio.sh`       | GitHub 侧：同上                    | 与另外两侧标签/冒烟同步                |
| `.gitlab/scripts/build-golang.sh`    | GitLab 侧：同上                    | 与另外两侧标签/冒烟同步                |
| `.gitlab/scripts/build-fnpack.sh`    | GitLab 侧：同上                    | 与另外两侧标签/冒烟同步                |
| `.gitlab/scripts/build-wails3.sh`    | GitLab 侧：同上                    | 与另外两侧标签/冒烟同步                |
| `.gitlab/scripts/build-wails2.sh`    | GitLab 侧：同上                    | 与另外两侧标签/冒烟同步                |
| `.gitlab/scripts/build-fyne.sh`      | GitLab 侧：同上                    | 与另外两侧标签/冒烟同步                |
| `.gitlab/scripts/build-mygo.sh`      | GitLab 侧：同上                    | 与另外两侧标签/冒烟同步                |
| `.gitlab/scripts/build-gio.sh`       | GitLab 侧：同上                    | 与另外两侧标签/冒烟同步                |
| `.cnb/workflows/build-golang.yml`    | CNB 触发器（golang）               | 按钮事件                               |
| `.cnb/workflows/build-fnpack.yml`    | CNB 触发器（fnpack）               | 依赖基础镜像已推送                     |
| `.cnb/workflows/build-wails3.yml`    | CNB 触发器（wails3）               | 依赖基础镜像已推送                     |
| `.cnb/workflows/build-wails2.yml`    | CNB 触发器（wails2）               | 依赖基础镜像已推送                     |
| `.cnb/workflows/build-fyne.yml`      | CNB 触发器（fyne）                 | 依赖基础镜像已推送                     |
| `.cnb/workflows/build-mygo.yml`      | CNB 触发器（mygo）                 | 依赖基础镜像已推送                     |
| `.cnb/workflows/build-gio.yml`       | CNB 触发器（gio）                  | 依赖基础镜像已推送                     |
| `.github/workflows/build-golang.yml` | GitHub 触发器（golang）            | QEMU、Step Summary                     |
| `.github/workflows/build-fnpack.yml` | GitHub 触发器（fnpack）            | 独立定时                               |
| `.github/workflows/build-wails3.yml` | GitHub 触发器（wails3）            | 独立定时                               |
| `.github/workflows/build-wails2.yml` | GitHub 触发器（wails2）            | 独立定时                               |
| `.github/workflows/build-fyne.yml`   | GitHub 触发器（fyne）              | 独立定时                               |
| `.github/workflows/build-mygo.yml`   | GitHub 触发器（mygo）              | 独立定时                               |
| `.github/workflows/build-gio.yml`    | GitHub 触发器（gio）               | 独立定时                               |
| `.gitlab/workflows/build-golang.yml` | GitLab 触发器（golang）            | dind、QEMU、buildx                     |
| `.gitlab/workflows/build-fnpack.yml` | GitLab 触发器（fnpack）            | 依赖基础镜像已推送                     |
| `.gitlab/workflows/build-wails3.yml` | GitLab 触发器（wails3）            | 依赖基础镜像已推送                     |
| `.gitlab/workflows/build-wails2.yml` | GitLab 触发器（wails2）            | 依赖基础镜像已推送                     |
| `.gitlab/workflows/build-fyne.yml`   | GitLab 触发器（fyne）              | 依赖基础镜像已推送                     |
| `.gitlab/workflows/build-mygo.yml`   | GitLab 触发器（mygo）              | 依赖基础镜像已推送                     |
| `.gitlab/workflows/build-gio.yml`    | GitLab 触发器（gio）               | 依赖基础镜像已推送                     |
| `.cnb.yml`、`.cnb/web_trigger.yml`   | CNB 定时任务、七个构建按钮         | 事件名必须与 workflow 一致             |
| `.gitlab-ci.yml`                     | GitLab 全局配置、变量、schedules   | 定时任务建在 UI / API 里               |

## 本地验证

```bash
# 1. 语法与静态检查
sh -n .cnb/scripts/build-golang.sh
sh -n .cnb/scripts/build-fnpack.sh
sh -n .cnb/scripts/build-wails3.sh
sh -n .cnb/scripts/build-wails2.sh
sh -n .cnb/scripts/build-fyne.sh
sh -n .cnb/scripts/build-mygo.sh
sh -n .cnb/scripts/build-gio.sh
sh -n .github/scripts/build-golang.sh
sh -n .github/scripts/build-fnpack.sh
sh -n .github/scripts/build-wails3.sh
sh -n .github/scripts/build-wails2.sh
sh -n .github/scripts/build-fyne.sh
sh -n .github/scripts/build-mygo.sh
sh -n .github/scripts/build-gio.sh
sh -n .gitlab/scripts/build-golang.sh
sh -n .gitlab/scripts/build-fnpack.sh
sh -n .gitlab/scripts/build-wails3.sh
sh -n .gitlab/scripts/build-wails2.sh
sh -n .gitlab/scripts/build-fyne.sh
sh -n .gitlab/scripts/build-mygo.sh
sh -n .gitlab/scripts/build-gio.sh
shellcheck -s sh -S warning .cnb/scripts/*.sh .github/scripts/*.sh .gitlab/scripts/*.sh

# 2. 构建七个镜像
docker build -f .github/docker/Dockerfile.golang -t golang:local .
docker build -f .github/docker/Dockerfile.fnpack \
  --build-arg GOLANG_IMAGE=golang:local -t golang-fnpack:local .
docker build -f .github/docker/Dockerfile.wails3 \
  --build-arg GOLANG_IMAGE=golang:local -t golang-wails3:local .
docker build -f .github/docker/Dockerfile.wails2 \
  --build-arg GOLANG_IMAGE=golang:local -t golang-wails2:local .
docker build -f .github/docker/Dockerfile.fyne \
  --build-arg GOLANG_IMAGE=golang:local -t golang-fyne:local .
docker build -f .github/docker/Dockerfile.mygo \
  --build-arg GOLANG_IMAGE=golang:local -t golang-mygo:local .
docker build -f .github/docker/Dockerfile.gio \
  --build-arg GOLANG_IMAGE=golang:local -t golang-gio:local .

# 3. 冒烟
docker run --rm golang:local sh -c 'go version; node -v; pnpm -v; sqlc version; gotestsum --version; upx --version; nfpm --version; command -v ent entc zip unzip pkg-config; date; date +%z'
docker run --rm golang-fnpack:local sh -c 'go version; fnpack --help'
docker run --rm golang-wails3:local sh -c 'go version; wails3 version; pkg-config --exists gtk4; pkg-config --exists webkitgtk-6.0'
docker run --rm golang-wails2:local sh -c 'go version; wails version; pkg-config --exists gtk+-3.0; pkg-config --exists webkit2gtk-4.1'
docker run --rm golang-fyne:local sh -c 'go version; fyne version; for pc in gl x11 xrandr xcursor xinerama xi xxf86vm wayland-client xkbcommon; do pkg-config --exists "$pc" || echo "missing $pc"; done'
docker run --rm golang-gio:local sh -c 'go version; go version -m "$(command -v gogio)"; for pc in egl glesv2 wayland-client wayland-cursor wayland-egl x11 x11-xcb xkbcommon xkbcommon-x11 xcursor xfixes xrandr xinerama xi xxf86vm libffi vulkan; do pkg-config --exists "$pc" || echo "missing $pc"; done'
```

GitHub / GitLab runner 默认直连官方下载源；CNB 走 DaoCloud。国内网络本地构建时用 CNB 的 Dockerfile：

```bash
docker build -f .cnb/docker/Dockerfile.golang \
  --build-arg GITHUB_MIRROR=https://files.m.daocloud.io \
  --build-arg NODE_MIRROR=https://files.m.daocloud.io \
  -t golang:local .
```

## 硬性规则

- **三份实现必须同步**。改镜像内容、版本 ARG、标签规则、冒烟断言时，`.cnb/`、`.github/` 与 `.gitlab/` 都要改。只改平台胶水（变量来源、镜像源、元数据落地）时各改各的。
- **标签是对外契约**。只有 `<go 版本>`、`<major.minor>`、`latest`，以及 `<go 版本>-linux-{amd64,arm64}`。不要新增带日期或其他语义的标签；改名或删除标签要先在文档里写清兼容流程。
- **移动标签只在冒烟通过后提升**。golang 在自己的冒烟通过后提升；fnpack / wails3 / wails2 / fyne / mygo / gio 还要等基础镜像的对应标签也指向本次版本。不要为了「先发出去」提前移动标签。
- **变体镜像必须 FROM 本次构建的 golang 镜像**，保证七个镜像工具链一致。不要复制一份完整的 Dockerfile 重新装一遍。
- **七个镜像的 workflow 分开**。golang / fnpack / wails3 / wails2 / fyne / mygo / gio 各一个 workflow 与构建脚本，不要合并回一条流水线。
- **变体 CLI 的版本跟随上游最新**：`WAILS3_VERSION`、`WAILS2_VERSION`、`FYNE_VERSION`、`MYGO_VERSION` 与 `GIO_VERSION` 默认都是 `latest`，CI 必须在构建前用 `go list -m` 解析成具体版本号再传 `--build-arg`（否则层缓存键永远是 `latest`，CLI 再也不升级）；mygo 镜像里的 `bun` 同理，用 `BUN_VERSION` + `npm view bun version` 解析。`FNPACK_VERSION` 因为上游没有 latest 接口，默认值就是具体版本号（当前 `1.2.3`），升级时要手动改三份 Dockerfile。实际版本要写进元数据（`fnpack_version` / `wails3_version` / `wails2_version` / `fyne_version` / `mygo_version` / `bun_version` / `gio_version`），不要靠标签承载。
- **不加不必要的工具**。新增工具要说明解决什么场景、增加多少体积，并同步三侧 Dockerfile、三侧冒烟列表和 `docs/golang/dockerfile.md`。
- **CNB 侧的 GitHub Release 下载必须支持 `GITHUB_MIRROR`**。CNB 依赖 DaoCloud 镜像，CNB 侧直接写死 `github.com` 会让构建失败；GitHub / GitLab 侧则直接写死官方地址。走 `go install` 的工具（如 wails3 / wails2 / fyne / mygo / gogio）用基座 Dockerfile 里的 `GOPROXY`，三侧自动各自正确；mygo 的 `bun` 走 npm，用的是基座的 npm registry，同样三侧自动正确。
- **不要把构建脚本放进 CNB 的 `imports`**：imports 会改写 `${...}`。用 `source` 执行。
- **不要在仓库里写凭证**。CNB 凭证在 imports 的 `dtapp/envs`；GitHub 用 `secrets.GITHUB_TOKEN`；GitLab 用自动注入的 `CI_REGISTRY_USER` / `CI_REGISTRY_PASSWORD`。

## PR 检查清单

- [ ] 三份 Dockerfile 的安装内容一致；镜像源差异（`GOPROXY`、APT、`GITHUB_MIRROR` / `NODE_MIRROR`）符合平台约定
- [ ] 三份 `build-golang.sh` 的标签规则、冒烟断言一致
- [ ] 三份 `build-fnpack.sh` 的标签规则、基础镜像检查、冒烟断言一致
- [ ] 三份 `build-wails3.sh` 的标签规则、基础镜像检查、`WAILS3_VERSION` 解析、冒烟断言一致
- [ ] 三份 `build-wails2.sh` 的标签规则、基础镜像检查、`WAILS2_VERSION` 解析、冒烟断言一致
- [ ] 三份 `build-fyne.sh` 的标签规则、基础镜像检查、`FYNE_VERSION` 解析、冒烟断言一致
- [ ] 三份 `build-mygo.sh` 的标签规则、基础镜像检查、`MYGO_VERSION` / `BUN_VERSION` 解析、冒烟断言一致
- [ ] 三份 `build-gio.sh` 的标签规则、基础镜像检查、`GIO_VERSION` 解析、冒烟断言一致
- [ ] `sh -n` 与 `shellcheck` 通过（含 `.gitlab/scripts/`）
- [ ] 本地构建七个镜像成功
- [ ] golang 镜像里 `fnpack` / `wails3` / `wails` / `fyne` / `mygo` / `gogio` 都不存在；fnpack 镜像里只有 `fnpack`；wails3 镜像里只有 `wails3`；wails2 镜像里只有 `wails`；fyne 镜像里只有 `fyne`；mygo 镜像里只有 `mygo`（外加可选的前端工具 `bun`）；gio 镜像里只有 `gogio`（模块 `gioui.org/cmd`，不是 `gio`）
- [ ] 没有把 `.cnb/annotation*.json` / `.github/annotation*.json` / `.gitlab/annotation*.json` 提交进去
- [ ] 文档同步更新（至少 `docs/golang/` 与对应变体目录）

## 提交信息

用一句话说明「为什么」而不是「改了什么」，例如：

```text
升级 golangci-lint 到 v2.16.0，修复 Go 1.27 下的误报
```

## 许可

提交即表示同意以 [MIT](LICENSE) 许可发布。
