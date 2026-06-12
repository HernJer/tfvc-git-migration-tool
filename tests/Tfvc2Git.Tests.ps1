#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:ModuleName = 'Tfvc2Git'
    $script:ModuleRoot = Join-Path (Split-Path -Parent $PSScriptRoot) $ModuleName
    $script:Manifest   = Join-Path $ModuleRoot "$ModuleName.psd1"

    Get-Module $ModuleName | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module $Manifest -Force
}

AfterAll {
    Get-Module $script:ModuleName | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Module manifest' {
    It 'is a valid manifest' {
        { Test-ModuleManifest -Path $script:Manifest } | Should -Not -Throw
    }

    It 'has a parseable version' {
        $info = Test-ModuleManifest -Path $script:Manifest
        $info.Version | Should -BeOfType [version]
    }
}

Describe 'Exported commands' {
    BeforeAll {
        $script:Expected = @(
            'Invoke-TfvcMigration',
            'New-TfvcMigrationConfig',
            'Export-TfvcChangeset',
            'Invoke-TfvcReplay',
            'Test-TfvcMigration',
            'New-TfvcMigrationReport'
        )
    }

    It 'exports <_>' -ForEach $script:Expected {
        Get-Command -Module $script:ModuleName -Name $_ -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }

    It 'exports exactly the expected functions' {
        $actual = (Get-Command -Module $script:ModuleName -CommandType Function).Name | Sort-Object
        $actual | Should -Be ($script:Expected | Sort-Object)
    }

    It 'exposes the tfvc2git alias for Invoke-TfvcMigration' {
        $alias = Get-Command -Module $script:ModuleName -CommandType Alias -Name 'tfvc2git' -ErrorAction SilentlyContinue
        $alias | Should -Not -BeNullOrEmpty
        $alias.ResolvedCommand.Name | Should -Be 'Invoke-TfvcMigration'
    }

    It 'does not leak private API functions' {
        Get-Command -Module $script:ModuleName -Name 'New-TfvcConnection' -ErrorAction SilentlyContinue |
            Should -BeNullOrEmpty
    }

    It 'uses only approved verbs' {
        $unapproved = Get-Command -Module $script:ModuleName -CommandType Function |
            Where-Object { $_.Verb -notin (Get-Verb).Verb }
        $unapproved | Should -BeNullOrEmpty
    }
}

Describe 'ConvertTo-RelativePath (private)' {
    It 'maps a server path under the base to a destination-prefixed relative path' {
        InModuleScope $script:ModuleName {
            ConvertTo-RelativePath -ServerPath '$/Project/App/src/file.cs' -TfvcBase '$/Project/App' -DestinationPrefix 'App' |
                Should -Be 'App/src/file.cs'
        }
    }

    It 'returns relative path with no prefix when prefix is empty' {
        InModuleScope $script:ModuleName {
            ConvertTo-RelativePath -ServerPath '$/Project/App/src/file.cs' -TfvcBase '$/Project/App' |
                Should -Be 'src/file.cs'
        }
    }

    It 'returns $null when the path is the base folder itself' {
        InModuleScope $script:ModuleName {
            ConvertTo-RelativePath -ServerPath '$/Project/App' -TfvcBase '$/Project/App' |
                Should -BeNullOrEmpty
        }
    }

    It 'returns $null when the path is outside the base' {
        InModuleScope $script:ModuleName {
            ConvertTo-RelativePath -ServerPath '$/Other/file.cs' -TfvcBase '$/Project/App' |
                Should -BeNullOrEmpty
        }
    }
}

Describe 'New-TfvcConnection (private)' {
    It 'uses default credentials (Windows Auth) when no PAT is supplied' {
        InModuleScope $script:ModuleName {
            $conn = New-TfvcConnection -ServerUrl 'http://tfs:8080/tfs' -Collection 'DefaultCollection' -Project 'Proj'
            $conn.UseDefaultCredentials | Should -BeTrue
            $conn.Headers.ContainsKey('Authorization') | Should -BeFalse
        }
    }

    It 'sets a Basic auth header when a PAT is supplied' {
        InModuleScope $script:ModuleName {
            $conn = New-TfvcConnection -ServerUrl 'http://tfs:8080/tfs' -Collection 'DefaultCollection' -Project 'Proj' -Pat 'abc123'
            $conn.UseDefaultCredentials | Should -BeFalse
            $conn.Headers.Authorization | Should -Match '^Basic '
        }
    }
}
