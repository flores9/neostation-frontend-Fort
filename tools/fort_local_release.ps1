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

function Get-NativeVersionText {
    param([Parameter(Mandatory = $true)][string]$Executable)

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $Executable
    $startInfo.Arguments = "-version"
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    [void]$process.Start()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    return "$stdout`n$stderr"
}

function Find-Java17Home {
    $candidates = New-Object System.Collections.Generic.List[string]

    if ($env:JAVA_HOME) {
        $candidates.Add($env:JAVA_HOME)
    }

    $candidates.Add("C:\Program Files\Android\Android Studio\jbr")
    $candidates.Add((Join-Path $env:LOCALAPPDATA "Programs\Android Studio\jbr"))

    foreach ($root in @("C:\Program Files\Eclipse Adoptium", "C:\Program Files\Java")) {
        if (Test-Path $root) {
            Get-ChildItem $root -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '17' } |
                ForEach-Object { $candidates.Add($_.FullName) }
        }
    }

    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        $javaExe = Join-Path $candidate "bin\java.exe"
        if (-not (Test-Path $javaExe)) { continue }

        try {
            $versionText = Get-NativeVersionText -Executable $javaExe
        } catch {
            continue
        }

        if ($versionText -match 'version\s+"17\.' -or $versionText -match 'openjdk\s+17\.') {
            return (Resolve-Path $candidate).Path
        }
    }

    return $null
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

# Match upstream Android CI: JDK 17. Reuse JAVA_HOME, Android Studio's bundled
# JBR or a normal JDK 17 installation without changing machine-wide settings.
$Java17Home = Find-Java17Home
if ($Java17Home) {
    $env:JAVA_HOME = $Java17Home
    $env:Path = "$(Join-Path $Java17Home 'bin');$env:Path"
    Write-Host "Java 17: $Java17Home"
} else {
    throw "JDK 17 was not found. Install Temurin 17 (for example: winget install EclipseAdoptium.Temurin.17.JDK), reopen PowerShell, and rerun this same command."
}

$FlutterMode = $null
$FlutterExe = $null
$DartExe = $null

if (Get-Command fvm -ErrorAction SilentlyContinue) {
    $FlutterMode = "fvm"
    Invoke-Checked "Install/select Flutter $RequiredFlutter with FVM" {
        & fvm install $RequiredFlutter
        if ($LASTEXITCODE -ne 0) { return }
        & fvm use $RequiredFlutter --force
    }
} elseif (Get-Command flutter -ErrorAction SilentlyContinue) {
    $FlutterMode = "path"
    $FlutterExe = (Get-Command flutter).Source
    $dartCommand = Get-Command dart -ErrorAction SilentlyContinue
    if ($dartCommand) { $DartExe = $dartCommand.Source }
    Write-Warning "FVM is not installed. The script will use Flutter from PATH; the exact version will be verified below."
} else {
    # First-machine bootstrap. Keep the SDK outside the repository so `git status`
    # stays clean and future Fort releases can reuse the same pinned toolchain.
    $SdkParent = Join-Path $env:USERPROFILE ".fort\flutter"
    $SdkRoot = Join-Path $SdkParent $RequiredFlutter
    $FlutterExe = Join-Path $SdkRoot "bin\flutter.bat"
    $DartExe = Join-Path $SdkRoot "bin\dart.bat"

    if (-not (Test-Path $FlutterExe)) {
        if (Test-Path $SdkRoot) {
            Remove-Item $SdkRoot -Recurse -Force
        }
        New-Item $SdkParent -ItemType Directory -Force | Out-Null
        Invoke-Checked "Bootstrap Flutter $RequiredFlutter from the official Git tag" {
            & git clone --branch $RequiredFlutter --depth 1 https://github.com/flutter/flutter.git $SdkRoot
        }
    } else {
        Write-Host "Reusing local Fort Flutter SDK: $SdkRoot"
    }

    $FlutterMode = "local"
}

function Invoke-Flutter {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
    if ($FlutterMode -eq "fvm") {
        & fvm flutter @Args
    } else {
        & $FlutterExe @Args
    }
}

