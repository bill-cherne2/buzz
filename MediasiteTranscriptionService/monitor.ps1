Param(
  [string]$ConfigPath = ""
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$DefaultConfigPath = Join-Path $ScriptDir 'monitor_config.json'
if ($ConfigPath -eq "") { $ConfigPath = $DefaultConfigPath }

# Load config (if present)
$config = @{}
if (Test-Path $ConfigPath) {
  try { $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json } catch { $config = @{} }
}

# Defaults and precedence (env > config > built-in)
$myDocs = [Environment]::GetFolderPath('MyDocuments')
$monitorDir = if ($env:MONITOR_DIR) { $env:MONITOR_DIR } elseif ($config.MonitorDir) { [Environment]::ExpandEnvironmentVariables($config.MonitorDir) } else { Join-Path $myDocs 'Recorded Presentations' }
$buzzExe = if ($env:BUZZ_EXE_PATH) { $env:BUZZ_EXE_PATH } elseif ($config.BuzzExePath) { $config.BuzzExePath } else { 'C:\Program Files (x86)\Buzz\Buzz.exe' }
$poll = if ($config.PollIntervalSeconds) { [int]$config.PollIntervalSeconds } else { 20 }
$processedFile = if ($config.ProcessedFile) { $config.ProcessedFile } else { Join-Path $ScriptDir 'processed.json' }
$modelArgs = if ($config.ModelArgs) { $config.ModelArgs } else { '--model-type fasterwhisper --model-size tiny.en' }
$prompt = if ($config.Prompt) { $config.Prompt } else { '' }
$escapedPrompt = $null
if ($prompt -ne '') { $escapedPrompt = $prompt -replace '"','\"' }
$wordTimestamps = if ($null -ne $config.WordTimestamps) { [bool]$config.WordTimestamps } else { $true }
$maxCharsPerCue = if ($null -ne $config.MaxCharsPerCue) { [int]$config.MaxCharsPerCue } else { 80 }
$maxSecondsPerCue = if ($null -ne $config.MaxSecondsPerCue) { [double]$config.MaxSecondsPerCue } else { 4.0 }
$retryCount = if ($config.RetryCount) { [int]$config.RetryCount } else { 1 }
$timeoutSeconds = if ($config.TimeoutSeconds) { [int]$config.TimeoutSeconds } else { 3600 }
$maxWordsPerCue = if ($null -ne $config.MaxWordsPerCue) { [int]$config.MaxWordsPerCue } else { 12 }
$minDurationSeconds = if ($null -ne $config.MinDurationSeconds) { [double]$config.MinDurationSeconds } else { 0.4 }
$pauseThresholdMs = if ($null -ne $config.PauseThresholdMs) { [int]$config.PauseThresholdMs } else { 300 }
$preferPunctuation = if ($null -ne $config.PreferPunctuation) { [bool]$config.PreferPunctuation } else { $true }
$reprocessIfMissingSrt = if ($null -ne $config.ReprocessIfMissingSrt) { [bool]$config.ReprocessIfMissingSrt } else { $true }
# Optional mapping for whisper-like CLI line options
$maxLineWidth = if ($null -ne $config.MaxLineWidth) { [int]$config.MaxLineWidth } else { $null }
$maxLineCount = if ($null -ne $config.MaxLineCount) { [int]$config.MaxLineCount } else { $null }

# Load processed map (store as a hashtable so ContainsKey/indexing works)
$processed = @{}
if (Test-Path $processedFile) {
  try {
    $tmp = Get-Content $processedFile -Raw | ConvertFrom-Json
    if ($tmp -ne $null) {
      foreach ($prop in $tmp.PSObject.Properties) {
        $processed[$prop.Name] = $prop.Value
      }
    }
  } catch {
    $processed = @{}
  }
}
if (-not $processed) { $processed = @{} }

 

function Save-Processed {
  $processed | ConvertTo-Json | Set-Content -Path $processedFile
}

function Log($msg) {
  $ts = (Get-Date).ToString('s')
  $line = "$ts`t$msg"
  Write-Output $line
  Add-Content -Path (Join-Path $ScriptDir 'monitor.log') -Value $line
}

Log "Run starting. MonitorDir=$monitorDir, BuzzExe=$buzzExe"

if (-not (Test-Path $monitorDir)) {
  Log "MonitorDir not found: $monitorDir"
  exit 0
}

$folders = Get-ChildItem -Path $monitorDir -Directory -ErrorAction SilentlyContinue
foreach ($folder in $folders) {
  $fname = $folder.Name

  $expectedSrt = ($fname + '.srt').ToLower()
  $srtExists = Get-ChildItem -Path $folder.FullName -File -Filter '*.srt' -ErrorAction SilentlyContinue |
              Where-Object { $_.Name.ToLower() -eq $expectedSrt }

  if ($srtExists) {
    if (-not $processed.ContainsKey($fname)) {
      Log "SRT exists for $fname; marking processed."
      $processed[$fname] = @{ processedAt = (Get-Date).ToString(); source = 'srt' }
      Save-Processed
    }
    continue
  } else {
    if ($processed.ContainsKey($fname)) {
      if ($reprocessIfMissingSrt) {
        Log "Previously processed $fname but SRT missing; removing from processed map to allow reprocessing."
        $null = $processed.Remove($fname)
        Save-Processed
      } else {
        Log "Previously processed $fname and ReprocessIfMissingSrt is false; skipping."
        continue
      }
    }
  }

  # Prefer a file that exactly matches the folder name in this order: .f.mp4, .isma, .ism, .mp4
  $matchingFile = $null

  # 1) Check for ABC123.f.mp4
  $specialName = ($fname + '.f.mp4').ToLower()
  $found = Get-ChildItem -Path $folder.FullName -File -ErrorAction SilentlyContinue |
           Where-Object { $_.Name.ToLower() -eq $specialName } | Select-Object -First 1
  if ($found) { $matchingFile = $found }

  # 2) Fallback to .isma, .ism, .mp4
  if (-not $matchingFile) {
    $extensions = @('.isma', '.ism', '.mp4')
    foreach ($ext in $extensions) {
      $expectedName = ($fname + $ext).ToLower()
      $found = Get-ChildItem -Path $folder.FullName -File -Filter "*$ext" -ErrorAction SilentlyContinue |
               Where-Object { $_.Name.ToLower() -eq $expectedName } | Select-Object -First 1
      if ($found) { $matchingFile = $found; break }
    }
  }

  if ($matchingFile) {
    $mp4Path = $matchingFile.FullName
    Log "Found matching media for folder $($fname): $($mp4Path)"

    # Ensure file size > 0 bytes before sending for transcription
    try {
      $fi = Get-Item -LiteralPath $mp4Path -ErrorAction Stop
      $size = $fi.Length
    } catch {
      Log "Failed to stat file $($mp4Path): $($_)"
      continue
    }

    $kb = 1024
    $mb = 1024 * $kb
    if ($size -ge $mb) { $hr = "{0:N2} MB" -f ($size / $mb) }
    elseif ($size -ge $kb) { $hr = "{0:N2} KB" -f ($size / $kb) }
    else { $hr = "{0} bytes" -f $size }

    Log "File size: $hr"

    if ($size -le 0) {
      # Don't mark zero-length files as processed — these may be in-progress recordings
      Log "Found zero-length file (likely still recording) $($mp4Path) for folder $($fname); will retry later."
      continue
    }
  } else {
    $xmlPath = Join-Path $folder.FullName 'RecordedPresentation_70.xml'
    if (-not (Test-Path $xmlPath)) {
      Log "XML not found in $($fname): $($xmlPath)"
      continue
    }

    try { [xml]$x = Get-Content $xmlPath -ErrorAction Stop } catch { Log "Failed to load XML for $($fname): $($_)"; continue }

    # Try to find Video1 node
    $videoNode = $x.SelectSingleNode('//Video1')
    if (-not $videoNode) { $videoNode = $x.SelectSingleNode('//Video') }
    if (-not $videoNode) { Log "Video1 node not found in XML for $($fname)"; continue }

    $mp4Rel = $videoNode.InnerText.Trim()
    if (-not $mp4Rel) { Log "Video1 node empty for $($fname)"; continue }

    $mp4Path = $mp4Rel
    if (-not [System.IO.Path]::IsPathRooted($mp4Path)) { $mp4Path = Join-Path $folder.FullName $mp4Path }
    if (-not (Test-Path $mp4Path)) { Log "MP4 not found at resolved path: $($mp4Path)"; continue }
  }

  # Add --word-timestamps if requested so the transcriber emits word-level timing
  $extraArgs = ""
  if ($wordTimestamps) { $extraArgs = "$extraArgs --word-timestamps" }
  if ($escapedPrompt -ne $null -and $escapedPrompt -ne '') { $extraArgs = "$extraArgs --prompt `"$escapedPrompt`"" }
  $argList = "add --task transcribe --hide-gui --srt $modelArgs $extraArgs -- `"$mp4Path`""
  Log "Starting Buzz for $fname -> $mp4Path"
  try {
    $outLogFile = Join-Path $ScriptDir ("{0}_buzz.out.log" -f $fname)
    $errLogFile = Join-Path $ScriptDir ("{0}_buzz.err.log" -f $fname)

    # Capture existing SRT files so we can detect any newly-created SRT
    $existingSrtFiles = @()
    try { $existingSrtFiles = Get-ChildItem -Path $folder.FullName -File -Filter '*.srt' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName } catch {}

    $proc = Start-Process -FilePath $buzzExe -ArgumentList $argList -PassThru -WindowStyle Hidden -RedirectStandardOutput $outLogFile -RedirectStandardError $errLogFile
  } catch {
    Log "Failed to start Buzz: $($_)"
    continue
  }

  # Monitor Buzz logs for download/progress output and show a spinner/percent in console
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $spinner = @('|','/','-','\')
  $spinIndex = 0
  $lastOutSize = 0
  $lastErrSize = 0
  $percentShown = $null

  while (-not $proc.HasExited -and $sw.Elapsed.TotalSeconds -lt $timeoutSeconds) {
    Start-Sleep -Milliseconds 500

    # Read appended output and error
    $outText = ''
    $errText = ''
    if (Test-Path $outLogFile) {
      try { $outText = Get-Content -Raw -Path $outLogFile -ErrorAction SilentlyContinue } catch {}
    }
    if (Test-Path $errLogFile) {
      try { $errText = Get-Content -Raw -Path $errLogFile -ErrorAction SilentlyContinue } catch {}
    }

    $combined = "$outText`n$errText"

    # Detect download messages
        $isDownloading = ($combined -match "download" -or $combined -match "Downloading" -or $combined -match "Downloading model")

        # Try to parse percentage (e.g. '45%' or '45 %')
        $m = [Regex]::Match($combined, "(\d{1,3})\s?%")
        if ($m.Success) {
          $p = [int]$m.Groups[1].Value
          if ($percentShown -ne $p) {
            Write-Progress -Activity "Buzz: $fname" -Status "Transcribing" -PercentComplete $p -Id 1
            $percentShown = $p
          }
        } else {
          if ($isDownloading) {
            Write-Progress -Activity "Buzz: $fname" -Status "Downloading model..." -PercentComplete 0 -Id 1
          } else {
            # Spinner fallback implemented as incremental pseudo-percent for display
            $pseudo = ($spinIndex * 10) % 100
            Write-Progress -Activity "Buzz: $fname" -Status "Processing" -PercentComplete $pseudo -Id 1
            $spinIndex++
          }
        }
  }

  if (-not $proc.HasExited) {
    try { $proc.Kill() } catch {}
    Log "Buzz timed out for $fname"
    continue
  }

  # Ensure process fully exited and exit code is available
  try { $proc.WaitForExit() } catch {}
  Start-Sleep -Milliseconds 200

  $exitCode = $null
  try { $exitCode = $proc.ExitCode } catch {}
  if ($null -eq $exitCode -or $exitCode -ne 0) {
    Log "Buzz exited with code '$exitCode' for $fname (ProcessId=$($proc.Id))"
    # Dump complete stdout/stderr to monitor.log and console for diagnosis
    if (Test-Path $outLogFile) {
      $outAll = Get-Content -Raw -Path $outLogFile -ErrorAction SilentlyContinue
      Add-Content -Path (Join-Path $ScriptDir 'monitor.log') -Value "--- Buzz stdout (full) for $fname ---"
      if ($outAll) { Add-Content -Path (Join-Path $ScriptDir 'monitor.log') -Value $outAll }
      Write-Host "[Buzz stdout]"
      if ($outAll) { Write-Host $outAll } else { Write-Host "<no stdout content>" }
    }
    if (Test-Path $errLogFile) {
      $errAll = Get-Content -Raw -Path $errLogFile -ErrorAction SilentlyContinue
      Add-Content -Path (Join-Path $ScriptDir 'monitor.log') -Value "--- Buzz stderr (full) for $fname ---"
      if ($errAll) { Add-Content -Path (Join-Path $ScriptDir 'monitor.log') -Value $errAll }
      Write-Host "[Buzz stderr]"
      if ($errAll) { Write-Host $errAll } else { Write-Host "<no stderr content>" }
    }
    Write-Progress -Id 1 -Activity "Buzz: $fname" -Completed
    # NOTE: Some Buzz runs produce output files even when the parent process exit code is empty/non-zero
    # Continue on to SRT discovery/rename so we can capture and rename any produced SRT.
    Add-Content -Path (Join-Path $ScriptDir 'monitor.log') -Value "Proceeding to SRT discovery despite exit code '$exitCode' for $fname"
    # Do NOT 'continue' here; attempt to find/rename SRT below.
  }

  # After process exit, check for newly-created SRT files (prefer the newest)
  try {
    $allSrts = Get-ChildItem -Path $folder.FullName -File -Filter '*.srt' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
    $newSrts = $allSrts | Where-Object { $existingSrtFiles -notcontains $_.FullName }
    if (-not $newSrts -or $newSrts.Count -eq 0) {
      # If no newly-created SRT found, fall back to any SRT named after the folder
      $newSrts = $allSrts | Where-Object { $_.Name.ToLower() -eq $expectedSrt }
    }

    if ($newSrts -and $newSrts.Count -gt 0) {
      $created = $newSrts[0]
        # Diagnostic: log what SRTs we see
        Add-Content -Path (Join-Path $ScriptDir 'monitor.log') -Value "--- SRT discovery for $fname ---"
        Add-Content -Path (Join-Path $ScriptDir 'monitor.log') -Value ("All SRTs: {0}" -f ($allSrts | ForEach-Object { $_.Name } | Out-String))
        Add-Content -Path (Join-Path $ScriptDir 'monitor.log') -Value ("New SRTs: {0}" -f ($newSrts | ForEach-Object { $_.Name } | Out-String))
      # Determine desired output name: prefer matching media base name (e.g., 'ABC.f') else folder name
      if ($matchingFile) {
        $desiredBase = $matchingFile.BaseName
        # If the matching media used the special '.f' marker (e.g. 'ABC.f.mp4'), strip the trailing '.f' so output becomes 'ABC.srt'
        if ($desiredBase -match '\.f$') { $desiredBase = $desiredBase -replace '\.f$','' }
      } else { $desiredBase = $fname }
      $desiredName = "$desiredBase.srt"
      $desiredPath = Join-Path $folder.FullName $desiredName
      if ($created.FullName -ne $desiredPath) {
        $moved = $false
        for ($i=0; $i -lt 3; $i++) {
          try {
            Move-Item -LiteralPath $created.FullName -Destination $desiredPath -Force
            Log "Renamed SRT '$($created.Name)' -> '$desiredName' for $fname"
            $moved = $true
            break
          } catch {
            Log "Attempt $($i+1): Failed to rename SRT '$($created.Name)' -> '$desiredName': $($_)"
            Start-Sleep -Milliseconds 200
          }
        }
        if (-not $moved) {
          # Fallback: try copy then remove
          try {
            Copy-Item -LiteralPath $created.FullName -Destination $desiredPath -Force
            Remove-Item -LiteralPath $created.FullName -Force
            Log "Copied then removed SRT '$($created.Name)' -> '$desiredName' for $fname"
            $moved = $true
          } catch {
            Log "Final fallback failed to move SRT '$($created.Name)' -> '$desiredName': $($_)"
          }
        }
        if (-not $moved) {
          Log "SRT left as '$($created.Name)' for $fname"
        }
      } else {
        Log "SRT created for $($fname): $($created.Name)"
      }

        # Post-process SRT: always attempt to group short per-word cues into readable cues
        try {
          # Determine actual SRT path (handle rename/copy fallback where desiredPath might not exist)
          $actualSrt = $null
          if (Test-Path $desiredPath) { $actualSrt = $desiredPath }
          elseif (Test-Path $created.FullName) { $actualSrt = $created.FullName }
          if ($actualSrt) {
            $rechunkScript = Join-Path $ScriptDir 'rechunk_srt.ps1'
            if (Test-Path $rechunkScript) {
              try {
                & $rechunkScript -InPath $actualSrt -OutPath $actualSrt -MaxChars $maxCharsPerCue -MaxSeconds $maxSecondsPerCue -MaxWords $maxWordsPerCue -MinDuration $minDurationSeconds -PauseMs $pauseThresholdMs -PreferPunctuation:$preferPunctuation -MaxLineWidth $maxLineWidth -MaxLineCount $maxLineCount
                Log "Post-processed SRT grouping applied to $(Split-Path $actualSrt -Leaf) via rechunk_srt.ps1"
              } catch {
                Log ("Failed to post-process SRT via external script {0}: {1}" -f $rechunkScript, $_)
              }
            } else {
              Log "rechunk_srt.ps1 not found in $ScriptDir; skipping post-process for $fname"
            }
            # If we processed a file that wasn't at desiredPath, move it into place now
            if ($actualSrt -ne $desiredPath) {
              try {
                Move-Item -LiteralPath $actualSrt -Destination $desiredPath -Force
                Log "Moved post-processed SRT '$(Split-Path $actualSrt -Leaf)' -> '$desiredName' for $fname"
              } catch {
                Log ("Failed to move post-processed SRT {0} -> {1}: {2}" -f $actualSrt, $desiredPath, $_)
              }
            }
          } else {
            Log "No SRT file found to post-process for $fname"
          }
        } catch {
          Log ("Failed to post-process SRT {0}: {1}" -f $desiredName, $_)
        }

      Write-Host "Captions Generated for $fname"
      $processed[$fname] = @{ processedAt = (Get-Date).ToString(); source = 'buzz' }
      Save-Processed
    } else {
      Log "SRT not found after Buzz run for $fname"
    }
  } catch {
    Log "Error while locating/renaming SRT for $($fname): $($_)"
  }
  Write-Progress -Id 1 -Activity "Buzz: $fname" -Completed
}

Log "Run complete. Exiting single-shot script."

 
