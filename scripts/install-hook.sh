#!/bin/sh
# Installs Gooby's capture hook into ~/.claude/settings.json for two events:
#   UserPromptSubmit (what you ask) and Stop (Claude finished replying; used for timing
#   offers and for reading what Claude did).
# Safe to run more than once. Undo with: scripts/install-hook.sh --uninstall
# Backs up settings to ~/.claude/settings.json.gooby-backup first.
set -e
here="$(cd "$(dirname "$0")/.." && pwd)"
support="$HOME/Library/Application Support/Gooby"
dest="$support/gooby-capture-prompt.sh"
settings="$HOME/.claude/settings.json"
mkdir -p "$support" "$HOME/.claude"
[ -f "$settings" ] || echo '{}' > "$settings"
cp "$settings" "$settings.gooby-backup"
if [ "$1" != "--uninstall" ]; then
  cp "$here/hooks/gooby-capture-prompt.sh" "$dest"
  chmod +x "$dest"
fi
/usr/bin/python3 - "$settings" "$dest" "${1:-}" <<'PY'
import json, sys
path, dest, mode = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    data = json.load(f)
hooks = data.setdefault("hooks", {})
for event in ("UserPromptSubmit", "Stop"):
    groups = hooks.setdefault(event, [])
    for g in groups:
        g["hooks"] = [h for h in g.get("hooks", []) if "gooby-capture-prompt" not in h.get("command", "")]
    groups[:] = [g for g in groups if g.get("hooks")]
    if mode != "--uninstall":
        groups.append({"matcher": "", "hooks": [{"type": "command", "command": '"%s"' % dest, "timeout": 5}]})
    if not groups:
        del hooks[event]
if not hooks:
    del data["hooks"]
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
print(("Removed" if mode == "--uninstall" else "Installed") + " Gooby prompt hook in " + path)
PY
