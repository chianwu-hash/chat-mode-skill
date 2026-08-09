# Runbook

Last reviewed: 2026-08-08

Use this runbook for repository maintenance. Use `skills/chat-mode/SKILL.md` and the relevant reference file as the protocol source of truth before changing behavior.

## Required first checks

Before any repository change:

1. Read `docs/PROJECT_MEMORY.md`.
2. Run `git status --short --branch`.
3. Identify whether the task changes docs only, protocol, UIA behavior, worktree behavior, direct-main behavior, installer behavior, tests, or smoke-test evidence.
4. Read `skills/chat-mode/SKILL.md`.
5. Read the relevant reference:
   - `skills/chat-mode/references/protocol.md`
   - `skills/chat-mode/references/windows-uia.md`
   - `skills/chat-mode/references/review-bypass-readonly.md`
   - `skills/chat-mode/references/host-setup-delegated.md`
   - `skills/chat-mode/references/isolated-implementer.md`
   - `skills/chat-mode/references/direct-main-exclusive.md`

## Change routing

| Change area | Required files to consider | Validation |
|---|---|---|
| General protocol | `skills/chat-mode/SKILL.md`, `references/protocol.md`, `README.md`, `docs/PROJECT_MEMORY.md` | PowerShell parse, relevant smoke tests |
| Review Bypass | `references/review-bypass-readonly.md`, `scripts/claude-desktop-uia.ps1`, review smoke docs | UIA read-only review when available |
| Host setup | `references/host-setup-delegated.md`, `scripts/claude-desktop-uia.ps1`, README | Verify no project writes or secret paths |
| Isolated implementation | `references/isolated-implementer.md`, `scripts/chat-mode-worktree.ps1`, tests/worktree smoke | `tests/worktree-smoke.ps1` |
| Direct main | `references/direct-main-exclusive.md`, `scripts/chat-mode-direct-main.ps1`, tests/direct smoke | `tests/direct-main-smoke.ps1` |
| Installer | `install.ps1`, `install.sh`, `skills/chat-mode/**` | Install into a test / local skill path when appropriate |
| Docs only | README, docs, memory docs | `git diff --check` and link consistency |

## Validation commands

Run what matches the change. For docs-only memory onboarding, `git diff --check` is enough.

PowerShell parse checks:

```powershell
pwsh -NoProfile -Command "& { [void][scriptblock]::Create((Get-Content -LiteralPath 'skills\chat-mode\scripts\claude-desktop-uia.ps1' -Raw)); 'uia parse ok' }"
pwsh -NoProfile -Command "& { [void][scriptblock]::Create((Get-Content -LiteralPath 'skills\chat-mode\scripts\chat-mode-worktree.ps1' -Raw)); 'worktree parse ok' }"
pwsh -NoProfile -Command "& { [void][scriptblock]::Create((Get-Content -LiteralPath 'skills\chat-mode\scripts\chat-mode-direct-main.ps1' -Raw)); 'direct parse ok' }"
```

Smoke tests:

```powershell
pwsh -NoProfile -File .\tests\worktree-smoke.ps1
pwsh -NoProfile -File .\tests\direct-main-smoke.ps1
```

Read-only UIA / Claude Desktop smoke tests require a live Windows desktop and signed-in Claude Desktop. Do not fake or claim them without running them.

## Commit checklist

Before commit:

1. `git status --short --branch`
2. `git diff --check`
3. Verify `.chat-mode/` and `.chat-mode-worktrees/` are not staged.
4. Verify no request files, transcripts, secrets, local machine paths beyond documented examples, or temporary smoke worktrees are staged.
5. Confirm mode docs, scripts, tests, and README are consistent.
6. Record major protocol or smoke-test changes in `docs/OPERATIONS_LOG.md`.

## Mode-specific safety checks

### Review

- Record branch, HEAD, upstream state when available, and dirty status before guarded Bypass.
- Keep contract read-only.
- Leave Bypass enabled after a successful review with no new mutation relative to baseline.
- Restore Manual on failure, ambiguity, new mutation relative to baseline, or explicit user request.

### Host setup

- Use only after explicit user request.
- Record exact commands, non-secret config paths, allowed network hosts, credential boundary, and restart authority.
- Restore Manual at the end.
- Verify project repo remains clean.

### Isolated implementation

- Prepare sibling worktree with helper.
- Require nonempty safe write scope.
- Open Claude in the isolated worktree, not main.
- Inspect before integration.
- Never auto-delete the worktree or branch.

### Direct main exclusive

- Use only after explicit user request.
- Freeze Codex writes and Git operations in the selected main worktree.
- Restore Manual and inspect before Codex resumes writing.
- Reject unauthorized Git, network, credential, deployment, destructive, or external-path actions.

## Memory update rule

Update `docs/PROJECT_MEMORY.md` and `docs/OPERATIONS_LOG.md` when:

- protocol authority model changes;
- default permission lifecycle changes;
- helper fail-safe behavior changes;
- a smoke test validates or invalidates a workflow;
- installation or startup requirements change.

For cross-tool durable recall, update Nowledge Memory after repo docs are committed.
