#!/usr/bin/env bash
# herdr-quota-monitor: coding-agent and LLM API quotas inside Herdr (formerly herdr-llmapi-usage).
# Windows: bin/herdr-quota-monitor.ps1 is a PowerShell port; change both together.
#
# Data sources:
# 1. Claude Code statusLine hook (same as herdr-claude-usage)
# 2. LLM Provider APIs (OpenAI, Anthropic, etc.) via API keys stored in keychain/env
set -u

PLUGIN="herdr-quota-monitor"
OLD_PLUGIN="herdr-llmapi-usage" # previous name: its data and keychain entries are reused
TITLE="~ AI usage Monitor ~" # dashboard heading
HERDR=${HERDR_BIN_PATH:-herdr}
STATE_DIR=${HERDR_PLUGIN_STATE_DIR:-$HOME/.local/state/herdr/plugins/$PLUGIN}
CONFIG_DIR=${HERDR_PLUGIN_CONFIG_DIR:-$HOME/.config/herdr/plugins/config/$PLUGIN}
KEYCHAIN_SERVICE="$OLD_PLUGIN" # kept: renaming it would orphan keys already stored
PAYLOAD="$STATE_DIR/payload.json"
CHAIN="$CONFIG_DIR/chain"
STALE_SECS=${STALE_SECS:-1800}

for d in "$STATE_DIR:$HOME/.local/state/herdr/plugins/$OLD_PLUGIN" "$CONFIG_DIR:$HOME/.config/herdr/plugins/config/$OLD_PLUGIN"; do
  # one-time move of the old plugin's data (statusLine chain, profiles, caches) into the new dirs
  if [ -d "${d#*:}" ] && [ -z "$(ls -A "${d%%:*}" 2>/dev/null)" ]; then
    mkdir -p "${d%%:*}" && cp -a "${d#*:}/." "${d%%:*}/" && rm -rf "${d#*:}"
  fi
done
mkdir -p "$STATE_DIR"
[ -f "$CONFIG_DIR/config" ] && . "$CONFIG_DIR/config"

# ---------- collect: statusLine hook (invoked by Claude Code, not manually) ----------
collect() {
  local payload key sid
  payload=$(cat)
  if [ -n "$payload" ]; then
    printf '%s' "$payload" >"$PAYLOAD.tmp.$$" && mv "$PAYLOAD.tmp.$$" "$PAYLOAD"
    key=$(printf '%s' "$payload" | jq -r '(.rate_limits.seven_day.resets_at // .rate_limits.five_hour.resets_at // 0) | tostring' 2>/dev/null)
    if [ -n "$key" ] && [ "$key" != "0" ]; then
      mkdir -p "$STATE_DIR/profiles"
      local pfile="$STATE_DIR/profiles/$key.json" stored="$payload"
      if [ -s "$pfile" ]; then
        stored=$(printf '%s' "$payload" | jq --slurpfile old "$pfile" --argjson now "$(date +%s)" '
          if (.rate_limits.five_hour // null) == null
             and (($old[0].rate_limits.five_hour // null) != null)
             and ((($old[0].rate_limits.five_hour.resets_at // 0) | tonumber? // 0) > $now)
          then .rate_limits.five_hour = $old[0].rate_limits.five_hour
          else . end' 2>/dev/null) || stored="$payload"
        [ -n "$stored" ] || stored="$payload"
      fi
      printf '%s' "$stored" >"$pfile.tmp.$$" && mv "$pfile.tmp.$$" "$pfile"
      sid=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)
      if [ -n "$sid" ]; then
        {
          grep -v "^$sid	" "$STATE_DIR/profiles/$key.sessions" 2>/dev/null
          printf '%s\t%s\t%s\n' "$sid" "$(date +%s)" \
            "$(printf '%s' "$payload" | jq -r '.cwd // "" | split("/") | last // ""' 2>/dev/null)"
        } \
          >"$STATE_DIR/profiles/$key.sessions.tmp.$$" && mv "$STATE_DIR/profiles/$key.sessions.tmp.$$" "$STATE_DIR/profiles/$key.sessions"
      fi
    fi
  fi
  if [ -f "$CHAIN" ]; then
    printf '%s' "$payload" | sh -c "$(cat "$CHAIN")"
  fi
}

# ---------- API key management ----------
# Keys come from env <PROVIDER>_API_KEY (e.g. OPENROUTER_API_KEY), else macOS keychain
# entry "herdr-llmapi-usage-<provider>" (the old name, see KEYCHAIN_SERVICE). A provider listed in DISABLED_PROVIDERS (plugin
# config) gets no key, so it is never fetched or shown; "claude" also hides statusLine data.
# Coding agents need no key: they use the login their own CLI/app saved (or CodexBar).
AGENT_PROVIDERS="codex grok droid antigravity cursor"
# Gateways/routers report what went through them: LiteLLM, Portkey, Cloudflare AI Gateway, Bedrock.
API_PROVIDERS="claude $AGENT_PROVIDERS openai openrouter llmapi orcarouter deepseek moonshot portkey litellm cloudflare bedrock"

provider_enabled() { case " ${DISABLED_PROVIDERS:-} " in *" $1 "*) return 1 ;; esac }

key_vars() { # provider -> env var names, first set wins
  case "$1" in
  claude) printf 'ANTHROPIC_ADMIN_KEY ANTHROPIC_API_KEY' ;;
  openai) printf 'OPENAI_ADMIN_KEY OPENAI_API_KEY' ;;
  cloudflare) printf 'CLOUDFLARE_API_TOKEN' ;; # an API token; the legacy global key uses other headers
  *) printf '%s_API_KEY' "$(printf '%s' "$1" | tr a-z A-Z)" ;;
  esac
}

cursor_token() { # Cursor's saved login: auth.json, else the Linux app's state DB
  local f
  for f in "${CURSOR_AUTH_FILE:-}" "${XDG_CONFIG_HOME:-$HOME/.config}/cursor/auth.json" "$HOME/.cursor/auth.json"; do
    [ -f "$f" ] && {
      jq -r '.accessToken // empty' "$f" 2>/dev/null
      return
    }
  done
  f="${XDG_CONFIG_HOME:-$HOME/.config}/Cursor/User/globalStorage/state.vscdb"
  [ -f "$f" ] && command -v python3 >/dev/null && python3 -I -c '
import pathlib, sqlite3, sys
db = sqlite3.connect(pathlib.Path(sys.argv[1]).resolve().as_uri() + "?mode=ro", uri=True, timeout=0.2)
row = db.execute("SELECT value FROM ItemTable WHERE key = ?", ("cursorAuth/accessToken",)).fetchone()
v = row[0] if row else ""
print((v.decode("utf-8", "ignore") if isinstance(v, bytes) else str(v)).strip())' "$f" 2>/dev/null
}

get_api_key() { # provider -> key (agents: their saved token, or a marker that local data exists)
  local provider="$1" var key=""
  provider_enabled "$provider" || return 0
  case "$provider" in
  codex)
    [ -d "${CODEX_HOME:-$HOME/.codex}/sessions" ] && printf local
    return 0
    ;;
  droid | antigravity)
    command -v "${CODEXBAR_BIN:-codexbar}" 2>/dev/null
    return 0
    ;;
  cursor)
    cursor_token
    return 0
    ;;
  bedrock) # Cost Explorer needs IAM credentials; the aws CLI does the request signing
    [ -n "${AWS_BEARER_TOKEN_BEDROCK:-}${AWS_PROFILE:-}${AWS_ACCESS_KEY_ID:-}" ] && command -v aws 2>/dev/null
    return 0
    ;;
  cloudflare) [ -n "${CLOUDFLARE_ACCOUNT_ID:-}" ] || return 0 ;; # then the token, as usual
  grok) # first entry of the Grok CLI login; skipped once expires_at (epoch or ISO) has passed
    jq -r --argjson now "$(date +%s)" 'first(.[]) | objects | (.expires_at // "") as $e
        | ($e | tonumber? // (sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601?) // null) as $t
        | select($t == null or $t > $now) | .key // empty' "${GROK_AUTH_FILE:-$HOME/.grok/auth.json}" 2>/dev/null
    return 0
    ;;
  esac
  for var in $(key_vars "$provider"); do
    key="${!var:-}"
    [ -n "$key" ] && break
  done
  if [ -z "$key" ] && command -v security >/dev/null 2>&1; then
    key=$(security find-generic-password -s "${KEYCHAIN_SERVICE}-${provider}" -w 2>/dev/null || true)
  fi
  printf '%s' "$key"
}

