<#
.SYNOPSIS
    Internal helpers for per-mapping branch resolution.
.DESCRIPTION
    Each source mapping may target a specific Git branch (e.g. $/Proj/DEV -> dev,
    $/Proj/Prod -> main). These helpers read that branch safely from either a
    hashtable (built by New-TfvcMigrationConfig) or a PSCustomObject (parsed from
    config.json), defaulting to 'main' when unspecified. Not exported.
#>

function Get-MappingBranch {
    <#
    .SYNOPSIS
        Returns the target Git branch for a source mapping (default 'main').
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Mapping
    )

    $branch = $null
    if ($Mapping -is [hashtable]) {
        if ($Mapping.ContainsKey('branch')) { $branch = $Mapping['branch'] }
    }
    elseif ($null -ne $Mapping -and $null -ne $Mapping.PSObject.Properties['branch']) {
        $branch = $Mapping.branch
    }

    if ([string]::IsNullOrWhiteSpace("$branch")) { return 'main' }
    return "$branch".Trim()
}

function Get-ConfigBranches {
    <#
    .SYNOPSIS
        Returns the distinct list of target branches across all source mappings,
        in first-seen order.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$SourceMappings
    )

    $seen = [System.Collections.Generic.List[string]]::new()
    foreach ($m in $SourceMappings) {
        $b = Get-MappingBranch -Mapping $m
        if (-not ($seen -contains $b)) { [void]$seen.Add($b) }
    }
    return ,@($seen)
}

function Get-PrimaryBranch {
    <#
    .SYNOPSIS
        The branch the repo should be left on (and the repo's natural default):
        'main' if any mapping targets it, otherwise the first branch.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$SourceMappings
    )

    $branches = Get-ConfigBranches -SourceMappings $SourceMappings
    if ($branches -contains 'main') { return 'main' }
    if ($branches.Count -gt 0) { return $branches[0] }
    return 'main'
}
