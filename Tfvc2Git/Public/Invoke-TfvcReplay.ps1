function Invoke-TfvcReplay {
    <#
    .SYNOPSIS
        Replays exported TFVC changesets as Git commits, one branch per mapping.
    .DESCRIPTION
        Reads changesets.json produced by Export-TfvcChangeset, downloads file content
        from TFVC at each changeset version, and creates a corresponding Git commit
        preserving author, date, comment, and work-item links.

        Each source mapping targets a Git branch (default 'main'). Branches are built
        as independent histories: for each branch, only the changesets that touch that
        branch's folder are replayed, in order. A changeset touching folders for two
        branches produces a commit on each. Supports checkpoint/resume and optional
        push of all branches.
    .PARAMETER ConfigPath
        Path to the migration config.json file. Defaults to ./config.json.
    .PARAMETER Resume
        Resume replay from the last replay-checkpoint.json.
    .PARAMETER Push
        Push all branches to the configured remote after replay completes.
    .EXAMPLE
        Invoke-TfvcReplay -ConfigPath ./config.json -Push
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

    $config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
    $outputDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($config.outputDir)
    $logFile = Join-Path $outputDir 'migration-log.txt'
    $checkpointFile = Join-Path $outputDir 'replay-checkpoint.json'

    $changesetsFile = Join-Path $outputDir 'changesets.json'
    if (-not (Test-Path $changesetsFile)) {
        throw "Exported changesets not found at: $changesetsFile`nRun 'tfvc2git export' (or 'tfvc2git -DryRun') first."
    }

    $export = Get-Content -Path $changesetsFile -Raw | ConvertFrom-Json
    $changesets = $export.changesets

    $branches      = Get-ConfigBranches -SourceMappings $config.sourceMappings
    $primaryBranch = Get-PrimaryBranch  -SourceMappings $config.sourceMappings

    Write-MigrationLog -Message "=== Git Replay started ===" -LogFile $logFile
    Write-MigrationLog -Message "Total changesets in export: $($changesets.Count)" -LogFile $logFile
    Write-MigrationLog -Message "Target branches: $($branches -join ', ')  (primary: $primaryBranch)" -LogFile $logFile

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

    # --- LFS helpers ---

    $lfsThreshold = $(if ($config.lfsThresholdBytes) { $config.lfsThresholdBytes } else { 0 })
    $lfsPatterns  = @($(if ($config.lfsPatterns) { $config.lfsPatterns } else { @() }))

    # Tracking set for patterns already in the current branch's .gitattributes.
    $trackedLfsPatterns = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $gitattributes = Join-Path $repoPath '.gitattributes'

    function Reset-LfsTracking {
        # Re-read .gitattributes for the branch we're currently on (empty after a
        # fresh orphan checkout), so LFS tracking is per-branch.
        $trackedLfsPatterns.Clear()
        if (Test-Path $gitattributes) {
            Get-Content $gitattributes | ForEach-Object {
                if ($_ -match '^\s*(\S+)\s+filter=lfs') {
                    $trackedLfsPatterns.Add($Matches[1]) | Out-Null
                }
            }
        }
    }

    function Test-NeedsLfs {
        param(
            [string]$FilePath,
            [long]$SizeBytes
        )
        if ($lfsThreshold -gt 0 -and $SizeBytes -ge $lfsThreshold) { return $true }
        $ext = [System.IO.Path]::GetExtension($FilePath)
        foreach ($pattern in $lfsPatterns) {
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

    # --- Helper: the target branch of a single change (default 'main') ---

    function Get-ChangeBranch {
        param($Change)
        if ($null -ne $Change.psobject.Properties['branch'] -and $Change.branch) {
            return "$($Change.branch)"
        }
        return 'main'
    }

    # --- Helper: start a fresh, empty orphan branch ---

    function Start-OrphanBranch {
        param([string]$Branch)
        # If any commit exists, detach so we can (re)create the branch from nothing.
        git -C $repoPath rev-parse --verify -q HEAD > $null 2>&1
        if ($LASTEXITCODE -eq 0) {
            git -C $repoPath checkout --detach 2>&1 | Out-Null
            git -C $repoPath branch -D $Branch 2>&1 | Out-Null
        }
        git -C $repoPath checkout --orphan $Branch 2>&1 | Out-Null
        git -C $repoPath read-tree --empty 2>&1 | Out-Null
        # Physically clear the working tree (except .git) so the branch starts empty.
        Get-ChildItem -LiteralPath $repoPath -Force |
            Where-Object { $_.Name -ne '.git' } |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }

    # --- Helper: persist checkpoint ---

    function Save-ReplayCheckpoint {
        param(
            [string[]]$CompletedBranches,
            [string]$CurrentBranch,
            [int]$LastChangesetId,
            [int]$TotalReplayed
        )
        $lastHash = (git -C $repoPath rev-parse HEAD 2>&1).Trim()
        @{
            completedBranches = @($CompletedBranches)
            currentBranch     = $CurrentBranch
            lastChangesetId   = $LastChangesetId
            lastCommitHash    = $lastHash
            totalReplayed     = $TotalReplayed
        } | ConvertTo-Json | Set-Content -Path $checkpointFile -Encoding UTF8
    }

    # --- Helper: apply one changeset's changes and commit on the current branch ---

    function Write-ChangesetCommit {
        param($Changeset, $Changes)
        $cs = $Changeset

        foreach ($change in $Changes) {
            $destFile = Join-Path $repoPath $change.destinationPath

            switch ($change.changeType) {
                { $_ -in 'add', 'edit', 'branch', 'merge', 'undelete' } {
                    Save-TfvcItemContent -Connection $conn -ServerPath $change.serverPath -OutputPath $destFile -ChangesetVersion $cs.changesetId
                }
                'delete' {
                    Remove-FileAndEmptyParents -FilePath $destFile
                }
                'rename' {
                    if ($change.sourceServerPath) {
                        foreach ($m in $config.sourceMappings) {
                            $oldDest = ConvertTo-RelativePath -ServerPath $change.sourceServerPath -TfvcBase $m.tfvcPath -DestinationPrefix $(if ($m.destinationPath) { $m.destinationPath } else { '' })
                            if ($oldDest) {
                                Remove-FileAndEmptyParents -FilePath (Join-Path $repoPath $oldDest)
                                break
                            }
                        }
                    }
                    Save-TfvcItemContent -Connection $conn -ServerPath $change.serverPath -OutputPath $destFile -ChangesetVersion $cs.changesetId
                }
            }

            if ($change.changeType -ne 'delete' -and (Test-Path $destFile)) {
                $fileSize = (Get-Item $destFile).Length
                if (Test-NeedsLfs -FilePath $destFile -SizeBytes $fileSize) {
                    $ext = [System.IO.Path]::GetExtension($destFile)
                    if ($ext) { Add-LfsTracking -Pattern "*$ext" }
                }
            }
        }

        git -C $repoPath add -A 2>&1 | Out-Null

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

        $tempMsgFile = Join-Path $outputDir "commit-msg-$($cs.changesetId).tmp"
        [System.IO.File]::WriteAllText($tempMsgFile, $commitMsg, [System.Text.Encoding]::UTF8)

        try {
            $env:GIT_AUTHOR_NAME     = $cs.author
            $env:GIT_AUTHOR_EMAIL    = "$($cs.author)@tfvc.local"
            $env:GIT_AUTHOR_DATE     = $cs.createdDate
            $env:GIT_COMMITTER_DATE  = $cs.createdDate
            git -C $repoPath commit -F $tempMsgFile --allow-empty 2>&1 | Out-Null
        }
        finally {
            $env:GIT_AUTHOR_NAME    = $null
            $env:GIT_AUTHOR_EMAIL   = $null
            $env:GIT_AUTHOR_DATE    = $null
            $env:GIT_COMMITTER_DATE = $null
        }

        Remove-Item $tempMsgFile -ErrorAction SilentlyContinue
    }

    # --- Group changesets per branch (ascending order is preserved) ---

    $byBranch = [ordered]@{}
    foreach ($b in $branches) { $byBranch[$b] = [System.Collections.Generic.List[object]]::new() }

    foreach ($cs in $changesets) {
        $grp = @{}
        foreach ($ch in $cs.changes) {
            $cb = Get-ChangeBranch -Change $ch
            if (-not $grp.ContainsKey($cb)) { $grp[$cb] = [System.Collections.Generic.List[object]]::new() }
            $grp[$cb].Add($ch)
        }

        if ($grp.Count -eq 0) {
            # Changeset touches nothing in scope - keep an empty commit on the
            # primary branch so every changeset still maps to a commit (audit).
            $byBranch[$primaryBranch].Add([pscustomobject]@{ cs = $cs; changes = @() })
            continue
        }

        foreach ($cb in $grp.Keys) {
            if (-not $byBranch.Contains($cb)) {
                $byBranch[$cb] = [System.Collections.Generic.List[object]]::new()
                $branches += $cb
            }
            $byBranch[$cb].Add([pscustomobject]@{ cs = $cs; changes = @($grp[$cb]) })
        }
    }

    # --- Resume state ---

    $completedBranches   = @()
    $resumeCurrentBranch = ''
    $resumeAfterId       = 0
    $totalReplayed       = 0
    if ($Resume -and (Test-Path $checkpointFile)) {
        $checkpoint = Get-Content $checkpointFile -Raw | ConvertFrom-Json
        if ($null -ne $checkpoint.psobject.Properties['completedBranches'] -and $checkpoint.completedBranches) { $completedBranches = @($checkpoint.completedBranches) }
        if ($null -ne $checkpoint.psobject.Properties['currentBranch']) { $resumeCurrentBranch = "$($checkpoint.currentBranch)" }
        if ($null -ne $checkpoint.psobject.Properties['lastChangesetId']) { $resumeAfterId = [int]$checkpoint.lastChangesetId }
        if ($null -ne $checkpoint.psobject.Properties['totalReplayed'] -and $checkpoint.totalReplayed) { $totalReplayed = [int]$checkpoint.totalReplayed }
        Write-MigrationLog -Message "Resuming: completed [$($completedBranches -join ', ')], current '$resumeCurrentBranch' after changeset $resumeAfterId" -LogFile $logFile
    }

    # --- Build each branch as an independent history ---

    foreach ($b in $branches) {
        if ($completedBranches -contains $b) {
            Write-MigrationLog -Message "Branch '$b' already complete - skipping" -LogFile $logFile
            continue
        }

        $branchItems = $byBranch[$b]
        if (-not $branchItems -or $branchItems.Count -eq 0) {
            Write-MigrationLog -Message "No changesets target branch '$b' - skipping" -LogFile $logFile
            $completedBranches += $b
            continue
        }

        $branchResumeAfterId = 0
        if ($Resume -and $b -eq $resumeCurrentBranch -and $resumeAfterId -gt 0) {
            Write-MigrationLog -Message "Resuming branch '$b' after changeset $resumeAfterId" -LogFile $logFile
            git -C $repoPath checkout $b 2>&1 | Out-Null
            $branchResumeAfterId = $resumeAfterId
        }
        else {
            Write-MigrationLog -Message "Building branch '$b' ($($branchItems.Count) changeset(s))" -LogFile $logFile
            Start-OrphanBranch -Branch $b
        }
        Reset-LfsTracking

        $bi = 0
        $bcount = $branchItems.Count
        foreach ($item in $branchItems) {
            $bi++
            $cs = $item.cs
            if ($branchResumeAfterId -gt 0 -and $cs.changesetId -le $branchResumeAfterId) { continue }

            if ($bi % 50 -eq 0 -or $bi -eq 1 -or $bi -eq $bcount) {
                Write-MigrationLog -Message "  [$b] changeset $($cs.changesetId)  ($bi / $bcount)" -LogFile $logFile
            }

            Write-ChangesetCommit -Changeset $cs -Changes $item.changes
            $totalReplayed++

            if ($totalReplayed % 50 -eq 0) {
                Save-ReplayCheckpoint -CompletedBranches $completedBranches -CurrentBranch $b -LastChangesetId $cs.changesetId -TotalReplayed $totalReplayed
            }
        }

        $completedBranches += $b
        Save-ReplayCheckpoint -CompletedBranches $completedBranches -CurrentBranch '' -LastChangesetId 0 -TotalReplayed $totalReplayed
        Write-MigrationLog -Message "Branch '$b' complete" -LogFile $logFile
    }

    # Leave the repo on the primary branch (its natural default).
    git -C $repoPath checkout $primaryBranch 2>&1 | Out-Null

    Write-MigrationLog -Message "Replay complete. $totalReplayed commits across $($branches.Count) branch(es)." -LogFile $logFile

    # --- Push (all branches) ---

    if ($Push) {
        Write-MigrationLog -Message "Pushing all branches to remote..." -LogFile $logFile
        git -C $repoPath push -u origin --all 2>&1
        Write-MigrationLog -Message "Push complete (branches: $($branches -join ', '))" -LogFile $logFile
    }

    Write-MigrationLog -Message "=== Git Replay finished ===" -LogFile $logFile
}
