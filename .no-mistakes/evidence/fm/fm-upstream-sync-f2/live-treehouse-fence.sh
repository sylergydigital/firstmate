#!/usr/bin/env bash
# Live driver: fork commit cb61ba34 + 20369e6 (Treehouse foreign-slot fence).
# Two local clones of ONE origin share a single real Treehouse pool. Clone A
# leaves a free slot in it; a real bin/fm-spawn.sh from clone B's home (real
# Herdr lab session, real Treehouse 2.x) must still land in a clone-B worktree
# and hand the fenced clone-A slot back afterwards.
set -u

ROOT=${ROOT:?set ROOT to the firstmate checkout}
cd "$ROOT" || exit 1
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
export FM_GATE_REFUSE_BYPASS=1

TMP=$(mktemp -d /tmp/fm-fence-live.XXXXXX); TMP=$(cd "$TMP" && pwd -P)
S=$(bin/fm-herdr-lab.sh name fence)
export HERDR_SESSION=$S
HARN="sh -c 'while :; do sleep 60; done'"
HA="$TMP/homeA" HB="$TMP/homeB"
CA="$HA/projects/widget" CB="$HB/projects/widget"
PASSES=0 FAILS=0; RESULTS=()
LAB_UP=0
cleanup() {
  [ "$LAB_UP" = 1 ] && bin/fm-herdr-lab.sh teardown "$S" >/dev/null 2>&1 && echo "# lab session $S torn down"
  for h in "$HA" "$HB"; do
    hh=$(printf '%s' "$h" | sha256sum | awk '{print $1}')
    for id in fence1 fence2; do rm -rf "/tmp/fm-$id+$hh" "/tmp/fm-$id"; done
  done
  chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"
}
trap cleanup EXIT
say() { printf '%s\n' "$*"; }
hdr() { printf '\n===== %s =====\n' "$*"; }
ok() { PASSES=$((PASSES + 1)); RESULTS+=("PASS $1"); say "PASS: $1"; }
bad() { FAILS=$((FAILS + 1)); RESULTS+=("FAIL $1"); say "FAIL: $1"; }
checkc() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
common_dir() { (cd "$1" && cd "$(git rev-parse --git-common-dir)" && pwd -P); }
pool_status() { (cd "$1" && treehouse status --json); }
show_pool() { say "-- pool (treehouse status --json, seen from $(basename "$(dirname "$(dirname "$1")")")):"; pool_status "$1" | jq -r '.[] | "   slot \(.name)  \(.status)  holder=\(.lease_holder // "")  path=\(.path)"' | while IFS= read -r l; do p=${l##*path=}; say "$l  owner-clone=$(common_dir "$p" 2>/dev/null | sed "s|$TMP/||")"; done; }
meta() { sed -n "s/^$3=//p" "$1/state/$2.meta" | tail -1; }
spawn() { # <home> <id> <project>
  env FM_SPAWN_NO_GUARD=1 FM_HOME="$1" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-spawn.sh" "$2" "$3" "$HARN" --mode no-mistakes --yolo off --backend herdr 2>&1
}

hdr "setup"
say "firstmate checkout: $ROOT ($(git -C "$ROOT" rev-parse --short HEAD)); herdr $(herdr --version | awk '{print $2}'); treehouse $(treehouse --version)"
mkdir -p "$TMP/seed" "$TMP/origin"
git -C "$TMP/seed" init -q
printf '# widget\n' > "$TMP/seed/README.md"
printf 'max_trees = 16\nroot = "%s"\n' "$TMP/th" > "$TMP/seed/treehouse.toml"
git -C "$TMP/seed" add README.md treehouse.toml
git -C "$TMP/seed" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
git clone --quiet --bare "$TMP/seed" "$TMP/origin/widget.git"
for h in "$HA" "$HB"; do
  mkdir -p "$h/state" "$h/config" "$h/projects" "$h/data/fence1" "$h/data/fence2"
  touch "$h/state/.last-watcher-beat"
  printf 'off\n' > "$h/config/herdr-presentation-spaces"
  for id in fence1 fence2; do
    printf '# Task\n## Captain'"'"'s intent\nFence fixture %s.\n\n## Firstmate spec\nLand in this clone.\n' "$id" > "$h/data/$id/brief.md"
  done
  git clone --quiet "file://$TMP/origin/widget.git" "$h/projects/widget"
done
say "clone A: $CA"; say "clone B: $CB  (same dir name, same origin URL -> one shared pool)"
bin/fm-herdr-lab.sh provision "$S" || { echo "lab provision failed"; exit 1; }
LAB_UP=1

hdr "seed: clone A leaves a FREE slot in the shared pool"
PA=$(cd "$CA" && treehouse get --lease --lease-holder seed-a 2>/dev/null)
(cd "$CA" && treehouse return --if-lease-holder seed-a "$PA" >/dev/null 2>&1)
say "clone A slot: $PA  (git common dir $(common_dir "$PA"))"
show_pool "$CB"
case "$PA" in "$TMP/th/.treehouse/"*) ;; *) echo "pool escaped scratch: $PA"; exit 1 ;; esac