function Invoke-Dart {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
    if ($FlutterMode -eq "fvm") {
        & fvm dart @Args
    } elseif ($DartExe -and (Test-Path $DartExe)) {
        & $DartExe @Args
    } elseif (Get-Command dart -ErrorAction SilentlyContinue) {
        & dart @Args
    } else {
        throw "Dart was not found next to the selected Flutter SDK."
    }
}

Invoke-Checked "Flutter version" { Invoke-Flutter --version }
$ActualFlutterVersion = (Invoke-Flutter --version --machine | ConvertFrom-Json).frameworkVersion
if ($ActualFlutterVersion -ne $RequiredFlutter) {
    throw "Flutter version mismatch. Required $RequiredFlutter, found $ActualFlutterVersion."
}

if ($FlutterMode -eq "local") {
    Invoke-Checked "Precache Android Flutter artifacts" { Invoke-Flutter precache --android }
}

$KeyProperties = Join-Path $RepoRoot "android\key.properties"
if (-not (Test-Path $KeyProperties) -and -not $AllowDebugSigning) {
    throw "android\key.properties is missing. Run .\tools\fort_setup_signing.ps1 once for permanent Fort signing, or use -AllowDebugSigning only for a disposable test APK."
}

$DistRoot = Join-Path $RepoRoot "dist\$ReleaseName"
if (Test-Path $DistRoot) { Remove-Item $DistRoot -Recurse -Force }
New-Item $DistRoot -ItemType Directory -Force | Out-Null
$Logs = Join-Path $DistRoot "logs"
New-Item $Logs -ItemType Directory -Force | Out-Null

# Match upstream CI: never silently rewrite a lock file during a release build.
Invoke-Checked "Flutter dependencies" { Invoke-Flutter pub get --enforce-lockfile }

# Match upstream CI: formatting is checked across the repository, not only lib/test.
Invoke-Checked "Dart formatting check" {
    Invoke-Dart format --output=none --set-exit-if-changed .
}

if (-not $SkipAnalyze) {
    Invoke-Checked "Flutter analyze" { Invoke-Flutter analyze }
}

if (-not $SkipTests) {
    if ($env:OS -eq "Windows_NT") {
        # Upstream's authoritative PR test job runs on ubuntu-latest. A small
        # set of unchanged upstream tests is intentionally POSIX/Linux-specific
        # (chmod, Linux executable names, symlinks and POSIX separator asserts)
        # and cannot be evaluated faithfully by the Windows Dart VM. Exclude
        # only those host-specific files; every remaining upstream test plus all
        # Fort/ES-DE tests still gates the local Android build.
        $WindowsIncompatibleTests = @(
            "artwork_cache_test.dart",
            "launcher_service_linux_hints_test.dart",
            "linux_emulator_discovery_test.dart",
            "retroarch_linux_config_discovery_test.dart",
            "rom_scan_symlink_alias_test.dart",
            "storage_space_service_test.dart"
        )
        $TestFiles = Get-ChildItem (Join-Path $RepoRoot "test") -Recurse -File -Filter "*_test.dart" |
            Where-Object { $WindowsIncompatibleTests -notcontains $_.Name } |
            ForEach-Object { $_.FullName }

        Write-Host "Windows host: excluding upstream Linux/POSIX-only test files:"
        $WindowsIncompatibleTests | ForEach-Object { Write-Host "  - $_" }
        Write-Host "Running $($TestFiles.Count) host-compatible test files (including all Fort tests)."
        Invoke-Checked "Flutter tests (Windows host-compatible gate)" {
            Invoke-Flutter test @TestFiles
        }
    } else {
        Invoke-Checked "Flutter tests" { Invoke-Flutter test }
    }
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
Copy-Item "tools\fort_setup_signing.ps1" $DistRoot -Force

$Manifest = @"
NeoStation Fort local release manifest
Release: $ReleaseName
Branch: $Branch
Commit: $Commit
Flutter required: $RequiredFlutter
Flutter mode: $FlutterMode
JAVA_HOME: $env:JAVA_HOME
Generated: $((Get-Date).ToString('o'))
Signing config present: $(Test-Path $KeyProperties)
Skip tests: $SkipTests
Skip analyze: $SkipAnalyze
Windows host-aware test exclusions: $($env:OS -eq "Windows_NT")
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
