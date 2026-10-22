param(
    [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
    [string] $BuildVersion
)

$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 默认可能未启用 TLS 1.2，会导致下载失败
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {
    Write-Warning 'Cannot enable TLS 1.2.'
}
# 禁用 Invoke-WebRequest 自带进度条，改用下面的自定义下载进度显示
$ProgressPreference = 'SilentlyContinue'

$workDir = $PSScriptRoot
$tempDir = "$workDir\Temp"
$buildDir = "$workDir\$BuildVersion"

# 版本号转换为 Release Tag：7z2605 -> 26.05
$buildVersionTag = $BuildVersion -replace '^7z(\d{2})(\d{2})$', '$1.$2'
if ($buildVersionTag -eq $BuildVersion) {
    throw "Cannot convert '$BuildVersion' to a release tag."
}

function Format-DataSize {
    param(
        [Parameter(Mandatory = $true)]
        [double] $Bytes
    )

    $units = @('B', 'KB', 'MB', 'GB', 'TB')
    $index = 0
    while ($Bytes -ge 1024 -and $index -lt ($units.Length - 1)) {
        $Bytes /= 1024
        $index++
    }

    if ($index -eq 0) {
        return "$([int]$Bytes) $($units[$index])"
    }
    return "$($Bytes.ToString('0.0')) $($units[$index])"
}

# 在同一行刷新进度条，避免刷屏
function Write-DownloadProgress {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,
        [Parameter(Mandatory = $true)]
        [long] $BytesReceived,
        [Parameter(Mandatory = $true)]
        [long] $TotalBytes
    )

    $label = if ($Name.Length -gt 20) { $Name.Substring(0, 20) } else { $Name.PadRight(20) }

    if ($TotalBytes -gt 0) {
        $barWidth = 24
        $ratio = [Math]::Min(1.0, $BytesReceived / $TotalBytes)
        $filled = [int][Math]::Floor($ratio * $barWidth)
        $bar = ('#' * $filled).PadRight($barWidth, '-')
        $text = '{0} [{1}] {2,6:P1}  {3} / {4}' -f $label,
            $bar,
            $ratio,
            (Format-DataSize $BytesReceived),
            (Format-DataSize $TotalBytes)
    } else {
        # 服务端未返回长度时只显示已下载大小
        $spinner = '|/-\'
        $char = $spinner[[int]([Math]::Floor($BytesReceived / 262144) % $spinner.Length)]
        $text = '{0} {1}  {2}' -f $label, $char, (Format-DataSize $BytesReceived)
    }

    $width = 120
    try {
        if ([Console]::WindowWidth -gt 20) {
            $width = [Console]::WindowWidth - 1
        }
    } catch {
        # 输出被重定向时无法获取窗口宽度
    }

    Write-Host -NoNewLine ("`r" + $text.PadRight($width))
}

# 流式下载，边写文件边显示进度
function Invoke-FileDownload {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Url,
        [Parameter(Mandatory = $true)]
        [string] $OutFile,
        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    $request = [Net.WebRequest]::Create($Url)
    $request.Method = 'GET'
    $request.UserAgent = 'MoreModern7Zip'
    $request.Timeout = 60000
    $request.ReadWriteTimeout = 60000

    $response = $null
    $fileStream = $null
    try {
        $response = $request.GetResponse()
        $totalBytes = $response.ContentLength
        $buffer = New-Object byte[] 262144
        $received = [long]0
        $lastUpdate = [DateTime]::MinValue

        $fileStream = [IO.File]::Create($OutFile)
        $stream = $response.GetResponseStream()
        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $fileStream.Write($buffer, 0, $read)
            $received += $read

            if (([DateTime]::UtcNow - $lastUpdate).TotalMilliseconds -ge 100) {
                $lastUpdate = [DateTime]::UtcNow
                Write-DownloadProgress -Name $Name -BytesReceived $received -TotalBytes $totalBytes
            }
        }

        Write-DownloadProgress -Name $Name -BytesReceived $received -TotalBytes $totalBytes
    } finally {
        Write-Host ''
        if ($fileStream) { $fileStream.Dispose() }
        if ($response) { $response.Dispose() }
    }
}

function Save-ReleaseFile {
    param(
        [Parameter(Mandatory = $true)]
        [string] $FileName,
        [Parameter(Mandatory = $true)]
        [string] $OutFile
    )

    # GitHub Release 为主，官方镜像作为备用
    $urls = @(
        "https://github.com/ip7z/7zip/releases/download/$buildVersionTag/$FileName",
        "https://7-zip.org/a/$FileName"
    )

    foreach ($url in $urls) {
        try {
            Write-Host "Downloading $url"
            Invoke-FileDownload -Url $url -OutFile $OutFile -Name $FileName
            if ((Get-Item -LiteralPath $OutFile).Length -gt 0) {
                return
            }
            throw 'Downloaded file is empty.'
        } catch {
            Write-Warning "Download failed: $($_.Exception.Message)"
            Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
        }
    }

    throw "Cannot download '$FileName'."
}

if (-not (Test-Path $tempDir)) {
    New-Item -ItemType Directory -Path $tempDir | Out-Null
}

# 下载7zr
if (-not (Test-Path "$tempDir\7zr.exe")) {
    Save-ReleaseFile '7zr.exe' "$tempDir\7zr.exe"
}

# 下载并解压源码
if (-not (Test-Path $buildDir)) {
    $srcArchive = "$tempDir\$BuildVersion-src.7z"
    if (-not (Test-Path $srcArchive)) {
        Save-ReleaseFile "$BuildVersion-src.7z" $srcArchive
    }
    & "$tempDir\7zr.exe" x "$srcArchive" -o"$buildDir" -y
    if ($LASTEXITCODE -ne 0) {
        Remove-Item -LiteralPath $buildDir -Recurse -Force -ErrorAction SilentlyContinue
        throw "Cannot extract '$srcArchive'."
    }
}

# 如果子流程存在则调用子流程用于自定义操作源码
$subPrepareScript = "$workDir\SubPrepare.ps1"
if (Test-Path $subPrepareScript) {
    & $subPrepareScript $buildDir $BuildVersion
}
