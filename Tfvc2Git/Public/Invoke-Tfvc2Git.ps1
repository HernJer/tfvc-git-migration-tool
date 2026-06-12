function Invoke-Tfvc2Git {
    <#
    .SYNOPSIS
        Unified command-line entry point for the Tfvc2Git tool (the `tfvc2git` command).
    .DESCRIPTION
        Dispatches to the underlying cmdlets based on a leading subcommand, so the
        whole tool is reachable through the single `tfvc2git` command - including
        from cmd.exe via the Chocolatey PATH shim. Any remaining arguments are
        forwarded to the target cmdlet unchanged.

        Subcommands (a leading '--' is also accepted, e.g. --create-config):
          config | create-config | init   -> New-TfvcMigrationConfig
          run | migrate                    -> Invoke-TfvcMigration   (default)
          export                           -> Export-TfvcChangeset
          replay                           -> Invoke-TfvcReplay
          verify | test                    -> Test-TfvcMigration
          report                           -> New-TfvcMigrationReport
          help | --help | -h | /?          -> show usage
          version | --version              -> show the module version

        With no subcommand - or when the first argument is a switch such as -Push -
        all arguments are passed to Invoke-TfvcMigration.

        NOTE: this function intentionally declares no parameters so that raw argv
        (including GNU-style --flags) lands in $args untouched for dispatch.
    .EXAMPLE
        tfvc2git --create-config
    .EXAMPLE
        tfvc2git -ConfigPath .\config.json -Push
    .EXAMPLE
        tfvc2git verify -ConfigPath .\config.json
    #>

    function Show-Tfvc2GitUsage {
        Write-Host @"
tfvc2git - migrate TFVC folders to Git/GitHub

Usage:
  tfvc2git [run] [options]      Run the full migration pipeline (default)
  tfvc2git config               Generate config.json interactively
                                (aliases: --create-config, init)
  tfvc2git export [options]     Export changesets only
  tfvc2git replay [options]     Replay changesets as Git commits
  tfvc2git verify [options]     Verify the migration (3-pass)
  tfvc2git report [options]     Generate the HTML audit report
  tfvc2git help                 Show this help
  tfvc2git version              Show the installed version

Options are forwarded to the underlying command, for example:
  tfvc2git -ConfigPath .\config.json -Push
  tfvc2git config -NonInteractive -ServerUrl https://tfs:8080/tfs -Project P -Pat *** -TfvcPath `$/P/App -GitRemoteUrl https://github.com/org/repo.git
  tfvc2git verify -ConfigPath .\config.json
"@
    }

    $argv = @($args)
    $sub  = if ($argv.Count -ge 1) { "$($argv[0])" } else { '' }
    $rest = if ($argv.Count -ge 2) { $argv[1..($argv.Count - 1)] } else { @() }

    switch -Regex ($sub) {
        '^(--)?(config|create-config|init)$' { New-TfvcMigrationConfig @rest; break }
        '^(--)?(run|migrate)$'               { Invoke-TfvcMigration   @rest; break }
        '^(--)?export$'                      { Export-TfvcChangeset   @rest; break }
        '^(--)?replay$'                      { Invoke-TfvcReplay      @rest; break }
        '^(--)?(verify|test)$'               { Test-TfvcMigration     @rest; break }
        '^(--)?report$'                      { New-TfvcMigrationReport @rest; break }
        '^(--help|-h|help|/\?)$'             { Show-Tfvc2GitUsage; break }
        '^(--version|version)$' {
            $v = $MyInvocation.MyCommand.Module.Version
            Write-Host "tfvc2git $(if ($v) { $v } else { '0.0.0' })"
            break
        }
        default {
            if ($sub -and $sub -notmatch '^-') {
                throw "Unknown command '$sub'. Run 'tfvc2git help' for usage."
            }
            Invoke-TfvcMigration @argv
        }
    }
}
