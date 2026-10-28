# claude-statusline

A one-row [Claude Code status line](https://code.claude.com/docs/en/statusline) showing the active model, context usage and weekly plan usage, including the per-model Fable weekly limit, coloured by whether your usage is running ahead of the week.

```
user@host:/home/user/project                Opus 5.5 (high) · ctx 80k/200k · week 52% · fable 40% · resets 3d11h (50%)
```

The working directory is on the left; everything else is right-aligned.

## What it shows

| Segment        | Meaning                                                       | Colour                                            |
| -------------- | ------------------------------------------------------------- | ------------------------------------------------- |
| `Opus 5.5`     | Current model                                                 | Purple for Fable, bright white otherwise          |
| `(high)`       | Reasoning effort, if the model supports it                    | Red for `xhigh` and `max`                         |
| `ctx 80k/1M`   | Tokens in the context window / window size                    | Green under 150k, yellow 150k–250k, red from 250k |
| `week 52%`     | Weekly usage across all models                                | By pace (below)                                   |
| `fable 40%`    | Weekly Fable usage                                            | By pace (below)                                   |
| `resets 3d11h` | Time until the weekly reset; hours to one decimal under a day | Yellow under 48h, red under 24h                   |
| `(50%)`        | How far through the week you are                              |                                                   |

**Pace colouring** compares weekly usage with progress through the week, with some leniency for irregular usage: green when usage is less than 5 points ahead, yellow from 5 to 10 points ahead, red when more than 10 points ahead. At `(50%)`, `week 54%` is green, `week 55%` yellow and `week 61%` red.

**Which quota is in play:** the label of the weekly quota the current model mostly draws from is highlighted. On Fable, `fable` is purple and `week` is plain; on other models, `week` is bright white and `fable` is plain.

## Requirements

- Claude Code, signed in with a Pro or Max subscription (usage limits aren't shown otherwise)
- `bash`, `jq` (1.6 or later), `curl`
- Linux or WSL. macOS isn't supported yet: Claude Code keeps credentials in the Keychain there.

## Install

```sh
git clone https://github.com/sam-hunt/claude-statusline.git
cd claude-statusline
./install.sh
```

The installer links the scripts into `~/.claude/statusline/` and adds the `statusLine` setting and a `Stop` hook to `~/.claude/settings.json`, backing it up first. Your other settings and hooks are left alone, and re-running it is safe. Because the scripts are linked, `git pull` updates them.

`./uninstall.sh` removes both settings entries and the links.

## How it works

**`statusline.sh`** is the status line. Claude Code runs it after each message and every 60 seconds, passing session data as JSON on stdin. It runs locally and uses no API tokens.

Claude Code only gives each session the usage figures from that session's own last API response, so an idle session would show stale numbers while another session works. To fix that, each session saves its figures to `~/.cache/claude-statusline/sessions/`, and every status line shows the highest usage any session has reported in the current week. Usage only rises within a week, so the highest figure is the newest.

**`fetch-usage.sh`** is a Stop hook that supplies the Fable figure, which isn't in the status line data. When a turn ends, it fetches the same data `/usage` shows and adds it to the shared cache. It makes at most one request every 30 seconds across all sessions, runs in the background so turns aren't delayed, and never polls while you're idle. It reads your Claude Code login token from `~/.claude/.credentials.json` and sends it only to Anthropic's API.

> The endpoint behind `/usage` isn't a public API and could change without notice. If it does, the Fable segment disappears and the rest keeps working.

## Configuration

| Environment variable      | Default     | Purpose                                                                              |
| ------------------------- | ----------- | ------------------------------------------------------------------------------------ |
| `STATUSLINE_RIGHT_MARGIN` | `5`         | Columns kept free on the right. Increase if the end of the line is cut off with `…`. |
| `CLAUDE_CONFIG_DIR`       | `~/.claude` | Claude Code's config directory, if you've moved it                                   |

## Troubleshooting

- `~/.cache/claude-statusline/last-input.json` holds the latest status line input from Claude Code.
- `~/.cache/claude-statusline/oauth-usage-raw.json` holds the latest raw usage response.
- `echo '{}' | bash ~/.claude/statusline/fetch-usage.sh` runs the hook by hand; check the files above afterwards.

## Tests

```sh
./test/run.sh
```

The tests render the made-up sessions in `test/fixtures/` and check text and colours, pace thresholds, alignment, usage sharing between sessions, the usage conversion and install/uninstall. They use temporary directories and never touch your real settings or cache.
