<#
.SYNOPSIS
    Internal helpers for clean, user-friendly CLI error handling.
.DESCRIPTION
    Loaded into the module's private scope (not exported). Used by the public
    commands to render actionable error messages instead of raw PowerShell
    error records, and to pre-flight whether a target folder is writable.
#>

function Write-CleanError {
    <#
    .SYNOPSIS
        Prints a friendly, multi-line error block in red - no stack trace,
        no CategoryInfo/FullyQualifiedErrorId noise.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message
    )

    Write-Host ''
    foreach ($line in ($Message -split "`r?`n")) {
        Write-Host "  $line" -ForegroundColor Red
    }
    Write-Host ''
}

function Test-PathWritable {
    <#
    .SYNOPSIS
        Returns $true if a file can be created under $Path.
    .DESCRIPTION
        Walks up to the nearest existing ancestor directory (since the final
        directory may be created on save) and probes it with a temp file.
        Never throws - returns $false on any failure (e.g. access denied when
        the path is in a protected location such as C:\Windows\System32).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    $dir = $Path
    while ($dir -and -not (Test-Path -LiteralPath $dir)) {
        $parent = Split-Path $dir -Parent
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }
    if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { return $false }

    try {
        $probe = Join-Path $dir ".tfvc2git-write-test-$([guid]::NewGuid().ToString('N'))"
        [System.IO.File]::WriteAllText($probe, '')
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return $true
    }
    catch {
        return $false
    }
}
