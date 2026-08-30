[CmdletBinding()]
param(
    [string]$ReleaseName = "NeoStation-Fort-R1",
    [string]$UpstreamBase = "58e94a65788a800db8805d622fa88dc8bf485877",
    [switch]$AllowDirty
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Assert-ExitCode {
    param([Parameter(Mandatory = $true)][string]$Label)
    if ($LASTEXITCODE -ne 0) {
        throw "$Label failed with exit code $LASTEXITCODE"
    }
}

function Get-RelativePathCompat {
    param(
        [Parameter(Mandatory = $true)][string]$BasePath,
        [Parameter(Mandatory = $true)][string]$TargetPath
    )

    $baseFull = [IO.Path]::GetFullPath($BasePath).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    ) + [IO.Path]::DirectorySeparatorChar
    $targetFull = [IO.Path]::GetFullPath($TargetPath)

    if ($targetFull.StartsWith($baseFull, [StringComparison]::OrdinalIgnoreCase)) {
        return $targetFull.Substring($baseFull.Length)
    }

    return $targetFull
}

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Set-Location $RepoRoot

if (-not (Test-Path ".git")) {
    throw "Run this script from a Git checkout of NeoStation Fort."
}

$Branch = (git branch --show-current).Trim()
Assert-ExitCode "Read current branch"
$Commit = (git rev-parse HEAD).Trim()
Assert-ExitCode "Read current commit"

if (-not $AllowDirty) {
    $Dirty = git status --porcelain
    Assert-ExitCode "Inspect working tree"
    if ($Dirty) {
        throw "Working tree is not clean. Commit/pull the checkpoint changes first, or use -AllowDirty only for diagnostics."
    }
}

$DistParent = Join-Path $RepoRoot "dist"
$PackageRoot = Join-Path $DistParent "$ReleaseName-checkpoint"
if (Test-Path $PackageRoot) {
    Remove-Item $PackageRoot -Recurse -Force
}
New-Item $PackageRoot -ItemType Directory -Force | Out-Null

$ApkCandidates = @(
    (Join-Path $RepoRoot "dist\$ReleaseName\$ReleaseName-arm64-v8a.apk"),
    (Join-Path $RepoRoot "build\app\outputs\flutter-apk\app-arm64-v8a-release.apk"),
    (Join-Path $RepoRoot "build\app\outputs\flutter-apk\app-release.apk")
)
$Apk = $ApkCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $Apk) {
    throw "No built APK found. Build the technical/final APK first, then rerun this checkpoint packager."
}

Copy-Item $Apk (Join-Path $PackageRoot "$ReleaseName-arm64-v8a.apk") -Force

$SourceZip = Join-Path $PackageRoot "$ReleaseName-source-$($Commit.Substring(0, 12)).zip"
& git archive --format=zip --output=$SourceZip HEAD
Assert-ExitCode "Archive exact Git HEAD"

$DocsTarget = Join-Path $PackageRoot "docs"
New-Item $DocsTarget -ItemType Directory -Force | Out-Null
if (Test-Path "docs\fort") {
    Copy-Item "docs\fort\*" $DocsTarget -Recurse -Force
}

$ToolsTarget = Join-Path $PackageRoot "tools"
New-Item $ToolsTarget -ItemType Directory -Force | Out-Null
foreach ($tool in @(
    "tools\fort_local_release.ps1",
    "tools\fort_setup_signing.ps1",
    "tools\fort_package_checkpoint.ps1"
)) {
    if (Test-Path $tool) {
        Copy-Item $tool $ToolsTarget -Force
    }
}

$Manifest = @"
NeoStation Fort project checkpoint
Release/checkpoint: $ReleaseName
Branch: $Branch
Commit: $Commit
Upstream base: $UpstreamBase
Generated: $((Get-Date).ToString('o'))
APK source: $Apk
Source snapshot: exact tracked contents of Git HEAD via git archive
Secrets included: NO
Git metadata included: NO
Build caches included: NO

Important release status:
- This packager does not promote a technical APK to a final signed release.
- Signing/validation status must be read from the release notes/checklist for this checkpoint.
- Permanent keystore/password material is intentionally excluded.
"@
Set-Content (Join-Path $PackageRoot "CHECKPOINT_MANIFEST.txt") $Manifest -Encoding UTF8

git log -n 50 --pretty=format:"%H`t%ad`t%s" --date=iso-strict |
    Set-Content (Join-Path $PackageRoot "GIT_HISTORY.txt") -Encoding UTF8
Assert-ExitCode "Write Git history"

git diff "$UpstreamBase..HEAD" --stat |
    Set-Content (Join-Path $PackageRoot "UPSTREAM_BASE_DIFFSTAT.txt") -Encoding UTF8
Assert-ExitCode "Write upstream diff summary"

git diff "$UpstreamBase..HEAD" --name-status |
    Set-Content (Join-Path $PackageRoot "UPSTREAM_BASE_FILES.txt") -Encoding UTF8
Assert-ExitCode "Write upstream changed-file list"

$Hashes = Get-ChildItem $PackageRoot -File -Recurse |
    Where-Object { $_.Name -ne "SHA256SUMS.txt" } |
    Sort-Object FullName |
    ForEach-Object {
        $hash = Get-FileHash $_.FullName -Algorithm SHA256
        $relative = (Get-RelativePathCompat -BasePath $PackageRoot -TargetPath $_.FullName).Replace('\', '/')
        "$($hash.Hash.ToLowerInvariant())  $relative"
    }
$Hashes | Set-Content (Join-Path $PackageRoot "SHA256SUMS.txt") -Encoding ASCII

$ZipPath = Join-Path $DistParent "$ReleaseName-project-checkpoint-$($Commit.Substring(0, 12)).zip"
if (Test-Path $ZipPath) {
    Remove-Item $ZipPath -Force
}
Compress-Archive -Path (Join-Path $PackageRoot "*") -DestinationPath $ZipPath -CompressionLevel Optimal

$ZipHash = (Get-FileHash $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content "$ZipPath.sha256.txt" "$ZipHash  $(Split-Path $ZipPath -Leaf)" -Encoding ASCII

Write-Host ""
Write-Host "=== NeoStation Fort project checkpoint ready ==="
Write-Host "APK: $(Join-Path $PackageRoot "$ReleaseName-arm64-v8a.apk")"
Write-Host "Source: $SourceZip"
Write-Host "Folder: $PackageRoot"
Write-Host "ZIP: $ZipPath"
Write-Host "ZIP SHA256: $ZipHash"
Write-Host "Commit: $Commit"
