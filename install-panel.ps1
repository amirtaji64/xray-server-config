<#
.SYNOPSIS
  One-command installer: 3x-ui panel (user accounts with traffic / device / expiry limits) on Windows Server,
  serving the same VLESS + WebSocket inbound behind Cloudflare. Replaces the standalone Xray from install.ps1.

.DESCRIPTION
  Run in PowerShell as Administrator:

    [Net.ServicePointManager]::SecurityProtocol='Tls12'; & ([scriptblock]::Create((irm https://raw.githubusercontent.com/amirtaji64/xray-server-config/main/install-panel.ps1))) -Uuid <YOUR-UUID> -Domain <your.domain>

  What it does (safe to run again):
    1. Downloads the latest official 3x-ui for Windows into C:\x-ui and the latest Xray-core into it.
    2. Sets a random panel username / password / URL path (saved in C:\x-ui\panel-login.txt, admins only).
       The panel port is NOT opened in the firewall: open it only while connected to the VPN.
    3. Starts 3x-ui as the "3x-ui" task (starts with Windows; a 1-minute watchdog restarts it if it stops).
    4. Creates the VLESS + WS inbound (same port / path as before) with your UUID as the unlimited "owner"
       account, real client IP from Cloudflare (CF-Connecting-IP) so per-account device limits work.
    5. Routes Google through Cloudflare WARP (own free WARP account in C:\x-ui\warp-account.json).
    6. Stops and disables the old standalone Xray task, verifies the inbound is listening.
    7. Installs iplimit.ps1 (task "3x-ui-iplimit"): enforces each account's "Limit IP" device count,
       which 3x-ui alone does not do on Windows.

  Roll back to the standalone Xray at any time:
    'Xray','3x-ui','3x-ui-iplimit' | % { Disable-ScheduledTask $_ -EA 0 | Out-Null }
    Get-Process 3x-ui,xray-windows-amd64 -EA 0 | Stop-Process -Force
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | ? CommandLine -match 'iplimit' | % { Stop-Process -Id $_.ProcessId -Force }
    Enable-ScheduledTask Xray; Start-ScheduledTask Xray
#>
param(
  [Parameter(Mandatory = $true, HelpMessage = 'Owner UUID, e.g. the one already in your v2rayN config')]
  [string]$Uuid,
  [string]$Domain = '',
  [string]$WsPath = '/api/v1/stream',
  [int]$Port = 80,
  [int]$PanelPort = 2053,
  [string]$InstallDir = 'C:\x-ui',
  [switch]$NoWarp,
  [switch]$UpdatePanel,
  [string]$IpLimitScript = 'https://raw.githubusercontent.com/amirtaji64/xray-server-config/main/iplimit.ps1',   # URL or local path
  [switch]$KeepStandaloneXray   # testing only: leave the old Xray task running (use a different -Port)
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Step($n, $msg) { Write-Host "[$n/7] $msg" -ForegroundColor Cyan }
# Startup task + a 1-minute watchdog trigger: if the process dies, it is started again within a minute.
function Register-Watched($name, $execute, $arguments, $workDir) {
  $a = if ($arguments) { New-ScheduledTaskAction -Execute $execute -Argument $arguments -WorkingDirectory $workDir }
       else { New-ScheduledTaskAction -Execute $execute -WorkingDirectory $workDir }
  $boot = New-ScheduledTaskTrigger -AtStartup
  $watch = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1)
  $s = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
         -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew
  Register-ScheduledTask -TaskName $name -Action $a -Trigger @($boot, $watch) -Settings $s -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
}
function Fail($msg) { Write-Host "ERROR: $msg" -ForegroundColor Red; throw $msg }
function RandStr($len) { -join ((48..57) + (97..122) | Get-Random -Count $len | ForEach-Object { [char]$_ }) }
function PortOwner($p) {
  $c = Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($c) { (Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue).ProcessName }
}

$guid = [guid]::Empty
if (-not [guid]::TryParse($Uuid, [ref]$guid)) { Fail "'$Uuid' is not a valid UUID (format: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx)." }
$Uuid = $guid.ToString()
if (-not $WsPath.StartsWith('/')) { $WsPath = "/$WsPath" }
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Fail 'Run PowerShell as Administrator (right-click > Run as Administrator).' }

New-Item -ItemType Directory -Force $InstallDir | Out-Null
$exe = Join-Path $InstallDir '3x-ui.exe'
$loginFile = Join-Path $InstallDir 'panel-login.txt'

# --- 1. Download 3x-ui ---------------------------------------------------------
Step 1 '3x-ui panel'
if ($UpdatePanel -or -not (Test-Path $exe)) {
  $rel = Invoke-RestMethod 'https://api.github.com/repos/MHSanaei/3x-ui/releases/latest' -Headers @{ 'User-Agent' = 'xui-installer' }
  $asset = $rel.assets | Where-Object name -eq 'x-ui-windows-amd64.zip'
  $zip = Join-Path $env:TEMP 'x-ui-windows-amd64.zip'
  $tmp = Join-Path $env:TEMP 'x-ui-extract'
  Invoke-WebRequest $asset.browser_download_url -OutFile $zip -UseBasicParsing
  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
  Expand-Archive $zip -DestinationPath $tmp -Force
  Get-ScheduledTask -TaskName '3x-ui' -ErrorAction SilentlyContinue | Stop-ScheduledTask
  Get-Process 3x-ui, xray-windows-amd64 -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep 2
  Copy-Item (Join-Path $tmp 'x-ui\*') $InstallDir -Recurse -Force
  Remove-Item $zip, $tmp -Recurse -Force
  Write-Host "      Installed 3x-ui $($rel.tag_name)"
} else {
  Write-Host '      Already installed (use -UpdatePanel to update).'
}
# The Xray bundled with 3x-ui can lag behind (26.10.21 breaks the WARP outbound unless loglevel=debug),
# so always run the latest official Xray-core.
$coreExe = Join-Path $InstallDir 'bin\xray-windows-amd64.exe'
$xrel = Invoke-RestMethod 'https://api.github.com/repos/XTLS/Xray-core/releases/latest' -Headers @{ 'User-Agent' = 'xui-installer' }
$have = if (Test-Path $coreExe) { 'v' + (& $coreExe version | Select-Object -First 1).Split(' ')[1] } else { '' }
if ($have -ne $xrel.tag_name) {
  $zip = Join-Path $env:TEMP 'Xray-windows-64.zip'; $tmp = Join-Path $env:TEMP 'xray-core-extract'
  Invoke-WebRequest ($xrel.assets | Where-Object name -eq 'Xray-windows-64.zip').browser_download_url -OutFile $zip -UseBasicParsing
  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
  Expand-Archive $zip -DestinationPath $tmp -Force
  Get-Process xray-windows-amd64 -ErrorAction SilentlyContinue | Stop-Process -Force   # 3x-ui restarts it
  Start-Sleep 1
  Copy-Item (Join-Path $tmp 'xray.exe') $coreExe -Force
  Remove-Item $zip, $tmp -Recurse -Force
  Write-Host "      Xray-core $have -> $($xrel.tag_name)"
} else {
  Write-Host "      Xray-core $have (latest)"
}

# --- 2. Panel login (random, saved locally) -------------------------------------
Step 2 'Panel login'
if (Test-Path $loginFile) {
  $login = Get-Content $loginFile -Raw | ConvertFrom-Json
  Write-Host "      Reusing saved login ($loginFile)."
} else {
  $login = [pscustomobject]@{ username = 'admin' + (RandStr 4); password = (RandStr 20); basePath = '/' + (RandStr 12) + '/'; port = $PanelPort }
  Get-Process 3x-ui -ErrorAction SilentlyContinue | Stop-Process -Force
  Push-Location $InstallDir
  try {
    $out = & $exe setting -username $login.username -password $login.password -port $login.port -webBasePath $login.basePath 2>&1
  } finally { Pop-Location }
  if ($LASTEXITCODE -ne 0) { Fail "3x-ui setting failed: $out" }
  $login | ConvertTo-Json | Set-Content $loginFile -Encoding ascii
  icacls $loginFile /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F' | Out-Null
  Write-Host "      New random login saved to $loginFile (admins only)."
}

# --- 3. Startup task ---------------------------------------------------------------
Step 3 'Startup task'
Register-Watched '3x-ui' $exe $null $InstallDir
if (-not (Get-Process 3x-ui -ErrorAction SilentlyContinue)) { Start-ScheduledTask -TaskName '3x-ui' }
for ($i = 0; $i -lt 30 -and (PortOwner $login.port) -ne '3x-ui'; $i++) { Start-Sleep 1 }
if ((PortOwner $login.port) -ne '3x-ui') { Fail "Panel did not start on port $($login.port)." }
Write-Host "      Panel running on port $($login.port) (task '3x-ui', starts with Windows)."

# --- API session -----------------------------------------------------------------------
$base = "http://127.0.0.1:$($login.port)$($login.basePath.TrimEnd('/'))"
$csrf = (Invoke-RestMethod "$base/csrf-token" -SessionVariable web).obj   # every POST, including login, needs it
$hdr = @{ 'X-CSRF-Token' = $csrf }
$r = Invoke-RestMethod "$base/login" -Method Post -ContentType 'application/json' -WebSession $web -Headers $hdr `
       -Body (@{ username = $login.username; password = $login.password } | ConvertTo-Json)
if (-not $r.success) { Fail "Panel login failed: $($r.msg)" }
function Api($path, $body, [switch]$Form) {
  $p = @{ Uri = "$base$path"; Method = 'Post'; WebSession = $web; Headers = $hdr }
  if ($Form) { $p.Body = $body } elseif ($null -ne $body) { $p.Body = ($body | ConvertTo-Json -Depth 20); $p.ContentType = 'application/json' }
  $res = Invoke-RestMethod @p
  if (-not $res.success) { Fail "API $path failed: $($res.msg)" }
  $res.obj
}

# --- 4. Inbound + owner account -------------------------------------------------------
Step 4 'VLESS inbound'
$stream = [ordered]@{
  network = 'ws'; security = 'none'
  wsSettings = [ordered]@{ path = $WsPath; host = '' }
  sockopt = [ordered]@{ trustedXForwardedFor = @('CF-Connecting-IP') }   # real client IP behind Cloudflare -> device limits work
}
if ($Domain) { $stream.externalProxy = @([ordered]@{ forceTls = 'tls'; dest = $Domain; port = 443; remark = '' }) }   # share links use domain:443 TLS
$inbound = [ordered]@{
  enable = $true; remark = 'vless-ws-cloudflare'; listen = ''; port = $Port; protocol = 'vless'; expiryTime = 0; total = 0
  settings = [ordered]@{
    clients = @([ordered]@{ id = $Uuid; email = 'owner'; enable = $true; flow = ''; limitIp = 0; totalGB = 0; expiryTime = 0
                            subId = (RandStr 16); comment = 'server owner (unlimited)'; reset = 0 })
    decryption = 'none'
  }
  streamSettings = $stream
  sniffing = [ordered]@{ enabled = $true; destOverride = @('http', 'tls', 'quic'); routeOnly = $true }
}
$existing = @(Invoke-RestMethod "$base/panel/api/inbounds/list" -WebSession $web).obj | Where-Object remark -eq 'vless-ws-cloudflare' | Select-Object -First 1
if (-not $KeepStandaloneXray -and (PortOwner $Port) -eq 'xray') {
  # free the port from the standalone Xray before the panel's Xray binds it
  Get-ScheduledTask -TaskName 'Xray' -ErrorAction SilentlyContinue | Disable-ScheduledTask | Out-Null
  Get-Process xray -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep 2
}
$owner = PortOwner $Port
if ($owner -and $owner -ne 'xray-windows-amd64') {
  if ($owner -eq 'xray' -and $KeepStandaloneXray) { Fail "Port $Port is used by the standalone Xray. Use another -Port for testing." }
  Fail "Port $Port is used by '$owner'. Stop it first (IIS: Stop-Service W3SVC -Force; Set-Service W3SVC -StartupType Disabled)."
}
if ($existing) {
  Api "/panel/api/inbounds/update/$($existing.id)" $inbound | Out-Null
  Write-Host "      Updated existing inbound (port $Port, path $WsPath). Accounts unchanged."
} else {
  Api '/panel/api/inbounds/add' $inbound | Out-Null
  Write-Host "      Created inbound (port $Port, path $WsPath) with account 'owner' = $Uuid (unlimited)."
}

# --- 5. WARP for Google -------------------------------------------------------------------
Step 5 'Cloudflare WARP for Google'
$xo = Api '/panel/api/xray/' $null
if ($xo -is [string]) { $xo = $xo | ConvertFrom-Json }          # obj comes back as a JSON string
$tpl = $xo.xraySetting
if ($tpl -is [string]) { $tpl = $tpl | ConvertFrom-Json }
$outs = @($tpl.outbounds | Where-Object tag -ne 'warp')
$rules = @($tpl.routing.rules | Where-Object outboundTag -ne 'warp')
if ($NoWarp) {
  Write-Host '      Skipped (-NoWarp).'
} else {
  # The panel gets its own WARP account: two Xray processes sharing one WARP key keep kicking each other off.
  $acct = $null
  $acctFile = Join-Path $InstallDir 'warp-account.json'
  if (Test-Path $acctFile) { $acct = Get-Content $acctFile -Raw | ConvertFrom-Json }
  if (-not $acct) {
    try {
      $kv = @{}
      & (Join-Path $InstallDir 'bin\xray-windows-amd64.exe') wg | ForEach-Object { $k, $v = $_ -split ':\s*', 2; $kv[$k.Trim()] = $v.Trim() }
      $body = @{ install_id = ''; fcm_token = ''; key = $kv['Password (PublicKey)']; type = 'Android'; locale = 'en_US';
                 tos = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ') } | ConvertTo-Json
      $w = Invoke-RestMethod -Method Post 'https://api.cloudflareclient.com/v0a2158/reg' -Body $body -ContentType 'application/json' `
             -Headers @{ 'CF-Client-Version' = 'a-6.11-2223'; 'User-Agent' = 'okhttp/3.12.1' }
      if ($w.result) { $w = $w.result }
      $acct = [pscustomobject]@{ private_key = $kv['PrivateKey']; v4 = $w.config.interface.addresses.v4; v6 = $w.config.interface.addresses.v6
        peer_public_key = $w.config.peers[0].public_key; reserved = @([Convert]::FromBase64String($w.config.client_id) | ForEach-Object { [int]$_ }) }
      $acct | ConvertTo-Json | Set-Content $acctFile -Encoding ascii
    } catch {
      Write-Host "      WARNING: WARP registration failed ($($_.Exception.Message)). Continuing without WARP." -ForegroundColor Yellow
    }
  }
  if ($acct) {
    $outs += [pscustomobject][ordered]@{
      tag = 'warp'; protocol = 'wireguard'
      settings = [ordered]@{
        secretKey = $acct.private_key; address = @("$($acct.v4)/32", "$($acct.v6)/128")
        peers = @([ordered]@{ publicKey = $acct.peer_public_key; endpoint = 'engage.cloudflareclient.com:2408'; allowedIPs = @('0.0.0.0/0', '::/0') })
        mtu = 1280; reserved = @($acct.reserved); domainStrategy = 'ForceIPv4'
      }
    }
    # put the Google rule right after the panel's internal api rule
    $apiRules = @($rules | Where-Object outboundTag -eq 'api')
    $other = @($rules | Where-Object outboundTag -ne 'api')
    $rules = $apiRules + @([pscustomobject][ordered]@{ type = 'field'; domain = @('geosite:google', 'domain:ipinfo.io'); outboundTag = 'warp' }) + $other
    Write-Host '      Google -> WARP.'
  }
}
$tpl.outbounds = $outs
$tpl.routing.rules = $rules
# loopback-only socks inbound used by iplimit.ps1 to health-check WARP (never reachable from outside)
$ins = @($tpl.inbounds | Where-Object tag -ne 'warp-probe')
if ($outs | Where-Object tag -eq 'warp') {
  $ins += [pscustomobject][ordered]@{ tag = 'warp-probe'; listen = '127.0.0.1'; port = 10899; protocol = 'socks'; settings = [ordered]@{ auth = 'noauth'; udp = $false } }
}
$tpl.inbounds = $ins
Api '/panel/api/xray/update' @{ xraySetting = ($tpl | ConvertTo-Json -Depth 30) } -Form | Out-Null
Api '/panel/api/server/restartXrayService' $null | Out-Null

