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

### 生成 SQL 代码

```bash
docker run --rm -v "$PWD":/src -w /src ghcr.io/dtapps/golang:latest \
  sqlc generate
```

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

私有包需要认证时，在容器里自行配置 `GOPRIVATE` / `.netrc`；镜像里的 `GOINSECURE=go.dtapp.net` 只解决该域名的 TLS 校验，不代替认证。

## 版本选择

| 需求              | 建议标签                       |
|-------------------|--------------------------------|
| 跟随最新          | `latest`                       |
| 跟随某个 Go minor | `1.27`                         |
| 固定补丁版本      | `1.27.3`                       |
| 固定产物          | `@sha256:<digest>`（见元数据） |

标签会随重建移动；生产环境建议固定到 `<go 版本>` 或 digest。
