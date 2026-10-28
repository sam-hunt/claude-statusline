#!/usr/bin/env bash
# Claude Code status line, one row:
#   user@host:cwd  (left)                 model (effort) · ctx · weekly usage · reset  (right)
input=$(cat)
cache_root="${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline"
cache_dir="$cache_root/sessions"
mkdir -p "$cache_dir"

# Keep the latest raw input so new or undocumented fields can be inspected.
printf '%s' "$input" > "$cache_root/last-input.json"

# Share usage windows across concurrent sessions: each session caches the rate_limits from its
# last API response, and every status line shows the freshest figure any session has seen.
find "$cache_dir" -name '*.json' -mtime +8 -delete 2>/dev/null
session_id=$(jq -r '.session_id // empty' <<<"$input")
if [[ -n $session_id ]] && jq -e '.rate_limits | type == "object"' <<<"$input" >/dev/null; then
  tmp=$(mktemp "$cache_dir/.tmp.XXXXXX")
  jq -c '.rate_limits' <<<"$input" > "$tmp" && mv "$tmp" "$cache_dir/$session_id.json"
fi

# Claude Code sets COLUMNS to the terminal width; the margin covers the columns it reserves (it truncates with … past that).
jq -r \
  --slurpfile seen <(cat "$cache_dir"/*.json 2>/dev/null) \
  --arg userhost "$(whoami)@$(hostname -s)" \
  --argjson cols "${COLUMNS:-120}" \
  --argjson margin "${STATUSLINE_RIGHT_MARGIN:-5}" '
  def esc($c): "\u001b[\($c)m";
  def reset: esc("0");
  def tok_color($t): if $t >= 250000 then esc("31") elif $t >= 150000 then esc("33") else esc("32") end;
  def tok:
    if . >= 1000000 then "\(. / 100000 | floor / 10)M"
    elif . >= 1000 then "\(. / 1000 | floor)k"
    else tostring end;
  def visible_len: gsub("\u001b\\[[0-9;]*m"; "") | length;
  # Whole percent of the 7-day window elapsed, given its reset time
  def week_elapsed($resets_at):
    [[(604800 - ($resets_at - now | floor)) * 100 / 604800 | floor, 0] | max, 100] | min;
  # Weekly usage coloured by pace: how far it is ahead of progress through the week
  def pct_segment($tag; $w):
    if $w.used_percentage != null
    then ($w.used_percentage | floor) as $p
      | ($p - week_elapsed($w.resets_at)) as $ahead
      | (if $ahead > 10 then esc("31") elif $ahead >= 5 then esc("33") else esc("32") end) as $pace
      | "\($tag) \($pace)\($p)%\(reset)"
    else empty end;

  # Fable gets purple; otherwise bright white marks what is active / which weekly quota matters
  ((.model.id // "") + " " + (.model.display_name // "") | test("fable"; "i")) as $is_fable
  | (if $is_fable then esc("38;5;141") else esc("97") end) as $active

  | "\(esc("01;32"))\($userhost)\(reset):\(esc("01;34"))\(.cwd)\(reset)" as $left

  # Model and effort
  | ( "\($active)\(.model.display_name // .model.id)\(reset)"
      + ( if .effort.level == null then ""
          elif .effort.level == "xhigh" or .effort.level == "max" then " \(esc("31"))(\(.effort.level))\(reset)"
          else " (\(.effort.level))" end )
    ) as $model

  # Context window: input-only token count, matching how used_percentage is calculated
  | .context_window as $c
  | ($c.current_usage
      | if . then .input_tokens + .cache_creation_input_tokens + .cache_read_input_tokens
        else null end) as $used
  | ( if $used == null then "ctx -"
      else "ctx \(tok_color($used))\($used | tok)\(reset)/\($c.context_window_size | tok)"
      end
    ) as $ctx

  # Merge every session'"'"'s cached windows. Usage only rises within a window, so for each window
  # take the newest period (latest resets_at, allowing jitter) and the highest usage seen in it.
  | ( [$seen[] | objects | keys[]] | unique
      | map(. as $k
          | [$seen[] | objects | .[$k] | objects
              | select(.used_percentage != null and (.resets_at // 0) > now)]
          | select(length > 0)
          | (map(.resets_at) | max) as $latest
          | {key: $k, value: (map(select(.resets_at >= $latest - 3600)) | max_by(.used_percentage))})
      | from_entries
    ) as $rl

  # Weekly windows: overall, plus the Fable one cached by the Stop hook
  | ($rl | to_entries | map(select(.key | test("fable"; "i"))) | first | .value) as $fable
  | ( $rl.seven_day.resets_at
      | if . == null then null
        else (. - now | floor) as $s
        | (if $s < 86400 then esc("31") elif $s < 172800 then esc("33") else "" end) as $soon
        | week_elapsed($rl.seven_day.resets_at) as $elapsed
        | ( if $s >= 86400 then "\($s / 86400 | floor)d\($s % 86400 / 3600 | floor)h"
            else ([$s / 360 | floor, 0] | max) as $tenths | "\($tenths / 10 | floor).\($tenths % 10)h" end
          ) as $remaining
        | "resets \($soon)\($remaining)\(reset) (\($elapsed)%)"
        end
    ) as $reset

  | ([$model, $ctx, pct_segment(if $is_fable then "week" else "\($active)week\(reset)" end; $rl.seven_day),
      pct_segment(if $is_fable then "\($active)fable\(reset)" else "fable" end; $fable), ($reset // empty)]
      | join(" \(esc("2"))·\(reset) ")) as $right

  | ([$cols - $margin - ($left | visible_len) - ($right | visible_len), 2] | max) as $pad
  | $left + (" " * $pad) + $right
' <<<"$input"