store_api_key() { # provider key
  local provider="$1" key="$2"
  if command -v security >/dev/null 2>&1; then
    security add-generic-password -a "$USER" -s "${KEYCHAIN_SERVICE}-${provider}" -w "$key" -U 2>/dev/null
    echo "Stored $provider key in keychain"
  else
    echo "Keychain not available. Set $(key_vars "$provider" | cut -d' ' -f1) in your shell config or plugin config."
  fi
}

delete_api_key() { # provider
  local provider="$1"
  if command -v security >/dev/null 2>&1; then
    security delete-generic-password -s "${KEYCHAIN_SERVICE}-${provider}" 2>/dev/null
    echo "Deleted $provider key from keychain"
  fi
}

# ---------- API fetchers ----------
# Only providers whose plain API key can read its own usage. Cached 5 min per provider.
API_CACHE_DIR="$STATE_DIR/api_cache"
mkdir -p "$API_CACHE_DIR"

fetch_api() { # provider url [auth header, KEY = the key] [extra curl config lines...]
  local cache="$API_CACHE_DIR/$1.json" tmp="$API_CACHE_DIR/$1.json.tmp.$$" url="$2" auth="${3:-Authorization: Bearer KEY}" key code
  key=$(get_api_key "$1")
  [ -n "$key" ] || return 0
  [ "$(payload_age "$cache")" -lt 300 ] && return 0
  shift 3 2>/dev/null || set --
  umask 077 # always run as a background job, so this stays out of the caller
  # the key reaches curl on stdin, never in argv where ps would show it
  code=$({
    printf 'url = "%s"\nheader = "%s"\n' "$url" "${auth/KEY/$key}"
    printf '%s\n' "$@"
  } |
    curl -s -m 10 -K - -o "$tmp" -w '%{http_code}' 2>/dev/null)
  if [ "$code" = 200 ] && jq -e 'type == "object"' "$tmp" >/dev/null 2>&1; then
    mv "$tmp" "$cache"
  else
    rm -f "$tmp"
    # 4xx = this key can't read usage (e.g. not an admin key); cache it so the tab says so
    case "$code" in 4*) printf '{"error":"HTTP %s"}' "$code" >"$cache" ;; esac
  fi
}

codex_snapshot() { # newest rate_limits in Codex's own session logs -> cache (no network)
  local cache="$API_CACHE_DIR/codex.json" f line
  [ -n "$(get_api_key codex)" ] || return 0
  [ "$(payload_age "$cache")" -lt 60 ] && return 0
  while IFS= read -r f; do
    line=$(grep '"rate_limits"' "$f" 2>/dev/null | tail -1)
    [ -n "$line" ] || continue
    printf '%s' "$line" | jq -c '{timestamp, rate_limits: first(.. | .rate_limits? | objects)}' >"$cache.tmp.$$" 2>/dev/null &&
      [ -s "$cache.tmp.$$" ] && mv "$cache.tmp.$$" "$cache" && return 0
    rm -f "$cache.tmp.$$"
  done < <(find "${CODEX_HOME:-$HOME/.codex}/sessions" -name '*.jsonl' -mtime -31 -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | head -5)
}

detached_refresh() { # provider max-age jq-check cmd...: for CLIs slower than the tab bar's 5s
  # timeout; runs fully detached (outside fetch_all_apis' wait) and the next tick reads the cache.
  local p="$1" ttl="$2" check="$3" cache="$API_CACHE_DIR/$1.json" lock="$API_CACHE_DIR/$1.lock"
  shift 3
  [ "$(payload_age "$cache")" -lt "$ttl" ] && return 0
  [ -d "$lock" ] && [ "$(payload_age "$lock")" -lt 60 ] && return 0
  rmdir "$lock" 2>/dev/null
  mkdir "$lock" 2>/dev/null || return 0
  ( (
    umask 077
    tmp="$cache.tmp.$$"
    # only a usable answer replaces the cache, so a failed run keeps the last good one
    "$@" >"$tmp" 2>/dev/null && jq -e "$check" "$tmp" >/dev/null 2>&1 && mv "$tmp" "$cache"
    rm -f "$tmp"
    rmdir "$lock"
  ) </dev/null >/dev/null 2>&1 &)
}

