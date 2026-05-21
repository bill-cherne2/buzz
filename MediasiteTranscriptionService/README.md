MediasiteTranscriptionService

Overview
- `monitor.ps1` monitors a folder for new presentation subfolders, looks for `<foldername>.srt`, and if missing will parse `RecordedPresentation_70.xml` to find the MP4 and call Buzz to generate an SRT using Faster-Whisper tiny.en.

Quick install
1. Create folder `MediasiteTranscriptionService` in your repo and save `monitor.ps1` and `monitor_config.json` there (already done).
2. Edit `monitor_config.json` if needed (or let the script use your Windows My Documents -> Recorded Presentations path).
3. Ensure `Buzz.exe` is installed at `C:\Program Files (x86)\Buzz\Buzz.exe` or update `BuzzExePath` in the config.

Run manually (for testing)
Open PowerShell as Administrator (if needed) and run:

```powershell
powershell -ExecutionPolicy Bypass -File "C:\path\to\MediasiteTranscriptionService\monitor.ps1"
```

Example:
```powershell
powershell -ExecutionPolicy Bypass -File "C:\MediasiteTranscriptionService\monitor.ps1"
```


Run as a background service (recommended approach without installing extra software)
- Use Windows Task Scheduler:
  - Create a new Task.
  - Trigger: At startup (or on a schedule).
  - Action: Start a program:
    - Program/script: `powershell.exe`
    - Add arguments: `-ExecutionPolicy Bypass -File "C:\path\to\MediasiteTranscriptionService\monitor.ps1"`
  - On the General tab: choose "Run whether user is logged on or not" and provide credentials.
  - Optionally enable "Run with highest privileges".

Notes
- The script uses the presence of `<foldername>.srt` to mark completion. It also writes a `processed.json` and `monitor.log` next to the script.
- Because the script invokes the Buzz executable, no additional software is required on the workstation beyond Buzz itself.
