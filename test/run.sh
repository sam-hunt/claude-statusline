#!/usr/bin/env bash
# Runs the scripts against the fixtures and checks their output. Uses throwaway cache and config
# dirs, so it never touches the real ones.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname "$here")
fixtures="$here/fixtures"

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
export XDG_CACHE_HOME="$scratch/cache" CLAUDE_CONFIG_DIR="$scratch/claude" COLUMNS=160
sessions="$XDG_CACHE_HOME/claude-statusline/sessions"

failures=0
fail() { echo "FAIL $1"; shift; printf '  %s\n' "$@"; failures=$((failures + 1)); }

# Fixtures give reset times as "resets_in" seconds from now; turn them into absolute resets_at.
materialise() {
  jq --argjson now "$(date +%s)" '
    walk(if type == "object" and has("resets_in")
         then .resets_at = $now + .resets_in | del(.resets_in) else . end)'
}

# Writes the fixture transcript with its last request <ago> seconds ago (written with the 1h or 5m
# TTL), turning each entry's "ago" into a timestamp like Claude Code writes, and prints its path.
# Lines that aren't JSON are kept as they are.
transcript() {  # transcript <ago> [1h|5m]
  local path="$scratch/transcript-$1-${2:-1h}.jsonl"
  jq -rR --argjson now "$(date +%s)" --argjson ago "$1" --arg ttl "${2:-1h}" '
    . as $raw
    | ( fromjson?
        | if .uuid == "last-request" then .ago = $ago else . end
        | if .uuid == "last-request" and $ttl == "5m"
          then .message.usage.cache_creation |= {ephemeral_1h_input_tokens: 0, ephemeral_5m_input_tokens: .ephemeral_1h_input_tokens}
          else . end
        | .timestamp = ($now - .ago | todate | sub("Z$"; ".123Z")) | del(.ago)
        | tojson
      ) // $raw' < "$fixtures/transcript.jsonl" > "$path"
  echo "$path"
}

