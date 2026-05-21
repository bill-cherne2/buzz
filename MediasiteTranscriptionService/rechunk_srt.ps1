Param(
  [Parameter(Mandatory=$true)][string]$InPath,
  [Parameter(Mandatory=$true)][string]$OutPath,
  [int]$MaxChars = 80,
  [double]$MaxSeconds = 4.0,
  [int]$MaxWords = 12,
  [double]$MinDuration = 0.4,
  [int]$PauseMs = 300,
  [bool]$PreferPunctuation = $true,
  [int]$MaxLineWidth = $null,
  [int]$MaxLineCount = $null
)

function Write-Usage {
  Write-Host "Usage: ./rechunk_srt.ps1 -InPath in.srt -OutPath out.srt [-MaxChars 80] [-MaxSeconds 4.0] [-MaxWords 12] [-MinDuration 0.4] [-PauseMs 300] [-PreferPunctuation $true]"
}

if (-not (Test-Path $InPath)) {
  Write-Error "Input SRT not found: $InPath"
  exit 2
}

$raw = Get-Content -Raw -Path $InPath -ErrorAction Stop
$blocks = $raw -split "\r?\n\r?\n"
$items = @()
foreach ($b in $blocks) {
  $lines = $b -split "\r?\n"
  if ($lines.Count -lt 2) { continue }
  $timeLine = $null
  foreach ($ln in $lines) { if ($ln -match '-->') { $timeLine = $ln; break } }
  if (-not $timeLine) { continue }
  $m = [Regex]::Match($timeLine, "(?<start>\d{2}:\d{2}:\d{2}[\.,]\d{3})\s*-->\s*(?<end>\d{2}:\d{2}:\d{2}[\.,]\d{3})")
  if (-not $m.Success) { continue }
  $start = $m.Groups['start'].Value
  $end = $m.Groups['end'].Value
  $idx = [Array]::IndexOf($lines, $timeLine)
  $text = ""
  if ($idx -lt ($lines.Count - 1)) { $text = ($lines[$idx+1..($lines.Count-1)] -join ' ').Trim() }
  $wCount = 0
  if ($text -ne '') { $wCount = ($text -split '\s+' | Where-Object { $_ -ne '' }).Count }
  $items += [PSCustomObject]@{ Start=$start; End=$end; Text=$text; StartMs = (ts_ms $start); EndMs = (ts_ms $end); WordCount=$wCount; DurationMs=((ts_ms $end) - (ts_ms $start)) }
}

# helper: parse timestamp to ms (local function)
function ts_ms($t) {
  $t = $t -replace ',', '.'
  $parts = $t -split ':'
  $hr = [int]$parts[0]; $mn=[int]$parts[1]; $secf=[double]$parts[2]
  return [int](($hr*3600 + $mn*60 + $secf) * 1000)
}

# Build parsed array with numeric fields
$parsed = @()
foreach ($it in $items) {
  $parsed += [PSCustomObject]@{ Start=$it.Start; End=$it.End; StartMs=$it.StartMs; EndMs=$it.EndMs; Text=$it.Text; WordCount=$it.WordCount; DurationMs=$it.DurationMs }
}

$merged = @()
$cur = $null
foreach ($it in $parsed) {
  if ($null -eq $cur) { $cur = $it.PSObject.Copy(); continue }

  $curEndsSentence = $false
  if ($PreferPunctuation) { $curEndsSentence = ($cur.Text -match '[\.\!\?]$') }
  if ($curEndsSentence) { $merged += $cur; $cur = $it.PSObject.Copy(); continue }

  $gapMs = $it.StartMs - $cur.EndMs
  if ($gapMs -gt $PauseMs) { $merged += $cur; $cur = $it.PSObject.Copy(); continue }

  $newText = ("{0} {1}" -f $cur.Text.Trim(), $it.Text.Trim()).Trim()
  $newWordCount = $cur.WordCount + $it.WordCount
  $newDurationMs = $it.EndMs - $cur.StartMs

  $canMergeByLimits = ($newText.Length -le $MaxChars) -and (($newDurationMs/1000.0) -le $MaxSeconds) -and ($newWordCount -le $MaxWords)

  if ($canMergeByLimits) {
    $cur.End = $it.End
    $cur.EndMs = $it.EndMs
    $cur.Text = $newText
    $cur.WordCount = $newWordCount
    $cur.DurationMs = $newDurationMs
    continue
  }

  if (($cur.DurationMs/1000.0) -lt $MinDuration) {
    if ($newText.Length -le ($MaxChars * 1.5) -and (($newDurationMs/1000.0) -le ($MaxSeconds * 1.5)) -and ($newWordCount -le ($MaxWords * 2))) {
      $cur.End = $it.End
      $cur.EndMs = $it.EndMs
      $cur.Text = $newText
      $cur.WordCount = $newWordCount
      $cur.DurationMs = $newDurationMs
      continue
    }
  }

  $merged += $cur
  $cur = $it.PSObject.Copy()
}
if ($cur -ne $null) { $merged += $cur }

# write out
$sb = New-Object System.Text.StringBuilder
$i = 1
foreach ($m in $merged) {
  $null = $sb.AppendLine($i.ToString())
  $null = $sb.AppendLine("$($m.Start) --> $($m.End)")
  $null = $sb.AppendLine($m.Text)
  $null = $sb.AppendLine("")
  $i++
}
# If MaxLineWidth/MaxLineCount provided, derive MaxChars/MaxWords heuristically
if ($MaxLineWidth -ne $null -and $MaxLineCount -ne $null) {
  $avgWordLen = 5
  $computedMaxChars = $MaxLineWidth * $MaxLineCount
  $wordsPerLine = [int]([math]::Floor($MaxLineWidth / $avgWordLen))
  if ($wordsPerLine -lt 1) { $wordsPerLine = 1 }
  $computedMaxWords = $MaxLineCount * $wordsPerLine
  $MaxChars = $computedMaxChars
  $MaxWords = $computedMaxWords
} elseif ($MaxLineWidth -ne $null) {
  # assume 2 lines if only width provided
  $MaxChars = $MaxLineWidth * 2
} elseif ($MaxLineCount -ne $null) {
  # assume 12 words per line heuristic
  $MaxWords = $MaxLineCount * 12
}

[System.IO.File]::WriteAllText($OutPath, $sb.ToString(), [System.Text.Encoding]::UTF8)
Write-Host "Wrote $OutPath ($($items.Count) -> $($merged.Count) cues)"
