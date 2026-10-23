#!/usr/bin/env bash
# Mint a marked lab home with a private fm-lab tmux server; print its path.
set -eu
ROOT=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
mkdir -p "$LAB/tmux"
cat > "$LAB/config/watch.env" <<'ENV'
export FM_POLL=2
export FM_PAUSE_RESURFACE_SECS=60
export FM_SIGNAL_GRACE=1
export FM_HEARTBEAT=999999
export FM_CHECK_INTERVAL=999999
export FM_SECONDMATE_LIVENESS_SECS=99999999
ENV
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
  -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -s primary -x 200 -y 50 -c "$ROOT" -e FM_HOME="$LAB" bash
printf '%s\n' "$LAB"
