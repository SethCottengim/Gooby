#!/bin/sh
# Gooby capture hook for Claude Code (UserPromptSubmit and Stop events).
# Writes {"gooby_tty":"<this chat's Terminal tab, e.g. ttys002>","hook":<hook JSON>}
# into Gooby's inbox. On Stop it also saves the end of the session log next to the
# event (<name>.tail.jsonl), so Gooby can read what Claude did even if the log is
# deleted before Gooby gets to it.
# Prints nothing (stdout from this hook would be added to the chat) and always exits 0.
[ -n "$GOOBY_INTERNAL" ] && exit 0   # skip Gooby's own `claude -p` calls
dir="$HOME/Library/Application Support/Gooby/inbox"
mkdir -p "$dir" 2>/dev/null || exit 0
base="$dir/$(date +%s)-$$"
tmp="$dir/.tmp-$$"
cat > "$tmp" 2>/dev/null || { rm -f "$tmp"; exit 0; }

# The Terminal tab this chat runs in: the first parent process that has a terminal.
tty=""; p=$PPID; n=0
while [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null && [ "$n" -lt 10 ]; do
  t=$(ps -o tty= -p "$p" 2>/dev/null | tr -d ' ')
  case "$t" in ""|"??") ;; *) tty="$t"; break ;; esac
  p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
  n=$((n + 1))
done

if grep -q '"hook_event_name"[[:space:]]*:[[:space:]]*"Stop"' "$tmp" 2>/dev/null; then
  tp=$(sed -n 's/.*"transcript_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$tmp" | head -n 1)
  if [ -n "$tp" ] && [ -f "$tp" ]; then
    tail -c 524288 "$tp" > "$dir/.tail-$$" 2>/dev/null && mv "$dir/.tail-$$" "$base.tail.jsonl" 2>/dev/null
  fi
fi

# The .json file appears last (atomic mv), so Gooby never sees an event without its log copy.
{ printf '{"gooby_tty":"%s","hook":' "$tty"; cat "$tmp"; printf '}'; } > "$tmp.w" 2>/dev/null \
  && mv "$tmp.w" "$base.json" 2>/dev/null
rm -f "$tmp" "$tmp.w" "$dir/.tail-$$" 2>/dev/null
exit 0
