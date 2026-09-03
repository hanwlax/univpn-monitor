# UniVPN Monitor

Windows 下的 UniVPN 断线监控与客户端重启脚本。每 30 秒检查 VPN 网卡，连续失败两次后尝试恢复；通过观察窗口、退避和熔断减少频繁重启。

> 个人环境使用的脚本，非 UniVPN 官方工具。当前版本存在守护启动及参数传递限制，详见末尾。不能绕过认证、MFA 或服务端策略，也不保证启动客户端后一定连接成功。

## 文件与前提

| 文件 | 用途 |
| --- | --- |
| `Install-UniVPN-Reconnect.ps1` | 安装/更新副本，配置启动项与守护任务，尝试立即启动监控 |
| `Watch-UniVPN.ps1` | 常驻检查，断线后启动或重启 UniVPN 主程序 |
| `Ensure-UniVPN-Watcher.ps1` | 检查监控进程，不存在时尝试后台启动 |
| `Uninstall-UniVPN-Reconnect.ps1` | 删除启动项、任务和安装副本，保留日志 |

四个 `.ps1` 文件保持在同一目录，通常只需运行安装脚本，不必逐个运行。

- 在 Windows 当前登录用户的桌面会话中使用 Windows PowerShell 5.1。
- 默认客户端路径：`C:\Program Files (x86)\UniVPN\UniVPN.exe`。
- 默认健康条件：存在 `172.16.*` IPv4 地址，且对应网卡为 `Up`。其他网卡使用相同网段时可能误判。
- 按组织规定配置 UniVPN 保存密码和自动登录，先手动成功连接一次。脚本不读取、保存或填写凭据。
- 验证码、MFA、登录弹窗或服务端拒绝登录仍需人工处理。

## 安装或更新

下载本仓库 ZIP 并解压，或执行：

```powershell
git clone https://github.com/hanwlax/univpn-monitor.git
Set-Location .\univpn-monitor
```

在脚本所在目录打开 PowerShell，检查脚本内容后运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-UniVPN-Reconnect.ps1
```

`Bypass` 只用于本次进程，不永久修改执行策略，也不能覆盖组织策略。安装按当前用户设计；若策略拒绝创建任务，请检查实际错误。

安装会：

1. 将监控与守护复制到 `%LOCALAPPDATA%\UniVPN-Reconnect`。
2. 创建 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` 下的 `UniVPNReconnectWatcher` 登录启动项。
3. 创建“UniVPN 监控守护”任务：登录时及约每 5 分钟检查监控进程，重复触发配置约 10 年。
4. 清理旧版“UniVPN 自动重连监控”任务，停止旧监控并尝试启动新实例。

更新时获取仓库更新后重新运行安装命令；仅修改仓库文件不会更新安装副本。安装/更新会重置监控内存计数。

**这是登录后启动，不是无人登录时运行的系统服务，也不是提权任务。** 休眠、关机时不检查。安装完成提示并不证明守护可靠，必须核验进程和日志。本次仓库发布不会自动更新你的已安装脚本。

## 核验与日志

检查安装文件和监控进程：

```powershell
$watchScript = Join-Path $env:LOCALAPPDATA 'UniVPN-Reconnect\Watch-UniVPN.ps1'
Test-Path -LiteralPath $watchScript
Get-CimInstance -ClassName Win32_Process |
  Where-Object {
    $_.Name -match '^(powershell|pwsh)\.exe$' -and
    $_.ProcessId -ne $PID -and
    $_.CommandLine -like "*$watchScript*"
  } |
  Select-Object ProcessId, CommandLine
```

文件应存在；进程查询无输出表示未检出监控（也可能是权限导致无法看到命令行）。常驻的是 `Watch-UniVPN.ps1`，守护启动器正常情况下检查后就退出。

```powershell
Get-Content "$env:LOCALAPPDATA\UniVPN-Reconnect\watcher.log" -Tail 30 -Wait
```

新的“监控启动”日志说明该时刻启动过，不证明现在仍存活。VPN 健康时不逐轮写日志。此处 `Ctrl+C` 仅结束日志查看，不停止后台监控。

另开 PowerShell 窗口查看守护状态：

```powershell
Get-Content "$env:LOCALAPPDATA\UniVPN-Reconnect\launcher.log" -Tail 20
Get-ScheduledTask -TaskName 'UniVPN 监控守护' |
  Select-Object TaskName, State
Get-ScheduledTaskInfo -TaskName 'UniVPN 监控守护' |
  Select-Object LastRunTime, LastTaskResult, NextRunTime
Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name UniVPNReconnectWatcher
```

任务存在、状态 `Ready`、启动器记录“已重新启动”，都不单独证明监控存活。请结合进程及新日志核验，重启并登录后也检查一次。

