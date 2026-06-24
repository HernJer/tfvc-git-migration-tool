# Configuration Guide

The `config.json` file is the heart of the `tfvc2git` migration tool. It defines how TFVC folders map to Git branches, handles authentication, and configures performance tuning.

## Minimal Example

```json
{
  "adoServerUrl": "https://tfs.yourcompany.com/tfs",
  "collection": "DefaultCollection",
  "project": "MyProject",
  "pat": "YOUR_PERSONAL_ACCESS_TOKEN",
  "outputDir": "./migration-output",
  "sourceMappings": [
    {
      "tfvcPath": "$/MyProject/Main",
      "branch": "main",
      "destinationPath": ""
    }
  ]
}
```

## Dependent Branches (`gitParentBranch`)

In complex TFVC setups, branches have a hierarchical relationship. For instance, `develop` may have originally been branched from `main`. By default, Git repositories created by `tfvc2git` will have independent, orphaned histories for every branch.

If you want `tfvc2git` to automatically branch `develop` off of `main`, you must specify a `gitParentBranch` in the source mapping for `develop`.

```json
  "sourceMappings": [
    {
      "tfvcPath": "$/MyProject/Main",
      "branch": "main",
      "destinationPath": ""
    },
    {
      "tfvcPath": "$/MyProject/Dev",
      "branch": "develop",
      "gitParentBranch": "main",
      "destinationPath": ""
    }
  ]
```

### How Dependent Branches Work
1. **Topological Execution**: The tool automatically analyzes the dependencies and ensures `main` is completely processed *before* `develop` is started.
2. **Branch Creation**: When the tool begins processing `develop`, instead of creating an orphaned branch, it performs `git checkout -b develop main`.
3. **Commit History**: The `develop` branch will inherit the complete commit history of `main` up to that point in time. Any TFVC changes mapped to `develop` will be applied on top of the `main` history.

## Performance Tuning

Migrating large repositories can be time-consuming due to the sheer volume of API calls and file downloads. You can tweak `config.json` to improve performance:

### `downloadConcurrency`
During the Replay and Verify phases, physical files must be downloaded from TFVC. By default, `tfvc2git` downloads 8 files concurrently. You can increase this value if you have high network bandwidth and your TFS server can handle the load.

```json
{
  "downloadConcurrency": 16,
  "sourceMappings": [ ... ]
}
```
*Warning: Setting this too high (e.g., > 32) can cause your TFS server to throw HTTP 429 Too Many Requests or HTTP 503 Service Unavailable errors.*

### `exportConcurrency`
During the Export phase, metadata for each changeset is fetched from TFVC. By default, `tfvc2git` fetches metadata for 1 changeset at a time (sequential execution) to ensure maximum compatibility. You can increase this value to fetch changeset metadata in parallel, drastically speeding up the export phase.

```json
{
  "exportConcurrency": 8,
  "sourceMappings": [ ... ]
}
```
*Note: In PowerShell 5.1, this uses a background RunspacePool. In PowerShell 7+, it leverages the native `ForEach-Object -Parallel`.*

### `apiVersion`
The Azure DevOps REST API version to target. Defaults to `7.0`. Older TFS 2017/2018 servers may require a lower version (e.g., `3.0` or `4.1`). If you encounter HTTP 400 or HTTP 404 errors during export, lowering the `apiVersion` will often resolve the issue.

```json
{
  "apiVersion": "5.1",
  "sourceMappings": [ ... ]
}
```
