#!/usr/bin/env bash
# Control for live-herdr-groups-order.sh: is the failed workspace move specific
# to the merged group-key path, or does this host's Herdr reject the move for
# any ordering? Runs against <tree> (the merged worktree, or an extracted
# upstream tree). Groups OFF: grp-b is projected under "firstmate", then a
# foreign workspace is created, then grp-a is projected; block-end placement
# needs one move (grp-a back next to grp-b). Also drives the mover directly
# with stderr visible.
set -u
TREE=${1:?tree}
GRPMODE=${2:-off}
cd "$TREE"
LAB_HELPER="$TREE/bin/fm-herdr-lab.sh"
SES=$("$LAB_HELPER" name movectl)
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
cleanup() {
  "$LAB_HELPER" teardown "$SES" && echo "lab session $SES torn down (tripwire verified)"
  chmod -R u+w "$LAB" /tmp/fm-grp-* 2>/dev/null
  rm -rf "$LAB" /tmp/fm-grp-*
}
trap cleanup EXIT
lab() { "$LAB_HELPER" run "$SES" "$@"; }
meta() { sed -n "s/^$2=//p" "$LAB/state/$1.meta" | tail -1; }
layout() { echo "-- workspaces (in order): $(lab workspace list 2>&1 | jq -c '[.result.workspaces[]? | {workspace_id, label}]')"; }

echo "## tree $TREE ($(git -C "$TREE" log -1 --format=%h 2>/dev/null || cat "$TREE/.tree-rev" 2>/dev/null)), groups=$GRPMODE, lab $SES"
"$LAB_HELPER" provision "$SES" || { echo "VERDICT: SETUP-FAIL provision"; exit 1; }
"$TREE/bin/fm-lab-home.sh" create "$LAB" >/dev/null
printf 'herdr\n' > "$LAB/config/backend"
printf 'codex\n' > "$LAB/config/crew-harness"
[ "$GRPMODE" = off ] || printf 'Alpha task:grp-a\nBeta  task:grp-b\n' > "$LAB/config/herdr-project-groups"
R="$LAB/repos"; mkdir -p "$R" "$LAB/thr"
git init -q -b main "$R/seed"
printf 'base\n' > "$R/seed/README.md"
printf 'max_trees = 4\nroot = "%s"\n' "$LAB/thr" > "$R/seed/treehouse.toml"
git -C "$R/seed" add . && git -C "$R/seed" -c user.name=lab -c user.email=lab@example.invalid commit -qm init
git clone -q --bare "$R/seed" "$R/origin.git"
git clone -q "file://$R/origin.git" "$R/repo"
PROJ="$R/repo"
for id in grp-a grp-b; do
  mkdir -p "$LAB/data/$id"
  printf '# Task\n## Captain'"'"'s intent\nLive lab check only. Do nothing; reply "ok" and stop.\n\n## Firstmate spec\nNo changes. Stop immediately.\n' > "$LAB/data/$id/brief.md"
done
PRIM_WS=$(lab workspace create --label firstmate --cwd "$TREE" --no-focus 2>&1 | jq -r '.result.workspace.workspace_id // empty')
PRIM_PANE=$(lab pane list --workspace "$PRIM_WS" 2>/dev/null | jq -r '.result.panes[0].pane_id // empty')
spawn_from_launcher() { # <id>
  local id=$1
  cat > "$LAB/spawn-$id.sh" <<EOF
#!/usr/bin/env bash
cd "$TREE"
env -u FM_GATE_REFUSE_BYPASS -u TMUX -u TMUX_PANE FM_HOME="$LAB" FM_SPAWN_NO_GUARD=1 \\
  timeout 300 bin/fm-spawn.sh "$id" "$PROJ" --scout > "$LAB/spawn-$id.out" 2>&1
echo \$? > "$LAB/spawn-$id.rc"
EOF
  chmod +x "$LAB/spawn-$id.sh"
  lab pane run "$PRIM_PANE" "$LAB/spawn-$id.sh" >/dev/null
  for _ in $(seq 1 150); do [ -s "$LAB/spawn-$id.rc" ] && break; sleep 1; done
  grep -v '^fm-gate-refuse' "$LAB/spawn-$id.out"
  echo "spawn $id rc=$(cat "$LAB/spawn-$id.rc" 2>/dev/null)"
}
spawn_from_launcher grp-b
lab workspace create --label zz-foreign --cwd "$LAB" --no-focus >/dev/null
layout
spawn_from_launcher grp-a
layout
WA=$(meta grp-a herdr_workspace_id)
echo "## direct mover probe (stderr visible): move $WA to index 1"
SOCK=$( { lab session list --json 2>/dev/null || herdr session list --json; } | jq -r --arg s "$SES" '.sessions[] | select(.name == $s) | .socket_path')
echo "socket: $SOCK"
echo "## mover probe from INSIDE the launcher pane (the product's context): move $WA to index 1"
cat > "$LAB/probe.sh" <<EOF
#!/usr/bin/env bash
{ echo "python3=\$(command -v python3) \$(python3 --version 2>&1)"; env | grep -E '^HERDR' | sed 's/=.*/=<set>/' | tr '\\n' ' '; echo;
  "$TREE/bin/backends/herdr-workspace-move.py" "$SOCK" "$WA" 1; echo "mover exit=\$?"; } > "$LAB/probe.out" 2>&1
EOF
chmod +x "$LAB/probe.sh"; lab pane run "$PRIM_PANE" "$LAB/probe.sh" >/dev/null
for _ in $(seq 1 30); do grep -q 'mover exit' "$LAB/probe.out" 2>/dev/null && break; sleep 1; done
cat "$LAB/probe.out"
layout
