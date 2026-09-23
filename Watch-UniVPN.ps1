[CmdletBinding()]
param(
    [string]$VpnAddressPrefix = '172.16.',
    [string]$ProbeHost = '',
    [ValidateRange(0, 65535)]
    [int]$ProbePort = 0,
    [ValidateRange(10, 3600)]
    [int]$CheckIntervalSeconds = 10,
    [ValidateRange(1, 20)]
    [int]$FailureThreshold = 2,
    [ValidateRange(30, 1800)]
    [int]$RecoveryObservationSeconds = 60,
    [int[]]$RetryBackoffMinutes = @(1, 2, 5, 10),
    [ValidateRange(1, 20)]
    [int]$MaxRestartsPerHour = 6,
    # 兼容旧调用；暂停时间现在由滚动一小时预算决定，此参数不再使用。
    [ValidateRange(5, 1440)]
    [int]$CircuitBreakerMinutes = 30,
    [ValidatePattern('^[A-Za-z0-9._:-]*$')]
    [string]$NetworkProbeHost = '',
    [ValidateRange(1, 65535)]
    [int]$NetworkProbePort = 443,
    [string]$ClientPath = 'C:\Program Files (x86)\UniVPN\UniVPN.exe',
    [string]$LogPath = "$env:LOCALAPPDATA\UniVPN-Reconnect\watcher.log"
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ($RetryBackoffMinutes.Count -eq 0 -or
    @($RetryBackoffMinutes | Where-Object { $_ -lt 1 }).Count -gt 0) {
    throw 'RetryBackoffMinutes 必须至少包含一个大于 0 的分钟数。'
}

$logDirectory = Split-Path -Parent $LogPath
if (-not (Test-Path -LiteralPath $logDirectory)) {
    New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
}

function Write-Log {
    param([Parameter(Mandatory = $true)][string]$Message)

    if ((Test-Path -LiteralPath $LogPath) -and
        (Get-Item -LiteralPath $LogPath).Length -gt 2MB) {
        Move-Item -LiteralPath $LogPath -Destination "$LogPath.old" -Force
    }

    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
}

function Get-UniVpnProcessCount {
    return @(Get-Process -Name 'UniVPN' -ErrorAction SilentlyContinue).Count
}

function Get-VpnHealth {
    try {
        $processCount = Get-UniVpnProcessCount
        $vpnAddresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.IPAddress.StartsWith($VpnAddressPrefix) })

        if ($vpnAddresses.Count -eq 0) {
            return [PSCustomObject]@{
                Healthy      = $false
                Reason       = "未找到 $VpnAddressPrefix* IPv4 地址"
                ProcessCount = $processCount
                Addresses    = '-'
                Adapters     = '-'
            }
        }

        $upAdapterNames = @()
        $allAdapterStates = @()
        foreach ($address in $vpnAddresses) {
            $adapter = Get-NetAdapter -InterfaceIndex $address.InterfaceIndex -ErrorAction SilentlyContinue
            if ($null -eq $adapter) {
                $allAdapterStates += "ifIndex=$($address.InterfaceIndex):Missing"
                continue
            }

            $allAdapterStates += "$($adapter.Name):$($adapter.Status)"
            if ($adapter.Status -eq 'Up') {
                $upAdapterNames += $adapter.Name
            }
        }

        $addressSummary = ($vpnAddresses.IPAddress -join ',')
        $adapterSummary = ($allAdapterStates -join ',')
        if ($upAdapterNames.Count -eq 0) {
            return [PSCustomObject]@{
                Healthy      = $false
                Reason       = 'VPN 地址存在，但对应网卡未处于 Up 状态'
                ProcessCount = $processCount
                Addresses    = $addressSummary
                Adapters     = $adapterSummary
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($ProbeHost)) {
            if ($ProbePort -gt 0) {
                $probeOk = [bool](Test-NetConnection -ComputerName $ProbeHost -Port $ProbePort `
                    -InformationLevel Quiet -WarningAction SilentlyContinue -ErrorAction SilentlyContinue)
                $probeDescription = "$ProbeHost`:$ProbePort TCP"
            }
            else {
                $probeOk = [bool](Test-Connection -ComputerName $ProbeHost -Count 1 `
                    -Quiet -ErrorAction SilentlyContinue)
                $probeDescription = "$ProbeHost ICMP"
            }

            if (-not $probeOk) {
                return [PSCustomObject]@{
                    Healthy      = $false
                    Reason       = "内网探测失败：$probeDescription"
                    ProcessCount = $processCount
                    Addresses    = $addressSummary
                    Adapters     = $adapterSummary
                }
            }
        }

        return [PSCustomObject]@{
            Healthy      = $true
            Reason       = 'VPN 地址和网卡正常'
            ProcessCount = $processCount
            Addresses    = $addressSummary
            Adapters     = $adapterSummary
        }
    }
    catch {
        return [PSCustomObject]@{
            Healthy      = $false
            Reason       = "健康检查异常：$($_.Exception.Message)"
            ProcessCount = Get-UniVpnProcessCount
            Addresses    = '-'
            Adapters     = '-'
        }
    }
}

function Format-VpnHealth {
    param([Parameter(Mandatory = $true)]$Health)
    return "原因=$($Health.Reason)；UniVPN进程=$($Health.ProcessCount)；地址=$($Health.Addresses)；网卡=$($Health.Adapters)"
}

function Get-NetworkContext {
    try {
        $adapters = @(Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -match 'UniVPN|TAP|WSL|WireGuard|vEthernet' -or
                $_.InterfaceDescription -match 'UniVPN|TAP|Hyper-V|WireGuard|WSL'
            } |
            ForEach-Object { "$($_.Name):$($_.Status)" })

        if ($adapters.Count -eq 0) {
            return '相关网卡=未发现'
        }
        return '相关网卡=' + ($adapters -join ',')
    }
    catch {
        return "相关网卡读取失败=$($_.Exception.Message)"
    }
}

function Start-UniVpnClient {
    if (-not (Test-Path -LiteralPath $ClientPath)) {
        throw "找不到 UniVPN 客户端：$ClientPath"
    }
    Start-Process -FilePath $ClientPath -WorkingDirectory (Split-Path -Parent $ClientPath)
}

# 只检查物理网卡，避免把 VPN/WSL 虚拟网卡误当作底层网络。
function Get-NetworkHealth {
    try {
        $ready = @()
        $allAddresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop)
        $allRoutes = @(Get-NetRoute -AddressFamily IPv4 -ErrorAction Stop)
        foreach ($adapter in @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object Status -eq 'Up')) {
            $addresses = @($allAddresses | Where-Object {
                $_.InterfaceIndex -eq $adapter.InterfaceIndex -and
                $_.AddressState -eq 'Preferred' -and $_.IPAddress -notlike '169.254.*'
            })
            $routes = @($allRoutes | Where-Object {
                $_.InterfaceIndex -eq $adapter.InterfaceIndex -and
                $_.DestinationPrefix -eq '0.0.0.0/0' -and $_.NextHop -ne '0.0.0.0'
            })
            if ($addresses.Count -gt 0 -and $routes.Count -gt 0) {
                $ready += $adapter.Name
            }
        }
        if ($ready.Count -eq 0) {
            return [PSCustomObject]@{ Ready = $false; Reason = '物理网卡尚未就绪（需要 Up、有效 IPv4 和默认路由）' }
        }
        if (-not [string]::IsNullOrWhiteSpace($NetworkProbeHost)) {
            # ConnectAsync 包含 DNS 解析；整体等待上限 3 秒。
            $client = New-Object System.Net.Sockets.TcpClient
            try {
                $connect = $client.ConnectAsync($NetworkProbeHost, $NetworkProbePort)
                if (-not $connect.Wait(3000) -or -not $client.Connected) {
                    return [PSCustomObject]@{ Ready = $false; Reason = "底层入口不可达：$NetworkProbeHost`:$NetworkProbePort" }
                }
            }
            finally { $client.Dispose() }
        }
        return [PSCustomObject]@{ Ready = $true; Reason = "底层网络就绪：$($ready -join ',')；入口探测=$NetworkProbeHost" }
    }
    catch {
        return [PSCustomObject]@{ Ready = $false; Reason = "底层网络检查失败：$($_.Exception.Message)" }
    }
}

function Invoke-UniVpnRecovery {
    param([Parameter(Mandatory = $true)][int]$AttemptNumber)

    $healthBefore = Get-VpnHealth
    Write-Log "开始第 $AttemptNumber 轮恢复；$(Format-VpnHealth $healthBefore)；$(Get-NetworkContext)。"

    $clientProcesses = @(Get-Process -Name 'UniVPN' -ErrorAction SilentlyContinue)
    if ($clientProcesses.Count -eq 0) {
        Write-Log 'UniVPN 主程序未运行，正在启动。'
        Start-UniVpnClient
    }
    else {
        # 不重复启动单实例程序；只重启用户界面进程，后台 UniVPNService 保持运行。
        Write-Log 'UniVPN 主程序仍在但隧道已断，正在直接重启主程序。'
        $clientProcesses | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 5
        Start-UniVpnClient
    }

    # 观察由主循环执行，期间仍持续检测底层网络变化。
}

function Get-BackoffMinutes {
    param([Parameter(Mandatory = $true)][int]$FailedAttemptNumber)
    $index = [Math]::Min($FailedAttemptNumber - 1, $RetryBackoffMinutes.Count - 1)
    return $RetryBackoffMinutes[$index]
}

function Invoke-MonitorLoop {
    $failureCount = 0
    $recoveryAttempt = 0
    $nextRecoveryAt = [DateTime]::MinValue
    $observationUntil = [DateTime]::MinValue
    $lastWaitingLog = [DateTime]::MinValue
    $networkWasReady = $null
    $readyCount = 0
    $networkRecoveryPending = $false
    $restartHistory = New-Object 'System.Collections.Generic.List[datetime]'

    while ($true) {
        $network = Get-NetworkHealth
        $health = Get-VpnHealth
        $now = Get-Date
        if ($null -eq $networkWasReady -or $network.Ready -ne $networkWasReady) {
            Write-Log "底层网络状态变化；Ready=$($network.Ready)；$($network.Reason)。"
        }
        if (-not $network.Ready) {
            $readyCount = 0
            $networkRecoveryPending = $true
            $observationUntil = [DateTime]::MinValue
        }
        else { $readyCount++ }
        $networkWasReady = $network.Ready

        # 预算跨短暂恢复保留，避免网络抖动导致无限重启。
        for ($i = $restartHistory.Count - 1; $i -ge 0; $i--) {
            if (($now - $restartHistory[$i]).TotalHours -ge 1) { $restartHistory.RemoveAt($i) }
        }
        if ($health.Healthy) {
            if ($failureCount -gt 0) { Write-Log "VPN 健康检查恢复正常；$(Format-VpnHealth $health)。" }
            $failureCount = 0
            $recoveryAttempt = 0
            $nextRecoveryAt = [DateTime]::MinValue
            $observationUntil = [DateTime]::MinValue
            $networkRecoveryPending = $false
        }
        else {
            $failureCount++
            if ($failureCount -le $FailureThreshold) {
                Write-Log "VPN 健康检查失败（$failureCount/$FailureThreshold）；$(Format-VpnHealth $health)。"
            }
            if ($network.Ready -and $readyCount -ge 2 -and $networkRecoveryPending) {
                # 两次网络就绪确认后取消旧退避，但不绕过每小时重启预算。
                $nextRecoveryAt = $now
                $recoveryAttempt = 0
                $networkRecoveryPending = $false
                Write-Log '底层网络已连续两次就绪，取消旧退避，优先恢复 VPN（仍受重启预算限制）。'
            }
            if (-not $network.Ready -or $readyCount -lt 2) {
                if (($now - $lastWaitingLog).TotalSeconds -ge 60) {
                    Write-Log "等待底层网络稳定，不重启 UniVPN，不消耗重启预算；$($network.Reason)。"
                    $lastWaitingLog = $now
                }
            }
            elseif ($failureCount -ge $FailureThreshold) {
                if ($observationUntil -ne [DateTime]::MinValue -and $now -ge $observationUntil) {
                    $backoffMinutes = Get-BackoffMinutes -FailedAttemptNumber $recoveryAttempt
                    $nextRecoveryAt = $now.AddMinutes($backoffMinutes)
                    $observationUntil = [DateTime]::MinValue
                    Write-Log "第 $recoveryAttempt 轮观察超时；退避=${backoffMinutes}min；下次最早尝试=$($nextRecoveryAt.ToString('yyyy-MM-dd HH:mm:ss'))。"
                }
                if ($observationUntil -eq [DateTime]::MinValue -and $now -ge $nextRecoveryAt) {
                    if ($restartHistory.Count -ge $MaxRestartsPerHour) {
                        $nextRecoveryAt = $restartHistory[0].AddHours(1)
                        # 到预算释放时重试，避免每次触顶都重新延长暂停。
                        Write-Log "重启预算已用尽；下次最早尝试=$($nextRecoveryAt.ToString('yyyy-MM-dd HH:mm:ss'))。"
                    }
                    else {
                        $recoveryAttempt++
                        $restartHistory.Add($now)
                        try {
                            Invoke-UniVpnRecovery -AttemptNumber $recoveryAttempt
                            $observationUntil = (Get-Date).AddSeconds($RecoveryObservationSeconds)
                            Write-Log "恢复观察开始；窗口=${RecoveryObservationSeconds}s。"
                        }
                        catch {
                            $nextRecoveryAt = (Get-Date).AddMinutes((Get-BackoffMinutes -FailedAttemptNumber $recoveryAttempt))
                            Write-Log "第 $recoveryAttempt 轮恢复异常：$($_.Exception.Message)；下次最早尝试=$($nextRecoveryAt.ToString('yyyy-MM-dd HH:mm:ss'))。"
                        }
                    }
                }
                if (($now - $lastWaitingLog).TotalSeconds -ge 60) {
                    if ($observationUntil -ne [DateTime]::MinValue) {
                        Write-Log "恢复观察中；观察截止=$($observationUntil.ToString('yyyy-MM-dd HH:mm:ss'))；$(Format-VpnHealth $health)。"
                    }
                    else {
                        Write-Log "等待重试；下次最早尝试=$($nextRecoveryAt.ToString('yyyy-MM-dd HH:mm:ss'))；$(Format-VpnHealth $health)。"
                    }
                    $lastWaitingLog = $now
                }
            }
        }
        Start-Sleep -Seconds $CheckIntervalSeconds
    }
}

$mutex = [System.Threading.Mutex]::new($false, 'Local\UniVPN-Reconnect-Watcher')
$ownsMutex = $false
try {
    $ownsMutex = $mutex.WaitOne(0, $false)
    if (-not $ownsMutex) {
        Write-Log '已有一个监控实例在运行，本实例退出。'
        exit 0
    }
    Write-Log "监控启动：检查=${CheckIntervalSeconds}s；失败阈值=$FailureThreshold；恢复观察=${RecoveryObservationSeconds}s；退避=$($RetryBackoffMinutes -join ',')min；每小时最多重启=$MaxRestartsPerHour；底层入口=$NetworkProbeHost`:$NetworkProbePort；内网探测=$ProbeHost`:$ProbePort。"
    Invoke-MonitorLoop
}
finally {
    if ($ownsMutex) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
