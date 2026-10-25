#Requires -Version 5.1
# herdr-quota-monitor.ps1: Windows port of bin/herdr-quota-monitor.sh. Keep the two in sync:
# same commands, providers, options and output. No jq/curl needed: PowerShell does JSON and HTTP.
param([string]$Cmd = '', [string]$Arg = '')
$ErrorActionPreference = 'Stop'

$PLUGIN = 'herdr-quota-monitor'
$TITLE = '~ AI usage Monitor ~' # dashboard heading
$HERDR = if ($env:HERDR_BIN_PATH) { $env:HERDR_BIN_PATH } else { 'herdr' }
$Inv = [Globalization.CultureInfo]::InvariantCulture
$Utf8 = New-Object Text.UTF8Encoding $false
$ESC = [char]27
# PowerShell variable names are case-insensitive: script-wide names must not collide with any function's locals
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
try { [Console]::OutputEncoding = $Utf8 } catch {}
if ([Console]::IsOutputRedirected) {
  $Sink = New-Object IO.StreamWriter([Console]::OpenStandardOutput(), $Utf8)
  $Sink.AutoFlush = $true
} else { $Sink = [Console]::Out }
function Emit([string]$s) { $Sink.Write($s) }

# State lives at a fixed path: herdr gives tab-bar and keybinding commands no HERDR_PLUGIN_STATE_DIR,
# and every entry point must see the same profiles and caches.
$StateDir = Join-Path $env:LOCALAPPDATA "herdr\plugins\$PLUGIN"
$ConfigDir = $env:HERDR_PLUGIN_CONFIG_DIR
if (-not $ConfigDir) { try { $ConfigDir = (& $HERDR plugin config-dir $PLUGIN 2>$null | Select-Object -First 1) } catch {} }
if (-not $ConfigDir) { $ConfigDir = Join-Path $env:APPDATA "herdr\plugins\config\$PLUGIN" }
$PayloadFile = Join-Path $StateDir 'payload.json'
$Chain = Join-Path $ConfigDir 'chain'
$ApiCache = Join-Path $StateDir 'api_cache'
New-Item -ItemType Directory -Force -Path $ApiCache | Out-Null

# Plugin config: the same NAME=value file as the bash version; it wins over environment variables.
$Options = @{}
$cfgFile = Join-Path $ConfigDir 'config'
if (Test-Path -LiteralPath $cfgFile) {
  foreach ($line in Get-Content -LiteralPath $cfgFile -Encoding UTF8) {
    if ($line -match '^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
      $name = $Matches[1]; $v = $Matches[2].Trim()
      if ($v -match '^"([^"]*)"') { $v = $Matches[1] }
      elseif ($v -match "^'([^']*)'") { $v = $Matches[1] }
      else { $v = $v -replace '\s+#.*$', '' }
      $Options[$name] = $v
    }
  }
}
function Opt([string]$name, $default = '') {
  if ($Options.ContainsKey($name)) { return $Options[$name] }
  $v = [Environment]::GetEnvironmentVariable($name)
  if ($v) { return $v }
  return $default
}

$STALE_SECS = [int](Opt 'STALE_SECS' 1800)
$BAR_HOT = [int](Opt 'BAR_HOT' 80)
$BAR_WARN = [int](Opt 'BAR_WARN' 50)
$BAR_GAUGE = Opt 'BAR_GAUGE' '0'
$BAR_GAUGE_W = [int](Opt 'BAR_GAUGE_W' 5)
$BAR_POSITION = Opt 'BAR_POSITION' 'top-right'
$TEXT_DIR = Opt 'TEXT_DIR' 'ltr'
$Rtl = $TEXT_DIR -eq 'rtl'

