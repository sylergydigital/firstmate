#!/usr/bin/env bash
# Live lab proof for the merge integration point in bin/fm-spawn.sh: upstream's
# opt-in project-group order key ("Project groups") now flows through the
# fork's refactored spawn_herdr_projection_create. With rules
#   Alpha task:grp-a / Beta task:grp-b
# grp-b is spawned first (projected child of the "firstmate" launcher
# workspace), then grp-a. Upstream contract (docs/herdr-backend.md "Placement
# inside the group"): grp-a's projection must be placed BEFORE grp-b's, not at
# the block end. Real fm-spawn.sh, real Herdr (protocol 22) on a named fm-lab-*
# session, real Treehouse (pool root inside the lab), real codex harness.
set -u
WT=${1:?worktree}
cd "$WT"
LAB_HELPER="$WT/bin/fm-herdr-lab.sh"
# LAB_SES lets the caller pick a short fm-lab-* name: the canonical socket path
# on this host is ~85 chars + session + "/herdr.sock", and AF_UNIX caps it at 107.
SES=${LAB_SES:-$("$LAB_HELPER" name groups)}
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

echo "## provision herdr lab session $SES ($(herdr status client --json | jq -r '"herdr \(.version), protocol \(.protocol)"'))"
"$LAB_HELPER" provision "$SES" || { echo "VERDICT: SETUP-FAIL provision"; exit 1; }
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
printf 'herdr\n' > "$LAB/config/backend"
printf 'codex\n' > "$LAB/config/crew-harness"
printf 'Alpha task:grp-a\nBeta  task:grp-b\n' > "$LAB/config/herdr-project-groups"
echo "config/herdr-project-groups:"; sed 's/^/  /' "$LAB/config/herdr-project-groups"
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
echo "order-key grp-a: $(FM_HOME="$LAB" bin/fm-herdr-groups.sh order-key grp-a "$PROJ")"
echo "order-key grp-b: $(FM_HOME="$LAB" bin/fm-herdr-groups.sh order-key grp-b "$PROJ")"

# Logging shim around the REAL mover (supported override FM_BACKEND_HERDR_WORKSPACE_MOVER):
# records the insert index fm-spawn asks for and the real mover's exit/output.
cat > "$LAB/mover-shim.sh" <<EOF
#!/usr/bin/env bash
out=\$("$WT/bin/backends/herdr-workspace-move.py" "\$@" 2>"$LAB/mover.err"); rc=\$?
{ echo "args: \$*"; echo "exit: \$rc"; echo "stdout: \$out" | cut -c1-300; echo "stderr: \$(cat "$LAB/mover.err")"; } >> "$LAB/mover.log"
printf '%s' "\$out"; exit \$rc
EOF
chmod +x "$LAB/mover-shim.sh"
PRIM_WS=$(lab workspace create --label firstmate --cwd "$WT" --no-focus 2>&1 | jq -r '.result.workspace.workspace_id // empty')
PRIM_PANE=$(lab pane list --workspace "$PRIM_WS" 2>/dev/null | jq -r '.result.panes[0].pane_id // empty')
spawn_from_launcher() { # <id>
  local id=$1
  cat > "$LAB/spawn-$id.sh" <<EOF
#!/usr/bin/env bash
cd "$WT"
env -u FM_GATE_REFUSE_BYPASS -u TMUX -u TMUX_PANE FM_HOME="$LAB" FM_SPAWN_NO_GUARD=1 FM_BACKEND_HERDR_WORKSPACE_MOVER="$LAB/mover-shim.sh" \\
  timeout 300 bin/fm-spawn.sh "$id" "$PROJ" --scout > "$LAB/spawn-$id.out" 2>&1
echo \$? > "$LAB/spawn-$id.rc"
EOF
  chmod +x "$LAB/spawn-$id.sh"
  lab pane run "$PRIM_PANE" "$LAB/spawn-$id.sh" >/dev/null
  for _ in $(seq 1 150); do [ -s "$LAB/spawn-$id.rc" ] && break; sleep 1; done
  grep -v '^fm-gate-refuse' "$LAB/spawn-$id.out"
  echo "spawn $id rc=$(cat "$LAB/spawn-$id.rc" 2>/dev/null)"
}

echo; echo "## spawn grp-b (group Beta) first"
spawn_from_launcher grp-b
WB=$(meta grp-b herdr_workspace_id); layout
echo "grp-b workspace $WB metadata: $(lab workspace get "$WB" 2>/dev/null | jq -c '.result.workspace | {label, metadata: (.metadata // .display_metadata // .tokens // null)}')"

echo; echo "## spawn grp-a (group Alpha) second"
spawn_from_launcher grp-a
WA=$(meta grp-a herdr_workspace_id); layout

order=$(lab workspace list | jq -r '[.result.workspaces[].workspace_id] | join(" ")')
ip=$(lab workspace list | jq -r --arg w "$PRIM_WS" '[.result.workspaces[].workspace_id] | index($w)')
ia=$(lab workspace list | jq -r --arg w "$WA" '[.result.workspaces[].workspace_id] | index($w)')
ib=$(lab workspace list | jq -r --arg w "$WB" '[.result.workspaces[].workspace_id] | index($w)')
echo "order: $order  (parent=$PRIM_WS@$ip, grp-a=$WA@$ia, grp-b=$WB@$ib)"
V=PASS
[ "$(cat "$LAB/spawn-grp-a.rc")" = 0 ] && [ "$(cat "$LAB/spawn-grp-b.rc")" = 0 ] || { V=FAIL; echo "x a spawn failed"; }
[ -n "$WA" ] && [ -n "$WB" ] && [ "$WA" != "$PRIM_WS" ] && [ "$WB" != "$PRIM_WS" ] && [ "$WA" != "$WB" ] || { V=FAIL; echo "x tasks were not each projected into their own workspace"; }
[ "$ip" != null ] && [ "$ia" != null ] && [ "$ib" != null ] && [ "$ip" -lt "$ia" ] && [ "$ia" -lt "$ib" ] \
  || { V=FAIL; echo "x grp-a (Alpha) was not placed before grp-b (Beta) inside the parent's child block"; }
echo "## mover calls made by fm-spawn:"; cat "$LAB/mover.log" 2>/dev/null || echo "(none)"
echo "VERDICT: group-order placement=$V"
