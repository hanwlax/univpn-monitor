[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z0-9._:-]*$')]
    [string]$ProbeHost = '',
    [ValidateRange(0, 65535)]
    [int]$ProbePort = 0,
    [ValidatePattern('^[A-Za-z0-9._:-]*$')]
    [string]$NetworkProbeHost = '',
    [ValidateRange(1, 65535)]
    [int]$NetworkProbePort = 443
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$taskName = 'UniVPN 自动重连监控'
$watchdogTaskName = 'UniVPN 监控守护'
$runValueName = 'UniVPNReconnectWatcher'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$installDirectory = Join-Path $env:LOCALAPPDATA 'UniVPN-Reconnect'
$targetScript = Join-Path $installDirectory 'Watch-UniVPN.ps1'
$sourceScript = Join-Path $PSScriptRoot 'Watch-UniVPN.ps1'
$targetLauncher = Join-Path $installDirectory 'Ensure-UniVPN-Watcher.ps1'
$sourceLauncher = Join-Path $PSScriptRoot 'Ensure-UniVPN-Watcher.ps1'

foreach ($requiredFile in @($sourceScript, $sourceLauncher)) {
    if (-not (Test-Path -LiteralPath $requiredFile)) {
        throw "安装脚本旁边缺少文件：$requiredFile"
    }
}

New-Item -ItemType Directory -Path $installDirectory -Force | Out-Null
Copy-Item -LiteralPath $sourceScript -Destination $targetScript -Force
Copy-Item -LiteralPath $sourceLauncher -Destination $targetLauncher -Force

$powerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
# 所有启动入口经守护读取同一配置，避免立即启动/补拉时丢失探测参数。
@{
    ProbeHost = $ProbeHost
    ProbePort = $ProbePort
    NetworkProbeHost = $NetworkProbeHost
    NetworkProbePort = $NetworkProbePort
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $installDirectory 'settings.json') -Encoding UTF8
$arguments = "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$targetLauncher`" -WatchScript `"$targetScript`""

# 旧版本使用任务计划；部分机器会拒绝以任务方式运行长驻 PowerShell 脚本。
$legacyTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($null -ne $legacyTask) {
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}

# HKCU 登录启动项会在真实桌面会话中运行，更适合需要唤起界面的 UniVPN。
$runCommand = "`"$powerShellExe`" $arguments"
New-Item -Path $runKey -Force | Out-Null
New-ItemProperty -Path $runKey -Name $runValueName -PropertyType String -Value $runCommand -Force | Out-Null

# 轻量守护任务只检查监控进程是否存在；任务自身立即退出，不直接操作 UniVPN。
$launcherLog = Join-Path $installDirectory 'launcher.log'
$watchdogArguments = "$arguments -LogPath `"$launcherLog`""
$watchdogAction = New-ScheduledTaskAction -Execute $powerShellExe -Argument $watchdogArguments
$currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $currentUser
$repeatTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 3650)
$watchdogPrincipal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Limited
$watchdogSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
Register-ScheduledTask -TaskName $watchdogTaskName -Action $watchdogAction -Trigger @($logonTrigger, $repeatTrigger) -Principal $watchdogPrincipal -Settings $watchdogSettings -Description '每 5 分钟检查 UniVPN 监控进程；仅在监控缺失时重新启动。' -Force | Out-Null

# 若正在升级，先结束旧监控实例；不影响其他 PowerShell 进程。
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like "*$targetScript*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

& $targetLauncher -WatchScript $targetScript

Write-Host 'UniVPN 自动重连监控已安装并启动。' -ForegroundColor Green
Write-Host "登录启动项：$runValueName"
Write-Host "守护任务：$watchdogTaskName（每 5 分钟）"
Write-Host "监控脚本：$targetScript"
Write-Host ("守护日志：" + (Join-Path $installDirectory 'launcher.log'))
Write-Host "运行日志：$installDirectory\watcher.log"
if ([string]::IsNullOrWhiteSpace($ProbeHost)) {
    Write-Host '当前仅检查 172.16.* 网卡。如需检测隧道是否真正可达，可重新安装并传入实验室内网主机：'
    Write-Host ".\Install-UniVPN-Reconnect.ps1 -ProbeHost 172.16.x.x"
}
elseif ($ProbePort -gt 0) {
    Write-Host "内网探测：$ProbeHost`:$ProbePort (TCP)"
}
else {
    Write-Host "内网探测：$ProbeHost (ICMP)"
}
