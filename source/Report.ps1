<#
.SYNOPSIS
    Generates a standalone HTML audit report for a TFVC-to-GitHub migration.
.DESCRIPTION
    Reads verification data produced by Verify.ps1 and generates a professional,
    self-contained HTML report suitable for auditors and compliance review.
.PARAMETER ConfigPath
    Path to config.json. Defaults to ./config.json.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = "./config.json"
)

$ErrorActionPreference = 'Stop'

function ConvertTo-HtmlSafe {
    param([string]$Text)
    if (-not $Text) { return '' }
    $Text.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;').Replace("'", '&#39;')
}

function Get-TruncatedHash {
    param([string]$Hash, [int]$Length = 16)
    if (-not $Hash -or $Hash.Length -le $Length) { return $Hash }
    $Hash.Substring(0, $Length) + '...'
}

try {
    $config     = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    $outputDir  = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($config.outputDir)
    $verifyDir  = Join-Path $outputDir 'verification'

    $summary    = Get-Content (Join-Path $verifyDir 'summary.json') -Raw | ConvertFrom-Json
    $hashCsv    = Import-Csv  (Join-Path $verifyDir 'hash-comparison.csv')
    $csMappCsv  = Import-Csv  (Join-Path $verifyDir 'changeset-mapping.csv')
    $invDiff    = Get-Content (Join-Path $verifyDir 'inventory-diff.json') -Raw | ConvertFrom-Json

    $reportPath = Join-Path $outputDir 'audit-report.html'
    $now        = (Get-Date).ToString('o')
    $sourceServer = "$($config.adoServerUrl)/$($config.collection)/$($config.project)"

    # -- Compute migration duration from changeset dates --------------
    $dates = @($csMappCsv | Where-Object { $_.Date } | ForEach-Object {
        try { [DateTime]::Parse($_.Date) } catch { $null }
    } | Where-Object { $_ })

    $migrationDuration = 'N/A'
    if ($dates.Count -ge 2) {
        $sorted = $dates | Sort-Object
        $span   = $sorted[-1] - $sorted[0]
        $migrationDuration = "$($sorted[0].ToString('yyyy-MM-dd')) to $($sorted[-1].ToString('yyyy-MM-dd')) ($([int]$span.TotalDays) days)"
    }

    # -- Build table rows --------------------------------------------─

    # File Inventory discrepancies
    $invDiscrepancyRows = ''
    foreach ($f in $invDiff.onlyInTfvc) {
        $safe = ConvertTo-HtmlSafe $f
        $invDiscrepancyRows += "<tr><td class=`"mono`">$safe</td><td>TFVC only</td></tr>`n"
    }
    foreach ($f in $invDiff.onlyInGit) {
        $safe = ConvertTo-HtmlSafe $f
        $invDiscrepancyRows += "<tr><td class=`"mono`">$safe</td><td>Git only</td></tr>`n"
    }

    # Hash comparison rows
    $hashTableRows = ''
    foreach ($row in $hashCsv) {
        $path      = ConvertTo-HtmlSafe $row.Path
        $tfvcFull  = ConvertTo-HtmlSafe $row.TfvcSHA256
        $gitFull   = ConvertTo-HtmlSafe $row.GitSHA256
        $tfvcShort = ConvertTo-HtmlSafe (Get-TruncatedHash $row.TfvcSHA256)
        $gitShort  = ConvertTo-HtmlSafe (Get-TruncatedHash $row.GitSHA256)
        $match     = $row.Match
        $cls       = if ($match -ne 'True') { ' class="mismatch"' } else { '' }
        $hashTableRows += "<tr$cls><td class=`"mono`">$path</td><td class=`"mono`" title=`"$tfvcFull`">$tfvcShort</td><td class=`"mono`" title=`"$gitFull`">$gitShort</td><td>$match</td></tr>`n"
    }

    # Changeset mapping rows
    $unmappedSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($id in $summary.changesetCoverage.unmappedChangesets) { [void]$unmappedSet.Add("$id") }

    $csTableRows = ''
    foreach ($row in $csMappCsv) {
        $csId    = ConvertTo-HtmlSafe $row.ChangesetId
        $hash    = ConvertTo-HtmlSafe $row.GitCommitHash
        $hashShort = if ($hash.Length -gt 8) { $hash.Substring(0, 8) } else { $hash }
        $author  = ConvertTo-HtmlSafe $row.Author
        $date    = ConvertTo-HtmlSafe $row.Date
        $comment = ConvertTo-HtmlSafe $row.Comment
        if ($comment.Length -gt 80) { $comment = $comment.Substring(0, 80) + '...' }
        $cls     = if ($unmappedSet.Contains($row.ChangesetId)) { ' class="mismatch"' } else { '' }
        $csTableRows += "<tr$cls><td>$csId</td><td class=`"mono`" title=`"$(ConvertTo-HtmlSafe $row.GitCommitHash)`">$hashShort</td><td>$author</td><td>$date</td><td>$comment</td></tr>`n"
    }

    # Configuration (sanitized)
    $sanitizedConfig = $config.PSObject.Copy()
    $sanitizedConfig.pat = '***'
    $configJson = ConvertTo-HtmlSafe ($sanitizedConfig | ConvertTo-Json -Depth 5)

    $sourceMappingRows = ''
    foreach ($m in $config.sourceMappings) {
        $tp = ConvertTo-HtmlSafe $m.tfvcPath
        $dp = ConvertTo-HtmlSafe $(if ($m.destinationPath) { $m.destinationPath } else { '(root)' })
        $sourceMappingRows += "<tr><td class=`"mono`">$tp</td><td class=`"mono`">$dp</td></tr>`n"
    }

    # -- Badge and result helpers ------------------------------------─
    $overallBadge = if ($summary.overallResult -eq 'PASS') {
        '<span class="badge pass">PASS</span>'
    } else {
        '<span class="badge fail">FAIL</span>'
    }

    function Get-ResultBadgeSmall($result) {
        if ($result -eq 'PASS') { '<span class="badge-sm pass">PASS</span>' }
        else { '<span class="badge-sm fail">FAIL</span>' }
    }

    $invBadge  = Get-ResultBadgeSmall $summary.inventoryCheck.result
    $hashBadge = Get-ResultBadgeSmall $summary.hashCheck.result
    $csBadge   = Get-ResultBadgeSmall $summary.changesetCoverage.result

    # Inventory discrepancy section
    $invDiscrepancySection = ''
    if ($invDiscrepancyRows) {
        $invDiscrepancySection = @"
        <h3>Discrepancies</h3>
        <div class="table-scroll">
            <table>
                <thead><tr><th>File Path</th><th>Location</th></tr></thead>
                <tbody>$invDiscrepancyRows</tbody>
            </table>
        </div>
"@
    }

    # -- HTML Template ------------------------------------------------
    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>TFVC to GitHub Migration &mdash; Audit Report</title>
<style>
    *, *::before, *::after { box-sizing: border-box; }
    body {
        font-family: system-ui, -apple-system, 'Segoe UI', Roboto, sans-serif;
        font-size: 14px;
        line-height: 1.6;
        color: #212529;
        background: #f5f5f5;
        margin: 0;
        padding: 0;
    }
    .container {
        max-width: 1100px;
        margin: 0 auto;
        padding: 24px;
    }
    .header {
        background: #1a1a2e;
        color: #fff;
        padding: 32px;
        border-radius: 8px 8px 0 0;
        margin-bottom: 0;
    }
    .header h1 {
        margin: 0 0 16px 0;
        font-size: 24px;
        font-weight: 600;
    }
    .header-meta {
        display: flex;
        flex-wrap: wrap;
        gap: 24px;
        font-size: 13px;
        opacity: 0.85;
    }
    .header-meta span { display: inline-block; }
    .header-meta strong { color: #a8d8ea; }
    .badge {
        display: inline-block;
        padding: 6px 20px;
        border-radius: 4px;
        font-weight: 700;
        font-size: 18px;
        letter-spacing: 1px;
    }
    .badge.pass { background: #28a745; color: #fff; }
    .badge.fail { background: #dc3545; color: #fff; }
    .badge-sm {
        display: inline-block;
        padding: 2px 10px;
        border-radius: 3px;
        font-weight: 600;
        font-size: 12px;
    }
    .badge-sm.pass { background: #28a745; color: #fff; }
    .badge-sm.fail { background: #dc3545; color: #fff; }
    .content {
        background: #fff;
        border: 1px solid #dee2e6;
        border-top: none;
        border-radius: 0 0 8px 8px;
        padding: 32px;
    }
    section {
        margin-bottom: 32px;
        padding-bottom: 24px;
        border-bottom: 1px solid #e9ecef;
    }
    section:last-child { border-bottom: none; margin-bottom: 0; }
    h2 {
        font-size: 18px;
        font-weight: 600;
        color: #1a1a2e;
        margin: 0 0 16px 0;
        padding-bottom: 8px;
        border-bottom: 2px solid #e9ecef;
    }
    h3 {
        font-size: 15px;
        font-weight: 600;
        color: #495057;
        margin: 16px 0 8px 0;
    }
    table {
        width: 100%;
        border-collapse: collapse;
        font-size: 13px;
    }
    thead th {
        background: #343a40;
        color: #fff;
        padding: 8px 12px;
        text-align: left;
        font-weight: 600;
        white-space: nowrap;
    }
    tbody td {
        padding: 6px 12px;
        border-bottom: 1px solid #e9ecef;
        vertical-align: top;
    }
    tbody tr:nth-child(even) { background: #f8f9fa; }
    tbody tr:hover { background: #e9ecef; }
    tr.mismatch, tr.mismatch td { background: #f8d7da !important; }
    .mono {
        font-family: 'Consolas', 'Courier New', monospace;
        font-size: 12px;
    }
    .table-scroll {
        max-height: 400px;
        overflow-y: auto;
        overflow-x: auto;
        border: 1px solid #dee2e6;
        border-radius: 4px;
        margin-top: 8px;
    }
    .table-scroll table { margin: 0; }
    .summary-grid {
        display: grid;
        grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
        gap: 16px;
        margin-bottom: 16px;
    }
    .summary-card {
        background: #f8f9fa;
        border: 1px solid #dee2e6;
        border-radius: 6px;
        padding: 16px;
        text-align: center;
    }
    .summary-card .label {
        font-size: 12px;
        color: #6c757d;
        text-transform: uppercase;
        letter-spacing: 0.5px;
    }
    .summary-card .value {
        font-size: 28px;
        font-weight: 700;
        color: #1a1a2e;
        margin: 4px 0;
    }
    .config-block {
        background: #f8f9fa;
        border: 1px solid #dee2e6;
        border-radius: 4px;
        padding: 16px;
        overflow-x: auto;
    }
    .config-block pre {
        margin: 0;
        font-family: 'Consolas', 'Courier New', monospace;
        font-size: 12px;
        white-space: pre-wrap;
        word-break: break-all;
    }
    .gaps-list {
        list-style: none;
        padding: 0;
    }
    .gaps-list li {
        padding: 8px 12px;
        border-left: 3px solid #ffc107;
        background: #fff8e1;
        margin-bottom: 6px;
        border-radius: 0 4px 4px 0;
    }
    .gaps-list li strong { color: #856404; }
    .footer {
        text-align: center;
        padding: 16px;
        font-size: 12px;
        color: #6c757d;
    }
    @media print {
        body { background: #fff; }
        .container { padding: 0; max-width: 100%; }
        .header { border-radius: 0; }
        .content { border: none; border-radius: 0; }
        .table-scroll {
            max-height: none;
            overflow: visible;
        }
        section { page-break-inside: avoid; }
    }
</style>
</head>
<body>
<div class="container">
    <div class="header">
        <h1>TFVC to GitHub Migration &mdash; Audit Report</h1>
        <div style="margin-bottom: 16px;">$overallBadge</div>
        <div class="header-meta">
            <span><strong>Date:</strong> $(ConvertTo-HtmlSafe $summary.verificationDate)</span>
            <span><strong>Source:</strong> $(ConvertTo-HtmlSafe $sourceServer)</span>
            <span><strong>Target:</strong> $(ConvertTo-HtmlSafe $config.gitRemoteUrl)</span>
        </div>
    </div>
    <div class="content">

        <!-- Section 1: Executive Summary -->
        <section>
            <h2>1. Executive Summary</h2>
            <div class="summary-grid">
                <div class="summary-card">
                    <div class="label">Changesets Migrated</div>
                    <div class="value">$($summary.changesetCoverage.totalExportedChangesets)</div>
                </div>
                <div class="summary-card">
                    <div class="label">Files Verified</div>
                    <div class="value">$($summary.hashCheck.totalCompared)</div>
                </div>
                <div class="summary-card">
                    <div class="label">Overall Result</div>
                    <div class="value" style="color: $(if ($summary.overallResult -eq 'PASS') { '#28a745' } else { '#dc3545' })">$($summary.overallResult)</div>
                </div>
            </div>
            <table>
                <tbody>
                    <tr><td><strong>Source Server</strong></td><td class="mono">$(ConvertTo-HtmlSafe $sourceServer)</td></tr>
                    <tr><td><strong>Target Repository</strong></td><td class="mono">$(ConvertTo-HtmlSafe $config.gitRemoteUrl)</td></tr>
                    <tr><td><strong>Migration Duration</strong></td><td>$(ConvertTo-HtmlSafe $migrationDuration)</td></tr>
                    <tr><td><strong>Inventory Check</strong></td><td>$invBadge</td></tr>
                    <tr><td><strong>File Integrity</strong></td><td>$hashBadge</td></tr>
                    <tr><td><strong>Changeset Coverage</strong></td><td>$csBadge</td></tr>
                </tbody>
            </table>
        </section>

        <!-- Section 2: File Inventory -->
        <section>
            <h2>2. File Inventory $invBadge</h2>
            <table style="max-width: 500px;">
                <tbody>
                    <tr><td><strong>Total TFVC Files</strong></td><td>$($summary.inventoryCheck.totalTfvcFiles)</td></tr>
                    <tr><td><strong>Total Git Files</strong></td><td>$($summary.inventoryCheck.totalGitFiles)</td></tr>
                    <tr><td><strong>Matched</strong></td><td>$($summary.inventoryCheck.matchCount)</td></tr>
                    <tr><td><strong>Only in TFVC</strong></td><td>$($summary.inventoryCheck.onlyInTfvc.Count)</td></tr>
                    <tr><td><strong>Only in Git</strong></td><td>$($summary.inventoryCheck.onlyInGit.Count)</td></tr>
                </tbody>
            </table>
            $invDiscrepancySection
        </section>

        <!-- Section 3: File Integrity -->
        <section>
            <h2>3. File Integrity $hashBadge</h2>
            <p><strong>$($summary.hashCheck.totalCompared)</strong> files compared &mdash;
               <strong>$($summary.hashCheck.matched)</strong> matched,
               <strong>$($summary.hashCheck.mismatched)</strong> mismatched.</p>
            <div class="table-scroll">
                <table>
                    <thead><tr><th>Path</th><th>TFVC SHA-256</th><th>Git SHA-256</th><th>Match</th></tr></thead>
                    <tbody>$hashTableRows</tbody>
                </table>
            </div>
        </section>

        <!-- Section 4: Changeset Coverage -->
        <section>
            <h2>4. Changeset Coverage $csBadge</h2>
            <p><strong>$($summary.changesetCoverage.totalExportedChangesets)</strong> changesets mapped to
               <strong>$($summary.changesetCoverage.totalMappedCommits)</strong> Git commits.</p>
            <div class="table-scroll">
                <table>
                    <thead><tr><th>Changeset</th><th>Commit</th><th>Author</th><th>Date</th><th>Comment</th></tr></thead>
                    <tbody>$csTableRows</tbody>
                </table>
            </div>
        </section>

        <!-- Section 5: Known Gaps -->
        <section>
            <h2>5. Known Gaps</h2>
            <p>The following TFVC concepts are <strong>not</strong> migrated and are outside the scope of this tool:</p>
            <ul class="gaps-list">
                <li><strong>Shelvesets</strong> &mdash; Pending changes stored on the server are not migrated.</li>
                <li><strong>Labels</strong> &mdash; TFVC labels are not converted to Git tags.</li>
                <li><strong>Check-in Policies</strong> &mdash; Server-side policies are not transferable to Git.</li>
                <li><strong>Code Review Associations</strong> &mdash; TFVC code review metadata is not preserved.</li>
                <li><strong>Branch Merge History</strong> &mdash; When migrating subfolders, cross-branch merge relationships are not reconstructed in Git.</li>
            </ul>
        </section>

        <!-- Section 6: Configuration -->
        <section>
            <h2>6. Configuration</h2>
            <h3>Source Mappings</h3>
            <table style="max-width: 700px;">
                <thead><tr><th>TFVC Path</th><th>Destination Path</th></tr></thead>
                <tbody>$sourceMappingRows</tbody>
            </table>
            <h3>Full Configuration (sanitized)</h3>
            <div class="config-block"><pre>$configJson</pre></div>
        </section>

    </div>
    <div class="footer">
        Generated by TFVC Migration Tool &bull; $(ConvertTo-HtmlSafe $now)
    </div>
</div>
</body>
</html>
"@

    $html | Set-Content $reportPath -Encoding UTF8
    Write-Host "Audit report generated: $reportPath"
}
catch {
    Write-Error "Report generation failed: $_"
    throw
}
