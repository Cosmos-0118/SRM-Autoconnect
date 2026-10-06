param([switch]$NoLaunch, [switch]$NoStartup)

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

if (Test-Path $BuildDir) {
    $ResolvedBuildDir = (Resolve-Path -LiteralPath $BuildDir).Path
    $BuildRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "build")) + [IO.Path]::DirectorySeparatorChar
    if (-not $ResolvedBuildDir.StartsWith($BuildRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to clean build output outside $BuildRoot"
    }
    Remove-Item -LiteralPath $ResolvedBuildDir -Recurse -Force
}
New-Item -ItemType Directory -Path $BuildDir -Force | Out-Null

Write-Host "Publishing $AppName ($Configuration)..."
$Runtime = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()) {
    "Arm64" { "win-arm64" }
    "X86" { "win-x86" }
    default { "win-x64" }
}
dotnet publish $Project -c $Configuration -r $Runtime --self-contained true -o $BuildDir --nologo
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

# Keep the current app running until its replacement has built successfully.
Get-Process SRMAutoconnect -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 1

New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

# Replace published files without recursively deleting an arbitrary INSTALL_DIR.
Copy-Item (Join-Path $BuildDir "*") $InstallDir -Recurse -Force
Write-Host "Installed to: $InstalledExe"

if (-not $NoStartup) {
    $RunKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    New-Item -Path $RunKey -Force | Out-Null
    New-ItemProperty -Path $RunKey -Name "SRMAutoconnect" -Value ('"' + $InstalledExe + '"') -PropertyType String -Force | Out-Null
    Write-Host "Open at Login enabled for the installed app. Disable it in Settings if desired."
}

# Launch the installed copy, not the scratch build.
if (-not $NoLaunch) { Start-Process -FilePath $InstalledExe -WindowStyle Hidden }