hdr "hazard (no fence): plain treehouse get from clone B hands out clone A's worktree"
PX=$(cd "$CB" && treehouse get --lease --lease-holder probe-b 2>/dev/null)
say "$ (cd clone-B && treehouse get --lease) -> $PX  (git common dir $(common_dir "$PX"))"
checkc "hazard reproduced: clone B's raw get returns a clone-A worktree" '[ "$(common_dir "$PX")" = "$(common_dir "$CA")" ]'
(cd "$CB" && treehouse return --if-lease-holder probe-b "$PX" >/dev/null 2>&1)

hdr "spawn fence1 from clone B's home (real fm-spawn, Herdr backend)"
OUT=$(spawn "$HB" fence1 "$CB"); RC=$?
say "$ FM_HOME=homeB fm-spawn.sh fence1 <clone B> \"$HARN\" --backend herdr -> rc=$RC"; say "$OUT" | tail -3
WT=$(meta "$HB" fence1 worktree)
say "fence1 worktree: $WT (git common dir $(common_dir "$WT" 2>/dev/null))"
show_pool "$CB"
checkc "spawn succeeds" '[ "$RC" -eq 0 ]'
checkc "fence1 landed in a clone-B worktree" '[ "$(common_dir "$WT")" = "$(common_dir "$CB")" ]'
checkc "fence1 did not take clone A's slot" '[ "$WT" != "$PA" ]'
checkc "fenced clone-A slot handed back (available again)" '[ "$(pool_status "$CB" | jq -r --arg p "$PA" ".[] | select(.path == \$p) | .status")" = available ]'
checkc "no lease left under the spawn fence holder" '[ -z "$(pool_status "$CB" | jq -r ".[] | select(.lease_holder == \"firstmate-spawn-fence:fence1\") | .path")" ]'

hdr "spawn fence2 from clone A's home: its own slot is free, so it takes it"
OUT=$(spawn "$HA" fence2 "$CA"); RC=$?
say "$ FM_HOME=homeA fm-spawn.sh fence2 <clone A> ... -> rc=$RC"; say "$OUT" | tail -2
WT2=$(meta "$HA" fence2 worktree)
show_pool "$CA"
checkc "fence2 spawn succeeds" '[ "$RC" -eq 0 ]'
checkc "fence2 landed in clone A's own free slot" '[ "$WT2" = "$PA" ] && [ "$(common_dir "$WT2")" = "$(common_dir "$CA")" ]'
checkc "no lease left under the fence2 holder" '[ -z "$(pool_status "$CA" | jq -r ".[] | select(.lease_holder == \"firstmate-spawn-fence:fence2\") | .path")" ]'

hdr "summary"
printf '%s\n' "${RESULTS[@]}"
say "passes=$PASSES fails=$FAILS"
[ "$FAILS" -eq 0 ]
