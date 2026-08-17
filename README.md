# chat-mode-skill

`chat-mode-skill` lets Codex coordinate bounded, auditable work with Claude Code through filesystem authority envelopes.

The default transport is now a supervised `claude -p` process for read-only review and isolated implementation. Claude Desktop remains for host setup, explicit direct-main ownership, visible secret entry, and bounded fallback.

## Why the CLI path

- It does not depend on Claude Desktop controls or a foreground Send action.
- It uses the signed-in Claude Pro or Max subscription, not an Anthropic API key.
- `--setting-sources user` excludes project/local settings and repeated project `CLAUDE.md` loading.
- `--resume` preserves one Claude session across turns.
- Resume requires the same SHA-256 fingerprint of stable authority fields.
- Mailbox requests, responses, run records, transcripts, STOP handling, Git baselines, and handback inspection remain intact.

Do not use `--bare`: current Claude Code routes that mode away from subscription OAuth. Do not call raw `claude -p` for chat-mode turns; use the bundled supervisor.

## Requirements

- PowerShell 7 (`pwsh`)
- Claude Code 2.1.233 or newer
- `claude auth status` reporting `authMethod: claude.ai`
- no `ANTHROPIC_API_KEY` or `ANTHROPIC_AUTH_TOKEN` in the worker environment
- Git for repository-backed sessions
- Claude Desktop on Windows only for Desktop-specific modes

Install on Windows:

```powershell
pwsh -NoProfile -File .\install.ps1
```

## Mode routing

| Mode | Default transport | Write boundary |
|---|---|---|
| `review` | Claude CLI | Read-only main worktree |
| `isolated-implementer` | Claude CLI | Dedicated sibling worktree and declared scope |
| `host-setup-delegated` | Claude Desktop | Exact host commands and non-secret config only |
| `direct-main-exclusive` | Claude Desktop | Explicit, serial ownership of a clean main worktree |

CLI review receives only `Read`, `Glob`, and `Grep`. Isolated implementation adds `Edit` and `Write`; exact `Bash(...)` allowances exist only for declared validation commands. These rules are not an OS sandbox, so every turn is checked against its Git baseline and declared write scope.

> **Review confidentiality boundary:** `Read`, `Glob`, and `Grep` prevent project mutation but are not OS-level path confinement. A Claude CLI review may read any file accessible to the current Windows account, not only the selected repository. Do not start review from an account that can access secrets or unrelated sensitive files unless that exposure is acceptable.

## CLI workflow

Create a version-2 request at `<worktree>/.chat-mode/exchange/<session-id>/turn-0001.request.md`, then run:

```powershell
pwsh -NoProfile -File .\skills\chat-mode\scripts\claude-cli-supervisor.ps1 `
  -Action Invoke -RequestPath <request-file> -WorkingTree <worktree>
```

For a later turn with memory, create the next request and add `-Resume`. State lives in ignored `.chat-mode/sessions/<session-id>/claude-cli-state.json`. A changed path, branch, base commit, scope, command, or authority field cannot silently inherit the old context.

## Safety and handback

- Codex owns orchestration and Git integration; Claude must not start another agent loop.
- One writer owns a worktree at a time.
- Review tool restrictions prevent writes but do not confine reads to the repository.
- `.chat-mode/STOP` terminates the worker process tree.
- A marker proves turn completion, not approval to integrate.
- Secrets never belong in requests, transcripts, repository docs, or memory.
- Isolated worktrees and branches are not removed without separate authorization.

Canonical details are in [the skill](skills/chat-mode/SKILL.md), [the protocol](skills/chat-mode/references/protocol.md), and [the CLI supervisor reference](skills/chat-mode/references/claude-cli.md).

## Validation

```powershell
pwsh -NoProfile -File .\tests\claude-cli-supervisor-smoke.ps1
pwsh -NoProfile -File .\tests\worktree-smoke.ps1
pwsh -NoProfile -File .\tests\direct-main-smoke.ps1
```

The 2026-08-17 migration was validated with a real subscription-authenticated first turn and resumed turn. Earlier Desktop UIA evidence remains under `docs/smoke-test-*.md` for retained fallback modes.
