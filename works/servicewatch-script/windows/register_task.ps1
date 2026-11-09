$act = New-ScheduledTaskAction -Execute 'powershell.exe' `
       -Argument '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\ServiceWatch\scripts\sw_custom_metrics.ps1"'
$trg = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 1)
$set = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName 'ServiceWatchCustomMetrics' -Action $act -Trigger $trg -Settings $set -User 'SYSTEM' -RunLevel Highest
