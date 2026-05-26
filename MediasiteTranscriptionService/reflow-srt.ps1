<#
.SYNOPSIS
Reflow and split/merge SRT captions similar to srt-equalizer / buzz defaults.

.DESCRIPTION
Parses an SRT file, reflows cue text by max-chars/max-words, splits long cues
proportionally by word-count into smaller cues, and merges very short cues or
small gaps according to timing thresholds.

Target: Windows PowerShell 5.1 (no external dependencies).

.EXAMPLE
# Safe default - writes input.reflow.srt next to input
.\reflow-srt.ps1 -InputPath C:\temp\input.srt

.EXAMPLE
# Custom parameters
.\reflow-srt.ps1 -InputPath C:\in.srt -OutputPath C:\out.srt -MaxChars 80 -MaxWords 12 -MaxSeconds 4 -MinDuration 0.4 -PauseMs 300 -PreferPunct
#>

param(
    [Parameter(Mandatory=$true,Position=0)]
    [string]$InputPath,

    [Parameter(Mandatory=$false,Position=1)]
    [string]$OutputPath,

    [int]$MaxChars = 80,
    [int]$MaxWords = 12,
    [double]$MaxSeconds = 4.0,
    [double]$MinDuration = 0.4,
    [int]$PauseMs = 300,
    [switch]$PreferPunct,
    [switch]$Overwrite
)

# Allow overriding defaults via environment variables (matches BUZZ_SRT_* names used by buzz)
if ($env:BUZZ_SRT_MAX_CHARS) { $MaxChars = [int]$env:BUZZ_SRT_MAX_CHARS }
if ($env:BUZZ_SRT_MAX_WORDS) { $MaxWords = [int]$env:BUZZ_SRT_MAX_WORDS }
if ($env:BUZZ_SRT_MAX_SECONDS) { $MaxSeconds = [double]$env:BUZZ_SRT_MAX_SECONDS }
if ($env:BUZZ_SRT_MIN_DURATION) { $MinDuration = [double]$env:BUZZ_SRT_MIN_DURATION }
if ($env:BUZZ_SRT_PAUSE_MS) { $PauseMs = [int]$env:BUZZ_SRT_PAUSE_MS }
if ($env:BUZZ_SRT_PREFER_PUNCT) {
    $val = $env:BUZZ_SRT_PREFER_PUNCT.ToLower()
    if ($val -in @('1','true','yes','y')) { $PreferPunct = $true } else { $PreferPunct = $false }
}

# Print effective parameters when verbose
Write-Log "Effective settings: MaxChars=$MaxChars MaxWords=$MaxWords MaxSeconds=$MaxSeconds MinDuration=$MinDuration PauseMs=$PauseMs PreferPunct=$($PreferPunct.IsPresent)"

function Write-Log {
    param([string]$msg)
    # Use Write-Verbose so the script honors the common -Verbose switch
    Write-Verbose $msg
}

function Parse-TimecodeToSeconds($tc) {
    # tc example: 00:00:01,234
    if ($tc -match '(\d{2}):(\d{2}):(\d{2}),(\d{1,3})') {
        $h = [int]$matches[1]; $m = [int]$matches[2]; $s = [int]$matches[3]; $ms = [int]$matches[4]
        return ($h*3600 + $m*60 + $s + ($ms/1000.0))
    }
    throw "Invalid timecode: $tc"
}

function SecondsToTimecode($seconds) {
    if ($seconds -lt 0) { $seconds = 0 }
    $ts = [TimeSpan]::FromSeconds([double]$seconds)
    $h = [int]$ts.TotalHours
    $mm = $ts.Minutes.ToString("00")
    $ss = $ts.Seconds.ToString("00")
    $ms = [int]($ts.Milliseconds)
    return ("{0:00}:{1}:{2},{3:000}" -f $h, $mm, $ss, $ms)
}

function Read-SrtFile($path) {
    $raw = Get-Content -Raw -Encoding UTF8 -Path $path
    # Normalize line endings
    $raw = $raw -replace "\r\n", "\n"
    $blocks = $raw -split "\n\n"
    $cues = @()
    foreach ($b in $blocks) {
        $lines = $b -split "\n" | ForEach-Object { $_.TrimEnd() }
        if ($lines.Count -lt 2) { continue }
        # find timecode line
        $timeLine = $null; $indexLine = $null
        if ($lines[0] -match '-->') {
            $timeLine = $lines[0]
        } else {
            # first is index, second should be time
            if ($lines.Count -ge 2 -and $lines[1] -match '-->') { $indexLine = $lines[0]; $timeLine = $lines[1] }
            else { continue }
        }
        $times = $timeLine -split '-->' | ForEach-Object { $_.Trim() }
        if ($times.Count -ne 2) { continue }
        $start = Parse-TimecodeToSeconds $times[0]
        $end = Parse-TimecodeToSeconds $times[1]
        $textLines = @()
        $startLine = if ($indexLine) { 2 } else { 1 }
        for ($i = $startLine; $i -lt $lines.Count; $i++) {
            $textLines += $lines[$i]
        }
        $text = ($textLines -join " ") -replace '\s+', ' ';
        $cue = [pscustomobject]@{
            Start = $start; End = $end; Duration = ($end - $start); Text = $text; Words = @(); WordCount = 0
        }
        $cues += $cue
    }
    return $cues
}

