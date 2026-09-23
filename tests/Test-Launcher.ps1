$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
function Assert($condition, $message) { if (-not $condition) { throw $message } }
$root = Split-Path -Parent $PSScriptRoot
foreach ($file in Get-ChildItem -LiteralPath $root -Filter '*.ps1') {
    $tokens = $null
    $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    Assert ($errors.Count -eq 0) "Parse errors in $($file.Name): $errors"
}
$temp = Join-Path ([IO.Path]::GetTempPath()) ('UniVPN test ' + [guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    $watch = Join-Path $temp 'Watch-UniVPN.ps1'
    Set-Content -LiteralPath $watch -Value '# test placeholder'
    @{
        ProbeHost = '172.16.1.2'; ProbePort = 22
        NetworkProbeHost = 'vpn.example.test'; NetworkProbePort = 443
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $temp 'settings.json')
    function Get-CimInstance { param($ClassName, $ErrorAction) @() }
    $capture = [PSCustomObject]@{ Arguments = '' }
    function Start-Process { param($FilePath, $ArgumentList, $WindowStyle) $capture.Arguments = $ArgumentList }
    & (Join-Path $root 'Ensure-UniVPN-Watcher.ps1') -WatchScript $watch -LogPath (Join-Path $temp 'launcher.log')
    Assert ($capture.Arguments.Contains('-ProbeHost "172.16.1.2"')) 'Lost VPN probe host'
    Assert ($capture.Arguments.Contains('-ProbePort 22')) 'Lost VPN probe port'
    Assert ($capture.Arguments.Contains('-NetworkProbeHost "vpn.example.test"')) 'Lost network probe host'
    Assert ($capture.Arguments.Contains('-NetworkProbePort 443')) 'Lost network probe port'
    Assert ($capture.Arguments.Contains('-File "' + $watch + '"')) 'Script path with spaces must be quoted'
    Write-Output 'PASS: script parsing and launcher configuration forwarding'
}
finally { Remove-Item -LiteralPath $temp -Recurse -Force }
