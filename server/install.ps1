<#
.SYNOPSIS
  Installs the Xray VLESS+WS server (behind Cloudflare) with Google traffic routed through Cloudflare WARP.

.DESCRIPTION
  1. Downloads the latest Xray-core for Windows (official XTLS/Xray-core release) unless xray.exe already exists.
  2. Registers a free Cloudflare WARP device (or reuses warp-account.json) - no extra tools needed.
  3. Builds config.json from config.template.json and validates it.
  4. Opens the firewall port and creates the "Xray" startup task (+ "XrayRestart" helper task).

  Secrets (UUID, WARP private key) are never stored in the repository. warp-account.json and
  config.json are written only to the install directory.

.EXAMPLE
  # Keep the same UUID as before so existing client configs keep working:
  .\install.ps1 -Uuid xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
#>
param(
  [string]$Uuid = ([guid]::NewGuid().ToString()),
  [string]$WsPath = '/api/v1/stream',
  [int]$Port = 80,
  [string]$InstallDir = 'C:\Xray',
  [switch]$UpdateXray,
  [switch]$SkipTask
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
New-Item -ItemType Directory -Force $InstallDir | Out-Null
$xray = Join-Path $InstallDir 'xray.exe'

# --- 1. Xray-core -----------------------------------------------------------
if ($UpdateXray -or -not (Test-Path $xray)) {
  Write-Host '[1/4] Downloading latest Xray-core...'
  $rel = Invoke-RestMethod 'https://api.github.com/repos/XTLS/Xray-core/releases/latest' -Headers @{ 'User-Agent' = 'xray-installer' }
  $asset = $rel.assets | Where-Object name -eq 'Xray-windows-64.zip'
  $zip = Join-Path $env:TEMP 'Xray-windows-64.zip'
  Invoke-WebRequest $asset.browser_download_url -OutFile $zip -UseBasicParsing
  Get-Process xray -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $xray } | Stop-Process -Force
  Expand-Archive $zip -DestinationPath $InstallDir -Force
  Remove-Item $zip
  Write-Host "      Installed $($rel.tag_name)"
} else {
  Write-Host '[1/4] Xray already installed, skipping download (use -UpdateXray to update).'
}

# --- 2. Cloudflare WARP account ---------------------------------------------
$acctFile = Join-Path $InstallDir 'warp-account.json'
if (Test-Path $acctFile) {
  Write-Host '[2/4] Reusing existing WARP account.'
  $acct = Get-Content $acctFile -Raw | ConvertFrom-Json
} else {
  Write-Host '[2/4] Registering a new Cloudflare WARP device...'
  $kv = @{}
  & $xray wg | ForEach-Object { $k, $v = $_ -split ':\s*', 2; $kv[$k.Trim()] = $v.Trim() }
  $priv = $kv['PrivateKey']; $pub = $kv['Password (PublicKey)']
  $body = @{ install_id = ''; fcm_token = ''; key = $pub; type = 'Android'; locale = 'en_US';
             tos = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ') } | ConvertTo-Json
  $r = Invoke-RestMethod -Method Post 'https://api.cloudflareclient.com/v0a2158/reg' -Body $body `
         -ContentType 'application/json' -Headers @{ 'CF-Client-Version' = 'a-6.11-2223'; 'User-Agent' = 'okhttp/3.12.1' }
  if ($r.result) { $r = $r.result }
  $acct = [ordered]@{
    private_key     = $priv
    v4              = $r.config.interface.addresses.v4
    v6              = $r.config.interface.addresses.v6
    peer_public_key = $r.config.peers[0].public_key
    reserved        = @([Convert]::FromBase64String($r.config.client_id) | ForEach-Object { [int]$_ })
    device_id       = $r.id
  }
  $acct | ConvertTo-Json | Set-Content $acctFile -Encoding ascii
  $acct = Get-Content $acctFile -Raw | ConvertFrom-Json
  Write-Host "      Registered (WARP address $($acct.v4))."
}

# --- 3. config.json ---------------------------------------------------------
Write-Host '[3/4] Writing config.json...'
$cfgPath = Join-Path $InstallDir 'config.json'
if (Test-Path $cfgPath) { Copy-Item $cfgPath (Join-Path $InstallDir ("config-backup-{0:yyyyMMdd-HHmmss}.json" -f (Get-Date))) }
$cfg = (Get-Content (Join-Path $here 'config.template.json') -Raw).
  Replace('__PORT__', "$Port").
  Replace('__UUID__', $Uuid).
  Replace('__WS_PATH__', $WsPath).
  Replace('__WARP_PRIVATE_KEY__', $acct.private_key).
  Replace('__WARP_V4__', $acct.v4).
  Replace('__WARP_V6__', $acct.v6).
  Replace('__WARP_PEER_PUBLIC_KEY__', $acct.peer_public_key).
  Replace('__WARP_RESERVED__', '[' + (($acct.reserved | ForEach-Object { "$_" }) -join ', ') + ']')
Set-Content $cfgPath $cfg -Encoding ascii
$test = & $xray run -test -c $cfgPath 2>&1 | Select-Object -Last 1
if ("$test" -notmatch 'Configuration OK') { throw "Config validation failed: $test" }
Write-Host '      Configuration OK.'

# --- 4. Firewall + startup task ---------------------------------------------
if (-not $SkipTask) {
  Write-Host '[4/4] Firewall rule and startup task...'
  if (-not (Get-NetFirewallRule -DisplayName "Xray TCP $Port" -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName "Xray TCP $Port" -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow | Out-Null
  }
  $a = New-ScheduledTaskAction -Execute $xray -Argument "run -c `"$cfgPath`"" -WorkingDirectory $InstallDir
  $t = New-ScheduledTaskTrigger -AtStartup
  $s = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
         -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew
  Register-ScheduledTask -TaskName 'Xray' -Action $a -Trigger $t -Settings $s -User 'SYSTEM' -RunLevel Highest -Force | Out-Null

  $restart = Join-Path $InstallDir 'restart.ps1'
  'Stop-Process -Name xray -Force -ErrorAction SilentlyContinue; Start-Sleep 2; Start-ScheduledTask -TaskName Xray' | Set-Content $restart -Encoding ascii
  $ra = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$restart`""
  Register-ScheduledTask -TaskName 'XrayRestart' -Action $ra -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
  Start-ScheduledTask -TaskName 'XrayRestart'
  Write-Host '      Xray started via scheduled task.'
} else {
  Write-Host '[4/4] Skipped firewall/task (-SkipTask).'
}

Write-Host ''
Write-Host "Done. UUID: $Uuid   WS path: $WsPath   Port: $Port"
Write-Host 'Point the Cloudflare DNS record (proxied, orange cloud) at this server IP. SSL mode: Flexible.'
