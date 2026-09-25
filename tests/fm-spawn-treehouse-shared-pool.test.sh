#!/usr/bin/env bash
# Regression tests for fm-spawn in a Treehouse pool shared by two clones.
#
# Treehouse keys a pool by repository name plus origin URL, so two local clones
# of one origin share it, and its get hands out the lowest free slot whichever
# clone owns that worktree.
# These tests drive the real spawn path with a fake terminal and a stateful fake
# Treehouse whose lowest free slots belong to the other clone, then prove the
# spawn lands in its own clone's worktree and returns every slot it fenced.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-treehouse-shared-pool)

# The fake Treehouse keeps one ordered slot list plus one owner file per busy
# slot: "lease:<holder>" for a durable lease, "pane" for the interactive get.
write_fake_treehouse() {
  local fakebin=$1
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
db=$FM_FAKE_TH_DB
printf '%s\n' "$*" >> "$db/calls.log"
first_free() {
  local slot
  while IFS= read -r slot; do
    [ -e "$db/owner.$(basename "$(dirname "$slot")")" ] || { printf '%s\n' "$slot"; return 0; }
  done < "$db/slots"
  return 1
}
case "${1:-}" in
  status)
    sep='['
    while IFS= read -r slot; do
      n=$(basename "$(dirname "$slot")")
      st=available holder=
      if [ -e "$db/owner.$n" ]; then
        st=in-use
        holder=$(sed -n 's/^lease://p' "$db/owner.$n")
      fi
      printf '%s{"name":"%s","path":"%s","status":"%s","lease_id":"","lease_holder":"%s","leased_at":null,"processes":[]}' "$sep" "$n" "$slot" "$st" "$holder"
      sep=','
    done < "$db/slots"
    printf ']\n'
    ;;
  get)
    slot=$(first_free) || exit 1
    n=$(basename "$(dirname "$slot")")
    if [ "${2:-}" = --lease ]; then
      printf 'lease:%s\n' "${4:-}" > "$db/owner.$n"
      if [ -n "${FM_FAKE_TH_TERM_AT_LEASE:-}" ] \
         && [ "$(grep -c -- '^get --lease' "$db/calls.log")" = "$FM_FAKE_TH_TERM_AT_LEASE" ]; then
        pid=$PPID spawn_pid=
        while [ "$pid" -gt 1 ]; do
          if grep -q 'bin/fm-spawn\.sh' "/proc/$pid/cmdline" 2>/dev/null; then
            spawn_pid=$pid
          elif [ -n "$spawn_pid" ]; then
            break
          fi
          pid=$(awk '{print $4}' "/proc/$pid/stat")
        done
        kill -TERM "$spawn_pid"
      fi
      printf '%s\n' "$slot"
    else
      printf 'pane\n' > "$db/owner.$n"
      printf '%s\n' "$slot" > "$db/pane"
    fi
    ;;
  return)
    [ "${2:-}" = --if-lease-holder ] || exit 2
    n=$(basename "$(dirname "$4")")
    [ "$(cat "$db/owner.$n" 2>/dev/null)" = "lease:$3" ] || exit 1
    rm -f "$db/owner.$n"
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/treehouse"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) cat "$FM_FAKE_TH_DB/pane"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n' ;;
  send-keys)
    for a in "$@"; do
      [ "$a" != 'treehouse get' ] || treehouse get
    done
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
}

# <case> <id> <foreign-slots> <own-slot-numbers...>: pool slots 1..N, where the
# first <foreign-slots> belong to the other clone and the rest to the project.
make_case() {
  local name=$1 id=$2 foreign=$3 case_dir home origin project other pool db fakebin n total=$4 owner
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  origin="$case_dir/origin.git"
  project="$case_dir/main-home/repo"
  other="$case_dir/secondmate-home/repo"
  pool="$case_dir/pool"
  db="$case_dir/th"
  fakebin=$(fm_fakebin "$case_dir/fake")
  fm_fake_exit0 "$fakebin" sleep
  write_fake_treehouse "$fakebin"

  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config" "$db" "$pool"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_test_spawn_brief "$home" "$id"
  touch "$home/state/.last-watcher-beat"

  git init --quiet -b main "$case_dir/seed"
  printf 'base\n' > "$case_dir/seed/README.md"
  git -C "$case_dir/seed" add README.md
  git -C "$case_dir/seed" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git clone --quiet --bare "$case_dir/seed" "$origin"
  git clone --quiet "file://$origin" "$project"
  git clone --quiet "file://$origin" "$other"

  printf '{"worktrees":[]}\n' > "$pool/treehouse-state.json"
  : > "$db/slots"
  for n in $(seq 1 "$total"); do
    owner=$project
    [ "$n" -gt "$foreign" ] || owner=$other
    git -C "$owner" worktree add --quiet --detach "$pool/$n/repo" HEAD
    printf '%s\n' "$pool/$n/repo" >> "$db/slots"
  done
  printf '%s\n' "$project" > "$db/pane"
  printf '%s\n' "$home|$project|$pool|$db|$fakebin"
}

