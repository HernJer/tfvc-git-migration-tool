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

function Get-MappingParentBranch {
    <#
    .SYNOPSIS
        Returns the parent Git branch for a source mapping (default empty).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Mapping
    )

    $parent = $null
    if ($Mapping -is [hashtable]) {
        if ($Mapping.ContainsKey('gitParentBranch')) { $parent = $Mapping['gitParentBranch'] }
    }
    elseif ($null -ne $Mapping -and $null -ne $Mapping.PSObject.Properties['gitParentBranch']) {
        $parent = $Mapping.gitParentBranch
    }

    if ([string]::IsNullOrWhiteSpace("$parent")) { return '' }
    return "$parent".Trim()
}

function Get-ConfigBranches {
    <#
    .SYNOPSIS
        Returns the distinct list of target branches across all source mappings.
        Topologically sorted so that parent branches appear before their children.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$SourceMappings
    )

    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $deps = @{}
    
    foreach ($m in $SourceMappings) {
        $b = Get-MappingBranch -Mapping $m
        $p = Get-MappingParentBranch -Mapping $m
        if (-not $seen.Contains($b)) {
            [void]$seen.Add($b)
            $deps[$b] = $p
        }
    }

    $sorted = [System.Collections.Generic.List[string]]::new()
    $visited = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $visiting = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    function Visit([string]$branch) {
        if ($visited.Contains($branch)) { return }
        if ($visiting.Contains($branch)) { throw "Circular branch dependency detected for '$branch'." }
        
        [void]$visiting.Add($branch)
        $parent = $deps[$branch]
        if (-not [string]::IsNullOrEmpty($parent) -and $seen.Contains($parent)) {
            Visit $parent
        }
        [void]$visiting.Remove($branch)
        [void]$visited.Add($branch)
        $sorted.Add($branch)
    }

    foreach ($b in $seen) {
        Visit $b
    }

    return ,@($sorted)
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
