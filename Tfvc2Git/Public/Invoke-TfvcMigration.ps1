function Invoke-TfvcMigration {
    <#
    .SYNOPSIS
        Orchestrates the full TFVC-to-GitHub migration pipeline.
    .DESCRIPTION
        Runs Export, Replay, Verify, and Report steps in sequence.
        Supports dry-run mode, selective step skipping, resume from checkpoints,
        and optional push to GitHub.
    .PARAMETER ConfigPath
        Path to the migration config.json file.
    .PARAMETER DryRun
        Export only - shows a summary of what would be migrated without replaying.
    .PARAMETER SkipExport
        Skip the export step (use existing changesets.json).
    .PARAMETER SkipReplay
        Skip the replay step.
    .PARAMETER SkipVerify
        Skip the verification step.
    .PARAMETER SkipReport
        Skip the audit report generation step.
    .PARAMETER Push
        Push to GitHub after replay completes.
    .PARAMETER Resume
        Resume export/replay from the last checkpoint.
    .EXAMPLE
        Invoke-TfvcMigration -ConfigPath ./config.json
    .EXAMPLE
        Invoke-TfvcMigration -ConfigPath ./config.json -DryRun
    .EXAMPLE
        Invoke-TfvcMigration -ConfigPath ./config.json -Push
    #>
    [CmdletBinding()]
    param(
        [string]$ConfigPath = './config.json',
        [switch]$DryRun,
        [switch]$SkipExport,
        [switch]$SkipReplay,
        [switch]$SkipVerify,
        [switch]$SkipReport,
        [switch]$Push,
        [switch]$Resume
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $Version = if ($MyInvocation.MyCommand.Module -and $MyInvocation.MyCommand.Module.Version) {
        $MyInvocation.MyCommand.Module.Version.ToString()
    } else {
        '0.0.0'
    }

    # --- Banner ---
    Write-Host ''
    Write-Host '  =======================================================╗' -ForegroundColor Cyan
    Write-Host '  |        TFVC -> GitHub  Migration Tool  v'$Version'        |' -ForegroundColor Cyan
    Write-Host '  =======================================================╝' -ForegroundColor Cyan
    Write-Host ''

    # --- Validate config ---
    $resolvedConfig = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ConfigPath)
    if (-not (Test-Path $resolvedConfig)) {
        throw "Config file not found: $resolvedConfig`nRun 'tfvc2git config' to create one, or pass -ConfigPath <path>."
    }

    # --- Load and display config summary ---
    $config = Get-Content $resolvedConfig -Raw | ConvertFrom-Json

    Write-Host '  -- Configuration --' -ForegroundColor White
    Write-Host "  Server     : $($config.adoServerUrl)" -ForegroundColor Gray
    Write-Host "  Collection : $($config.collection)" -ForegroundColor Gray
    Write-Host "  Project    : $($config.project)" -ForegroundColor Gray
    Write-Host "  Mappings   : $($config.sourceMappings.Count) source path(s)" -ForegroundColor Gray
    foreach ($m in $config.sourceMappings) {
        $dest = if ($m.destinationPath) { $m.destinationPath } else { '(root)' }
        $br   = Get-MappingBranch -Mapping $m
        Write-Host "               $($m.tfvcPath) -> [$br] $dest" -ForegroundColor DarkGray
    }
    Write-Host "  Git Remote : $($config.gitRemoteUrl)" -ForegroundColor Gray
    Write-Host "  Output Dir : $($config.outputDir)" -ForegroundColor Gray
    Write-Host "  PAT        : ****" -ForegroundColor Gray
    Write-Host ''

    # --- Mode summary ---
    if ($DryRun)   { Write-Host '  MODE: Dry Run (export only, no git operations)' -ForegroundColor Yellow; Write-Host '' }
    if ($Resume)   { Write-Host '  MODE: Resume from checkpoint' -ForegroundColor Yellow; Write-Host '' }

    # --- Step runner ---
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $stepResults = [ordered]@{}

    function Invoke-Step {
        param(
            [int]$Number,
            [string]$Name,
            [string]$Command,
            [string[]]$ExtraArgs = @()
        )

        Write-Host "  --------------------------------------------" -ForegroundColor DarkGray
        Write-Host "  Step $Number : $Name" -ForegroundColor White
        Write-Host "  --------------------------------------------" -ForegroundColor DarkGray

        if (-not (Get-Command $Command -ErrorAction SilentlyContinue)) {
            Write-Host "  [x] Command not found: $Command" -ForegroundColor Red
            $stepResults[$Name] = 'NOT FOUND'
            return $false
        }

        $stepTimer = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $splat = @{ ConfigPath = $resolvedConfig }
            if ($ExtraArgs -contains '-Resume') { $splat.Resume = $true }
            if ($ExtraArgs -contains '-Push') { $splat.Push = $true }
            & $Command @splat
            $stepTimer.Stop()
            $stepResults[$Name] = "OK ($([math]::Round($stepTimer.Elapsed.TotalSeconds, 1))s)"
            Write-Host "  [+] $Name completed in $([math]::Round($stepTimer.Elapsed.TotalSeconds, 1))s" -ForegroundColor Green
            Write-Host ''
            return $true
        }
        catch {
            $stepTimer.Stop()
            $stepResults[$Name] = "FAILED: $($_.Exception.Message)"
            Write-Host "  [x] $Name failed: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host ''
            return $false
        }
    }

    # --- Execute pipeline ---

    $failed = $false

    # Step 1: Export
    if (-not $SkipExport -and -not $failed) {
        $exportArgs = @()
        if ($Resume) { $exportArgs += '-Resume' }

        $ok = Invoke-Step -Number 1 -Name 'Export' -Command 'Export-TfvcChangeset' -ExtraArgs $exportArgs
        if (-not $ok) { $failed = $true }
    }
    elseif ($SkipExport) {
        Write-Host '  Step 1: Export - SKIPPED' -ForegroundColor DarkYellow
        $stepResults['Export'] = 'SKIPPED'
        Write-Host ''
    }

    # Dry-run stops here
    if ($DryRun -and -not $failed) {
        $outputDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($config.outputDir)
        $changesetsFile = Join-Path $outputDir 'changesets.json'

        Write-Host '  -- Dry Run Summary --' -ForegroundColor Yellow
        if (Test-Path $changesetsFile) {
            $csData = Get-Content $changesetsFile -Raw | ConvertFrom-Json
            $csList = $csData.changesets
            $count  = $csData.totalChangesets
            Write-Host "  Exported $count changeset(s) to: $changesetsFile" -ForegroundColor Gray
            if ($count -gt 0) {
                $first = ($csList | Select-Object -First 1).changesetId
                $last  = ($csList | Select-Object -Last 1).changesetId
                Write-Host "  Changeset range: C$first - C$last" -ForegroundColor Gray
            }
        }
        else {
            Write-Host "  Export output not found at $changesetsFile" -ForegroundColor Yellow
        }
        Write-Host '  No git replay was performed (dry-run mode).' -ForegroundColor Yellow
        Write-Host ''

        $stepResults['Replay']  = 'SKIPPED (dry-run)'
        $stepResults['Verify']  = 'SKIPPED (dry-run)'
        $stepResults['Report']  = 'SKIPPED (dry-run)'
    }

    # Step 2: Replay
    if (-not $DryRun -and -not $SkipReplay -and -not $failed) {
        $replayArgs = @()
        if ($Resume) { $replayArgs += '-Resume' }
        if ($Push)   { $replayArgs += '-Push' }

        $ok = Invoke-Step -Number 2 -Name 'Replay' -Command 'Invoke-TfvcReplay' -ExtraArgs $replayArgs
        if (-not $ok) { $failed = $true }
    }
    elseif (-not $DryRun -and $SkipReplay) {
        Write-Host '  Step 2: Replay - SKIPPED' -ForegroundColor DarkYellow
        $stepResults['Replay'] = 'SKIPPED'
        Write-Host ''
    }

    # Step 3: Verify
    if (-not $DryRun -and -not $SkipVerify -and -not $failed) {
        $ok = Invoke-Step -Number 3 -Name 'Verify' -Command 'Test-TfvcMigration'
        if (-not $ok) { $failed = $true }
    }
    elseif (-not $DryRun -and $SkipVerify) {
        Write-Host '  Step 3: Verify - SKIPPED' -ForegroundColor DarkYellow
        $stepResults['Verify'] = 'SKIPPED'
        Write-Host ''
    }

    # Step 4: Report
    if (-not $DryRun -and -not $SkipReport -and -not $failed) {
        $ok = Invoke-Step -Number 4 -Name 'Report' -Command 'New-TfvcMigrationReport'
        if (-not $ok) { $failed = $true }
    }
    elseif (-not $DryRun -and $SkipReport) {
        Write-Host '  Step 4: Report - SKIPPED' -ForegroundColor DarkYellow
        $stepResults['Report'] = 'SKIPPED'
        Write-Host ''
    }

    # --- Final summary ---
    $timer.Stop()
    $elapsed = $timer.Elapsed
    $elapsedStr = '{0:hh\:mm\:ss}' -f $elapsed

    Write-Host '  ==============================================' -ForegroundColor Cyan
    Write-Host '  Migration Pipeline Summary' -ForegroundColor Cyan
    Write-Host '  ==============================================' -ForegroundColor Cyan
    Write-Host ''

    foreach ($kv in $stepResults.GetEnumerator()) {
        $color = if ($kv.Value -like 'OK*') { 'Green' }
                 elseif ($kv.Value -like 'SKIP*') { 'DarkYellow' }
                 elseif ($kv.Value -like 'NOT FOUND*') { 'Yellow' }
                 else { 'Red' }
        Write-Host "  $($kv.Key.PadRight(12)) : $($kv.Value)" -ForegroundColor $color
    }

    Write-Host ''
    Write-Host "  Total elapsed : $elapsedStr" -ForegroundColor Gray

    $outputDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($config.outputDir)
    $reportPath = Join-Path $outputDir 'audit-report.html'
    if (Test-Path $reportPath) {
        Write-Host "  Audit report  : $reportPath" -ForegroundColor Gray
    }

    Write-Host ''
    if ($failed) {
        Write-Host '  RESULT: FAILED - see errors above.' -ForegroundColor Red
        throw 'Migration pipeline failed - see errors above.'
    }
    else {
        Write-Host '  RESULT: SUCCESS' -ForegroundColor Green
    }
    Write-Host ''
}
