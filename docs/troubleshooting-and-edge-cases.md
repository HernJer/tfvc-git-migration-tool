# Troubleshooting and Edge Cases

When migrating large legacy repositories, you are likely to encounter network interruptions, missing files, or remote repository conflicts. The `tfvc2git` tool is designed to be highly resilient against these edge cases.

## Remote Push Rejections (`[rejected] main -> main (fetch first)`)

If you execute `tfvc2git -Push` to automatically push the migrated repository to GitHub, you may encounter an error like this during Pass 4:

```text
 ! [rejected]        main -> main (fetch first)
error: failed to push some refs to 'https://github.com/org/repo.git'
hint: Updates were rejected because the remote contains work that you do not
hint: have locally.
```

**Cause**: You provided a `gitRemoteUrl` in `config.json` that points to a repository that is *not* empty. For example, if you created the repository on GitHub with a default `README.md` or `.gitignore`, the remote `main` branch will have an initial commit that conflicts with the completely distinct `main` branch generated locally by `tfvc2git`.

**Resolution**:
1. Open a terminal and navigate to your `migration-output/git-repo` directory.
2. If you do not care about the remote initialization commits, force push your local history:
   ```bash
   git push --force --all origin
   ```
3. Once the push succeeds, you can run `tfvc2git report` to re-generate the audit report. Note: Because `tfvc2git -Push` failed originally, the report's `RemotePush` status may still say `FAIL`. The migration itself is mathematically sound and completed successfully.

## Verification Cleanups & Auto-Resolutions

If you check the audit report, you might notice a section titled "Cleanups & Auto-Resolutions". This tracks expected discrepancies that the tool automatically resolved during verification:
1. **Orphaned Files (Destroyed in TFVC)**: If TFVC administrators used the "Destroy" command to permanently delete files without leaving a deletion changeset, the tool might inadvertently migrate those files into Git. The verification step detects these orphaned files and automatically issues a `git rm` and commits the cleanup.
2. **Redacted Secrets**: If `secretScanningEnabled` is turned on, the migration tool scrubbed sensitive passwords or tokens from the Git history. During verification, the tool applies the same scrubbing logic to the raw TFVC files as they are downloaded before hashing them. This ensures the hashes perfectly match without falsely failing the integrity check. Both operations are securely tracked in the final HTML report.

## Network Interruptions During Export or Replay

Large migrations can take hours or even days. If your VPN disconnects, your machine goes to sleep, or the TFS server restarts, the pipeline will fail with an exception.

**Resolution**: Do not delete your `migration-output` directory! The tool checkpoints its progress. Simply rerun the failed step with the `--Resume` flag.

For example, if the export fails:
```powershell
tfvc2git export --Resume
```

If the replay fails:
```powershell
tfvc2git replay --Resume
```

The tool will read `export-checkpoint.json` or `replay-checkpoint.json` and pick up exactly where it left off, skipping changesets that were already processed.

## HTTP 400 Bad Request or HTTP 404 Not Found during Export

**Cause**: The version of the Azure DevOps / TFS REST API being used by `tfvc2git` (default `7.0`) is not supported by your TFS server. Older on-premises TFS servers (e.g., TFS 2017) require much older API endpoints.

**Resolution**: Modify your `config.json` and manually specify a lower `apiVersion`:

```json
{
  "apiVersion": "6.0",
  ...
}
```
If `6.0` fails, you can try `5.1`, `4.1`, or `3.0` depending on the age of your TFS server.

## "Cannot bind argument to parameter 'Path' because it is an empty string"

**Cause**: This error occurs when the `tfvc2git` wrapper inadvertently passes an empty string argument to a subcommand. This usually happens if you execute a command with a trailing space in certain terminal environments (e.g., `tfvc2git verify `).

**Resolution**: Ensure you are using the latest version of `tfvc2git` (v0.0.0+), which includes graceful handling of empty arguments. If you encounter this on an older version, strictly run `tfvc2git verify -ConfigPath ./config.json` instead of relying on default empty arguments.

## PowerShell Strict Mode Errors (`The variable '$LASTEXITCODE' cannot be retrieved`)

**Cause**: `tfvc2git` utilizes `Set-StrictMode -Version Latest`. If you execute the script from an interactive PowerShell session where `$LASTEXITCODE` was never initialized, strict mode will throw an error when `tfvc2git` attempts to read it during Git execution.

**Resolution**: Initialize the variable in your terminal before running the tool:
```powershell
$global:LASTEXITCODE = 0
tfvc2git run
```
