[CmdletBinding()]
param(
    [string]$WatchScript = "$env:LOCALAPPDATA\UniVPN-Reconnect\Watch-UniVPN.ps1",
    [string]$LogPath = "$env:LOCALAPPDATA\UniVPN-Reconnect\launcher.log"
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Write-LauncherLog {
    param([Parameter(Mandatory = $true)][string]$Message)
    $logDirectory = Split-Path -Parent $LogPath
    if (-not (Test-Path -LiteralPath $logDirectory)) {
        New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
    }
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
}

try {
    if (-not (Test-Path -LiteralPath $WatchScript)) {
        Write-LauncherLog "监控脚本不存在：$WatchScript"
        exit 2
    }
    $watchers = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -match '^(powershell|pwsh)\.exe$' -and
            $_.ProcessId -ne $PID -and
            $_.CommandLine -like "*$WatchScript*"
        })
    if ($watchers.Count -gt 0) {
        exit 0
    }
    $powerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $watcherLog = Join-Path (Split-Path -Parent $WatchScript) 'watcher.log'
    $quote = [char]34
    $arguments = "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File $quote$WatchScript$quote -LogPath $quote$watcherLog$quote"
    Start-Process -FilePath $powerShellExe -ArgumentList $arguments -WindowStyle Hidden
    Write-LauncherLog '检测到监控进程缺失，已重新启动。'
    exit 0
}
catch {
    Write-LauncherLog "守护检查失败：$($_.Exception.Message)"
    exit 1
}
