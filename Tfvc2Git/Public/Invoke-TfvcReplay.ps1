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
    if (-not $ConfigPath) { $ConfigPath = "./config.json" }
    if (Test-Path -LiteralPath $ConfigPath -PathType Container) { $ConfigPath = Join-Path $ConfigPath 'config.json' }
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

    # How many file downloads to run concurrently per changeset (config-tunable).
    $downloadConcurrency = $(if ($null -ne $config.psobject.Properties['downloadConcurrency'] -and $config.downloadConcurrency) { [int]$config.downloadConcurrency } else { 8 })

    # Add a Visual Studio .gitignore to each branch (after its history) unless disabled.
    $addGitignore = $(if ($null -ne $config.psobject.Properties['addGitignore']) { [bool]$config.addGitignore } else { $true })

    Write-MigrationLog -Message "=== Git Replay started ===" -LogFile $logFile
    Write-MigrationLog -Message "Total changesets in export: $($changesets.Count)" -LogFile $logFile
    Write-MigrationLog -Message "Download concurrency: $downloadConcurrency" -LogFile $logFile
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
        Invoke-Git -C $repoPath config core.autocrlf false
        Invoke-Git -C $repoPath config core.safecrlf false
        # Windows MAX_PATH (260) otherwise makes 'git add' fail on deep .NET paths
        # (obj/, .vs/, generated files), which silently produced empty commits.
        Invoke-Git -C $repoPath config core.longpaths true

        if ($config.gitRemoteUrl) {
            $cleanUrl = $config.gitRemoteUrl.TrimEnd('/')
            Invoke-Git -C $repoPath remote add origin $cleanUrl
            Write-MigrationLog -Message "Remote 'origin' set to $cleanUrl" -LogFile $logFile
        }
    }

    # --- LFS availability check ---

    $lfsAvailable = $false
    try {
        $null = Invoke-Git lfs version 2>&1
        if ($LASTEXITCODE -eq 0) {
            $lfsAvailable = $true
            Invoke-Git -C $repoPath lfs install --local 2>&1 | Out-Null
            Write-MigrationLog -Message "Git LFS is available and initialised" -LogFile $logFile
        }
    }
    catch {
        Write-MigrationLog -Message "Git LFS not available - large files will be committed directly" -Level WARN -LogFile $logFile
    }

    $script:redactedSecrets = [System.Collections.Generic.List[object]]::new()
    $script:destroyedFiles  = [System.Collections.Generic.List[object]]::new()

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
            try { Invoke-Git lfs track $Pattern 2>&1 | Out-Null }
            finally { Pop-Location }
            Write-MigrationLog -Message "LFS tracking added for: $Pattern" -LogFile $logFile
        }
        else {
            # git-lfs is NOT installed: commit these files directly. Do NOT write a
            # 'filter=lfs' entry to .gitattributes - git would then try to run the
            # missing git-lfs clean filter on 'git add' and fail, which silently
            # produces empty commits and leaves files untracked. Install git-lfs
            # before migrating if you want large files stored via LFS.
            Write-MigrationLog -Message "git-lfs not available - committing '$Pattern' files directly (no LFS)." -Level WARN -LogFile $logFile
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

    function Start-GitBranch {
        param(
            [string]$Branch,
            [string]$ParentBranch
        )
        # If any commit exists, detach so we can (re)create the branch from nothing.
        Invoke-Git -C $repoPath rev-parse --verify -q HEAD > $null 2>&1
        if ($LASTEXITCODE -eq 0) {
            Invoke-Git -C $repoPath checkout --detach 2>&1 | Out-Null
            Invoke-Git -C $repoPath branch -D $Branch 2>&1 | Out-Null
        }
        
        if ($ParentBranch) {
            # Continue from the parent: inherit BOTH its history and its tree, then
            # layer this branch's changesets on top. Branches are topologically
            # ordered, so the parent is already built. We deliberately do NOT empty
            # the tree here - that's what gives the child a real shared base.
            Write-MigrationLog -Message "Basing branch '$Branch' on parent '$ParentBranch' (inherits its tree)" -LogFile $logFile
            Invoke-Git -C $repoPath checkout -b $Branch $ParentBranch 2>&1 | Out-Null
        }
        else {
            # Orphan root: start from a completely empty tree.
            Invoke-Git -C $repoPath checkout --orphan $Branch 2>&1 | Out-Null
            Invoke-Git -C $repoPath read-tree --empty 2>&1 | Out-Null
            Get-ChildItem -LiteralPath $repoPath -Force |
                Where-Object { $_.Name -ne '.git' } |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # --- Helper: persist checkpoint ---

    function Save-ReplayCheckpoint {
        param(
            [string[]]$CompletedBranches,
            [string]$CurrentBranch,
            [int]$LastChangesetId,
            [int]$TotalReplayed
        )
        $lastHash = (Invoke-Git -C $repoPath rev-parse HEAD 2>&1).Trim()
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
        param($Changeset, $Changes, $Branch)
        $cs = $Changeset

        # Pass 1: apply filesystem ops (deletes, rename-old removal) and collect
        # the file downloads so they can run concurrently.
        $downloads = [System.Collections.Generic.List[object]]::new()
        foreach ($change in $Changes) {
            $destFile = Join-Path $repoPath $change.destinationPath

            switch ($change.changeType) {
                { $_ -in 'add', 'edit', 'branch', 'merge', 'undelete' } {
                    $downloads.Add(@{ ServerPath = $change.serverPath; OutputPath = $destFile; ChangesetVersion = $cs.changesetId })
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
                    $downloads.Add(@{ ServerPath = $change.serverPath; OutputPath = $destFile; ChangesetVersion = $cs.changesetId })
                }
            }
        }

        # Pass 2: download this changeset's files concurrently. Any whose content
        # is gone from TFVC (persistent 404) come back as 'destroyed' so we can
        # record them - they're written as empty placeholders by the downloader.
        $destroyedPaths = @()
        if ($downloads.Count -gt 0) {
            $destroyedPaths = @(Invoke-ParallelDownload -Connection $conn -Items $downloads.ToArray() -Concurrency $downloadConcurrency)
        }
        foreach ($dp in $destroyedPaths) {
            $match = $downloads | Where-Object { $_.ServerPath -eq $dp } | Select-Object -First 1
            $relPath = ''
            if ($match) { $relPath = $match.OutputPath.Substring($repoPath.Length).TrimStart('\', '/').Replace('\', '/') }
            $script:destroyedFiles.Add(@{ ChangesetId = $cs.changesetId; ServerPath = $dp; DestinationPath = $relPath; Branch = $Branch })
        }

        # Pass 2.5: Secret Scanning
        if ($config.secretScanningEnabled) {
            foreach ($d in $downloads) {
                if (Test-Path $d.OutputPath) {
                    $wasCleaned = Invoke-SecretScanAndClean -FilePath $d.OutputPath -Patterns $config.secretPatterns -ReplacementToken $config.secretReplacementToken
                    if ($wasCleaned) {
                        Write-MigrationLog -Message "Secret redacted in $($d.ServerPath) at Changeset $($cs.changesetId)" -Level WARN -LogFile $logFile
                        $script:redactedSecrets.Add(@{
                            ChangesetId = $cs.changesetId
                            ServerPath  = $d.ServerPath
                            Branch      = $Branch
                        })
                    }
                }
            }
        }

        # Pass 3: LFS tracking for any downloaded file that needs it.
        foreach ($d in $downloads) {
            if (Test-Path $d.OutputPath) {
                $fileSize = (Get-Item $d.OutputPath).Length
                if (Test-NeedsLfs -FilePath $d.OutputPath -SizeBytes $fileSize) {
                    $ext = [System.IO.Path]::GetExtension($d.OutputPath)
                    if ($ext) { Add-LfsTracking -Pattern "*$ext" }
                }
            }
        }

        $addOut = Invoke-Git -C $repoPath add -A --force 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "git add failed for changeset $($cs.changesetId) (exit $LASTEXITCODE): $addOut"
        }

        # Diagnostic: a changeset that downloaded files but stages nothing means git
        # silently skipped them (path length, etc.) - surface it instead of an empty commit.
        if ($downloads.Count -gt 0) {
            Invoke-Git -C $repoPath diff --cached --quiet | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-MigrationLog -Message "Changeset $($cs.changesetId): $($downloads.Count) file(s) downloaded but nothing staged (git skipped them - check path length)." -Level WARN -LogFile $logFile
            }
        }

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
        Write-Utf8NoBom -Path $tempMsgFile -Content $commitMsg

        try {
            $env:GIT_AUTHOR_NAME      = $cs.author
            $env:GIT_AUTHOR_EMAIL     = "$($cs.author)@tfvc.local"
            $env:GIT_AUTHOR_DATE      = $cs.createdDate
            # Set committer too (the repo has no user.name/email configured, so
            # without this 'git commit' can fail with "committer identity unknown").
            $env:GIT_COMMITTER_NAME   = $cs.author
            $env:GIT_COMMITTER_EMAIL  = "$($cs.author)@tfvc.local"
            $env:GIT_COMMITTER_DATE   = $cs.createdDate
            $commitOut = Invoke-Git -C $repoPath commit -F $tempMsgFile --allow-empty 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "git commit failed for changeset $($cs.changesetId) (exit $LASTEXITCODE): $commitOut"
            }
        }
        finally {
            $env:GIT_AUTHOR_NAME     = $null
            $env:GIT_AUTHOR_EMAIL    = $null
            $env:GIT_AUTHOR_DATE     = $null
            $env:GIT_COMMITTER_NAME  = $null
            $env:GIT_COMMITTER_EMAIL = $null
            $env:GIT_COMMITTER_DATE  = $null
        }

        Remove-Item $tempMsgFile -ErrorAction SilentlyContinue
    }

    # --- Helper: add a Visual Studio .gitignore as a final commit on the branch ---

    function Add-GitignoreCommit {
        $giPath = Join-Path $repoPath '.gitignore'
        if (Test-Path $giPath) { return }   # branch already has one (migrated from TFVC)

        Write-Utf8NoBom -Path $giPath -Content (Get-VisualStudioGitignore)
        $addOut = Invoke-Git -C $repoPath add -- .gitignore 2>&1
        if ($LASTEXITCODE -ne 0) { throw "git add .gitignore failed (exit $LASTEXITCODE): $addOut" }

        # Marker in the footer so verification doesn't flag this as an orphan commit.
        $msg = "Add .gitignore (Visual Studio template)`n`n---`nTfvc2Git-Generated: gitignore"
        $tmp = Join-Path $outputDir 'gitignore-msg.tmp'
        Write-Utf8NoBom -Path $tmp -Content $msg
        try {
            $env:GIT_AUTHOR_NAME      = 'tfvc2git'
            $env:GIT_AUTHOR_EMAIL     = 'noreply@tfvc2git.local'
            $env:GIT_COMMITTER_NAME   = 'tfvc2git'
            $env:GIT_COMMITTER_EMAIL  = 'noreply@tfvc2git.local'
            $commitOut = Invoke-Git -C $repoPath commit -F $tmp 2>&1
            if ($LASTEXITCODE -ne 0) { throw "git commit .gitignore failed (exit $LASTEXITCODE): $commitOut" }
        }
        finally {
            $env:GIT_AUTHOR_NAME     = $null
            $env:GIT_AUTHOR_EMAIL    = $null
            $env:GIT_COMMITTER_NAME  = $null
            $env:GIT_COMMITTER_EMAIL = $null
        }
        Remove-Item $tmp -ErrorAction SilentlyContinue
        Write-MigrationLog -Message "Added Visual Studio .gitignore to branch" -LogFile $logFile
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
            Invoke-Git -C $repoPath checkout $b 2>&1 | Out-Null
            $branchResumeAfterId = $resumeAfterId
        }
        else {
            Write-MigrationLog -Message "Building branch '$b' ($($branchItems.Count) changeset(s))" -LogFile $logFile
            $parentBranch = ''
            foreach ($m in $config.sourceMappings) {
                if ((Get-MappingBranch -Mapping $m) -eq $b) {
                    $parentBranch = Get-MappingParentBranch -Mapping $m
                    break
                }
            }
            Start-GitBranch -Branch $b -ParentBranch $parentBranch
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

            Write-ChangesetCommit -Changeset $cs -Changes $item.changes -Branch $b
            $totalReplayed++

            if ($totalReplayed % 50 -eq 0) {
                Save-ReplayCheckpoint -CompletedBranches $completedBranches -CurrentBranch $b -LastChangesetId $cs.changesetId -TotalReplayed $totalReplayed
            }
        }

        if ($addGitignore) { Add-GitignoreCommit }

        $completedBranches += $b
        Save-ReplayCheckpoint -CompletedBranches $completedBranches -CurrentBranch '' -LastChangesetId 0 -TotalReplayed $totalReplayed
        Write-MigrationLog -Message "Branch '$b' complete" -LogFile $logFile
    }

    # Leave the repo on the primary branch (its natural default).
    Invoke-Git -C $repoPath checkout $primaryBranch 2>&1 | Out-Null

    Write-MigrationLog -Message "Replay complete. $totalReplayed commits across $($branches.Count) branch(es)." -LogFile $logFile

    # --- Push (all branches) ---

    if ($Push) {
        if ($config.gitRemoteUrl) {
            $cleanUrl = $config.gitRemoteUrl.TrimEnd('/')
            Invoke-Git -C $repoPath remote set-url origin $cleanUrl 2>&1 | Out-Null
        }
        Write-MigrationLog -Message "Pushing all branches to remote..." -LogFile $logFile
        $pushOut = Invoke-Git -C $repoPath push -u origin --all 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-MigrationLog -Message "Push failed: $pushOut" -Level ERROR -LogFile $logFile
            throw "Failed to push branches to remote 'origin' (exit code $LASTEXITCODE). See log for details: $pushOut"
        }
        Write-MigrationLog -Message "Push complete (branches: $($branches -join ', '))" -LogFile $logFile
    }

    Write-MigrationLog -Message "=== Git Replay finished ===" -LogFile $logFile

    if ($script:redactedSecrets.Count -gt 0) {
        $redactedSecretsFile = Join-Path $outputDir 'redacted-secrets.json'
        $script:redactedSecrets | ConvertTo-Json -Depth 5 | Set-Content $redactedSecretsFile -Encoding UTF8
        Write-MigrationLog -Message "Wrote redacted secrets report to $redactedSecretsFile" -LogFile $logFile
    }

    if ($script:destroyedFiles.Count -gt 0) {
        $destroyedFile = Join-Path $outputDir 'destroyed-files.json'
        Write-Utf8NoBom -Path $destroyedFile -Content ($script:destroyedFiles | ConvertTo-Json -Depth 5)
        Write-MigrationLog -Message "Wrote $($script:destroyedFiles.Count) destroyed-file record(s) (content purged in TFVC) to $destroyedFile" -Level WARN -LogFile $logFile
    }
}
