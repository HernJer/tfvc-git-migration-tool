<#
.SYNOPSIS
    Self-contained worker logic for processing a single TFVC changeset.
.DESCRIPTION
    This function processes the details of a single changeset by querying its file changes
    and associated work items, evaluating them against the mapping configuration, and
    returning a consolidated changeset object.
    It is extracted into its own file so it can be easily dot-sourced into parallel runspaces
    and unit-tested independently.
#>

function Invoke-ExportWorker {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Changeset,
        [Parameter(Mandatory)][hashtable]$Connection,
        [Parameter(Mandatory)][object]$Config
    )

    # --- Helper: find the mapping for a server path ---
    function Find-SourceMapping {
        param([string]$ServerPath)
        $sp = $ServerPath.Replace('\', '/').TrimEnd('/')
        foreach ($m in $Config.sourceMappings) {
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

    try {
        $changes = @(Get-TfvcChangesetChanges -Connection $Connection -ChangesetId $Changeset.changesetId)
        $workItems = @(Get-TfvcChangesetWorkItems -Connection $Connection -ChangesetId $Changeset.changesetId)
    }
    catch {
        # Return the error details, making sure to include the fully qualified exception message
        return [PSCustomObject]@{ Error = "ERROR fetching details for changeset $($Changeset.changesetId): $_" }
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
            foreach ($m in $Config.sourceMappings) {
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
                        $items = Get-TfvcItems -Connection $Connection -ScopePath $fetchPath -ChangesetVersion $Changeset.changesetId -RecursionLevel 'Full'
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
                        $prev = $Changeset.changesetId - 1
                        if ($prev -gt 0) {
                            $items = Get-TfvcItems -Connection $Connection -ScopePath $fetchPath -ChangesetVersion $prev -RecursionLevel 'Full'
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

    $authorName = "Unknown"
    if ($null -ne $Changeset.psobject.Properties['author']) {
        $authorName = "$($Changeset.author)"
        if ($null -ne $Changeset.author.psobject.Properties['displayName']) {
            $authorName = $Changeset.author.displayName
        } elseif ($null -ne $Changeset.author.psobject.Properties['uniqueName']) {
            $authorName = $Changeset.author.uniqueName
        }
    }
    
    $comment = if ($null -ne $Changeset.psobject.Properties['comment']) { $Changeset.comment } else { '' }
    $createdDate = if ($null -ne $Changeset.psobject.Properties['createdDate']) { $Changeset.createdDate } else { '' }

    return [PSCustomObject]@{
        changesetId = $Changeset.changesetId
        author      = $authorName
        createdDate = $createdDate
        comment     = $comment
        workItems   = $wiList
        changes     = @($scopedChanges)
        Error       = $null
    }
}
