$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$source = Join-Path (Split-Path -Parent $PSScriptRoot) 'Watch-UniVPN.ps1'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
# Load functions only: no real monitoring, process termination, or network changes.
$ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false) |
    ForEach-Object { Invoke-Expression $_.Extent.Text }
$CheckIntervalSeconds = 10
$FailureThreshold = 2
$RecoveryObservationSeconds = 60
$RetryBackoffMinutes = @(1, 2, 5, 10)
$MaxRestartsPerHour = 6

function Assert($condition, $message) { if (-not $condition) { throw $message } }
function Write-Log($Message) { $script:messages.Add($Message) }
function Get-Date { $script:time }
function Get-NetworkHealth { [PSCustomObject]@{ Ready = [bool](& $script:networkAt $script:tick); Reason = 'test' } }
function Get-VpnHealth { [PSCustomObject]@{ Healthy = [bool](& $script:healthAt $script:tick); Reason = 'test'; ProcessCount = 1; Addresses = '-'; Adapters = '-' } }
function Invoke-UniVpnRecovery($AttemptNumber) { $script:attempts.Add($script:tick) }
function Start-Sleep($Seconds) {
    $script:tick++
    $script:time = $script:time.AddSeconds($Seconds)
    if ($script:tick -ge $script:limit) { throw 'TEST_END' }
}
function Run-Scenario($Network, $Health, $Ticks) {
    $script:networkAt = $Network
    $script:healthAt = $Health
    $script:limit = $Ticks
    $script:tick = 0
    $script:time = [datetime]'2026-09-23T23:00:00'
    $script:attempts = New-Object 'System.Collections.Generic.List[int]'
    $script:messages = New-Object 'System.Collections.Generic.List[string]'
    try { Invoke-MonitorLoop } catch { if ($_.Exception.Message -ne 'TEST_END') { throw } }
}
Run-Scenario { $false } { $false } 100
Assert ($attempts.Count -eq 0) 'Offline must not spend restart budget'
Run-Scenario { $true } { $false } 15
Assert (($attempts -join ',') -eq '1,13') 'First retry should occur after 60s observation + 60s backoff'
Run-Scenario { param($t) $t -lt 8 -or $t -ge 10 } { $false } 13
Assert (($attempts -join ',') -eq '1,11') 'Network restoration must cancel backoff after two ready samples'
Run-Scenario { param($t) $t -lt 3 -or $t -ge 5 } { $false } 8
Assert (($attempts -join ',') -eq '1,6') 'Network loss during observation must allow prompt recovery'
Run-Scenario { $true } { param($t) $t -ge 3 } 50
Assert ($attempts.Count -eq 1) 'Healthy VPN must end observation and suppress retries'
$MaxRestartsPerHour = 1
Run-Scenario { param($t) $t -lt 8 -or $t -ge 10 } { $false } 363
Assert (($attempts -join ',') -eq '1,361') 'Network restoration must not bypass hourly budget or add a fixed circuit delay'
Run-Scenario { $true } { param($t) $t -ge 3 -and $t -lt 5 } 50
Assert ($attempts.Count -eq 1) 'Brief VPN health must not erase restart history'
$MaxRestartsPerHour = 6
function Invoke-UniVpnRecovery($AttemptNumber) { $script:attempts.Add($script:tick); throw 'simulated launch failure' }
Run-Scenario { $true } { $false } 9
Assert (($attempts -join ',') -eq '1,7') 'Launch failures must back off without breaking monitor'
Write-Output 'PASS: 8 recovery state scenarios'

# Exercise real network readiness function with mocked Windows network cmdlets.
$ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-NetworkHealth' }, $false) |
    ForEach-Object { Invoke-Expression $_.Extent.Text }
$NetworkProbeHost = ''
$NetworkProbePort = 443
function Get-NetAdapter { param([switch]$Physical, $ErrorAction) @([PSCustomObject]@{ Name = 'Wi-Fi'; Status = 'Up'; InterfaceIndex = 7 }) }
function Get-NetIPAddress { param($InterfaceIndex, $AddressFamily, $ErrorAction) [PSCustomObject]@{ InterfaceIndex = 7; AddressState = 'Preferred'; IPAddress = $script:testIp } }
function Get-NetRoute { param($InterfaceIndex, $AddressFamily, $ErrorAction) if ($script:hasRoute) { [PSCustomObject]@{ InterfaceIndex = 7; DestinationPrefix = '0.0.0.0/0'; NextHop = '192.168.1.1' } } }
$script:testIp = '192.168.1.2'
$script:hasRoute = $true
Assert ((Get-NetworkHealth).Ready) 'Physical adapter with IPv4 and default route should be ready'
$script:testIp = '169.254.1.2'
Assert (-not (Get-NetworkHealth).Ready) 'Link-local address must not count as ready'
$script:testIp = '192.168.1.2'
$script:hasRoute = $false
Assert (-not (Get-NetworkHealth).Ready) 'Missing default route must not count as ready'
function Get-NetAdapter { param([switch]$Physical, $ErrorAction) throw 'adapter query failed' }
Assert (-not (Get-NetworkHealth).Ready) 'Adapter query errors must defer recovery'
Write-Output 'PASS: 4 network readiness scenarios'

# A second Up adapter without an IP must not hide a usable Wi-Fi adapter.
function Get-NetAdapter {
    param([switch]$Physical, $ErrorAction)
    @([PSCustomObject]@{ Name = 'Ethernet'; Status = 'Up'; InterfaceIndex = 8 },
      [PSCustomObject]@{ Name = 'Wi-Fi'; Status = 'Up'; InterfaceIndex = 7 })
}
$script:hasRoute = $true
Assert ((Get-NetworkHealth).Ready) 'An unconfigured adapter must not hide a ready adapter'
# Use a local TCP listener to verify the optional entry probe without external traffic.
$listener = New-Object System.Net.Sockets.TcpListener -ArgumentList ([System.Net.IPAddress]::Loopback), 0
try {
    $listener.Start()
    $NetworkProbeHost = '127.0.0.1'
    $NetworkProbePort = $listener.LocalEndpoint.Port
    Assert ((Get-NetworkHealth).Ready) 'Reachable entry must pass TCP probe'
    $listener.Stop()
    Assert (-not (Get-NetworkHealth).Ready) 'Refused entry must defer recovery'
}
finally { $listener.Stop() }
Write-Output 'PASS: multiple adapters and reachable/refused TCP entry'
