# Device-limit enforcer + WARP health check for 3x-ui on Windows.
# 3x-ui's own "Limit IP" on Windows only drops the account for 0.1 s, so extra devices keep working.
# Every 5 s this reads each limited account's online IPs from Xray and blocks the extra devices
# (newest first) with an Xray routing rule for a few minutes. Real client IPs come from Cloudflare
# (X-Forwarded-For, trusted via CF-Connecting-IP on the inbound).
# Runs as the "3x-ui-iplimit" startup task. Log: C:\x-ui\log\iplimit.log
param(
  [string]$Dir = 'C:\x-ui',
  [int]$IntervalSec = 5,
  [int]$WindowSec = 60,    # a device counts as online if seen in the last N seconds (short requests come and go)
  [int]$BanMinutes = 3
)
$ErrorActionPreference = 'Continue'
$xray = Join-Path $Dir 'bin\xray-windows-amd64.exe'
$cfgFile = Join-Path $Dir 'bin\config.json'
$logFile = Join-Path $Dir 'log\iplimit.log'
New-Item -ItemType Directory -Force (Split-Path $logFile) | Out-Null

function Log($m) {
  $line = '{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $m
  Add-Content $logFile $line
  if ((Get-Item $logFile).Length -gt 2MB) { Move-Item $logFile "$logFile.old" -Force }
}

