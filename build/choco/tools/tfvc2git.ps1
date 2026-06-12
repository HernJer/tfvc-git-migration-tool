#Requires -Version 5.1
<#
    PowerShell launcher behind the `tfvc2git` PATH shim.
    Imports the module and forwards all arguments to the tfvc2git dispatcher,
    so `tfvc2git config`, `tfvc2git -Push`, etc. behave the same as the alias.
    Handled errors are rendered cleanly by the dispatcher; this catch only
    guards against unexpected failures (e.g. the module failing to import).
#>
try {
    Import-Module Tfvc2Git -ErrorAction Stop
    Invoke-Tfvc2Git @args
}
catch {
    [Console]::Error.WriteLine("tfvc2git: $($_.Exception.Message)")
    exit 1
}
