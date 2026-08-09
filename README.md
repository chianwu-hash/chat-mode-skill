# chat-mode-skill

`chat-mode-skill` lets Codex coordinate bounded review, discussion, and isolated implementation with Claude Desktop Code on Windows without occupying the foreground desktop.

The current design uses:

- filesystem request files and transcripts for durable context;
- Windows UI Automation (UIA) to operate Claude Desktop in the background;
- accessible document text instead of screenshots or OCR for responses;
- sibling Git worktrees when Claude is explicitly asked to implement changes;
- exclusive main-worktree handoff when the user explicitly requests equal non-isolated project access;
- guarded Bypass for prompt-free, contractually read-only review, even when the repository already has dirty files;
- guarded Bypass for exact, user-authorized host setup without project writes or credential disclosure;
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

Primary UIA actions do not move the mouse or bring Claude to the foreground. A Claude build whose permission selector ignores `ExpandCollapse` may require one guarded Space key after exact control, process, focus, window-handle, and existing-foreground checks; it never uses coordinates or activates another window.

## Modes

| Mode | Claude access | Writer ownership | Permission mode |
| --- | --- | --- | --- |
| `review` | Read-only main worktree | Codex | Guarded `Bypass permissions` by default |
| `host-setup-delegated` | Exact host setup commands and non-secret config only | Codex owns project files; Claude owns declared setup steps | Guarded `Bypass permissions` |
| `isolated-implementer` | Dedicated sibling worktree | Claude owns the isolated tree | `Accept edits` or guarded prompts |
| `direct-main-exclusive` | Current main worktree | Claude temporarily owns main; Codex freezes | Explicit guarded `Bypass permissions` |

## Isolated implementation

When the user explicitly asks Claude to modify files, Codex creates a clean sibling worktree and dedicated `chat-mode/claude-*` branch. Claude may write only inside that worktree and the declared path scope. The main worktree stays unchanged while Claude works.

Codex records and reports the exact worktree, branch, base commit, scope, authorized actions, and commands. The user's implementation request delegates the ordinary project-local reads, in-scope writes, and validation needed for that task, so Codex enables `Accept edits` without asking for a second confirmation. When Claude still opens a prompt, Codex verifies its accessible text and may invoke `Allow once` for an exact contract match.

Authority expansion still returns to the user. Examples include out-of-scope paths, destructive operations, credentials, production or deployment access, and unexpected network activity. Claude remains prohibited from Git operations assigned to Codex. The Claude session returns to `Manual` when the run ends.

After Claude stops, Codex inspects the complete diff, checks scope, reproduces tests, and decides whether to apply or cherry-pick the result. Claude never commits, pushes, manages branches, or writes directly into the main worktree. Worktree cleanup remains a separate user-authorized action.

## Read-only review

For review and discussion, chat-mode defaults Claude Desktop to guarded Bypass under a `review-readonly` contract. This removes routine prompts while Claude reads, lists, searches, and inspects the project. Codex remains the sole writer, and the request forbids edits, Git mutation, network access, credentials, deployment, destructive commands, and external paths.

Review Bypass is the default even when the repository already has dirty files. Codex records branch, HEAD, upstream state when available, and the current status before sending. After a successful review with no new mutation relative to that baseline, chat-mode leaves Claude in Bypass so the next review can reuse the already-enabled state. It restores `Manual` on failure or ambiguity and rejects the turn if branch, HEAD, commits, upstream state, or project status changes beyond the recorded baseline.

## Host setup delegation

When the user explicitly asks Claude to install a plugin or configure a local tool, chat-mode may use `host-setup-delegated`. This keeps project files read-only while allowing exact declared setup commands, declared non-secret config writes, and declared network hosts. It is useful for tasks such as installing a Claude Code plugin after Codex has recorded the setup scope and smoke tests. This is the writable setup path; ordinary discussion and review remain read-only even in Bypass.

Secrets stay outside chat-mode. Claude must not ask for, print, store, or write Access Anywhere URLs, API keys, passwords, tokens, private keys, or one-time codes. If secret entry is required, the user handles it directly in the local UI or command prompt, and Claude resumes only for non-secret verification. Codex restores `Manual`, verifies the repository stayed clean, and checks that Claude did not exceed the setup contract.

