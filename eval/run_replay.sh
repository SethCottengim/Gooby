#!/bin/sh
# Builds the replay tool from Gooby's own SkillCoach sources and runs it.
#   eval/run_replay.sh build
#   eval/run_replay.sh <setup> <run> [extra args, e.g. --limit 5]
set -e
root="$(cd "$(dirname "$0")/.." && pwd)"
bin="$root/build/gooby-replay"
if [ "$1" = "build" ] || [ ! -x "$bin" ]; then
  mkdir -p "$root/build"
  swiftc -O -swift-version 6 -o "$bin" \
    "$root/Sources/SkillCoach/IntentStore.swift" \
    "$root/Sources/SkillCoach/ClaudeCLI.swift" \
    "$root/Sources/SkillCoach/IntentClassifier.swift" \
    "$root/Sources/SkillCoach/TranscriptContext.swift" \
    "$root/Sources/SkillCoach/PromptInbox.swift" \
    "$root/eval/replay/main.swift"
  [ "$1" = "build" ] && { echo "built $bin"; exit 0; }
fi
setup="$1"; run="$2"; shift 2
exec "$bin" --setup "$setup" --run "$run" "$@"