# ---------- shared helpers ----------
function Now { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
function Age([string]$f) {
  if (-not (Test-Path -LiteralPath $f)) { return 999999 }
  [int]((Get-Date) - (Get-Item -LiteralPath $f).LastWriteTime).TotalSeconds
}
function Write-Atomic([string]$path, [string]$text) {
  $tmp = "$path.tmp.$PID"
  [IO.File]::WriteAllText($tmp, $text, $Utf8)
  Move-Item -LiteralPath $tmp -Destination $path -Force
}
function Read-Json([string]$f) {
  if (-not (Test-Path -LiteralPath $f)) { return $null }
  try { return (Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}
function IsObj($x) { $x -is [System.Management.Automation.PSCustomObject] }
function RoundAway($x) { [math]::Round([double]$x, [MidpointRounding]::AwayFromZero) }
function Pctr($x) { [int][math]::Max(0, [math]::Min(100, (RoundAway $x))) }
function Usd($x) { '$' + ([math]::Round([double]$x, 2)).ToString($Inv) }
function ToEpoch($v) { # number (s or ms), ISO string or DateTime -> unix seconds, 0 if unknown
  if ($null -eq $v -or "$v" -eq '') { return 0 }
  if ($v -is [datetime]) { return ([DateTimeOffset]$v.ToUniversalTime()).ToUnixTimeSeconds() }
  if ($v -is [string]) {
    $n = 0.0
    if ([double]::TryParse($v, [Globalization.NumberStyles]::Float, $Inv, [ref]$n)) { $v = $n }
    else { try { return [DateTimeOffset]::Parse($v, $Inv).ToUnixTimeSeconds() } catch { return 0 } }
  }
  $d = [double]$v
  if ($d -gt 1e11) { $d = $d / 1000 }
  [long][math]::Floor($d)
}
function LocalTime([long]$e) { [DateTimeOffset]::FromUnixTimeSeconds($e).ToLocalTime() }
function Hour12([long]$e) { (LocalTime $e).ToString('htt', $Inv).ToLower() }
function Row($k, $u, $e, $r = '') { [pscustomobject]@{ k = $k; u = $u; e = [long]$e; r = $r } }
function Cap([string]$s) { if ($s) { $s.Substring(0, 1).ToUpper() + $s.Substring(1) } else { $s } }

# ---------- providers and keys ----------
# Keys come from <PROVIDER>_API_KEY (plugin config, then environment; `setup-keys` stores them as
# user environment variables). shortcut: Windows Credential Manager isn't read, add it if asked for.
$AGENT_PROVIDERS = 'codex', 'grok', 'droid', 'antigravity', 'cursor'
$API_PROVIDERS = @('claude') + $AGENT_PROVIDERS + @('openai', 'openrouter', 'llmapi', 'orcarouter', 'deepseek', 'moonshot', 'portkey', 'litellm', 'cloudflare', 'bedrock')

function Provider-Enabled([string]$p) { -not ((" " + (Opt 'DISABLED_PROVIDERS') + " ") -like "* $p *") }

function Key-Vars([string]$p) {
  switch ($p) {
    'claude' { 'ANTHROPIC_ADMIN_KEY', 'ANTHROPIC_API_KEY' }
    'openai' { 'OPENAI_ADMIN_KEY', 'OPENAI_API_KEY' }
    'cloudflare' { 'CLOUDFLARE_API_TOKEN' } # an API token; the legacy global key uses other headers
    default { $p.ToUpper() + '_API_KEY' }
  }
}

function Cursor-Token { # Cursor's saved login: auth.json, else the app's state DB (needs python)
  foreach ($f in @($env:CURSOR_AUTH_FILE, (Join-Path $env:USERPROFILE '.cursor\auth.json'))) {
    if ($f -and (Test-Path -LiteralPath $f)) { $j = Read-Json $f; if ($j) { return "$($j.accessToken)" }; return '' }
  }
  $db = Join-Path $env:APPDATA 'Cursor\User\globalStorage\state.vscdb'
  $py = Get-Command python -ErrorAction SilentlyContinue
  if (-not (Test-Path -LiteralPath $db) -or -not $py) { return '' }
  $code = 'import pathlib, sqlite3, sys; db = sqlite3.connect(pathlib.Path(sys.argv[1]).resolve().as_uri() + "?mode=ro", uri=True, timeout=0.2); row = db.execute("SELECT value FROM ItemTable WHERE key = ?", ("cursorAuth/accessToken",)).fetchone(); v = row[0] if row else ""; print((v.decode("utf-8", "ignore") if isinstance(v, bytes) else str(v)).strip())'
  try { return "$(& $py.Source -I -c $code $db 2>$null)".Trim() } catch { return '' }
}

function Get-ApiKey([string]$p) { # provider -> key (agents: their saved token, or a marker that local data exists)
  if (-not (Provider-Enabled $p)) { return '' }
  switch ($p) {
    'codex' {
      $h = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
      if (Test-Path -LiteralPath (Join-Path $h 'sessions')) { return 'local' }; return ''
    }
    { $_ -in 'droid', 'antigravity' } {
      $c = Get-Command $(if ($env:CODEXBAR_BIN) { $env:CODEXBAR_BIN } else { 'codexbar' }) -ErrorAction SilentlyContinue
      if ($c) { return $c.Source }; return ''
    }
    'cursor' { return (Cursor-Token) }
    'bedrock' { # Cost Explorer needs IAM credentials; the aws CLI does the request signing
      $c = Get-Command aws -ErrorAction SilentlyContinue
      if ($c -and ((Opt 'AWS_BEARER_TOKEN_BEDROCK') + (Opt 'AWS_PROFILE') + (Opt 'AWS_ACCESS_KEY_ID'))) { return $c.Source }; return ''
    }
    'cloudflare' { if (-not (Opt 'CLOUDFLARE_ACCOUNT_ID')) { return '' } } # then the token, as usual
    'grok' { # first entry of the Grok CLI login; skipped once expires_at (epoch or ISO) has passed
      $f = if ($env:GROK_AUTH_FILE) { $env:GROK_AUTH_FILE } else { Join-Path $env:USERPROFILE '.grok\auth.json' }
      $j = Read-Json $f
      if (-not (IsObj $j)) { return '' }
      $first = @($j.PSObject.Properties)[0].Value
      if (-not (IsObj $first) -or -not $first.key) { return '' }
      $t = ToEpoch $first.expires_at
      if ($t -gt 0 -and $t -le (Now)) { return '' }
      return "$($first.key)"
    }
  }
  foreach ($v in (Key-Vars $p)) { $k = Opt $v; if ($k) { return $k } }
  return ''
}

# ---------- API fetchers ----------
# Each provider is cached; a 4xx means this key can't read usage, which is cached too so the tab says so.
function Fetch-Api([string]$p, [string]$url, $headers = $null, $body = $null) {
  $key = Get-ApiKey $p
  if (-not $key) { return }
  $cache = Join-Path $ApiCache "$p.json"
  if ((Age $cache) -lt 300) { return }
  if (-not $headers) { $headers = @{ Authorization = 'Bearer {key}' } }
  $h = @{}
  foreach ($k in $headers.Keys) { $h[$k] = $headers[$k].Replace('{key}', $key) }
  $args_ = @{ Uri = $url; Headers = $h; TimeoutSec = 10; UseBasicParsing = $true; Method = 'GET' }
  if ($null -ne $body) { $args_.Method = 'POST'; $args_.Body = $body; $args_.ContentType = 'application/json' }
  try {
    $r = Invoke-WebRequest @args_
    $text = $Utf8.GetString($r.RawContentStream.ToArray())
    if (-not (IsObj ($text | ConvertFrom-Json))) { return }
    Write-Atomic $cache $text
  } catch {
    $code = 0
    try { $code = [int]$_.Exception.Response.StatusCode } catch {}
    if ($code -ge 400 -and $code -lt 500) { Write-Atomic $cache ('{"error":"HTTP ' + $code + '"}') }
  }
}

function Find-RateLimits($node) { # first .rate_limits object, in jq's `..` (pre-order) order
  if (IsObj $node) {
    if (IsObj $node.rate_limits) { return $node.rate_limits }
    foreach ($pr in $node.PSObject.Properties) { $f = Find-RateLimits $pr.Value; if ($f) { return $f } }
  } elseif ($node -is [array]) {
    foreach ($x in $node) { $f = Find-RateLimits $x; if ($f) { return $f } }
  }
  return $null
}

function Codex-Snapshot { # newest rate_limits in Codex's own session logs -> cache (no network)
  if (-not (Get-ApiKey 'codex')) { return }
  $cache = Join-Path $ApiCache 'codex.json'
  if ((Age $cache) -lt 60) { return }
  $h = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
  $since = (Get-Date).AddDays(-31)
  $files = Get-ChildItem -LiteralPath (Join-Path $h 'sessions') -Recurse -Filter '*.jsonl' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -gt $since } | Sort-Object LastWriteTime -Descending | Select-Object -First 5
  foreach ($f in $files) {
    $m = Select-String -LiteralPath $f.FullName -Pattern '"rate_limits"' -SimpleMatch -ErrorAction SilentlyContinue | Select-Object -Last 1
    if (-not $m) { continue }
    try { $j = $m.Line | ConvertFrom-Json } catch { continue }
    $rl = Find-RateLimits $j
    if (-not $rl) { continue }
    Write-Atomic $cache ([pscustomobject]@{ timestamp = $j.timestamp; rate_limits = $rl } | ConvertTo-Json -Depth 20 -Compress)
    return
  }
}

function Cli-Refresh([string]$p) { # slow CLIs (CodexBar, aws); only a usable answer replaces the cache
  $bin = Get-ApiKey $p
  if (-not $bin) { return }
  $cache = Join-Path $ApiCache "$p.json"
  if ($p -eq 'bedrock') {
    if ((Age $cache) -lt 21600) { return } # Cost Explorer bills $0.01 per call and updates about daily
    $start = (Get-Date).ToUniversalTime().ToString('yyyy-MM-01', $Inv)
    $end = (Get-Date).ToUniversalTime().AddDays(1).ToString('yyyy-MM-dd', $Inv)
    $cliArgs = @('ce', 'get-cost-and-usage', '--region', 'us-east-1', '--output', 'json', '--time-period', "Start=$start,End=$end",
      '--granularity', 'MONTHLY', '--metrics', 'UnblendedCost', '--group-by', 'Type=DIMENSION,Key=SERVICE')
  } else {
    if ((Age $cache) -lt 300) { return }
    $cliArgs = @('usage', '--format', 'json', '--provider', $(if ($p -eq 'droid') { 'factory' } else { $p }), '--no-color')
  }
  try { $text = (& $bin @cliArgs 2>$null) -join "`n" } catch { return }
  try { $j = $text | ConvertFrom-Json } catch { return }
  if ($p -eq 'bedrock') { $ok = $j.ResultsByTime -is [array] }
  else {
    $cb = if ($p -eq 'droid') { 'factory' } else { $p }
    $ok = @(@($j) | Where-Object { $_.provider -eq $cb -and (IsObj $_.usage) -and $_.source -ne 'offline' }).Count -gt 0
  }
  if ($ok) { Write-Atomic $cache $text }
}

function Refresh-All {
  if ((Opt 'USE_API' '1') -ne '1') { return }
  Codex-Snapshot
  Cli-Refresh 'droid'
  Cli-Refresh 'antigravity'
  Cli-Refresh 'bedrock'
  $now = [DateTimeOffset]::UtcNow
  $m0 = New-Object DateTimeOffset($now.Year, $now.Month, 1, 0, 0, 0, [TimeSpan]::Zero)
  $iso = $m0.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", $Inv)
  $nowIso = $now.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", $Inv)
  Fetch-Api 'claude' "https://api.anthropic.com/v1/organizations/cost_report?starting_at=$iso&bucket_width=1d&limit=31" @{ 'x-api-key' = '{key}'; 'anthropic-version' = '2023-06-01' }
  Fetch-Api 'grok' 'https://cli-chat-proxy.grok.com/v1/billing?format=credits' @{ Authorization = 'Bearer {key}'; 'x-xai-token-auth' = 'xai-grok-cli'; Accept = 'application/json' }
  Fetch-Api 'cursor' 'https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage' @{ Authorization = 'Bearer {key}'; 'Connect-Protocol-Version' = '1' } '{}'
  Fetch-Api 'openai' "https://api.openai.com/v1/organization/costs?start_time=$($m0.ToUnixTimeSeconds())&bucket_width=1d&limit=31"
  Fetch-Api 'openrouter' 'https://openrouter.ai/api/v1/key'
  Fetch-Api 'llmapi' 'https://api.llmapi.ai/v1/credits'
  Fetch-Api 'orcarouter' 'https://api.orcarouter.ai/v1/tools/balance'
  Fetch-Api 'deepseek' 'https://api.deepseek.com/user/balance'
  Fetch-Api 'moonshot' 'https://api.moonshot.ai/v1/users/me/balance'
  Fetch-Api 'portkey' "https://api.portkey.ai/v1/analytics/graphs/cost?time_of_generation_min=$iso&time_of_generation_max=$nowIso" @{ 'x-portkey-api-key' = '{key}' }
  $base = Opt 'LITELLM_BASE_URL' 'http://localhost:4000'
  Fetch-Api 'litellm' "$base/key/info"
  # GraphQL variables keep the account id out of the query text
  $q = @{ variables = @{ a = (Opt 'CLOUDFLARE_ACCOUNT_ID'); s = $iso; e = $nowIso }
    query = 'query($a: string!, $s: Time!, $e: Time!) { viewer { accounts(filter: {accountTag: $a}) { aiGatewayRequestsAdaptiveGroups(limit: 1, filter: {datetimeHour_geq: $s, datetimeHour_leq: $e}) { count sum { cost } } } } }' }
  Fetch-Api 'cloudflare' 'https://api.cloudflare.com/client/v4/graphql' $null ($q | ConvertTo-Json -Depth 5 -Compress)
}

function Spawn-Refresh { # the tab bar never waits on the network: a hidden worker refreshes caches for the next tick
  $lock = Join-Path $ApiCache 'refresh.lock'
  if ((Age $lock) -lt 120 -or (Age (Join-Path $ApiCache 'refresh.stamp')) -lt 60) { return }
  [IO.File]::WriteAllText($lock, "$PID")
  try {
    Start-Process -FilePath (Get-Process -Id $PID).Path -WindowStyle Hidden `
      -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", 'refresh')
  } catch { Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue }
}

# ---------- rows ----------
function Wlabel($m) {
  if ($null -eq $m) { return 'usage' }
  switch ([int]$m) { 300 { return '5h' } 10080 { return 'week' } 43200 { return 'month' } }
  return "$(RoundAway ($m / 60))h"
}

# Claude statusLine windows: rows k/u/e, five_hour first, then seven_day, then the rest
function Windows-Of([string]$file) {
  $j = Read-Json $file
  if (-not $j) { return }
  $rl = if (IsObj $j.rate_limits) { $j.rate_limits } else { $j }
  $i = 0
  $rows = foreach ($pr in $rl.PSObject.Properties) {
    $v = $pr.Value
    if (-not (IsObj $v)) { continue }
    $u = if ($null -ne $v.used_percentage) { $v.used_percentage } else { $v.utilization }
    if ($null -eq $u) { continue }
    $r = $v.resets_at
    $e = if ($r -is [string]) { (ToEpoch $r) + $(if ($r -match '\.[0-9]') { 1 } else { 0 }) } else { ToEpoch $r }
    $o = switch ($pr.Name) { 'five_hour' { 0 } 'seven_day' { 1 } default { 2 } }
    [pscustomobject]@{ k = $pr.Name; u = [int](RoundAway $u); e = $e; o = $o; i = ($i++) }
  }
  $rows | Sort-Object o, i
}

function Provider-Rows([string]$p, $j) {
  if ($j -isnot [array] -and $j.error) { return (Row "${p}:error" '-' 0 "$($j.error) · key has no usage access") }
  switch ($p) {
    'openrouter' {
      $d = $j.data; $b = $d.effective_budget
      if ($b -and [double]$b.limit_usd -gt 0) {
        $iv = if ($b.reset_interval) { $b.reset_interval } else { 'budget' }
        Row "openrouter:$iv" ([math]::Min(100, (RoundAway ([double]$b.spend_usd * 100 / [double]$b.limit_usd)))) (ToEpoch $b.resets_at) ((Usd $b.spend_usd) + '/' + (Usd $b.limit_usd))
      } else { Row 'openrouter:spend' '-' 0 ((Usd $d.usage) + ' used') }
      $f = $d.free_model_daily_requests
      if ($f -and [double]$f.limit -gt 0) { # shortcut: assumes UTC-midnight reset, fix if OpenRouter says otherwise
        Row 'openrouter:free/day' ([math]::Min(100, (RoundAway ([double]$f.used * 100 / [double]$f.limit)))) (([math]::Floor((Now) / 86400) + 1) * 86400) "$($f.used)/$($f.limit) req"
      }
    }
    'codex' {
      foreach ($w in @($j.rate_limits.primary, $j.rate_limits.secondary)) {
        if (-not (IsObj $w)) { continue }
        $r = if ($null -ne $w.resets_at) { ToEpoch $w.resets_at } elseif ($w.resets_in_seconds) { (ToEpoch $j.timestamp) + [long]$w.resets_in_seconds } else { 0 }
        $u = if ($r -gt 0 -and $r -lt (Now)) { 0 } else { $w.used_percent }
        Row ('codex:' + (Wlabel $w.window_minutes)) (Pctr $u) $r
      }
    }
    'grok' {
      foreach ($s in @($j.config, $j)) {
        if (-not (IsObj $s)) { continue }
        $v = $s.creditUsagePercent
        if ($null -eq $v -and [double]$s.onDemandCap.val -gt 0) { $v = [double]$s.onDemandUsed.val * 100 / [double]$s.onDemandCap.val }
        if ($null -ne $v) { Row 'grok:credits' (Pctr $v) 0; break }
      }
    }
    { $_ -in 'droid', 'antigravity' } {
      $cb = if ($p -eq 'droid') { 'factory' } else { $p }
      foreach ($en in @($j)) {
        if ($en.provider -ne $cb -or $en.source -eq 'offline') { continue }
        $u = $en.usage; $ws = @()
        foreach ($k in 'primary', 'secondary', 'tertiary') { if (IsObj $u.$k) { $ws += , @($u.$k, (Wlabel $u.$k.windowMinutes)) } }
        foreach ($x in @($u.extraRateWindows)) {
          if ((IsObj $x) -and $x.usageKnown -ne $false) { $ws += , @($x.window, $(if ($x.title) { $x.title } else { $x.id })) }
        }
        foreach ($pair in $ws) {
          $w = $pair[0]
          if ((IsObj $w) -and $w.usageKnown -ne $false -and $null -ne $w.usedPercent) { Row "${p}:$($pair[1])" (Pctr $w.usedPercent) (ToEpoch $w.resetsAt) }
        }
      }
    }
    'cursor' {
      $pu = $j.planUsage
      if (IsObj $pu) {
        $l = [double]$pu.limit; $inc = $pu.totalPercentUsed
        if ($null -eq $inc -and $l -gt 0) {
          $x = $pu.includedSpend
          if ($null -eq $x -and $null -ne $pu.remaining) { $x = $l - [double]$pu.remaining }
          if ($null -eq $x) { $x = $pu.used }
          if ($null -ne $x) { $inc = [double]$x * 100 / $l }
        }
        if ($null -ne $inc) { Row 'cursor:included' (Pctr $inc) 0 }
        if ($null -ne $pu.autoPercentUsed) { Row 'cursor:auto' (Pctr $pu.autoPercentUsed) 0 }
        if ($null -ne $pu.apiPercentUsed) { Row 'cursor:api' (Pctr $pu.apiPercentUsed) 0 }
      }
    }
    'llmapi' { Row 'llmapi:credits' '-' 0 ((Usd $j.total_credits) + ' left') }
    'orcarouter' { $v = if ($null -ne $j.data.spendable_usd) { $j.data.spendable_usd } else { $j.data.wallet_usd }; Row 'orcarouter:wallet' '-' 0 ((Usd $v) + ' left') }
    'deepseek' { foreach ($bi in @($j.balance_infos)) { if ($bi) { Row 'deepseek:balance' '-' 0 "$($bi.total_balance) $($bi.currency) left" } } }
    'moonshot' { Row 'moonshot:balance' '-' 0 ((Usd $j.data.available_balance) + ' left') }
    'openai' { $s = 0.0; foreach ($b in @($j.data)) { foreach ($r in @($b.results)) { $s += [double]$r.amount.value } }; Row 'openai:month' '-' 0 ((Usd $s) + ' this month') }
    'portkey' { Row 'portkey:month' '-' 0 ((Usd ([double]$j.summary.total / 100)) + ' this month') } # cents
    'litellm' {
      $i = if (IsObj $j.info) { $j.info } else { $j }
      if ([double]$i.max_budget -gt 0) { Row 'litellm:budget' (Pctr ([double]$i.spend * 100 / [double]$i.max_budget)) (ToEpoch $i.budget_reset_at) ((Usd $i.spend) + '/' + (Usd $i.max_budget)) }
      else { Row 'litellm:spend' '-' 0 ((Usd $i.spend) + ' used') }
    }
    'cloudflare' {
      if ($j.errors -and @($j.errors).Count -gt 0) { Row 'cloudflare:error' '-' 0 "$(@($j.errors)[0].message)" }
      else {
        $g = @(@($j.data.viewer.accounts)[0].aiGatewayRequestsAdaptiveGroups)[0]
        $n = if ($null -ne $g.count) { $g.count } else { 0 }
        Row 'cloudflare:month' '-' 0 ((Usd $g.sum.cost) + " this month · $n req")
      }
    }
    'bedrock' { # Marketplace models bill as "<model> (Amazon Bedrock Edition)"
      $s = 0.0
      foreach ($t in @($j.ResultsByTime)) { foreach ($g in @($t.Groups)) { if ($g -and "$($g.Keys[0])" -match 'Bedrock') { $s += [double]$g.Metrics.UnblendedCost.Amount } } }
      Row 'bedrock:month' '-' 0 ((Usd $s) + ' this month')
    }
    'claude' { $s = 0.0; foreach ($b in @($j.data)) { foreach ($r in @($b.results)) { $s += [double]$r.amount } }; Row 'claude:API month' '-' 0 ((Usd ($s / 100)) + ' this month') } # cents
  }
}

# API usage rows: k/u/e/r, u "-" = no bar (balance only)
function Api-Rows {
  foreach ($p in $API_PROVIDERS) {
    $c = Join-Path $ApiCache "$p.json"
    if ((Age $c) -ge $(if ($p -eq 'bedrock') { 43200 } else { 3600 })) { continue }
    if (-not (Get-ApiKey $p)) { continue }
    $j = Read-Json $c
    if ($null -eq $j) { continue }
    try { Provider-Rows $p $j } catch {}
  }
}

function Provider-Name([string]$p) {
  switch ($p) {
    'all' { 'All' } 'claude' { 'Claude' } 'openai' { 'OpenAI' } 'openrouter' { 'OpenRouter' } 'llmapi' { 'llmapi.ai' }
    'orcarouter' { 'OrcaRouter' } 'deepseek' { 'DeepSeek' } 'moonshot' { 'Moonshot' } 'codex' { 'Codex' } 'grok' { 'Grok' }
    'droid' { 'Droid' } 'antigravity' { 'Antigravity' } 'cursor' { 'Cursor' } 'portkey' { 'Portkey' } 'litellm' { 'LiteLLM' }
    'cloudflare' { 'CF AI Gateway' } 'bedrock' { 'Bedrock' } default { $p }
  }
}

function Label-For([string]$k) {
  if ($k -eq 'five_hour') { return 'Session (5h)' }
  if ($k -eq 'seven_day') { return 'Week · all models' }
  if ($k -like 'seven_day_*') { return 'Week · ' + (Cap $k.Substring(10)) }
  if ($k -eq 'spend') { return 'Extra usage' }
  if ($k -like '*:*') { $i = $k.IndexOf(':'); return (Provider-Name $k.Substring(0, $i)) + ' · ' + $k.Substring($i + 1) }
  return $k
}

function Rel-Time([long]$e) { # "2h04m" / "45m" / "2d3h"
  $d = [math]::Max(0, $e - (Now))
  if ($d -ge 86400) { return '{0}d{1}h' -f [math]::Floor($d / 86400), [math]::Floor($d % 86400 / 3600) }
  if ($d -ge 3600) { return '{0}h{1:00}m' -f [math]::Floor($d / 3600), [math]::Floor($d % 3600 / 60) }
  return '{0}m' -f [math]::Floor($d / 60)
}

function Abs-Time([long]$e) { # "3pm" today, "Wed 6pm" otherwise
  $t = LocalTime $e
  if ($t.Date -eq (Get-Date).Date) { return (Hour12 $e) }
  return $t.ToString('ddd', $Inv) + ' ' + (Hour12 $e)
}

function Unit-For([string]$k) { # window key or sub-label -> compact suffix, as in 13%m, 50%w, 45%h
  if ($k -eq 'five_hour' -or $k -like '*5h*' -or $k -like '*5-hour*' -or $k -like '*hour*') { return 'h' }
  if ($k -eq 'seven_day') { return 'w' }
  if ($k -like 'seven_day_*') { return 'w(' + (Cap $k.Substring(10)) + ')' }
  if ($k -like '*week*') { return 'w' }
  if ($k -like '*month*') { return 'm' }
  if ($k -like '*day*' -or $k -like '*daily*') { return 'd' }
  if ($k -in 'included', 'credits', 'budget', 'usage', 'spend', 'wallet', 'balance') { return '' } # the provider's main number
  return "($k)"
}

function Gauge([int]$pct) { # ██░░░, filled from the right in rtl
  $f = [math]::Floor(($pct * $BAR_GAUGE_W + 50) / 100)
  if ($pct -gt 0 -and $f -eq 0) { $f = 1 }
  if ($f -gt $BAR_GAUGE_W) { $f = $BAR_GAUGE_W }
  if ($Rtl) { ('░' * ($BAR_GAUGE_W - $f)) + ('█' * $f) } else { ('█' * $f) + ('░' * ($BAR_GAUGE_W - $f)) }
}

function Fmt-Pct([int]$pct, [string]$unit = '') { # "13%m", "⚠️" above BAR_HOT, gauge when BAR_GAUGE=1
  $v = "$pct%$unit"
  if ($pct -gt $BAR_HOT) { $v += '⚠️' }
  if ($BAR_GAUGE -eq '1') { if ($Rtl) { $v = "$v $(Gauge $pct)" } else { $v = "$(Gauge $pct) $v" } }
  $v
}

function Herdr-Width { # width of the focused tab's area, from herdr's own snapshot
  try {
    $s = (& $HERDR api snapshot 2>$null | Out-String | ConvertFrom-Json).result.snapshot
    return [int](@($s.layouts | Where-Object { $_.tab_id -eq $s.focused_tab_id })[0].area.width)
  } catch { return 0 }
}

# ---------- profiles ----------
function Profiles-Ranked { # f/n/mt/names, most active first
  if (-not (Provider-Enabled 'claude')) { return }
  $cut = (Now) - $STALE_SECS
  $dir = Join-Path $StateDir 'profiles'
  if (-not (Test-Path -LiteralPath $dir)) { return }
  $list = foreach ($f in Get-ChildItem -LiteralPath $dir -Filter '*.json' -File) {
    $mt = ([DateTimeOffset]$f.LastWriteTimeUtc).ToUnixTimeSeconds()
    if ($mt -lt $cut) { continue }
    $n = 0; $names = ''
    $s = [IO.Path]::ChangeExtension($f.FullName, '.sessions')
    if (Test-Path -LiteralPath $s) {
      $live = @(Get-Content -LiteralPath $s -Encoding UTF8 | ForEach-Object { , ($_ -split "`t") } | Where-Object { $_.Count -ge 2 -and [long]$_[1] -ge $cut })
      $n = $live.Count
      $names = (@($live | ForEach-Object { if ($_.Count -ge 3) { $_[2] } } | Sort-Object -Unique) | Select-Object -First 3) -join ','
    }
    [pscustomobject]@{ f = $f.FullName; n = $n; mt = $mt; names = $names }
  }
  $list | Sort-Object @{ e = 'n'; Descending = $true }, @{ e = 'mt'; Descending = $true }
}

# ---------- collect: statusLine hook (invoked by Claude Code, not manually) ----------
function Git-Bash { # Claude Code on Windows runs commands in Git Bash; bash.exe on PATH is often WSL's
  foreach ($b in @($env:CLAUDE_CODE_GIT_BASH_PATH, (Join-Path $env:ProgramFiles 'Git\bin\bash.exe'))) {
    if ($b -and (Test-Path -LiteralPath $b)) { return $b }
  }
  return $null
}

function Collect {
  $payload = (New-Object IO.StreamReader([Console]::OpenStandardInput(), $Utf8)).ReadToEnd()
  if ($payload) {
    Write-Atomic $PayloadFile $payload
    try { $j = $payload | ConvertFrom-Json } catch { $j = $null }
    $rk = $null
    if ($j) { $rk = $j.rate_limits.seven_day.resets_at; if ($null -eq $rk) { $rk = $j.rate_limits.five_hour.resets_at } }
    if ($null -ne $rk -and "$rk" -ne '0') {
      $key = "$rk" -replace '[^\w.-]', '_' # ISO timestamps carry ':' which Windows file names can't
      $pdir = Join-Path $StateDir 'profiles'
      New-Item -ItemType Directory -Force -Path $pdir | Out-Null
      $pfile = Join-Path $pdir "$key.json"
      $stored = $payload
      $old = Read-Json $pfile
      if ($old -and $null -eq $j.rate_limits.five_hour -and $null -ne $old.rate_limits.five_hour -and (ToEpoch $old.rate_limits.five_hour.resets_at) -gt (Now)) {
        # Claude Code sometimes omits five_hour; keep the previous unexpired window
        $j.rate_limits | Add-Member -NotePropertyName five_hour -NotePropertyValue $old.rate_limits.five_hour -Force
        $stored = $j | ConvertTo-Json -Depth 50 -Compress
      }
      Write-Atomic $pfile $stored
      if ($j.session_id) {
        $sfile = Join-Path $pdir "$key.sessions"
        $lines = @()
        if (Test-Path -LiteralPath $sfile) { $lines = @(Get-Content -LiteralPath $sfile -Encoding UTF8 | Where-Object { $_ -notlike "$($j.session_id)`t*" }) }
        $cwd = @("$($j.cwd)" -split '[\\/]')[-1]
        $lines += "$($j.session_id)`t$(Now)`t$cwd"
        Write-Atomic $sfile (($lines -join "`n") + "`n")
      }
    }
  }
  if (Test-Path -LiteralPath $Chain) { # pass stdin and stdout through to the previous statusLine
    $chainCmd = [IO.File]::ReadAllText($Chain, $Utf8)
    $bash = Git-Bash
    $psi = New-Object Diagnostics.ProcessStartInfo
    if ($bash) { $psi.FileName = $bash; $psi.Arguments = '-c "' + $chainCmd.Replace('\', '\\').Replace('"', '\"') + '"' }
    else { $psi.FileName = 'cmd.exe'; $psi.Arguments = "/d /c $chainCmd" }
    $psi.UseShellExecute = $false; $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true
    $psi.StandardOutputEncoding = $Utf8
    try {
      $proc = [Diagnostics.Process]::Start($psi)
      $bytes = $Utf8.GetBytes($payload)
      $proc.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
      $proc.StandardInput.Close()
      Emit $proc.StandardOutput.ReadToEnd()
      $proc.WaitForExit()
    } catch {}
  }
}

# ---------- bar: one-line summary for the Herdr tab bar ----------
function Bar-Name([string]$p) { switch ($p) { 'openrouter' { 'OR' } 'llmapi' { 'LLMAPI' } default { Provider-Name $p } } }

function Bar {
  Spawn-Refresh
  $ranked = @(Profiles-Ranked)
  $primary = if ($ranked.Count) { $ranked[0].f } else { $null }
  $items = New-Object Collections.Generic.List[object]
  if ($primary) {
    $ws = @(Windows-Of $primary)
    if (-not ($ws | Where-Object { $_.k -eq 'five_hour' })) { $items.Add(@('claude', (Fmt-Pct 0 'h'))) }
    foreach ($w in $ws) {
      $v = Fmt-Pct $w.u (Unit-For $w.k)
      if ($w.k -eq 'five_hour' -and $w.e -gt 0) { $v = "$v ↻ $(Hour12 $w.e)" }
      $items.Add(@('claude', $v))
    }
  }
  foreach ($r in @(Api-Rows)) {
    $i = $r.k.IndexOf(':'); $p = $r.k.Substring(0, $i); $sub = $r.k.Substring($i + 1)
    if ($sub -eq 'error') { continue }
    $v = if ("$($r.u)" -eq '-') { $r.r } else { Fmt-Pct $r.u (Unit-For $sub) }
    $items.Add(@($p, $v))
  }

  # one "Name: v v" part per provider; rtl reads "v v :Name" and runs right to left
  $parts = New-Object Collections.Generic.List[string]
  $last = ''; $vals = ''
  $items.Add(@('', '')) # sentinel: flushes the last provider
  foreach ($it in $items) {
    if ($it[0] -ne $last -and $last) {
      if ($Rtl) { $parts.Insert(0, "$vals :$(Bar-Name $last)") } else { $parts.Add("$(Bar-Name $last): $vals") }
      $vals = ''
    }
    $last = $it[0]
    if (-not $last) { continue }
    if ($Rtl) { $vals = if ($vals) { "$($it[1]) $vals" } else { $it[1] } } else { $vals = if ($vals) { "$vals $($it[1])" } else { $it[1] } }
  }
  $out = if ($parts.Count) { $parts -join ' · ' } else { 'LLM —' }
  if ($Rtl) { $out = "$out  ✳"; if ($ranked.Count -gt 1) { $out = "⁺ $out" } }
  else { $out = "✳  $out"; if ($ranked.Count -gt 1) { $out = "$out ⁺" } }
  # herdr right-aligns the entry; trailing spaces push it to the middle of the row
  if ($BAR_POSITION -like '*-center') {
    $pad = [math]::Floor(((Herdr-Width) - $out.Length) / 2)
    if ($pad -gt 0) { $out += ' ' * $pad }
  }
  Emit $out
}

# ---------- dashboard: pretty popup ----------
$BAR_W = 34
$LINE_W = 39
$dim = "$ESC[2m"; $rst = "$ESC[0m"; $bold = "$ESC[1m"

function Draw-One([string]$key, $used, [long]$epoch, [string]$right = '') {
  $label = Label-For $key
  if ($epoch -gt 0) {
    if (-not $right) { $right = "↻ $(Rel-Time $epoch) · $(Abs-Time $epoch)" } else { $right = "$right · ↻ $(Rel-Time $epoch)" }
  }
  $pad = [math]::Max(1, $LINE_W - $label.Length - $right.Length)
  if ($Rtl) { Emit ("`n  $dim$right$rst" + (' ' * $pad) + "$bold$label$rst`n") }
  else { Emit ("`n  $bold$label$rst" + (' ' * $pad) + "$dim$right$rst`n") }
  if ("$used" -eq '-') { return }
  $used = [int]$used
  $color = if ($used -ge $BAR_HOT) { "$ESC[38;5;210m" } elseif ($used -ge $BAR_WARN) { "$ESC[38;5;222m" } else { "$ESC[38;5;147m" }
  $filled = [math]::Min($BAR_W, [math]::Floor($used * $BAR_W / 100))
  if ($used -gt 0 -and $filled -eq 0) { $filled = 1 }
  $tick = [math]::Min($BAR_W - 1, [math]::Floor($BAR_W * $BAR_HOT / 100))
  $cells = ''
  for ($i = 0; $i -lt $BAR_W; $i++) {
    $cell = if ($i -lt $filled) { '█' } elseif ($i -eq $tick) { "$ESC[38;5;243m┊$color" } else { "$ESC[38;5;238m░$color" }
    if ($Rtl) { $cells = "$cell$cells" } else { $cells += $cell } # rtl fills from the right
  }
  if ($Rtl) { Emit ("  {0,3}% $color$cells$rst`n" -f $used) } else { Emit ("  $color$cells$rst {0,3}%`n" -f $used) }
}

function Draw([int]$tabIndex = 0) {
  Refresh-All
  $ranked = @(Profiles-Ranked)
  $primary = if ($ranked.Count) { $ranked[0].f } else { $null }
  $apirows = @(Api-Rows)
  # One tab per provider with data, in API_PROVIDERS order; claude also when statusLine data exists.
  $tabs = New-Object Collections.Generic.List[string]
  $tabs.Add('all')
  if ($primary) { $tabs.Add('claude') }
  foreach ($r in $apirows) { $p = $r.k.Substring(0, $r.k.IndexOf(':')); if (-not $tabs.Contains($p)) { $tabs.Add($p) } }
  $n = $tabs.Count
  $tab = $tabs[(($tabIndex % $n) + $n) % $n]
  $strip = ''
  foreach ($t in $tabs) {
    $s = if ($t -eq $tab) { "$ESC[7m $(Provider-Name $t) $rst" } else { "$dim $(Provider-Name $t) $rst" }
    if ($Rtl) { $strip = "$s$strip" } else { $strip += $s }
  }

  if (-not $primary -or ($tab -ne 'all' -and $tab -ne 'claude')) {
    Emit "`n  $bold$TITLE$rst`n"
    if ($n -gt 1) { Emit "`n  $strip`n" }
    if (-not $apirows.Count -and -not $primary) { Emit "`n  ${dim}No fresh data. Run a Claude Code session or set <PROVIDER>_API_KEY.$rst`n" }
  } else {
    $age = Age $primary
    $agetxt = if ($age -lt 120) { "${age}s ago" } else { "$([math]::Floor($age / 60))m ago" }
    Emit "`n  $bold$TITLE$rst   $dim$agetxt · $($ranked[0].n) session(s) · $([TimeZoneInfo]::Local.Id)$rst`n"
    Emit "`n  $strip`n"
    $ws = @(Windows-Of $primary)
    if (-not ($ws | Where-Object { $_.k -eq 'five_hour' })) { Draw-One 'five_hour' 0 0 }
    foreach ($w in $ws) { Draw-One $w.k $w.u $w.e }
  }

  foreach ($r in $apirows) {
    if ($tab -ne 'all' -and $r.k.Substring(0, $r.k.IndexOf(':')) -ne $tab) { continue }
    Draw-One $r.k $r.u $r.e $r.r
  }

  # Other signed-in profiles, compact.
  if ($tab -ne 'all' -and $tab -ne 'claude') { return }
  foreach ($pr in $ranked) {
    if ($pr.f -eq $primary) { continue }
    $ws = @(Windows-Of $pr.f)
    $s = ($ws | Where-Object { $_.k -eq 'five_hour' } | Select-Object -First 1).u
    $w = ($ws | Where-Object { $_.k -eq 'seven_day' } | Select-Object -First 1).u
    $line = "5h $(if ($null -eq $s) { '?' } else { $s })% · wk $(if ($null -eq $w) { '?' } else { $w })%"
    Emit "`n  $dim◦ $line · other profile ($($pr.n) session(s)$(if ($pr.names) { " · $($pr.names)" }))$rst`n"
  }
}

function Dashboard {
  try { # make sure the console interprets the ANSI colors
    Add-Type -Namespace HQM -Name Con -MemberDefinition '[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int h); [DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr h, out int m); [DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr h, int m);'
    $h = [HQM.Con]::GetStdHandle(-11); $m = 0
    if ([HQM.Con]::GetConsoleMode($h, [ref]$m)) { [void][HQM.Con]::SetConsoleMode($h, $m -bor 4) }
  } catch {}
  $tab = 0
  while ($true) {
    Emit "$ESC[H$ESC[2J"
    Draw $tab
    Emit "`n  $dim←/→ tab · 1-9 jump · q close · any key refresh · auto 30s$rst`n"
    $deadline = (Get-Date).AddSeconds(30); $k = $null
    while ((Get-Date) -lt $deadline) {
      if ([Console]::KeyAvailable) { $k = [Console]::ReadKey($true); break }
      Start-Sleep -Milliseconds 100
    }
    if (-not $k) { continue }
    if ($k.KeyChar -in 'q', 'Q' -or $k.Key -eq 'Escape') { break }
    if ($k.Key -eq 'RightArrow' -or $k.KeyChar -eq 'l' -or ($k.Key -eq 'Tab' -and -not ($k.Modifiers -band [ConsoleModifiers]::Shift))) { $tab++ }
    elseif ($k.Key -eq 'LeftArrow' -or $k.KeyChar -eq 'h' -or $k.Key -eq 'Tab') { $tab-- }
    elseif ($k.KeyChar -match '^[1-9]$') { $tab = [int]"$($k.KeyChar)" - 1 }
  }
}

# ---------- herdr config ----------
function Herdr-Cfg { if ($env:HERDR_CONFIG_PATH) { $env:HERDR_CONFIG_PATH } else { Join-Path $env:APPDATA 'herdr\config.toml' } }
function Read-Lines([string]$f) { if (Test-Path -LiteralPath $f) { @(Get-Content -LiteralPath $f -Encoding UTF8) } else { @() } }
function Write-Lines([string]$f, $lines) { Write-Atomic $f ((@($lines) -join "`n") + "`n") }
function Ps-Command([string]$sub) { "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" $sub" }

function Herdr-Position([string]$cfg) { # herdr's tab_bar_position follows BAR_POSITION's top-/bottom- half
  if ($BAR_POSITION -notin 'top-right', 'top-center', 'bottom-right', 'bottom-center') {
    Write-Host "BAR_POSITION=$BAR_POSITION not supported: herdr only has a right-aligned, one-line slot in the tab row."
    Write-Host 'Use top-right, top-center, bottom-right or bottom-center.'
    return $false
  }
  $want = $BAR_POSITION.Split('-')[0]
  $lines = Read-Lines $cfg
  $has = @($lines | Where-Object { $_ -match '^\s*tab_bar_position' }).Count -gt 0
  if (-not $has -and $want -eq 'top') { return $true } # top is herdr's default
  # an existing line is edited in place (kept on uninstall); a new one carries our marker
  $outl = New-Object Collections.Generic.List[string]; $done = $false
  foreach ($l in $lines) {
    if ($has -and $l -match '^\s*tab_bar_position') { $outl.Add("tab_bar_position = `"$want`"" + $(if ($l -like "*# $PLUGIN*") { " # $PLUGIN" } else { '' })); continue }
    $outl.Add($l)
    if (-not $has -and -not $done -and $l -match '^\[ui\]') { $outl.Add("tab_bar_position = `"$want`" # $PLUGIN"); $done = $true }
  }
  Write-Lines $cfg $outl
  Write-Host "herdr tab bar at the $want (tab_bar_position)"
  return $true
}

function Herdr-Reload { try { return (& $HERDR server reload-config 2>$null | Out-String) } catch { return '' } }

function Herdr-Config {
  $cfg = Herdr-Cfg
  New-Item -ItemType Directory -Force -Path (Split-Path $cfg) | Out-Null
  if (-not (Test-Path -LiteralPath $cfg)) { Write-Lines $cfg @() }
  $lines = Read-Lines $cfg
  if ($lines -match [regex]::Escape($PLUGIN)) {
    Write-Host "herdr config already has the $PLUGIN entries"
    if (Herdr-Position $cfg) { Herdr-Reload | Out-Null }
    return
  }
  if ($PSCommandPath.Contains("'")) { Write-Host "The script path contains a quote; add the entries manually (see README)."; return }
  $bak = "$cfg.bak-quota-monitor"
  Copy-Item -LiteralPath $cfg -Destination $bak -Force
  # TOML literal strings ('...') keep the Windows path's backslashes and quotes as they are
  $barEntry = "{ type = `"command`", command = '$(Ps-Command 'bar')', interval_seconds = 30, timeout_seconds = 10 }"
  $barLine = "tab_bar_right = [ $barEntry ] # $PLUGIN"
  $outl = New-Object Collections.Generic.List[string]
  if ($lines -match '^\s*tab_bar_right') {
    Write-Host 'config already defines tab_bar_right; add this entry to it yourself:'
    Write-Host "  $barEntry"
    $lines | ForEach-Object { $outl.Add($_) }
  } elseif ($lines -match '^\[ui\]\s*$') {
    $done = $false
    foreach ($l in $lines) { $outl.Add($l); if (-not $done -and $l -match '^\[ui\]\s*$') { $outl.Add($barLine); $done = $true } }
  } else {
    $lines | ForEach-Object { $outl.Add($_) }
    $outl.Add(''); $outl.Add("[ui] # $PLUGIN"); $outl.Add($barLine)
  }
  $outl.Add(''); $outl.Add("[[keys.command]] # $PLUGIN")
  $outl.Add("key = `"prefix+u`" # $PLUGIN")
  $outl.Add("type = `"popup`" # $PLUGIN")
  $outl.Add("command = '$(Ps-Command 'dashboard')' # $PLUGIN")
  $outl.Add("description = `"LLM API usage dashboard`" # $PLUGIN")
  $outl.Add("width = 104 # $PLUGIN")
  $outl.Add("height = 26 # $PLUGIN")
  Write-Lines $cfg $outl
  Herdr-Position $cfg | Out-Null
  $out = Herdr-Reload
  if (-not $out.Trim()) { Write-Host "herdr config updated (server not running; it loads on next start). Backup: $bak"; return }
  $diag = -1
  try { $diag = @(($out | ConvertFrom-Json).result.diagnostics).Count } catch {}
  if ($diag -eq 0) { Write-Host "herdr config updated: tab-bar entry + prefix+u dashboard. Backup: $bak" }
  else {
    Copy-Item -LiteralPath $bak -Destination $cfg -Force
    Herdr-Reload | Out-Null
    Write-Host 'herdr rejected the config change; backup restored. Add the entries manually (see README).'
  }
}

function Herdr-Config-Remove {
  $cfg = Herdr-Cfg
  $lines = Read-Lines $cfg
  if ($lines -like "*# $PLUGIN*") {
    Write-Lines $cfg @($lines | Where-Object { $_ -notlike "*# $PLUGIN*" })
    Herdr-Reload | Out-Null
    Write-Host 'removed herdr config entries'
  }
}

# ---------- configure: install the statusLine wrapper ----------
function Settings-Path { Join-Path $env:USERPROFILE '.claude\settings.json' }

function Set-StatusLine($settings, $command) { # $null removes it
  $s = Read-Json $settings
  if (-not $s) { $s = [pscustomobject]@{} }
  if ($null -eq $command) { $s.PSObject.Properties.Remove('statusLine') }
  else { $s | Add-Member -NotePropertyName statusLine -NotePropertyValue ([pscustomobject]@{ type = 'command'; command = $command; refreshInterval = 60 }) -Force }
  Write-Atomic $settings ($s | ConvertTo-Json -Depth 100)
}

function Configure {
  $settings = Settings-Path
  New-Item -ItemType Directory -Force -Path $ConfigDir, (Split-Path $settings) | Out-Null
  $current = "$((Read-Json $settings).statusLine.command)"
  if ($current -like "*$PLUGIN*collect*") {
    Write-Host 'statusLine wrapper already installed'
    Herdr-Config
    return
  }
  if ($current) { Write-Atomic $Chain $current; Write-Host "chaining to previous statusLine: $current" }
  if (Test-Path -LiteralPath $settings) { Copy-Item -LiteralPath $settings -Destination "$settings.bak-quota-monitor" -Force }
  Set-StatusLine $settings (Ps-Command 'collect')
  Write-Host "statusLine wrapper installed (backup: $settings.bak-quota-monitor)"
  Herdr-Config
}

# ---------- setup-keys: interactive API key storage ----------
function Setup-Keys {
  Write-Host 'LLM API Key Setup'
  Write-Host 'Keys are stored as user environment variables (restart the herdr server to pick them up).'
  Write-Host 'They can also go in the plugin config file. Use OPENAI_ADMIN_KEY / ANTHROPIC_ADMIN_KEY for OpenAI / Claude.'
  Write-Host ''
  foreach ($p in $API_PROVIDERS) {
    if ($p -in ($AGENT_PROVIDERS + 'bedrock')) { continue } # they use their own CLI login
    $k = Read-Host "Enter $p API key (or press Enter to skip)"
    if ($k) {
      $var = @(Key-Vars $p)[0]
      [Environment]::SetEnvironmentVariable($var, $k, 'User')
      Write-Host "Stored $var"
    }
  }
  Write-Host "Done. Run '$PLUGIN.ps1 bar' to test."
}

function Uninstall {
  $settings = Settings-Path
  if (Test-Path -LiteralPath $Chain) {
    Set-StatusLine $settings ([IO.File]::ReadAllText($Chain, $Utf8)) # not Get-Content: its string carries provider properties ConvertTo-Json would walk
    Write-Host 'restored previous statusLine'
  } elseif (Test-Path -LiteralPath $settings) {
    Set-StatusLine $settings $null
    Write-Host 'removed statusLine'
  }
  Herdr-Config-Remove
}

switch ($Cmd) {
  'collect' { Collect }
  'bar' { Bar }
  'dashboard' { Dashboard }
  'draw' { Draw ([int]$(if ($Arg) { $Arg } else { 0 })); Emit "`n" }
  'refresh' { # hidden worker started by the tab bar
    try { [IO.File]::WriteAllText((Join-Path $ApiCache 'refresh.stamp'), "$PID"); Refresh-All }
    finally { Remove-Item -LiteralPath (Join-Path $ApiCache 'refresh.lock') -Force -ErrorAction SilentlyContinue }
  }
  'configure' { Configure }
  'uninstall' { Uninstall }
  'setup-keys' { Setup-Keys }
  default { [Console]::Error.WriteLine("usage: $PLUGIN.ps1 collect|bar|dashboard|draw|configure|uninstall|setup-keys"); exit 2 }
}
