<#
.SYNOPSIS
  One-command installer: Xray VLESS + WebSocket server (behind Cloudflare) on a fresh Windows Server.

.DESCRIPTION
  Run in PowerShell as Administrator on a brand-new VPS (nothing else needed - no git, no zip):

    [Net.ServicePointManager]::SecurityProtocol='Tls12'; & ([scriptblock]::Create((irm https://raw.githubusercontent.com/amirtaji64/xray-server-config/main/install.ps1))) -Uuid <YOUR-UUID> -Domain <your.domain>

  What it does (safe to run again at any time):
    1. Downloads the latest official Xray-core (XTLS/Xray-core) into C:\Xray if missing.
    2. Registers a free Cloudflare WARP device and routes Google traffic through it (skip with -NoWarp).
    3. Writes and validates C:\Xray\config.json with YOUR UUID (backup of the old one is kept).
    4. Opens the firewall port, creates the "Xray" startup task, (re)starts Xray and verifies it is listening.
    5. Prints the client link.

  Xray runs as a Scheduled Task named "Xray" (not a Windows service), so use:
    status : Get-Process xray ; netstat -ano | findstr :80
    restart: Start-ScheduledTask XrayRestart
#>
param(
  [Parameter(Mandatory = $true, HelpMessage = 'Client UUID, e.g. the one already in your v2rayN config')]
  [string]$Uuid,
  [string]$Domain = '',
  [string]$WsPath = '/api/v1/stream',
  [int]$Port = 80,
  [string]$InstallDir = 'C:\Xray',
  [switch]$NoWarp,
  [switch]$UpdateXray,
  [switch]$SkipTask
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is very slow with the progress bar on PS 5.1
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Step($n, $msg) { Write-Host "[$n/5] $msg" -ForegroundColor Cyan }
function Fail($msg) { Write-Host "ERROR: $msg" -ForegroundColor Red; throw $msg }

$guid = [guid]::Empty
if (-not [guid]::TryParse($Uuid, [ref]$guid)) { Fail "'$Uuid' is not a valid UUID (format: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx)." }
$Uuid = $guid.ToString()
if (-not $WsPath.StartsWith('/')) { $WsPath = "/$WsPath" }

if (-not $SkipTask) {
  $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if (-not $isAdmin) { Fail 'Run PowerShell as Administrator (right-click > Run as Administrator).' }
}

New-Item -ItemType Directory -Force $InstallDir | Out-Null
$xray = Join-Path $InstallDir 'xray.exe'

# --- 1. Xray-core -----------------------------------------------------------
Step 1 'Xray-core'
if ($UpdateXray -or -not (Test-Path $xray)) {
  $rel = Invoke-RestMethod 'https://api.github.com/repos/XTLS/Xray-core/releases/latest' -Headers @{ 'User-Agent' = 'xray-installer' }
  $asset = $rel.assets | Where-Object name -eq 'Xray-windows-64.zip'
  $zip = Join-Path $env:TEMP 'Xray-windows-64.zip'
  Invoke-WebRequest $asset.browser_download_url -OutFile $zip -UseBasicParsing
  Get-Process xray -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep 1
  Expand-Archive $zip -DestinationPath $InstallDir -Force
  Remove-Item $zip
  Write-Host "      Installed $($rel.tag_name)"
} else {
  $ver = (& $xray version | Select-Object -First 1).Split(' ')[1]
  Write-Host "      Already installed: Xray $ver"
}

# --- 2. Cloudflare WARP (Google traffic) --------------------------------------
Step 2 'Cloudflare WARP'
$acct = $null
$acctFile = Join-Path $InstallDir 'warp-account.json'
if ($NoWarp) {
  Write-Host '      Skipped (-NoWarp): all traffic goes out directly.'
} elseif (Test-Path $acctFile) {
  $acct = Get-Content $acctFile -Raw | ConvertFrom-Json
  Write-Host '      Reusing existing WARP account.'
} else {
  try {
    $kv = @{}
    & $xray wg | ForEach-Object { $k, $v = $_ -split ':\s*', 2; $kv[$k.Trim()] = $v.Trim() }
    $body = @{ install_id = ''; fcm_token = ''; key = $kv['Password (PublicKey)']; type = 'Android'; locale = 'en_US';
               tos = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ') } | ConvertTo-Json
    $r = Invoke-RestMethod -Method Post 'https://api.cloudflareclient.com/v0a2158/reg' -Body $body -ContentType 'application/json' `
           -Headers @{ 'CF-Client-Version' = 'a-6.11-2223'; 'User-Agent' = 'okhttp/3.12.1' }
    if ($r.result) { $r = $r.result }
    [ordered]@{
      private_key     = $kv['PrivateKey']
      v4              = $r.config.interface.addresses.v4
      v6              = $r.config.interface.addresses.v6
      peer_public_key = $r.config.peers[0].public_key
      reserved        = @([Convert]::FromBase64String($r.config.client_id) | ForEach-Object { [int]$_ })
    } | ConvertTo-Json | Set-Content $acctFile -Encoding ascii
    $acct = Get-Content $acctFile -Raw | ConvertFrom-Json
    Write-Host '      Registered a new WARP account.'
  } catch {
    Write-Host "      WARNING: WARP registration failed ($($_.Exception.Message)). Continuing without WARP." -ForegroundColor Yellow
  }
}

# --- 3. config.json -----------------------------------------------------------
Step 3 'config.json'
$outbounds = @([ordered]@{ tag = 'direct'; protocol = 'freedom' })
$rules = @()
if ($acct) {
  $outbounds += [ordered]@{
    tag = 'warp'; protocol = 'wireguard'
    settings = [ordered]@{
      secretKey = $acct.private_key
      address   = @("$($acct.v4)/32", "$($acct.v6)/128")
      peers     = @([ordered]@{ publicKey = $acct.peer_public_key; endpoint = 'engage.cloudflareclient.com:2408'; allowedIPs = @('0.0.0.0/0', '::/0') })
      mtu = 1280; reserved = @($acct.reserved); domainStrategy = 'ForceIPv4'
    }
  }
  $rules += [ordered]@{ type = 'field'; domain = @('geosite:google', 'domain:ipinfo.io'); outboundTag = 'warp' }
}
$config = [ordered]@{
  log = @{ loglevel = 'warning' }
  inbounds = @([ordered]@{
    listen = '0.0.0.0'; port = $Port; protocol = 'vless'
    settings = [ordered]@{ clients = @(@{ id = $Uuid }); decryption = 'none' }
    streamSettings = [ordered]@{ network = 'ws'; wsSettings = @{ path = $WsPath } }
    sniffing = [ordered]@{ enabled = $true; destOverride = @('http', 'tls', 'quic'); routeOnly = $true }
  })
  outbounds = $outbounds
  routing = [ordered]@{ domainStrategy = 'AsIs'; rules = $rules }
}
$cfgPath = Join-Path $InstallDir 'config.json'
$tmp = Join-Path $InstallDir 'config.new.json'
$config | ConvertTo-Json -Depth 10 | Set-Content $tmp -Encoding ascii
$test = & $xray run -test -c $tmp 2>&1 | Select-Object -Last 1
if ("$test" -notmatch 'Configuration OK') { Remove-Item $tmp; Fail "Config validation failed: $test" }
if (Test-Path $cfgPath) { Copy-Item $cfgPath (Join-Path $InstallDir ('config-backup-{0:yyyyMMdd-HHmmss}.json' -f (Get-Date))) }
Move-Item $tmp $cfgPath -Force
Write-Host "      OK (UUID $Uuid, path $WsPath, port $Port, WARP: $([bool]$acct))"

# --- 4. Firewall + startup task + start ---------------------------------------
if ($SkipTask) {
  Step 4 'Skipped firewall/task (-SkipTask).'
} else {
  Step 4 'Firewall, startup task, (re)start'
  if (-not (Get-NetFirewallRule -DisplayName "Xray TCP $Port" -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName "Xray TCP $Port" -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow | Out-Null
  }

  # Stop any running Xray (manual starts, old tasks, xray_no_window scripts) so the port is free.
  Get-Process xray -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep 2
  $owner = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($owner) {
    $p = Get-Process -Id $owner.OwningProcess -ErrorAction SilentlyContinue
    Fail "Port $Port is used by '$($p.ProcessName)' (PID $($owner.OwningProcess)). Stop it first (IIS: Stop-Service W3SVC -Force; Set-Service W3SVC -StartupType Disabled) or use -Port."
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

  Start-ScheduledTask -TaskName 'Xray'
  $listening = $false
  for ($i = 0; $i -lt 15 -and -not $listening; $i++) {
    Start-Sleep 1
    $listening = [bool](Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
      Where-Object { (Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).ProcessName -eq 'xray' })
  }
  if (-not $listening) { Fail "Xray did not start listening on port $Port. Test manually: & '$xray' run -c '$cfgPath'" }
  Write-Host "      Xray is running and listening on port $Port."
}

# --- 5. Summary ---------------------------------------------------------------
Step 5 'Done'
$ip = try { (Invoke-RestMethod 'https://api.ipify.org' -TimeoutSec 10) } catch { '<server-ip>' }
$d = if ($Domain) { $Domain } else { '<your.domain>' }
$path = [uri]::EscapeDataString($WsPath)
Write-Host ''
Write-Host 'Cloudflare: DNS record  A  ' -NoNewline; Write-Host "$d -> $ip" -ForegroundColor Green -NoNewline; Write-Host '  (Proxied/orange), SSL/TLS = Flexible, WebSockets = On'
Write-Host 'Client link (v2rayN / phone):'
Write-Host "vless://$Uuid@${d}:443?encryption=none&security=tls&sni=$d&fp=firefox&alpn=http%2F1.1&type=ws&host=$d&path=$path#$d" -ForegroundColor Green
Write-Host ''
Write-Host 'Xray is a Scheduled Task, not a service:  status = Get-Process xray   restart = Start-ScheduledTask XrayRestart'