$session = $null; $csrfHdr = $null
function Panel($path, [switch]$Post) {
  # calls the panel API (logs in on demand); returns the response or $null
  $login = Get-Content (Join-Path $Dir 'panel-login.txt') -Raw | ConvertFrom-Json
  $base = "http://127.0.0.1:$($login.port)$($login.basePath.TrimEnd('/'))"
  for ($try = 0; $try -lt 2; $try++) {
    try {
      if (-not $script:session) {
        $csrf = (Invoke-RestMethod "$base/csrf-token" -SessionVariable s -TimeoutSec 10).obj
        $script:csrfHdr = @{ 'X-CSRF-Token' = $csrf }
        $null = Invoke-RestMethod "$base/login" -Method Post -ContentType 'application/json' -WebSession $s -Headers $script:csrfHdr `
                  -Body (@{ username = $login.username; password = $login.password } | ConvertTo-Json) -TimeoutSec 10
        $script:session = $s
      }
      $r = if ($Post) { Invoke-RestMethod "$base$path" -Method Post -WebSession $script:session -Headers $script:csrfHdr -TimeoutSec 20 }
           else { Invoke-RestMethod "$base$path" -WebSession $script:session -TimeoutSec 10 }
      if (-not $r.success) { throw "$path failed" }
      return $r
    } catch { $script:session = $null }
  }
  return $null
}

function Get-Limits {
  # returns @{ email = limit } for enabled accounts with a device limit
  $r = Panel '/panel/api/clients/list'
  if (-not $r) { return $null }
  $m = @{}
  foreach ($c in $r.obj) { if ($c.enable -and $c.limitIp -gt 0) { $m[$c.email] = [int]$c.limitIp } }
  return $m
}

# WARP health check. Xray's WireGuard (WARP) outbound occasionally stops passing traffic until Xray restarts,
# which silently breaks every Google site. A loopback-only socks inbound "warp-probe" (added by
# install-panel.ps1) lets us test the real path; two failed probes in a row -> restart Xray via the panel.
$probeFails = 0; $lastProbe = [datetime]::MinValue
function Check-Warp {
  $cfg = Get-Content $cfgFile -Raw | ConvertFrom-Json
  $probe = $cfg.inbounds | Where-Object tag -eq 'warp-probe' | Select-Object -First 1
  if (-not $probe -or -not ($cfg.outbounds | Where-Object tag -eq 'warp')) { return }
  $code = & curl.exe -s -o NUL -w '%{http_code}' -m 10 -x "socks5h://127.0.0.1:$($probe.port)" https://www.google.com/generate_204
  if ($code -eq '204') { $script:probeFails = 0; return }
  $script:probeFails++
  Log "WARP probe failed ($code), $($script:probeFails) in a row"
  if ($script:probeFails -ge 2) {
    if (Panel '/panel/api/server/restartXrayService' -Post) { Log 'restarted Xray to recover WARP' } else { Log 'Xray restart via panel failed' }
    $script:probeFails = 0
  }
}

function Get-OnlineIps($email) {
  $out = & $xray api statsonlineiplist --server=127.0.0.1:62789 -email $email 2>$null
  if (-not $out) { return @() }
  $j = ($out -join "`n") | ConvertFrom-Json
  if (-not $j.ips) { return @() }
  @($j.ips.PSObject.Properties.Name)
}

function Apply-Bans($bans) {
  # replaces the live routing rules: panel rules with our block rules right after the internal "api" rule
  $cfg = Get-Content $cfgFile -Raw | ConvertFrom-Json
  $rules = @($cfg.routing.rules | Where-Object { -not ($_.ruleTag -like 'iplimit-*') })
  $apiRules = @($rules | Where-Object { $_.outboundTag -eq 'api' })
  $other = @($rules | Where-Object { $_.outboundTag -ne 'api' })
  $mine = @()
  $i = 0
  foreach ($email in $bans.Keys) {
    $ips = @($bans[$email].Keys)
    if ($ips.Count) { $mine += [pscustomobject][ordered]@{ ruleTag = "iplimit-$i"; type = 'field'; user = @($email); source = $ips; outboundTag = 'blocked' }; $i++ }
  }
  $routing = [ordered]@{ rules = @($apiRules + $mine + $other) }
  if ($cfg.routing.balancers) { $routing.balancers = $cfg.routing.balancers }
  $tmp = Join-Path $env:TEMP 'iplimit-rules.json'
  [pscustomobject]@{ routing = $routing } | ConvertTo-Json -Depth 20 | Set-Content $tmp -Encoding ascii
  $res = & $xray api adrules --server=127.0.0.1:62789 $tmp 2>&1
  if ($LASTEXITCODE -ne 0) { Log "adrules failed: $res"; return $false }
  return $true
}

$firstSeen = @{}   # "email|ip" -> datetime first seen online
$lastSeen = @{}    # "email|ip" -> datetime last seen online
$bans = @{}        # email -> @{ ip = until }
$applied = ''      # signature of the rules currently pushed to Xray
$xrayPid = 0
Log "started (interval ${IntervalSec}s, window ${WindowSec}s, ban ${BanMinutes}m)"

while ($true) {
  try {
    $now = Get-Date
    $limits = Get-Limits
    $xp = Get-Process xray-windows-amd64 -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($limits -and $xp) {
      if ($xp.Id -ne $xrayPid) { $xrayPid = $xp.Id; $applied = '' }   # Xray restarted: its rules were reset
      foreach ($email in @($bans.Keys)) {
        foreach ($ip in @($bans[$email].Keys)) { if ($bans[$email][$ip] -le $now) { $bans[$email].Remove($ip); Log "unblocked $email $ip" } }
        if (-not $limits.ContainsKey($email) -or $bans[$email].Count -eq 0) { $bans.Remove($email) }
      }
      foreach ($email in $limits.Keys) {
        foreach ($ip in (Get-OnlineIps $email)) {
          if (-not $firstSeen.ContainsKey("$email|$ip")) { $firstSeen["$email|$ip"] = $now }
          $lastSeen["$email|$ip"] = $now
        }
        $banned = if ($bans.ContainsKey($email)) { $bans[$email] } else { @{} }
        $recent = @()
        foreach ($k in @($lastSeen.Keys | Where-Object { $_ -like "$email|*" })) {
          $ip = ($k -split '\|', 2)[1]
          if (($now - $lastSeen[$k]).TotalSeconds -le $WindowSec) { $recent += $ip }
          elseif (-not $banned.ContainsKey($ip)) { $lastSeen.Remove($k); $firstSeen.Remove($k) }   # device went offline
        }
        $active = @($recent | Where-Object { -not $banned.ContainsKey($_) } | Sort-Object { $firstSeen["$email|$_"] })
        if ($active.Count -gt $limits[$email]) {
          $extra = $active | Select-Object -Skip $limits[$email]
          if (-not $bans.ContainsKey($email)) { $bans[$email] = @{} }
          foreach ($ip in $extra) {
            $bans[$email][$ip] = $now.AddMinutes($BanMinutes)
            $firstSeen["$email|$ip"] = $now.AddMinutes($BanMinutes)   # when it comes back it counts as the newest device
            Log "blocked $email $ip for ${BanMinutes}m (limit $($limits[$email]), online: $($active -join ', '))"
          }
        }
      }
      foreach ($k in @($lastSeen.Keys)) {   # forget accounts that no longer have a limit
        if (-not $limits.ContainsKey(($k -split '\|', 2)[0])) { $lastSeen.Remove($k); $firstSeen.Remove($k) }
      }
      $sig = ($bans.Keys | Sort-Object | ForEach-Object { "$_=" + (($bans[$_].Keys | Sort-Object) -join ',') }) -join ';'
      if ($sig -ne $applied) { if (Apply-Bans $bans) { $applied = $sig } }
    }
    if ($xp -and ($now - $lastProbe).TotalSeconds -ge 60) { $lastProbe = $now; Check-Warp }
  } catch { Log "error: $($_.Exception.Message)" }
  Start-Sleep $IntervalSec
}
