#Requires -Version 5.1
<#
    PowerShell launcher behind the `tfvc2git` PATH shim.
    Imports the module and forwards all arguments to the main orchestrator,
    so `tfvc2git -DryRun`, `tfvc2git -ConfigPath .\config.json -Push`, etc.
    behave the same as calling Invoke-TfvcMigration directly.
#>
Import-Module Tfvc2Git -ErrorAction Stop
Invoke-TfvcMigration @args
