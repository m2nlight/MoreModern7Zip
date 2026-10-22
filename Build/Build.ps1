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

function Invoke-Nmake {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,
        [Parameter(Mandatory = $true)]
        [string] $Platform
    )

    Write-Host "Building $Path ($Platform)"
    Set-Location $Path
    & nmake PLATFORM=$Platform
    if ($LASTEXITCODE -ne 0) {
        throw "Build failed: $Path ($Platform)"
    }
}

try {
    Import-Module "$vsInstallPath\Common7\Tools\Microsoft.VisualStudio.DevShell.dll"

    # 进入x64编译环境
    Enter-VsDevShell -VsInstallPath $vsInstallPath -DevCmdArguments "-arch=amd64 -host_arch=amd64" -SkipAutomaticLocation

    # 编译7-Zip本体及其安装卸载程序
    Invoke-Nmake "$buildDir\CPP\7zip" 'x64'
    Invoke-Nmake "$buildDir\C\Util\7zipInstall" 'x64'
    Invoke-Nmake "$buildDir\C\Util\7zipUninstall" 'x64'

    # 进入x86编译环境
    Enter-VsDevShell -VsInstallPath $vsInstallPath -DevCmdArguments "-arch=x86 -host_arch=amd64" -SkipAutomaticLocation

    # 编译32位Shell拓展
    Invoke-Nmake "$buildDir\CPP\7zip\UI\Explorer" 'x86'
} finally {
    # 回到原始目录
    Set-Location $currentDir
}
