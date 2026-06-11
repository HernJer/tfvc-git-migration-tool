<#
.SYNOPSIS
    Three-pass verification of a TFVC-to-GitHub migration.
.DESCRIPTION
    Compares the migrated Git repository against the original TFVC source:
      Pass 1 - File inventory comparison
      Pass 2 - Content hash comparison (SHA-256)
      Pass 3 - Changeset-to-commit coverage
    Writes detailed results to $outputDir/verification/ and a summary JSON.
.PARAMETER ConfigPath
    Path to config.json. Defaults to ./config.json.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = "./config.json"
)

$ErrorActionPreference = 'Stop'

try {
    # -- Bootstrap ----------------------------------------------------
    . "$PSScriptRoot/TfvcApi.ps1"

    $config    = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    $outputDir = $config.outputDir
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

    Write-MigrationLog "=== Verification started ===" -LogFile $logFile

    # -- Pass 1 - File Inventory --------------------------------------
    Write-MigrationLog "Pass 1: File inventory comparison" -LogFile $logFile

    # Build TFVC file set and a lookup from destinationPath -> serverPath
    $tfvcFiles   = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $pathLookup  = @{}  # destinationPath -> TFVC server path

    foreach ($mapping in $config.sourceMappings) {
        $items = Get-TfvcItems -Connection $conn -ScopePath $mapping.tfvcPath -RecursionLevel 'Full'

        foreach ($item in $items) {
            if ($item.isFolder -eq $true) { continue }

            $destPath = ConvertTo-RelativePath `
                -ServerPath        $item.path `
                -TfvcBase          $mapping.tfvcPath `
                -DestinationPrefix $mapping.destinationPath
            if (-not $destPath) { continue }

            $normalized = $destPath.Replace('\', '/')
            [void]$tfvcFiles.Add($normalized)
            $pathLookup[$normalized] = $item.path
        }
    }

    # Build Git file set
    $gitOutput = & git -C $repoPath ls-files 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git ls-files failed: $gitOutput" }

    $gitFiles = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($line in ($gitOutput -split "`n")) {
        $f = $line.Trim()
        if ($f) { [void]$gitFiles.Add($f.Replace('\', '/')) }
    }

    # Compare
    $onlyInTfvc = @($tfvcFiles | Where-Object { -not $gitFiles.Contains($_) })
    $onlyInGit  = @($gitFiles  | Where-Object { -not $tfvcFiles.Contains($_) -and $_ -ne '.gitattributes' })
    $inBoth     = @($tfvcFiles | Where-Object { $gitFiles.Contains($_) })

    $inventoryDiff = @{
        onlyInTfvc = $onlyInTfvc
        onlyInGit  = $onlyInGit
        inBoth     = $inBoth
    }
    $inventoryDiff | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $verifyDir 'inventory-diff.json') -Encoding UTF8

    Write-MigrationLog "  TFVC files: $($tfvcFiles.Count)  |  Git files: $($gitFiles.Count)  |  Matched: $($inBoth.Count)" -LogFile $logFile
    if ($onlyInTfvc.Count) { Write-MigrationLog "  Only in TFVC: $($onlyInTfvc.Count)" -Level WARN -LogFile $logFile }
    if ($onlyInGit.Count)  { Write-MigrationLog "  Only in Git:  $($onlyInGit.Count)"  -Level WARN -LogFile $logFile }

    # -- Pass 2 - Content Hash Comparison ----------------------------─
    Write-MigrationLog "Pass 2: Content hash comparison ($($inBoth.Count) files)" -LogFile $logFile

    $hashRows   = [System.Collections.Generic.List[string]]::new()
    $hashRows.Add("Path,TfvcSHA256,GitSHA256,Match")
    $mismatches = [System.Collections.Generic.List[object]]::new()
    $matched    = 0
    $compared   = 0

    foreach ($destPath in $inBoth) {
        $compared++
        $serverPath = $pathLookup[$destPath]
        $tempFile   = Join-Path $tempDir ([Guid]::NewGuid().ToString('N'))

        try {
            Save-TfvcItemContent -Connection $conn -ServerPath $serverPath -OutputPath $tempFile
            $tfvcHash = (Get-FileHash -Path $tempFile   -Algorithm SHA256).Hash
            $gitHash  = (Get-FileHash -Path (Join-Path $repoPath $destPath) -Algorithm SHA256).Hash
            $isMatch  = $tfvcHash -eq $gitHash

            if ($isMatch) { $matched++ }
            else {
                $mismatches.Add(@{ path = $destPath; tfvcHash = $tfvcHash; gitHash = $gitHash })
            }

            $hashRows.Add("$destPath,$tfvcHash,$gitHash,$isMatch")
        }
        catch {
            Write-MigrationLog "  Error hashing ${destPath}: $_" -Level ERROR -LogFile $logFile
            $hashRows.Add("$destPath,ERROR,ERROR,False")
            $mismatches.Add(@{ path = $destPath; tfvcHash = 'ERROR'; gitHash = 'ERROR' })
        }
        finally {
            if (Test-Path $tempFile) { Remove-Item $tempFile -Force -ErrorAction SilentlyContinue }
        }

        if ($compared % 100 -eq 0) {
            Write-MigrationLog "  Progress: $compared / $($inBoth.Count) files compared" -LogFile $logFile
        }
    }

    $hashRows | Set-Content (Join-Path $verifyDir 'hash-comparison.csv') -Encoding UTF8
    Write-MigrationLog "  Compared: $compared  |  Matched: $matched  |  Mismatched: $($mismatches.Count)" -LogFile $logFile

    # Clean up temp directory
    if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue }

    # -- Pass 3 - Changeset Coverage ----------------------------------
    Write-MigrationLog "Pass 3: Changeset coverage" -LogFile $logFile

    $changesetsFile = Join-Path $outputDir 'changesets.json'
    $exportData = Get-Content $changesetsFile -Raw | ConvertFrom-Json
    $exportedCs = $exportData.changesets
    $exportedIds = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($cs in $exportedCs) { [void]$exportedIds.Add([int]$cs.changesetId) }

    # Parse git log
    $gitLogOutput = & git -C $repoPath log --all --format="%H|||%an|||%ai|||%s|||%b" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git log failed: $gitLogOutput" }

    $csToCommit       = @{}      # changesetId -> commit info
    $orphanedCommits  = [System.Collections.Generic.List[string]]::new()
    $mappingRows      = [System.Collections.Generic.List[string]]::new()
    $mappingRows.Add("ChangesetId,GitCommitHash,Author,Date,Comment")

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
        if ($body -match 'TFVC-Changeset:\s*(\d+)') {
            $csId = [int]$Matches[1]
        }
        elseif ($subj -match 'TFVC-Changeset:\s*(\d+)') {
            $csId = [int]$Matches[1]
        }

        if ($csId) {
            $csToCommit[$csId] = @{ Hash = $hash; Author = $author; Date = $date; Comment = $subj }
            # Escape commas in comment for CSV
            $safeComment = $subj -replace '"', '""'
            $mappingRows.Add("$csId,$hash,$author,$date,`"$safeComment`"")
        }
        else {
            $orphanedCommits.Add($hash)
        }
    }

    $unmappedCs = @($exportedIds | Where-Object { -not $csToCommit.ContainsKey($_) })

    # Add unmapped changesets to CSV with empty commit data
    foreach ($csId in $unmappedCs) {
        $mappingRows.Add("$csId,,,,")
    }

    $mappingRows | Set-Content (Join-Path $verifyDir 'changeset-mapping.csv') -Encoding UTF8

    Write-MigrationLog "  Exported changesets: $($exportedIds.Count)  |  Mapped commits: $($csToCommit.Count)" -LogFile $logFile
    if ($unmappedCs.Count)       { Write-MigrationLog "  Unmapped changesets: $($unmappedCs.Count)" -Level WARN -LogFile $logFile }
    if ($orphanedCommits.Count)  { Write-MigrationLog "  Orphaned commits:   $($orphanedCommits.Count)" -Level WARN -LogFile $logFile }

    # -- Summary ------------------------------------------------------
    $invResult  = if ($onlyInTfvc.Count -eq 0 -and $onlyInGit.Count -eq 0) { 'PASS' } else { 'FAIL' }
    $hashResult = if ($mismatches.Count -eq 0) { 'PASS' } else { 'FAIL' }
    $csResult   = if ($unmappedCs.Count -eq 0 -and $orphanedCommits.Count -eq 0) { 'PASS' } else { 'FAIL' }
    $overall    = if ($invResult -eq 'PASS' -and $hashResult -eq 'PASS' -and $csResult -eq 'PASS') { 'PASS' } else { 'FAIL' }

    $summary = [ordered]@{
        verificationDate = (Get-Date).ToString('o')
        overallResult    = $overall
        inventoryCheck   = [ordered]@{
            result        = $invResult
            totalTfvcFiles = $tfvcFiles.Count
            totalGitFiles  = $gitFiles.Count
            onlyInTfvc     = $onlyInTfvc
            onlyInGit      = $onlyInGit
            matchCount     = $inBoth.Count
        }
        hashCheck        = [ordered]@{
            result        = $hashResult
            totalCompared = $compared
            matched       = $matched
            mismatched    = $mismatches.Count
            mismatches    = @($mismatches | ForEach-Object { [ordered]@{ path = $_.path; tfvcHash = $_.tfvcHash; gitHash = $_.gitHash } })
        }
        changesetCoverage = [ordered]@{
            result               = $csResult
            totalExportedChangesets = $exportedIds.Count
            totalMappedCommits     = $csToCommit.Count
            unmappedChangesets     = @($unmappedCs)
            orphanedCommits        = @($orphanedCommits)
        }
    }

    $summary | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $verifyDir 'summary.json') -Encoding UTF8

    Write-MigrationLog "" -LogFile $logFile
    Write-MigrationLog "=== Verification complete ===" -LogFile $logFile
    Write-MigrationLog "Overall result: $overall" -LogFile $logFile
    Write-MigrationLog "  Inventory:  $invResult"  -LogFile $logFile
    Write-MigrationLog "  Hashes:     $hashResult" -LogFile $logFile
    Write-MigrationLog "  Changesets: $csResult"   -LogFile $logFile
    Write-MigrationLog "Results written to: $verifyDir" -LogFile $logFile
}
catch {
    Write-MigrationLog "FATAL: $_" -Level ERROR -LogFile $logFile
    Write-MigrationLog $_.ScriptStackTrace -Level ERROR -LogFile $logFile
    throw
}
