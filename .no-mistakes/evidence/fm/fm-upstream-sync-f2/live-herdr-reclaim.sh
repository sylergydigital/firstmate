#!/usr/bin/env bash
# Live driver: Herdr missing-endpoint reclaim guards ported onto RELAUNCH_REBIND.
# Drives the real bin/fm-spawn.sh (fresh spawn + --relaunch) against a real
# Herdr server in an isolated, guarded fm-lab-* session, with a real Treehouse
# pool rooted in a scratch dir. The only non-real piece is the worker itself:
# a raw "sh -c 'while :; do sleep 60; done'" launch command instead of an AI
# harness, plus (scenario G only) a PATH mv shim that fails the final record
# publication to force the abort path.
set -u

ROOT=${ROOT:?set ROOT to the firstmate checkout}
cd "$ROOT" || exit 1
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
export FM_GATE_REFUSE_BYPASS=1

TMP=$(mktemp -d /tmp/fm-reclaim-live.XXXXXX); TMP=$(cd "$TMP" && pwd -P)
# Treehouse 2.x takes its pool root from the repo's treehouse.toml (below), so
# the pool lives under $TMP/th/.treehouse and never in ~/.treehouse.
S=$(bin/fm-herdr-lab.sh name reclaim)
export HERDR_SESSION=$S
H="$TMP/home"
PROJ="$TMP/project"
HARN="sh -c 'while :; do sleep 60; done'"
PASSES=0 FAILS=0
RESULTS=()

LAB_UP=0
cleanup() {
  [ "$LAB_UP" = 1 ] && bin/fm-herdr-lab.sh teardown "$S" >/dev/null 2>&1 && echo "# lab session $S torn down"
  if [ -n "${HOME_HASH:-}" ]; then
    for id in anchor rcflat rcdup rcproj rcoff rcdrift rcab; do rm -rf "/tmp/fm-$id+$HOME_HASH" "/tmp/fm-$id"; done
  fi
  chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"
}
trap cleanup EXIT

say() { printf '%s\n' "$*"; }
hdr() { printf '\n===== %s =====\n' "$*"; }
ok() { PASSES=$((PASSES + 1)); RESULTS+=("PASS $1"); say "PASS: $1"; }
bad() { FAILS=$((FAILS + 1)); RESULTS+=("FAIL $1"); say "FAIL: $1"; }
checkc() { # <name> <shell-expression>
  if eval "$2"; then ok "$1"; else bad "$1"; fi
}
check() { # <name> <command...>
  local name=$1; shift
  if "$@"; then ok "$name"; else bad "$name"; fi
}

lab() { bin/fm-herdr-lab.sh run "$S" "$@"; }
meta() { sed -n "s/^$2=//p" "$H/state/$1.meta" | tail -1; }
journal() { sed -n "s/^$2=//p" "$H/state/$1.herdr-presentation" 2>/dev/null | tail -1; }
ws_list() { lab workspace list | jq -r '.result.workspaces[] | [.workspace_id, .label] | @tsv'; }
ws_exists() { lab workspace list | jq -e --arg w "$1" 'any(.result.workspaces[]; .workspace_id == $w)' >/dev/null; }
ws_count() { lab workspace list | jq '.result.workspaces | length'; }
tabs_in() { lab tab list --workspace "$1" | jq -r '.result.tabs[] | [.tab_id, .label] | @tsv'; }
task_tab_count() { # <id> -> count of fm-<id> tabs across every workspace
  local w n=0
  while IFS=$'\t' read -r w _; do
    n=$((n + $(lab tab list --workspace "$w" | jq --arg l "fm-$1" '[.result.tabs[] | select(.label == $l)] | length')))
  done < <(ws_list)
  echo "$n"
}
pane_exists() { lab pane get "$1" >/dev/null 2>&1; }
pane_cwd() { lab pane get "$1" | jq -r '.result.pane.foreground_cwd // .result.pane.cwd // empty'; }
snapshot() { say "-- herdr layout:"; while IFS=$'\t' read -r w l; do say "   workspace $w '$l'"; tabs_in "$w" | sed 's/^/      tab /'; done < <(ws_list); }

