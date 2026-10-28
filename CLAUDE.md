# CLAUDE.md

Bash + jq status line for Claude Code. See README.md for what it shows and how it's installed.

## Working on it

- Run `./test/run.sh` after every change. It uses throwaway `XDG_CACHE_HOME` and `CLAUDE_CONFIG_DIR`, so it's safe to run anywhere.
- Add or adjust a fixture in `test/fixtures/` for new behaviour. Fixtures give reset times as `resets_in` (seconds from now); the runner converts them to absolute `resets_at`. Pick `resets_in` values a little way from display boundaries (e.g. `302000`, not `302400`), because a second or two passes between building the input and rendering it.
- Fixtures must be made up. Never copy real session input, cache files or usage responses into the repo: they contain session IDs, local paths and usernames.
- To see what Claude Code actually sends, read `~/.cache/claude-statusline/last-input.json`; for the usage endpoint, `oauth-usage-raw.json` in the same directory.

## jq gotchas (Ubuntu ships jq 1.6)

- `label` is a reserved word: it can't be used as a function name or a `$variable` name.
- The jq program is a single-quoted bash string, so apostrophes in jq comments break the script. Reword, or write `'"'"'`.
- `expr as $x | ...` where `expr` yields `empty` produces no output at all, silently blanking the status line. Bind `null` instead and drop it at the point of use with `($x // empty)`.
- `%` truncates its operands to integers; `floor` first when working from `now`.
- `fromdateiso8601` only accepts `YYYY-MM-DDTHH:MM:SSZ`, so strip fractional seconds and the `+00:00` offset first (see `epoch` in fetch-usage.sh).
- `"str" * 0` is `null`, not `""`; padding is clamped to a minimum of 2.

## Claude Code behaviour this relies on

- The terminal width comes from `$COLUMNS`; `tput cols` doesn't work because output is captured. Claude Code reserves about 4 columns and cuts off anything past that with `…`, hence the default right margin of 5.
- The status line runs locally and uses no API tokens; it re-runs on events and every `refreshInterval` seconds.
- `rate_limits` in the status line input only has `five_hour` and `seven_day`, taken from that session's own last API response. That's why sessions share figures through the cache.
- Per-model weekly limits (Fable) are only in the private `/api/oauth/usage` endpoint, under `limits[]` as `kind: "weekly_scoped"` with `scope.model.display_name`. The top-level `seven_day_*` keys for other models are null, and other top-level keys are internal codenames, so don't rely on them. `utilization`/`percent` are 0–100.
- Hook stdout and stderr aren't shown to Claude when the hook exits 0, which keeps credential handling out of the conversation. Keep it that way: the hook must stay silent and always exit 0.

## Design decisions (from the owner)

- **No polling of the usage endpoint.** It's fetched only when a turn ends (Stop hook), debounced to once per 30 seconds across sessions. Reading the local cache on a timer is fine.
- **Merge rule:** for each window, take the latest week (by `resets_at`, allowing an hour of jitter) and the highest usage any source reported in it. Usage only rises within a week, so no timestamps are needed.
- **Pace colours** compare the displayed whole-number usage % with the displayed whole-number % of the week elapsed, so the colour always agrees with the numbers on screen.
- **ASCII-only glyphs**, apart from `·` and the `…` Claude Code adds itself. The owner's terminal font has no `↻`-style symbols.

## Auto mode

Claude reading `~/.claude/.credentials.json` or editing hooks in `~/.claude/settings.json` is blocked by the auto mode classifier. Token handling belongs inside the scripts. To install or update the hook on a machine, ask the owner to run `./install.sh` rather than editing settings directly.
