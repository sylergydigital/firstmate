#!/usr/bin/env bash
# add-task.sh <task> <tick-secs> <status-line>: open a crew window running the
# scripted worker and write the task's meta and status the way a spawn and the
# worker's own append leave them.
set -eu
task=$1; tick=$2; line=$3; SCR=$(dirname "$0")
tmux new-window -d -t primary: -n "fm-$task" -e FM_HOME="$FM_HOME" "bash $SCR/worker.sh $task $tick"
mkdir -p "$FM_HOME/projects/$task"
printf 'window=primary:fm-%s\nkind=ship\nharness=claude\nbackend=tmux\nmode=no-mistakes\nworktree=%s\n' \
  "$task" "$FM_HOME/projects/$task" > "$FM_HOME/state/$task.meta"
printf '%s\n' "$line" > "$FM_HOME/state/$task.status"