spawn() { # <id>
  env FM_SPAWN_NO_GUARD=1 FM_HOME="$H" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-spawn.sh" "$1" "$PROJ" "$HARN" --mode no-mistakes --yolo off --backend herdr
}
relaunch() { # <id> -> runs fm-spawn --relaunch, prints combined output, returns its rc
  env FM_SPAWN_NO_GUARD=1 FM_HOME="$H" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-spawn.sh" "$1" --relaunch --harness "$HARN" 2>&1
}
presentation() { printf '%s\n' "$1" > "$H/config/herdr-presentation-spaces"; }
close_pane() { lab pane close "$1" >/dev/null; sleep 1; }
show_meta() { say "-- $1.meta endpoint: window=$(meta "$1" window) ws=$(meta "$1" herdr_workspace_id) tab=$(meta "$1" herdr_tab_id) pane=$(meta "$1" herdr_pane_id) worktree=$(meta "$1" worktree)"; }
show_journal() {
  if [ -f "$H/state/$1.herdr-presentation" ]; then
    say "-- $1 presentation journal: version=$(journal "$1" version) ws=$(journal "$1" workspace_id) tab=$(journal "$1" tab_id) pane=$(journal "$1" pane_id) parent=$(journal "$1" parent_workspace_id) projection_id=$(journal "$1" projection_id)"
  else
    say "-- $1 presentation journal: (absent)"
  fi
}

# ---------------------------------------------------------------- setup
hdr "setup"
say "firstmate checkout: $ROOT ($(git -C "$ROOT" rev-parse --short HEAD))"
say "herdr: $(herdr --version 2>&1 | head -1); treehouse: $(treehouse --version 2>&1 | head -1)"
say "lab session: $S   scratch: $TMP   treehouse pool root: $TMP/th/.treehouse"
mkdir -p "$H/state" "$H/config"
touch "$H/state/.last-watcher-beat"
for id in anchor rcflat rcdup rcproj rcoff rcdrift rcab; do
  mkdir -p "$H/data/$id"
  printf '# Task\n## Captain'"'"'s intent\nLive reclaim fixture %s.\n\n## Firstmate spec\nKeep the isolated copy intact.\n' "$id" > "$H/data/$id/brief.md"
done
mkdir -p "$PROJ"
git -C "$PROJ" init -q
printf '# reclaim live fixture\n' > "$PROJ/README.md"
printf 'max_trees = 16\nroot = "%s"\n' "$TMP/th" > "$PROJ/treehouse.toml"
git -C "$PROJ" add README.md treehouse.toml
git -C "$PROJ" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
git clone --quiet --bare "$PROJ" "$PROJ.origin.git"
git -C "$PROJ" remote add origin "file://$PROJ.origin.git"
HOME_HASH=$(printf '%s' "$(cd "$H" && pwd -P)" | sha256sum | awk '{print $1}')
bin/fm-herdr-lab.sh provision "$S" || { echo "could not provision lab"; exit 1; }
LAB_UP=1

presentation off
spawn anchor > "$TMP/anchor.out" 2>&1 || { cat "$TMP/anchor.out"; echo "anchor spawn failed"; exit 1; }
W=$(meta anchor herdr_workspace_id)
case "$(meta anchor worktree)" in "$TMP/th/.treehouse/"*) ;; *) echo "anchor worktree escaped the scratch pool: $(meta anchor worktree)"; exit 1 ;; esac
say "anchor task spawned flat; home workspace 'firstmate' = $W"

