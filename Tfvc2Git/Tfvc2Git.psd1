@{
    # Script module associated with this manifest.
    RootModule        = 'Tfvc2Git.psm1'

    # Version is stamped from the git tag at publish time by build/Build.ps1.
    ModuleVersion     = '0.0.0'

    # Unique identifier for this module.
    GUID              = 'f361285e-d50c-4e85-bf89-2c5b92a8cd1e'

    Author            = 'HernJer'
    CompanyName       = 'HernJer'
    Copyright         = '(c) HernJer. All rights reserved.'

    Description       = 'Migrate specific folders from an on-premise Azure DevOps Server (2020/2022) TFVC repository to Git/GitHub, preserving full changeset history and producing an audit-grade verification trail.'

    # Requires Windows PowerShell 5.1+ (Desktop edition) for seamless Windows
    # (NTLM/Kerberos) authentication against on-premise Azure DevOps Server.
    PowerShellVersion = '5.1'

    # Functions to export from this module. Keep this explicit (no wildcards)
    # so import is fast and PSGallery analysis is clean.
    FunctionsToExport = @(
        'Invoke-Tfvc2Git',
        'Invoke-TfvcMigration',
        'New-TfvcMigrationConfig',
        'Export-TfvcChangeset',
        'Invoke-TfvcReplay',
        'Test-TfvcMigration',
        'New-TfvcMigrationReport'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @('tfvc2git')

    PrivateData = @{
        PSData = @{
            Tags         = @('TFVC', 'Git', 'GitHub', 'Migration', 'AzureDevOps', 'TFS', 'VersionControl', 'DevOps', 'Windows')
            LicenseUri   = 'https://github.com/HernJer/tfvc-git-migration-tool/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/HernJer/tfvc-git-migration-tool'
            ReleaseNotes = 'https://github.com/HernJer/tfvc-git-migration-tool/releases'
        }
    }
}
