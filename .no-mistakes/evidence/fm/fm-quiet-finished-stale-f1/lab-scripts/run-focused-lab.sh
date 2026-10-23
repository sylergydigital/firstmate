#!/usr/bin/env bash
# run-focused-lab.sh <root> <evidence-prefix> <rework|late-ack|away>
# One single-task lab per adversarial case, so no other alarming pane competes
# for the watcher's one-wake cycle.
set -u
ROOT=$1; EVP=$2; CASE=$3; SCR=$(cd "$(dirname "$0")" && pwd)
GH=https://github.com/kunchenguid/firstmate/pull
LAB=$("$SCR/lab-up.sh" "$ROOT") || exit 1
. "$SCR/lab-env.sh"
ST="$FM_HOME/state"
LOG="$EVP.cycle.log"; : > "$LOG"
note() { printf '%s\tLAB\t%s\n' "$(date +%T)" "$*" >> "$LOG"; }
note "case=$CASE lab=$LAB root=$ROOT FM_POLL=2 FM_PAUSE_RESURFACE_SECS=60"
start_loop() { "$SCR/primary-loop.sh" "$ROOT" "$LOG" & LOOP=$!; }
record_pr() { note "fm-pr-check.sh $1 $2 -> $("$ROOT/bin/fm-pr-check.sh" "$1" "$2" 2>/dev/null | tail -1)"; }
case "$CASE" in
  rework)
    T=rework-merge
    "$SCR/add-task.sh" $T 8 "done: PR $GH/7674 checks green"; record_pr $T "$GH/7674"
    start_loop; sleep 40
    note "STEER $T: $("$ROOT/bin/fm-send.sh" $T 'address the review comment on the flag name' 2>&1 | grep -v WARNING | tail -1)"
    i=0; while [ ! -e "$ST/$T.inbox/handled/001.msg" ] && [ "$i" -lt 20 ]; do sleep 0.5; i=$((i + 1)); done
    sleep 2
    printf 'done: addressed the review\n' >> "$ST/$T.status"
    note "worker acted on the steer, then appended its pre-validation handoff: done: addressed the review"
    sleep 45 ;;
  late-ack)
    T=late-ack
    "$SCR/add-task.sh" $T 8 'working: final turn, pushing the branch'
    touch "$ST/$T.lab-defer"
    note "STEER $T while it is still in its last turn: $("$ROOT/bin/fm-send.sh" $T 'rename the flag before the merge' 2>&1 | grep -v WARNING | tail -1)"
    sleep 2
    printf 'done: PR %s/7677 checks green\n' "$GH" >> "$ST/$T.status"
    note "worker appended done: PR $GH/7677 checks green (after the steer was written, before reading it)"
    record_pr $T "$GH/7677"
    start_loop; sleep 40
    rm -f "$ST/$T.lab-defer"
    i=0; while [ ! -e "$ST/$T.inbox/handled/001.msg" ] && [ "$i" -lt 20 ]; do sleep 0.5; i=$((i + 1)); done
    note "worker read the steer only now and moved it to handled/ (record mtime still predates the done: line)"
    sleep 40 ;;
  away)
    "$SCR/add-task.sh" away-churn 8 "done: PR $GH/7677 checks green"; record_pr away-churn "$GH/7677"
    "$SCR/add-task.sh" away-stable 0 "done: PR $GH/7676 checks green"; record_pr away-stable "$GH/7676"
    note "away: $("$ROOT/bin/fm-afk-contract.sh" enter --words 'lab: away overnight, merge decisions wait for my return' 2>&1 | head -1)"
    start_loop; sleep 100
    note "return: archived $("$ROOT/bin/fm-afk-contract.sh" archive 2>&1 | tail -1)"
    sleep 40 ;;
esac
touch "$ST/.lab-stop"
i=0
while kill -0 "$LOOP" 2>/dev/null && [ "$i" -lt 30 ]; do
  kill "$(cat "$ST/.watch.lock/pid" 2>/dev/null)" 2>/dev/null; sleep 1; i=$((i + 1))
done
wait "$LOOP" 2>/dev/null
note "stopped"
for meta in "$ST"/*.meta; do
  t=${meta##*/}; t=${t%.meta}
  { echo "=== $t pane (tail)"; tmux capture-pane -p -t "primary:fm-$t" | grep -v '^$' | tail -4
    echo "=== $t status"; cat "$ST/$t.status"
    echo "=== $t inbox"; (cd "$ST" && find "$t.inbox" -type f 2>/dev/null; ls -l --time-style=+%T "$t.status" "$t.inbox/handled" -d 2>/dev/null; find "$t.inbox" -name '*.msg' -exec ls -l --time-style=+%T {} + 2>/dev/null) || true
    echo
  } >> "$EVP.final-state.txt"
done
cp "$ST/.watch-triage.log" "$EVP.watch-triage.log" 2>/dev/null || true
TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab kill-server 2>/dev/null
rm -rf "$LAB"
note "lab removed"
