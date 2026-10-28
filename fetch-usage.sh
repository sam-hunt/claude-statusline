#!/usr/bin/env bash
# Stop hook: when a turn ends, fetch account usage from the endpoint behind /usage (which includes
# per-model weekly windows such as Fable) into the status line's shared cache, in the same shape as
# the status line's rate_limits. Runs detached and silent: the turn isn't delayed, and nothing it
# reads or prints reaches the conversation.
#
#   fetch-usage.sh            run as the hook (hook JSON on stdin is ignored)
#   fetch-usage.sh --convert  convert a saved usage response on stdin and print the result

# {"seven_day": {"utilization": 4.0, "resets_at": "2026-11-04T02:00:00.123+00:00"}, ...,
#  "limits": [{"kind": "weekly_scoped", "percent": 7, "scope": {"model": {"display_name": "Fable"}}, ...}]}
#   -> {"seven_day": {"used_percentage": 4.0, "resets_at": 1793757600}, "seven_day_fable": {...}}
convert() {
  jq -c '
    def epoch:
      if type == "string" then sub("\\.[0-9]+"; "") | sub("(\\+00:00)?$"; "Z") | sub("ZZ$"; "Z") | fromdateiso8601
      else . end;

    ( with_entries(select(.value | type == "object" and .utilization != null and .resets_at != null))
      | map_values({used_percentage: .utilization, resets_at: (.resets_at | epoch)})
    )
    # Per-model weekly limits only appear in the limits list
    + ( [ .limits[]?
          | select(.kind == "weekly_scoped" and .percent != null and .resets_at != null
                   and .scope.model.display_name != null)
          | { key: "seven_day_\(.scope.model.display_name | ascii_downcase | gsub("[^a-z0-9]+"; "_"))",
              value: {used_percentage: .percent, resets_at: (.resets_at | epoch)} } ]
        | from_entries
      )
  '
}

if [[ ${1:-} == --convert ]]; then convert; exit; fi

cat >/dev/null  # hook input isn't needed

cache_root="${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline"
mkdir -p "$cache_root/sessions"

# Debounce: concurrent sessions finishing turns together share one fetch.
stamp="$cache_root/last-fetch"
if [[ -n $(find "$stamp" -newermt '-30 seconds' 2>/dev/null) ]]; then exit 0; fi
touch "$stamp"

(
  credentials="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json"
  token=$(jq -r '.claudeAiOauth.accessToken // empty' "$credentials" 2>/dev/null)
  [[ -n $token ]] || exit 0

  # Header passed on stdin so the token never appears in the process list.
  resp=$(printf 'Authorization: Bearer %s\n' "$token" | curl -sf --max-time 10 -H @- \
    -H 'anthropic-beta: oauth-2025-04-20' https://api.anthropic.com/api/oauth/usage) || exit 0

  printf '%s' "$resp" > "$cache_root/oauth-usage-raw.json"

  tmp=$(mktemp "$cache_root/sessions/.tmp.XXXXXX")
  convert <<<"$resp" > "$tmp" && mv "$tmp" "$cache_root/sessions/account-usage.json" || rm -f "$tmp"
) </dev/null >/dev/null 2>&1 &
disown
exit 0
