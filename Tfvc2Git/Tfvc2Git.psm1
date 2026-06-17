<#
    Tfvc2Git root module.

    Dot-sources every function under Private/ and Public/ into the module scope,
    then exports only the public commands. Private API functions remain internal.

    Note: strict mode is intentionally NOT set here. Functions that require it
    (Export/Replay/Config/orchestrator) set 'Set-StrictMode -Version Latest'
    themselves; the verification and report functions inherit the caller's mode,
    matching the original standalone-vs-orchestrated behavior.
#>

$private = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Private') -Filter '*.psm1' -ErrorAction SilentlyContinue)
$public  = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Public')  -Filter '*.psm1' -ErrorAction SilentlyContinue)

foreach ($file in @($private + $public)) {
    try {
        . $file.FullName
    }
    catch {
        throw "Failed to import function file $($file.FullName): $_"
    }
}

# `tfvc2git` is the unified CLI entry point (a subcommand dispatcher) so the whole
# tool runs as a single command. The Chocolatey package additionally shims this
# onto PATH so it works from cmd.exe and other shells, not just PowerShell.
Set-Alias -Name tfvc2git -Value Invoke-Tfvc2Git

Export-ModuleMember -Function $public.BaseName -Alias 'tfvc2git'
