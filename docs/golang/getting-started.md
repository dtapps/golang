# 快速上手

## 作为基础镜像

```dockerfile
FROM ghcr.io/dtapps/golang:latest

WORKDIR /src
COPY . .
RUN go build -trimpath -ldflags="-s -w" -o app .
```

需要 fnpack 时换镜像：

```dockerfile
FROM ghcr.io/dtapps/golang/fnpack:latest
```

需要编译 Fyne 桌面应用时换镜像：

```dockerfile
FROM ghcr.io/dtapps/golang/fyne:latest
```

## 常见用法

### Go 构建 + 压缩

```bash
docker run --rm -v "$PWD":/src -w /src ghcr.io/dtapps/golang:latest sh -c '
  go build -trimpath -ldflags="-s -w" -o app .
  upx --best --lzma app
'
```

### 代码检查

```bash
docker run --rm -v "$PWD":/src -w /src ghcr.io/dtapps/golang:latest sh -c '
  golangci-lint run
  govulncheck ./...
'
```

### 跑测试（gotestsum）

```bash
docker run --rm -v "$PWD":/src -w /src ghcr.io/dtapps/golang:latest \
  gotestsum --format testname -- ./...
```

### 生成 SQL 代码

```bash
docker run --rm -v "$PWD":/src -w /src ghcr.io/dtapps/golang:latest \
  sqlc generate
```

### 生成 ent 代码

```bash
docker run --rm -v "$PWD":/src -w /src ghcr.io/dtapps/golang:latest \
  ent generate ./ent/schema
```

镜像里同时提供底层命令 `entc`，用法相同。

### 打包 deb / rpm（nfpm）

```bash
docker run --rm -v "$PWD":/src -w /src ghcr.io/dtapps/golang:latest sh -c '
  go build -o dist/app .
  nfpm package --config nfpm.yaml --packager deb --target dist/
'
```

### 前端依赖与构建

```bash
docker run --rm -v "$PWD":/src -w /src ghcr.io/dtapps/golang:latest sh -c '
  pnpm install --frozen-lockfile
  pnpm build
'
```

### 格式化

```bash
docker run --rm -v "$PWD":/src -w /src ghcr.io/dtapps/golang:latest sh -c '
  shfmt -w -i 2 -ci -bn -ln posix scripts/
  dockerfmt -w .
  yamlfmt -conf .yamlfmt .
  markdownfmt -w README.md
  gojq . package.json >/dev/null
'
```

### FnOS 打 `.fpk` 包

```bash
docker run --rm -v "$PWD":/src -w /src ghcr.io/dtapps/golang/fnpack:latest sh -c '
  fnpack build
  fnpack --help
'
```

具体命令以 [fnpack 官方文档](https://developer.fnnas.com/docs/cli/fnpack/) 为准；镜像只负责提供二进制。

### 编译 Fyne 桌面应用

```bash
docker run --rm -v "$PWD":/src -w /src ghcr.io/dtapps/golang/fyne:latest sh -c '
  fyne version
  go build -o dist/app .
'
```

镜像已装 OpenGL / X11 / Wayland 开发包（`gl` / `x11` / `xrandr` / `xcursor` / `xinerama` / `xi` / `xxf86vm` / `wayland-client` / `xkbcommon` 都能被 `pkg-config` 解析），所以 cgo 阶段直接可用。`fyne.io/fyne/v2` 的版本由你自己的 `go.mod` 决定，镜像只提供 `fyne` CLI。

运行带窗口的二进制需要真实显示环境（容器里要自己准备 X11/Wayland），这个镜像只保证**构建**可用。

## 在 GitHub Actions 里用

```yaml
jobs:
  build:
    runs-on: ubuntu-24.04
    container:
      image: ghcr.io/dtapps/golang:latest
    steps:
      - uses: actions/checkout@v4
      - run: go build ./...
      - run: golangci-lint run
```

私有包需要认证时，在容器里自行配置 `GOPRIVATE` / `.netrc`。

## 版本选择

| 需求              | 建议标签                       |
|-------------------|--------------------------------|
| 跟随最新          | `latest`                       |
| 跟随某个 Go minor | `1.27`                         |
| 固定补丁版本      | `1.27.3`                       |
| 固定产物          | `@sha256:<digest>`（见元数据） |

标签会随重建移动；生产环境建议固定到 `<go 版本>` 或 digest。
