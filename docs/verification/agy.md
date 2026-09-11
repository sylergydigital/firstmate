# Verification: the agy (Antigravity CLI) crewmate/scout adapter

Active empirical evidence for firstmate's agy adapter.
The skill tree rooted at [`.agents/skills/harness-adapters/SKILL.md`](../../.agents/skills/harness-adapters/references/harness/agy.md) owns the operating facts; this record owns how they were established and what is still unproven.

## Subject

| Field | Value |
|---|---|
| Version | `agy 1.2.0` |
| Verified | 2026-09-10 |
| Binary | `~/.local/bin/agy`, a stripped, dynamically-linked native ELF (no wrapper exec) |
| Platform | Linux x86-64 |
| Herdr on this host | 0.9.0, with a native but not-installed `antigravity-cli` integration |

## Detection

```
$ file ~/.local/bin/agy
.../agy: ELF 64-bit LSB pie executable, x86-64, ... stripped
```

The process name is exactly `agy` (no wrapper), so `bin/fm-harness.sh`'s ancestry arm matches `comm=agy` anchored.

```
$ cd /tmp/<isolated-dir> && git init -q
$ agy -p "Run the shell command: env | sort" --model gpt-oss-120b-medium --dangerously-skip-permissions --output-format json
{"conversation_id":"...","status":"SUCCESS","response":"...\nANTIGRAVITY_AGENT=1\nANTIGRAVITY_LS_VERSION=cli-1.2.0\n...\nCLAUDECODE=1\n...","...}
```

`ANTIGRAVITY_AGENT=1` is set on agy's own tool subprocesses; the same subprocess environment also carried `CLAUDECODE=1` inherited from the Claude primary that ran this command, confirming agy does not clear a foreign marker.
`bin/fm-harness.sh` therefore tests `ANTIGRAVITY_AGENT=1` before its `CLAUDECODE` line, matching the same precedence fix already applied for cursor/gemini/rovo.
`tests/fm-agy-harness.test.sh` pins this ordering with faked `ps` output and a faked marker environment (no live agy invocation needed for that portable test).

## Model and effort

```
$ agy models
gemini-3.8-flash-high	Gemini 3.8 Flash (High)
gemini-3.8-flash-medium	Gemini 3.8 Flash (Medium)
gemini-3.8-flash-low	Gemini 3.8 Flash (Low)
gemini-3.7-flash-high	Gemini 3.7 Flash (High)
gemini-3.7-flash-medium	Gemini 3.7 Flash (Medium)
gemini-3.7-flash-low	Gemini 3.7 Flash (Low)
gemini-3.6-flash-high	Gemini 3.6 Flash (High)
gemini-3.6-flash-medium	Gemini 3.6 Flash (Medium)
gemini-3.6-flash-low	Gemini 3.6 Flash (Low)
gemini-3.1-pro-high	Gemini 3.1 Pro (High)
gemini-3.1-pro-low	Gemini 3.1 Pro (Low)
claude-sonnet-4-6	Claude Sonnet 4.6 (Thinking)
claude-opus-4-6-thinking	Claude Opus 4.6 (Thinking)
gpt-oss-120b-medium	GPT-OSS 120B (Medium)

$ agy --help | grep -- --effort
  --effort                        Reasoning effort for the current CLI session (low|medium|high)
```

`--model <id>` and `--effort low|medium|high` were both confirmed accepted by a real `agy -p` call (the first command above used `--model gpt-oss-120b-medium`; a second call added `--effort low` with no error, output omitted as redundant).
`xhigh`/`max` are not in the printed vocabulary, so `bin/fm-spawn.sh`'s `effort_flag_for_harness` omits them for agy, the same "record but omit an unsupported value" policy as grok/rovo.

## Launch flag ordering: `-i`'s value is positional and greedy

```
$ agy -i --model gpt-oss-120b-medium --dangerously-skip-permissions 'Reply with exactly: HELLO_AGY_TEST'
Error: -i took "--model" as its prompt, so the intended prompt was left as an argument and ignored.
Attach the prompt to the flag (-i='your prompt') and move --model elsewhere on the command line.
```

`-i`/`--prompt-interactive` consumes the very next token as its prompt regardless of whether that token looks like another flag.
Every other flag must therefore be placed BEFORE `-i`, with the encoded brief directly following it and nothing in between:

