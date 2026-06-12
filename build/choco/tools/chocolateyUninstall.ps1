$ErrorActionPreference = 'Stop'

$moduleName = 'Tfvc2Git'
$destRoot   = Join-Path $env:ProgramFiles "WindowsPowerShell\Modules\$moduleName"

# Remove the PATH shim created during install.
Uninstall-BinFile -Name 'tfvc2git'

if (Test-Path $destRoot) {
    Remove-Item $destRoot -Recurse -Force
    Write-Host "Removed $moduleName from $destRoot" -ForegroundColor Green
}
else {
    Write-Host "$moduleName was not found at $destRoot - nothing to remove." -ForegroundColor Yellow
}
