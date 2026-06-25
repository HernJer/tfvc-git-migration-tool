<#
.SYNOPSIS
    Small I/O helpers. Not exported.
.DESCRIPTION
    [System.Text.Encoding]::UTF8 (and 'Set-Content -Encoding UTF8' on Windows
    PowerShell 5.1) prepend a UTF-8 BOM. For content that ends up *inside* git
    (commit messages, .gitignore, redacted files) that BOM is visible - e.g. it
    shows up as a leading character on every commit subject. Write-Utf8NoBom
    writes UTF-8 without a BOM.
#>

function Write-Utf8NoBom {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content
    )
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}
