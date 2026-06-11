<#
.SYNOPSIS
    Azure DevOps TFVC REST API wrapper for migration tooling.
.DESCRIPTION
    Provides functions to query changesets, list items, and download file content
    from TFVC repositories via the Azure DevOps Server REST API (v7.0).
    Designed for Azure DevOps Server 2022 on-premises. Supports PAT or Windows Auth.
#>

# --- Connection ---

function New-TfvcConnection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ServerUrl,
        [Parameter(Mandatory)][string]$Collection,
        [Parameter(Mandatory)][string]$Project,
        [string]$Pat = "",
        [string]$ApiVersion = "7.0"
    )

    $server = $ServerUrl.TrimEnd('/')
    $headers = @{}
    if ($Pat) {
        $base64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$Pat"))
        $headers.Authorization = "Basic $base64"
    }

    $col = [uri]::EscapeDataString($Collection)
    $proj = ""
    if ($Project) {
        $proj = "/" + [uri]::EscapeDataString($Project)
    }

    @{
        BaseUrl    = "$server/$col"
        ApiVersion = $ApiVersion
        Headers    = $headers
        UseDefaultCredentials = (-not $Pat)
    }
}

# --- Low-level API ---

function Invoke-TfvcApi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Connection,
        [Parameter(Mandatory)][string]$Endpoint,
        [hashtable]$QueryParams = @{},
        [int]$MaxRetries = 3
    )

    $params = @{} + $QueryParams
    $params['api-version'] = $Connection.ApiVersion

    $qs = ($params.GetEnumerator() | Where-Object { $null -ne $_.Value } | ForEach-Object {
        [uri]::EscapeDataString($_.Key) + '=' + [uri]::EscapeDataString("$($_.Value)")
    }) -join '&'

    $url = "$($Connection.BaseUrl)/_apis/tfvc/${Endpoint}?${qs}"

    for ($i = 1; $i -le $MaxRetries; $i++) {
        Write-Host "  [DEBUG] GET $url" -ForegroundColor DarkGray; try { if ($Connection.UseDefaultCredentials) {
                return Invoke-RestMethod -Uri $url -Headers $Connection.Headers -Method Get -UseDefaultCredentials
            } else {
                return Invoke-RestMethod -Uri $url -Headers $Connection.Headers -Method Get
            }
        }
        catch {
            $code = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
            if ($code -in 400, 401, 403, 404 -or $i -eq $MaxRetries) {
                $errBody = ""
                if ($_.Exception.Response) {
                    try {
                        $stream = $_.Exception.Response.GetResponseStream()
                        $reader = New-Object System.IO.StreamReader($stream)
                        $errBody = $reader.ReadToEnd()
                    } catch {}
                }
                if ($errBody) { throw "$($_.Exception.Message) - Body: $errBody" }
                throw
            }
            $delay = [Math]::Min([Math]::Pow(2, $i), 30)
            Write-Warning "API call failed (attempt $i/$MaxRetries), retrying in ${delay}s..."
            Start-Sleep -Seconds $delay
        }
    }
}

# --- Changesets ---

function Get-TfvcChangesets {
    <#
    .SYNOPSIS
        Fetches a single page of changesets, optionally filtered by path.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Connection,
        [string]$ItemPath,
        [int]$Top = 100,
        [int]$Skip = 0,
        [int]$FromId,
        [int]$ToId
    )

    $qp = @{ '$top' = $Top }
    if ($Skip -gt 0)    { $qp['$skip'] = $Skip }
    if ($ItemPath)       { $qp['searchCriteria.itemPath'] = $ItemPath }
    if ($FromId -gt 0)   { $qp['searchCriteria.fromId'] = $FromId }
    if ($ToId -gt 0)     { $qp['searchCriteria.toId'] = $ToId }

    $result = Invoke-TfvcApi -Connection $Connection -Endpoint 'changesets' -QueryParams $qp
    if ($result.value) { $result.value } else { @() }
}

function Get-TfvcAllChangesets {
    <#
    .SYNOPSIS
        Fetches ALL changesets for a path using efficient ID-range pagination.
        Returns in ascending order (oldest first).
    .PARAMETER ResumeAfterId
        If specified, only fetches changesets with ID > this value (for resume).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Connection,
        [Parameter(Mandatory)][string]$ItemPath,
        [int]$ResumeAfterId = 0
    )

    $all = [System.Collections.Generic.List[object]]::new()
    $ceiling = 0

    do {
        $p = @{ Connection = $Connection; ItemPath = $ItemPath; Top = 100 }
        if ($ceiling -gt 0)        { $p.ToId = $ceiling }
        if ($ResumeAfterId -gt 0)  { $p.FromId = $ResumeAfterId }

        $batch = @(Get-TfvcChangesets @p)
        if ($batch.Count -eq 0) { break }

        $all.AddRange($batch)
        $min = ($batch | Measure-Object -Property changesetId -Minimum).Minimum
        $ceiling = $min - 1

        Write-Host "  Fetched $($all.Count) changesets so far..."

        if ($ceiling -le 0) { break }
    } while ($batch.Count -eq 100)

    $all | Sort-Object changesetId
}

