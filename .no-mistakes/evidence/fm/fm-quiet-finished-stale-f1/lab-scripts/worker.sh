#!/usr/bin/env bash
# Scripted stand-in for a finished crew pane (a bare shell: its agent has
# exited). It prints its delivery, then either stays stable (tick=0) or prints
# a status-bar clock line every <tick> seconds, the churn a finished pane shows.
# When a steer lands in its steering inbox it acts on it the way the brief
# says - read each record, then mv it into handled/ - and appends no status
# line, as a real rework turn does.
task=$1; tick=${2:-0}; state="$FM_HOME/state"
printf 'worker %s: delivered, sitting at its prompt\n' "$task"
i=0; s=0
while :; do
  for m in "$state/$task.inbox"/*.msg; do
    [ -e "$m" ] || continue
    [ -e "$state/$task.lab-defer" ] && break   # still in its last turn: reads the inbox later
    printf 'acting on steer %s: %s\n' "${m##*/}" "$(sed -n '/^--$/,$p' "$m" | sed 1d | head -1)"
    mkdir -p "$state/$task.inbox/handled"
    mv "$m" "$state/$task.inbox/handled/"
    printf 'rework in progress (no status appended)\n'
  done
  sleep 1; s=$((s + 1))
  if [ "$tick" -gt 0 ] && [ $((s % tick)) -eq 0 ]; then
    i=$((i + 1)); printf 'clock %s tick %d\n' "$(date +%T)" "$i"
  fi
done
