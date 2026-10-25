# AGENTS.md

## Keep the bash and PowerShell versions in sync

The plugin ships two implementations of the same script:

- `bin/herdr-quota-monitor.sh` — bash, for macOS and Linux (uses `jq` and `curl`)
- `bin/herdr-quota-monitor.ps1` — PowerShell 5.1+, for Windows (built-in JSON/HTTP, no `jq` or `curl`)

Every change to one must be made in the other in the same change: commands, providers, options, output format (tab bar and dashboard), and herdr/Claude Code config handling. Windows-only differences are listed in the README's Windows section; keep that list current. New manifest entries need a Windows twin with a `-windows` id and `platforms = ["windows"]` in `herdr-plugin.toml`.

PowerShell pitfalls:

- Save the `.ps1` as UTF-8 **with BOM**, or Windows PowerShell 5.1 garbles `✳ █ ↻ ⚠️`.
- Variable names are case-insensitive: script-wide names (`$Sink`, `$ESC`, `$PayloadFile`, `$Options`) must not collide with any function's locals (`$out`, `$e`, `$payload`, `$cfg`).
- Read files you pass to `ConvertTo-Json` with `[IO.File]::ReadAllText`, not `Get-Content` (its strings carry provider properties that make `ConvertTo-Json` hang).
- Write output with `Emit`, never let a function return stray values into the tab-bar line.

## Testing

- Check both: `bash -n bin/herdr-quota-monitor.sh`, and parse the `.ps1` with `[System.Management.Automation.Language.Parser]::ParseFile`. From WSL, run the `.ps1` with `powershell.exe`.
- Compare outputs: the same fixture data must give the same `bar` line from both scripts.
- `bar` and `draw` only read the home directory. `configure`, `uninstall` and `collect` write to Claude Code settings and herdr's config: never run them against real ones. Point `HOME` (or `USERPROFILE`, `APPDATA`, `LOCALAPPDATA` on Windows), `HERDR_CONFIG_PATH`, `HERDR_PLUGIN_STATE_DIR` and `HERDR_PLUGIN_CONFIG_DIR` at a scratch directory, and set `HERDR_BIN_PATH` to a missing binary so the live herdr server isn't reloaded.