# ---------------------------------------------------------------- A
hdr "A: flat task, pane destroyed, recorded workspace survives -> recreated in the recorded workspace"
spawn rcflat > "$TMP/rcflat.out" 2>&1 || { cat "$TMP/rcflat.out"; bad "A spawn"; }
show_meta rcflat
A_WT=$(meta rcflat worktree); A_PANE=$(meta rcflat herdr_pane_id); A_WS=$(meta rcflat herdr_workspace_id)
A_WSCOUNT=$(ws_count)
close_pane "$A_PANE"
say "closed pane $A_PANE; workspace $A_WS still present: $(ws_exists "$A_WS" && echo yes || echo no)"
OUT=$(relaunch rcflat); RC=$?
say "$ fm-spawn.sh rcflat --relaunch --harness \"$HARN\"  -> rc=$RC"; say "$OUT" | tail -5
show_meta rcflat; snapshot
check "A relaunch succeeds (rc=0)" [ "$RC" -eq 0 ]
check "A record keeps recorded workspace $A_WS" [ "$(meta rcflat herdr_workspace_id)" = "$A_WS" ]
check "A record rebinds to a new pane" [ "$(meta rcflat herdr_pane_id)" != "$A_PANE" ]
check "A new pane really exists in Herdr" pane_exists "$(meta rcflat herdr_pane_id)"
check "A worktree reused (no second copy)" [ "$(meta rcflat worktree)" = "$A_WT" ]
check "A exactly one fm-rcflat tab exists" [ "$(task_tab_count rcflat)" = 1 ]
check "A no workspace created" [ "$(ws_count)" = "$A_WSCOUNT" ]
sleep 1
check "A replacement shell sits in the recorded worktree" [ "$(pane_cwd "$(meta rcflat herdr_pane_id)")" = "$A_WT" ]

# ---------------------------------------------------------------- C
hdr "C: adversarial - a duplicate fm-<id> tab lives in another workspace -> refuse"
spawn rcdup > "$TMP/rcdup.out" 2>&1 || { cat "$TMP/rcdup.out"; bad "C spawn"; }
C_PANE=$(meta rcdup herdr_pane_id); C_WT=$(meta rcdup worktree)
X=$(lab workspace create --cwd "$TMP" --label captain-scratch --no-focus | jq -r '.result.workspace.workspace_id')
lab tab create --workspace "$X" --cwd "$TMP" --label fm-rcdup --no-focus >/dev/null
close_pane "$C_PANE"
say "closed rcdup pane $C_PANE; planted a stray fm-rcdup tab in workspace $X"
C_WSCOUNT=$(ws_count); C_TABS_W=$(tabs_in "$W" | wc -l)
OUT=$(relaunch rcdup); RC=$?
say "$ fm-spawn.sh rcdup --relaunch -> rc=$RC"; say "$OUT" | tail -3
check "C relaunch refuses (rc!=0)" [ "$RC" -ne 0 ]
check "C refusal names the competing tab/workspace" grep -q "another Herdr task tab named fm-rcdup exists in workspace '$X'" <<<"$OUT"
check "C no tab created in recorded workspace" [ "$(tabs_in "$W" | wc -l)" = "$C_TABS_W" ]
check "C no workspace created" [ "$(ws_count)" = "$C_WSCOUNT" ]
check "C record still names the old pane" [ "$(meta rcdup herdr_pane_id)" = "$C_PANE" ]
lab workspace close "$X" >/dev/null 2>&1 || true

