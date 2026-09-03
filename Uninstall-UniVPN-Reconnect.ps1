[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$taskName = 'UniVPN 自动重连监控'
$watchdogTaskName = 'UniVPN 监控守护'
$runValueName = 'UniVPNReconnectWatcher'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$installDirectory = Join-Path $env:LOCALAPPDATA 'UniVPN-Reconnect'

foreach ($registeredTaskName in @($taskName, $watchdogTaskName)) {
    $task = Get-ScheduledTask -TaskName $registeredTaskName -ErrorAction SilentlyContinue
    if ($null -ne $task) {
        Stop-ScheduledTask -TaskName $registeredTaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $registeredTaskName -Confirm:$false
    }
}

Remove-ItemProperty -Path $runKey -Name $runValueName -ErrorAction SilentlyContinue

$installedScript = Join-Path $installDirectory 'Watch-UniVPN.ps1'
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like "*$installedScript*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

# 保留 watcher.log 便于排查，只删除已安装的脚本副本。
if (Test-Path -LiteralPath $installedScript) {
    Remove-Item -LiteralPath $installedScript -Force
}
$installedLauncher = Join-Path $installDirectory 'Ensure-UniVPN-Watcher.ps1'
if (Test-Path -LiteralPath $installedLauncher) {
    Remove-Item -LiteralPath $installedLauncher -Force
}

Write-Host 'UniVPN 自动重连监控、登录启动项和守护任务已卸载；历史日志仍保留在：' -ForegroundColor Green
Write-Host $installDirectory
