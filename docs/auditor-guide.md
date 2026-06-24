# Auditor's Guide to the Migration Report

This guide is intended for compliance officers, auditors, and engineering leads who need to verify that a Team Foundation Version Control (TFVC) to Git migration was executed with 100% data integrity and no historical loss.

The `tfvc2git` tool generates a standalone HTML artifact named `audit-report.html` at the end of the migration pipeline. This report provides mathematical proof of the migration's fidelity.

## Understanding the "Overall Result"

If the report displays an Overall Result of **PASS**, it means the migration successfully passed a strict 4-pass verification process. Every single file on the Git remote perfectly matches its historical TFVC counterpart, and every historical changeset was successfully mapped to a Git commit.

If any single file differs, goes missing, or fails to push to the remote, the overall result will report **FAIL**.

---

## The Four Verification Passes

The report is broken down into four distinct cryptographic and metadata checks.

### 1. File Inventory Check
* **What it proves:** No files were left behind, and no extra files were mysteriously added.
* **How it works:** The tool queries the TFVC server for a complete list of every file present at the tip of the mapped paths. It then queries the local Git repository for its list of tracked files. The two lists must exactly match.
* **Exceptions:** Empty directories are ignored (Git does not track empty directories).

### 2. Content Hash Check (SHA-256)
* **What it proves:** The contents of every file are byte-for-byte identical to the server.
* **How it works:** The tool concurrently downloads every file from the TFVC server to a temporary directory. It calculates a SHA-256 cryptographic hash of the downloaded file, and calculates a SHA-256 hash of the corresponding file in the Git repository. The hashes must perfectly match.

### 3. Changeset Coverage
* **What it proves:** The entire history of the repository was preserved, including author attribution, timestamps, and commit messages.
* **How it works:** The tool retrieves the complete list of TFVC Changeset IDs that affected the migrated folders. It then reads the Git commit history and searches the commit messages for the `TFVC-Changeset: {id}` footers. It verifies that every single TFVC changeset has a corresponding Git commit, and that there are no "orphaned" Git commits that lack a TFVC mapping.

### 4. Remote Push Verification
* **What it proves:** The verified local Git repository was successfully uploaded to the central Git hosting provider (e.g., GitHub, Azure Repos).
* **How it works:** The tool queries the Git remote (`origin`) and compares the commit hashes of the remote branches against the local branches. If they match, it proves that the exact state verified by Passes 1-3 is now safely hosted on the remote server.

---

## Cleanups & Auto-Resolutions

When migrating decades of legacy TFVC history, the tool may encounter discrepancies caused by destructive TFVC administrative actions or modern security requirements. To ensure a clean migration, the tool automatically resolves these issues and logs them in this section.

**These resolutions are expected and do not invalidate the integrity of the migration.**

### Orphaned Files Removed
In TFVC, administrators can use the `tf destroy` command to permanently obliterate a file or folder from the database. Unlike a standard "Delete", a Destroy operation leaves no changeset trail. 
Because `tfvc2git` replays history chronologically, it will replay the original "Add" changeset for the file. However, because there is no "Delete" changeset to replay, the file becomes "orphaned" in Git—it exists in Git, but no longer exists in the TFVC tip.
* **Resolution:** During the File Inventory check, the tool detects these orphaned files, issues a `git rm` to remove them from the Git repository, and commits the cleanup.

### Secrets Redacted
If Secret Scanning was enabled during the migration, the tool actively searched for hardcoded credentials (e.g., passwords, API keys, SAS tokens) in historical changesets and scrubbed them from the Git history.
If the tool attempted to compare the raw TFVC file against the scrubbed Git file, the hashes would naturally mismatch.
* **Resolution:** During the Content Hash check, the tool applies the exact same scrubbing logic to the raw TFVC files *as they are being downloaded* for verification. By hashing the post-scrubbed file, it ensures the rest of the file content matches perfectly while successfully proving the secret was removed.

---

## Known Gaps (By Design)

The report includes a "Known Gaps" section that outlines fundamental differences between TFVC and Git that cannot be migrated. These are architectural limitations of the version control systems, not failures of the migration tool.

1. **Empty Folders:** TFVC tracks folders as distinct items. Git only tracks files. Any empty folders in TFVC are intentionally dropped.
2. **Git Ignore / Attributes:** The files `.gitignore` and `.gitattributes` are reserved by Git. If TFVC happens to contain files with these exact names, they are dropped to prevent them from interfering with the new Git repository's configuration.
3. **Case Sensitivity:** Windows and TFVC are case-insensitive, but Git is fundamentally case-sensitive. The tool normalizes file paths to match the exact casing provided by the TFVC server to prevent duplicate file conflicts on Linux-based Git hosting platforms.

---

## Audit Process & Formal Sign-off

To satisfy Data Migration Plan and Sign-off requirements without manual overhead, this tool natively employs an "Audit as Code" approach via GitOps.

### 1. Automated Audit PR Generation
When the migration completes successfully and pushes the code to the target repository (e.g., `main`), the tool automatically executes an additional Audit Publish step:
- It creates a new, dedicated branch for the audit report (e.g., `audit/migration-report-<timestamp>`).
- It commits the `audit-report.html` and migration logs into a `.migration-audit/` folder.
- It uses the GitHub CLI (`gh`) to automatically open a Pull Request against the target branch (`main`).

### 2. The Pull Request as the Migration Plan
The automated Pull Request serves as the formal Migration Plan. The PR body outlines the scope and requests review of the attached cryptographic evidence.

### 3. Formal Stakeholder Sign-off
Data owners, technical leads, and compliance officers are added as Reviewers to this Pull Request.
- Reviewers download and inspect the `audit-report.html` from the PR files.
- By clicking **Approve** on the Pull Request, stakeholders provide their formal, non-repudiable sign-off that the migration results are accepted.

### 4. Access Restrictions and Integrity (RBAC)
Once the Pull Request is approved and merged into `main`:
- Standard branch protection policies prevent any unauthorized user from tampering with or rewriting the migration history or the audit report.
- Every action (who ran the migration, who approved it, who merged it) is permanently logged in the Git provider's audit trail, satisfying strict compliance access controls.