# ---------------------------------------------------------------- D
hdr "D: projected task (presentation on), pane + own projection gone -> projection recreated"
presentation on
spawn rcproj > "$TMP/rcproj.out" 2>&1 || { cat "$TMP/rcproj.out"; bad "D spawn"; }
show_meta rcproj; show_journal rcproj
D_WS=$(meta rcproj herdr_workspace_id); D_PANE=$(meta rcproj herdr_pane_id); D_WT=$(meta rcproj worktree)
D_PID=$(journal rcproj projection_id)
checkc "D fresh spawn was projected into its own workspace" '[ "$D_WS" != "$W" ] && [ "$(journal rcproj parent_workspace_id)" = "$W" ]' 
close_pane "$D_PANE"
ws_exists "$D_WS" && { say "projection $D_WS survived the pane close; closing it explicitly"; lab workspace close "$D_WS" >/dev/null; sleep 1; }
say "projection workspace $D_WS present after pane loss: $(ws_exists "$D_WS" && echo yes || echo no)"
OUT=$(relaunch rcproj); RC=$?
say "$ fm-spawn.sh rcproj --relaunch -> rc=$RC"; say "$OUT" | tail -5
show_meta rcproj; show_journal rcproj; snapshot
ND_WS=$(meta rcproj herdr_workspace_id)
check "D relaunch succeeds (rc=0)" [ "$RC" -eq 0 ]
checkc "D record names a new projection workspace" '[ "$ND_WS" != "$D_WS" ] && [ "$ND_WS" != "$W" ]' 
check "D new projection workspace exists in Herdr" ws_exists "$ND_WS"
check "D new projection labelled for rcproj" grep -q "rcproj" <<<"$(ws_list | awk -F'\t' -v w="$ND_WS" '$1==w{print $2}')"
checkc "D journal rebound: v2, new ws/pane, same parent, new token" '[ "$(journal rcproj version)" = 2 ] && [ "$(journal rcproj workspace_id)" = "$ND_WS" ] && [ "$(journal rcproj pane_id)" = "$(meta rcproj herdr_pane_id)" ] && [ "$(journal rcproj parent_workspace_id)" = "$W" ] && [ "$(journal rcproj projection_id)" != "$D_PID" ]' 
check "D did not fall back into the shared parent workspace" [ -z "$(tabs_in "$W" | awk -F'\t' '$2=="fm-rcproj"')" ]
check "D worktree reused" [ "$(meta rcproj worktree)" = "$D_WT" ]
check "D exactly one fm-rcproj tab" [ "$(task_tab_count rcproj)" = 1 ]
check "D no journal scratch copy left" [ -z "$(find "$H/state" -name '*herdr-relaunch-journal-prior*' -print -quit)" ]

# ---------------------------------------------------------------- E
hdr "E: projected task, presentation switched off, pane + projection gone -> flat in recorded parent"
spawn rcoff > "$TMP/rcoff.out" 2>&1 || { cat "$TMP/rcoff.out"; bad "E spawn"; }
E_WS=$(meta rcoff herdr_workspace_id); E_PANE=$(meta rcoff herdr_pane_id); E_WT=$(meta rcoff worktree)
show_meta rcoff; show_journal rcoff
presentation off
close_pane "$E_PANE"
ws_exists "$E_WS" && { lab workspace close "$E_WS" >/dev/null; sleep 1; }
E_WSCOUNT=$(ws_count)
OUT=$(relaunch rcoff); RC=$?
say "$ fm-spawn.sh rcoff --relaunch (presentation off) -> rc=$RC"; say "$OUT" | tail -5
show_meta rcoff; show_journal rcoff; snapshot
check "E relaunch succeeds (rc=0)" [ "$RC" -eq 0 ]
check "E record lands flat in recorded parent $W" [ "$(meta rcoff herdr_workspace_id)" = "$W" ]
check "E fm-rcoff tab is in the parent workspace" [ -n "$(tabs_in "$W" | awk -F'\t' '$2=="fm-rcoff"')" ]
check "E no projection workspace created" [ "$(ws_count)" = "$E_WSCOUNT" ]
check "E stale projection journal retired" [ ! -e "$H/state/rcoff.herdr-presentation" ]
check "E worktree reused" [ "$(meta rcoff worktree)" = "$E_WT" ]
check "E same Herdr session" [ "$(meta rcoff herdr_session)" = "$S" ]