# --- 6. Verify -----------------------------------------------------------------------------
Step 6 'Verify'
for ($i = 0; $i -lt 20 -and (PortOwner $Port) -ne 'xray-windows-amd64'; $i++) { Start-Sleep 1 }
if ((PortOwner $Port) -ne 'xray-windows-amd64') { Fail "Panel Xray is not listening on port $Port. Check: Panel > Xray logs." }
if (-not (Get-NetFirewallRule -DisplayName "Xray TCP $Port" -ErrorAction SilentlyContinue)) {
  New-NetFirewallRule -DisplayName "Xray TCP $Port" -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow | Out-Null
}
Write-Host "      Panel Xray listening on port $Port."

# --- 7. Device-limit enforcer ----------------------------------------------------------------
Step 7 'Device-limit enforcer (Limit IP)'
$ipl = Join-Path $InstallDir 'iplimit.ps1'
if ($IpLimitScript -match '^https?://') { Invoke-WebRequest $IpLimitScript -OutFile $ipl -UseBasicParsing } else { Copy-Item $IpLimitScript $ipl -Force }
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object CommandLine -match 'iplimit\.ps1' |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force }   # restart with the new version
Register-Watched '3x-ui-iplimit' 'powershell.exe' "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ipl`"" $InstallDir
Start-ScheduledTask -TaskName '3x-ui-iplimit'
Write-Host "      Running (task '3x-ui-iplimit', log $InstallDir\log\iplimit.log)."

