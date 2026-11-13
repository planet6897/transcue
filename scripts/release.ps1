# 배포: main의 지금 버전을 빌드해 태그(vX.Y.Z)를 달고 GitHub Release에 올린다.
#  - Windows: transcue-X.Y.Z-windows-x64.zip (Release 폴더 전체)
#  - Android: transcue-X.Y.Z-android.apk
# 버전은 scripts/bump-version.ps1로 미리 올려 main에 넣어 둔다.
#
# 사용: powershell -File scripts/release.ps1            # 빌드 → 태그 → GitHub Release
#       powershell -File scripts/release.ps1 -DryRun    # 빌드와 묶기까지만 (태그·업로드 안 함)
#       -AllowDirty: 커밋하지 않은 변경이 있어도 진행 (그 변경이 빌드에 들어간다)
param(
    [switch]$DryRun,
    [switch]$AllowDirty
)
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$app = Join-Path $root 'app'
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Run($exe, [string[]]$argList) {
    & $exe @argList
    if ($LASTEXITCODE -ne 0) { throw "$exe $($argList -join ' ') 실패 (exit $LASTEXITCODE)" }
}

Push-Location $root
try {
    # ---- 버전과 상태 확인 ----
    $pubspec = [IO.File]::ReadAllText((Join-Path $app 'pubspec.yaml'), $utf8)
    $m = [regex]::Match($pubspec, '(?m)^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$')
    if (-not $m.Success) { throw 'pubspec.yaml에서 version: X.Y.Z+빌드 를 찾지 못했습니다' }
    $ver = $m.Groups[1].Value
    $build = $m.Groups[2].Value
    $tag = "v$ver"
    Write-Host "== Transcue $ver (빌드 $build)"

    $branch = (git rev-parse --abbrev-ref HEAD).Trim()
    if ($branch -ne 'main') { throw "main 브랜치에서 배포합니다 (지금: $branch)" }
    Run git @('fetch', '--quiet', 'origin', 'main', '--tags')
    if ((git rev-parse HEAD).Trim() -ne (git rev-parse origin/main).Trim()) {
        throw 'main이 origin/main과 다릅니다. git pull 또는 push 후 다시 실행하세요'
    }
    if (git tag --list $tag) { throw "태그 $tag 가 이미 있습니다. bump-version.ps1로 버전을 올리세요" }
    $dirty = git status --porcelain --untracked-files=no
    if ($dirty -and -not $AllowDirty) {
        throw "커밋하지 않은 변경이 있습니다 (빌드에 섞여 들어갑니다):`n$($dirty -join "`n")`n그대로 진행하려면 -AllowDirty"
    }

    # CHANGELOG의 이 버전 항목 → Release 설명
    $log = [IO.File]::ReadAllText((Join-Path $root 'CHANGELOG.md'), $utf8)
    $sec = [regex]::Match($log, "(?ms)^## \[$([regex]::Escape($ver))\][^\n]*\n(.*?)(?=^## \[|\z)")
    if (-not $sec.Success) { throw "CHANGELOG.md에 ## [$ver] 항목이 없습니다" }
    $notes = $sec.Groups[1].Value.Trim()

    # ---- 테스트와 빌드 ----
    Push-Location $app
    try {
        Run flutter @('test')
        Run flutter @('build', 'windows', '--release')
        Run flutter @('build', 'apk', '--release')
    } finally { Pop-Location }

    # ---- 묶기 ----
    $dist = Join-Path $root "dist/$ver"
    New-Item -ItemType Directory -Force $dist | Out-Null
    $zip = Join-Path $dist "transcue-$ver-windows-x64.zip"
    $apk = Join-Path $dist "transcue-$ver-android.apk"
    if (Test-Path $zip) { Remove-Item $zip -Confirm:$false }
    Compress-Archive -Path (Join-Path $app 'build/windows/x64/runner/Release/*') -DestinationPath $zip
    Copy-Item (Join-Path $app 'build/app/outputs/flutter-apk/app-release.apk') $apk -Force
    $notesPath = Join-Path $dist 'notes.md'
    [IO.File]::WriteAllText($notesPath, $notes, $utf8)
    Get-ChildItem $dist | ForEach-Object { Write-Host ("  {0}  {1:N1}MB" -f $_.Name, ($_.Length / 1MB)) }

    if ($DryRun) {
        Write-Host '== DryRun: 태그와 GitHub Release는 만들지 않았습니다'
        return
    }

    # ---- 태그와 GitHub Release ----
    Run git @('tag', '-a', $tag, '-m', "Transcue $ver")
    Run git @('push', 'origin', $tag)
    Run gh @('release', 'create', $tag, $zip, $apk, '--title', "Transcue $ver", '--notes-file', $notesPath)
    Write-Host "== 배포 완료: $tag"
} finally { Pop-Location }
