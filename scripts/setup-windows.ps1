# Installs the external tools Transcue needs on Windows:
#   ffmpeg, yt-dlp (winget) and whisper.cpp (%LOCALAPPDATA%\Programs\whisper.cpp).
# Usage: powershell -ExecutionPolicy Bypass -File scripts\setup-windows.ps1
# Messages are ASCII because Windows PowerShell 5.1 misreads BOM-less UTF-8 scripts.

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue' # Invoke-WebRequest is very slow with the progress bar
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# v1.9.3 and later tags ship no binaries; keep this on a tag that has whisper-bin-x64.zip.
$whisperVersion = 'v1.9.2'
$whisperDir = Join-Path $env:LOCALAPPDATA 'Programs\whisper.cpp'

function Install-WingetPackage([string]$id) {
    winget list --id $id -e --accept-source-agreements *> $null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "$id is already installed."
        return
    }
    Write-Host "Installing $id ..."
    winget install --id $id -e --silent --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -ne 0) { throw "winget install $id failed (exit code $LASTEXITCODE)" }
}

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw 'winget was not found. Install "App Installer" from the Microsoft Store and run this again.'
}

Install-WingetPackage 'Gyan.FFmpeg'
Install-WingetPackage 'yt-dlp.yt-dlp'

if (Test-Path (Join-Path $whisperDir 'whisper-cli.exe')) {
    Write-Host "whisper.cpp is already installed in $whisperDir."
} else {
    Write-Host "Installing whisper.cpp $whisperVersion to $whisperDir ..."
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("transcue-whisper-" + [Guid]::NewGuid())
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $zip = Join-Path $tmp 'whisper-bin-x64.zip'
        $url = "https://github.com/ggml-org/whisper.cpp/releases/download/$whisperVersion/whisper-bin-x64.zip"
        Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
        Expand-Archive -Path $zip -DestinationPath $tmp
        New-Item -ItemType Directory -Force -Path $whisperDir | Out-Null
        Copy-Item -Path (Join-Path $tmp 'Release\*') -Destination $whisperDir -Recurse -Force
    } finally {
        Remove-Item -Recurse -Force $tmp
    }
}

Write-Host 'Done. Restart Transcue if it is running.'