function Get-TfvcChangesetChanges {
    <#
    .SYNOPSIS
        Gets all file changes in a changeset (paginated).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Connection,
        [Parameter(Mandatory)][int]$ChangesetId
    )

    $all = [System.Collections.Generic.List[object]]::new()
    $skip = 0

    do {
        $result = Invoke-TfvcApi -Connection $Connection `
            -Endpoint "changesets/$ChangesetId/changes" `
            -QueryParams @{ '$top' = 100; '$skip' = $skip }

        if (-not $result.value -or $result.value.Count -eq 0) { break }
        $all.AddRange($result.value)
        $skip += $result.value.Count
    } while ($result.value.Count -eq 100)

    $all
}

function Get-TfvcChangesetWorkItems {
    <#
    .SYNOPSIS
        Gets work items linked to a changeset.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Connection,
        [Parameter(Mandatory)][int]$ChangesetId
    )

    $result = Invoke-TfvcApi -Connection $Connection -Endpoint "changesets/$ChangesetId/workItems"
    if ($result.value) { $result.value } else { @() }
}

# --- Items ---

function Get-TfvcItems {
    <#
    .SYNOPSIS
        Lists files and folders at a specific path and version.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Connection,
        [Parameter(Mandatory)][string]$ScopePath,
        [ValidateSet('None', 'OneLevel', 'Full')]
        [string]$RecursionLevel = 'Full',
        [int]$ChangesetVersion = 0
    )

    $qp = @{
        scopePath      = $ScopePath
        recursionLevel = $RecursionLevel
    }
    if ($ChangesetVersion -gt 0) {
        $qp['versionDescriptor.versionType'] = 'changeset'
        $qp['versionDescriptor.version']     = $ChangesetVersion
    }

    $result = Invoke-TfvcApi -Connection $Connection -Endpoint 'items' -QueryParams $qp
    if ($result.value) { $result.value } else { @() }
}

function Save-TfvcItemContent {
    <#
    .SYNOPSIS
        Downloads a file from TFVC and saves it to disk.
        Uses Invoke-WebRequest with -OutFile for correct binary handling.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Connection,
        [Parameter(Mandatory)][string]$ServerPath,
        [Parameter(Mandatory)][string]$OutputPath,
        [int]$ChangesetVersion = 0,
        [int]$MaxRetries = 3
    )

    $qp = @{
        path          = $ServerPath
        'api-version' = $Connection.ApiVersion
    }
    if ($ChangesetVersion -gt 0) {
        $qp['versionDescriptor.versionType'] = 'changeset'
        $qp['versionDescriptor.version']     = $ChangesetVersion
    }

    $qs = ($qp.GetEnumerator() | ForEach-Object {
        [uri]::EscapeDataString($_.Key) + '=' + [uri]::EscapeDataString("$($_.Value)")
    }) -join '&'

    $url = "$($Connection.BaseUrl)/_apis/tfvc/items?$qs"

    $dir = Split-Path $OutputPath -Parent
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }

    for ($i = 1; $i -le $MaxRetries; $i++) {
        Write-Host "  [DEBUG] GET $url" -ForegroundColor DarkGray; try { if ($Connection.UseDefaultCredentials) {
                Invoke-WebRequest -Uri $url -Headers $Connection.Headers -OutFile $OutputPath -UseBasicParsing -UseDefaultCredentials
            } else {
                Invoke-WebRequest -Uri $url -Headers $Connection.Headers -OutFile $OutputPath -UseBasicParsing
            }
            return
        }
        catch {
            $code = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
            if ($code -in 400, 401, 403, 404 -or $i -eq $MaxRetries) { throw }
            Start-Sleep -Seconds ([Math]::Pow(2, $i))
        }
    }
}

# --- Helpers ---

function ConvertTo-RelativePath {
    <#
    .SYNOPSIS
        Converts a TFVC server path to a relative path for the Git repo.
    .EXAMPLE
        ConvertTo-RelativePath -ServerPath '$/Project/App/src/file.cs' -TfvcBase '$/Project/App' -DestinationPrefix 'App'
        # Returns: 'App/src/file.cs'
    #>
    param(
        [Parameter(Mandatory)][string]$ServerPath,
        [Parameter(Mandatory)][string]$TfvcBase,
        [string]$DestinationPrefix = ''
    )

    $s = $ServerPath.Replace('\', '/').TrimEnd('/')
    $b = $TfvcBase.Replace('\', '/').TrimEnd('/')

    if (-not $s.StartsWith($b, [StringComparison]::OrdinalIgnoreCase)) { return $null }

    $rel = $s.Substring($b.Length).TrimStart('/')
    if (-not $rel) { return $null }  # path IS the base (folder itself)

    if ($DestinationPrefix) {
        $rel = "$($DestinationPrefix.TrimEnd('/'))/$rel"
    }
    $rel
}

function Write-MigrationLog {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO',
        [string]$LogFile
    )

    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$Level] $Message"
    Write-Host $line
    if ($LogFile) { $line | Add-Content -Path $LogFile -Encoding UTF8 }
}