$ip = try { Invoke-RestMethod 'https://api.ipify.org' -TimeoutSec 10 } catch { '<server-ip>' }
$d = if ($Domain) { $Domain } else { '<your.domain>' }
Write-Host ''
Write-Host "Inbound OK on port $Port. Old standalone Xray task: $(if ($KeepStandaloneXray) { 'still running (test mode)' } else { 'disabled' })" -ForegroundColor Green
Write-Host ''
Write-Host 'PANEL (open it while CONNECTED to this VPN; the port is closed to the internet):' -ForegroundColor Yellow
Write-Host "  URL:      http://${ip}:$($login.port)$($login.basePath)"
Write-Host "  Username: $($login.username)"
Write-Host "  Password: $($login.password)"
Write-Host "  (saved in $loginFile)"
Write-Host ''
Write-Host 'Owner link (same as before):'
Write-Host "vless://$Uuid@${d}:443?encryption=none&security=tls&sni=$d&fp=firefox&alpn=http%2F1.1&type=ws&host=$d&path=$([uri]::EscapeDataString($WsPath))#owner" -ForegroundColor Green
Write-Host ''
Write-Host 'New account: Panel > Inbounds > vless-ws-cloudflare > Add client: Email = name, Limit IP = devices, Total GB, Expiry / monthly renewal, Comment = owner details.'
Write-Host 'Restart panel: Stop-Process -Name 3x-ui -Force  (the watchdog starts it again within 1 minute)'
