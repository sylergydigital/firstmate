#!/usr/bin/env bash
# Live lab proof: a real fm-spawn.sh (merged tree) in a marked lab home, on a
# private tmux socket, against the real Treehouse CLI whose pool is shared by
# two clones of one origin and whose lowest free slots belong to the OTHER
# clone. Expected: the spawn lands in its own clone's worktree and every
# foreign slot it fenced is returned (available, no lease holder).
set -u
WT=${1:?worktree}
EVID=${2:?evidence dir}
cd "$WT"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
bin/fm-lab-home.sh create "$LAB" >/dev/null
TMUXD=$(bin/fm-lab-home.sh tmux-dir "$LAB")
cleanup() {
  TMUX_TMPDIR="$TMUXD" tmux -L fm-lab kill-server 2>/dev/null || true
  bin/fm-lab-home.sh teardown "$LAB" >/dev/null 2>&1 || true
  chmod -R u+w "$LAB" /tmp/fm-th-fence-live* 2>/dev/null
  rm -rf "$LAB" /tmp/fm-th-fence-live*
}
trap cleanup EXIT

R="$LAB/repos"
mkdir -p "$R" "$LAB/thr"
git init -q -b main "$R/seed"
printf 'base\n' > "$R/seed/README.md"
printf 'max_trees = 8\nroot = "%s"\n' "$LAB/thr" > "$R/seed/treehouse.toml"
git -C "$R/seed" add README.md treehouse.toml
git -C "$R/seed" -c user.name=lab -c user.email=lab@example.invalid commit -qm init
git clone -q --bare "$R/seed" "$R/origin.git"
git clone -q "file://$R/origin.git" "$R/main-home/repo"
git clone -q "file://$R/origin.git" "$R/secondmate-home/repo"
PROJ="$R/main-home/repo"
OTHER="$R/secondmate-home/repo"

echo "## pool seeded by the OTHER clone (2 slots, then returned)"
for i in 1 2; do (cd "$OTHER" && treehouse get --lease --lease-holder seed-other 2>/dev/null); done | tee "$LAB/seeded"
while IFS= read -r p; do (cd "$OTHER" && treehouse return "$p" >/dev/null 2>&1); done < "$LAB/seeded"
(cd "$PROJ" && treehouse status --json 2>/dev/null) | jq -c '.[] | {path, status, lease_holder}'
for p in $(cat "$LAB/seeded"); do
  printf '%s common-dir=%s\n' "$p" "$(git -C "$p" rev-parse --path-format=absolute --git-common-dir)"
done

ID=th-fence-live
mkdir -p "$LAB/data/$ID"
cat > "$LAB/data/$ID/brief.md" <<'EOF'
# Task
## Captain's intent
Live lab check only. Do nothing; reply "ok" and stop.

## Firstmate spec
No changes. Stop immediately.
EOF
printf 'codex\n' > "$LAB/config/crew-harness"

env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
  -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  TMUX_TMPDIR="$TMUXD" tmux -L fm-lab new-session -d -s primary -c "$WT" -e FM_HOME="$LAB" bash --norc
sock=$(TMUX_TMPDIR="$TMUXD" tmux -L fm-lab display-message -p -t primary '#{socket_path}')
pid=$(TMUX_TMPDIR="$TMUXD" tmux -L fm-lab display-message -p -t primary '#{pid}')
pane=$(TMUX_TMPDIR="$TMUXD" tmux -L fm-lab display-message -p -t primary "#{pane_id}")

echo "## real spawn: bin/fm-spawn.sh $ID $PROJ --scout (FM_HOME=lab, tmux lab socket, harness codex)"
out=$(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
  -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  FM_HOME="$LAB" TMUX_TMPDIR="$TMUXD" TMUX="$sock,$pid,0" TMUX_PANE="$pane" FM_SPAWN_NO_GUARD=1 \
  timeout 300 bin/fm-spawn.sh "$ID" "$PROJ" --scout 2>&1)
rc=$?
printf '%s\n' "$out" | tail -15
echo "spawn rc=$rc"

echo "## state/$ID.meta"
grep -E '^(worktree|backend|harness|kind|window|tmux_target)=' "$LAB/state/$ID.meta" 2>/dev/null || echo "(no meta)"
wt=$(sed -n 's/^worktree=//p' "$LAB/state/$ID.meta" 2>/dev/null)
echo "## landed worktree belongs to:"
[ -n "$wt" ] && printf '%s common-dir=%s\n' "$wt" "$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir)"
echo "## project common-dir: $(git -C "$PROJ" rev-parse --path-format=absolute --git-common-dir)"
echo "## pool after spawn"
(cd "$PROJ" && treehouse status --json 2>/dev/null) | jq -c '.[] | {path, status, lease_holder}'
echo "## leases still held by the fence holder"
(cd "$PROJ" && treehouse status --json 2>/dev/null) | jq -r '.[] | select(.lease_holder == "firstmate-spawn-fence:'"$ID"'") | .path' | sed 's/^/LEFT FENCED: /'
echo "## task pane"
TMUX_TMPDIR="$TMUXD" tmux -L fm-lab list-windows -a -F '#{session_name}:#{window_name} #{pane_current_path}'
TMUX_TMPDIR="$TMUXD" tmux -L fm-lab capture-pane -p -t "primary:fm-$ID" 2>/dev/null | sed '/^$/d' | tail -15

# Verdict
verdict=PASS
[ "$rc" = 0 ] || verdict=FAIL
[ -n "$wt" ] || verdict=FAIL
[ -n "$wt" ] && [ "$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir)" = "$(git -C "$PROJ" rev-parse --path-format=absolute --git-common-dir)" ] || verdict=FAIL
grep -qxF "$wt" "$LAB/seeded" && verdict=FAIL
[ -z "$( (cd "$PROJ" && treehouse status --json 2>/dev/null) | jq -r '.[] | select(.lease_holder == "firstmate-spawn-fence:'"$ID"'") | .path')" ] || verdict=FAIL
for p in $(cat "$LAB/seeded"); do
  st=$( (cd "$PROJ" && treehouse status --json 2>/dev/null) | jq -r --arg p "$p" '.[] | select(.path == $p) | .status')
  [ "$st" = available ] || { echo "foreign slot $p status=$st"; verdict=FAIL; }
done
echo "VERDICT: $verdict"

# Stop the worker before teardown: kill only the lab tmux server.
TMUX_TMPDIR="$TMUXD" tmux -L fm-lab kill-server 2>/dev/null || true