# ---------------------------------------------------------------- F
hdr "F: adversarial - drifted presentation journal -> refuse, journal untouched"
presentation on
spawn rcdrift > "$TMP/rcdrift.out" 2>&1 || { cat "$TMP/rcdrift.out"; bad "F spawn"; }
F_WS=$(meta rcdrift herdr_workspace_id); F_PANE=$(meta rcdrift herdr_pane_id)
close_pane "$F_PANE"
ws_exists "$F_WS" && { lab workspace close "$F_WS" >/dev/null; sleep 1; }
sed -i 's/^tab_id=.*/tab_id=w999:t999/' "$H/state/rcdrift.herdr-presentation"
F_SUM=$(sha256sum < "$H/state/rcdrift.herdr-presentation"); F_WSCOUNT=$(ws_count)
OUT=$(relaunch rcdrift); RC=$?
say "$ fm-spawn.sh rcdrift --relaunch -> rc=$RC"; say "$OUT" | tail -3
check "F relaunch refuses (rc!=0)" [ "$RC" -ne 0 ]
check "F refusal names the journal mismatch" grep -q "recovery journal does not match" <<<"$OUT"
check "F journal byte-identical" [ "$(sha256sum < "$H/state/rcdrift.herdr-presentation")" = "$F_SUM" ]
check "F no workspace created" [ "$(ws_count)" = "$F_WSCOUNT" ]
check "F no fm-rcdrift tab created" [ "$(task_tab_count rcdrift)" = 0 ]

# ---------------------------------------------------------------- G
hdr "G: abort after minting (record publication fails) -> journal restored, minted pane closed"
spawn rcab > "$TMP/rcab.out" 2>&1 || { cat "$TMP/rcab.out"; bad "G spawn"; }
G_WS=$(meta rcab herdr_workspace_id); G_PANE=$(meta rcab herdr_pane_id); G_TAB=$(meta rcab herdr_tab_id)
lab tab create --workspace "$G_WS" --cwd "$TMP" --label keepalive --no-focus >/dev/null
close_pane "$G_PANE"
say "closed rcab pane $G_PANE; its projection $G_WS kept alive by a sibling tab: $(ws_exists "$G_WS" && echo yes || echo no)"
show_journal rcab
G_JSUM=$(sha256sum < "$H/state/rcab.herdr-presentation"); G_MSUM=$(sha256sum < "$H/state/rcab.meta")
SHIM="$TMP/mvshim"; mkdir -p "$SHIM"
cat > "$SHIM/mv" <<'SH'
#!/usr/bin/env bash
for p in "$@"; do [ "$p" != "$FM_FAKE_META_PUBLISH_MV_FAIL" ] || exit 1; done
exec /usr/bin/mv "$@"
SH
chmod +x "$SHIM/mv"
G_TABS_BEFORE=$(tabs_in "$G_WS")
OUT=$(PATH="$SHIM:$PATH" FM_FAKE_META_PUBLISH_MV_FAIL="$H/state/rcab.meta" relaunch rcab); RC=$?
say "$ fm-spawn.sh rcab --relaunch (record publication forced to fail) -> rc=$RC"; say "$OUT" | tail -4
show_journal rcab; snapshot
check "G relaunch fails (rc!=0)" [ "$RC" -ne 0 ]
check "G journal restored byte-identical" [ "$(sha256sum < "$H/state/rcab.herdr-presentation")" = "$G_JSUM" ]
check "G record byte-identical (old endpoint kept)" [ "$(sha256sum < "$H/state/rcab.meta")" = "$G_MSUM" ]
checkc "G minted replacement tab/pane cleaned up" '[ "$(tabs_in "$G_WS")" = "$G_TABS_BEFORE" ] && [ "$(task_tab_count rcab)" = 0 ]' 
check "G no journal scratch copy left" [ -z "$(find "$H/state" -name '*herdr-relaunch-journal-prior*' -print -quit)" ]
hdr "G2: same task, no fault -> recreated inside its surviving recorded projection, journal advanced"
OUT=$(relaunch rcab); RC=$?
say "$ fm-spawn.sh rcab --relaunch -> rc=$RC"; say "$OUT" | tail -3
show_meta rcab; show_journal rcab
check "G2 relaunch succeeds" [ "$RC" -eq 0 ]
check "G2 stays in recorded projection $G_WS" [ "$(meta rcab herdr_workspace_id)" = "$G_WS" ]
checkc "G2 journal advanced to the replacement tab/pane" '[ "$(journal rcab pane_id)" = "$(meta rcab herdr_pane_id)" ] && [ "$(journal rcab tab_id)" = "$(meta rcab herdr_tab_id)" ] && [ "$(journal rcab tab_id)" != "$G_TAB" ]' 

