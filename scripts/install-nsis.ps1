# 安装 NSIS（Windows）：下载官方便携版 zip，解压后把 makensis.exe 目录加入 PATH。
#
# 由 action.yml 的 Install NSIS 步骤调用（tools 含 nsis 且 runner.os == 'Windows'）：
#   pwsh -NoProfile -File "$env:GITHUB_ACTION_PATH/scripts/install-nsis.ps1"
#
# 注意：GitHub 的 pwsh 默认 $ErrorActionPreference='Stop'，Write-Error 会被升级为
# OperationStopped 异常直接终止脚本（表现为 "OperationStopped: exit code 1"）。
# 故显式设为 Continue，并用 Write-Host + exit 1 报告失败，避免异常中断。
# https://nsis.sourceforge.io/Download

$ErrorActionPreference = 'Continue'

$dest = "$env:RUNNER_TEMP\nsis"

# 缓存命中：actions/cache 已把上次解压好的目录还原，直接用——
# 放在版本解析之前，命中时连 RSS 请求都省掉
$cached = Get-ChildItem -Path $dest -Filter makensis.exe -Recurse -ErrorAction SilentlyContinue |
  Select-Object -First 1
if ($cached) {
  Add-Content -Path $env:GITHUB_PATH -Value (Split-Path -Parent $cached.FullName)
  Write-Host "NSIS 命中缓存：$($cached.FullName)"
  exit 0
}

$nsisVer = $env:NSIS_VERSION

# 版本解析：latest（或空）时从 SourceForge RSS 取最新 nsis-x.y.z.zip；
# 解析失败回退固定版本，避免 RSS 抖动直接让构建挂掉。
if (-not $nsisVer -or $nsisVer -eq 'latest') {
  Write-Host "NSIS_VERSION=latest，从 SourceForge RSS 解析最新版本 ..."
  $rssUrl = 'https://sourceforge.net/projects/nsis/rss?path=/NSIS%203'
  $rss = ''
  try { $rss = (curl.exe -L -fsS $rssUrl) -join "`n" } catch { $rss = '' }
  $vers = @()
  if ($rss) {
    $vers = [regex]::Matches($rss, 'nsis-(\d+(?:\.\d+)+)\.zip') |
      ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
  }
  if ($vers.Count -gt 0) {
    $nsisVer = $vers | Sort-Object { [version]$_ } | Select-Object -Last 1
    Write-Host "解析到 NSIS 最新版本: $nsisVer"
  } else {
    $nsisVer = '3.13'
    Write-Host "::warning::无法解析 NSIS 最新版本，回退 ${nsisVer}（可显式传 nsis-version 固定）"
  }
}

$urls = @(
  "https://downloads.sourceforge.net/project/nsis/NSIS%203/$nsisVer/nsis-$nsisVer.zip",
  "https://master.dl.sourceforge.net/project/nsis/NSIS%203/$nsisVer/nsis-$nsisVer.zip"
)
$zip = "$env:RUNNER_TEMP\nsis-$nsisVer.zip"
if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }

$ok = $false
foreach ($u in $urls) {
  try {
    Write-Host "下载 NSIS $nsisVer from $u ..."
    # 用 curl.exe（Windows 自带）而非 Invoke-WebRequest：SourceForge 返回带签名参数的
    # 302 重定向，Invoke-WebRequest 在部分 runner 上跟随重定向会写入错误页而非真文件，
    # 导致后续 Expand-Archive 拿到损坏 zip 解压失败。curl.exe 能稳定跟随重定向取回真文件。
    curl.exe -L -f -o $zip $u
    if (Test-Path $zip) {
      $ok = $true
      break
    } else {
      Write-Host "下载后文件不存在"
    }
  } catch {
    Write-Host "下载失败: $_"
  }
}
if (-not $ok) {
  Write-Host "NSIS 下载失败：所有镜像均不可用"
  exit 1
}

try {
  Expand-Archive -Path $zip -DestinationPath $dest -Force -ErrorAction Stop
} catch {
  Write-Host "解压失败: $($_.Exception.Message)"
  exit 1
}

# 在解压目录动态探测 makensis.exe（不假设固定目录结构）
$candidates = @(
  "$dest\nsis-$nsisVer\Bin\makensis.exe",
  "$dest\nsis-$nsisVer\makensis.exe"
)
$makensis = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $makensis) {
  $found = Get-ChildItem -Path $dest -Filter makensis.exe -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($found) { $makensis = $found.FullName }
}
if (-not $makensis) {
  Write-Host "makensis.exe 未找到，请检查 NSIS 下载包"
  exit 1
}

# 把 makensis.exe 所在目录加入 PATH
$makensisDir = Split-Path -Parent $makensis
Add-Content -Path $env:GITHUB_PATH -Value $makensisDir
Write-Host "makensis 路径: $makensis"
exit 0
