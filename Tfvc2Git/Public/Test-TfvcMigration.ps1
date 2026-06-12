function Test-TfvcMigration {
    <#
    .SYNOPSIS
        Three-pass, branch-aware verification of a TFVC-to-GitHub migration.
    .DESCRIPTION
        For each target branch, compares the migrated branch against its TFVC source:
          Pass 1 - File inventory comparison (per branch)
          Pass 2 - Content hash comparison (SHA-256, per branch)
          Pass 3 - Changeset-to-commit coverage (across all branches)
        Writes detailed results to $outputDir/verification/ and a summary JSON.
    .PARAMETER ConfigPath
        Path to config.json. Defaults to ./config.json.
    .EXAMPLE
        Test-TfvcMigration -ConfigPath ./config.json
    #>
    [CmdletBinding()]
    param(
        [string]$ConfigPath = "./config.json"
    )

    $ErrorActionPreference = 'Stop'
    $logFile = $null

    try {
        # -- Bootstrap ----------------------------------------------------
        $config    = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
        $outputDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($config.outputDir)
        $repoPath  = Join-Path $outputDir 'git-repo'
        $verifyDir = Join-Path $outputDir 'verification'
        $tempDir   = Join-Path $verifyDir 'temp'
        $logFile   = Join-Path $verifyDir 'verify.log'

        foreach ($d in @($verifyDir, $tempDir)) {
            if (-not (Test-Path $d)) { New-Item -Path $d -ItemType Directory -Force | Out-Null }
        }

        $conn = New-TfvcConnection `
            -ServerUrl  $config.adoServerUrl `
            -Collection $config.collection `
            -Project    $config.project `
            -Pat        $config.pat `
            -ApiVersion $(if ($config.apiVersion) { $config.apiVersion } else { '7.0' })

        $branches      = Get-ConfigBranches -SourceMappings $config.sourceMappings
        $primaryBranch = Get-PrimaryBranch  -SourceMappings $config.sourceMappings

        Write-MigrationLog "=== Verification started ===" -LogFile $logFile
        Write-MigrationLog "Branches to verify: $($branches -join ', ')" -LogFile $logFile

        # -- Pass 1 + 2 - per-branch inventory and hash -------------------
        $allOnlyInTfvc = [System.Collections.Generic.List[string]]::new()
        $allOnlyInGit  = [System.Collections.Generic.List[string]]::new()
        $perBranch     = [System.Collections.Generic.List[object]]::new()
        $existingBranches = [System.Collections.Generic.List[string]]::new()
        $totalTfvc = 0; $totalGit = 0; $totalInBoth = 0

        $hashRows   = [System.Collections.Generic.List[string]]::new()
        $hashRows.Add("Branch,Path,TfvcSHA256,GitSHA256,Match")
        $mismatches = [System.Collections.Generic.List[object]]::new()
        $matched    = 0
        $compared   = 0

        foreach ($b in $branches) {
            git -C $repoPath rev-parse --verify -q "refs/heads/$b" > $null 2>&1
            $branchExists = ($LASTEXITCODE -eq 0)
            if ($branchExists) {
                [void]$existingBranches.Add($b)
                git -C $repoPath checkout $b 2>&1 | Out-Null
            }

            Write-MigrationLog "Pass 1 [$b]: file inventory" -LogFile $logFile

            # TFVC files for the mappings that target this branch
            $tfvcFiles  = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            $pathLookup = @{}
            foreach ($mapping in $config.sourceMappings) {
                if ((Get-MappingBranch -Mapping $mapping) -ne $b) { continue }
                $items = Get-TfvcItems -Connection $conn -ScopePath $mapping.tfvcPath -RecursionLevel 'Full'
                foreach ($item in $items) {
                    if ($null -ne $item.psobject.Properties['isFolder'] -and $item.isFolder -eq $true) { continue }
                    if ($null -ne $item.psobject.Properties['gitObjectType'] -and $item.gitObjectType -eq 'tree') { continue }
                    $destPath = ConvertTo-RelativePath -ServerPath $item.path -TfvcBase $mapping.tfvcPath -DestinationPrefix $mapping.destinationPath
                    if (-not $destPath) { continue }
                    $normalized = $destPath.Replace('\', '/')
                    [void]$tfvcFiles.Add($normalized)
                    $pathLookup[$normalized] = $item.path
                }
            }

            # Git files on this branch
            $gitFiles = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            if ($branchExists) {
                $gitOutput = & git -C $repoPath ls-files 2>&1
                if ($LASTEXITCODE -ne 0) { throw "git ls-files failed on '$b': $gitOutput" }
                foreach ($line in ($gitOutput -split "`n")) {
                    $f = $line.Trim()
                    if ($f) { [void]$gitFiles.Add($f.Replace('\', '/')) }
                }
            }

            $onlyInTfvc = @($tfvcFiles | Where-Object { -not $gitFiles.Contains($_) })
            $onlyInGit  = @($gitFiles  | Where-Object { -not $tfvcFiles.Contains($_) -and $_ -ne '.gitattributes' })
            $inBoth     = @($tfvcFiles | Where-Object { $gitFiles.Contains($_) })

            foreach ($f in $onlyInTfvc) { [void]$allOnlyInTfvc.Add("${b}:$f") }
            foreach ($f in $onlyInGit)  { [void]$allOnlyInGit.Add("${b}:$f") }
            $totalTfvc += $tfvcFiles.Count; $totalGit += $gitFiles.Count; $totalInBoth += $inBoth.Count

            Write-MigrationLog "  [$b] TFVC: $($tfvcFiles.Count)  Git: $($gitFiles.Count)  Matched: $($inBoth.Count)  OnlyTfvc: $($onlyInTfvc.Count)  OnlyGit: $($onlyInGit.Count)" -LogFile $logFile

            # Pass 2 - hashes for this branch
            Write-MigrationLog "Pass 2 [$b]: content hashes ($($inBoth.Count) files)" -LogFile $logFile
            foreach ($destPath in $inBoth) {
                $compared++
                $serverPath = $pathLookup[$destPath]
                $tempFile   = Join-Path $tempDir ([Guid]::NewGuid().ToString('N'))
                try {
                    Save-TfvcItemContent -Connection $conn -ServerPath $serverPath -OutputPath $tempFile
                    $tfvcHash = (Get-FileHash -Path $tempFile -Algorithm SHA256).Hash
                    $gitHash  = (Get-FileHash -Path (Join-Path $repoPath $destPath) -Algorithm SHA256).Hash
                    $isMatch  = $tfvcHash -eq $gitHash
                    if ($isMatch) { $matched++ }
                    else { $mismatches.Add(@{ path = "${b}:$destPath"; tfvcHash = $tfvcHash; gitHash = $gitHash }) }
                    $hashRows.Add("$b,$destPath,$tfvcHash,$gitHash,$isMatch")
                }
                catch {
                    Write-MigrationLog "  Error hashing [$b] ${destPath}: $_" -Level ERROR -LogFile $logFile
                    $hashRows.Add("$b,$destPath,ERROR,ERROR,False")
                    $mismatches.Add(@{ path = "${b}:$destPath"; tfvcHash = 'ERROR'; gitHash = 'ERROR' })
                }
                finally {
                    if (Test-Path $tempFile) { Remove-Item $tempFile -Force -ErrorAction SilentlyContinue }
                }
            }

            $perBranch.Add([ordered]@{
                branch     = $b
                exists     = $branchExists
                tfvcFiles  = $tfvcFiles.Count
                gitFiles   = $gitFiles.Count
                matched    = $inBoth.Count
                onlyInTfvc = $onlyInTfvc.Count
                onlyInGit  = $onlyInGit.Count
            })
        }

        $inventoryDiff = @{
            onlyInTfvc = @($allOnlyInTfvc)
            onlyInGit  = @($allOnlyInGit)
            perBranch  = @($perBranch)
        }
        $inventoryDiff | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $verifyDir 'inventory-diff.json') -Encoding UTF8
        $hashRows | Set-Content (Join-Path $verifyDir 'hash-comparison.csv') -Encoding UTF8

        if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
        Write-MigrationLog "  Total compared: $compared  Matched: $matched  Mismatched: $($mismatches.Count)" -LogFile $logFile

        # -- Pass 3 - Changeset Coverage (per branch, then aggregate) -----
        Write-MigrationLog "Pass 3: changeset coverage" -LogFile $logFile

        $changesetsFile = Join-Path $outputDir 'changesets.json'
        $exportData = Get-Content $changesetsFile -Raw | ConvertFrom-Json
        $exportedIds = [System.Collections.Generic.HashSet[int]]::new()
        foreach ($cs in $exportData.changesets) { [void]$exportedIds.Add([int]$cs.changesetId) }

        $mappedIds       = [System.Collections.Generic.HashSet[int]]::new()
        $orphanedCommits = [System.Collections.Generic.List[string]]::new()
        $mappingRows     = [System.Collections.Generic.List[string]]::new()
        $mappingRows.Add("ChangesetId,Branch,GitCommitHash,Author,Date,Comment")
        $totalMappedCommits = 0

        foreach ($b in $existingBranches) {
            $gitLogOutput = & git -C $repoPath log $b --format="%H|||%an|||%ai|||%s|||%b" 2>&1
            if ($LASTEXITCODE -ne 0) { throw "git log failed on '$b': $gitLogOutput" }
            foreach ($line in ($gitLogOutput -split "`n")) {
                $line = $line.Trim()
                if (-not $line) { continue }
                $parts  = $line -split '\|\|\|', 5
                $hash   = $parts[0].Trim()
                $author = $parts[1].Trim()
                $date   = $parts[2].Trim()
                $subj   = if ($parts.Count -gt 3) { $parts[3].Trim() } else { '' }
                $body   = if ($parts.Count -gt 4) { $parts[4].Trim() } else { '' }

                $csId = $null
                if ($body -match 'TFVC-Changeset:\s*(\d+)') { $csId = [int]$Matches[1] }
                elseif ($subj -match 'TFVC-Changeset:\s*(\d+)') { $csId = [int]$Matches[1] }

                if ($csId) {
                    [void]$mappedIds.Add($csId)
                    $totalMappedCommits++
                    $safeComment = $subj -replace '"', '""'
                    $mappingRows.Add("$csId,$b,$hash,$author,$date,`"$safeComment`"")
                }
                else {
                    $orphanedCommits.Add($hash)
                }
            }
        }

        $unmappedCs = @($exportedIds | Where-Object { -not $mappedIds.Contains($_) })
        foreach ($csId in $unmappedCs) { $mappingRows.Add("$csId,,,,,") }
        $mappingRows | Set-Content (Join-Path $verifyDir 'changeset-mapping.csv') -Encoding UTF8

        Write-MigrationLog "  Exported changesets: $($exportedIds.Count)  Mapped commits: $totalMappedCommits  Unmapped: $($unmappedCs.Count)  Orphaned: $($orphanedCommits.Count)" -LogFile $logFile

        # Leave the repo on the primary branch.
        git -C $repoPath checkout $primaryBranch 2>&1 | Out-Null

        # -- Summary ------------------------------------------------------
        $invResult  = if ($allOnlyInTfvc.Count -eq 0 -and $allOnlyInGit.Count -eq 0) { 'PASS' } else { 'FAIL' }
        $hashResult = if ($mismatches.Count -eq 0) { 'PASS' } else { 'FAIL' }
        $csResult   = if ($unmappedCs.Count -eq 0 -and $orphanedCommits.Count -eq 0) { 'PASS' } else { 'FAIL' }
        $overall    = if ($invResult -eq 'PASS' -and $hashResult -eq 'PASS' -and $csResult -eq 'PASS') { 'PASS' } else { 'FAIL' }

        $summary = [ordered]@{
            verificationDate = (Get-Date).ToString('o')
            overallResult    = $overall
            branches         = @($branches)
            perBranch        = @($perBranch)
            inventoryCheck   = [ordered]@{
                result         = $invResult
                totalTfvcFiles = $totalTfvc
                totalGitFiles  = $totalGit
                onlyInTfvc     = @($allOnlyInTfvc)
                onlyInGit      = @($allOnlyInGit)
                matchCount     = $totalInBoth
            }
            hashCheck        = [ordered]@{
                result        = $hashResult
                totalCompared = $compared
                matched       = $matched
                mismatched    = $mismatches.Count
                mismatches    = @($mismatches | ForEach-Object { [ordered]@{ path = $_.path; tfvcHash = $_.tfvcHash; gitHash = $_.gitHash } })
            }
            changesetCoverage = [ordered]@{
                result                  = $csResult
                totalExportedChangesets = $exportedIds.Count
                totalMappedCommits      = $totalMappedCommits
                unmappedChangesets      = @($unmappedCs)
                orphanedCommits         = @($orphanedCommits)
            }
        }

        $summary | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $verifyDir 'summary.json') -Encoding UTF8

        Write-MigrationLog "-------------------------------" -LogFile $logFile
        Write-MigrationLog "=== Verification complete ===" -LogFile $logFile
        Write-MigrationLog "Overall result: $overall" -LogFile $logFile
        Write-MigrationLog "  Inventory:  $invResult"  -LogFile $logFile
        Write-MigrationLog "  Hashes:     $hashResult" -LogFile $logFile
        Write-MigrationLog "  Changesets: $csResult"   -LogFile $logFile
        Write-MigrationLog "Results written to: $verifyDir" -LogFile $logFile
    }
    catch {
        if ($logFile) {
            Write-MigrationLog "FATAL: $_" -Level ERROR -LogFile $logFile
            Write-MigrationLog $_.ScriptStackTrace -Level ERROR -LogFile $logFile
        }
        throw
    }
}
