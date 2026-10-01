$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = 'C:\便签'
$server = Join-Path $root 'server'
$node = (Get-Command node).Source
$action = New-ScheduledTaskAction -Execute $node -Argument ('"' + (Join-Path $server 'server.mjs') + '"') -WorkingDirectory $server
$trigger = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName 'SongNoteServer' -Action $action -Trigger $trigger -Settings $settings -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
Start-ScheduledTask -TaskName 'SongNoteServer'
$backupAction = New-ScheduledTaskAction -Execute $node -Argument ('"' + (Join-Path $server 'backup.mjs') + '"') -WorkingDirectory $server
$backupTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) -RepetitionInterval (New-TimeSpan -Hours 1)
Register-ScheduledTask -TaskName 'SongNoteBackup' -Action $backupAction -Trigger $backupTrigger -Settings (New-ScheduledTaskSettingsSet -StartWhenAvailable) -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
Start-Sleep -Seconds 2
$health = Invoke-RestMethod 'http://127.0.0.1:18084/health'
if (-not $health.ok) { throw 'SongNote server failed health check' }
& $node (Join-Path $server 'backup.mjs')
if ($LASTEXITCODE -ne 0) { throw 'Backup failed' }
Write-Output 'SONGNOTE_SERVER_OK'
