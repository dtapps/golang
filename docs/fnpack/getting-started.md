# 快速上手：fnpack 与 .fpk 打包

[fnpack](https://developer.fnnas.com/docs/cli/fnpack/) 是 FnOS 官方的应用打包 CLI，把项目产出打成 `.fpk` 安装包。本镜像只负责把这个官方二进制放进 Go 构建环境，不改动它的任何行为；命令用法以 [官方文档](https://developer.fnnas.com/docs/cli/fnpack/) 为准。

## 什么时候选这个镜像

| 需求                                                 | 用哪个                                     |
|------------------------------------------------------|--------------------------------------------|
| Go 编译、golangci-lint、测试、deb/rpm 打包、前端构建 | [golang 基座](../golang/README.md) 就够    |
| 上面任何一件事，再加产出 `.fpk`                      | `golang/fnpack`                            |
| 拿不准                                               | 直接用 `golang/fnpack`，它包含基座全部能力 |

两个镜像的工具链完全一致，只差一个 `/usr/local/bin/fnpack`；标签也一一对应，换镜像不用改标签习惯。

## 拉取与自检

```bash
# GHCR 与 CNB 制品库二选一，标签规则一致
docker pull ghcr.io/dtapps/golang/fnpack:latest
docker run --rm ghcr.io/dtapps/golang/fnpack:latest fnpack --help
```

确认镜像里装的 fnpack 版本：读 [元数据徽章](metadata-and-badges.md) 的 `fnpack_version`，或查构建参数（默认取 Dockerfile 的 `ARG FNPACK_VERSION`，手动触发时可能被 `fnpack_version` 覆盖，见 [dockerfile.md](dockerfile.md)）。

## 打 .fpk 包

典型流程是「Go 编译 → 在项目目录跑 `fnpack build`」：

```bash
docker run --rm -v "$PWD":/src -w /src ghcr.io/dtapps/golang/fnpack:latest sh -c '
  go build -trimpath -ldflags="-s -w" -o dist/app .
  fnpack build
'
```

`fnpack build` 读取项目目录里的打包清单并产出 `.fpk`；清单格式、签名、版本号等参数以 [官方文档](https://developer.fnnas.com/docs/cli/fnpack/) 为准，本镜像不预置任何模板。

只用 fnpack、不需要编译时，可以省掉编译步骤：

```bash
docker run --rm -v "$PWD":/src -w /src ghcr.io/dtapps/golang/fnpack:latest fnpack build
```

## 作为基础镜像

```dockerfile
FROM ghcr.io/dtapps/golang/fnpack:latest
# 或钉住 Go 版本：ghcr.io/dtapps/golang/fnpack:1.27
WORKDIR /src
COPY . .
RUN go build -trimpath -ldflags="-s -w" -o dist/app . && fnpack build
```

## 在 CI 里给 FnOS 出包

```yaml
jobs:
  fpk:
    runs-on: ubuntu-24.04
    container:
      image: ghcr.io/dtapps/golang/fnpack:latest
    steps:
      - uses: actions/checkout@v4
      - run: go build -trimpath -ldflags="-s -w" -o dist/app .
      - run: fnpack build
      - uses: actions/upload-artifact@v4
        with:
          name: fpk
          path: dist/*.fpk
```

## 版本选择

| 需求               | 怎么选                                                                 |
|--------------------|------------------------------------------------------------------------|
| 跟随最新 Go 与基座 | `latest`                                                               |
| 跟随某个 Go minor  | `1.27`                                                                 |
| 固定补丁版本       | `1.27.3`                                                               |
| 固定产物           | `@sha256:<fnpack_digest>`（见 [元数据与徽章](metadata-and-badges.md)） |

注意两点：

- 标签里的版本是 **Go 版本**，不是 fnpack 版本；fnpack 自身版本只在元数据 `fnpack_version` 里。
- fnpack 的版本升级改的是 Dockerfile 的 `FNPACK_VERSION`（见 [基座维护手册](../golang/maintenance.md) 的「升级 fnpack」），不是靠标签选择。手动触发构建时也可以填 `fnpack_version` 临时覆盖；留空则使用 Dockerfile 的 `FNPACK_VERSION`（当前 `1.2.3`，上游暂无 latest 查询接口，暂作为最新版本）。
