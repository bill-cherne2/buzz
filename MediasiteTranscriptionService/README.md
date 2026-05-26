# Mediasite Transcribe Script

This folder contains `transcribe.ps1` — a small PowerShell wrapper that invokes the installed Buzz CLI to transcribe a single media file and emit an SRT next to the source file.

## Purpose
- Run Buzz from an external system (e.g., Mediasite Recorder) to queue a single file for transcription.
- Rename the generated SRT to match the source basename (ensures predictable filenames for downstream systems).
- Serve as a Proof of Concept for providng local transcription services on a Mediasite Recorder

## Configurable settings (edit `transcribe.ps1` header)

- `ModelType` — e.g. `whisper`, `whisper.cpp`, `faster_whisper`. Default: `whisper`.
- `ModelSize` — whisper model size: `tiny`, `small`, `base`, `medium`, `large`. Default: `tiny`.
- `Language` — set to `'auto'` (default) for auto-detection, or a language code like `'en'` to force English.
- `OutputType` — currently `SRT` is used by the script; changing this requires editing the script logic.
- `HideGUI` — when `$true` the script will prefer to run without showing the Buzz GUI (note: when `UseExeWorkingDirectory` is true the script avoids passing `--hide-gui` to match the user's working invocation).
- `UseExeWorkingDirectory` — when `$true` the script runs `Buzz.exe` from its install folder (recommended; mirrors the manual command that succeeded).
- `BuzzPath` — full path to the installed `Buzz.exe` (defaults to `C:\Program Files (x86)\Buzz\Buzz.exe`). Update this if Buzz is installed in another location.

Edit these variables at the top of `transcribe.ps1` to change defaults.

## Examples

1) Basic (default settings)

```powershell
powershell -ExecutionPolicy Bypass -File "MediasiteTranscriptionService\transcribe.ps1" "C:\path\to\presentation.mp3"
```

2) Example: change defaults (edit script header) then run

Open `transcribe.ps1` and set:

```powershell
$ModelSize = 'small'
$Language = 'en'
$HideGUI = $false
```

Then run:

```powershell
powershell -ExecutionPolicy Bypass -File "MediasiteTranscriptionService\transcribe.ps1" "C:\path\to\presentation.mp3"
```

Notes
- The script prints a temp log path containing combined stdout/stderr for the Buzz run — use that for troubleshooting.
- You can also inspect Buzz logs at `%LOCALAPPDATA%\Buzz\Buzz\Logs\logs.txt`.
- The script intentionally renames the generated SRT to `<basename>.srt`. If the move fails the script prints the found path so you can retrieve the file.
MediasiteTranscriptionService

Overview
- `transcibe.ps1` looks for a media file and will call Buzz to generate an SRT using Faster-Whisper tiny.en.

Quick install
1. Download Buzz from SourceForge: https://sourceforge.net/projects/buzz-captions/files/
2. Install Buzz
3. Ensure `Buzz.exe` is installed at `C:\Program Files (x86)\Buzz\Buzz.exe` or update `BuzzExePath` in the config.

Run manually (for testing)
Open PowerShell as Administrator (if needed) and run:
