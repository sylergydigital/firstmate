#!/usr/bin/env bash
# Behavior tests for the Antigravity CLI (agy) crewmate/scout adapter.
#
# The facts pinned here are the ones an agy release could silently change and
# the ones a wrong guess would make dangerous:
#   1. ANTIGRAVITY_AGENT=1 is agy's own child/tool-process marker, and it
#      outranks an inherited CLAUDECODE, because agy does NOT clear one
#      (verified live on agy 1.2.0 under a claude primary, where an agy tool
#      process carried ANTIGRAVITY_AGENT=1 and CLAUDECODE=1 together).
#   2. -i/--prompt-interactive greedily consumes the very next token as its
#      prompt, even one that looks like another flag (verified live: `agy -i
#      --model ...` errored with `-i took "--model" as its prompt`), so every
#      other flag must be placed BEFORE -i and nothing may sit between -i and
#      its argument.
#   3. agy is a crewmate/scout adapter only: it has no primary supervision
#      protocol that can be installed without writing into the shared global
#      Antigravity config every real agy invocation on the host reads
#      (docs/verification/agy.md), so a secondmate launch on it is refused.
#   4. agy's interactive-TUI composer, interrupt key, and exit command remain
#      UNVERIFIED (docs/verification/agy.md), so the control-plane tables must
#      NOT claim them.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"

HARNESS="$ROOT/bin/fm-harness.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-agy-harness)

test_agy_marker_outranks_inherited_claudecode() {
  local out
  # This is the exact hazard: agy does not clear an inherited CLAUDECODE, so
  # an agy worker under a claude primary carries both markers at once.
  out=$(CLAUDECODE=1 ANTIGRAVITY_AGENT=1 "$HARNESS")
  [ "$out" = agy ] || fail "CLAUDECODE + ANTIGRAVITY_AGENT must detect agy, got '$out'"
  # Drive the two signals apart so the case above cannot go quietly vacuous:
  # each marker alone must still produce its own verdict.
  out=$(env -u CLAUDECODE ANTIGRAVITY_AGENT=1 "$HARNESS")
  [ "$out" = agy ] || fail "ANTIGRAVITY_AGENT alone must detect agy, got '$out'"
  out=$(env -u ANTIGRAVITY_AGENT CLAUDECODE=1 "$HARNESS")
  [ "$out" = claude ] || fail "CLAUDECODE alone must still detect claude, got '$out'"
  # Cursor's, gemini's, and rovo's markers still outrank agy's, preserving the
  # documented precedence order.
  out=$(CURSOR_AGENT=1 ANTIGRAVITY_AGENT=1 "$HARNESS")
  [ "$out" = cursor ] || fail "CURSOR_AGENT must still outrank ANTIGRAVITY_AGENT, got '$out'"
  out=$(GEMINI_CLI=1 ANTIGRAVITY_AGENT=1 "$HARNESS")
  [ "$out" = gemini ] || fail "GEMINI_CLI must still outrank ANTIGRAVITY_AGENT, got '$out'"
  out=$(ATLASSIAN_AGENT_TYPE=rovo ANTIGRAVITY_AGENT=1 "$HARNESS")
  [ "$out" = rovo ] || fail "ATLASSIAN_AGENT_TYPE must still outrank ANTIGRAVITY_AGENT, got '$out'"
  # A non-1 ANTIGRAVITY_AGENT is not the verified marker value.
  out=$(env -u ANTIGRAVITY_AGENT -u CLAUDECODE -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
        -u GEMINI_CLI -u PI_CODING_AGENT -u GROK_AGENT -u ATLASSIAN_AGENT_TYPE \
        -u ROVODEV_CLI ANTIGRAVITY_AGENT=0 "$HARNESS")
  [ "$out" != agy ] || fail "ANTIGRAVITY_AGENT=0 must not claim the agy identity, got '$out'"
  pass "fm-harness.sh: agy's marker outranks an inherited CLAUDECODE"
}

test_agy_ancestry_matches_only_the_exact_command_name() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/ancestry")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' 'agy'; exit 0 ;;
  *"args="*) printf '%s\n' 'agy'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(env -u ANTIGRAVITY_AGENT -u CLAUDECODE -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
        -u GEMINI_CLI -u PI_CODING_AGENT -u GROK_AGENT -u ATLASSIAN_AGENT_TYPE \
        -u ROVODEV_CLI PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" = agy ] || fail "an exact agy ancestry command must be detected, got '$out'"
  pass "fm-harness.sh: ancestry detects the exact agy command name"
}

test_agy_ancestry_rejects_unrelated_mentions() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/ancestry-reject")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' 'agyagram-daemon'; exit 0 ;;
  *"args="*) printf '%s\n' 'agyagram-daemon --serve'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(env -u ANTIGRAVITY_AGENT -u CLAUDECODE -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
        -u GEMINI_CLI -u PI_CODING_AGENT -u GROK_AGENT -u ATLASSIAN_AGENT_TYPE \
        -u ROVODEV_CLI PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" != agy ] || fail "an unrelated command sharing the agy prefix must not be misread as agy, got '$out'"
  pass "fm-harness.sh: ancestry never misreads an unrelated agy-prefixed command"
}

