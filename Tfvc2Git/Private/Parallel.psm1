<#
.SYNOPSIS
    Downloads many TFVC files concurrently via a runspace pool.
.DESCRIPTION
    File downloads are the dominant cost of a migration and are independent, so
    they parallelize cleanly. Runspaces run as threads in the same process, so
    Windows (NTLM/Kerberos) auth via -UseDefaultCredentials still works, and no
    external module is required (Windows PowerShell 5.1 compatible).

    The worker is fully self-contained because runspaces do not see the module's
    own functions. Not exported.
#>

function Invoke-ParallelDownload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Connection,
        # Each item: @{ ServerPath = '$/...'; OutputPath = 'C:\...'; ChangesetVersion = <int> }
        [object[]]$Items = @(),
        [int]$Concurrency = 8,
        [int]$MaxRetries = 3
    )

    if (-not $Items -or $Items.Count -eq 0) { return }
    if ($Concurrency -lt 1) { $Concurrency = 1 }

    # Self-contained download worker (no access to module functions).
    $worker = {
        param($BaseUrl, $ApiVersion, $Headers, $UseDefaultCredentials, $ServerPath, $OutputPath, $ChangesetVersion, $MaxRetries)

        $ProgressPreference = 'SilentlyContinue'

        $qp = @{ path = $ServerPath; 'api-version' = $ApiVersion }
        if ($ChangesetVersion -gt 0) {
            $qp['versionDescriptor.versionType'] = 'changeset'
            $qp['versionDescriptor.version']     = $ChangesetVersion
        }
        $qs = ($qp.GetEnumerator() | ForEach-Object {
            [uri]::EscapeDataString($_.Key) + '=' + [uri]::EscapeDataString("$($_.Value)")
        }) -join '&'
        $url = "$BaseUrl/_apis/tfvc/items?$qs"

        $dir = Split-Path $OutputPath -Parent
        if ($dir -and -not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }

        for ($i = 1; $i -le $MaxRetries; $i++) {
            try {
                if ($UseDefaultCredentials) {
                    Invoke-WebRequest -Uri $url -Headers $Headers -OutFile $OutputPath -UseBasicParsing -UseDefaultCredentials
                } else {
                    Invoke-WebRequest -Uri $url -Headers $Headers -OutFile $OutputPath -UseBasicParsing
                }
                return
            }
            catch {
                $code = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
                if ($code -eq 404) {
                    New-Item -Path $OutputPath -ItemType File -Force | Out-Null
                    return "WARNING_404"
                }
                if ($code -in 400, 401, 403 -or $i -eq $MaxRetries) {
                    throw "Download failed for ${ServerPath}: $($_.Exception.Message)"
                }
                Start-Sleep -Seconds ([Math]::Pow(2, $i))
            }
        }
    }

    $pool = [runspacefactory]::CreateRunspacePool(1, $Concurrency)
    $pool.Open()
    try {
        $errors = [System.Collections.Generic.List[string]]::new()

        # Dispatch in batches so a huge changeset doesn't create thousands of
        # runspace handles at once; the pool still caps active downloads at $Concurrency.
        $batchSize = [Math]::Max($Concurrency * 50, 200)
        for ($start = 0; $start -lt $Items.Count; $start += $batchSize) {
            $end  = [Math]::Min($start + $batchSize, $Items.Count) - 1
            $jobs = [System.Collections.Generic.List[object]]::new()

            foreach ($it in $Items[$start..$end]) {
                $version = if ($it.ContainsKey('ChangesetVersion')) { [int]$it.ChangesetVersion } else { 0 }
                $ps = [powershell]::Create()
                $ps.RunspacePool = $pool
                [void]$ps.AddScript($worker).
                    AddArgument($Connection.BaseUrl).
                    AddArgument($Connection.ApiVersion).
                    AddArgument($Connection.Headers).
                    AddArgument([bool]$Connection.UseDefaultCredentials).
                    AddArgument($it.ServerPath).
                    AddArgument($it.OutputPath).
                    AddArgument($version).
                    AddArgument($MaxRetries)
                $jobs.Add([pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke(); ServerPath = $it.ServerPath })
            }

            foreach ($j in $jobs) {
                try {
                    $res = $j.PS.EndInvoke($j.Handle)
                    if ($res -contains "WARNING_404") {
                        Write-Warning "File destroyed in TFVC (404 Not Found): $($j.ServerPath). Created empty placeholder."
                    }
                }
                catch { $errors.Add("$($j.ServerPath): $($_.Exception.Message)") }
                finally { $j.PS.Dispose() }
            }
        }

        if ($errors.Count -gt 0) {
            throw "Parallel download failed for $($errors.Count) file(s):`n$([string]::Join([Environment]::NewLine, $errors))"
        }
    }
    finally {
        $pool.Close()
        $pool.Dispose()
    }
}
