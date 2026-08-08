# Claude Delegated-Authority Live Smoke Test

- Date: 2026-08-08
- Platform: Windows 11
- Result: passed
- Model: Claude Opus 5, High effort
- Permission mode: Manual, intentionally selected to produce a real write prompt
- User interaction after task delegation: none
- Bypass permissions: not used

## Contract

Codex created a clean temporary Git repository and an isolated sibling worktree:

```text
main repo: D:\projects\chat-mode-delegated-smoke-20260808-134102
worktree: D:\projects\.chat-mode-worktrees\delegated-smoke-20260808-134102
branch: chat-mode/claude-delegated-write-20260808-134102
base: e6a58f0a1ea129978d2e755a1e82d3c5285b006c
write_scope: smoke/**
authorized actions: read request, write scope
authorized commands: none
```

Turn 1 instructed Claude to create exactly `smoke/delegated-allow-once.md`, run no commands, touch no other path, and return `CHAT_MOD_DELEGATED_20260808_134102_DONE`.

## Guarded UIA execution

1. Claude displayed `Trust this workspace?` for the exact isolated worktree.
2. `ApproveWorkspaceTrust` matched the accessible absolute path, required one `Trust Workspace` and one `Cancel`, and invoked trust in the background.
3. Codex selected `Manual` to force a permission prompt and invoked `Send` through UIA.
4. Claude exposed the requested write through accessible controls:

```text
Permission requested: write. D:\projects\.chat-mode-worktrees\delegated-smoke-20260808-134102\smoke\delegated-allow-once.md
Allow Claude to write delegated-allow-once.md?
Deny 1
Allow once 3
```

5. Codex passed the escaped exact question to `ApprovePrompt`.
6. The helper verified the prompt text, refused trust-dialog crossover, required one enabled `Allow once` and one `Deny`, and invoked `Allow once 3`.
7. Claude wrote the file and returned the exact completion marker.

No mouse movement, coordinate click, foreground typing, user click, shell command, Git command, or bypass mode was used.

## Tightened-matcher retest

Code review then replaced whole-window text matching with a stricter rule: exactly one currently named UIA control must match the contract-specific expression, preventing stale conversation text from satisfying the check.

Turn 2 requested one additional file, `smoke/delegated-unique-control.md`, under the unchanged scope and command policy. Claude Desktop presented workspace trust again; the final exact-path trust action approved it. After navigating through named `Code` and `New session in delegated-smoke-20260808-134102` controls, Claude exposed:

```text
Allow Claude to write delegated-unique-control.md?
Deny 1
Allow once 3
```

The unique-control implementation matched the question control, verified visible and enabled Allow/Deny controls, invoked `Allow once 3`, and received `CHAT_MOD_DELEGATED_20260808_134102_RETEST_DONE`.

The final guard then required the matched prompt or path control itself to be visible and enabled. Turn 3 created `smoke/delegated-final-guard.md`; the final helper approved exact-path workspace trust and the uniquely matched write question, invoked `Allow once 3`, received `CHAT_MOD_DELEGATED_20260808_134102_FINAL_DONE`, and returned to `Manual`. No approval logic changed after this turn.

## Fail-closed checks

Before the live test, `ApprovePrompt -TextRegex '.*'` failed with:

```text
Approval actions require a contract-specific -TextRegex.
```

The approval action also fails on missing or duplicate controls, missing `Deny`, disabled `Allow once`, prompt-text mismatch, or any detected workspace trust dialog. Workspace trust has a separate exact-path action.

## Independent verification

```text
WorktreeStatus:  ?? smoke/delegated-allow-once.md
                 ?? smoke/delegated-final-guard.md
                 ?? smoke/delegated-unique-control.md
ChangedPaths:    smoke/delegated-allow-once.md
                 smoke/delegated-final-guard.md
                 smoke/delegated-unique-control.md
WriteScope:      smoke/**
ScopePassed:     True
ScopeViolations: <empty>
DiffCheckPassed: True
MainStatus:      <empty>
Head:            e6a58f0a1ea129978d2e755a1e82d3c5285b006c
Commits:         <empty>
```

All three files' UTF-8 contents and trailing LF matched exactly. The temporary main worktree remained clean.

## Conclusion

The user task can serve as the initial delegation. Codex can manage exact contract-matching Claude permissions without returning routine prompts to the user. `Accept edits` remains the efficient default for ordinary isolated implementation; guarded `ApprovePrompt` handles prompts that still appear or sessions intentionally kept in `Manual`.

Authority expansion still requires user involvement. `Bypass permissions` is unnecessary for the normal local-workstation workflow and is not an OS sandbox.

## Remaining artifact

The temporary repository, isolated worktree, and branch are intentionally preserved. No integration, commit in the isolated branch, worktree removal, or branch removal occurred.
