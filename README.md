# TFVC → GitHub Migration Tool

Migrate specific folders from an on-premise Azure DevOps Server (2020/2022) TFVC repository to GitHub, preserving full changeset history and producing a verifiable, audit-grade trail.

Ships as the **`Tfvc2Git`** PowerShell module — a command-line tool you install once and drive from any Windows PowerShell session.

## Overview

This tool exports TFVC changesets via the Azure DevOps REST API, replays them as Git commits in a local repository, and verifies that the final state matches the TFVC source. Every step is logged and a comprehensive HTML audit report is generated.

**Key Features:**
- **Agentless / PowerShell-only**: No TFS dependencies or Visual Studio client libraries required.
- **Windows Authentication**: Seamlessly authenticate to on-premise servers using your current Windows login (NTLM/Kerberos) by leaving the PAT blank, or use a PAT for cloud/remote servers.
- **PowerShell 5.1 Compatible**: Built to run natively on the built-in Windows PowerShell 5.1 without requiring PowerShell Core.
- **Audit-Grade Verification**: Performs a 3-pass verification (File Inventory, SHA-256 Hash comparisons, and Changeset mapping) to prove 100% data integrity.
- **Massive Repo Support**: Safe for tens of thousands of changesets. Uses memory-efficient ID-range pagination, binary-safe download streams, and checkpoints to resume after interruptions.

---

## Installation

Pick whichever distribution channel suits you.

**PowerShell Gallery** (recommended):
```powershell
Install-Module Tfvc2Git -Scope CurrentUser
Import-Module Tfvc2Git
```

**Chocolatey** (installs the module machine-wide):
```powershell
choco install tfvc2git
```

