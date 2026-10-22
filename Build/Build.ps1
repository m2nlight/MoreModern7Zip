param(
    [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
    [string] $BuildVersion
)

$ErrorActionPreference = 'Stop'

$workDir = $PSScriptRoot
$buildDir = "$workDir\$BuildVersion"
$tempDir = "$workDir\Temp"

$currentDir = Get-Location

if (-not (Test-Path $tempDir)) {
    New-Item -ItemType Directory -Path $tempDir | Out-Null
}

# 优先使用 Visual Studio Installer 自带的 vswhere.exe，其次回退到已下载的版本
$vswhere = @(
    'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe',
    "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe",
    "$tempDir\VsWhere\tools\vswhere.exe"
) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1

if (-not $vswhere) {
    # 以上路径都不存在时下载并解压 VsWhere
    if (-not (Test-Path "$tempDir\vswhere.zip")) {
        Invoke-WebRequest -Uri "https://www.nuget.org/api/v2/package/vswhere" -OutFile "$tempDir\vswhere.zip" -UseBasicParsing
    }
    Expand-Archive -Path "$tempDir\vswhere.zip" -DestinationPath "$tempDir\VsWhere" -Force
    $vswhere = "$tempDir\VsWhere\tools\vswhere.exe"
    if (-not (Test-Path -LiteralPath $vswhere)) {
        throw 'vswhere.exe not found.'
    }
}

# 查找Visual Studio安装路径
$vswhereArgs = @('-latest', '-products', '*', '-requires', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', '-property', 'installationPath')
$vsInstallPath = & "$vswhere" @vswhereArgs
if ($LASTEXITCODE -ne 0 -or -not $vsInstallPath) {
    # 正式版未找到时尝试预览版（如 Visual Studio Insiders）
    $vsInstallPath = & "$vswhere" -prerelease @vswhereArgs
}
if (-not $vsInstallPath) {
    throw 'Visual Studio with x86/x64 C++ tools not found.'
}
$vsInstallPath = $vsInstallPath.Trim()

$vsDevCmd = Join-Path $vsInstallPath 'Common7\Tools\VsDevCmd.bat'
if (-not (Test-Path -LiteralPath $vsDevCmd)) {
    throw "Cannot locate VsDevCmd.bat in '$vsInstallPath'."
}

function Invoke-Nmake {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,
        [Parameter(Mandatory = $true)]
        [string] $Platform
    )

    # 32 位目标必须使用 x86 工具链，其中才包含 32 位汇编器 ml.exe（x64 工具目录下只有 ml64.exe）。
    # 不能在同一个 PowerShell 会话中使用 Enter-VsDevShell 反复切换架构：
    # 切换可能不生效，导致 x86 构建仍然调用 x64 的 cl.exe 并且找不到 ml.exe。
    # 因此这里为每次构建单独启动一个 cmd.exe，先按架构初始化环境再执行 nmake。
    if ($Platform -eq 'x86') {
        $arch = 'x86'
        $tools = @('cl', 'ml', 'link', 'rc')
    } else {
        $arch = 'amd64'
        $tools = @('cl', 'ml64', 'link', 'rc')
    }

    Write-Host "Building $Path ($Platform)"
    Set-Location $Path

    $bootstrapFile = Join-Path $tempDir "build-$Platform.cmd"
    $bootstrap = @(
        '@echo off'
        "call ""$vsDevCmd"" -arch=$arch -host_arch=amd64 -no_logo"
        'if errorlevel 1 exit /b 1'
    )
    foreach ($tool in $tools) {
        $bootstrap += "where $tool >nul 2>&1"
        $bootstrap += "if errorlevel 1 (echo [ERROR] '$tool' not found in the '$arch' toolset. & exit /b 1)"
    }
    $bootstrap += "nmake PLATFORM=$Platform"
    $bootstrap += 'exit /b %ERRORLEVEL%'
    Set-Content -LiteralPath $bootstrapFile -Value $bootstrap -Encoding ASCII

    try {
        & cmd.exe /c "`"$bootstrapFile`""
        if ($LASTEXITCODE -ne 0) {
            throw "Build failed: $Path ($Platform)"
        }
    } finally {
        Remove-Item -LiteralPath $bootstrapFile -Force -ErrorAction SilentlyContinue
    }
}

try {
    # 编译7-Zip本体及其安装卸载程序
    Invoke-Nmake "$buildDir\CPP\7zip" 'x64'
    Invoke-Nmake "$buildDir\C\Util\7zipInstall" 'x64'
    Invoke-Nmake "$buildDir\C\Util\7zipUninstall" 'x64'

    # 编译32位Shell拓展
    Invoke-Nmake "$buildDir\CPP\7zip\UI\Explorer" 'x86'
} finally {
    # 回到原始目录
    Set-Location $currentDir
}
