# TFVC → GitHub Migration Tool

Migrate specific folders from an on-premise Azure DevOps Server (2020/2022) TFVC repository to GitHub, preserving full changeset history and producing a verifiable, audit-grade trail.

## Overview

This tool exports TFVC changesets via the Azure DevOps REST API, replays them as Git commits in a local repository, and verifies that the final state matches the TFVC source. Every step is logged and a comprehensive HTML audit report is generated.

**Key Features:**
- **Agentless / PowerShell-only**: No TFS dependencies or Visual Studio client libraries required.
- **Windows Authentication**: Seamlessly authenticate to on-premise servers using your current Windows login (NTLM/Kerberos) by leaving the PAT blank, or use a PAT for cloud/remote servers.
- **PowerShell 5.1 Compatible**: Built to run natively on the built-in Windows PowerShell 5.1 without requiring PowerShell Core.
- **Audit-Grade Verification**: Performs a 3-pass verification (File Inventory, SHA-256 Hash comparisons, and Changeset mapping) to prove 100% data integrity.
- **Massive Repo Support**: Safe for tens of thousands of changesets. Uses memory-efficient ID-range pagination, binary-safe download streams, and checkpoints to resume after interruptions.

### Pipeline Architecture

```
Configure.ps1 → Export.ps1 → Replay.ps1 → Verify.ps1 → Report.ps1
```

| Step | Script | Purpose |
|------|--------|---------|
| 0 | `Configure.ps1` | Interactive configuration generator and connection tester. |
| 1 | `Export.ps1` | Fetch changesets, file metadata, and work item links from TFVC via REST API. |
| 2 | `Replay.ps1` | Replay each changeset as a Git commit (preserves Author, Date, and Comment). |
| 3 | `Verify.ps1` | 3-pass verification (inventory diff, SHA-256 hash checks, commit mapping). |
| 4 | `Report.ps1` | Generate a standalone HTML audit document. |
| — | `Run-Migration.ps1` | Orchestrate all steps sequentially with progress reporting. |

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
# Note: For on-premise HTTP servers, just press Enter when prompted for the PAT to use Windows Auth.
.\Configure.ps1

# 2. Run a Dry-Run first to test extraction
.\Run-Migration.ps1 -DryRun

# 3. Run the full migration and push to GitHub
.\Run-Migration.ps1 -Push

# 4. Review the audit report
Start-Process .\migration-output\audit-report.html
```

---

## Configuration Details

The tool reads a `config.json` file. You can generate this using `.\Configure.ps1` or copy `config-sample.json`.

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

### 1. Configure.ps1
Runs an interactive prompt to build `config.json`. It will automatically test the connection to your Azure DevOps server before saving.
* **Pro-tip:** For Azure DevOps Server 2020, type `6.0` when prompted for the API Version. For 2022, press Enter to accept `7.0`.

### 2. Run-Migration.ps1
The main orchestrator. You should generally just use this script to run the migration.

```powershell
# Full migration
.\Run-Migration.ps1

# Dry run — export only, see what would be migrated without touching Git
.\Run-Migration.ps1 -DryRun

# Push to GitHub after a successful replay
.\Run-Migration.ps1 -Push

# Resume an interrupted migration from the last checkpoint
.\Run-Migration.ps1 -Resume
```

---

## Resume After Interruption

Both the Export and Replay steps are built to survive network drops or manual interruptions.

1. **Export** saves an `export-checkpoint.json` every 100 changesets.
2. **Replay** saves a `replay-checkpoint.json` every 50 commits.

To resume an interrupted run safely, simply pass the `-Resume` flag:

```powershell
.\Run-Migration.ps1 -Resume
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

### HTTP 400 Bad Request during Configure
If your Azure DevOps server is on-premises and uses `http://` instead of `https://`, IIS will often reject Personal Access Tokens (Basic Auth) for security reasons. 
**Fix:** Run `.\Configure.ps1` again, and when prompted for the PAT, leave it completely blank. The script will automatically fall back to Windows Authentication (NTLM) and succeed.

### API Version Errors
If you get 404s or Bad Requests, ensure you are using the correct API version for your server:
- Azure DevOps Server 2022: `7.0`
- Azure DevOps Server 2020: `6.0`

### PowerShell 5.1 Strict Mode errors
If you modify the scripts, be aware they run with `Set-StrictMode -Version Latest`. Azure DevOps REST APIs omit empty JSON properties entirely rather than returning `null`. You must check for a property's existence using `$obj.psobject.Properties.Match('PropName')` before dot-accessing it, or PowerShell will throw a fatal error. All built-in scripts already handle this safely.