# ---------------------------------------------------------------- B
hdr "B: adversarial - recorded flat workspace destroyed -> refuse; gone projection whose parent is gone -> refuse"
D2_PANE=$(meta rcproj herdr_pane_id); D2_WS=$(meta rcproj herdr_workspace_id)
lab workspace close "$W" >/dev/null; sleep 1
close_pane "$D2_PANE"
ws_exists "$D2_WS" && { lab workspace close "$D2_WS" >/dev/null; sleep 1; }
say "closed home workspace $W (flat tasks' recorded workspace) and rcproj's projection $D2_WS"
snapshot
B_WSCOUNT=$(ws_count); B_MSUM=$(sha256sum < "$H/state/rcflat.meta")
OUT=$(relaunch rcflat); RC=$?
say "$ fm-spawn.sh rcflat --relaunch -> rc=$RC"; say "$OUT" | tail -3
check "B flat relaunch refuses (rc!=0)" [ "$RC" -ne 0 ]
check "B refusal names the missing recorded workspace" grep -q "recorded Herdr workspace '$W' for task rcflat is missing" <<<"$OUT"
check "B no workspace created" [ "$(ws_count)" = "$B_WSCOUNT" ]
check "B no fm-rcflat tab created" [ "$(task_tab_count rcflat)" = 0 ]
check "B record byte-identical" [ "$(sha256sum < "$H/state/rcflat.meta")" = "$B_MSUM" ]
OUT=$(relaunch rcproj); RC=$?
say "$ fm-spawn.sh rcproj --relaunch -> rc=$RC"; say "$OUT" | tail -3
check "B projected-without-parent relaunch refuses" [ "$RC" -ne 0 ]
check "B refusal names both projection and parent gone" grep -q "recorded parent workspace '$W' are both gone" <<<"$OUT"
check "B still no workspace created" [ "$(ws_count)" = "$B_WSCOUNT" ]

hdr "B2: adversarial - a NEW workspace labelled 'firstmate' replaces the destroyed one -> still refuse, never adopt it"
IMP=$(lab workspace create --cwd "$TMP" --label firstmate --no-focus | jq -r '.result.workspace.workspace_id')
say "created impostor workspace $IMP labelled 'firstmate' (recorded parent/flat workspace was $W)"
snapshot
OUT=$(relaunch rcflat); RC=$?
say "$ fm-spawn.sh rcflat --relaunch -> rc=$RC"; say "$OUT" | tail -2
check "B2 flat relaunch still refuses" [ "$RC" -ne 0 ]
check "B2 no fm-rcflat tab landed in the impostor" [ -z "$(tabs_in "$IMP" | awk -F'\t' '$2=="fm-rcflat"')" ]
OUT=$(relaunch rcproj); RC=$?
say "$ fm-spawn.sh rcproj --relaunch -> rc=$RC"; say "$OUT" | tail -2
check "B2 projected relaunch still refuses (parent id must match, not just label)" [ "$RC" -ne 0 ]
check "B2 no fm-rcproj tab landed in the impostor" [ -z "$(tabs_in "$IMP" | awk -F'\t' '$2=="fm-rcproj"')" ]
check "B2 no projection workspace created" [ "$(ws_count)" = "$((B_WSCOUNT + 1))" ]

hdr "summary"
printf '%s\n' "${RESULTS[@]}"
say "passes=$PASSES fails=$FAILS"
[ "$FAILS" -eq 0 ]
