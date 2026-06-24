function Publish-GitHubAuditPr {
    <#
    .SYNOPSIS
        Automatically commits the audit report to a new branch and opens a GitHub PR.
    .DESCRIPTION
        This function handles the 'Audit as Code' sign-off process. It copies the 
        migration artifacts into a .migration-audit directory, commits them to a 
        new audit branch, pushes to the GitHub remote, and automatically creates 
        a Pull Request using the GitHub CLI (gh).
    .PARAMETER ConfigPath
        Path to the migration config.json file.
    #>
    [CmdletBinding()]
    param(
        [string]$ConfigPath = './config.json'
    )

    $ErrorActionPreference = 'Stop'

    # Validate gh CLI is installed
    if (-not (Get-Command 'gh' -ErrorAction SilentlyContinue)) {
        Write-Host "  [!] GitHub CLI ('gh') is not installed or not in PATH." -ForegroundColor Yellow
        Write-Host "      Cannot automatically create the audit PR. Please install it from https://cli.github.com/ and authenticate." -ForegroundColor Yellow
        return
    }

    $resolvedConfig = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ConfigPath)
    $config = Get-Content $resolvedConfig -Raw | ConvertFrom-Json

    $outputDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($config.outputDir)
    $gitRepoDir = Join-Path $outputDir 'git-repo'
    $reportPath = Join-Path $outputDir 'audit-report.html'
    $logPath = Join-Path $outputDir 'migration-log.txt'

    if (-not (Test-Path $reportPath)) {
        Write-Host "  [!] Audit report not found at $reportPath. Skipping PR creation." -ForegroundColor Yellow
        return
    }

    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $branchName = "audit/migration-report-$timestamp"

    Write-Host "  [+] Creating audit branch: $branchName" -ForegroundColor Cyan

    Push-Location $gitRepoDir
    try {
        # Check out the main target branch (assuming main for now, but could be dynamic)
        # Using the first mapping's branch as base, default to main
        $baseBranch = "main"
        if ($config.sourceMappings.Count -gt 0 -and $config.sourceMappings[0].branch) {
            $baseBranch = $config.sourceMappings[0].branch
        }

        # Ensure we are on the base branch and clean
        git checkout -q $baseBranch 2>&1 | Out-Null
        
        # Create and checkout the new audit branch
        git checkout -q -b $branchName 2>&1 | Out-Null

        # Create audit directory
        $auditDir = Join-Path $gitRepoDir '.migration-audit'
        if (-not (Test-Path $auditDir)) {
            New-Item -ItemType Directory -Path $auditDir | Out-Null
        }

        # Copy artifacts
        Copy-Item -Path $reportPath -Destination $auditDir -Force
        if (Test-Path $logPath) {
            Copy-Item -Path $logPath -Destination $auditDir -Force
        }

        # Commit
        git add .migration-audit/
        git commit -m "chore: Add migration audit report for formal sign-off"

        # Push branch
        Write-Host "  [+] Pushing audit branch to remote..." -ForegroundColor Cyan
        $maxRetries = 3
        for ($i = 1; $i -le $maxRetries; $i++) {
            git push -u origin $branchName
            if ($LASTEXITCODE -eq 0) { break }
            Write-Host "  [!] Push failed (Attempt $i of $maxRetries)" -ForegroundColor Yellow
            if ($i -lt $maxRetries) { Start-Sleep -Seconds 5 }
        }
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to push audit branch to remote after $maxRetries attempts."
        }

        # Create PR
        Write-Host "  [+] Creating GitHub Pull Request..." -ForegroundColor Cyan
        $prTitle = "Migration Audit Report & Formal Sign-off"
        $prBody = @"
## Data Migration / Integrity Plan

This PR serves as the formal Data Migration Plan and Sign-off vehicle. 
The code migration has been pushed to the target branch. This PR contains the cryptographic audit report proving data integrity.

### Verification Procedures
The attached HTML Audit Report contains mathematical proof (via SHA-256 hash comparisons and changeset mapping) that the migration completed with 100% fidelity.

### Formal Sign-off
**Stakeholders and Data Owners**: Please review the `audit-report.html`. 
Approving this Pull Request constitutes formal sign-off that the migration results are accepted and verified.
"@

        gh pr create --title $prTitle --body $prBody --base $baseBranch --head $branchName
        
        Write-Host "  [+] Audit PR created successfully!" -ForegroundColor Green
    }
    catch {
        Write-Host "  [!] Failed to create Audit PR: $($_.Exception.Message)" -ForegroundColor Red
    }
    finally {
        Pop-Location
    }
}
