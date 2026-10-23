#!/usr/bin/env bash
# Live lab proof of the fork's Herdr missing-endpoint relaunch recovery on the
# merged tree. Real fm-spawn.sh / fm-control.sh, real Herdr on a named fm-lab-*
# session (bin/fm-herdr-lab.sh lifecycle), real Treehouse with its pool root
# inside the lab home, real codex harness.
#
# Projection-only rerun (see live-herdr-reclaim.sh for A/B); the launcher
# workspace carries the home label "firstmate", as a real primary workspace does.
#  A. flat: a scout lands as a tab in the home workspace (which a second tab
#     keeps alive); its pane is destroyed; `fm-control.sh <id> relaunch` must
#     recreate one tab in the SAME recorded session+workspace, rebind the record
#     and reuse the worktree untouched.
#  B. adversarial: the pane is destroyed again and a decoy fm-<id> tab is
#     planted in ANOTHER workspace; the reclaim must refuse before creating
#     anything and leave the record untouched.
#  C. projection: a second scout is spawned from INSIDE a lab Herdr pane, so
#     it gets its own one-task projection workspace; its pane is destroyed (the
#     projection vanishes with it); the reclaim must recreate a projection
#     beneath the recorded parent and rebind.
set -u
WT=${1:?worktree}
cd "$WT"
LAB_HELPER="$WT/bin/fm-herdr-lab.sh"
SES=$("$LAB_HELPER" name reclaim)
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
A=hr-flat-live
C=hr-proj-live
cleanup() {
  "$LAB_HELPER" teardown "$SES" && echo "lab session $SES torn down (tripwire verified)"
  chmod -R u+w "$LAB" /tmp/fm-hr-* 2>/dev/null
  rm -rf "$LAB" /tmp/fm-hr-*
}
trap cleanup EXIT
lab() { "$LAB_HELPER" run "$SES" "$@"; }
fmenv() {
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    -u TMUX -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u HERDR_SOCKET_PATH \
    FM_HOME="$LAB" HERDR_SESSION="$SES" FM_SPAWN_NO_GUARD=1 "$@"
}
meta() { sed -n "s/^$2=//p" "$LAB/state/$1.meta" | tail -1; }
rec() { grep -E '^(window|worktree|herdr_session|herdr_workspace_id|herdr_tab_id|herdr_pane_id)=' "$LAB/state/$1.meta" | tr '\n' ' '; echo; }
layout() {
  echo "-- workspaces: $(lab workspace list 2>&1 | jq -c '[.result.workspaces[]? | {workspace_id, label}]')"
  echo "-- tabs:       $(lab tab list 2>&1 | jq -c '[.result.tabs[]? | {tab_id, workspace_id, label}]')"
}
cwd_of() { fmenv bash -c '. bin/fm-backend.sh; fm_backend_source herdr; fm_backend_herdr_current_path "$1"' _ "$1" 2>/dev/null; }
pane_tail() { lab pane read "$1" 2>/dev/null | jq -r '.. | strings' 2>/dev/null | sed '/^\s*$/d' | tail -4; }
brief() {
  mkdir -p "$LAB/data/$1"
  printf '# Task\n## Captain'"'"'s intent\nLive lab check only. Do nothing; reply "ok" and stop.\n\n## Firstmate spec\nNo changes. Stop immediately.\n' > "$LAB/data/$1/brief.md"
}
check_reclaim() { # <id> <rc> <old-pane> <old-wt> <old-ses> -> sets V
  local id=$1 rc=$2 old_pane=$3 old_wt=$4 old_ses=$5 np cwd
  V=PASS
  np=$(meta "$id" herdr_pane_id)
  [ "$rc" = 0 ] || { V=FAIL; echo "x relaunch rc=$rc"; }
  [ "$(meta "$id" herdr_session)" = "$old_ses" ] || { V=FAIL; echo "x herdr_session moved"; }
  [ "$(meta "$id" worktree)" = "$old_wt" ] && [ -d "$old_wt" ] || { V=FAIL; echo "x worktree changed/removed"; }
  [ -n "$np" ] && [ "$np" != "$old_pane" ] || { V=FAIL; echo "x pane not rebound"; }
  lab pane get "$np" >/dev/null 2>&1 || { V=FAIL; echo "x rebound pane $np absent"; }
  cwd=$(cwd_of "$(meta "$id" window)")
  echo "rebound pane cwd: $cwd"
  [ "$(cd "$cwd" 2>/dev/null && pwd -P)" = "$(cd "$old_wt" && pwd -P)" ] || { V=FAIL; echo "x rebound pane not in recorded worktree"; }
  [ "$(find "$LAB/thr/.treehouse" -mindepth 2 -maxdepth 2 -name repo | wc -l)" -le 2 ] || { V=FAIL; echo "x a second worktree was created"; }
}

