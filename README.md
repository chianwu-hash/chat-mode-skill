# chat-mode-skill

`chat-mode-skill` lets Codex coordinate bounded review, discussion, and isolated implementation with Claude Desktop Code on Windows without occupying the foreground desktop.

The current design uses:

- filesystem request files and transcripts for durable context;
- Windows UI Automation (UIA) to operate Claude Desktop in the background;
- accessible document text instead of screenshots or OCR for responses;
- sibling Git worktrees when Claude is explicitly asked to implement changes;
- exclusive main-worktree handoff when the user explicitly requests equal non-isolated project access;
- Codex-managed approval for prompts that exactly match the delegated task contract.

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

For equal access in the current main worktree:

```text
啟動 chat-mode 的 direct-main-exclusive 模式，讓 Claude 直接在目前專案工作；明確允許 Bypass permissions，Claude 接手期間由它獨佔寫入權。
```

Codex should:

1. write a bounded request under `.chat-mode/exchange/`;
2. open the repository in Claude Desktop Code;
3. verify workspace trust and permission prompts against the task contract;
4. select the requested model and the permission mode allowed by the session contract through background UIA;
5. send a short request-file pointer;
6. read Claude's accessible response text until the unique completion marker appears;
7. evaluate the response and return the result to the user.

Successful UIA actions do not move the mouse, synthesize keystrokes, or bring Claude to the foreground.

## Modes

| Mode | Claude access | Writer ownership | Permission mode |
| --- | --- | --- | --- |
| `review` | Read-only main worktree | Codex | `Manual` |
| `isolated-implementer` | Dedicated sibling worktree | Claude owns the isolated tree | `Accept edits` or guarded prompts |
| `direct-main-exclusive` | Current main worktree | Claude temporarily owns main; Codex freezes | Explicit guarded `Bypass permissions` |

## Isolated implementation

When the user explicitly asks Claude to modify files, Codex creates a clean sibling worktree and dedicated `chat-mode/claude-*` branch. Claude may write only inside that worktree and the declared path scope. The main worktree stays unchanged while Claude works.

Codex records and reports the exact worktree, branch, base commit, scope, authorized actions, and commands. The user's implementation request delegates the ordinary project-local reads, in-scope writes, and validation needed for that task, so Codex enables `Accept edits` without asking for a second confirmation. When Claude still opens a prompt, Codex verifies its accessible text and may invoke `Allow once` for an exact contract match.

Authority expansion still returns to the user. Examples include out-of-scope paths, destructive operations, credentials, production or deployment access, and unexpected network activity. Claude remains prohibited from Git operations assigned to Codex. The Claude session returns to `Manual` when the run ends.

After Claude stops, Codex inspects the complete diff, checks scope, reproduces tests, and decides whether to apply or cherry-pick the result. Claude never commits, pushes, manages branches, or writes directly into the main worktree. Worktree cleanup remains a separate user-authorized action.

## Direct main handoff

When the user explicitly requests non-isolated equal project access, Codex requires a clean main worktree and records the branch, baseline commit, upstream state, scope, authorized commands, and any Git, network, credential, deployment, or external-path authority. Codex then freezes its own writes and hands the main worktree exclusively to Claude.

The guarded UIA action selects Bypass only after checking Claude's `Bypass all permissions?` dialog, destructive-command warning, Cancel control, and confirmation control. After Claude returns the marker, Codex restores `Manual` before inspecting every tracked and untracked path plus branch, HEAD, commits, and upstream state. Codex resumes writing only after this handback inspection.

Equal access means equivalent authority under the user's task, not concurrent edits. Bypass is not an OS sandbox and does not silently authorize paths or actions outside the recorded contract.

## Safety model

- Codex owns the loop; Claude never starts another agent loop.
- Claude is read-only by default; Codex is the sole main-worktree writer.
- Isolated implementation uses one writer per worktree and an explicit `write_scope`.
- Direct main implementation transfers exclusive writer ownership serially; Codex and Claude never write the same worktree concurrently.
- `Accept edits` is session convenience, not path-level sandboxing; out-of-scope changes are rejected during inspection.
- Guarded UIA approval requires one uniquely matching prompt control plus visible, enabled `Allow once` and `Deny` controls; ambiguity fails closed.
- `Bypass permissions` is not the normal local-workstation mode.
- Explicit direct-main handoff is the only normal path that enables Bypass, and it remains bounded by the task contract.
- Sessions have turn, time, and response-size bounds.
- `.chat-mode/STOP` aborts the session.
- Screenshots and OCR are not the source of truth for long responses.
- Unexpected mutation or ambiguous UI state stops the session.

The canonical protocol is [skills/chat-mode/references/protocol.md](skills/chat-mode/references/protocol.md). Windows adapter details are in [skills/chat-mode/references/windows-uia.md](skills/chat-mode/references/windows-uia.md), isolated implementation is defined in [skills/chat-mode/references/isolated-implementer.md](skills/chat-mode/references/isolated-implementer.md), and direct handoff is defined in [skills/chat-mode/references/direct-main-exclusive.md](skills/chat-mode/references/direct-main-exclusive.md).

## Evidence

The first end-to-end background UIA review is recorded in [docs/smoke-test-2026-08-08.md](docs/smoke-test-2026-08-08.md). The first real isolated Claude write is recorded in [docs/smoke-test-isolated-write-2026-08-08.md](docs/smoke-test-isolated-write-2026-08-08.md). The delegated-authority prompt approval test is recorded in [docs/smoke-test-delegated-authority-2026-08-08.md](docs/smoke-test-delegated-authority-2026-08-08.md). The first non-isolated main-worktree Bypass handoff is recorded in [docs/smoke-test-direct-main-bypass-2026-08-08.md](docs/smoke-test-direct-main-bypass-2026-08-08.md).

## Status

Experimental. The 2026-08-08 tests validated background read-only review, isolated Claude writes, guarded workspace trust, Codex-controlled `Allow once`, and an explicit non-isolated `Bypass permissions` handoff. The direct-main test completed without user permission prompts, restored `Manual`, and passed exact-content, write-scope, branch, HEAD, upstream, and diff-check inspection.
