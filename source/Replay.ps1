<#
.SYNOPSIS
    Replays exported TFVC changesets as Git commits.
.DESCRIPTION
    Reads changesets.json produced by Export.ps1, downloads file content
    from TFVC at each changeset version, and creates a corresponding Git
    commit preserving author, date, comment, and work-item links.
    Supports checkpoint/resume and optional push to a remote.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = "./config.json",
    [switch]$Resume,
    [switch]$Push
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Bootstrap ---

. "$PSScriptRoot\TfvcApi.ps1"

$config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
$outputDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($config.outputDir)
$logFile = Join-Path $outputDir 'migration-log.txt'
$checkpointFile = Join-Path $outputDir 'replay-checkpoint.json'

$changesetsFile = Join-Path $outputDir 'changesets.json'
if (-not (Test-Path $changesetsFile)) {
    throw "changesets.json not found at $changesetsFile. Run Export.ps1 first."
}

$export = Get-Content -Path $changesetsFile -Raw | ConvertFrom-Json
$changesets = $export.changesets

Write-MigrationLog -Message "=== Git Replay started ===" -LogFile $logFile
Write-MigrationLog -Message "Total changesets in export: $($changesets.Count)" -LogFile $logFile

# --- TFVC connection (for downloading files) ---

$conn = New-TfvcConnection `
    -ServerUrl  $config.adoServerUrl `
    -Collection $config.collection `
    -Project    $config.project `
    -Pat        $config.pat `
    -ApiVersion $(if ($config.apiVersion) { $config.apiVersion } else { '7.0' })

# --- Git repo setup ---

$repoPath = Join-Path $outputDir 'git-repo'

if (-not (Test-Path (Join-Path $repoPath '.git'))) {
    Write-MigrationLog -Message "Initialising Git repo at $repoPath" -LogFile $logFile
    git init $repoPath
    git -C $repoPath config core.autocrlf false
    git -C $repoPath config core.safecrlf false

    if ($config.gitRemoteUrl) {
        git -C $repoPath remote add origin $config.gitRemoteUrl
        Write-MigrationLog -Message "Remote 'origin' set to $($config.gitRemoteUrl)" -LogFile $logFile
    }
}

# --- LFS availability check ---

$lfsAvailable = $false
try {
    $null = git lfs version 2>&1
    if ($LASTEXITCODE -eq 0) {
        $lfsAvailable = $true
        git -C $repoPath lfs install --local 2>&1 | Out-Null
        Write-MigrationLog -Message "Git LFS is available and initialised" -LogFile $logFile
    }
}
catch {
    Write-MigrationLog -Message "Git LFS not available - large files will be committed directly" -Level WARN -LogFile $logFile
}

# --- Resume ---

$resumeAfterId = 0
$totalReplayed = 0
if ($Resume -and (Test-Path $checkpointFile)) {
    $checkpoint = Get-Content $checkpointFile -Raw | ConvertFrom-Json
    $resumeAfterId = $checkpoint.lastChangesetId
    $totalReplayed = $(if ($checkpoint.totalReplayed) { $checkpoint.totalReplayed } else { 0 })
    Write-MigrationLog -Message "Resuming after changeset $resumeAfterId ($totalReplayed already replayed)" -LogFile $logFile
}

# --- LFS helpers ---

$lfsThreshold = $(if ($config.lfsThresholdBytes) { $config.lfsThresholdBytes } else { 0 })
$lfsPatterns  = @($(if ($config.lfsPatterns) { $config.lfsPatterns } else { @() }))

# Tracking set for patterns already in .gitattributes
$trackedLfsPatterns = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$gitattributes = Join-Path $repoPath '.gitattributes'
if (Test-Path $gitattributes) {
    Get-Content $gitattributes | ForEach-Object {
        if ($_ -match '^\s*(\S+)\s+filter=lfs') {
            $trackedLfsPatterns.Add($Matches[1]) | Out-Null
        }
    }
}

function Test-NeedsLfs {
    param(
        [string]$FilePath,
        [long]$SizeBytes
    )
    # Size check
    if ($lfsThreshold -gt 0 -and $SizeBytes -ge $lfsThreshold) { return $true }
    # Extension pattern check
    $ext = [System.IO.Path]::GetExtension($FilePath)
    foreach ($pattern in $lfsPatterns) {
        # Pattern like "*.dll" - compare extension
        $patExt = $pattern.TrimStart('*')
        if ($ext -eq $patExt) { return $true }
    }
    return $false
}

function Add-LfsTracking {
    param([string]$Pattern)
    if ($trackedLfsPatterns.Contains($Pattern)) { return }
    $trackedLfsPatterns.Add($Pattern) | Out-Null

    if ($lfsAvailable) {
        Push-Location $repoPath
        try { git lfs track $Pattern 2>&1 | Out-Null }
        finally { Pop-Location }
        Write-MigrationLog -Message "LFS tracking added for: $Pattern" -LogFile $logFile
    }
    else {
        # Manually append to .gitattributes
        "$Pattern filter=lfs diff=lfs merge=lfs -text" |
            Add-Content -Path $gitattributes -Encoding UTF8
        Write-MigrationLog -Message "LFS pattern added to .gitattributes (git lfs not available): $Pattern" -Level WARN -LogFile $logFile
    }
}

# --- Helper: remove file and empty parent dirs ---

function Remove-FileAndEmptyParents {
    param([string]$FilePath)
    if (Test-Path $FilePath) {
        Remove-Item -Path $FilePath -Force
    }
    $dir = Split-Path $FilePath -Parent
    while ($dir -and $dir -ne $repoPath -and (Test-Path $dir)) {
        $children = @(Get-ChildItem -Path $dir -Force)
        if ($children.Count -eq 0) {
            Remove-Item -Path $dir -Force
            $dir = Split-Path $dir -Parent
        }
        else { break }
    }
}

# --- Replay loop ---

$index = 0
$total = @($changesets).Count

foreach ($cs in $changesets) {
    $index++

    # Skip if already replayed
    if ($resumeAfterId -gt 0 -and $cs.changesetId -le $resumeAfterId) { continue }

    $changeCount = @($cs.changes).Count

    # Progress
    if ($totalReplayed % 50 -eq 0 -or $totalReplayed -eq 0 -or $index -eq $total) {
        Write-MigrationLog -Message "Replaying changeset $($cs.changesetId)  ($index / $total)" -LogFile $logFile
    }

    if ($changeCount -eq 0) {
        Write-MigrationLog -Message "Changeset $($cs.changesetId) has 0 in-scope changes - creating empty commit" -LogFile $logFile
    }

    # --- Process each change ---

    foreach ($change in $cs.changes) {
        $destFile = Join-Path $repoPath $change.destinationPath

        switch ($change.changeType) {
            { $_ -in 'add', 'edit', 'branch', 'merge', 'undelete' } {
                Save-TfvcItemContent `
                    -Connection $conn `
                    -ServerPath $change.serverPath `
                    -OutputPath $destFile `
                    -ChangesetVersion $cs.changesetId
            }
            'delete' {
                Remove-FileAndEmptyParents -FilePath $destFile
            }
            'rename' {
                # Delete old location (compute from sourceServerPath if available)
                if ($change.sourceServerPath) {
                    # Find mapping for the source path to get the old dest
                    foreach ($m in $config.sourceMappings) {
                        $oldDest = ConvertTo-RelativePath `
                            -ServerPath $change.sourceServerPath `
                            -TfvcBase $m.tfvcPath `
                            -DestinationPrefix $(if ($m.destinationPath) { $m.destinationPath } else { '' })
                        if ($oldDest) {
                            $oldFile = Join-Path $repoPath $oldDest
                            Remove-FileAndEmptyParents -FilePath $oldFile
                            break
                        }
                    }
                }
                # Download at new location
                Save-TfvcItemContent `
                    -Connection $conn `
                    -ServerPath $change.serverPath `
                    -OutputPath $destFile `
                    -ChangesetVersion $cs.changesetId
            }
        }

        # LFS check for files that were downloaded
        if ($change.changeType -ne 'delete' -and (Test-Path $destFile)) {
            $fileSize = (Get-Item $destFile).Length
            if (Test-NeedsLfs -FilePath $destFile -SizeBytes $fileSize) {
                $ext = [System.IO.Path]::GetExtension($destFile)
                if ($ext) {
                    Add-LfsTracking -Pattern "*$ext"
                }
            }
        }
    }

    # --- Stage ---
    git -C $repoPath add -A 2>&1 | Out-Null

    # --- Build commit message ---

    $body = $(if ($cs.comment) { $cs.comment } else { '' })
    $trailer  = "`n---"
    $trailer += "`nTFVC-Changeset: $($cs.changesetId)"
    $trailer += "`nTFVC-Author: $($cs.author)"
    $trailer += "`nTFVC-Date: $($cs.createdDate)"

    if ($cs.workItems -and @($cs.workItems).Count -gt 0) {
        $wiRefs = ($cs.workItems | ForEach-Object { "#$($_.id)" }) -join ', '
        $trailer += "`nTFVC-WorkItems: $wiRefs"
    }

    $commitMsg = "$body$trailer"

    # Write to temp file to avoid shell escaping issues
    $tempMsgFile = Join-Path $outputDir "commit-msg-$($cs.changesetId).tmp"
    [System.IO.File]::WriteAllText($tempMsgFile, $commitMsg, [System.Text.Encoding]::UTF8)

    # --- Commit ---

    try {
        $env:GIT_AUTHOR_NAME     = $cs.author
        $env:GIT_AUTHOR_EMAIL    = "$($cs.author)@tfvc.local"
        $env:GIT_AUTHOR_DATE     = $cs.createdDate
        $env:GIT_COMMITTER_DATE  = $cs.createdDate

        git -C $repoPath commit -F $tempMsgFile --allow-empty 2>&1 | Out-Null
    }
    finally {
        Remove-Item $env:GIT_AUTHOR_NAME     -ErrorAction SilentlyContinue
        Remove-Item $env:GIT_AUTHOR_EMAIL    -ErrorAction SilentlyContinue
        Remove-Item $env:GIT_AUTHOR_DATE     -ErrorAction SilentlyContinue
        Remove-Item $env:GIT_COMMITTER_DATE  -ErrorAction SilentlyContinue
        $env:GIT_AUTHOR_NAME    = $null
        $env:GIT_AUTHOR_EMAIL   = $null
        $env:GIT_AUTHOR_DATE    = $null
        $env:GIT_COMMITTER_DATE = $null
    }

    # Clean up temp file
    Remove-Item $tempMsgFile -ErrorAction SilentlyContinue

    $totalReplayed++

    # --- Checkpoint every 50 ---

    if ($totalReplayed % 50 -eq 0) {
        $lastHash = (git -C $repoPath rev-parse HEAD 2>&1).Trim()
        @{
            lastChangesetId = $cs.changesetId
            lastCommitHash  = $lastHash
            totalReplayed   = $totalReplayed
        } | ConvertTo-Json | Set-Content -Path $checkpointFile -Encoding UTF8
        Write-MigrationLog -Message "Checkpoint: $totalReplayed commits replayed (changeset $($cs.changesetId))" -LogFile $logFile
    }
}

# --- Final checkpoint ---

if ($totalReplayed -gt 0) {
    $lastHash = (git -C $repoPath rev-parse HEAD 2>&1).Trim()
    @{
        lastChangesetId = ($changesets | Select-Object -Last 1).changesetId
        lastCommitHash  = $lastHash
        totalReplayed   = $totalReplayed
    } | ConvertTo-Json | Set-Content -Path $checkpointFile -Encoding UTF8
}

Write-MigrationLog -Message "Replay complete. $totalReplayed commits created." -LogFile $logFile

# --- Push ---

if ($Push) {
    Write-MigrationLog -Message "Pushing to remote..." -LogFile $logFile
    $branch = (git -C $repoPath branch --show-current 2>&1).Trim()
    if (-not $branch) { $branch = 'main' }
    git -C $repoPath push -u origin $branch 2>&1
    Write-MigrationLog -Message "Push complete (branch: $branch)" -LogFile $logFile
}

Write-MigrationLog -Message "=== Git Replay finished ===" -LogFile $logFile
