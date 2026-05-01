# build.ps1
# Build Orchestra.exe headlessly. Requires Godot export templates
# (one-time download, see README "Building the .exe").
#
# Usage from project root:
#   .\tools\build.ps1
#
# Output: dist\Orchestra.exe (PCK embedded — single-file binary).

param(
    [string]$Godot = "C:\Godot\Godot_v4.6.2-stable_mono_win64.exe"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $Godot)) {
    Write-Error "Godot not found at $Godot. Pass -Godot <path> or edit this script."
    exit 1
}

# Ensure dist/ exists — Godot won't create the parent directory.
$Dist = Join-Path $PSScriptRoot "..\dist"
if (-not (Test-Path $Dist)) {
    New-Item -ItemType Directory -Path $Dist | Out-Null
}

Push-Location (Join-Path $PSScriptRoot "..")
try {
    Write-Host "[build] exporting Orchestra.exe..."
    & $Godot --headless --export-release "Windows Desktop" "dist/Orchestra.exe"
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Export failed with exit code $LASTEXITCODE"
        exit $LASTEXITCODE
    }
    $Out = Join-Path (Get-Location) "dist\Orchestra.exe"
    if (Test-Path $Out) {
        $Size = (Get-Item $Out).Length / 1MB
        Write-Host ("[build] OK -> {0} ({1:N1} MB)" -f $Out, $Size)
    } else {
        Write-Error "Build succeeded but $Out is missing."
        exit 1
    }
} finally {
    Pop-Location
}
