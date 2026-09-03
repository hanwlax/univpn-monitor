[CmdletBinding()]
param(
    [string]$VpnAddressPrefix = '172.16.',
    [string]$ProbeHost = '',
    [ValidateRange(0, 65535)]
    [int]$ProbePort = 0,
    [ValidateRange(10, 3600)]
    [int]$CheckIntervalSeconds = 30,
    [ValidateRange(1, 20)]
    [int]$FailureThreshold = 2,
    [ValidateRange(30, 1800)]
    [int]$RecoveryObservationSeconds = 300,
    [int[]]$RetryBackoffMinutes = @(5, 10, 20, 30),
    [ValidateRange(1, 20)]
    [int]$MaxRestartsPerHour = 3,
    [ValidateRange(5, 1440)]
    [int]$CircuitBreakerMinutes = 30,
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

function Wait-VpnRecovery {
    param([Parameter(Mandatory = $true)][DateTime]$StartedAt)

    $deadline = $StartedAt.AddSeconds($RecoveryObservationSeconds)
    $nextProgressLog = (Get-Date).AddSeconds(60)

    while ((Get-Date) -lt $deadline) {
        $health = Get-VpnHealth
        if ($health.Healthy) {
            $elapsed = [int]((Get-Date) - $StartedAt).TotalSeconds
            Write-Log "VPN 已恢复；耗时=${elapsed}s；$(Format-VpnHealth $health)。"
            return $true
        }

        if ((Get-Date) -ge $nextProgressLog) {
            $remaining = [Math]::Max(0, [int]($deadline - (Get-Date)).TotalSeconds)
            Write-Log "恢复观察中；剩余约=${remaining}s；$(Format-VpnHealth $health)。"
            $nextProgressLog = (Get-Date).AddSeconds(60)
        }

        $remainingSeconds = [int]($deadline - (Get-Date)).TotalSeconds
        if ($remainingSeconds -le 0) {
            break
        }
        Start-Sleep -Seconds ([Math]::Min($CheckIntervalSeconds, $remainingSeconds))
    }

    $finalHealth = Get-VpnHealth
    Write-Log "本轮恢复观察超时；观察=${RecoveryObservationSeconds}s；$(Format-VpnHealth $finalHealth)。"
    return $false
}

function Invoke-UniVpnRecovery {
    param([Parameter(Mandatory = $true)][int]$AttemptNumber)

    $startedAt = Get-Date
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

    return Wait-VpnRecovery -StartedAt $startedAt
}

function Get-BackoffMinutes {
    param([Parameter(Mandatory = $true)][int]$FailedAttemptNumber)
    $index = [Math]::Min($FailedAttemptNumber - 1, $RetryBackoffMinutes.Count - 1)
    return $RetryBackoffMinutes[$index]
}

$mutex = [System.Threading.Mutex]::new($false, 'Local\UniVPN-Reconnect-Watcher')
$ownsMutex = $false

try {
    $ownsMutex = $mutex.WaitOne(0, $false)
    if (-not $ownsMutex) {
        Write-Log '已有一个监控实例在运行，本实例退出。'
        exit 0
    }

    $backoffText = ($RetryBackoffMinutes -join ',')
    Write-Log "监控启动：地址前缀=$VpnAddressPrefix；检查=${CheckIntervalSeconds}s；失败阈值=$FailureThreshold；恢复观察=${RecoveryObservationSeconds}s；退避=${backoffText}min；每小时最多重启=$MaxRestartsPerHour；熔断=${CircuitBreakerMinutes}min。"

    $failureCount = 0
    $outageActive = $false
    $recoveryAttempt = 0
    $nextRecoveryAt = [DateTime]::MinValue
    $circuitOpenUntil = [DateTime]::MinValue
    $lastWaitingLog = [DateTime]::MinValue
    $restartHistory = New-Object 'System.Collections.Generic.List[datetime]'

    while ($true) {
        $health = Get-VpnHealth
        $now = Get-Date

        if ($health.Healthy) {
            if ($outageActive -or $failureCount -gt 0) {
                Write-Log "VPN 健康检查恢复正常；$(Format-VpnHealth $health)；故障状态和退避计数已清零。"
            }
            $failureCount = 0
            $outageActive = $false
            $recoveryAttempt = 0
            $nextRecoveryAt = [DateTime]::MinValue
            $circuitOpenUntil = [DateTime]::MinValue
            $lastWaitingLog = [DateTime]::MinValue
            $restartHistory.Clear()
        }
        else {
            $failureCount++
            if ($failureCount -le $FailureThreshold) {
                Write-Log "VPN 健康检查失败（$failureCount/$FailureThreshold）；$(Format-VpnHealth $health)。"
            }

            if ($failureCount -ge $FailureThreshold) {
                if (-not $outageActive) {
                    $outageActive = $true
                    $nextRecoveryAt = $now
                    Write-Log "确认 VPN 断线，将立即执行首轮恢复；$(Format-VpnHealth $health)。"
                }

                for ($i = $restartHistory.Count - 1; $i -ge 0; $i--) {
                    if (($now - $restartHistory[$i]).TotalHours -ge 1) {
                        $restartHistory.RemoveAt($i)
                    }
                }

                if ($now -lt $circuitOpenUntil) {
                    if (($now - $lastWaitingLog).TotalMinutes -ge 5) {
                        Write-Log "熔断中，不重启 UniVPN；恢复尝试时间=$($circuitOpenUntil.ToString('yyyy-MM-dd HH:mm:ss'))；$(Format-VpnHealth $health)。"
                        $lastWaitingLog = $now
                    }
                }
                elseif ($now -ge $nextRecoveryAt) {
                    if ($restartHistory.Count -ge $MaxRestartsPerHour) {
                        $budgetAvailableAt = $restartHistory[0].AddHours(1)
                        $minimumCircuitEnd = $now.AddMinutes($CircuitBreakerMinutes)
                        if ($budgetAvailableAt -gt $minimumCircuitEnd) {
                            $circuitOpenUntil = $budgetAvailableAt
                        }
                        else {
                            $circuitOpenUntil = $minimumCircuitEnd
                        }
                        $nextRecoveryAt = $circuitOpenUntil
                        $lastWaitingLog = [DateTime]::MinValue
                        Write-Log "已达到每小时 $MaxRestartsPerHour 次重启预算，开启熔断；下次最早尝试=$($circuitOpenUntil.ToString('yyyy-MM-dd HH:mm:ss'))。"
                    }
                    else {
                        $recoveryAttempt++
                        $restartHistory.Add($now)
                        $recovered = $false
                        try {
                            $recovered = Invoke-UniVpnRecovery -AttemptNumber $recoveryAttempt
                        }
                        catch {
                            Write-Log "第 $recoveryAttempt 轮恢复异常：$($_.Exception.Message)"
                        }

                        if ($recovered) {
                            $failureCount = 0
                            $outageActive = $false
                            $recoveryAttempt = 0
                            $nextRecoveryAt = [DateTime]::MinValue
                            $circuitOpenUntil = [DateTime]::MinValue
                            $lastWaitingLog = [DateTime]::MinValue
                            $restartHistory.Clear()
                        }
                        else {
                            $backoffMinutes = Get-BackoffMinutes -FailedAttemptNumber $recoveryAttempt
                            $nextRecoveryAt = (Get-Date).AddMinutes($backoffMinutes)
                            $lastWaitingLog = [DateTime]::MinValue
                            Write-Log "第 $recoveryAttempt 轮恢复失败；退避=${backoffMinutes}min；下次最早尝试=$($nextRecoveryAt.ToString('yyyy-MM-dd HH:mm:ss'))。"
                        }
                    }
                }
                elseif (($now - $lastWaitingLog).TotalMinutes -ge 5) {
                    Write-Log "等待退避结束；下次最早尝试=$($nextRecoveryAt.ToString('yyyy-MM-dd HH:mm:ss'))；$(Format-VpnHealth $health)。"
                    $lastWaitingLog = $now
                }
            }
        }

        Start-Sleep -Seconds $CheckIntervalSeconds
    }
}
finally {
    if ($ownsMutex) {
        $mutex.ReleaseMutex()
    }
    $mutex.Dispose()
}
