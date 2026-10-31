# 维护

## 日常构建

- CNB：每天 00:05（Asia/Shanghai）构建 golang 基础镜像，01:05 构建 fnpack 镜像。
- GitHub：每天 16:35 UTC（北京 00:35）构建 golang 基础镜像，成功后由 `workflow_run` 接着构建 fnpack。

默认不会自动升级 Go 版本，因为 `GO_VERSION` 在 Dockerfile 里是钉死的。定时构建会重新拉取上游同 tag 的基座、重新下载全部依赖，因此上游重新推送同一 tag 时（安全修复）能吃到更新。

## 升级 Go 版本

1. 同步修改两份 Dockerfile 的 `GO_VERSION`：
   - `.cnb/docker/Dockerfile.golang`
   - `.github/docker/Dockerfile.golang`
2. 如果 Debian 代号也变（如 `trixie` → `forky`），同时改 `DEBIAN_VERSION`，两份都改。
3. 本地构建验证：

   ```bash
   docker build -f .github/docker/Dockerfile.golang -t golang:test .
   docker run --rm golang:test go version
   ```

4. 提交后由 CI 构建；也可以手动触发并填 `version` 先验证，不急着改默认值。

> 只想跟随补丁、不改默认值：手动触发时填 `1.27`，脚本会解析成实际补丁版本（如 `1.27.4`）并打标签。

## 升级工具版本

在**两份** `Dockerfile.golang` 里改对应的 `ARG`：

| 工具          | ARG                      |
|---------------|--------------------------|
| UPX           | `UPX_VERSION`            |
| nfpm          | `NFPM_VERSION`           |
| Node.js       | `NODE_VERSION`           |
| pnpm          | `PNPM_VERSION`           |
| sqlc          | `SQLC_VERSION`           |
| golangci-lint | `GOLANGCI_LINT_VERSION`  |
| govulncheck   | `GOVULNCHECK_VERSION`    |
| shfmt         | `SHFMT_VERSION`          |
| dockerfmt     | `DOCKERFMT_VERSION`      |
| yamlfmt       | `YAMLFMT_VERSION`        |
| gojq          | `GOJQ_VERSION`           |
| sql-formatter | `GOSQLFORMATTER_VERSION` |
| markdownfmt   | `MARKDOWNFMT_VERSION`    |

升级后本地构建一次，确认对应二进制仍可执行；CI 冒烟只检查「命令存在」，不检查版本号。

## 升级 fnpack

改两份 `Dockerfile.fnpack` 的 `FNPACK_VERSION`：

- `.cnb/docker/Dockerfile.fnpack`
- `.github/docker/Dockerfile.fnpack`

版本号以 [fnpack 官方文档](https://developer.fnnas.com/docs/cli/fnpack/) 为准。下载地址格式：

```text
https://static2.fnnas.com/fnpack/fnpack-<版本>-linux-<arch>
```

## 新增工具

1. 在两份 `Dockerfile.golang` 里加 `ARG` 与安装命令。
2. 在两份 `build-golang.sh` 的冒烟命令列表里加上二进制名。
3. 如果工具也应该在 fnpack 镜像里被检查，同步两份 `build-fnpack.sh` 的继承断言。
4. 更新 [dockerfile.md](dockerfile.md) 的版本表。
5. 如果工具是 GitHub Release 下载，必须同时支持 `GITHUB_MIRROR`（CNB 走 DaoCloud）。

## 同步检查清单

改镜像内容后：

- [ ] `.cnb/docker/Dockerfile.golang` 与 `.github/docker/Dockerfile.golang` 一致
- [ ] `.cnb/docker/Dockerfile.fnpack` 与 `.github/docker/Dockerfile.fnpack` 一致
- [ ] 两份 `build-golang.sh` 的标签规则、冒烟断言一致
- [ ] 两份 `build-fnpack.sh` 的标签规则、基础镜像检查、冒烟断言一致
- [ ] `make format` 通过
- [ ] `make lint-shell` 通过
- [ ] PR 校验里 golang 与 fnpack 两个作业都能通过

## 标签与制品库

- `<go 版本>` 每天可能被同名覆盖，不是固定点。
- golang 的 `latest` / `<major.minor>` 在自身冒烟通过后提升。
- fnpack 的 `latest` / `<major.minor>` 只在基础镜像对应标签也指向本次版本时提升。
- 固定产物请用 annotation 里的 digest。
- GHCR / CNB 制品库可能有保留策略，长期归档请自行保存 digest 或复制到别处。
