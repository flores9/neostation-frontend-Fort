[CmdletBinding()]
param(
    [string]$ReleaseName = "NeoStation-Fort-R1",
    [switch]$AllowDebugSigning,
    [switch]$SkipTests,
    [switch]$SkipAnalyze
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][scriptblock]$Command
    )
    Write-Host "=== $Label ==="
    & $Command
    if ($LASTEXITCODE -ne 0) {
        throw "$Label failed with exit code $LASTEXITCODE"
    }
}

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Set-Location $RepoRoot

Write-Host "NeoStation Fort local release"
Write-Host "Repository: $RepoRoot"

if (-not (Test-Path ".git")) {
    throw "Run this script from a Git checkout of NeoStation Fort."
}

$Branch = (git branch --show-current).Trim()
if ($LASTEXITCODE -ne 0) { throw "Could not read the current Git branch." }
$Commit = (git rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0) { throw "Could not read the current Git commit." }

Write-Host "Branch: $Branch"
Write-Host "Commit: $Commit"

if ($Branch -eq "main") {
    throw "Refusing to build a Fort release directly from main. Use a Fort release/development branch."
}

$Dirty = git status --porcelain
if ($LASTEXITCODE -ne 0) { throw "Could not inspect Git working tree." }
if ($Dirty) {
    throw "Working tree is not clean. Commit or stash changes before building a release."
}

$FvmConfig = Get-Content ".fvmrc" -Raw | ConvertFrom-Json
$RequiredFlutter = [string]$FvmConfig.flutter

$FlutterCommand = $null
$FlutterPrefix = @()
if (Get-Command fvm -ErrorAction SilentlyContinue) {
    $FlutterCommand = "fvm"
    $FlutterPrefix = @("flutter")
    Invoke-Checked "Install/select Flutter $RequiredFlutter with FVM" {
        & fvm install $RequiredFlutter
        if ($LASTEXITCODE -ne 0) { return }
        & fvm use $RequiredFlutter --force
    }
} elseif (Get-Command flutter -ErrorAction SilentlyContinue) {
    $FlutterCommand = "flutter"
    Write-Warning "FVM is not installed. The script will use Flutter from PATH; verify it is $RequiredFlutter."
} else {
    throw "Flutter was not found. Install FVM (recommended) or Flutter $RequiredFlutter and reopen PowerShell."
}

function Invoke-Flutter {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
    if ($FlutterCommand -eq "fvm") {
        & fvm flutter @Args
    } else {
        & flutter @Args
    }
}

Invoke-Checked "Flutter version" { Invoke-Flutter --version }

$Java = Get-Command java -ErrorAction SilentlyContinue
if (-not $Java) {
    if ($env:JAVA_HOME -and (Test-Path (Join-Path $env:JAVA_HOME "bin\java.exe"))) {
        $env:Path = "$(Join-Path $env:JAVA_HOME 'bin');$env:Path"
    } else {
        throw "Java was not found. Install/configure JDK 17 and set JAVA_HOME."
    }
}

$KeyProperties = Join-Path $RepoRoot "android\key.properties"
if (-not (Test-Path $KeyProperties) -and -not $AllowDebugSigning) {
    throw "android\key.properties is missing. A publishable Fort release requires permanent signing. Use -AllowDebugSigning only for a disposable test APK."
}

$DistRoot = Join-Path $RepoRoot "dist\$ReleaseName"
if (Test-Path $DistRoot) { Remove-Item $DistRoot -Recurse -Force }
New-Item $DistRoot -ItemType Directory -Force | Out-Null
$Logs = Join-Path $DistRoot "logs"
New-Item $Logs -ItemType Directory -Force | Out-Null

Invoke-Checked "Flutter dependencies" { Invoke-Flutter pub get }

Invoke-Checked "Dart formatting check" {
    if ($FlutterCommand -eq "fvm") {
        & fvm dart format --output=none --set-exit-if-changed lib test
    } else {
        & dart format --output=none --set-exit-if-changed lib test
    }
}

if (-not $SkipAnalyze) {
    Invoke-Checked "Flutter analyze" { Invoke-Flutter analyze }
}

if (-not $SkipTests) {
    Invoke-Checked "Flutter tests" { Invoke-Flutter test }
}

Invoke-Checked "Build Android ARM64 release APK" {
    Invoke-Flutter build apk --release --split-per-abi --target-platform android-arm64
}

$ApkCandidates = @(
    (Join-Path $RepoRoot "build\app\outputs\flutter-apk\app-arm64-v8a-release.apk"),
    (Join-Path $RepoRoot "build\app\outputs\flutter-apk\app-release.apk")
)
$BuiltApk = $ApkCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $BuiltApk) {
    throw "Build completed but no ARM64 release APK was found in build\app\outputs\flutter-apk."
}

$FinalApk = Join-Path $DistRoot "$ReleaseName-arm64-v8a.apk"
Copy-Item $BuiltApk $FinalApk -Force

$DocsTarget = Join-Path $DistRoot "docs"
New-Item $DocsTarget -ItemType Directory -Force | Out-Null
if (Test-Path "docs\fort") {
    Copy-Item "docs\fort\*" $DocsTarget -Recurse -Force
}
Copy-Item "tools\fort_local_release.ps1" $DistRoot -Force

$Manifest = @"
NeoStation Fort local release manifest
Release: $ReleaseName
Branch: $Branch
Commit: $Commit
Flutter required: $RequiredFlutter
Generated: $((Get-Date).ToString('o'))
Signing config present: $(Test-Path $KeyProperties)
Skip tests: $SkipTests
Skip analyze: $SkipAnalyze
"@
Set-Content (Join-Path $DistRoot "BUILD_MANIFEST.txt") $Manifest -Encoding UTF8

git log -n 30 --pretty=format:"%H`t%ad`t%s" --date=iso-strict | Set-Content (Join-Path $DistRoot "GIT_HISTORY.txt") -Encoding UTF8

git diff "58e94a65788a800db8805d622fa88dc8bf485877..HEAD" --stat | Set-Content (Join-Path $DistRoot "UPSTREAM_BASE_DIFFSTAT.txt") -Encoding UTF8

$Hashes = Get-ChildItem $DistRoot -File -Recurse | Where-Object { $_.Name -ne "SHA256SUMS.txt" } | ForEach-Object {
    $hash = Get-FileHash $_.FullName -Algorithm SHA256
    $relative = [IO.Path]::GetRelativePath($DistRoot, $_.FullName).Replace('\', '/')
    "$($hash.Hash.ToLowerInvariant())  $relative"
}
$Hashes | Set-Content (Join-Path $DistRoot "SHA256SUMS.txt") -Encoding ASCII

$ZipPath = Join-Path (Split-Path $DistRoot -Parent) "$ReleaseName-delivery.zip"
if (Test-Path $ZipPath) { Remove-Item $ZipPath -Force }
Compress-Archive -Path (Join-Path $DistRoot "*") -DestinationPath $ZipPath -CompressionLevel Optimal

Write-Host ""
Write-Host "=== Release package ready ==="
Write-Host "APK: $FinalApk"
Write-Host "Folder: $DistRoot"
Write-Host "ZIP: $ZipPath"
Write-Host "Commit: $Commit"
