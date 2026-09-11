# Antigravity CLI (agy)

Verified on 2026-09-10, extended 2026-09-11, with Antigravity CLI 1.2.0. See `../../../../../docs/verification/agy.md` for the exact commands and output.

## Operating facts

| Fact | Value |
|---|---|
| Binary | Bare `agy`, resolved from `PATH`; no absolute-path resolver like kimi/muse/cursor/rovo. |
| Launch | `--model`, `--effort`, and `--dangerously-skip-permissions` first, then `-i "<brief>"` last: `-i`/`--prompt-interactive` greedily consumes the very next token as its prompt (verified live: `agy -i --model ...` errored with `-i took "--model" as its prompt`), so no flag may follow it. |
| Models | Real ids observed via `agy models`: `gemini-3.8-flash-{high,medium,low}`, `gemini-3.7-flash-{high,medium,low}`, `gemini-3.6-flash-{high,medium,low}`, `gemini-3.1-pro-{high,low}`, `claude-sonnet-4-6`, `claude-opus-4-6-thinking`, `gpt-oss-120b-medium`. Some Gemini ids already bake in an effort tier. |
| Busy state | Observed live 2026-09-11: a rendered composer footer `<model> │ <state> │ Context X% left │ <cwd>`, state seen as `Idle`. Real and readable, but NOT yet wired into `bin/fm-control-lib.sh`/`bin/fm-busy-lib.sh` - a harness-dependent classifier needs the two-test proof `firstmate-coding-guidelines` requires, which this one manual observation is not. |
| Exit command | Observed live 2026-09-11: `/exit` cleanly ends the session and prints a resume hint (`agy --conversation=<id>`). NOT yet wired into `fm_control_exit_command` for the same two-test reason as busy state. |
| Interrupt | Still unverified; not present in `fm_control_interrupt_key`. |
| Skill invocation | Unverified. |
| Autonomy | `--dangerously-skip-permissions`, verified to remove the approval gate for a shell command run through `agy -p`. It does NOT bypass the trust dialog below (verified live). |
| Trust dialog | REAL, confirmed live 2026-09-11: a first launch in an untrusted worktree (firstmate's treehouse paths are never in the shared `~/.gemini/antigravity-cli/settings.json` `trustedWorkspaces` list) blocks on "Do you trust the contents of this project?" until something selects "Yes, I trust this folder" - `--dangerously-skip-permissions` does not answer it. This is a real gap for unattended dispatch: `bin/fm-spawn.sh`'s launch template does not currently answer this prompt, so a fresh crewmate/scout worktree can sit idle here. Flagged as a required follow-up, not fixed by this task. |
| Environment marker | `ANTIGRAVITY_AGENT=1`, set on agy's own tool subprocesses (verified live, agy 1.2.0). It does NOT clear an inherited `CLAUDECODE`, so `bin/fm-harness.sh` tests this marker before its `CLAUDECODE` line, the same ordering hazard cursor/gemini/rovo document. |
| Composer | See Busy state above; readable but not yet classified programmatically. |
| Effort | `--effort low\|medium\|high` (agy 1.2.0 `--help`); no `xhigh`/`max`. |

## Secondmate: refused (config scoping is verified, hook firing is not)

agy is verified as a CREWMATE/SCOUT adapter only. This is narrower than the original 2026-09-10 verification concluded; see `docs/verification/agy.md` for the corrected picture.

- agy DOES support a hooks mechanism, documented in the installed binary's own embedded `hooks.json` reference text: named hook groups keyed by event (`PreToolUse`, `PostToolUse`, `PreInvocation`, `PostInvocation`, `Stop`), where `Stop` fires "when the execution loop terminates" - the turn-end signal a secondmate needs.
- `ANTIGRAVITY_CLI_CONFIG_DIR` does NOT scope config (reconfirmed 2026-09-11): a malformed `hooks.json` written only at that override path caused no parse error.
- Overriding `$HOME` for the launched process DOES relocate agy's entire config/credential tree (reconfirmed 2026-09-11: an `agy -p` call under an isolated `$HOME` returned `authentication required`, proving it is not reading the real account's stored credentials). This parallels the `XDG_CONFIG_HOME`/`XDG_DATA_HOME` technique `bin/fm-spawn.sh` already uses for `muse` and the `GEMINI_CLI_SYSTEM_SETTINGS_PATH` override it uses for `gemini`, so a persistent secondmate's own isolated `$HOME` (one-time OAuth at provisioning, never touching the captain's shared `~/.gemini`) is a real, precedented scoping option - NOT the dead end the original verification claimed.
- What is NOT verified: whether the `Stop` hook actually fires for a firstmate-launched agy process. A project-relative `.agents/hooks.json` `Stop` hook did not fire during a `agy -p` (print-mode) call (2026-09-11), and agy's `-i`/`--prompt-interactive` mode - the launch shape crewmate/scout dispatch and any secondmate would need - refuses outside a real TTY (`bubbletea: could not open TTY`), so it can only be observed live inside a real pane. Completing that observation also requires a one-time interactive OAuth login inside the isolated `$HOME`, which needs a live browser round-trip with a real Google account and was out of scope for this task to perform unattended.

`bin/fm-spawn.sh` refuses `--secondmate agy` on this narrower, corrected basis: not "no scoping mechanism exists" but "the scoping mechanism (`$HOME` relocation) is verified, and the turn-end signal it would carry (the `Stop` hook) is not yet proven to fire for a firstmate launch." Revisit by: provisioning a candidate secondmate's persistent `FM_HOME`-scoped `$HOME`, completing the one-time OAuth login there, then launching `agy` with `-i` inside a real pane (tmux/Herdr) with a `Stop` hook installed at `<isolated-home>/.gemini/antigravity-cli/hooks.json` and confirming it fires and can carry `bin/fm-busy-event.sh`'s turn-end contract the way `gemini`'s `AfterAgent` hook does.

## Herdr integration

Herdr (verified 0.9.0 on this host) ships a NATIVE `antigravity-cli` integration: `herdr integration install antigravity-cli` installs a hook script at `~/.gemini/config/hooks/herdr-agent-state.sh` so Herdr's own UI can track an agy conversation. This is Herdr's own agent-tracking feature, separate from and irrelevant to firstmate's turn-end supervision contract above; installing it does not give firstmate a task-scoped turn-end signal. It was NOT installed on this host as of this verification (`herdr integration status` reported `antigravity-cli: not installed`), and installing it would touch the same shared global Antigravity config the secondmate refusal above avoids, so this task did not install it.
