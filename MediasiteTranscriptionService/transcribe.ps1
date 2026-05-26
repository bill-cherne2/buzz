<#
.SYNOPSIS
  Transcribe a single media file using the Buzz CLI and produce an SRT

.DESCRIPTION
  Wrapper around the Buzz CLI to transcribe one media file and place the
  resulting .srt file next to the source media. Configure default behaviour
  by editing the variables in the script header.

.USAGE
  .\transcribe.ps1 "C:\path\to\file.mp4"

#>

param(
    [Parameter(Mandatory=$false, Position=0, HelpMessage='Path to media file to transcribe')]
    [string]$SourceFile,

    [switch]$Help
)

function Show-Usage {
    Write-Host "Usage: .\transcribe.ps1 <filename>"
    Write-Host "Configurable variables are at the top of the script."
    Write-Host "Examples:"
    Write-Host "  powershell -ExecutionPolicy Bypass -File .\transcribe.ps1 'C:\path\to\file.mp4'"
}

if ($Help -or -not $SourceFile) {
    Show-Usage
    exit 0
}

# ----------------------
# User-configurable defaults
# ----------------------
# Model type: e.g. "whisper", "whisper.cpp", "faster_whisper"
$ModelType = 'whisper'
# Model size: tiny, small, base, medium, large
$ModelSize = 'small'
# Language: use 'auto' to let Buzz auto-detect, or e.g. 'en'
$Language = 'auto'
# Output type: currently only 'SRT' is supported in this wrapper
$OutputType = 'SRT'
# Hide GUI while processing
$HideGUI = true
# When true, invoke Buzz.exe with its working directory set to the install
# folder (where you ran the successful command). When true the script will
# NOT pass `--output-directory` or `--hide-gui` to match the working command.
$UseExeWorkingDirectory = $true
# Path to buzz CLI. If `buzz` is on PATH keep it as fallback. Set this to the
# full path of the Buzz executable so the script does not require Python.
# Update this value if your Buzz install lives elsewhere.
$BuzzPath = 'C:\Program Files (x86)\Buzz\Buzz.exe'
# ----------------------

try {
    $ResolvedSource = Resolve-Path -Path $SourceFile -ErrorAction Stop
    $SourcePath = $ResolvedSource.ProviderPath
} catch {
    Write-Error "Source file not found: $SourceFile"
    exit 2
}

if (-not (Test-Path -Path $SourcePath -PathType Leaf)) {
    Write-Error "Source is not a file: $SourcePath"
    exit 3
}

$SourceDir = Split-Path -Path $SourcePath -Parent
$BaseName = [System.IO.Path]::GetFileNameWithoutExtension($SourcePath)
$OutputPath = Join-Path -Path $SourceDir -ChildPath ($BaseName + '.srt')
# Defensive: ensure the output path ends with .srt (avoid accidental extension removal)
if (-not $OutputPath.ToLower().EndsWith('.srt')) {
    $OutputPath = $OutputPath + '.srt'
}

# Build argument list for buzz
$argsList = @('add', '--task', 'transcribe', '--model-type', $ModelType, '--model-size', $ModelSize)



# Always request SRT
$argsList += '--srt'

# Do not pass --output-directory; Buzz defaults to writing outputs next to the
# source file when no output directory is provided.

# Only include hide-gui if explicitly requested and we are NOT using the
# exe working directory. Your successful command did not pass --hide-gui.
if ($HideGUI -and -not $UseExeWorkingDirectory) {
    $argsList += '--hide-gui'
}

if ($Language -and $Language.ToLower() -ne 'auto') {
    $argsList += '--language'
    $argsList += $Language
}

# Append the source path as final argument
$argsList += $SourcePath

# Decide how to invoke Buzz. Prefer explicit executable path set in $BuzzPath.
if (Test-Path $BuzzPath -PathType Leaf) {
    $Exec = $BuzzPath
    $ExecArgs = @()
    Write-Host "Using Buzz executable: $Exec"
} else {
    # Fallback: check for 'buzz' on PATH
    $cmd = Get-Command buzz -ErrorAction SilentlyContinue
    if ($cmd) {
        $Exec = $cmd.Source
        $ExecArgs = @()
        Write-Host "Using Buzz executable from PATH: $Exec"
    } else {
        Write-Error "Buzz executable not found at '$BuzzPath' and 'buzz' is not on PATH. Edit the script to set the correct path."
        exit 7
    }
}

# Determine working directory for the executable (install directory)
$ExecWorkingDir = Split-Path -Path $Exec -Parent

