function Export-TfvcChangeset {
    <#
    .SYNOPSIS
        Exports TFVC changeset metadata for configured source paths.
    .DESCRIPTION
        Connects to Azure DevOps TFVC via REST API, fetches all changesets touching
        the configured source paths, enriches each with file-change details and
        linked work items, then writes a consolidated changesets.json file.
        Supports checkpoint/resume for large repositories.
    .PARAMETER ConfigPath
        Path to the migration config.json file. Defaults to ./config.json.
    .PARAMETER Resume
        Resume export from the last export-checkpoint.json.
    .EXAMPLE
        Export-TfvcChangeset -ConfigPath ./config.json
    .EXAMPLE
        Export-TfvcChangeset -ConfigPath ./config.json -Resume
    #>
    [CmdletBinding()]
    param(
        [string]$ConfigPath = "./config.json",
        [switch]$Resume
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # --- Bootstrap ---

    $config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
    $outputDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($config.outputDir)
    if (-not (Test-Path $outputDir)) {
        New-Item -Path $outputDir -ItemType Directory -Force | Out-Null
    }
    $logFile = Join-Path $outputDir 'migration-log.txt'
    $checkpointFile = Join-Path $outputDir 'export-checkpoint.json'

    Write-MigrationLog -Message "=== TFVC Export started ===" -LogFile $logFile
    Write-MigrationLog -Message "Config: $ConfigPath | Resume: $Resume" -LogFile $logFile

    # --- Connect ---

    $conn = New-TfvcConnection `
        -ServerUrl  $config.adoServerUrl `
        -Collection $config.collection `
        -Project    $config.project `
        -Pat        $config.pat `
        -ApiVersion $(if ($config.apiVersion) { $config.apiVersion } else { '7.0' })

    Write-MigrationLog -Message "Connected to $($config.adoServerUrl)/$($config.collection)/$($config.project)" -LogFile $logFile

    # --- Determine resume point ---

    $resumeAfterId = 0
    if ($Resume -and (Test-Path $checkpointFile)) {
        $checkpoint = Get-Content $checkpointFile -Raw | ConvertFrom-Json
        $resumeAfterId = $checkpoint.lastChangesetId
        Write-MigrationLog -Message "Resuming after changeset $resumeAfterId" -LogFile $logFile
    }

    # --- Fetch changesets for each source mapping ---

    $allChangesets = [System.Collections.Generic.List[object]]::new()

    foreach ($mapping in $config.sourceMappings) {
        Write-MigrationLog -Message "Fetching changesets for path: $($mapping.tfvcPath)" -LogFile $logFile
        $params = @{ Connection = $conn; ItemPath = $mapping.tfvcPath }
        if ($resumeAfterId -gt 0) { $params.ResumeAfterId = $resumeAfterId }
        $cs = @(Get-TfvcAllChangesets @params)
        Write-MigrationLog -Message "  Found $($cs.Count) changeset(s) for $($mapping.tfvcPath)" -LogFile $logFile
        $allChangesets.AddRange($cs)
    }

    # Deduplicate and sort ascending
    $changesets = $allChangesets |
        Sort-Object changesetId |
        Select-Object -Property * -Unique |
        Group-Object changesetId |
        ForEach-Object { $_.Group[0] }

    $totalCount = @($changesets).Count
    Write-MigrationLog -Message "Total unique changesets to export: $totalCount" -LogFile $logFile

    # --- Build tfvcPath list for filtering ---

    $tfvcPaths = @($config.sourceMappings | ForEach-Object { $_.tfvcPath.Replace('\', '/').TrimEnd('/') })

    # --- Helper: find the mapping for a server path ---

    function Find-SourceMapping {
        param([string]$ServerPath)
        $sp = $ServerPath.Replace('\', '/').TrimEnd('/')
        foreach ($m in $config.sourceMappings) {
            $base = $m.tfvcPath.Replace('\', '/').TrimEnd('/')
            if ($sp.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) {
                return $m
            }
        }
        return $null
    }

    # --- Helper: normalise changeType to primary type ---

    function Get-PrimaryChangeType {
        param([string]$RawChangeType)
        $types = $RawChangeType -split ',' | ForEach-Object { $_.Trim() }

        if ($types -contains 'delete') { return 'delete' }
        if ($types -contains 'sourcerename') { return 'delete' }
        if ($types -contains 'rename') { return 'rename' }
        if ($types -contains 'add') { return 'add' }
        if ($types -contains 'branch') { return 'branch' }
        if ($types -contains 'undelete') { return 'undelete' }
        if ($types -contains 'merge') { return 'merge' }

        return 'edit'
    }

    # --- Enrich each changeset ---

    $exportedChangesets = [System.Collections.Generic.List[object]]::new()
    $index = 0

    foreach ($cs in $changesets) {
        $index++

        # Progress
        if ($index % 100 -eq 0 -or $index -eq 1 -or $index -eq $totalCount) {
            Write-MigrationLog -Message "Processing changeset $($cs.changesetId)  ($index / $totalCount)" -LogFile $logFile
        }

        try {
            $changes = @(Get-TfvcChangesetChanges -Connection $conn -ChangesetId $cs.changesetId)
            $workItems = @(Get-TfvcChangesetWorkItems -Connection $conn -ChangesetId $cs.changesetId)
        }
        catch {
            Write-MigrationLog -Message "ERROR fetching details for changeset $($cs.changesetId): $_" -Level ERROR -LogFile $logFile
            throw
        }

        # Filter to in-scope file changes
        $scopedChanges = [System.Collections.Generic.List[object]]::new()

        foreach ($change in $changes) {
            if ($null -eq $change.psobject.Properties['item']) { continue }
            if ($null -eq $change.item.psobject.Properties['path']) { continue }
            $serverPath = $change.item.path
            if (-not $serverPath) { continue }

            $isFolder = ($null -ne $change.item.psobject.Properties['isFolder'] -and $change.item.isFolder -eq $true)
            $isTree = ($null -ne $change.item.psobject.Properties['gitObjectType'] -and $change.item.gitObjectType -eq 'tree')
            $changeType = Get-PrimaryChangeType -RawChangeType $change.changeType

            if ($isFolder -or $isTree) {
                # Check if this folder change affects any of our mappings
                $affectedMappings = @()
                foreach ($m in $config.sourceMappings) {
                    if ($serverPath -eq $m.tfvcPath -or $serverPath.StartsWith("$($m.tfvcPath)/", 'CurrentCultureIgnoreCase')) {
                        $affectedMappings += $m
                    } elseif ($m.tfvcPath.StartsWith("$serverPath/", 'CurrentCultureIgnoreCase')) {
                        $affectedMappings += $m
                    }
                }
                if ($affectedMappings.Count -gt 0) {
                    if ($changeType -in @('add', 'branch', 'rename', 'undelete')) {
                        foreach ($m in $affectedMappings) {
                            $fetchPath = if ($m.tfvcPath.StartsWith("$serverPath/", 'CurrentCultureIgnoreCase')) { $m.tfvcPath } else { $serverPath }
                            $items = Get-TfvcItems -Connection $conn -ScopePath $fetchPath -ChangesetVersion $cs.changesetId -RecursionLevel 'Full'
                            foreach ($item in $items) {
                                if ($null -ne $item.psobject.Properties['isFolder'] -and $item.isFolder -eq $true) { continue }
                                if ($null -ne $item.psobject.Properties['gitObjectType'] -and $item.gitObjectType -eq 'tree') { continue }
                                $destPath = ConvertTo-RelativePath -ServerPath $item.path -TfvcBase $m.tfvcPath -DestinationPrefix $(if ($m.destinationPath) { $m.destinationPath } else { '' })
                                if ($destPath) {
                                    $scopedChanges.Add([PSCustomObject]@{ changeType = 'add'; serverPath = $item.path; destinationPath = $destPath; sourceServerPath = $null; branch = (Get-MappingBranch -Mapping $m) })
                                }
                            }
                        }
                    } elseif ($changeType -eq 'delete') {
                        foreach ($m in $affectedMappings) {
                            $fetchPath = if ($m.tfvcPath.StartsWith("$serverPath/", 'CurrentCultureIgnoreCase')) { $m.tfvcPath } else { $serverPath }
                            $prev = $cs.changesetId - 1
                            if ($prev -gt 0) {
                                $items = Get-TfvcItems -Connection $conn -ScopePath $fetchPath -ChangesetVersion $prev -RecursionLevel 'Full'
                                foreach ($item in $items) {
                                    if ($null -ne $item.psobject.Properties['isFolder'] -and $item.isFolder -eq $true) { continue }
                                    if ($null -ne $item.psobject.Properties['gitObjectType'] -and $item.gitObjectType -eq 'tree') { continue }
                                    $destPath = ConvertTo-RelativePath -ServerPath $item.path -TfvcBase $m.tfvcPath -DestinationPrefix $(if ($m.destinationPath) { $m.destinationPath } else { '' })
                                    if ($destPath) {
                                        $scopedChanges.Add([PSCustomObject]@{ changeType = 'delete'; serverPath = $item.path; destinationPath = $destPath; sourceServerPath = $null; branch = (Get-MappingBranch -Mapping $m) })
                                    }
                                }
                            }
                        }
                    }
                }
                continue
            }

            # Must be under one of our configured paths
            $mapping = Find-SourceMapping -ServerPath $serverPath
            if (-not $mapping) { continue }

            $destPath = ConvertTo-RelativePath -ServerPath $serverPath -TfvcBase $mapping.tfvcPath -DestinationPrefix $(if ($mapping.destinationPath) { $mapping.destinationPath } else { '' })
            if (-not $destPath) { continue }

            $sourceServerPath = $null
            if ($changeType -eq 'rename' -and $null -ne $change.psobject.Properties['sourceServerItem']) {
                if ($null -ne $change.sourceServerItem.psobject.Properties['path']) {
                    $sourceServerPath = $change.sourceServerItem.path
                }
            }

            $scopedChanges.Add([PSCustomObject]@{
                changeType       = $changeType
                serverPath       = $serverPath
                destinationPath  = $destPath
                sourceServerPath = $sourceServerPath
                branch           = (Get-MappingBranch -Mapping $mapping)
            })
        }

        # Deduplicate changes for the same file in the same changeset. Key on
        # branch + destinationPath so the same relative path on two branches
        # (e.g. /DEV and /Prod both at root) does not collide.
        $uniqueChanges = @{}
        foreach ($c in $scopedChanges) {
            $key = "$($c.branch)|$($c.destinationPath)"
            if ($c.changeType -eq 'delete') {
                $uniqueChanges[$key] = $c
            } elseif (-not $uniqueChanges.ContainsKey($key)) {
                $uniqueChanges[$key] = $c
            } else {
                if ($c.changeType -ne 'add') {
                    $uniqueChanges[$key] = $c
                }
            }
        }
        $scopedChanges = $uniqueChanges.Values

        $wiList = @($workItems | ForEach-Object {
            [PSCustomObject]@{ id = $_.id; title = $_.title }
        })

        $authorName = "$($cs.author)"
        if ($null -ne $cs.psobject.Properties['author']) {
            if ($null -ne $cs.author.psobject.Properties['displayName']) {
                $authorName = $cs.author.displayName
            } elseif ($null -ne $cs.author.psobject.Properties['uniqueName']) {
                $authorName = $cs.author.uniqueName
            }
        }

        $exportedChangesets.Add([PSCustomObject]@{
            changesetId = $cs.changesetId
            author      = $authorName
            createdDate = $cs.createdDate
            comment     = $cs.comment
            workItems   = $wiList
            changes     = @($scopedChanges)
        })

        # Checkpoint every 100
        if ($index % 100 -eq 0) {
            @{ lastChangesetId = $cs.changesetId; timestamp = (Get-Date -Format 'o') } |
                ConvertTo-Json | Set-Content -Path $checkpointFile -Encoding UTF8
        }
    }

    # --- Write output ---

    $output = [PSCustomObject]@{
        exportDate      = (Get-Date -Format 'o')
        sourceMappings  = @($config.sourceMappings)
        totalChangesets = $exportedChangesets.Count
        changesets      = @($exportedChangesets)
    }

    $outputFile = Join-Path $outputDir 'changesets.json'
    $output | ConvertTo-Json -Depth 10 | Set-Content -Path $outputFile -Encoding UTF8

    # Final checkpoint
    @{ lastChangesetId = ($exportedChangesets | Select-Object -Last 1).changesetId; timestamp = (Get-Date -Format 'o') } |
        ConvertTo-Json | Set-Content -Path $checkpointFile -Encoding UTF8

    Write-MigrationLog -Message "Export complete. $($exportedChangesets.Count) changesets written to $outputFile" -LogFile $logFile
    Write-MigrationLog -Message "=== TFVC Export finished ===" -LogFile $logFile
}
