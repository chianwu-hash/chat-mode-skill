# Runbook

Last reviewed: 2026-08-17

Use `skills/chat-mode/SKILL.md` and the selected reference as protocol source of truth.

## Before changes

1. Read `docs/PROJECT_MEMORY.md` and recent `docs/OPERATIONS_LOG.md` entries.
2. Record `git status --short --branch`, HEAD, and upstream.
3. Read the skill, `references/protocol.md`, and the relevant mode reference.
4. For CLI work, also read `references/claude-cli.md`.

## Change routing

| Area | Required validation |
|---|---|
| CLI transport/session | parser, CLI supervisor smoke, real OAuth turn when feasible |
| Isolated implementation | CLI supervisor smoke and worktree smoke |
| Host setup/Desktop | guarded live Desktop test when feasible |
| Direct main/Desktop | direct-main smoke |
| Installer/metadata | test install and skill validator |

## Validation

```powershell
pwsh -NoProfile -Command "& { [void][scriptblock]::Create((Get-Content -LiteralPath 'skills\chat-mode\scripts\claude-cli-supervisor.ps1' -Raw)); 'cli parse ok' }"
pwsh -NoProfile -File .\tests\claude-cli-supervisor-smoke.ps1
pwsh -NoProfile -File .\tests\worktree-smoke.ps1
pwsh -NoProfile -File .\tests\direct-main-smoke.ps1
git diff --check
```

Run the skill-creator validator against `skills/chat-mode`. Live CLI validation requires Claude Code 2.1.233+, Pro/Max OAuth, and no Anthropic API-key environment variables. Live Desktop claims require an actual signed-in Desktop session.

## Handoff checklist

1. Inspect status and diff; keep `.chat-mode/`, worktrees, transcripts, requests, and secrets untracked/unstaged.
2. Confirm skill, references, helpers, tests, README, and memory agree.
3. Record major behavior and evidence in `docs/OPERATIONS_LOG.md`.
4. Do not commit unless the user requests a commit.

Mode checks: review records a baseline and rejects mutation; isolated requires clean main, safe scope, a dedicated worktree, and inspected handback; host setup requires exact commands/paths/hosts and user-handled secrets; direct main requires explicit clean, serial ownership and complete inspection.