function Tokenize-Words($text) {
    # Split on whitespace, keep punctuation attached. We return words as strings.
    if ([string]::IsNullOrWhiteSpace($text)) { return @() }
    $tokens = $text -split '\s+'
    return $tokens
}

function ReflowWordsIntoLines($words, $maxChars, $maxWords, $preferPunct) {
    $lines = @()
    $cur = @()
    foreach ($w in $words) {
        $curLen = ($cur -join ' ').Length
        $nextLen = if ($cur.Count -eq 0) { $w.Length } else { $curLen + 1 + $w.Length }
        if (($cur.Count -gt 0 -and $nextLen -gt $maxChars) -or ($cur.Count -ge $maxWords)) {
            $lines += ($cur -join ' ')
            $cur = @($w)
        } else {
            $cur += $w
        }
    }
    if ($cur.Count -gt 0) { $lines += ($cur -join ' ') }
    return $lines
}

function Split-CueByWords($cue, $maxWords) {
    $words = Tokenize-Words $cue.Text
    if ($words.Count -le $maxWords) { return @($cue) }
    $chunks = @()
    for ($i=0; $i -lt $words.Count; $i += $maxWords) {
        $slice = $words[$i..([math]::Min($i+$maxWords-1, $words.Count-1))]
        $obj = [pscustomobject]@{ Text = ($slice -join ' '); WordCount = $slice.Count }
        $chunks += $obj
    }
    # distribute times proportionally to word counts
    $totalWords = $words.Count
    $totalDuration = $cue.End - $cue.Start
    $pos = $cue.Start
    $out = @()
    foreach ($ch in $chunks) {
        $portion = $ch.WordCount / $totalWords
        $dur = [double]($totalDuration * $portion)
        if ($dur -lt $MinDuration) { $dur = $MinDuration }
        $start = $pos
        $end = $pos + $dur
        $pos = $end
        $out += [pscustomobject]@{ Start = $start; End = $end; Duration = ($end-$start); Text = $ch.Text }
    }
    # adjust last end to original end
    if ($out.Count -gt 0) { $out[-1].End = $cue.End; $out[-1].Duration = $cue.End - $out[-1].Start }
    return $out
}

function Merge-Cues($cues) {
    # Merge cues where duration < MinDuration or gap < PauseMs
    $out = @()
    for ($i=0; $i -lt $cues.Count; $i++) {
        $cur = $cues[$i]
        if ($out.Count -eq 0) { $out += $cur; continue }
        $prev = $out[-1]
        $gap = $cur.Start - $prev.End
        if ($prev.Duration -lt $MinDuration -or $gap -lt ($PauseMs/1000.0)) {
            # merge prev and cur
            $mergedText = ($prev.Text + ' ' + $cur.Text) -replace '\s+', ' '
            $merged = [pscustomobject]@{ Start = $prev.Start; End = $cur.End; Duration = ($cur.End - $prev.Start); Text = $mergedText }
            $out[-1] = $merged
        } else {
            $out += $cur
        }
    }
    return $out
}

function Normalize-And-Reflow($cues) {
    $expanded = @()
    foreach ($cue in $cues) {
        # split by words if too many words or too long in seconds
        $words = Tokenize-Words $cue.Text
        $cue | Add-Member -MemberType NoteProperty -Name Words -Value $words -Force
        $cue | Add-Member -MemberType NoteProperty -Name WordCount -Value $words.Count -Force
        if ($words.Count -gt $MaxWords -or $cue.Duration -gt $MaxSeconds) {
            $splits = Split-CueByWords $cue $MaxWords
            foreach ($s in $splits) { $expanded += $s }
        } else {
            $expanded += $cue
        }
    }
    Write-Log "After splitting: $($expanded.Count) cues"
    # Merge very short cues / small gaps
    $merged = Merge-Cues $expanded
    Write-Log "After merging: $($merged.Count) cues"
    # Reflow text lines per cue
    $final = @()
    foreach ($c in $merged) {
        $w = Tokenize-Words $c.Text
        $lines = ReflowWordsIntoLines $w $MaxChars $MaxWords $PreferPunct.IsPresent
        $c | Add-Member -MemberType NoteProperty -Name Lines -Value $lines -Force
        $final += $c
    }
    return $final
}

# Main
if (-not (Test-Path $InputPath)) { throw "Input file not found: $InputPath" }
if (-not $OutputPath) {
    $dir = Split-Path $InputPath -Parent
    $base = Split-Path $InputPath -LeafBase
    $OutputPath = Join-Path $dir ("$base.reflow.srt")
}
if ((Test-Path $OutputPath) -and -not $Overwrite) {
    # safe default: don't overwrite
    if ($OutputPath -eq $InputPath) { throw "Output equals input and Overwrite not specified" }
}

$cues = Read-SrtFile $InputPath
Write-Log "Read $($cues.Count) cues from $InputPath"
$normalized = Normalize-And-Reflow $cues

# final pass: ensure no line exceeds max chars (if any do because of very long words, allow them)
# write output
$outLines = @()
$idx = 1
foreach ($c in $normalized) {
    $outLines += $idx.ToString()
    $outLines += ("{0} --> {1}" -f (SecondsToTimecode $c.Start), (SecondsToTimecode $c.End))
    foreach ($l in $c.Lines) { $outLines += $l }
    $outLines += ""
    $idx++
}

# Ensure ASCII/UTF8 output
$outLines | Out-File -FilePath $OutputPath -Encoding UTF8
Write-Host "Wrote $($normalized.Count) cues to $OutputPath"

# end
