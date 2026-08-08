# Claude Isolated Worktree Live Write Smoke Test

> Historical baseline: this test used human `Allow once`. Its session-consent policy was superseded later the same day by the delegated-authority test in `smoke-test-delegated-authority-2026-08-08.md`.

- Date: 2026-08-08
- Platform: Windows 11
- Result: passed
- Model: Claude Opus 5, High effort
- Permission mode: Manual with one human `Allow once`

## Contract

Codex created:

```text
main repo: D:\projects\chat-mod
worktree: D:\projects\.chat-mode-worktrees\chat-mod-live-write-20260808-121014
branch: chat-mode/claude-live-write-20260808-121014
base: 8e086368a06e92b51a466b1e9b0feafb02343bd6
write_scope: smoke/**
```

Claude was instructed to create exactly:

```text
smoke/claude-isolated-write.md
```

and to avoid shell commands, Git operations, commits, pushes, branch management, the main repository, and every other project path.

## Execution

1. Codex created the sibling worktree with `chat-mode-worktree.ps1 -Action Prepare`.
2. Codex wrote a bounded request under the isolated worktree's `.chat-mode/exchange/` directory.
3. A Claude Code deep link opened the isolated worktree with a prefilled request pointer.
4. The worktree inherited trust; no new trust dialog appeared.
5. Codex selected `Manual` and invoked `Send` through background Windows UI Automation.
6. Claude requested `Allow Claude to write claude-isolated-write.md?`.
7. The user selected `Allow once`.
8. Claude created the file, read it back, and returned `CHAT_MOD_LIVE_WRITE_20260808_121014_DONE`.

Claude reported that it used no shell or Git commands and touched no other project path.

## Independent verification

Codex verified:

```text
WorktreeStatus:  ?? smoke/claude-isolated-write.md
ChangedPaths:    smoke/claude-isolated-write.md
WriteScope:      smoke/**
ScopePassed:     True
ScopeViolations: <empty>
DiffCheckPassed: True
MainStatus:      <empty>
Head:            8e086368a06e92b51a466b1e9b0feafb02343bd6
```

The file contents and trailing newline matched the request exactly. The main worktree remained unchanged. No commit, push, integration, worktree removal, or branch removal occurred.

## Historical policy learning

`Manual` correctly preserved the human permission gate, but repeated `Allow once` prompts would be unreasonable for large document, code, or website changes.

The adopted policy is:

1. Show the user the exact isolated worktree, branch, base commit, `write_scope`, and requested commands once.
2. After explicit approval, set that Claude session to `Accept edits`.
3. Keep shell, Git, workspace trust, credential, network, deployment, and unexpected permission dialogs under human control.
4. Inspect tracked and untracked paths after the turn and reject any scope violation.
5. Restore `Manual` when the isolated session ends.

`Accept edits` is not an OS-level path sandbox. Safety comes from the disposable isolated worktree, unchanged main worktree, bounded contract, post-turn scope enforcement, and the rule that completion never implies integration approval.

## Remaining artifact

The worktree and branch are intentionally preserved because cleanup is destructive and requires separate user authorization.