codexbar_refresh() { # droid|antigravity
  local bin cb="${1/droid/factory}"
  bin=$(get_api_key "$1")
  [ -n "$bin" ] || return 0
  detached_refresh "$1" 300 "any((if type == \"array\" then .[] else . end);
      .provider == \"$cb\" and (.usage | type) == \"object\" and .source != \"offline\")" \
    "$bin" usage --format json --provider "$cb" --no-color
}

bedrock_refresh() { # Cost Explorer bills $0.01 per call and updates about daily: every 6h is plenty
  local bin
  bin=$(get_api_key bedrock)
  [ -n "$bin" ] || return 0
  detached_refresh bedrock 21600 '.ResultsByTime | type == "array"' \
    "$bin" ce get-cost-and-usage --region us-east-1 --output json \
    --time-period "Start=$(date -u +%Y-%m-01),End=$(jq -rn 'now + 86400 | strftime("%Y-%m-%d")')" \
    --granularity MONTHLY --metrics UnblendedCost --group-by Type=DIMENSION,Key=SERVICE
}

fetch_all_apis() {
  [ "${USE_API:-1}" = 1 ] || return 0
  codex_snapshot
  codexbar_refresh droid
  codexbar_refresh antigravity
  bedrock_refresh
  local m0 iso now_iso # start of the current UTC month, for month-to-date cost reports
  m0=$(jq -n 'now | gmtime | .[2] = 1 | .[3] = 0 | .[4] = 0 | .[5] = 0 | mktime')
  iso=$(jq -rn --argjson t "$m0" '$t | todate')
  now_iso=$(jq -rn 'now | floor | todate')
  # GraphQL variables keep the account id out of the query text
  jq -n --arg a "${CLOUDFLARE_ACCOUNT_ID:-}" --arg s "$iso" --arg e "$now_iso" '{variables: {a: $a, s: $s, e: $e},
    query: "query($a: string!, $s: Time!, $e: Time!) { viewer { accounts(filter: {accountTag: $a}) {
      aiGatewayRequestsAdaptiveGroups(limit: 1, filter: {datetimeHour_geq: $s, datetimeHour_leq: $e}) { count sum { cost } } } } }"}' \
    >"$API_CACHE_DIR/cloudflare.query"
  fetch_api claude "https://api.anthropic.com/v1/organizations/cost_report?starting_at=$iso&bucket_width=1d&limit=31" \
    'x-api-key: KEY' 'header = "anthropic-version: 2023-06-01"' &
  fetch_api grok 'https://cli-chat-proxy.grok.com/v1/billing?format=credits' '' \
    'header = "x-xai-token-auth: xai-grok-cli"' 'header = "Accept: application/json"' &
  fetch_api cursor https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage '' \
    'data = "{}"' 'header = "Content-Type: application/json"' 'header = "Connect-Protocol-Version: 1"' &
  fetch_api openai "https://api.openai.com/v1/organization/costs?start_time=$m0&bucket_width=1d&limit=31" &
  fetch_api openrouter https://openrouter.ai/api/v1/key &
  fetch_api llmapi https://api.llmapi.ai/v1/credits &
  fetch_api orcarouter https://api.orcarouter.ai/v1/tools/balance &
  fetch_api deepseek https://api.deepseek.com/user/balance &
  fetch_api moonshot https://api.moonshot.ai/v1/users/me/balance &
  fetch_api portkey "https://api.portkey.ai/v1/analytics/graphs/cost?time_of_generation_min=$iso&time_of_generation_max=$now_iso" \
    'x-portkey-api-key: KEY' &
  fetch_api litellm "${LITELLM_BASE_URL:-http://localhost:4000}/key/info" &
  fetch_api cloudflare https://api.cloudflare.com/client/v4/graphql '' \
    'header = "Content-Type: application/json"' "data-binary = \"@$API_CACHE_DIR/cloudflare.query\"" &
  wait
}