```
$ agy --model gpt-oss-120b-medium --dangerously-skip-permissions -i 'Reply with exactly: HELLO_AGY_TEST'
```

This second invocation produced no flag-parsing error and started a real `agy` process (confirmed via `ps`, live PID with the exact launched command line), which is the ordering `bin/fm-spawn.sh`'s launch template uses.

## Not verified (2026-09-10 attempt)

The interactive-TUI launch was run once in an isolated `tmux` pane outside the fleet (a fresh scratch worktree, no firstmate state involved) with the flag ordering above.
The process started and stayed running, but `tmux capture-pane` returned no readable screen content for that session's available observation window.

## Compatibility launch: real render captured (2026-09-11)

A real `fm-spawn.sh` scout dispatch on `agy` (isolated throwaway `FM_HOME`, throwaway git project, tmux backend, no firstmate fleet state touched) rendered successfully this time:

```
Accessing workspace:
/home/.../proj

Do you trust the contents of this project?
Antigravity CLI requires permission to read, edit, and execute files here.

> Yes, I trust this folder
  No, exit
```

**Trust dialog is real and NOT bypassed by `--dangerously-skip-permissions`.** A first launch in an untrusted worktree (firstmate's treehouse paths are never in the shared `~/.gemini/antigravity-cli/settings.json` `trustedWorkspaces` list) blocks on this dialog until something selects "Yes, I trust this folder" (confirmed: an explicit `tmux send-keys Enter`, which is the default-highlighted option, unblocked it). This is a real gap for UNATTENDED dispatch: `fm-spawn.sh`'s launch template does not currently answer this prompt, so a fresh crewmate/scout worktree will sit idle at this dialog rather than proceeding, unless firstmate (or a control-plane step) sends the confirming keystroke. Not fixed in this task; flagged as a required follow-up before agy crewmate/scout dispatch can be treated as truly unattended, alongside the interrupt-key gap below.

After accepting trust, the encoded launch brief was picked up and answered correctly (`OK_AGY_SMOKE`, the exact string requested), and the composer rendered a real, readable status footer:

```
GPT-OSS 120B (Medium) │ Idle │ Context 82% left │ ~/.treehouse/proj-4bf6ee/1/proj
```

`/exit` was then sent and worked, cleanly ending the session and printing a resume hint (`Resume with -c (or command below): agy --conversation=<id>`) before returning to the host shell.

This confirms the composer/busy-state signal IS renderable (contradicting the earlier "no readable screen content" finding - the blank capture was evidently a one-off terminal-emulation issue, not a persistent agy defect) and that `/exit` is a real, working exit command with the same shape as `claude`/`codex`/`muse`/`rovo`.
It is deliberately NOT wired into `bin/fm-control-lib.sh` by this task: a harness-dependent control-plane check needs both a portable regression test and a live guard per `firstmate-coding-guidelines`, and this was a single manual observation, not that two-test proof. A future task should add `fm_busy_agy_tail_busy`-style classification (the `<model> │ <state> │ ...` footer looks straightforwardly parseable, following the shape of `fm_busy_rovo_tail_busy`) and `fm_control_exit_command agy` → `/exit`, each backed by the required tests, rather than this task guessing at the wiring from one observation.
Interrupt key, interrupt repeat count, and composer-clear-after-interrupt remain genuinely unobserved (not attempted this pass) and stay absent from `bin/fm-control-lib.sh`'s tables.

## Config-dir scoping: `ANTIGRAVITY_CLI_CONFIG_DIR` not honored, `$HOME` relocation is

Re-verified 2026-09-11 (agy 1.2.0, same host):

```
$ mkdir -p /tmp/<isolated-dir>/config/antigravity-cli
$ printf '{invalid json' > /tmp/<isolated-dir>/config/antigravity-cli/hooks.json
$ cd /tmp/<isolated-dir-workdir> && git init -q
$ env ANTIGRAVITY_CLI_CONFIG_DIR=/tmp/<isolated-dir>/config agy -p "say hi" --model gpt-oss-120b-medium --dangerously-skip-permissions --output-format json
{"conversation_id":"...","status":"SUCCESS","response":"Hi! ...","...}
```

A syntactically invalid `hooks.json` written only under the `ANTIGRAVITY_CLI_CONFIG_DIR` override path caused no error, confirming agy 1.2.0 does not read config from that path.

But the standard, already-precedented technique in this file - overriding `$HOME` for the launched process (the same shape `bin/fm-spawn.sh` uses for `muse`'s `XDG_CONFIG_HOME`/`XDG_DATA_HOME` and `gemini`'s `GEMINI_CLI_SYSTEM_SETTINGS_PATH`) - DOES relocate agy's config/credential tree:

```
$ env HOME=/tmp/<isolated-home> agy -p "say hi" --model gpt-oss-120b-medium --dangerously-skip-permissions --output-format json
Error: authentication required. Run 'agy' to log in, then retry.
```

Refusing with "authentication required" under an isolated `$HOME` (instead of succeeding, as every ordinary invocation on this host does) proves agy is not reading the real account's stored credentials from that isolated location - i.e. `$HOME` relocation genuinely isolates agy's whole config tree, credentials included.
So the config-scoping premise behind the original 2026-09-10 secondmate refusal was incomplete: a scoping mechanism does exist, it is just `$HOME` relocation rather than a dedicated config-dir flag, and for a *persistent* secondmate (which already gets its own persistent `FM_HOME`) the one-time OAuth login this forces is a one-time provisioning cost, not a per-task one.

## Hook-firing: not verified

agy's own embedded `hooks.json` reference (extracted from the installed binary's strings; agy 1.2.0 ships this documentation text internally) describes a `Stop` event that "fires when the execution loop terminates" - the turn-end signal a secondmate needs - configured either via a project-relative `.agents/hooks.json` ("customization root directory") or presumably the global `~/.gemini/antigravity-cli/hooks.json`/`~/.gemini/config/hooks.json` paths `bin/fm-control-lib.sh`'s sibling doc already named.