read_case_record() {
  IFS='|' read -r HOME_DIR PROJECT_DIR POOL_DIR DB_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_spawn() {
  local id=$1
  shift
  FM_FAKE_TH_DB="$DB_DIR" fm_test_run_spawn "$HOME_DIR" "$PROJECT_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJECT_DIR" "$@"
}

test_spawn_skips_foreign_lowest_slots() {
  local rec id out status leftover
  id='shared-pool-foreign-first'
  rec=$(make_case foreign-first "$id" 2 4)
  read_case_record "$rec"

  out=$(run_spawn "$id" --scout)
  status=$?
  expect_code 0 "$status" \
    "a spawn whose lowest free slots belong to another clone should still launch"$'\n'"$out"
  assert_grep "worktree=$POOL_DIR/3/repo" "$HOME_DIR/state/$id.meta" \
    "the spawn did not land in its own clone's lowest free worktree"
  [ "$(cat "$DB_DIR/owner.3")" = pane ] \
    || fail "the interactive get did not hold the project's own slot"
  for n in 1 2; do
    leftover=$(cat "$DB_DIR/owner.$n" 2>/dev/null || true)
    [ -z "$leftover" ] || fail "foreign slot $n was left fenced after the spawn: $leftover"
  done
  assert_grep "get --lease --lease-holder firstmate-spawn-fence:$id" "$DB_DIR/calls.log" \
    "the spawn did not fence the foreign slots through a Treehouse lease"
  pass "a spawn in a shared pool skips the other clone's lowest free slots and returns them"
}

test_unshared_pool_takes_no_lease() {
  local rec id out status
  id='shared-pool-own-only'
  rec=$(make_case own-only "$id" 0 2)
  read_case_record "$rec"

  out=$(run_spawn "$id" --scout)
  status=$?
  expect_code 0 "$status" "a spawn in an unshared pool should launch"$'\n'"$out"
  assert_grep "worktree=$POOL_DIR/1/repo" "$HOME_DIR/state/$id.meta" \
    "the spawn did not take the pool's lowest free slot"
  if grep -q -- '--lease' "$DB_DIR/calls.log"; then
    fail "a pool with no foreign slot was fenced anyway: $(cat "$DB_DIR/calls.log")"
  fi
  pass "a pool used by one clone is not fenced"
}

test_interrupted_fence_returns_leases_taken() {
  local rec id out status leftover
  id='shared-pool-interrupted'
  rec=$(make_case interrupted "$id" 3 4)
  read_case_record "$rec"

  out=$(FM_FAKE_TH_TERM_AT_LEASE=3 run_spawn "$id" --scout)
  status=$?
  [ "$status" != 0 ] || fail "a spawn terminated mid-fence should not report success"$'\n'"$out"
  [ ! -e "$DB_DIR/pane" ] || [ "$(cat "$DB_DIR/pane")" = "$PROJECT_DIR" ] \
    || fail "a spawn terminated mid-fence still ran the interactive get"
  for n in 1 2 3; do
    leftover=$(cat "$DB_DIR/owner.$n" 2>/dev/null || true)
    [ -z "$leftover" ] || fail "foreign slot $n stayed fenced after the spawn was terminated: $leftover"$'\n'"$out"
  done
  pass "a spawn terminated mid-fence returns the foreign slots it already leased"
}

test_spawn_skips_foreign_lowest_slots
test_unshared_pool_takes_no_lease
test_interrupted_fence_returns_leases_taken

echo "# all fm-spawn-treehouse-shared-pool tests passed"
