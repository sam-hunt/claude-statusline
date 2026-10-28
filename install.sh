#!/usr/bin/env bash
# Links the scripts into ~/.claude/statusline/ and registers the status line and Stop hook in
# ~/.claude/settings.json. Safe to re-run; other settings and hooks are left alone.
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
claude_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
dest="$claude_dir/statusline"
settings="$claude_dir/settings.json"

for dep in jq curl; do
  command -v "$dep" >/dev/null || { echo "install: $dep is required" >&2; exit 1; }
done

# Links rather than copies, so a git pull updates the installed scripts.
mkdir -p "$dest"
ln -sfn "$repo/statusline.sh" "$dest/statusline.sh"
ln -sfn "$repo/fetch-usage.sh" "$dest/fetch-usage.sh"

if [[ -f $settings ]]; then
  backup="$settings.bak.$(date +%Y%m%d%H%M%S)"
  cp "$settings" "$backup"
  echo "Backed up settings to $backup"
else
  echo '{}' > "$settings"
fi

# Replace any earlier fetch-usage.sh hook (whatever its path) so re-running doesn't duplicate it.
tmp=$(mktemp "$settings.XXXXXX")
jq --arg statusline "bash $dest/statusline.sh" --arg hook "bash $dest/fetch-usage.sh" '
  .statusLine = {type: "command", command: $statusline, refreshInterval: 60}
  | .hooks.Stop = (
      [ .hooks.Stop[]?
        | .hooks |= map(select((.command // "") | test("fetch-usage\\.sh") | not))
        | select(.hooks | length > 0) ]
      + [{hooks: [{type: "command", command: $hook}]}]
    )
' "$settings" > "$tmp" && mv "$tmp" "$settings"

echo "Installed: status line and Stop hook registered in $settings"
