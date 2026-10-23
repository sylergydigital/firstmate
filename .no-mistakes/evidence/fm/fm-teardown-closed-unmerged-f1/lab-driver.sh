#!/usr/bin/env bash
# Live-validation driver for the closed-unmerged teardown change.
# Drives the real bin/fm-teardown.sh, tasks-axi, git, treehouse, tmux, and gh
# (real GitHub reads with the machine's normal login) inside a disposable lab
# home minted by bin/fm-lab-home.sh. Nothing here stubs the forge.
#
#   lab-driver.sh prepare <lab> <id> <pr-url>      lease a real treehouse worktree in a
#                                                  lab tmux window, push a task branch to
#                                                  the lab origin, write the task record,
#                                                  and start the backlog row
#   lab-driver.sh teardown <lab> <id> [env=val...] [-- teardown-args]
#                                                  run bin/fm-teardown.sh inside the lab
#                                                  tmux server (so $TMUX names the lab
#                                                  socket) and wait for it to finish
#   lab-driver.sh show <lab> <id>                  print the backlog row and record state
set -u
GATE_WT=${FM_LAB_CODE_ROOT:-/home/admin_mmunem_altostrat_com/.no-mistakes/worktrees/86e7a0a30077/01M5M0WRJ94KDYCBZW75VN57QN}
cmd=$1 LAB=$2 ID=$3
shift 3
export TMUX_TMPDIR="$LAB/tmux"
unset TMUX
T() { tmux -L fm-lab "$@"; }
mkdir -p "$LAB/runs" "$LAB/pathbin"
ln -sf "$(type -P treehouse)" "$LAB/pathbin/treehouse"
# The lab PATH keeps every real tool except ~/.local/bin, whose no-mistakes
# binary must never be reached from a gate lab; treehouse is linked back in.
LAB_PATH="$LAB/pathbin:$(printf '%s' "$PATH" | tr ':' '\n' | grep -vx "$HOME/.local/bin" | paste -sd:)"

case "$cmd" in
  prepare)
    PR_URL=$1
    T new-window -d -t firstmate -n "fm-$ID" -c "$LAB/projects/sample"
    sleep 0.5
    T send-keys -t "firstmate:fm-$ID" "cd $LAB/projects/sample && treehouse get" Enter
    for _ in $(seq 1 40); do
      T capture-pane -p -t "firstmate:fm-$ID" -S -50 | tr -d '\n' | grep -q "Entered worktree at" && break
      sleep 0.5
    done
    T send-keys -t "firstmate:fm-$ID" "pwd -P > $LAB/runs/$ID.wt" Enter
    for _ in $(seq 1 20); do [ -s "$LAB/runs/$ID.wt" ] && break; sleep 0.25; done
    WT=$(cat "$LAB/runs/$ID.wt")
    git -C "$WT" switch -q -c "fm/$ID"
    printf 'work for %s\n' "$ID" > "$WT/$ID.txt"
    git -C "$WT" add "$ID.txt"
    git -C "$WT" -c user.email=lab@lab -c user.name=lab commit -q -m "work for $ID"
    git -C "$WT" push -q origin "fm/$ID" 2>/dev/null
    git -C "$LAB/projects/sample" fetch -q origin
    {
      echo "window=firstmate:fm-$ID"
      echo "endpoint_task_id=$ID"
      echo "worktree=$WT"
      echo "project=$LAB/projects/sample"
      echo "harness=claude"
      echo "kind=ship"
      echo "mode=no-mistakes"
      echo "yolo=off"
      echo "branch=fm/$ID"
      echo "tasktmp="
      echo "model=default"
      echo "effort=default"
      echo "spawn_gen=lab-$ID"
      echo "pr=$PR_URL"
    } > "$LAB/state/$ID.meta"
    [ -f "$LAB/data/backlog.md" ] || printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$LAB/data/backlog.md"
    tasks-axi add "$ID" "Lab ship task $ID" --kind ship --repo sample --start --file "$LAB/data/backlog.md" >/dev/null
    echo "prepared $ID worktree=$WT pr=$PR_URL"
    ;;
  teardown)
    envs=()
    while [ "$#" -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
    [ "${1:-}" = -- ] && shift
    rm -f "$LAB/runs/$ID.rc" "$LAB/runs/$ID.out" "$LAB/runs/$ID.err" "$LAB/runs/$ID.secs"
    runner="$LAB/runs/$ID.run.sh"
    {
      echo '#!/usr/bin/env bash'
      echo "cd $GATE_WT"
      echo 'start=$(date +%s)'
      printf 'env -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE PATH=%q FM_HOME=%q' "$LAB_PATH" "$LAB"
      for e in "${envs[@]+"${envs[@]}"}"; do printf ' %q' "$e"; done
      printf ' bin/fm-teardown.sh %q' "$ID"
      for a in "$@"; do printf ' %q' "$a"; done
      printf ' > %q 2> %q\n' "$LAB/runs/$ID.out" "$LAB/runs/$ID.err"
      echo "rc=\$?"
      echo "echo \$((\$(date +%s) - start)) > $LAB/runs/$ID.secs"
      echo "echo \$rc > $LAB/runs/$ID.rc"
    } > "$runner"
    chmod +x "$runner"
    T new-window -d -t firstmate -n "run-$ID" "$runner"
    for _ in $(seq 1 600); do [ -s "$LAB/runs/$ID.rc" ] && break; sleep 0.5; done
    echo "--- teardown $ID exit=$(cat "$LAB/runs/$ID.rc" 2>/dev/null) elapsed=$(cat "$LAB/runs/$ID.secs" 2>/dev/null)s"
    echo "--- stdout"; cat "$LAB/runs/$ID.out"
    echo "--- stderr"; cat "$LAB/runs/$ID.err"
    ;;
  show)
    echo "--- backlog row line (data/backlog.md)"
    grep -n -A2 -- "\] $ID " "$LAB/data/backlog.md" || echo "(no row)"
    echo "--- tasks-axi show $ID --full"
    tasks-axi show "$ID" --full --file "$LAB/data/backlog.md"
    echo "--- leftover state"
    ls "$LAB/state" | grep -F "$ID" || echo "(no $ID task record or pending-close record left in state/)"
    echo "--- lab tmux window fm-$ID"
    T list-windows -t firstmate -F '#W' | grep -x "fm-$ID" || echo "(window fm-$ID closed)"
    ;;
esac
