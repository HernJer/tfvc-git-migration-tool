$ErrorActionPreference = 'Stop'

$moduleName = 'Tfvc2Git'
$toolsDir   = Split-Path -Parent $MyInvocation.MyCommand.Definition
$source     = Join-Path $toolsDir $moduleName

if (-not (Test-Path $source)) {
    throw "Bundled module not found at $source. The package was built incorrectly."
}

# Read the version from the bundled manifest so the module is installed
# under a version-specific folder (matches PowerShellGet conventions).
$manifest = Join-Path $source "$moduleName.psd1"
$version  = (Import-PowerShellDataFile -Path $manifest).ModuleVersion

# All-users module path for Windows PowerShell 5.1 (Desktop edition).
$destRoot = Join-Path $env:ProgramFiles "WindowsPowerShell\Modules\$moduleName"
$dest     = Join-Path $destRoot $version

if (Test-Path $dest) {
    Remove-Item $dest -Recurse -Force
}
New-Item -ItemType Directory -Path $dest -Force | Out-Null

Copy-Item -Path (Join-Path $source '*') -Destination $dest -Recurse -Force

Write-Host "Installed $moduleName $version to $dest" -ForegroundColor Green
Write-Host "Open a new PowerShell session and run: Import-Module $moduleName" -ForegroundColor Cyan
