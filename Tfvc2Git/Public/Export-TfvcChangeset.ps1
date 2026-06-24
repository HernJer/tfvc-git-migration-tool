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
    if (-not $ConfigPath) { $ConfigPath = "./config.json" }
    if (Test-Path -LiteralPath $ConfigPath -PathType Container) { $ConfigPath = Join-Path $ConfigPath 'config.json' }
    $config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
    $outputDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($config.outputDir)
    if (-not (Test-Path $outputDir)) {
        New-Item -Path $outputDir -ItemType Directory -Force | Out-Null
    }
    $logFile = Join-Path $outputDir 'migration-log.txt'
    $checkpointFile = Join-Path $outputDir 'export-checkpoint.json'

    $exportConcurrency = $([int]1)
    if ($null -ne $config.psobject.Properties['exportConcurrency'] -and $config.exportConcurrency) {
        $exportConcurrency = [int]$config.exportConcurrency
    }

    Write-MigrationLog -Message "=== TFVC Export started ===" -LogFile $logFile
    Write-MigrationLog -Message "Config: $ConfigPath | Resume: $Resume | Concurrency: $exportConcurrency" -LogFile $logFile

    # --- Connect ---

    $connArgs = @{
        ServerUrl  = $config.adoServerUrl
        Collection = $config.collection
        Project    = $config.project
        Pat        = $config.pat
        ApiVersion = $(if ($config.apiVersion) { $config.apiVersion } else { '7.0' })
    }
    $conn = New-TfvcConnection @connArgs

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

    if ($totalCount -eq 0) {
        Write-MigrationLog -Message "No changesets to export." -LogFile $logFile
        Write-MigrationLog -Message "=== TFVC Export finished ===" -LogFile $logFile
        return
    }

    # --- Build tfvcPath list for filtering ---

    $tfvcPaths = @($config.sourceMappings | ForEach-Object { $_.tfvcPath.Replace('\', '/').TrimEnd('/') })

    # --- Worker Block ---
    $worker = {
        param($cs, $conn, $config, $ModuleRoot)

        if ($ModuleRoot) {
            . (Join-Path $ModuleRoot 'Private\TfvcApi.ps1')
            . (Join-Path $ModuleRoot 'Private\BranchHelpers.ps1')
            . (Join-Path $ModuleRoot 'Private\ExportWorker.ps1')
        }

        return Invoke-ExportWorker -Changeset $cs -Connection $conn -Config $config
    }

    # --- Execution ---
    $exportedChangesets = [System.Collections.Generic.List[object]]::new()
    $index = 0

    if ($exportConcurrency -gt 1) {
        $moduleRoot = Split-Path $PSScriptRoot -Parent
        
        if ($PSVersionTable.PSVersion.Major -ge 7) {
            Write-MigrationLog -Message "Running parallel export using ForEach-Object -Parallel (PS7+)" -LogFile $logFile
            $results = $changesets | ForEach-Object -Parallel {
                $params = @{
                    cs = $_
                    conn = $using:conn
                    config = $using:config
                    ModuleRoot = $using:moduleRoot
                }
                & $using:worker @params
            } -ThrottleLimit $exportConcurrency
            
            foreach ($res in $results) {
                if ($res.Error) {
                    Write-MigrationLog -Message $res.Error -Level ERROR -LogFile $logFile
                    throw $res.Error
                }
                $exportedChangesets.Add($res)
            }
            $exportedChangesets = [System.Collections.Generic.List[object]]($exportedChangesets | Sort-Object changesetId)
        } else {
            Write-MigrationLog -Message "Running parallel export using RunspacePool (PS5.1)" -LogFile $logFile
            $pool = [runspacefactory]::CreateRunspacePool(1, $exportConcurrency)
            $pool.Open()
            try {
                $jobs = [System.Collections.Generic.List[object]]::new()
                foreach ($cs in $changesets) {
                    $ps = [powershell]::Create()
                    $ps.RunspacePool = $pool
                    [void]$ps.AddScript($worker).
                        AddArgument($cs).
                        AddArgument($conn).
                        AddArgument($config).
                        AddArgument($moduleRoot)
                    $jobs.Add([pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke(); csId = $cs.changesetId })
                }
                
                $completed = 0
                foreach ($j in $jobs) {
                    $completed++
                    if ($completed % 100 -eq 0 -or $completed -eq 1 -or $completed -eq $totalCount) {
                        Write-MigrationLog -Message "Processing changeset $($j.csId)  ($completed / $totalCount)" -LogFile $logFile
                    }
                    
                    $pct = if ($totalCount -gt 0) { [int](($completed / $totalCount) * 100) } else { 100 }
                    Write-Progress -Activity 'Exporting TFVC changesets' `
                        -Status "Changeset $($j.csId)  ($completed / $totalCount)" `
                        -PercentComplete $pct

                    try {
                        $res = $j.PS.EndInvoke($j.Handle)
                        if ($res) {
                            if ($res.Error) {
                                Write-MigrationLog -Message $res.Error -Level ERROR -LogFile $logFile
                                throw $res.Error
                            }
                            $exportedChangesets.Add($res[0])
                        }
                    }
                    finally { $j.PS.Dispose() }
                }
                $exportedChangesets = [System.Collections.Generic.List[object]]($exportedChangesets | Sort-Object changesetId)
            }
            finally {
                $pool.Close()
                $pool.Dispose()
            }
        }
    } else {
        # Sequential Execution
        foreach ($cs in $changesets) {
            $index++
            $pct = if ($totalCount -gt 0) { [int](($index / $totalCount) * 100) } else { 100 }
            Write-Progress -Activity 'Exporting TFVC changesets' `
                -Status "Changeset $($cs.changesetId)  ($index / $totalCount)" `
                -PercentComplete $pct

            if ($index % 100 -eq 0 -or $index -eq 1 -or $index -eq $totalCount) {
                Write-MigrationLog -Message "Processing changeset $($cs.changesetId)  ($index / $totalCount)" -LogFile $logFile
            }

            $res = & $worker -cs $cs -conn $conn -config $config -ModuleRoot $null
            if ($res.Error) {
                Write-MigrationLog -Message $res.Error -Level ERROR -LogFile $logFile
                throw $res.Error
            }
            $exportedChangesets.Add($res)

            if ($index % 100 -eq 0) {
                @{ lastChangesetId = $cs.changesetId; timestamp = (Get-Date -Format 'o') } |
                    ConvertTo-Json | Set-Content -Path $checkpointFile -Encoding UTF8
            }
        }
    }

    Write-Progress -Activity 'Exporting TFVC changesets' -Completed

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
