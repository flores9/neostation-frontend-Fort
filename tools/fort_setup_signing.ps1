[CmdletBinding()]
param(
    [string]$Alias = "neostation-fort",
    [string]$DistinguishedName = "CN=NeoStation Fort, OU=Fort, O=NeoStation Fort, L=Sevilla, ST=Sevilla, C=ES"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$AndroidRoot = Join-Path $RepoRoot "android"
$KeyPropertiesPath = Join-Path $AndroidRoot "key.properties"
$SigningDir = Join-Path $env:USERPROFILE ".neostation-fort\signing"
$KeystorePath = Join-Path $SigningDir "neostation-fort-release.jks"

if (-not (Get-Command keytool -ErrorAction SilentlyContinue)) {
    if ($env:JAVA_HOME -and (Test-Path (Join-Path $env:JAVA_HOME "bin\keytool.exe"))) {
        $env:Path = "$(Join-Path $env:JAVA_HOME 'bin');$env:Path"
    } else {
        throw "keytool was not found. Install/configure JDK 17 and set JAVA_HOME."
    }
}

if ((Test-Path $KeystorePath) -or (Test-Path $KeyPropertiesPath)) {
    Write-Host "Existing Fort signing material detected."
    Write-Host "Keystore: $KeystorePath"
    Write-Host "Properties: $KeyPropertiesPath"
    throw "Refusing to overwrite permanent signing material. Back it up and remove it manually only if you intentionally want a new signing identity."
}

New-Item $SigningDir -ItemType Directory -Force | Out-Null

$StorePasswordSecure = Read-Host "Choose the permanent Fort keystore password" -AsSecureString
$KeyPasswordSecure = Read-Host "Choose the permanent Fort key password (may be the same)" -AsSecureString

$StorePassword = [System.Net.NetworkCredential]::new("", $StorePasswordSecure).Password
$KeyPassword = [System.Net.NetworkCredential]::new("", $KeyPasswordSecure).Password

if ([string]::IsNullOrWhiteSpace($StorePassword) -or [string]::IsNullOrWhiteSpace($KeyPassword)) {
    throw "Passwords cannot be empty."
}

try {
    & keytool -genkeypair `
        -v `
        -keystore $KeystorePath `
        -storetype JKS `
        -alias $Alias `
        -keyalg RSA `
        -keysize 4096 `
        -validity 10000 `
        -dname $DistinguishedName `
        -storepass $StorePassword `
        -keypass $KeyPassword
    if ($LASTEXITCODE -ne 0) {
        throw "keytool failed with exit code $LASTEXITCODE"
    }

    $PropertiesSafePath = $KeystorePath.Replace('\', '/')
    $Properties = @"
storePassword=$StorePassword
keyPassword=$KeyPassword
keyAlias=$Alias
storeFile=$PropertiesSafePath
"@
    Set-Content $KeyPropertiesPath $Properties -Encoding ASCII

    Write-Host ""
    Write-Host "=== Permanent Fort signing configured ==="
    Write-Host "Keystore: $KeystorePath"
    Write-Host "Gradle properties: $KeyPropertiesPath"
    Write-Host ""
    Write-Host "IMPORTANT: back up the JKS and its two passwords in a secure location."
    Write-Host "Losing them means future APKs cannot update installed NeoStation Fort releases."
    Write-Host "Neither file is tracked by Git (.gitignore protects them)."
} finally {
    $StorePassword = $null
    $KeyPassword = $null
    $StorePasswordSecure = $null
    $KeyPasswordSecure = $null
}