echo "## provision herdr lab session $SES"
"$LAB_HELPER" provision "$SES" || { echo "VERDICT: SETUP-FAIL provision"; exit 1; }
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
printf 'herdr\n' > "$LAB/config/backend"
printf 'codex\n' > "$LAB/config/crew-harness"
R="$LAB/repos"; mkdir -p "$R" "$LAB/thr"
git init -q -b main "$R/seed"
printf 'base\n' > "$R/seed/README.md"
printf 'max_trees = 4\nroot = "%s"\n' "$LAB/thr" > "$R/seed/treehouse.toml"
git -C "$R/seed" add . && git -C "$R/seed" -c user.name=lab -c user.email=lab@example.invalid commit -qm init
git clone -q --bare "$R/seed" "$R/origin.git"
git clone -q "file://$R/origin.git" "$R/repo"
PROJ="$R/repo"
brief "$A"; brief "$C"

echo
echo "################ C. projection reclaim (spawned from inside a lab Herdr pane)"
PRIM_WS=$(lab workspace create --label firstmate --cwd "$WT" --no-focus 2>&1 | jq -r '.result.workspace.workspace_id // empty')
PRIM_PANE=$(lab pane list --workspace "$PRIM_WS" 2>/dev/null | jq -r '.result.panes[0].pane_id // empty')
[ -n "$PRIM_PANE" ] || PRIM_PANE=$(lab pane list 2>/dev/null | jq -r --arg w "$PRIM_WS" '.result.panes[] | select(.workspace_id == $w) | .pane_id' | head -1)
cat > "$LAB/spawn-c.sh" <<EOF
#!/usr/bin/env bash
cd "$WT"
env -u FM_GATE_REFUSE_BYPASS -u TMUX -u TMUX_PANE FM_HOME="$LAB" FM_SPAWN_NO_GUARD=1 \\
  timeout 300 bin/fm-spawn.sh "$C" "$PROJ" --scout > "$LAB/spawn-c.out" 2>&1
echo \$? > "$LAB/spawn-c.rc"
EOF
chmod +x "$LAB/spawn-c.sh"
lab pane run "$PRIM_PANE" "$LAB/spawn-c.sh" >/dev/null
for _ in $(seq 1 150); do [ -s "$LAB/spawn-c.rc" ] && break; sleep 1; done
grep -v '^fm-gate-refuse' "$LAB/spawn-c.out" | tail -3; echo "spawn C rc=$(cat "$LAB/spawn-c.rc" 2>/dev/null)"
C_WS=$(meta $C herdr_workspace_id); C_PANE=$(meta $C herdr_pane_id); C_SES=$(meta $C herdr_session); C_WT=$(meta $C worktree)
echo "record: $(rec $C)"; layout
J="$LAB/state/$C.herdr-presentation"
ls "$LAB/state" | grep -F "$C" | tr '\n' ' '; echo
echo "journal after spawn:"; sed -n 's/^\(version\|session\|workspace_id\|tab_id\|pane_id\|parent_workspace_id\|parent_label\|workspace_label\)=/  &/p' "$J"
VC=PASS
if [ -z "$C_PANE" ]; then
  VC=SETUP-FAIL
elif [ "$C_WS" = "$PRIM_WS" ]; then
  echo "spawn C did not get its own projection workspace (landed in $C_WS); projection path not exercised"
  VC=NOT-PROJECTED
else
  sleep 5; echo "-- codex in projected pane:"; pane_tail "$C_PANE"
  lab pane close "$C_PANE" >/dev/null 2>&1; sleep 1
  echo "after destroying $C_PANE:"; layout
  lab workspace get "$C_WS" >/dev/null 2>&1 && echo "projection workspace $C_WS still present" || echo "projection workspace $C_WS vanished with its pane"
  out=$(fmenv timeout 300 bin/fm-control.sh "$C" relaunch --note "lab: projection destroyed, reclaim" 2>&1); rc3=$?
  printf '%s\n' "$out" | grep -v '^fm-gate-refuse' | tail -4
  echo "relaunch rc=$rc3"
  echo "record: $(rec $C)"; layout
  check_reclaim "$C" "$rc3" "$C_PANE" "$C_WT" "$C_SES"
  NWS=$(meta $C herdr_workspace_id)
  [ "$NWS" != "$C_WS" ] && lab workspace get "$NWS" >/dev/null 2>&1 || { V=FAIL; echo "x no recreated projection workspace"; }
  [ "$NWS" != "$PRIM_WS" ] || { V=FAIL; echo "x reclaim flattened into a shared workspace"; }
  sleep 5; echo "-- codex in rebound pane:"; pane_tail "$(meta $C herdr_pane_id)"
  echo "journal after reclaim:"; sed -n 's/^\(version\|session\|workspace_id\|tab_id\|pane_id\|parent_workspace_id\|parent_label\|workspace_label\)=/  &/p' "$J"
  [ "$(sed -n 's/^version=//p' "$J")" = 2 ] && [ "$(sed -n 's/^workspace_id=//p' "$J")" = "$NWS" ] && [ "$(sed -n 's/^parent_workspace_id=//p' "$J")" = "$PRIM_WS" ] || { V=FAIL; echo "x journal not rebound to the recreated projection under the recorded parent"; }
  VC=$V
fi
echo "SCENARIO C projection-reclaim: $VC"
echo
echo "VERDICT: C=$VC"