Two attempts to observe it firing were inconclusive:

```
$ mkdir -p .agents && cat > .agents/hooks.json <<'EOF'
{"fm-turnend-test":{"Stop":[{"type":"command","command":"printf 'STOP_HOOK_FIRED\n' >> /tmp/log"}]}}
EOF
$ agy -p "say hi" --model gpt-oss-120b-medium --dangerously-skip-permissions --output-format json
{"conversation_id":"...","status":"SUCCESS",...}
$ cat /tmp/log
cat: /tmp/log: No such file or directory
```

The `Stop` hook did not fire for a `-p` (print-mode, single-turn, non-interactive) invocation.
`bin/fm-spawn.sh`'s crewmate/scout launch template uses `-i`/`--prompt-interactive` instead (an auto-submit-at-launch interactive session, not print mode), which is the shape a `Stop` hook would plausibly need to observe an actual execution-loop termination - but `-i` refuses outside a real TTY:

```
$ agy --model gpt-oss-120b-medium --dangerously-skip-permissions --output-format json -i 'hi' < /dev/null
CLI error: bubbletea: error opening TTY: bubbletea: could not open TTY: open /dev/tty: no such device or address
```

So observing whether `Stop` fires for a real firstmate-shaped launch needs a real pane (tmux/Herdr), which in turn needs an authenticated agy session - and provisioning an isolated, authenticated `$HOME` requires a one-time interactive OAuth login with a live browser and a real Google account, which was out of scope for this task to perform unattended.
This is the actual remaining blocker, not the config-scoping question the 2026-09-10 verification framed it as.

## Secondmate

Refused by `bin/fm-spawn.sh` and `bin/fm-control-lib.sh`'s `fm_control_harness_supports_kind`, for the hook-firing reason above (config scoping itself is no longer the blocker; see the two sections above).
`tests/fm-agy-harness.test.sh` pins the refusal message.
Follow-up to lift the refusal: provision a candidate secondmate's persistent `FM_HOME`-scoped isolated `$HOME`, complete the one-time OAuth login there once (live browser, real Google account), install a `Stop` hook at `<isolated-home>/.gemini/antigravity-cli/hooks.json` wired to `bin/fm-busy-event.sh` the way `gemini`'s `AfterAgent` hook is wired in `bin/fm-spawn.sh`, launch `agy -i` inside a real pane, and confirm the hook fires and closes the turn. Only then extend `bin/fm-spawn.sh`'s secondmate launch template and remove the refusal.
