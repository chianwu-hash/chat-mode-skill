# chat-mode-skill

`chat-mode-skill` lets Codex coordinate bounded review, discussion, and isolated implementation with Claude Desktop Code on Windows without occupying the foreground desktop.

The current design uses:

- filesystem request files and transcripts for durable context;
- Windows UI Automation (UIA) to operate Claude Desktop in the background;
- accessible document text instead of screenshots or OCR for responses;
- sibling Git worktrees when Claude is explicitly asked to implement changes;
- explicit human approval for workspace trust and permission dialogs.

The previous PowerShell CLI runner and polling toolkit has been retired.

## Requirements

- Windows 11
- Codex with local Skill support
- Claude Desktop with Code access, signed in
- PowerShell 7 (`pwsh`)
- both agents able to read the same local repository

## Install

Clone the repository and copy the skill into the Codex skills directory:

```powershell
git clone https://github.com/chianwu-hash/chat-mode-skill.git
cd chat-mode-skill
pwsh -NoProfile -File .\install.ps1
```

On macOS or Linux, `./install.sh` installs the skill files for inspection, but the tested Claude Desktop UIA adapter is Windows-only.

Restart Codex after installation so it discovers the updated skill.

## Use

Ask naturally, for example:

```text
啟動 chat-mode，讓你和 Claude 用三個回合審查這個架構。Claude 只讀，不要修改檔案。
```

For a large implementation:

```text
啟動 chat-mode，讓 Claude 在隔離 worktree 實作這批文件與網頁修改，由你審查後再整合。
```

Codex should:

1. write a bounded request under `.chat-mode/exchange/`;
2. open the repository in Claude Desktop Code;
3. stop for any workspace trust or permission decision;
4. select the requested model and `Manual` mode through background UIA;
5. send a short request-file pointer;
6. read Claude's accessible response text until the unique completion marker appears;
7. evaluate the response and return the result to the user.

Successful UIA actions do not move the mouse, synthesize keystrokes, or bring Claude to the foreground.

## Isolated implementation

When the user explicitly asks Claude to modify files, Codex creates a clean sibling worktree and dedicated `chat-mode/claude-*` branch. Claude may write only inside that worktree and the declared path scope. The main worktree stays unchanged while Claude works.

After Claude stops, Codex inspects the complete diff, checks scope, reproduces tests, and decides whether to apply or cherry-pick the result. Claude never commits, pushes, manages branches, or writes directly into the main worktree. Worktree cleanup remains a separate user-authorized action.

## Safety model

- Codex owns the loop; Claude never starts another agent loop.
- Claude is read-only by default; Codex is the sole main-worktree writer.
- Isolated implementation uses one writer per worktree and an explicit `write_scope`.
- Trust and permission dialogs are never auto-approved.
- Sessions have turn, time, and response-size bounds.
- `.chat-mode/STOP` aborts the session.
- Screenshots and OCR are not the source of truth for long responses.
- Unexpected mutation or ambiguous UI state stops the session.

The canonical protocol is [skills/chat-mode/references/protocol.md](skills/chat-mode/references/protocol.md). Windows adapter details are in [skills/chat-mode/references/windows-uia.md](skills/chat-mode/references/windows-uia.md), and isolated implementation is defined in [skills/chat-mode/references/isolated-implementer.md](skills/chat-mode/references/isolated-implementer.md).

## Evidence

The first end-to-end background UIA run is recorded in [docs/smoke-test-2026-08-08.md](docs/smoke-test-2026-08-08.md).

## Status

Experimental. The 2026-08-08 smoke test validated one read-only Codex-to-Claude turn with Claude Opus 5, High effort, Manual mode, background send, and complete response extraction. The worktree helper is validated independently with a temporary isolated branch; an end-to-end Claude write session remains the next live test.