## Direct main handoff

When the user explicitly requests non-isolated equal project access, Codex requires a clean main worktree and records the branch, baseline commit, upstream state, scope, authorized commands, and any Git, network, credential, deployment, or external-path authority. Codex then freezes its own writes and hands the main worktree exclusively to Claude.

The guarded UIA action selects Bypass only after checking Claude's `Bypass all permissions?` dialog, destructive-command warning, Cancel control, and confirmation control. After Claude returns the marker, Codex restores `Manual` before inspecting every tracked and untracked path plus branch, HEAD, commits, and upstream state. Codex resumes writing only after this handback inspection.

Equal access means equivalent authority under the user's task, not concurrent edits. Bypass is not an OS sandbox and does not silently authorize paths or actions outside the recorded contract.

## Safety model

- Codex owns the loop; Claude never starts another agent loop.
- Claude is read-only by default; Codex is the sole main-worktree writer.
- Host setup Bypass permits only exact non-secret setup authority and never project edits or credentials.
- Isolated implementation uses one writer per worktree and an explicit `write_scope`.
- Direct main implementation transfers exclusive writer ownership serially; Codex and Claude never write the same worktree concurrently.
- `Accept edits` is session convenience, not path-level sandboxing; out-of-scope changes are rejected during inspection.
- Guarded UIA approval requires one uniquely matching prompt control plus visible, enabled `Allow once` and `Deny` controls; ambiguity fails closed.
- `Bypass permissions` is the default Claude Desktop UI mode for read-only review, but it does not expand the read-only task contract.
- Writable Bypass still requires an explicit direct-main handoff and remains bounded by the task contract.
- Sessions have turn, time, and response-size bounds.
- `.chat-mode/STOP` aborts the session.
- Screenshots and OCR are not the source of truth for long responses.
- Unexpected mutation or ambiguous UI state stops the session.

The canonical protocol is [skills/chat-mode/references/protocol.md](skills/chat-mode/references/protocol.md). Windows adapter details are in [skills/chat-mode/references/windows-uia.md](skills/chat-mode/references/windows-uia.md), isolated implementation is defined in [skills/chat-mode/references/isolated-implementer.md](skills/chat-mode/references/isolated-implementer.md), and direct handoff is defined in [skills/chat-mode/references/direct-main-exclusive.md](skills/chat-mode/references/direct-main-exclusive.md).

## Evidence

The first end-to-end background UIA review is recorded in [docs/smoke-test-2026-08-08.md](docs/smoke-test-2026-08-08.md). The first real isolated Claude write is recorded in [docs/smoke-test-isolated-write-2026-08-08.md](docs/smoke-test-isolated-write-2026-08-08.md). The delegated-authority prompt approval test is recorded in [docs/smoke-test-delegated-authority-2026-08-08.md](docs/smoke-test-delegated-authority-2026-08-08.md). The first non-isolated main-worktree Bypass handoff is recorded in [docs/smoke-test-direct-main-bypass-2026-08-08.md](docs/smoke-test-direct-main-bypass-2026-08-08.md). The default read-only Bypass review and current Claude permission-selector fallback are recorded in [docs/smoke-test-review-bypass-readonly-2026-08-08.md](docs/smoke-test-review-bypass-readonly-2026-08-08.md). Persistent reuse of the successful review Bypass state is recorded in [docs/smoke-test-review-bypass-persistence-2026-08-08.md](docs/smoke-test-review-bypass-persistence-2026-08-08.md).

## Status

Experimental. The 2026-08-08 tests validated prompt-free read-only review, isolated Claude writes, guarded workspace trust, Codex-controlled `Allow once`, and an explicit non-isolated `Bypass permissions` handoff. The original read-only Bypass test completed without permission prompts or commands, restored `Manual`, and left status, branch, HEAD, and commits unchanged; the persistence regression then verified that a successful review can leave Bypass enabled and reuse it idempotently. The direct-main test passed exact-content, write-scope, branch, HEAD, upstream, and diff-check inspection.