make_spawn_case() {
  local name=$1 case_dir home proj wt fakebin id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  id="agy-$name-x1"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" agy)
  fm_test_spawn_home "$home"
  fm_test_spawn_brief "$home" "$id"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$id"
}

test_agy_launch_command_shape() {
  local rec case_dir home proj wt fakebin id out status launch
  rec=$(make_spawn_case launch)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  FM_FAKE_LAUNCH_LOG="$case_dir/launch.log"
  : > "$FM_FAKE_LAUNCH_LOG"
  out=$(FM_FAKE_LAUNCH_LOG="$FM_FAKE_LAUNCH_LOG" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" \
    "$id" "$proj" agy --model gemini-3.1-pro-high --effort high --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "agy spawn should succeed"
  assert_contains "$out" "spawned $id harness=agy" "agy spawn did not report success"

  launch=$(cat "$FM_FAKE_LAUNCH_LOG")
  assert_contains "$launch" "env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS -u GEMINI_CLI -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u ATLASSIAN_AGENT_TYPE -u ROVODEV_CLI agy" \
    "agy launch did not clear every foreign primary marker before the bare agy command"
  assert_contains "$launch" "--model 'gemini-3.1-pro-high'" "agy launch omitted the requested model"
  assert_contains "$launch" "--effort 'high'" "agy launch omitted the requested effort"
  assert_contains "$launch" "--dangerously-skip-permissions" "agy launch omitted the autonomy flag"
  # -i's argument is positional and greedy (verified live), so nothing may sit
  # between -i and the encoded brief: every other flag must precede -i.
  case "$launch" in
    *"-i \"\$("*) : ;;
    *) fail "agy launch's -i flag was not immediately followed by the encoded brief: $launch" ;;
  esac
  case "$launch" in
    *"-i "*"--"*) fail "agy launch placed another flag after -i, which -i would swallow as its prompt: $launch" ;;
  esac
  pass "fm-spawn: agy launches with every flag before -i, and -i takes the encoded brief directly"
}

test_agy_effort_xhigh_is_recorded_but_omitted() {
  local rec case_dir home proj wt fakebin id out status launch meta
  rec=$(make_spawn_case effort-xhigh)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  FM_FAKE_LAUNCH_LOG="$case_dir/launch.log"
  : > "$FM_FAKE_LAUNCH_LOG"
  out=$(FM_FAKE_LAUNCH_LOG="$FM_FAKE_LAUNCH_LOG" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" agy --effort xhigh --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "agy spawn with an unsupported effort should still succeed"
  launch=$(cat "$FM_FAKE_LAUNCH_LOG")
  assert_not_contains "$launch" "--effort" "agy launch passed an unsupported effort value instead of omitting it"
  meta="$home/state/$id.meta"
  assert_grep 'effort=xhigh' "$meta" "agy meta did not retain the unsupported effort axis"
  pass "fm-spawn: agy omits an unsupported effort flag but keeps it in task metadata"
}

test_agy_secondmate_is_refused() {
  local case_dir home proj fakebin out status
  case_dir="$TMP_ROOT/secondmate-refuse"
  home="$case_dir/home"
  proj="$case_dir/project"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" agy)
  fm_test_spawn_home "$home"
  mkdir -p "$home/state"
  touch "$home/state/.last-watcher-beat"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 PATH="$fakebin:$PATH" \
    "$SPAWN" "agy-secondmate-refuse-x1" --secondmate agy 2>&1) || status=$?
  status=${status:-0}
  [ "$status" -ne 0 ] || fail "an agy secondmate spawn should be refused"
  assert_contains "$out" "agy is a verified crewmate/scout adapter only" \
    "agy secondmate refusal lacked its concrete reason"
  pass "fm-spawn: agy cannot be launched as a secondmate"
}

test_agy_control_lib_table() {
  local out
  fm_control_harness_supported agy || fail "agy must be a supported control harness"
  out=$(fm_control_harness_family agy-anything)
  [ "$out" = agy ] || fail "a recorded agy* harness must resolve to agy, got '$out'"
  fm_control_harness_supports_kind agy ship || fail "agy should support ship tasks"
  fm_control_harness_supports_kind agy scout || fail "agy should support scout tasks"
  if fm_control_harness_supports_kind agy secondmate; then
    fail "agy should never support secondmate tasks"
  fi
  pass "fm-control-lib: agy's task-kind table matches its verified facts"
}

test_agy_control_mechanics_stay_unclaimed() {
  # agy's interactive-TUI composer, interrupt key, and exit command are
  # UNVERIFIED (docs/verification/agy.md): the control-plane tables must
  # refuse rather than guess until a live pane confirms them.
  if fm_control_interrupt_key agy >/dev/null 2>&1; then
    fail "agy's interrupt key is unverified and must not be claimed"
  fi
  if fm_control_exit_command agy >/dev/null 2>&1; then
    fail "agy's exit command is unverified and must not be claimed"
  fi
  pass "fm-control-lib: agy's unverified control mechanics correctly refuse rather than guess"
}

test_agy_marker_outranks_inherited_claudecode
test_agy_ancestry_matches_only_the_exact_command_name
test_agy_ancestry_rejects_unrelated_mentions
test_agy_launch_command_shape
test_agy_effort_xhigh_is_recorded_but_omitted
test_agy_secondmate_is_refused
test_agy_control_lib_table
test_agy_control_mechanics_stay_unclaimed
