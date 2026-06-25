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
                # Hard client errors are never retried.
                if ($code -in 400, 401, 403) {
                    throw "Download failed for ${ServerPath}: $($_.Exception.Message)"
                }
                # Retry transient failures - including a one-off 404 - with backoff,
                # so a momentary blip isn't mistaken for a permanently-destroyed file.
                if ($i -lt $MaxRetries) {
                    Start-Sleep -Seconds ([Math]::Pow(2, $i))
                    continue
                }
                # Retries exhausted.
                if ($code -eq 404) {
                    # A 404 that persists across every retry means the content is gone
                    # from TFVC (a 'tf destroy' purges all versions). Write an empty
                    # placeholder so the referencing changeset still appears in history.
                    New-Item -Path $OutputPath -ItemType File -Force | Out-Null
                    return "DESTROYED"
                }
                throw "Download failed for ${ServerPath}: $($_.Exception.Message)"
            }
        }
    }

    $pool = [runspacefactory]::CreateRunspacePool(1, $Concurrency)
    $pool.Open()
    try {
        $errors = [System.Collections.Generic.List[string]]::new()
        # ServerPaths whose content is gone from TFVC (persistent 404) - returned
        # to the caller so the migration can record them in its audit trail.
        $destroyed = [System.Collections.Generic.List[string]]::new()

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
                    if ($res -contains "DESTROYED") {
                        Write-Warning "Content purged in TFVC (persistent 404): $($j.ServerPath). Wrote empty placeholder."
                        $destroyed.Add($j.ServerPath)
                    }
                }
                catch { $errors.Add("$($j.ServerPath): $($_.Exception.Message)") }
                finally { $j.PS.Dispose() }
            }
        }

        if ($errors.Count -gt 0) {
            throw "Parallel download failed for $($errors.Count) file(s):`n$([string]::Join([Environment]::NewLine, $errors))"
        }

        return ,@($destroyed)
    }
    finally {
        $pool.Close()
        $pool.Dispose()
    }
}
