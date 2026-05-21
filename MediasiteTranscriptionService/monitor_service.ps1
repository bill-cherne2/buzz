Param(
  [string]$ConfigPath = "",
  [int]$PollSeconds = 60,
  [switch]$RunOnce
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
if ($ConfigPath -eq "") { $ConfigPath = Join-Path $ScriptDir 'monitor_config.json' }

function Run-Monitor {
  param($cfg)
  $mon = Join-Path $ScriptDir 'monitor.ps1'
  if (-not (Test-Path $mon)) { Write-Error "monitor.ps1 not found in $ScriptDir"; return }
  Write-Host "Running monitor (Config=$cfg) at $(Get-Date)"
  & pwsh -NoProfile -File $mon -ConfigPath $cfg
  if ($LASTEXITCODE -ne 0) { Write-Warning "monitor.ps1 returned exit code $LASTEXITCODE" }
}

if ($RunOnce) { Run-Monitor -cfg $ConfigPath; exit 0 }

Write-Host "Starting long-running monitor service. Polling every $PollSeconds seconds. Press Ctrl-C to stop."
while ($true) {
  try {
    Run-Monitor -cfg $ConfigPath
  } catch {
    Write-Warning "Monitor run failed: $_"
  }
  Start-Sleep -Seconds $PollSeconds
}
