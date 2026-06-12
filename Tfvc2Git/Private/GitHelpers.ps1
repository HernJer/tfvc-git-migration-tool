<#
.SYNOPSIS
    Safe wrapper for invoking the git CLI.
.DESCRIPTION
    git writes informational messages (e.g. "Switched to a new branch 'X'") to
    stderr, not stdout. Under $ErrorActionPreference = 'Stop', merging that stderr
    with 2>&1 turns those normal messages into terminating errors. This wrapper
    runs git with the error preference set to 'Continue' so stderr never aborts
    the pipeline; callers check $LASTEXITCODE for genuine failures.

    Declared with no parameters so raw argv (including -C and --flags) flows
    straight through $args to git. Not exported.
#>

function Invoke-Git {
    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & git @args 2>&1
    }
    finally {
        $ErrorActionPreference = $eap
    }
}
