# herdr-quota-monitor

Global usage for **coding agents** (Claude Code, Codex, Grok CLI, Factory Droid, Antigravity, Cursor) and **multiple LLM APIs** (OpenAI, Anthropic, OpenRouter, llmapi.ai, OrcaRouter, DeepSeek, Moonshot) inside [Herdr](https://herdr.dev), in one place.

<img width="749" height="32" alt="bar" src="https://github.com/user-attachments/assets/e55078d2-fd86-40ce-8799-0ac0d20c7d48" />
<img width="939" height="496" alt="dashboard" src="https://github.com/user-attachments/assets/53b7c5b8-1bad-46b1-9f73-d16fcfda28c8" />

## Features

- **Tab-bar summary**, always visible: Claude Code session/week windows + usage from LLM provider APIs. A percentage above 80 gets a `⚠️` suffix; a trailing `⁺` means another signed-in Claude profile is also active.
- **Popup dashboard** on a keybinding (`prefix+u`), with one tab per provider (`←`/`→`, `Tab`, or `1`-`9`): severity-colored bars with a threshold tick, reset countdowns (`↻ 33m · 8pm`), active session count, one compact line per other signed-in Claude profile.
- **Multi-account aware**: Claude Code payloads are clustered into per-account profiles; the most active profile is primary, others stay visible.
- **LLM providers from env keys**: each provider is enabled when its key is present (macOS keychain as fallback), unless disabled in the plugin config. Shown even when no Claude Code session is running.
- **Reversible install**: the statusLine wrapper chains to whatever was installed before and restores it on uninstall.

## Installation

Requirements: Herdr 0.8+, `bash`, `jq`, `curl`. macOS or Linux. On Windows, see [Windows](#windows) (no `jq` or `curl` needed).

```sh
# Install the plugin (adjust path as needed)
herdr plugin install /path/to/herdr-quota-monitor

# Configure: wraps statusLine, adds tab-bar entry + prefix+u dashboard
herdr plugin action invoke herdr-quota-monitor.configure

# Store your LLM API keys (macOS keychain or prints env var instructions)
herdr plugin action invoke herdr-quota-monitor.setup-keys
```

That is the whole setup. `configure` wraps the `statusLine` in `~/.claude/settings.json` (backing it up and chaining to whatever was there), writes the tab-bar entry and the `prefix+u` dashboard keybinding into herdr's `config.toml` (backed up; rolled back automatically if herdr rejects the result), and reloads the server. Data appears within a minute of any Claude Code session running.

<details>
<summary>Manual setup (what configure writes)</summary>

```toml
[ui]
tab_bar_right = [
  { type = "command", command = "bash /path/to/herdr-quota-monitor/bin/herdr-quota-monitor.sh bar", interval_seconds = 30, timeout_seconds = 5 },
]

[[keys.command]]
key = "prefix+u"
type = "popup"
command = "bash /path/to/herdr-quota-monitor/bin/herdr-quota-monitor.sh dashboard"
width = 104
height = 26
```

Then `herdr server reload-config`.
</details>

### Windows

`bin/herdr-quota-monitor.ps1` is the Windows version of the same plugin: same providers, options, tab bar and dashboard. It needs only Windows PowerShell 5.1 (built into Windows 10/11) or PowerShell 7; JSON and HTTP are built in, so there is no `jq` or `curl` to install.

```powershell
herdr plugin link C:\path\to\herdr-quota-monitor
herdr plugin action invoke herdr-quota-monitor.configure-windows
herdr plugin action invoke herdr-quota-monitor.setup-keys-windows   # optional
```

Differences from macOS/Linux:

- Actions end in `-windows` (`configure-windows`, `uninstall-windows`, `setup-keys-windows`); herdr needs unique ids per platform.
- `setup-keys-windows` stores keys as user environment variables (restart the herdr server to pick them up); the plugin `config` file works too. The Windows Credential Manager isn't read.
- Paths: herdr config `%APPDATA%\herdr\config.toml`, data `%LOCALAPPDATA%\herdr\plugins\herdr-quota-monitor`, Claude Code settings `%USERPROFILE%\.claude\settings.json`.
- The tab bar never waits on the network: a hidden PowerShell process refreshes the provider data in the background and the next tick shows it.
- A previous Claude Code statusLine is chained through Git Bash (as Claude Code runs it), or `cmd.exe` if Git Bash isn't installed.
- Cursor's login is read from `%USERPROFILE%\.cursor\auth.json`, or Cursor's state database when `python` is on `PATH`.

## Coding agents

No key needed: each agent is monitored when its own login or data is on this machine.

| Agent | Source | Shows |
| --- | --- | --- |
| Claude Code | statusLine hook (installed by `configure`) | 5h / week windows |
| Codex | newest `rate_limits` in `~/.codex/sessions/**/*.jsonl` (`$CODEX_HOME`), local only | plan windows (5h / week / month) |
| Grok CLI | token in `~/.grok/auth.json` → `cli-chat-proxy.grok.com/v1/billing` | credit usage % |
| Cursor | `accessToken` in `~/.config/cursor/auth.json`, `~/.cursor/auth.json`, or Cursor's Linux state DB → `api2.cursor.sh` | included / auto / API usage % |
| Factory Droid, Antigravity | [CodexBar](https://github.com/steipete/CodexBar) CLI (`codexbar usage --format json`), refreshed in a detached job so the tab bar never waits on it | rate windows |

Tokens are passed to `curl` on stdin, never on the command line. Approach borrowed from herdr-status-ui-bar.

## API Key Setup

Keys are read from environment variables first. A provider is monitored only when its key is set:

| Provider | Key variable | Shows |
| --- | --- | --- |
| Claude | none (statusLine); `ANTHROPIC_ADMIN_KEY`, else `ANTHROPIC_API_KEY` | 5h/week windows; API spend this month |
| OpenAI | `OPENAI_ADMIN_KEY`, else `OPENAI_API_KEY` | API spend this month |
| OpenRouter | `OPENROUTER_API_KEY` | key budget + free-model daily requests |
| llmapi.ai | `LLMAPI_API_KEY` | prepaid credit balance |
| OrcaRouter | `ORCAROUTER_API_KEY` | spendable wallet balance |
| DeepSeek | `DEEPSEEK_API_KEY` | account balance |
| Moonshot | `MOONSHOT_API_KEY` | account balance (api.moonshot.ai) |
| Portkey | `PORTKEY_API_KEY` | gateway spend this month (default workspace for an org key) |
| LiteLLM | `LITELLM_API_KEY` (+ `LITELLM_BASE_URL`, default `http://localhost:4000`) | the key's budget bar, or its spend when it has no budget |
| Cloudflare AI Gateway | `CLOUDFLARE_API_TOKEN` + `CLOUDFLARE_ACCOUNT_ID` | gateway cost + requests this month (all gateways) |
| AWS Bedrock | `aws` CLI + `AWS_PROFILE`, `AWS_ACCESS_KEY_ID` or `AWS_BEARER_TOKEN_BEDROCK` | Bedrock spend this month from Cost Explorer, Marketplace models included |

```bash
export OPENROUTER_API_KEY="sk-or-..."
export LLMAPI_API_KEY="..."
```

They can also go in the plugin `config` file (see Configuration). On macOS, `setup-keys` stores them in the keychain under service `herdr-quota-monitor-<provider>` instead.

OpenAI and Anthropic only report usage to an org **admin** key (`sk-admin-...` / `sk-ant-admin...`). With a normal key their tab shows `HTTP 401 · key has no usage access`.

AWS Bedrock is read through Cost Explorer (`aws ce get-cost-and-usage`), which needs IAM credentials with `ce:GetCostAndUsage` (a Bedrock API key alone can't read cost). AWS bills **$0.01 per Cost Explorer call**, so it is refreshed only every 6 hours (about $1.20/month); its data lags by up to a day anyway.

## Usage

The tab bar updates on its own every 30s. `prefix+u` opens the dashboard:

<img width="939" height="496" alt="dashboard" src="https://github.com/user-attachments/assets/53b7c5b8-1bad-46b1-9f73-d16fcfda28c8" />

Bars are lavender below 50%, amber from 50%, red from 80%; the faint `┊` tick marks where red begins.

## Commands

| Command | Purpose |
| --- | --- |
| `collect` | statusLine hook (invoked by Claude Code; captures payload, chains onward) |
| `bar` | one-line tab-bar summary |
| `dashboard` | interactive popup with bars |
| `draw` | one-shot render (debugging) |
| `configure` / `uninstall` | install/remove the statusLine wrapper, reversibly |
| `setup-keys` | interactive API key storage (macOS keychain) |

## How it works

Two independent data sources:

1. **statusLine push (no credentials, all platforms).** Claude Code invokes the configured `statusLine` command with a JSON payload on stdin that includes `rate_limits`. This plugin's `collect` captures it and chains to whatever statusLine command was installed before, passing stdin and stdout through untouched.

2. **LLM Provider APIs (optional).** OpenRouter `GET /api/v1/key`, llmapi.ai `GET /v1/credits`, OrcaRouter `GET /v1/tools/balance`, DeepSeek `GET /user/balance`, Moonshot `GET /v1/users/me/balance`, OpenAI `GET /v1/organization/costs` and Anthropic `GET /v1/organizations/cost_report` (month to date), using keys from environment variables (macOS keychain fallback). Fetches are cached for 5 minutes per provider.

**Several accounts.** Sessions signed into different accounts or organizations report different limits, so payloads are clustered into profiles keyed by their weekly reset time. The profile with the most active sessions is shown as primary; others are shown compactly. Profiles quiet for 30 minutes are dropped from the display.

**The 5h reading never disappears.** Claude Code sometimes omits the `five_hour` window from a payload; the previous unexpired window is kept. When the window has genuinely expired, the displays show `5h 0%`.

## Configuration

Tab-bar percentages carry their window: `h` = 5-hour, `w` = week, `m` = month, `d` = day (e.g. `Codex: 13%m`).

Optional `config` file in the plugin config dir (`herdr plugin config-dir herdr-quota-monitor`), shell syntax (`NAME=value`, one per line). The same variables work as environment overrides.

| Option | Default | Description |
| --- | --- | --- |
| `<PROVIDER>_API_KEY` | – | API keys, e.g. `OPENROUTER_API_KEY="sk-or-..."` (see [API Key Setup](#api-key-setup)) |
| `USE_API` | `1` | `0` disables all API fetches |
| `DISABLED_PROVIDERS` | – | Space-separated ids never fetched or shown, even with a key set: `claude codex grok droid antigravity cursor openai openrouter llmapi orcarouter deepseek moonshot portkey litellm cloudflare bedrock`. `claude` also hides the Claude Code statusLine windows |
| `BAR_HOT` | `80` | Above this %, the tab bar adds `⚠️` and dashboard bars turn red |
| `BAR_WARN` | `50` | From this %, dashboard bars turn amber |
| `BAR_GAUGE` | `0` | `1` shows a progress bar next to each tab-bar percentage (`Claude: █░░░░░░░ 7%h ██████░░ 76%w`) |
| `BAR_GAUGE_W` | `8` | Progress bar width, in cells |
| `BAR_POSITION` | `top-right` | `top-right`, `top-center`, `bottom-right` or `bottom-center`. Top/bottom sets herdr's `tab_bar_position` (the whole tab row) when you run `configure`; center pads the entry with spaces to the middle of the row. Left and right-side (vertical) positions aren't possible: herdr only has a right-aligned, one-line slot in the tab row |
| `LLMAPI_CREDITS` | – | Your usual llmapi.ai balance in $ (e.g. `200`): the balance then gets a gauge of what's left, draining as you spend (`LLMAPI: ███████░ $145.56 left`), with `⚠️` once less than 100 − `BAR_HOT`% is left |
| `OPENROUTER_CREDITS` | – | Same for an OpenRouter key without a budget: its "$X used" gets a draining gauge of what's left of this amount (keys with a budget already have one) |
| `BAR_PROVIDERS` | all | Provider ids shown in the tab bar, e.g. `"claude codex openrouter"` (commas and any capitalization work too), shown in the order you list them. The dashboard still shows every enabled provider (use `DISABLED_PROVIDERS` to hide one everywhere) |
| `TEXT_DIR` | `ltr` | `rtl` mirrors the tab bar and dashboard for right-to-left readers |
| `STALE_SECS` | `1800` | How long (seconds) a Claude profile counts as fresh |

### Progress bar, right-to-left, position

Add the options you want to the config file, e.g. at the default path:

```sh
cat >> ~/.config/herdr/plugins/config/herdr-quota-monitor/config <<'EOF'
BAR_GAUGE=1     # progress bar next to each percentage
TEXT_DIR=rtl    # right-to-left tab bar and dashboard
EOF
```

Nothing to restart: the tab bar picks it up on its next refresh (within 30s), the dashboard the next time you open it. To turn an option off, delete its line or set `BAR_GAUGE=0` / `TEXT_DIR=ltr`. `BAR_POSITION=bottom-*` (or going back to `top-*`) also needs `herdr plugin action invoke herdr-quota-monitor.configure` once, to move herdr's tab row.

## Troubleshooting

- **Tab bar shows `✳  LLM —`**: no Claude Code session has reported for 30 minutes and no API keys configured. Open a session or run `setup-keys`.
- **A provider is missing**: check its key variable is exported in the environment herdr runs in (restart the herdr server after adding them), that `USE_API` is not `0`, and that it is not in `DISABLED_PROVIDERS`.
- **A keychain dialog appeared**: that is the first API fetch reading your key. "Always Allow" stops it from asking again.
- **Percentages look uncolored in the tab bar**: expected. The tab bar renders no ANSI colors; `⚠️` above 80 is the only marker there. The dashboard has the colors.

## Uninstall

```sh
herdr plugin action invoke herdr-quota-monitor.uninstall
herdr plugin uninstall herdr-quota-monitor
```

The uninstall action restores the previous statusLine and removes every config.toml line it added (they all carry a `# herdr-quota-monitor` marker).