**GitHub Releases** (manual): download `Tfvc2Git-<version>.zip` from the
[Releases page](https://github.com/HernJer/tfvc-git-migration-tool/releases), extract it into a folder on your `$env:PSModulePath`
(e.g. `Documents\WindowsPowerShell\Modules\Tfvc2Git\<version>`), then `Import-Module Tfvc2Git`.

---

## Commands

The module exports one cmdlet per pipeline stage, plus an orchestrator. You will normally only use `Invoke-TfvcMigration`.

| Cmdlet | Purpose |
|--------|---------|
| `New-TfvcMigrationConfig` | Interactive configuration generator and connection tester. |
| `Export-TfvcChangeset` | Fetch changesets, file metadata, and work item links from TFVC via REST API. |
| `Invoke-TfvcReplay` | Replay each changeset as a Git commit (preserves Author, Date, and Comment). |
| `Test-TfvcMigration` | 3-pass verification (inventory diff, SHA-256 hash checks, commit mapping). |
| `New-TfvcMigrationReport` | Generate a standalone HTML audit document. |
| `Invoke-TfvcMigration` | Orchestrate all steps sequentially with progress reporting. |

> **`tfvc2git` shortcut:** `tfvc2git` is a built-in alias for `Invoke-TfvcMigration`. In any PowerShell session you can run `tfvc2git -Push`. A **Chocolatey** install additionally shims `tfvc2git` onto your `PATH`, so it also works from `cmd.exe` and Windows Terminal:
> ```
> C:\> tfvc2git -ConfigPath .\config.json -Push
> ```
> Interactive config generation stays in PowerShell (`New-TfvcMigrationConfig`).

Run `Get-Help <cmdlet> -Full` for parameters and examples.

### Pipeline Architecture

```
New-TfvcMigrationConfig → Export-TfvcChangeset → Invoke-TfvcReplay → Test-TfvcMigration → New-TfvcMigrationReport
```

`Invoke-TfvcMigration` runs Export → Replay → Verify → Report in-process.

---

## Prerequisites

| Requirement | Details |
|-------------|---------|
| **PowerShell** | 5.1 or later (Native Windows PowerShell supported) |
| **Git CLI** | Installed and available in `PATH` (`git --version`) |
| **Azure DevOps Server** | 2020 or 2022 on-premises (REST API v6.0 or v7.0) |
| **Authentication** | Active Windows Login (for on-prem HTTP) OR a Personal Access Token (PAT) with **Code (Read)** scope |
| **GitHub repository** | Created and completely empty (no initial commits, no README) |

---

## Quick Start

```powershell
Import-Module Tfvc2Git

# 1. Generate config interactively
# Note: For on-premise HTTP servers, just press Enter when prompted for the PAT to use Windows Auth.
New-TfvcMigrationConfig

# 2. Run a Dry-Run first to test extraction
Invoke-TfvcMigration -DryRun

# 3. Run the full migration and push to GitHub
Invoke-TfvcMigration -Push

# 4. Review the audit report
Start-Process .\migration-output\audit-report.html
```

---

## Configuration Details

The tool reads a `config.json` file. You can generate this using `New-TfvcMigrationConfig` or copy `config-sample.json` from the module folder.

### Source Mappings

You can map one or more TFVC paths to specific folders inside your Git repository.

**Example 1: Single folder → single repo**
Migrate `$/MyProject/Application1` to the root of a new GitHub repo.
```json
    "sourceMappings": [
        {
            "tfvcPath": "$/MyProject/Application1",
            "destinationPath": ""
        }
    ]
```

**Example 2: Multiple folders → combined monorepo**
Merge two TFVC folders into a single Git repo under separate subdirectories.
```json
    "sourceMappings": [
        {
            "tfvcPath": "$/MyProject/Frontend",
            "destinationPath": "frontend"
        },
        {
            "tfvcPath": "$/MyProject/Backend",
            "destinationPath": "backend"
        }
    ]
```

---

## Step-by-Step Usage

### 1. New-TfvcMigrationConfig
Runs an interactive prompt to build `config.json`. It will automatically test the connection to your Azure DevOps server before saving.
* **Pro-tip:** For Azure DevOps Server 2020, type `6.0` when prompted for the API Version. For 2022, press Enter to accept `7.0`.
* For unattended setup, use `New-TfvcMigrationConfig -NonInteractive -ServerUrl ... -Project ... -Pat ... -TfvcPath ... -GitRemoteUrl ...`.

### 2. Invoke-TfvcMigration
The main orchestrator. You should generally just use this command to run the migration.

```powershell
# Full migration
Invoke-TfvcMigration

# Dry run — export only, see what would be migrated without touching Git
Invoke-TfvcMigration -DryRun

# Push to GitHub after a successful replay
Invoke-TfvcMigration -Push

# Resume an interrupted migration from the last checkpoint
Invoke-TfvcMigration -Resume
```

---

## Resume After Interruption

Both the Export and Replay steps are built to survive network drops or manual interruptions.

1. **Export** saves an `export-checkpoint.json` every 100 changesets.
2. **Replay** saves a `replay-checkpoint.json` every 50 commits.

To resume an interrupted run safely, simply pass the `-Resume` flag:

```powershell
Invoke-TfvcMigration -Resume
```

---

## Audit Deliverables

After a successful migration, your output directory will contain a robust set of artifacts proving the integrity of the migration to auditors:

| File | Purpose |
|------|---------|
| `audit-report.html` | A standalone, printable HTML report summarizing the migration with pass/fail badges. |
| `verification/summary.json` | Machine-readable pass/fail results for automated checks. |
| `verification/hash-comparison.csv` | File-by-file SHA-256 hash comparison between TFVC tip and Git HEAD. |
| `verification/inventory-diff.json` | Complete file inventory comparison to catch orphaned files. |
| `verification/changeset-mapping.csv` | A direct mapping of every TFVC changeset ID to its new Git commit SHA. |
| `migration-log.txt` | Timestamped log of all script operations and API calls. |
| Git commit footers | Every commit message contains `TFVC-Changeset: {id}` for lifetime traceability. |

These artifacts mathematically prove that the migration is complete, the file content is byte-identical, and the history is fully preserved.

---

## Troubleshooting

### HTTP 400 Bad Request during configuration
If your Azure DevOps server is on-premises and uses `http://` instead of `https://`, IIS will often reject Personal Access Tokens (Basic Auth) for security reasons.
**Fix:** Run `New-TfvcMigrationConfig` again, and when prompted for the PAT, leave it completely blank. The tool will automatically fall back to Windows Authentication (NTLM) and succeed.

### API Version Errors
If you get 404s or Bad Requests, ensure you are using the correct API version for your server:
- Azure DevOps Server 2022: `7.0`
- Azure DevOps Server 2020: `6.0`

### Verbose REST tracing
Every API call is emitted via `Write-Verbose`. To see the exact URLs being requested, add `-Verbose`:
```powershell
Invoke-TfvcMigration -DryRun -Verbose
```

### PowerShell 5.1 Strict Mode errors
If you modify the module, be aware it runs with `Set-StrictMode -Version Latest`. Azure DevOps REST APIs omit empty JSON properties entirely rather than returning `null`. You must check for a property's existence using `$obj.psobject.Properties.Match('PropName')` before dot-accessing it, or PowerShell will throw a fatal error. All built-in functions already handle this safely.

---

## Development & Releasing

The repository is laid out as a standard PowerShell module:

```
Tfvc2Git/          # the publishable module
  Tfvc2Git.psd1    # manifest
  Tfvc2Git.psm1    # loader
  Public/                  # exported cmdlets (one per file)
  Private/TfvcApi.ps1      # internal REST API + helpers
build/
  Build.ps1                # stamp version, test, package, choco-stage
  choco/                   # Chocolatey nuspec + install scripts
tests/                     # Pester tests
.github/workflows/         # ci.yml (PRs) + publish.yml (tags)
```

**Validate locally:**
```powershell
Install-Module PSScriptAnalyzer, Pester -Scope CurrentUser
./build/Build.ps1 -Test
Invoke-Pester ./tests
```

**Cut a release:** push a semver tag and the `Publish` workflow builds and publishes to every configured channel.
```powershell
git tag v1.0.0
git push origin v1.0.0
```

The workflow requires two repository secrets (Settings → Secrets and variables → Actions):

| Secret | Used for |
|--------|----------|
| `PSGALLERY_API_KEY` | Publishing to the PowerShell Gallery |
| `CHOCO_API_KEY` | Pushing to Chocolatey |

If a secret is absent the corresponding channel is skipped (with a warning) rather than failing the run. GitHub Releases always run using the built-in `GITHUB_TOKEN`.
