<#
.SYNOPSIS
    Build/packaging helper for the Tfvc2Git module.
.DESCRIPTION
    Used both locally and by CI. Supports four actions (combine freely):
      -Stamp    Write the given -Version into the module manifest.
      -Test     Validate the manifest (Test-ModuleManifest) and lint with PSScriptAnalyzer.
      -Package  Stage a clean copy of the module under dist/ and produce a versioned .zip.
      -Choco    Stage the module into the Chocolatey package's tools/ folder.
.PARAMETER Version
    SemVer version string (e.g. 1.2.3), normally derived from the git tag.
.EXAMPLE
    ./build/Build.ps1 -Version 1.2.3 -Stamp -Test -Package -Choco
#>
[CmdletBinding()]
param(
    [string]$Version,
    [string]$ModuleName = 'Tfvc2Git',
    [switch]$Stamp,
    [switch]$Test,
    [switch]$Package,
    [switch]$Choco,
    [string]$OutputPath = './dist'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot  = Split-Path -Parent $PSScriptRoot
$moduleDir = Join-Path $repoRoot $ModuleName
$manifest  = Join-Path $moduleDir "$ModuleName.psd1"

if (-not (Test-Path $manifest)) { throw "Manifest not found: $manifest" }

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }

# --- Stamp version into the manifest ---------------------------------
if ($Stamp) {
    if (-not $Version) { throw "-Stamp requires -Version." }
    if ($Version -notmatch '^\d+\.\d+\.\d+(\.\d+)?$') {
        throw "Version '$Version' is not a valid module version (expected N.N.N)."
    }
    Write-Step "Stamping ModuleVersion = $Version into $manifest"
    $content = Get-Content -Path $manifest -Raw
    $content = [regex]::Replace(
        $content,
        "(?m)^(\s*ModuleVersion\s*=\s*')[^']*(')",
        "`${1}$Version`${2}"
    )
    Set-Content -Path $manifest -Value $content -Encoding UTF8 -NoNewline
}

# --- Validate + lint --------------------------------------------------
if ($Test) {
    Write-Step "Test-ModuleManifest"
    $info = Test-ModuleManifest -Path $manifest
    Write-Host "    $($info.Name) $($info.Version) - $($info.ExportedFunctions.Count) exported function(s)" -ForegroundColor Gray

    if (Get-Module -ListAvailable -Name PSScriptAnalyzer) {
        Write-Step "PSScriptAnalyzer"
        $results = Invoke-ScriptAnalyzer -Path $moduleDir -Recurse -Severity @('Error', 'Warning')
        if ($results) {
            $results | Format-Table -AutoSize | Out-String | Write-Host
            $errors = @($results | Where-Object { $_.Severity -eq 'Error' })
            if ($errors.Count -gt 0) {
                throw "PSScriptAnalyzer reported $($errors.Count) error(s)."
            }
            Write-Host "    $($results.Count) warning(s), 0 error(s)." -ForegroundColor Yellow
        }
        else {
            Write-Host "    Clean." -ForegroundColor Green
        }
    }
    else {
        Write-Host "    PSScriptAnalyzer not installed - skipping lint." -ForegroundColor DarkYellow
    }
}

# --- Stage clean module copy + zip ------------------------------------
if ($Package) {
    $resolvedOut = if ([System.IO.Path]::IsPathRooted($OutputPath)) { $OutputPath } else { Join-Path $repoRoot $OutputPath }
    $stageDir = Join-Path $resolvedOut $ModuleName
    if (Test-Path $resolvedOut) { Remove-Item $resolvedOut -Recurse -Force }
    New-Item -ItemType Directory -Path $stageDir -Force | Out-Null

    Write-Step "Staging module to $stageDir"
    Copy-Item -Path (Join-Path $moduleDir '*') -Destination $stageDir -Recurse -Force

    $zipName = if ($Version) { "$ModuleName-$Version.zip" } else { "$ModuleName.zip" }
    $zipPath = Join-Path $resolvedOut $zipName
    Write-Step "Compressing to $zipPath"
    Compress-Archive -Path $stageDir -DestinationPath $zipPath -Force
    Write-Host "    Artifact: $zipPath" -ForegroundColor Green
}

# --- Stage module into the Chocolatey package -------------------------
if ($Choco) {
    $chocoTools = Join-Path $PSScriptRoot 'choco/tools'
    $chocoModule = Join-Path $chocoTools $ModuleName
    if (Test-Path $chocoModule) { Remove-Item $chocoModule -Recurse -Force }
    New-Item -ItemType Directory -Path $chocoModule -Force | Out-Null

    Write-Step "Staging module into Chocolatey package: $chocoModule"
    Copy-Item -Path (Join-Path $moduleDir '*') -Destination $chocoModule -Recurse -Force
}

Write-Step "Build complete."