# Colour codes -> readable tags, so expectations can assert colours.
tags() {
  sed -E $'s/\e\\[31m/<red>/g; s/\e\\[33m/<yellow>/g; s/\e\\[32m/<green>/g; s/\e\\[97m/<white>/g;
           s/\e\\[38;5;141m/<purple>/g; s/\e\\[0m/<\\/>/g; s/\e\\[[0-9;]*m//g'
}

# Renders a fixture (from a clean cache unless KEEP_CACHE is set) with colours as tags.
render() {
  [[ -n ${KEEP_CACHE:-} ]] || rm -rf "$sessions"
  "$root/statusline.sh" | tags
}

expect() {  # expect <name> <output> <substring>...
  local name=$1 out=$2; shift 2
  for want in "$@"; do [[ $out == *"$want"* ]] || fail "$name: missing '$want'" "got: $out"; done
}
expect_not() {  # expect_not <name> <output> <substring>...
  local name=$1 out=$2; shift 2
  for unwanted in "$@"; do [[ $out != *"$unwanted"* ]] || fail "$name: unexpected '$unwanted'" "got: $out"; done
}

# --- Status line rendering ---

out=$(materialise < "$fixtures/fresh-session.json" | render)
expect fresh-session "$out" "<white>Opus 5.5</> (high)" "ctx -"
expect_not fresh-session "$out" "week" "resets"

out=$(materialise < "$fixtures/opus-on-pace.json" | render)
expect opus-on-pace "$out" \
  "ctx <green>80k</>/200k" "<white>week</> <green>52%</>" "·</> fable <green>40%</>" "resets 3d11h</> (50%)"
expect_not opus-on-pace "$out" "5h"

out=$(materialise < "$fixtures/fable-ahead-of-pace.json" | render)
expect fable-ahead-of-pace "$out" \
  "<purple>Fable 5.1</> <red>(xhigh)</>" "ctx <yellow>180k</>/1M" "·</> week <yellow>56%</>" \
  "<purple>fable</> <red>65%</>"

out=$(materialise < "$fixtures/reset-under-48h.json" | render)
expect reset-under-48h "$out" "ctx <red>301k</>/200k" "resets <yellow>1d21h</> (72%)"

out=$(materialise < "$fixtures/reset-under-24h.json" | render)
expect reset-under-24h "$out" "<red>(max)</>" "<green>90%</>" "resets <red>10.0h</> (94%)"

# Pace colouring at 50% through the week: green below +5, yellow +5 to +10, red above +10
for case in 54:green 55:yellow 60:yellow 61:red; do
  pct=${case%%:*} colour=${case#*:}
  out=$(materialise < "$fixtures/opus-on-pace.json" \
        | jq --argjson p "$pct" '.rate_limits.seven_day.used_percentage = $p' | render)
  expect "pace-$pct" "$out" "week</> <$colour>$pct%</>"
done

# Prompt cache TTL: minutes left after the context, from the last main-chain request in the transcript.
# Subagent, synthetic and non-JSON lines after it are ignored. Plain above 20m, yellow to 11m, red from 10m.
with_transcript() { jq --arg t "$(transcript "$@")" '.transcript_path = $t' "$fixtures/opus-on-pace.json"; }
out=$(with_transcript 1680 | materialise | render)
expect cache-ttl "$out" "ctx <green>80k</>/200k (32m) ·"
for case in 2370:'(21m)' 2430:'<yellow>(20m)</>' 2970:'<yellow>(11m)</>' 3030:'<red>(10m)</>' 3570:'<red>(1m)</>' 3700:'<red>(cold)</>'; do
  out=$(with_transcript "${case%%:*}" | materialise | render)
  expect "cache-ttl-${case%%:*}s-ago" "$out" "/200k ${case#*:}"
done
out=$(with_transcript 100 5m | materialise | render)
expect cache-ttl-5m "$out" "/200k <red>(4m)</>"
out=$(with_transcript 400 5m | materialise | render)
expect cache-ttl-5m-cold "$out" "/200k <red>(cold)</>"
out=$(materialise < "$fixtures/opus-on-pace.json" | jq '.transcript_path = "/nonexistent/transcript.jsonl"' | render)
expect cache-ttl-no-transcript "$out" "/200k ·"
expect_not cache-ttl-no-transcript "$out" "cold"

# Right-aligned to COLUMNS minus the margin Claude Code reserves
width=$(materialise < "$fixtures/opus-on-pace.json" | COLUMNS=150 "$root/statusline.sh" \
        | sed -E $'s/\e\\[[0-9;]*m//g' | tr -d '\n' | LC_ALL=C.UTF-8 wc -m)
[[ $width == 145 ]] || fail "alignment: expected width 145 at COLUMNS=150" "got: $width"

# --- Sharing usage across sessions ---

rm -rf "$sessions"; mkdir -p "$sessions"
now=$(date +%s)
echo "{\"seven_day\":{\"used_percentage\":15,\"resets_at\":$((now + 300000))}}" > "$sessions/other-session.json"
echo "{\"seven_day\":{\"used_percentage\":99,\"resets_at\":$((now - 10))}}" > "$sessions/expired-session.json"
out=$(materialise < "$fixtures/fresh-session.json" | KEEP_CACHE=1 render)
expect shared-usage "$out" "week</> <green>15%</>"
expect_not shared-usage "$out" "99%"

out=$(materialise < "$fixtures/opus-on-pace.json" \
      | jq '.rate_limits.seven_day.used_percentage = 10' | KEEP_CACHE=1 render)
expect shared-usage-highest-wins "$out" "week</> <green>15%</>"

# A corrupt or empty cache file is skipped rather than blanking the line
printf '{"seven_day":{"used_' > "$sessions/corrupt-session.json"
: > "$sessions/empty-session.json"
out=$(materialise < "$fixtures/fresh-session.json" | KEEP_CACHE=1 render)
expect corrupt-cache-skipped "$out" "Opus 5.5" "week</> <green>15%</>"

# --- Stop hook conversion ---

converted=$("$root/fetch-usage.sh" --convert < "$fixtures/usage-response.json")
[[ $(jq -S . <<<"$converted") == $(jq -S . < "$fixtures/usage-converted.json") ]] \
  || fail "usage conversion" "got: $converted"

# --- Install / uninstall ---

mkdir -p "$CLAUDE_CONFIG_DIR"
settings="$CLAUDE_CONFIG_DIR/settings.json"
cat > "$settings" <<'EOF'
{
  "model": "opus",
  "statusLine": { "type": "command", "command": "bash /old/statusline.sh" },
  "hooks": {
    "Stop": [
      { "hooks": [{ "type": "command", "command": "bash /old/path/fetch-usage.sh" }] },
      { "hooks": [{ "type": "command", "command": "notify-send done" }] }
    ]
  }
}
EOF
"$root/install.sh" >/dev/null && "$root/install.sh" >/dev/null
got=$(jq -c '{model, statusLine: .statusLine.command, stop: [.hooks.Stop[].hooks[].command]}' "$settings")
want="{\"model\":\"opus\",\"statusLine\":\"bash $CLAUDE_CONFIG_DIR/statusline/statusline.sh\",\"stop\":[\"notify-send done\",\"bash $CLAUDE_CONFIG_DIR/statusline/fetch-usage.sh\"]}"
[[ $got == "$want" ]] || fail "install (run twice)" "want: $want" "got:  $got"
[[ -L $CLAUDE_CONFIG_DIR/statusline/statusline.sh && -L $CLAUDE_CONFIG_DIR/statusline/fetch-usage.sh ]] \
  || fail "install: scripts not linked"

"$root/uninstall.sh" >/dev/null
got=$(jq -c . "$settings")
want='{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"notify-send done"}]}]}}'
[[ $got == "$want" ]] || fail "uninstall" "want: $want" "got:  $got"
[[ ! -e $CLAUDE_CONFIG_DIR/statusline ]] || fail "uninstall: link dir left behind"

if ((failures)); then echo "$failures failure(s)"; exit 1; fi
echo "All tests passed"