## 临时手动运行

若文件存在而没有监控进程，可前台运行以查看错误：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File "$env:LOCALAPPDATA\UniVPN-Reconnect\Watch-UniVPN.ps1" `
  -LogPath "$env:LOCALAPPDATA\UniVPN-Reconnect\watcher.log"
```

保持窗口打开；此处 `Ctrl+C` 会停止前台监控。若提示脚本不存在，回到仓库目录重新安装。已有监控时新实例通常因互斥锁退出。

## 重连策略

| 参数 | 默认值 | 含义 |
| --- | --- | --- |
| `CheckIntervalSeconds` | 30 秒 | 每轮检查后的等待，不含检查耗时 |
| `FailureThreshold` | 2 | 连续两次失败确认断线 |
| `RecoveryObservationSeconds` | 300 秒 | 从本轮恢复开始计时的观察窗口，包含重启等待 |
| `RetryBackoffMinutes` | 5、10、20、30 分钟 | 失败后等待，再失败时逐步延长，之后保持 30 分钟 |
| `MaxRestartsPerHour` | 3 | 同一次连续故障中，滚动一小时最多三轮恢复尝试 |
| `CircuitBreakerMinutes` | 30 分钟 | 用尽预算时至少暂停恢复操作这么久 |

通常断线后约 30–60 秒确认，实际受检查耗时影响。客户端未运行就启动；仍运行则强制结束 `UniVPN.exe`、等待 5 秒再启动，不停止 `UniVPNService`。

首轮失败时可能经过约 5 分钟观察，再等待 5 分钟退避才重试。因此超过 5 分钟未重启，不一定是监控退出，也可能处于观察、退避或熔断；以日志的下次尝试时间为准。

**不会失败几次后永久放弃。** 只要监控进程存活，就继续检查并在等待结束后再尝试。恢复健康后会清空失败、退避及重启历史；计数不落盘，进程重启也清零。因此三次预算不是跨故障、跨进程的全局硬上限。

手动断开也会触发自动重连。若要长期保持断开，请卸载监控；仅结束监控进程可能被守护重新拉起。停止监控本身不会断开 VPN。

## 可选探测与参数

监控支持 `ProbeHost`：`ProbePort=0` 时用 ICMP，指定端口时检测 TCP。目标需经授权、稳定且仅在 VPN 内可达；目标自身故障也可能触发重启。

确认没有其他监控运行后，可在仓库目录前台运行：

```powershell
$probeHost = Read-Host '输入实际内网主机 IP 或域名'
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Watch-UniVPN.ps1 -ProbeHost $probeHost -ProbePort 22
```

端口应实际开放；若使用 ICMP，目标必须允许 Ping。探测耗时可能使检查周期超过配置值。

其他参数包括 `VpnAddressPrefix`、`ClientPath` 及上表各项，完整声明见 `Watch-UniVPN.ps1` 开头。安装器只暴露两个探测参数，其他参数不会由安装器自动持久化。

**当前限制：安装器的 `-ProbeHost`/`-ProbePort` 仅写入登录启动项。立即启动及守护补拉没有传递它们，会回退为仅检查网卡。** 在修复参数持久化前，不应依赖安装器保证所有启动入口都执行内网探测。

## 已知问题与安全边界

- 历史环境中计划任务曾返回 `0xFFFD0000`，未能补拉监控，根因未确证。当前版本不能承诺长期无人值守可靠；先以前台命令查看错误，再结合任务和日志诊断。
- 计划任务命令的路径未完整加引号，用户目录含空格时可能启动失败。
- 守护通过命令行包含脚本路径判断进程，可能误匹配；启动后也没有检查子进程持续存活。
- 主监控不是系统服务；异常退出后的恢复依赖守护正常运行，没有独立邮件、短信或桌面告警。
- 不主动重置网卡、修改路由或防火墙，但重启 UniVPN 可能引发 TAP、Hyper-V、WSL mirrored networking 网络变化，影响 WireGuard、SSH 等连接。不要在关键远程操作期间随意测试断线。
- 日志中的 WSL/WireGuard 信息仅为相关 Windows 网卡状态摘要，不是 WSL 内部连通性或 WireGuard 握手验证。
- `watcher.log` 超过约 2 MB 会轮转到 `watcher.log.old`；`launcher.log` 没有轮转。日志可能含内网地址、路径和网卡名称，分享前请脱敏；仓库默认忽略日志。

## 卸载

在仓库目录运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Uninstall-UniVPN-Reconnect.ps1
```

删除当前用户启动项、守护及旧版任务、安装后的两个脚本副本，并停止匹配到的监控进程。保留安装目录内的日志；不卸载 UniVPN，不主动断开 VPN，也不删除仓库文件。
