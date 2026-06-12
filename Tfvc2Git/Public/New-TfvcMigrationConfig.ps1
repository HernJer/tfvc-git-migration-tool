function New-TfvcMigrationConfig {
    <#
    .SYNOPSIS
        Interactive (or non-interactive) configuration generator for the TFVC-to-GitHub migration tool.
    .DESCRIPTION
        Prompts the user for Azure DevOps Server and GitHub details, tests the connection,
        and writes a config.json file compatible with the migration commands.
    .PARAMETER OutputPath
        Path where the config file will be saved. Defaults to ./config.json.
    .PARAMETER NonInteractive
        When set, skips interactive prompts and uses the values supplied via parameters.
    .PARAMETER ServerUrl
        Azure DevOps Server URL (non-interactive mode).
    .PARAMETER Collection
        TFS collection name (non-interactive mode).
    .PARAMETER Project
        Team project name (non-interactive mode).
    .PARAMETER Pat
        Personal Access Token (non-interactive mode).
    .PARAMETER TfvcPath
        TFVC source path, e.g. $/Project/Folder (non-interactive mode).
    .PARAMETER GitRemoteUrl
        GitHub remote URL (non-interactive mode).
    .PARAMETER OutputDir
        Migration output directory (non-interactive mode).
    .EXAMPLE
        New-TfvcMigrationConfig
    .EXAMPLE
        New-TfvcMigrationConfig -NonInteractive -ServerUrl https://tfs:8080/tfs -Project MyProject -Pat $pat -TfvcPath '$/MyProject/App' -GitRemoteUrl https://github.com/org/repo.git
    #>
    [CmdletBinding()]
    param(
        [string]$OutputPath = './config.json',

        [switch]$NonInteractive,

        [string]$ServerUrl,
        [string]$Collection,
        [string]$Project,
        [string]$Pat,
        [string]$TfvcPath,
        [string]$GitRemoteUrl,
        [string]$OutputDir
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # --- Banner ---
    function Show-Banner {
        Write-Host ''
        Write-Host '  =======================================================╗' -ForegroundColor Cyan
        Write-Host '  |        TFVC -> GitHub  Migration Configurator       |' -ForegroundColor Cyan
        Write-Host '  |                                                      |' -ForegroundColor Cyan
        Write-Host '  |   Generates a config.json for the migration tool.    |' -ForegroundColor Cyan
        Write-Host '  =======================================================╝' -ForegroundColor Cyan
        Write-Host ''
    }

    function Read-Prompt {
        param(
            [Parameter(Mandatory)][string]$Label,
            [string]$Default
        )
        $suffix = if ($Default) { " [$Default]" } else { '' }
        $value = Read-Host "  $Label$suffix"
        if ([string]::IsNullOrWhiteSpace($value) -and $Default) { return $Default }
        if ([string]::IsNullOrWhiteSpace($value)) {
            Write-Host "    Value is required." -ForegroundColor Yellow
            return Read-Prompt -Label $Label -Default $Default
        }
        $value
    }

    function Read-SecurePat {
        $secure = Read-Host '  Personal Access Token (PAT)' -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try { [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }

    function Test-TfvcConnection {
        param(
            [Parameter(Mandatory)][hashtable]$Connection
        )
        Write-Host ''
        Write-Host '  Testing connection...' -ForegroundColor Yellow
        try {
            $cs = Get-TfvcChangesets -Connection $Connection -Top 1
            $count = @($cs).Count
            Write-Host "  [+] Connection successful - retrieved $count changeset(s)." -ForegroundColor Green
            return $true
        }
        catch {
            Write-Host "  [x] Connection failed: $($_.Exception.Message)" -ForegroundColor Red
            return $false
        }
    }

    function Show-ConfigSummary {
        param([hashtable]$Config)
        Write-Host ''
        Write-Host '  ┌------------------─ Configuration Summary ------------------─┐' -ForegroundColor DarkCyan
        Write-Host "  |  Server URL    : $($Config.adoServerUrl)" -ForegroundColor DarkCyan
        Write-Host "  |  Collection    : $($Config.collection)" -ForegroundColor DarkCyan
        Write-Host "  |  Project       : $($Config.project)" -ForegroundColor DarkCyan
        Write-Host "  |  API Version   : $($Config.apiVersion)" -ForegroundColor DarkCyan
        $authDisplay = if ($Config.pat -and $Config.pat.Length -ge 4) { "****" + (($Config.pat)[-4..-1] -join '') } elseif ($Config.pat) { "****" } else { "(Windows Auth)" }
        Write-Host "  |  Auth          : $authDisplay" -ForegroundColor DarkCyan
        Write-Host "  |  Source Mappings:" -ForegroundColor DarkCyan
        foreach ($m in $Config.sourceMappings) {
            $dest = if ($m.destinationPath) { $m.destinationPath } else { '(root)' }
            Write-Host "  |    $($m.tfvcPath) -> $dest" -ForegroundColor DarkCyan
        }
        Write-Host "  |  Git Remote    : $($Config.gitRemoteUrl)" -ForegroundColor DarkCyan
        Write-Host "  |  Output Dir    : $($Config.outputDir)" -ForegroundColor DarkCyan
        Write-Host "  |  LFS Threshold : $([math]::Round($Config.lfsThresholdBytes / 1MB))MB" -ForegroundColor DarkCyan
        Write-Host "  |  LFS Patterns  : $($Config.lfsPatterns -join ', ')" -ForegroundColor DarkCyan
        Write-Host "  |  Config File   : $OutputPath" -ForegroundColor DarkCyan
        Write-Host '  └------------------------------------------------------------─┘' -ForegroundColor DarkCyan
        Write-Host ''
    }

    # --- Main ---

    Show-Banner

    if ($NonInteractive) {
        # -- Non-interactive mode --
        $requiredParams = @{
            ServerUrl    = $ServerUrl
            Project      = $Project
            Pat          = $Pat
            TfvcPath     = $TfvcPath
            GitRemoteUrl = $GitRemoteUrl
        }
        foreach ($kv in $requiredParams.GetEnumerator()) {
            if ([string]::IsNullOrWhiteSpace($kv.Value)) {
                throw "Parameter -$($kv.Key) is required in non-interactive mode."
            }
        }

        $cfgCollection  = if ($Collection) { $Collection } else { 'DefaultCollection' }
        $cfgOutputDir   = if ($OutputDir)  { $OutputDir }  else { './migration-output' }

        $config = @{
            adoServerUrl      = $ServerUrl
            collection        = $cfgCollection
            project           = $Project
            apiVersion        = '7.0'
            pat               = $Pat
            sourceMappings    = @(
                @{ tfvcPath = $TfvcPath; destinationPath = '' }
            )
            gitRemoteUrl      = $GitRemoteUrl
            outputDir         = $cfgOutputDir
            lfsThresholdBytes = 52428800
            lfsPatterns       = @('*.dll', '*.exe', '*.zip', '*.nupkg')
        }
    }
    else {
        # -- Interactive mode --
        Write-Host '  Answer each prompt to generate your migration config.' -ForegroundColor Gray
        Write-Host '  Values in [brackets] are defaults - press Enter to accept.' -ForegroundColor Gray
        Write-Host ''

        # 1. Server connection
        Write-Host '  -- Azure DevOps Server --' -ForegroundColor White
        $cfgServerUrl  = Read-Prompt -Label 'ADO Server URL (e.g. https://tfs.company.com:8080/tfs)'
        $cfgCollection = Read-Prompt -Label 'Collection' -Default 'DefaultCollection'
        $cfgProject    = Read-Prompt -Label 'Project'
        $cfgApiVersion = Read-Prompt -Label 'API Version' -Default '7.0'

        # 2. PAT (secure entry)
        Write-Host ''
        Write-Host '  -- Authentication --' -ForegroundColor White
        $cfgPat = Read-SecurePat

        # 3. Source mappings (loop)
        Write-Host ''
        Write-Host '  -- Source Mappings --' -ForegroundColor White
        Write-Host '  Map one or more TFVC folders to destinations in the Git repo.' -ForegroundColor Gray
        $mappings = [System.Collections.Generic.List[hashtable]]::new()
        do {
            $tfvc = Read-Prompt -Label 'TFVC path (e.g. $/Project/Folder)'
            $dest = Read-Host '  Destination path in Git repo (empty = repo root) []'
            if ([string]::IsNullOrWhiteSpace($dest)) { $dest = '' }
            $mappings.Add(@{ tfvcPath = $tfvc; destinationPath = $dest })
            $more = Read-Host '  Add another mapping? (y/n) [n]'
        } while ($more -eq 'y' -or $more -eq 'Y')

        # 4. Git remote
        Write-Host ''
        Write-Host '  -- GitHub --' -ForegroundColor White
        $cfgGitRemote = Read-Prompt -Label 'Git remote URL (e.g. https://github.com/org/repo.git)'

        # 5. Output directory
        Write-Host ''
        Write-Host '  -- Output --' -ForegroundColor White
        $cfgOutputDir = Read-Prompt -Label 'Output directory' -Default './migration-output'

        # 6. LFS settings
        Write-Host ''
        Write-Host '  -- Git LFS --' -ForegroundColor White
        $lfsRaw = Read-Prompt -Label 'LFS threshold (e.g. 50MB)' -Default '50MB'
        # Parse human-friendly size (e.g. "50MB", "100MB")
        if ($lfsRaw -match '^\s*(\d+)\s*MB\s*$') {
            $cfgLfsBytes = [int]$Matches[1] * 1MB
        }
        elseif ($lfsRaw -match '^\s*(\d+)\s*$') {
            $cfgLfsBytes = [int]$Matches[1]
        }
        else {
            Write-Host "    Could not parse '$lfsRaw', using default 50MB." -ForegroundColor Yellow
            $cfgLfsBytes = 52428800
        }
        $lfsPatRaw = Read-Prompt -Label 'LFS patterns (comma-separated)' -Default '*.dll,*.exe,*.zip,*.nupkg'
        $cfgLfsPatterns = $lfsPatRaw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }

        $config = @{
            adoServerUrl      = $cfgServerUrl
            collection        = $cfgCollection
            project           = $cfgProject
            apiVersion        = $cfgApiVersion
            pat               = $cfgPat
            sourceMappings    = @($mappings)
            gitRemoteUrl      = $cfgGitRemote
            outputDir         = $cfgOutputDir
            lfsThresholdBytes = $cfgLfsBytes
            lfsPatterns       = @($cfgLfsPatterns)
        }
    }

    # -- Test connection --
    $conn = New-TfvcConnection `
        -ServerUrl  $config.adoServerUrl `
        -Collection $config.collection `
        -Project    $config.project `
        -Pat        $config.pat `
        -ApiVersion $config.apiVersion

    $ok = Test-TfvcConnection -Connection $conn

    if (-not $ok) {
        Write-Host ''
        Write-Host '  Connection test failed. Config was NOT saved.' -ForegroundColor Red
        Write-Host '  Please verify your Server URL, Collection, Project, and PAT.' -ForegroundColor Red
        return
    }

    # -- Save config --
    $json = $config | ConvertTo-Json -Depth 5
    $resolvedPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
    $dir = Split-Path $resolvedPath -Parent
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }
    $json | Set-Content -Path $resolvedPath -Encoding UTF8

    Write-Host "  [+] Config saved to: $resolvedPath" -ForegroundColor Green

    Show-ConfigSummary -Config $config
}
