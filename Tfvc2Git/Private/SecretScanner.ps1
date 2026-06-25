function Invoke-SecretScanAndClean {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Patterns,
        [Parameter(Mandatory)][string]$ReplacementToken
    )

    if (-not (Test-Path -LiteralPath $FilePath)) { return $false }

    # Basic binary check by extension (can be expanded)
    $ext = [System.IO.Path]::GetExtension($FilePath).ToLower()
    $binaryExts = @('.dll', '.exe', '.zip', '.nupkg', '.pdb', '.png', '.jpg', '.jpeg', '.gif', '.pdf')
    if ($ext -in $binaryExts) { return $false }

    try {
        # Read raw content. We don't want to corrupt encoding if possible, but
        # simple UTF8 is usually safe for code.
        $content = [System.IO.File]::ReadAllText($FilePath, [System.Text.Encoding]::UTF8)
        $modified = $false

        foreach ($pattern in $Patterns) {
            # Replace using regex match evaluator to only replace the captured group if we want,
            # but the regexes provided capture the whole secret value.
            # Actually, to be safe, if the pattern contains a capture group for the secret,
            # we should only replace the captured group.
            # E.g. Password=([^\s]+)
            # If we just do $content -replace $pattern, $ReplacementToken it replaces the whole string 'Password=foo' -> '***REMOVED***'
            # which might break syntax.
            # Let's use Regex.Replace with a MatchEvaluator.

            $regex = [System.Text.RegularExpressions.Regex]::new($pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Compiled)
            
            if ($regex.IsMatch($content)) {
                $content = $regex.Replace($content, {
                    param($match)
                    if ($match.Groups.Count -gt 1) {
                        # If there is a capture group, we want to keep everything else and only replace the group.
                        # This is slightly complex in PowerShell Regex.Replace.
                        # Let's just replace the captured group's value within the full match.
                        $fullMatch = $match.Value
                        $secretValue = $match.Groups[1].Value
                        return $fullMatch.Replace($secretValue, $ReplacementToken)
                    } else {
                        # No capture group, replace the whole match
                        return $ReplacementToken
                    }
                })
                $modified = $true
            }
        }

        if ($modified) {
            # No BOM - this content gets committed to git; a BOM would alter bytes
            # beyond the redaction. (Self-contained so it works if dot-sourced.)
            [System.IO.File]::WriteAllText($FilePath, $content, (New-Object System.Text.UTF8Encoding($false)))
            return $true
        }
    }
    catch {
        # Ignore files we can't read as text
    }

    return $false
}
