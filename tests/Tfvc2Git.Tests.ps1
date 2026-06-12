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
            'Invoke-Tfvc2Git',
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

    It 'exposes the tfvc2git alias for the dispatcher' {
        $alias = Get-Command -Module $script:ModuleName -CommandType Alias -Name 'tfvc2git' -ErrorAction SilentlyContinue
        $alias | Should -Not -BeNullOrEmpty
        $alias.ResolvedCommand.Name | Should -Be 'Invoke-Tfvc2Git'
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

Describe 'Invoke-Tfvc2Git dispatcher' {
    It 'routes subcommand "<Sub>" to <Target>' -ForEach @(
        @{ Sub = 'config';          Target = 'New-TfvcMigrationConfig' }
        @{ Sub = '--create-config'; Target = 'New-TfvcMigrationConfig' }
        @{ Sub = 'init';            Target = 'New-TfvcMigrationConfig' }
        @{ Sub = 'run';             Target = 'Invoke-TfvcMigration' }
        @{ Sub = 'export';          Target = 'Export-TfvcChangeset' }
        @{ Sub = 'replay';          Target = 'Invoke-TfvcReplay' }
        @{ Sub = 'verify';          Target = 'Test-TfvcMigration' }
        @{ Sub = 'report';          Target = 'New-TfvcMigrationReport' }
    ) {
        Mock -CommandName $Target -ModuleName $script:ModuleName -MockWith {}
        Invoke-Tfvc2Git $Sub
        Should -Invoke -CommandName $Target -ModuleName $script:ModuleName -Times 1 -Exactly
    }

    It 'defaults to Invoke-TfvcMigration when the first argument is a switch' {
        Mock -CommandName Invoke-TfvcMigration -ModuleName $script:ModuleName -MockWith {}
        Invoke-Tfvc2Git -DryRun
        Should -Invoke -CommandName Invoke-TfvcMigration -ModuleName $script:ModuleName -Times 1 -Exactly
    }

    It 'forwards remaining arguments to the target cmdlet' {
        Mock -CommandName Test-TfvcMigration -ModuleName $script:ModuleName -MockWith {}
        Invoke-Tfvc2Git verify -ConfigPath 'C:\x\config.json'
        Should -Invoke -CommandName Test-TfvcMigration -ModuleName $script:ModuleName -Times 1 -Exactly -ParameterFilter {
            $ConfigPath -eq 'C:\x\config.json'
        }
    }

    It 'renders an unknown subcommand cleanly instead of throwing' {
        # The dispatcher catches and prints a friendly message - it must not
        # surface a raw PowerShell error record.
        { Invoke-Tfvc2Git frobnicate } | Should -Not -Throw
    }

    It 'renders a missing config cleanly (does not throw) via the dispatcher' {
        $missing = Join-Path ([System.IO.Path]::GetTempPath()) "tfvc2git-missing-$([guid]::NewGuid()).json"
        { Invoke-Tfvc2Git run -ConfigPath $missing } | Should -Not -Throw
    }
}

Describe 'Clean error handling' {
    It 'Invoke-TfvcMigration throws a clear, self-contained message when the config is missing' {
        $missing = Join-Path ([System.IO.Path]::GetTempPath()) "tfvc2git-missing-$([guid]::NewGuid()).json"
        { Invoke-TfvcMigration -ConfigPath $missing } | Should -Throw '*Config file not found*'
    }
}

Describe 'Test-PathWritable (private)' {
    It 'returns true for a writable directory' {
        InModuleScope $script:ModuleName {
            Test-PathWritable -Path ([System.IO.Path]::GetTempPath()) | Should -BeTrue
        }
    }

    It 'resolves to the nearest existing ancestor for a not-yet-created path' {
        InModuleScope $script:ModuleName {
            $deep = Join-Path ([System.IO.Path]::GetTempPath()) "a-$([guid]::NewGuid())/b/c"
            Test-PathWritable -Path $deep | Should -BeTrue
        }
    }
}

Describe 'Branch mapping helpers (private)' {
    It 'defaults to main when no branch is set (hashtable)' {
        InModuleScope $script:ModuleName {
            Get-MappingBranch -Mapping @{ tfvcPath = '$/x' } | Should -Be 'main'
        }
    }

    It 'reads the branch from a hashtable mapping' {
        InModuleScope $script:ModuleName {
            Get-MappingBranch -Mapping @{ tfvcPath = '$/x'; branch = 'dev' } | Should -Be 'dev'
        }
    }

    It 'reads the branch from a PSCustomObject mapping' {
        InModuleScope $script:ModuleName {
            Get-MappingBranch -Mapping ([pscustomobject]@{ tfvcPath = '$/x'; branch = 'release' }) | Should -Be 'release'
        }
    }

    It 'defaults to main for a PSCustomObject without a branch property' {
        InModuleScope $script:ModuleName {
            Get-MappingBranch -Mapping ([pscustomobject]@{ tfvcPath = '$/x' }) | Should -Be 'main'
        }
    }

    It 'returns distinct branches in first-seen order' {
        InModuleScope $script:ModuleName {
            $m = @(
                [pscustomobject]@{ tfvcPath = '$/a'; branch = 'dev' },
                [pscustomobject]@{ tfvcPath = '$/b'; branch = 'main' },
                [pscustomobject]@{ tfvcPath = '$/c'; branch = 'dev' }
            )
            $result = Get-ConfigBranches -SourceMappings $m
            $result | Should -Be @('dev', 'main')
        }
    }

    It 'picks main as the primary branch when present' {
        InModuleScope $script:ModuleName {
            $m = @([pscustomobject]@{ branch = 'dev' }, [pscustomobject]@{ branch = 'main' })
            Get-PrimaryBranch -SourceMappings $m | Should -Be 'main'
        }
    }

    It 'picks the first branch as primary when main is absent' {
        InModuleScope $script:ModuleName {
            $m = @([pscustomobject]@{ branch = 'dev' }, [pscustomobject]@{ branch = 'release' })
            Get-PrimaryBranch -SourceMappings $m | Should -Be 'dev'
        }
    }
}

Describe 'Invoke-Git (private)' {
    It 'does not let git stderr abort under ErrorActionPreference=Stop' {
        InModuleScope $script:ModuleName {
            $repo = Join-Path ([System.IO.Path]::GetTempPath()) "tfvc2git-git-$([guid]::NewGuid())"
            New-Item -ItemType Directory -Path $repo -Force | Out-Null
            try {
                Invoke-Git -C $repo init | Out-Null
                # 'git checkout --orphan' writes "Switched to a new branch 'X'" to
                # stderr; with $ErrorActionPreference='Stop' that used to terminate
                # the whole replay. Invoke-Git must swallow it.
                $ErrorActionPreference = 'Stop'
                { Invoke-Git -C $repo checkout --orphan develop-initial 2>&1 | Out-Null } | Should -Not -Throw
                $LASTEXITCODE | Should -Be 0
            }
            finally {
                Remove-Item $repo -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
