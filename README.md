# TFVC → GitHub Migration Tool

The `tfvc2git` tool provides a robust, reproducible, and auditable path for migrating complex TFVC repositories to Git (e.g. GitHub or Azure Repos). It guarantees zero data loss by performing a rigorous 3-pass cryptographic hash verification across the entire repository history.

For an exhaustive dive into the architecture, edge cases, and configuration, please see the [**Detailed Documentation**](./docs/index.md).

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

> **The `tfvc2git` command:** the whole tool is reachable through a single `tfvc2git` command that dispatches to the cmdlets above. After a **Chocolatey** install it's shimmed onto your `PATH`, so it works from `cmd.exe`, PowerShell, and Windows Terminal:
> ```
> tfvc2git config                            # generate config.json (also: --create-config, init)
> tfvc2git -ConfigPath .\config.json -Push   # run the full migration (default)
> tfvc2git verify -ConfigPath .\config.json  # subcommands: export | replay | verify | report
> tfvc2git help
> ```
> Bare options with no subcommand run the migration, so `tfvc2git -Push` still works. The individual cmdlets remain available for idiomatic PowerShell use.

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
# 1. Generate config interactively
#    (Press Enter at the PAT prompt to use Windows Auth on on-prem HTTP servers.)
tfvc2git config

# 2. Dry-run first to test extraction
tfvc2git -DryRun

# 3. Run the full migration and push to GitHub
tfvc2git -Push

# 4. Review the audit report
Start-Process .\migration-output\audit-report.html
```

The `tfvc2git` command auto-loads the module on first use (no `Import-Module` needed). Prefer the named cmdlets? `New-TfvcMigrationConfig` and `Invoke-TfvcMigration -DryRun` do the same thing.

---

## Configuration Details

The tool reads a `config.json` file. You can generate this using `New-TfvcMigrationConfig` or copy `config-sample.json` from the module folder.

### Source Mappings

Each mapping sends a TFVC path to a **Git branch** (`branch`, default `main`) and an optional sub-folder within that branch (`destinationPath`, empty = branch root). All mappings land in **one repository**.

You can also specify a **parent branch** (`gitParentBranch`). If specified, the tool will topological sort branches and create the child branch directly from its parent using `git checkout -b <branch> <parent>` instead of an orphan branch. This mathematically guarantees that parent/child histories are linked (eliminating GitHub "unrelated histories" errors when opening Pull Requests).

**Example 1: Single folder → `main`**
Migrate `$/MyProject/Application1` to the root of the `main` branch.
```json
    "sourceMappings": [
        {
            "tfvcPath": "$/MyProject/Application1",
            "destinationPath": "",
            "branch": "main"
        }
    ]
```

**Example 2: Dependent branch → `develop` branches off `main`**
Send `/Prod` to `main`, and `/DEV` to `develop`. Branch `develop` from `main` so PRs work perfectly.
```json
    "sourceMappings": [
        {
            "tfvcPath": "$/MyProject/Application1/Prod",
            "destinationPath": "",
            "branch": "main"
        },
        {
            "tfvcPath": "$/MyProject/Application1/DEV",
            "destinationPath": "",
            "branch": "develop",
            "gitParentBranch": "main"
        }
    ]
```

**Example 3: Multiple folders → combined monorepo (same branch)**
Merge two folders under sub-directories of `main`.
```json
    "sourceMappings": [
        { "tfvcPath": "$/MyProject/Frontend", "destinationPath": "frontend", "branch": "main" },
        { "tfvcPath": "$/MyProject/Backend",  "destinationPath": "backend",  "branch": "main" }
    ]
```

### How branches are built

Each branch is an **independent history**: for a given branch, only the changesets that touch its mapped folder(s) are replayed, in changeset order. A changeset that touches folders for two branches produces a commit on each. On `-Push`, **all** branches are pushed (`git push --all`). Verification compares each branch's HEAD against its own TFVC source.

### Performance (large migrations)

File downloads dominate the run time. To speed things up:

- **`downloadConcurrency`** (config, default `8`) — number of files downloaded in parallel during replay and verify. Raise it (e.g. `16`–`32`) on a fast LAN connection to the TFS server; lower it if the server pushes back. Replay scales close to linearly with this for download-bound repos.
- **Skip verify for the bulk run** with `tfvc2git -SkipVerify` — verification re-downloads and hashes every file, roughly doubling total I/O. Run it separately when you need the audit.
- **Run on a machine close to the TFS server** — per-request latency is the limiting factor over a WAN.

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

For a comprehensive guide on handling edge cases like network interruptions, Missing File errors, and Remote Push rejections, please see the [Troubleshooting & Edge Cases](./docs/troubleshooting-and-edge-cases.md) documentation.

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

### Beta / prerelease testing

Tag with an alphanumeric prerelease label to publish a **beta** that won't supersede the stable version:

```powershell
git tag v1.0.0-beta1
git push origin v1.0.0-beta1
```

This stamps the module as `1.0.0-beta1`, marks the GitHub Release as a pre-release, and publishes a prerelease to the PowerShell Gallery and Chocolatey. Install it explicitly with:

```powershell
Install-Module Tfvc2Git -AllowPrerelease      # PowerShell Gallery
choco install tfvc2git --pre                  # Chocolatey
```

If the registry secrets below aren't set yet, the beta still produces a downloadable GitHub Release `.zip` you can extract and `Import-Module` to test — the registry steps just skip. Once the beta checks out, tag `v1.0.0` for the stable release.

The workflow requires two repository secrets (Settings → Secrets and variables → Actions):

| Secret | Used for |
|--------|----------|
| `PSGALLERY_API_KEY` | Publishing to the PowerShell Gallery |
| `CHOCO_API_KEY` | Pushing to Chocolatey |

If a secret is absent the corresponding channel is skipped (with a warning) rather than failing the run. GitHub Releases always run using the built-in `GITHUB_TOKEN`.
