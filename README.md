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
  sessions/
  wakeup-logs/
```

You can override paths with `-StatePath`, `-SessionDir`, and `-LogDir` where supported.

## Quick Start

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

Copy the mirrored prompt to Claude Code. If Codex is the first mover, Codex should show the prompt first, then write round 1 in the same response and enter the polling loop.

## Protocol Summary

- The state file is the entry point.
- The `session_file` field points to the active markdown transcript.
- Round content goes into the session file, not into handoff notes.
- The current agent writes its round, updates state, schedules wakeup, and runs at least the first poll.
- When the turn limit is reached, set `status=done`, `current_agent=user`, and `stop_reason=turn_limit_reached`.

## Status

This project is experimental. The first release target is `v0.1.0`, focused on a clear protocol, a portable Skill, PowerShell helper scripts, and smoke tests.
