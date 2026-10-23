#!/usr/bin/env bash
# run-churn-lab.sh <root> <evidence-prefix> <phase1-secs> <with-steer:0|1>
# One lab run of the audit's pattern against the watcher in <root>: finished
# crew panes whose PR firstmate recorded through bin/fm-pr-check.sh, beside
# controls, all supervised by the scripted primary cycle for <phase1-secs>; then,
# when asked, firstmate steers two of them through bin/fm-send.sh.
set -u
ROOT=$1; EVP=$2; P1=$3; STEER=$4; SCR=$(cd "$(dirname "$0")" && pwd)
GH=https://github.com/kunchenguid/firstmate/pull
LAB=$("$SCR/lab-up.sh" "$ROOT") || exit 1
. "$SCR/lab-env.sh"
LOG="$EVP.cycle.log"; : > "$LOG"
note() { printf '%s\tLAB\t%s\n' "$(date +%T)" "$*" >> "$LOG"; }
note "lab=$LAB root=$ROOT FM_POLL=2 FM_PAUSE_RESURFACE_SECS=60"
"$SCR/add-task.sh" held-merge 8 "done: PR $GH/7677 checks green"
"$SCR/add-task.sh" stable-merge 0 "done: PR $GH/7676 checks green"
"$SCR/add-task.sh" unrecorded 8 "done: PR $GH/7675 checks green"
"$SCR/add-task.sh" blocked-pr 0 'blocked: the PR needs a release-host credential'
"$SCR/add-task.sh" rework-merge 8 "done: PR $GH/7674 checks green"
for spec in held-merge:7677 stable-merge:7676 blocked-pr:7670 rework-merge:7674; do
  out=$("$ROOT/bin/fm-pr-check.sh" "${spec%%:*}" "$GH/${spec#*:}" 2>/dev/null | tail -1)
  note "fm-pr-check.sh ${spec%%:*} $GH/${spec#*:} -> $out"
done
note "no PR recorded for unrecorded (control)"
"$SCR/primary-loop.sh" "$ROOT" "$LOG" &
LOOP=$!
sleep "$P1"
if [ "$STEER" = 1 ]; then
  note "STEER held-merge: $("$ROOT/bin/fm-send.sh" held-merge 'rename the flag before the merge' 2>&1 | tail -1)"
  note "STEER rework-merge: $("$ROOT/bin/fm-send.sh" rework-merge 'address the review comment on the flag name' 2>&1 | tail -1)"
  i=0; while [ ! -e "$FM_HOME/state/rework-merge.inbox/handled/001.msg" ] && [ "$i" -lt 20 ]; do sleep 0.5; i=$((i + 1)); done
  sleep 1
  printf 'done: addressed the review\n' >> "$FM_HOME/state/rework-merge.status"
  note "rework-merge worker appended its pre-validation handoff: done: addressed the review"
  sleep 45
fi
touch "$FM_HOME/state/.lab-stop"
i=0
while kill -0 "$LOOP" 2>/dev/null && [ "$i" -lt 30 ]; do
  kill "$(cat "$FM_HOME/state/.watch.lock/pid" 2>/dev/null)" 2>/dev/null
  sleep 1; i=$((i + 1))
done
wait "$LOOP" 2>/dev/null
note "stopped"
for t in held-merge stable-merge unrecorded blocked-pr rework-merge; do
  { echo "=== $t pane"; tmux capture-pane -p -t "primary:fm-$t" | grep -v '^$' | tail -6
    echo "=== $t status"; cat "$FM_HOME/state/$t.status"
    echo "=== $t re-surface marker"; cat "$FM_HOME/state/.paused-resurfaced-primary_fm-$t" 2>/dev/null || echo '(none)'; echo
    echo "=== $t inbox"; (cd "$FM_HOME/state" && find "$t.inbox" -type f 2>/dev/null) || true
  } >> "$EVP.final-state.txt"
done
cp "$FM_HOME/state/.watch-triage.log" "$EVP.watch-triage.log" 2>/dev/null || true
TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab kill-server 2>/dev/null
rm -rf "$LAB"
note "lab removed"
