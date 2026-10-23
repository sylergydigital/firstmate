#!/usr/bin/env bash
# Scripted primary cycle: arm the watcher the way firstmate does, and after each
# wake drain the queue and acknowledge it with the exact printed command. Every
# arm result, queued wake row, and acknowledgement result line is logged.
set -u
ROOT=$1; LOG=$2
STATE="$FM_HOME/state"
while :; do
  [ -e "$STATE/.lab-stop" ] && exit 0
  arm_out=$("$ROOT/bin/fm-watch-arm.sh" 2>&1)
  printf '%s\tARM\t%s\n' "$(date +%T)" "$(printf '%s' "$arm_out" | tr '\n' '|')" >> "$LOG"
  [ -e "$STATE/.lab-stop" ] && exit 0
  while IFS= read -r row; do
    printf '%s\tWAKE\t%s\n' "$(date +%T)" "$row" >> "$LOG"
  done < <(cat "$STATE/.wake-queue" 2>/dev/null)
  "$ROOT/bin/fm-wake-drain.sh" > "$STATE/.lab-drain.out" 2> "$STATE/.lab-drain.err"
  req=$(grep '^WAKE_ACK_REQUIRED:' "$STATE/.lab-drain.err" | tail -1)
  seq=$(printf '%s' "$req" | sed -n 's/.*--ack-through \([0-9][0-9]*\) --recovery-generation .*/\1/p')
  gen=$(printf '%s' "$req" | sed -n 's/.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p')
  if [ -n "$seq" ] && [ -n "$gen" ]; then
    ack=$("$ROOT/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" 2>&1); rc=$?
    printf '%s\tACK\t%s\t(rc=%s)\n' "$(date +%T)" "$(printf '%s' "$ack" | tr '\n' '|')" "$rc" >> "$LOG"
  else
    printf '%s\tNOACK\t%s\n' "$(date +%T)" "$(tr '\n' '|' < "$STATE/.lab-drain.err")" >> "$LOG"
  fi
done