# ---------- shared helpers ----------
payload_age() { # [file]
  local f="${1:-$PAYLOAD}"
  [ -f "$f" ] || {
    printf '%s' 999999
    return
  }
  printf '%s' $(($(date +%s) - $(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f")))
}

efmt() { date -r "$1" "$2" 2>/dev/null || date -d "@$1" "$2" 2>/dev/null; }

tz_name() {
  local link
  link=$(readlink /etc/localtime 2>/dev/null)
  case "$link" in
  *zoneinfo/*) printf '%s' "${link#*zoneinfo/}" ;;
  *) date +%Z ;;
  esac
}

# Parse rate_limits from statusLine payload.
# Emits: key<TAB>used%<TAB>resets_epoch
windows() {
  jq -r '
    (.rate_limits // .) | to_entries
    | map(select((.value | type) == "object" and ((.value.used_percentage // .value.utilization) != null)))
    | sort_by(if .key == "five_hour" then 0 elif .key == "seven_day" then 1 else 2 end)
    | .[] | [
        .key,
        ((.value.used_percentage // .value.utilization) | round | tostring),
        ((.value.resets_at // 0) as $r |
          (if ($r|type) == "number" then $r
           else (try (($r | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601) + (if ($r | test("\\.[0-9]")) then 1 else 0 end)) catch 0)
           end) | tostring)
      ] | @tsv' "${1:-$PAYLOAD}" 2>/dev/null
}

# jq program turning a provider's cached response into rows (see api_extra_windows).
api_rows_jq() {
  case "$1" in
  openrouter) printf '%s' '
    .data | (.effective_budget // null) as $b |
    (if $b and ($b.limit_usd // 0) > 0 then
       ["openrouter:" + ($b.reset_interval // "budget"),
        ([$b.spend_usd * 100 / $b.limit_usd, 100] | min | round | tostring),
        ($b.resets_at | epoch | tostring),
        ($b.spend_usd | usd) + "/" + ($b.limit_usd | usd)]
     else ["openrouter:spend", "-", "0", ((.usage // 0) | usd) + " used"] end),
    (.free_model_daily_requests // empty | select((.limit // 0) > 0) |
       ["openrouter:free/day",
        ([.used * 100 / .limit, 100] | min | round | tostring),
        (((now / 86400 | floor) + 1) * 86400 | tostring),  # shortcut: assumes UTC-midnight reset, fix if OpenRouter says otherwise
        "\(.used)/\(.limit) req"])
' ;;
  codex) printf '%s' '.timestamp as $ts | .rate_limits | (.primary, .secondary) | objects
      | (.resets_at // (if .resets_in_seconds then ($ts | epoch) + .resets_in_seconds else 0 end)) as $r
      | ["codex:" + (.window_minutes | wlabel), (if $r > 0 and $r < now then 0 else .used_percent end | pctr), ($r | tostring)]' ;;
  grok) printf '%s' '[(.config | objects), .] | map(.creditUsagePercent
        // (if (.onDemandCap.val // 0) > 0 then (.onDemandUsed.val // 0) * 100 / .onDemandCap.val else null end))
      | map(select(. != null)) | first // empty | ["grok:credits", pctr, "0"]' ;;
  droid | antigravity) printf '%s' '(if type == "array" then .[] else . end) | select(.provider == $cb and .source != "offline") | .usage
      | ((.primary, .secondary, .tertiary) | objects | {w: ., t: (.windowMinutes | wlabel)}),
        (.extraRateWindows[]? | select(.usageKnown != false) | {w: .window, t: (.title // .id)})
      | select(.w.usageKnown != false and .w.usedPercent != null)
      | [$p + ":" + .t, (.w.usedPercent | pctr), (.w.resetsAt | rst | tostring)]' ;;
  cursor) printf '%s' '.planUsage | objects | (.limit // 0) as $l
      | (.totalPercentUsed // (if $l > 0 then ((.includedSpend // (if .remaining then $l - .remaining else null end) // .used)
          | if . then . * 100 / $l else null end) else null end)) as $inc
      | (if $inc != null then ["cursor:included", ($inc | pctr), "0"] else empty end),
        (.autoPercentUsed // empty | ["cursor:auto", pctr, "0"]),
        (.apiPercentUsed // empty | ["cursor:api", pctr, "0"])' ;;
  llmapi) printf '%s' '["llmapi:credits", "-", "0", (.total_credits // 0 | usd) + " left"]' ;;
  orcarouter) printf '%s' '.data | ["orcarouter:wallet", "-", "0", (.spendable_usd // .wallet_usd // 0 | usd) + " left"]' ;;
  deepseek) printf '%s' '.balance_infos[]? | ["deepseek:balance", "-", "0", "\(.total_balance) \(.currency) left"]' ;;
  moonshot) printf '%s' '.data | ["moonshot:balance", "-", "0", (.available_balance // 0 | usd) + " left"]' ;;
  openai) printf '%s' '["openai:month", "-", "0", ([.data[]?.results[]?.amount.value // 0] | add // 0 | usd) + " this month"]' ;;
  portkey) printf '%s' '["portkey:month", "-", "0", ((.summary.total // 0) / 100 | usd) + " this month"]' ;; # cents
  litellm) printf '%s' '(.info // .) | if (.max_budget // 0) > 0
      then ["litellm:budget", (.spend * 100 / .max_budget | pctr), (.budget_reset_at | rst | tostring), (.spend | usd) + "/" + (.max_budget | usd)]
      else ["litellm:spend", "-", "0", ((.spend // 0) | usd) + " used"] end' ;;
  cloudflare) printf '%s' 'if ((.errors // []) | length) > 0 then ["cloudflare:error", "-", "0", .errors[0].message]
      else (.data.viewer.accounts[0].aiGatewayRequestsAdaptiveGroups[0] // {})
        | ["cloudflare:month", "-", "0", ((.sum.cost // 0) | usd) + " this month · \(.count // 0) req"] end' ;;
  bedrock) printf '%s' '["bedrock:month", "-", "0", ([.ResultsByTime[]?.Groups[]? | select(.Keys[0] | test("Bedrock"))
      | .Metrics.UnblendedCost.Amount | tonumber] | add // 0 | usd) + " this month"]' ;; # Marketplace models bill as "<model> (Amazon Bedrock Edition)"
  claude) printf '%s' '["claude:API month", "-", "0", ([.data[]?.results[]?.amount | tonumber? // 0] | add // 0 | . / 100 | usd) + " this month"]' ;; # amounts are cents
  esac
}

# API usage rows: key<TAB>used%<TAB>resets_epoch<TAB>right-text. used% "-" = no bar (balance only).
api_extra_windows() {
  local p c
  for p in $API_PROVIDERS; do
    c="$API_CACHE_DIR/$p.json"
    [ "$(payload_age "$c")" -lt "$([ "$p" = bedrock ] && echo 43200 || echo 3600)" ] && [ -n "$(get_api_key "$p")" ] || continue
    jq -r --arg p "$p" --arg cb "${p/droid/factory}" '
      def usd: "$" + (. * 100 | round / 100 | tostring);
      def epoch: (. // "") | (try (sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601) catch 0);
      def rst: if type == "number" then (if . > 1e11 then . / 1000 | floor else . end) elif type == "string" then epoch else 0 end;
      def pctr: [[., 100] | min, 0] | max | round | tostring;
      def wlabel: if . == 300 then "5h" elif . == 10080 then "week" elif . == 43200 then "month"
        elif . == null then "usage" else "\(. / 60 | round)h" end;
      if (.error? // null) then [$p + ":error", "-", "0", .error + " · key has no usage access"]
      else ('"$(api_rows_jq "$p")"') end | @tsv' "$c" 2>/dev/null
  done
  return 0
}

provider_name() {
  case "$1" in
  all) printf 'All' ;;
  claude) printf 'Claude' ;;
  openai) printf 'OpenAI' ;;
  openrouter) printf 'OpenRouter' ;;
  llmapi) printf 'llmapi.ai' ;;
  orcarouter) printf 'OrcaRouter' ;;
  deepseek) printf 'DeepSeek' ;;
  moonshot) printf 'Moonshot' ;;
  codex) printf 'Codex' ;;
  grok) printf 'Grok' ;;
  droid) printf 'Droid' ;;
  antigravity) printf 'Antigravity' ;;
  cursor) printf 'Cursor' ;;
  portkey) printf 'Portkey' ;;
  litellm) printf 'LiteLLM' ;;
  cloudflare) printf 'CF AI Gateway' ;;
  bedrock) printf 'Bedrock' ;;
  *) printf '%s' "$1" ;;
  esac
}

label_for() {
  case "$1" in
  five_hour) printf 'Session (5h)' ;;
  seven_day) printf 'Week · all models' ;;
  seven_day_*)
    local m="${1#seven_day_}"
    printf 'Week · %s' "$(printf '%s' "${m:0:1}" | tr a-z A-Z)${m:1}"
    ;;
  spend) printf 'Extra usage' ;;
  *:*) printf '%s · %s' "$(provider_name "${1%%:*}")" "${1#*:}" ;;
  *) printf '%s' "$1" ;;
  esac
}

rel_time() { # epoch -> "2h04m" / "45m" / "2d3h"
  local d=$(($1 - $(date +%s)))
  [ "$d" -lt 0 ] && d=0
  if [ "$d" -ge 86400 ]; then
    printf '%dd%dh' $((d / 86400)) $((d % 86400 / 3600))
  elif [ "$d" -ge 3600 ]; then
    printf '%dh%02dm' $((d / 3600)) $((d % 3600 / 60))
  else printf '%dm' $((d / 60)); fi
}

abs_time() { # epoch -> "3pm" today, "Wed 6pm" otherwise
  if [ "$(efmt "$1" +%Y%m%d)" = "$(date +%Y%m%d)" ]; then
    efmt "$1" +%-I%p | tr 'A-Z' 'a-z'
  else
    printf '%s %s' "$(efmt "$1" +%a)" "$(efmt "$1" +%-I%p | tr 'A-Z' 'a-z')"
  fi
}

short_label() {
  case "$1" in
  five_hour) printf '5h' ;;
  seven_day) printf 'wk' ;;
  seven_day_*)
    local m="${1#seven_day_}"
    printf '%s' "$(printf '%s' "${m:0:1}" | tr a-z A-Z)${m:1}"
    ;;
  openrouter:*) printf 'OR:%s' "${1#openrouter:}" ;;
  llmapi:*) printf 'LLMAPI' ;;
  *:*) printf '%s:%s' "$(provider_name "${1%%:*}")" "${1#*:}" ;;
  *) printf '%s' "$1" ;;
  esac
}

BAR_HOT=${BAR_HOT:-80}
BAR_WARN=${BAR_WARN:-50}
BAR_GAUGE=${BAR_GAUGE:-0}               # 1: small gauge next to each tab-bar percentage
BAR_GAUGE_W=${BAR_GAUGE_W:-5}           # gauge cells
BAR_POSITION=${BAR_POSITION:-top-right} # top-right | top-center | bottom-right | bottom-center
TEXT_DIR=${TEXT_DIR:-ltr}               # rtl: mirror the tab bar and dashboard (Arabic, Hebrew, ...)

unit_for() { # window key or sub-label -> compact suffix, as in 13%m, 50%w, 45%h
  case "$1" in
  five_hour | *5h* | *5-hour* | *[Hh]our*) printf h ;;
  seven_day) printf w ;;
  seven_day_*)
    local m="${1#seven_day_}"
    printf 'w(%s)' "$(printf '%s' "${m:0:1}" | tr a-z A-Z)${m:1}"
    ;;
  *[Ww]eek*) printf w ;;
  *[Mm]onth*) printf m ;;
  *[Dd]ay* | *[Dd]aily*) printf d ;;
  included | credits | budget | usage | spend | wallet | balance) ;; # the provider's main number
  *) printf '(%s)' "$1" ;;
  esac
}

gauge() { # pct -> ██░░░, filled from the right in rtl
  local f=$((($1 * BAR_GAUGE_W + 50) / 100)) i g=""
  [ "$1" -gt 0 ] && [ "$f" -eq 0 ] && f=1
  [ "$f" -gt "$BAR_GAUGE_W" ] && f=$BAR_GAUGE_W
  for ((i = 0; i < BAR_GAUGE_W; i++)); do
    if [ "$TEXT_DIR" = rtl ]; then
      if [ "$i" -lt $((BAR_GAUGE_W - f)) ]; then g+="░"; else g+="█"; fi
    elif [ "$i" -lt "$f" ]; then g+="█"; else g+="░"; fi
  done
  printf '%s' "$g"
}

fmt_pct() { # pct [unit] -> "13%m", "⚠️" above BAR_HOT, gauge when BAR_GAUGE=1
  local v="$1%${2:-}"
  [ "$1" -gt "$BAR_HOT" ] 2>/dev/null && v+="⚠️"
  if [ "$BAR_GAUGE" = 1 ]; then
    if [ "$TEXT_DIR" = rtl ]; then v="$v $(gauge "$1")"; else v="$(gauge "$1") $v"; fi
  fi
  printf '%s' "$v"
}

strlen() { # display length in characters, whatever locale herdr runs us under
  local LC_ALL=C.UTF-8
  printf '%s' "${#1}"
}

herdr_width() { # width of the focused tab's area, from herdr's own snapshot
  "$HERDR" api snapshot 2>/dev/null | jq -r '.result.snapshot as $s
    | first($s.layouts[] | select(.tab_id == $s.focused_tab_id) | .area.width) // empty' 2>/dev/null
}

# ---------- profiles ----------
profiles_ranked() {
  local now cutoff f s n names mtime
  now=$(date +%s)
  cutoff=$((now - STALE_SECS))
  for f in "$STATE_DIR"/profiles/*.json; do
    [ -f "$f" ] || continue
    mtime=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f")
    [ "$mtime" -ge "$cutoff" ] || continue
    s="${f%.json}.sessions"
    n=0
    names=""
    if [ -f "$s" ]; then
      n=$(awk -F'\t' -v c="$cutoff" '$2 >= c' "$s" | wc -l | tr -d ' ')
      names=$(awk -F'\t' -v c="$cutoff" '$2 >= c {print $3}' "$s" | sort -u | head -3 | paste -sd, -)
    fi
    printf '%s\t%s\t%s\t%s\n' "$n" "$mtime" "$f" "$names"
  done | sort -t$'\t' -k1,1nr -k2,2nr | awk -F'\t' '{print $3 "\t" $1 "\t" $4}'
}

# ---------- bar: one-line summary for the Herdr tab bar ----------
bar_name() {
  case "$1" in
  openrouter) printf 'OR' ;;
  llmapi) printf 'LLMAPI' ;;
  *) provider_name "$1" ;;
  esac
}

bar() {
  fetch_all_apis
  local ranked primary others
  ranked=$(provider_enabled claude && profiles_ranked)
  primary=$(printf '%s\n' "$ranked" | head -1 | cut -f1)
  others=$(printf '%s\n' "$ranked" | grep -c . || true)
  local items=() key used epoch right v hr
  [ -n "$primary" ] && { windows "$primary" | grep -q '^five_hour' || items+=("claude"$'\t'"$(fmt_pct 0 h)"); }
  while IFS=$'\t' read -r key used epoch; do
    v=$(fmt_pct "$used" "$(unit_for "$key")")
    if [ "$key" = "five_hour" ] && [ "$epoch" -gt 0 ] 2>/dev/null; then
      hr=$(efmt "$epoch" +%-I%p | tr 'A-Z' 'a-z')
      [ -n "$hr" ] && v="$v ↻ $hr"
    fi
    items+=("claude"$'\t'"$v")
  done < <([ -n "$primary" ] && windows "$primary")
  while IFS=$'\t' read -r key used epoch right; do
    [ -n "$key" ] && [ "${key#*:}" != error ] || continue
    if [ "$used" = "-" ]; then v="$right"; else v=$(fmt_pct "$used" "$(unit_for "${key#*:}")"); fi
    items+=("${key%%:*}"$'\t'"$v")
  done < <(api_extra_windows)

  # one "Name: v v" part per provider; rtl reads "v v :Name" and runs right to left
  local parts=() p last="" vals="" item i out
  for item in "${items[@]}" $'\t'; do
    p="${item%%$'\t'*}"
    if [ "$p" != "$last" ] && [ -n "$last" ]; then
      if [ "$TEXT_DIR" = rtl ]; then parts=("$vals :$(bar_name "$last")" "${parts[@]}")
      else parts+=("$(bar_name "$last"): $vals"); fi
      vals=""
    fi
    last="$p"
    [ -n "$p" ] || continue
    if [ "$TEXT_DIR" = rtl ]; then vals="${item#*$'\t'}${vals:+ $vals}"; else vals="${vals:+$vals }${item#*$'\t'}"; fi
  done

  if [ "${#parts[@]}" -eq 0 ]; then
    out="LLM —"
  else
    out="${parts[0]}"
    for ((i = 1; i < ${#parts[@]}; i++)); do out+=" · ${parts[$i]}"; done
  fi
  if [ "$TEXT_DIR" = rtl ]; then
    out="$out  ✳"
    [ "$others" -gt 1 ] 2>/dev/null && out="⁺ $out"
  else
    out="✳  $out"
    [ "$others" -gt 1 ] 2>/dev/null && out="$out ⁺"
  fi
  # herdr right-aligns the entry; trailing spaces push it to the middle of the row
  case "$BAR_POSITION" in
  *-center)
    local w pad
    w=$(herdr_width)
    pad=$(((${w:-0} - $(strlen "$out")) / 2))
    [ "$pad" -gt 0 ] && out+=$(printf '%*s' "$pad" '')
    ;;
  esac
  printf '%s' "$out"
}

# ---------- dashboard: pretty popup ----------
BAR_W=34
LINE_W=39

draw_one() { # key used epoch [right-text]
  local key="$1" used="$2" epoch="$3" right="${4:-}"
  local dim=$'\e[2m' rst=$'\e[0m' bold=$'\e[1m'
  local label color filled tick i cell cells pad
  label=$(label_for "$key")
  if [ "$epoch" -gt 0 ] 2>/dev/null; then
    if [ -z "$right" ]; then
      right="↻ $(rel_time "$epoch") · $(abs_time "$epoch")"
    else right="$right · ↻ $(rel_time "$epoch")"; fi
  fi
  pad=$((LINE_W - ${#label} - ${#right}))
  [ "$pad" -lt 1 ] && pad=1
  if [ "$TEXT_DIR" = rtl ]; then
    printf '\n  %s%s%s%*s%s%s%s\n' "$dim" "$right" "$rst" "$pad" '' "$bold" "$label" "$rst"
  else
    printf '\n  %s%s%s%*s%s%s%s\n' "$bold" "$label" "$rst" "$pad" '' "$dim" "$right" "$rst"
  fi
  [ "$used" = "-" ] && return
  if [ "$used" -ge "$BAR_HOT" ] 2>/dev/null; then
    color=$'\e[38;5;210m'
  elif [ "$used" -ge "$BAR_WARN" ] 2>/dev/null; then
    color=$'\e[38;5;222m'
  else color=$'\e[38;5;147m'; fi
  filled=$((used * BAR_W / 100))
  [ "$filled" -gt "$BAR_W" ] && filled=$BAR_W
  [ "$used" -gt 0 ] && [ "$filled" -eq 0 ] && filled=1
  tick=$((BAR_W * BAR_HOT / 100))
  [ "$tick" -ge "$BAR_W" ] && tick=$((BAR_W - 1))
  cells=""
  for ((i = 0; i < BAR_W; i++)); do
    if [ "$i" -lt "$filled" ]; then
      cell="█"
    elif [ "$i" -eq "$tick" ]; then
      cell=$'\e[38;5;243m'"┊${color}"
    else cell=$'\e[38;5;238m'"░${color}"; fi
    if [ "$TEXT_DIR" = rtl ]; then cells="$cell$cells"; else cells+="$cell"; fi # rtl fills from the right
  done
  if [ "$TEXT_DIR" = rtl ]; then
    printf '  %3d%% %s%s%s\n' "$used" "$color" "$cells" "$rst"
  else
    printf '  %s%s%s %3d%%\n' "$color" "$cells" "$rst" "$used"
  fi
}

draw_bars() { # payload_file
  local key used epoch
  while IFS=$'\t' read -r key used epoch; do
    draw_one "$key" "$used" "$epoch"
  done < <(windows "$1")
}

draw() { # [tab-index] (wraps around; 0 = All)
  local dim=$'\e[2m' rst=$'\e[0m' bold=$'\e[1m'
  local tz ranked primary nsess age agetxt
  tz=$(tz_name)
  fetch_all_apis
  ranked=$(provider_enabled claude && profiles_ranked)
  primary=$(printf '%s\n' "$ranked" | head -1 | cut -f1)

  local apirows
  apirows=$(api_extra_windows)
  # One tab per provider with data, in API_PROVIDERS order; claude also when statusLine data exists.
  local tabs=(all $({
    [ -n "$primary" ] && echo claude
    printf '%s\n' "$apirows" | cut -d: -f1
  } | awk 'NF && !s[$0]++'))
  local n=${#tabs[@]} tab t strip=""
  tab=${tabs[$(((${1:-0} % n + n) % n))]}
  for t in "${tabs[@]}"; do
    if [ "$t" = "$tab" ]; then
      t=$'\e[7m'" $(provider_name "$t") $rst"
    else t="$dim $(provider_name "$t") $rst"; fi
    if [ "$TEXT_DIR" = rtl ]; then strip="$t$strip"; else strip+="$t"; fi
  done

  if [ -z "$primary" ] || { [ "$tab" != all ] && [ "$tab" != claude ]; }; then
    printf '\n  %s%s%s\n' "$bold" "$TITLE" "$rst"
    [ "$n" -gt 1 ] && printf '\n  %s\n' "$strip"
    [ -n "$apirows" ] || [ -n "$primary" ] || printf '\n  %sNo fresh data. Run a Claude Code session or set <PROVIDER>_API_KEY.%s\n' "$dim" "$rst"
  else

    age=$(payload_age "$primary")
    if [ "$age" -lt 120 ]; then
      agetxt="${age}s ago"
    else agetxt="$((age / 60))m ago"; fi
    nsess=$(printf '%s\n' "$ranked" | awk -F'\t' -v f="$primary" '$1 == f {print $2}')
    printf '\n  %s%s%s   %s%s · %s session(s) · %s%s\n' \
      "$bold" "$TITLE" "$rst" "$dim" "$agetxt" "${nsess:-?}" "$tz" "$rst"
    printf '\n  %s\n' "$strip"
    windows "$primary" | grep -q '^five_hour' || draw_one five_hour 0 0
    draw_bars "$primary"
  fi

  local key used epoch right
  while IFS=$'\t' read -r key used epoch right; do
    [ -n "$key" ] || continue
    [ "$tab" = all ] || [ "${key%%:*}" = "$tab" ] || continue
    draw_one "$key" "$used" "$epoch" "$right"
  done <<<"$apirows"

  # Other signed-in profiles, compact.
  [ "$tab" = all ] || [ "$tab" = claude ] || return 0
  local file n names5 line
  while IFS=$'\t' read -r file n names5; do
    [ "$file" = "$primary" ] && continue
    line=$(windows "$file" | awk -F'\t' '
      $1 == "five_hour" {s = $2} $1 == "seven_day" {w = $2}
      END {printf "5h %s%% · wk %s%%", (s == "" ? "?" : s), (w == "" ? "?" : w)}')
    printf '\n  %s◦ %s · other profile (%s session(s)%s)%s\n' "$dim" "$line" "$n" "${names5:+ · $names5}" "$rst"
  done < <(printf '%s\n' "$ranked")
}

dashboard() {
  local tab=0 key rest
  while :; do
    printf '\e[H\e[2J'
    draw "$tab"
    printf '\n  \e[2m←/→ tab · 1-9 jump · q close · any key refresh · auto 30s\e[0m\n'
    key=""
    IFS= read -r -s -t 30 -n 1 key 2>/dev/null || continue
    case "$key" in
    q | Q) break ;;
    $'\t' | l) tab=$((tab + 1)) ;;
    h) tab=$((tab - 1)) ;;
    [1-9]) tab=$((key - 1)) ;;
    $'\e') # bare Esc closes; arrow keys arrive as Esc [ C / Esc [ D, shift-Tab as Esc [ Z
      rest=""
      IFS= read -r -s -t 0.05 -n 2 rest 2>/dev/null
      case "$rest" in '[C') tab=$((tab + 1)) ;; '[D' | '[Z') tab=$((tab - 1)) ;; '') break ;; esac
      ;;
    esac
  done
}

# ---------- herdr config ----------
herdr_position() { # cfg: herdr's tab_bar_position follows BAR_POSITION's top-/bottom- half
  local cfg="$1" want="${BAR_POSITION%%-*}"
  case "$BAR_POSITION" in
  top-right | top-center | bottom-right | bottom-center) ;;
  *)
    echo "BAR_POSITION=$BAR_POSITION not supported: herdr only has a right-aligned, one-line slot in the tab row."
    echo "Use top-right, top-center, bottom-right or bottom-center."
    return 1
    ;;
  esac
  local has=0
  grep -q '^[[:space:]]*tab_bar_position' "$cfg" && has=1
  [ "$has" = 1 ] || [ "$want" != top ] || return 0 # top is herdr's default
  # an existing line is edited in place (kept on uninstall); a new one carries our marker
  awk -v want="$want" -v mark="# $PLUGIN" -v has="$has" '
    has && /^[[:space:]]*tab_bar_position/ { print "tab_bar_position = \"" want "\"" (index($0, mark) ? " " mark : ""); next }
    { print }
    !has && /^\[ui\]/ && !done { print "tab_bar_position = \"" want "\" " mark; done = 1 }
  ' "$cfg" >"$cfg.tmp.$$" && mv "$cfg.tmp.$$" "$cfg"
  echo "herdr tab bar at the $want (tab_bar_position)"
}

herdr_config() {
  local cfg="${HERDR_CONFIG_PATH:-$HOME/.config/herdr/config.toml}" me tmp out
  me="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  [ -f "$cfg" ] || : >"$cfg"
  if grep -q "$PLUGIN" "$cfg"; then
    echo "herdr config already has the $PLUGIN entries"
    herdr_position "$cfg" && "$HERDR" server reload-config >/dev/null 2>&1
    return
  fi
  cp "$cfg" "$cfg.bak-${PLUGIN#herdr-}"
  tmp="$cfg.tmp.$$"
  local bar_entry="{ type = \"command\", command = \"bash '$me' bar\", interval_seconds = 30, timeout_seconds = 5 }"
  local bar_line="tab_bar_right = [ $bar_entry ] # $PLUGIN"
  if grep -q '^[[:space:]]*tab_bar_right' "$cfg"; then
    echo "config already defines tab_bar_right; add this entry to it yourself:"
    echo "  $bar_entry"
    cp "$cfg" "$tmp"
  elif grep -q '^\[ui\][[:space:]]*$' "$cfg"; then
    awk -v line="$bar_line" '{print} /^\[ui\][[:space:]]*$/ && !done {print line; done=1}' "$cfg" >"$tmp"
  else
    {
      cat "$cfg"
      printf '\n[ui] # %s\n%s\n' "$PLUGIN" "$bar_line"
    } >"$tmp"
  fi
  {
    cat "$tmp"
    printf '\n[[keys.command]] # %s\n' "$PLUGIN"
    printf 'key = "prefix+u" # %s\n' "$PLUGIN"
    printf 'type = "popup" # %s\n' "$PLUGIN"
    printf 'command = "bash '\''%s'\'' dashboard" # %s\n' "$me" "$PLUGIN"
    printf 'description = "LLM API usage dashboard" # %s\n' "$PLUGIN"
    printf 'width = 104 # %s\n' "$PLUGIN"
    printf 'height = 26 # %s\n' "$PLUGIN"
  } >"$tmp.2" && mv "$tmp.2" "$cfg" && rm -f "$tmp"
  herdr_position "$cfg"
  out=$("$HERDR" server reload-config 2>/dev/null)
  if [ -z "$out" ]; then
    echo "herdr config updated (server not running; it loads on next start). Backup: $cfg.bak-${PLUGIN#herdr-}"
  elif [ "$(printf '%s' "$out" | jq -r '.result.diagnostics | length' 2>/dev/null)" = "0" ]; then
    echo "herdr config updated: tab-bar entry + prefix+u dashboard. Backup: $cfg.bak-${PLUGIN#herdr-}"
  else
    cp "$cfg.bak-${PLUGIN#herdr-}" "$cfg"
    "$HERDR" server reload-config >/dev/null 2>&1
    echo "herdr rejected the config change; backup restored. Add the entries manually (see README)."
  fi
}

herdr_config_remove() {
  local cfg="${HERDR_CONFIG_PATH:-$HOME/.config/herdr/config.toml}"
  if [ -f "$cfg" ] && grep -q "# $PLUGIN" "$cfg"; then
    grep -v "# $PLUGIN" "$cfg" >"$cfg.tmp.$$" && mv "$cfg.tmp.$$" "$cfg"
    "$HERDR" server reload-config >/dev/null 2>&1
    echo "removed herdr config entries"
  fi
}

# ---------- configure: install the statusLine wrapper ----------
configure() {
  local settings="$HOME/.claude/settings.json" me
  me="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  mkdir -p "$CONFIG_DIR"
  command -v jq >/dev/null || {
    echo "jq required"
    exit 1
  }
  local current
  current=$(jq -r '.statusLine.command // ""' "$settings" 2>/dev/null)
  case "$current" in
  *"$PLUGIN"*collect*)
    echo "statusLine wrapper already installed"
    herdr_config
    return
    ;;
  esac
  [ -n "$current" ] && printf '%s' "$current" >"$CHAIN" && echo "chaining to previous statusLine: $current"
  cp "$settings" "$settings.bak-${PLUGIN#herdr-}"
  jq --arg cmd "'$me' collect" '.statusLine = {type:"command", command:$cmd, refreshInterval:60}' \
    "$settings" >"$settings.tmp" && mv "$settings.tmp" "$settings"
  echo "statusLine wrapper installed (backup: $settings.bak-${PLUGIN#herdr-})"
  herdr_config
}

# ---------- setup-keys: interactive API key storage ----------
setup_keys() {
  local provider key
  echo "LLM API Key Setup"
  echo "Keys are stored in macOS keychain (service: $KEYCHAIN_SERVICE-<provider>)"
  echo "Env vars win: <PROVIDER>_API_KEY, e.g. OPENROUTER_API_KEY; OPENAI_ADMIN_KEY and ANTHROPIC_ADMIN_KEY for OpenAI/Claude (set them in your shell config on Linux)."
  echo ""
  for provider in $API_PROVIDERS; do
    case " $AGENT_PROVIDERS bedrock " in *" $provider "*) continue ;; esac # they use their own CLI login
    read -rp "Enter $provider API key (or press Enter to skip): " key
    if [ -n "$key" ]; then
      store_api_key "$provider" "$key"
    fi
  done
  echo "Done. Run '$PLUGIN bar' to test."
}

uninstall() {
  local settings="$HOME/.claude/settings.json"
  if [ -f "$CHAIN" ]; then
    jq --arg cmd "$(cat "$CHAIN")" '.statusLine = {type:"command", command:$cmd, refreshInterval:60}' \
      "$settings" >"$settings.tmp" && mv "$settings.tmp" "$settings"
    echo "restored previous statusLine"
  else
    jq 'del(.statusLine)' "$settings" >"$settings.tmp" && mv "$settings.tmp" "$settings"
    echo "removed statusLine"
  fi
  herdr_config_remove
}

case "${1:-}" in
collect) collect ;;
bar) bar ;;
dashboard) dashboard ;;
draw)
  draw "${2:-0}"
  printf '\n'
  ;;
configure) configure ;;
uninstall) uninstall ;;
setup-keys) setup_keys ;;
*)
  printf 'usage: %s collect|bar|dashboard|draw|configure|uninstall|setup-keys\n' "$PLUGIN" >&2
  exit 2
  ;;
esac

