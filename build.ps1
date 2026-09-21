# Configuration
$AppName = "SRM Autoconnect"
$ExeName = "SRMAutoconnect.exe"
$Configuration = "Release"
# BUILD_DIR is scratch space by convention — git clean, bin/obj cleaners, and
# `Remove-Item build` can wipe it. The script installs the finished app to
# INSTALL_DIR below, which those tools never touch.
$BuildDir = Join-Path $PSScriptRoot "build\windows"
$InstallDir = if ($env:INSTALL_DIR) { $env:INSTALL_DIR } else {
    Join-Path $env:LOCALAPPDATA "Programs\SRM Autoconnect"
}
$Project = Join-Path $PSScriptRoot "windows\SRMAutoconnect\SRMAutoconnect.csproj"
$InstalledExe = Join-Path $InstallDir $ExeName

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: dotnet SDK not found. Install .NET 8 SDK from https://dotnet.microsoft.com/download"
    exit 1
}

# Stop any running instance first (locks the binary otherwise), including a
# copy launched from bin\Debug during development.
Get-Process SRMAutoconnect -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 1

if (Test-Path $BuildDir) {
    Remove-Item $BuildDir -Recurse -Force
}
New-Item -ItemType Directory -Path $BuildDir -Force | Out-Null

Write-Host "Publishing $AppName ($Configuration)..."
dotnet publish $Project -c $Configuration -o $BuildDir --nologo
if ($LASTEXITCODE -ne 0) {
    Write-Host "Compilation failed."
    exit 1
}

$BuiltExe = Join-Path $BuildDir $ExeName
if (-not (Test-Path $BuiltExe)) {
    Write-Host "ERROR: publish succeeded but $ExeName was not produced in $BuildDir"
    exit 1
}

Write-Host "Build successful! Output at: $BuildDir"

New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

# Open at Login records whatever path was running when the toggle was enabled.
# If it still points at a debug build, the installed copy will never start at logon.
$RunValue = (Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "SRMAutoconnect" -ErrorAction SilentlyContinue).SRMAutoconnect
if ($RunValue -and ($RunValue -notlike "*$InstallDir*")) {
    Write-Host ""
    Write-Host "NOTE: Open at Login still points at:"
    Write-Host "      $RunValue"
    Write-Host "      This script installs to $InstallDir."
    Write-Host "      Turn the setting off and on again from the installed app."
    Write-Host ""
}

# Remove the old installed copy first so a stale executable (or an older
# WebView2 folder next to it) can never survive alongside the new one.
Get-ChildItem $InstallDir -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force
Copy-Item (Join-Path $BuildDir "*") $InstallDir -Recurse -Force
Write-Host "Installed to: $InstalledExe"

# Launch the installed copy, not the scratch build.
Start-Process $InstalledExe
