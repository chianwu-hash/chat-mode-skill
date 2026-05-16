# chat-mode-skill

`chat-mode-skill` is a Codex Skill and small toolkit for running bounded agent-to-agent collaboration between Codex and Claude Code. It uses a shared state file, one markdown file per session, mirrored start prompts, and ScheduleWakeup-style polling so two agents can discuss, review, and refine a task without the user manually relaying every turn.

## Requirements

- Codex with local Skill support
- Claude Code or another second agent that can read and write files in the same host project
- PowerShell 7.6.1 or newer for the helper scripts. Use `pwsh`, not Windows PowerShell 5.1 (`powershell.exe`).
- A host project where both agents can access the same working tree

## Install

1. Clone this repository.

   ```powershell
   git clone https://github.com/chianwu-hash/chat-mode-skill.git
   ```

2. Run the installer for your platform.

   Linux/macOS:

   ```bash
   ./install.sh
   ```

   Windows:

   ```powershell
   .\install.ps1
   ```

   To also copy helper scripts into a host project:

   ```bash
   ./install.sh --tools-target ../your-host-project/tools
   ```

   ```powershell
   .\install.ps1 -ToolsTarget ..\your-host-project\tools
   ```

   The installers check for `git`, `pwsh`, `codex`, and `claude`. They can auto-install `git` and `pwsh` on supported platforms, while `codex` and `claude` remain account-based tools that are reported as warnings when missing. Project scripts are intended to run under PowerShell 7.6.1+ through `pwsh`.

3. Manual install is also supported. Copy the skill folder into your Codex skills directory.

   ```powershell
   Copy-Item -Recurse .\chat-mode-skill\skills\chat-mode $env:USERPROFILE\.codex\skills\chat-mode
   ```

   The exact Codex skills directory may vary by installation. On Windows, `$env:USERPROFILE\.codex\skills\` is the common default. On macOS/Linux, it is commonly `~/.codex/skills/`. If your Codex setup uses `CODEX_HOME`, install to `$env:CODEX_HOME\skills\chat-mode` on PowerShell or `$CODEX_HOME/skills/chat-mode` in POSIX shells.

4. Copy the helper scripts into any host project where you want chat-mode support.

   ```powershell
   Copy-Item -Recurse .\chat-mode-skill\tools .\your-host-project\tools
   ```

The helper scripts default to this host-project layout:

```text
.chat-mode/
  agent-sync-state.json
  config.json
  sessions/
  tmp/
  wakeup-logs/
```

You can override paths with `-StatePath`, `-SessionDir`, and `-LogDir` where supported.

## Quick Start

Natural language trigger:

```text
啟動暢聊模式 4 回合，檢視 chat-mode-skill 是否能順利運作，是否可以 commit+push，你先開始
```

In this repository, agents should interpret that as a request to use `tools/chat-mode-run.ps1` for real CLI orchestration. They should not manually roleplay the other agent.

Smoke tests such as `tests/smoke.ps1` and `tests/run-smoke.ps1` verify scripts, but they are not the chat-mode session itself.

For CLI orchestration, run first setup from Codex so the project records verified CLI paths for this host:

```powershell
pwsh -NoProfile -File .\tools\chat-mode-setup.ps1
```

If Claude Code starts first and `.chat-mode/config.json` does not contain a verified `codex_exe`, it should stop and ask the user to run this setup from Codex.

Then run a real 4-turn CLI-orchestrated session:

```powershell
pwsh -NoProfile -File .\tools\chat-mode-run.ps1 `
  -NewSession `
  -Topic "review the release plan" `
  -TaskSummary "review release plan" `
  -MaxTurns 4 `
  -FirstMover claude
```

`chat-mode-run.ps1` calls both worker CLIs as subprocesses, appends each response to the session markdown, and updates state. Do not manually simulate worker rounds when this runner is available.

From the host project, start a 4-turn session:

```powershell
pwsh -NoProfile -File .\tools\chat-mode-start.ps1 `
  -Topic "review the release plan" `
  -MaxTurns 4 `
  -FirstMover codex `
  -TaskSummary "review release plan" `
  -WritePromptFile
```

The command creates:

- `.chat-mode/agent-sync-state.json`
- `.chat-mode/sessions/YYYY-MM-DD-review-release-plan.md`
- `.chat-mode/claude-start-prompt.txt` when `-WritePromptFile` is used

Copy the mirrored prompt to Claude Code. The starter only bootstraps the state and session files; it does not write round 1. The agent named by `current_agent` writes the next round. If Codex is the first mover, Codex should show the prompt first, then write round 1 in the same response and enter the polling loop. If Claude Code is the first mover, Codex should stop after prompt/setup or schedule a passive recheck.

## Protocol Summary

- The state file is the entry point.
- The `session_file` field points to the active markdown transcript.
- Round content goes into the session file, not into handoff notes.
- The starter creates state/session files and leaves `current_agent` set to the first mover.
- The current agent writes its round, updates state, schedules wakeup, and runs at least the first poll.
- When the turn limit is reached, set `status=done`, `current_agent=user`, and `stop_reason=turn_limit_reached`.

See [Claude CLI Orchestration Proposal](docs/claude-cli-orchestration.md) for the proposed smoother path where Codex invokes Claude CLI directly and keeps polling as a fallback. The related [CLI Flag Validation](docs/cli-flag-validation.md) and [Worker Prompt Template](docs/worker-prompt-template.md) documents capture the current implementation prerequisites.

## Status

This project is experimental. The first release target is `v0.1.0`, focused on a clear protocol, a portable Skill, PowerShell helper scripts, and smoke tests.
