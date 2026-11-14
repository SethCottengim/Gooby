#!/bin/sh
# Runs (or resumes) all 12 replay runs, at most MAX_PARALLEL at a time, at the lowest
# CPU priority so the rest of the Mac stays responsive.
#   MAX_PARALLEL=6 sh eval/run_all.sh
# Each run resumes where it stopped. Pause any time:
#   pkill -TERM -f "Gooby-treehouse/build/gooby-replay"
set -u
here="$(cd "$(dirname "$0")" && pwd)"
max="${MAX_PARALLEL:-6}"
logs="$HOME/Library/Application Support/Gooby/eval/replay/logs"
mkdir -p "$logs"
# Run 1 of every setup first, so a partial finish still compares all four setups.
jobs="prompt:1 reply:1 title:1 reply+title:1 prompt:2 reply:2 title:2 reply+title:2 prompt:3 reply:3 title:3 reply+title:3"
for job in $jobs; do
  while [ "$(pgrep -f 'build/gooby-replay' | wc -l | tr -d ' ')" -ge "$max" ]; do sleep 5; done
  setup="${job%%:*}"; run="${job##*:}"
  nice -n 19 sh "$here/run_replay.sh" "$setup" "$run" >> "$logs/$setup-run$run.log" 2>&1 &
  sleep 2  # let it start so the count above sees it
done
wait
echo "all replay runs exited"
for job in $jobs; do tail -n 1 "$logs/${job%%:*}-run${job##*:}.log"; done