# Build a safe argument array and a quoted display string for logging
function QuoteArg($a) {
    if ($a -match '\s') { return "'" + $a + "'" } else { return $a }
}
$argArray = @()
if ($ExecArgs -and $ExecArgs.Count -gt 0) { $argArray += $ExecArgs }
$argArray += $argsList
$display = ($argArray | ForEach-Object { QuoteArg $_ }) -join ' '
Write-Host "Full command: $Exec $display"

# Capture existing .srt files in both the source directory and the exec
# working directory so we can identify newly-created files and rename them
# deterministically after the run.
$beforeSrt = @()
try {
    $beforeSrt = Get-ChildItem -Path $SourceDir -Filter *.srt -File -ErrorAction SilentlyContinue
} catch { $beforeSrt = @() }
try {
    $beforeSrt += Get-ChildItem -Path $ExecWorkingDir -Filter *.srt -File -ErrorAction SilentlyContinue
} catch { }

try {
    # If executing an .exe, use Start-Process with redirected output to capture logs reliably
    $ext = [System.IO.Path]::GetExtension($Exec)
        if ($ext -and $ext.ToLower() -eq '.exe') {
        $timestamp = (Get-Date).ToString('yyyyMMdd_HHmmss')
        $outFile = Join-Path -Path $env:TEMP -ChildPath ("buzz_out_$timestamp.log")
        $errFile = Join-Path -Path $env:TEMP -ChildPath ("buzz_err_$timestamp.log")

        Write-Host "Running executable (direct call). Combined stdout/stderr -> $outFile"
        Push-Location -Path $ExecWorkingDir
        try {
            # Call executable directly with argument array to preserve spacing
            & $Exec @argArray 2>&1 | Tee-Object -FilePath $outFile | ForEach-Object { Write-Host $_ }
            $exitCode = $LASTEXITCODE
        } finally {
            Pop-Location
        }
        if (Test-Path $outFile) { Get-Content $outFile -Raw | Write-Host }
    } else {
        # Use the prepared argument array to avoid accidental splitting
        $processOutput = & $Exec @argArray 2>&1
        $exitCode = $LASTEXITCODE
        if ($processOutput) { $processOutput | ForEach-Object { Write-Host $_ } }
    }
} catch {
    Write-Error "Failed to run Buzz CLI: $_"
    exit 4
}

Write-Host "Captured exit code: $exitCode"

if ($exitCode -ne 0) {
    Write-Error "Buzz CLI exited with code $exitCode"
    exit $exitCode
}

# Look for newly created .srt files in the source directory (exclude any that
# existed before the run). If none are found, fall back to any SRT in the
# directory and pick the newest.

# Gather SRTs from both the source dir and the exec working dir after run
$afterSrt = @()
try { $afterSrt = Get-ChildItem -Path $SourceDir -Filter *.srt -File -ErrorAction SilentlyContinue } catch { $afterSrt = @() }
try { $afterSrt += Get-ChildItem -Path $ExecWorkingDir -Filter *.srt -File -ErrorAction SilentlyContinue } catch { }

$newSrt = @()
if ($beforeSrt -and $beforeSrt.Count -gt 0) {
    $beforeNames = $beforeSrt | ForEach-Object { $_.FullName }
    $newSrt = $afterSrt | Where-Object { $beforeNames -notcontains $_.FullName }
} else {
    $newSrt = $afterSrt
}

if ($newSrt -and $newSrt.Count -gt 0) {
    # choose the most recently written file
    $picked = $newSrt | Sort-Object -Property LastWriteTime -Descending | Select-Object -First 1
    $found = $picked.FullName
    if ($found -ne $OutputPath) {
        try {
            Move-Item -Path $found -Destination $OutputPath -Force
            Write-Host "Moved captions from $found to $OutputPath"
        } catch {
            Write-Error "Found captions at $found but failed to move: $_"
            Write-Host "You may find the captions at: $found"
            exit 5
        }
    } else {
        Write-Host "Success: captions written to $OutputPath"
    }
    exit 0
}

# No newly created SRT found. As a fallback, look for any SRT in the directory
# and pick the newest one.
if ($afterSrt -and $afterSrt.Count -gt 0) {
    $picked = $afterSrt | Sort-Object -Property LastWriteTime -Descending | Select-Object -First 1
    $found = $picked.FullName
    if ($found -ne $OutputPath) {
        try {
            Move-Item -Path $found -Destination $OutputPath -Force
            Write-Host "Moved captions from $found to $OutputPath"
        } catch {
            Write-Error "Found captions at $found but failed to move: $_"
            Write-Host "You may find the captions at: $found"
            exit 5
        }
    } else {
        Write-Host "Success: captions written to $OutputPath"
    }
    exit 0
}

Write-Error "Transcription completed but no .srt was found for basename '$BaseName'."
exit 6
