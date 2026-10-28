#!/usr/bin/env bash
# Removes the status line and Stop hook from ~/.claude/settings.json and the links in
# ~/.claude/statusline/. Other settings and hooks are left alone. The cache in
# ~/.cache/claude-statusline/ is kept; delete it by hand if you want it gone.
set -euo pipefail

claude_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
dest="$claude_dir/statusline"
settings="$claude_dir/settings.json"

if [[ -f $settings ]]; then
  backup="$settings.bak.$(date +%Y%m%d%H%M%S)"
  cp "$settings" "$backup"
  echo "Backed up settings to $backup"

  tmp=$(mktemp "$settings.XXXXXX")
  jq '
    if (.statusLine.command // "") | test("statusline\\.sh") then del(.statusLine) else . end
    | if .hooks.Stop then
        .hooks.Stop = [ .hooks.Stop[]
                        | .hooks |= map(select((.command // "") | test("fetch-usage\\.sh") | not))
                        | select(.hooks | length > 0) ]
        | if .hooks.Stop == [] then del(.hooks.Stop) else . end
        | if .hooks == {} then del(.hooks) else . end
      else . end
  ' "$settings" > "$tmp" && mv "$tmp" "$settings"
fi

rm -f "$dest/statusline.sh" "$dest/fetch-usage.sh"
rmdir "$dest" 2>/dev/null || true

echo "Uninstalled"
