# 버전 올리기: pubspec.yaml, 앱 안 버전 표시(app_version.dart), CHANGELOG.md를 함께 바꾼다.
# 빌드 번호(Android versionCode)는 1씩 올린다. 바꾼 뒤 PR로 main에 넣고 scripts/release.ps1로 배포한다.
#
# 사용: powershell -File scripts/bump-version.ps1 0.10.0
param(
    [Parameter(Mandatory = $true)][string]$Version
)
$ErrorActionPreference = 'Stop'

if ($Version -notmatch '^\d+\.\d+\.\d+$') {
    throw "버전은 X.Y.Z 형식이어야 합니다: $Version"
}

$root = Split-Path -Parent $PSScriptRoot
$utf8 = New-Object System.Text.UTF8Encoding($false)  # BOM 없이
function Read-Text($path) { [IO.File]::ReadAllText($path, $utf8) }
function Write-Text($path, $text) { [IO.File]::WriteAllText($path, $text, $utf8) }

# pubspec.yaml: version: X.Y.Z+빌드
$pubspecPath = Join-Path $root 'app/pubspec.yaml'
$pubspec = Read-Text $pubspecPath
$m = [regex]::Match($pubspec, '(?m)^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$')
if (-not $m.Success) { throw 'pubspec.yaml에서 version: X.Y.Z+빌드 를 찾지 못했습니다' }
$old = $m.Groups[1].Value
$build = [int]$m.Groups[2].Value + 1
if ([version]$Version -le [version]$old) {
    throw "새 버전($Version)이 지금 버전($old)보다 커야 합니다"
}
$pubspec = [regex]::Replace($pubspec, '(?m)^version:\s*.*$', "version: $Version+$build")
Write-Text $pubspecPath $pubspec

# 앱 안 버전 표시
$verPath = Join-Path $root 'app/lib/src/app_version.dart'
$ver = Read-Text $verPath
$ver = [regex]::Replace($ver, "const appVersion = '[^']*';", "const appVersion = '$Version';")
$ver = [regex]::Replace($ver, 'const appBuild = \d+;', "const appBuild = $build;")
Write-Text $verPath $ver

# CHANGELOG.md: [Unreleased] 아래 내용을 새 버전 항목으로
$logPath = Join-Path $root 'CHANGELOG.md'
$log = Read-Text $logPath
if ($log -notmatch "(?m)^## \[$([regex]::Escape($Version))\]") {
    $date = Get-Date -Format 'yyyy-MM-dd'
    if ($log -notmatch '(?m)^## \[Unreleased\]') { throw 'CHANGELOG.md에 ## [Unreleased] 가 없습니다' }
    # [ \t]*: \s*는 줄바꿈까지 먹어 다음 항목과의 빈 줄이 사라진다
    $log = ([regex]'(?m)^## \[Unreleased\][ \t]*\r?$').Replace($log, "## [Unreleased]`n`n## [$Version] - $date", 1)
    Write-Text $logPath $log
}

Write-Host "버전: $old -> $Version (빌드 $build)"
Write-Host '다음: CHANGELOG.md 내용을 확인하고 PR로 main에 넣은 뒤 scripts/release.ps1'
