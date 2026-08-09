# Local Agent Instructions

## Runtime

- Use PowerShell 7 through `pwsh` for repository scripts.
- Keep PowerShell scripts ASCII-only when practical and use explicit UTF-8 for text files.
- Treat `skills/chat-mode/SKILL.md` as the source of truth.

## Required startup steps

Before changing this repository:

1. Read `docs/PROJECT_MEMORY.md`.
2. Read `docs/RUNBOOK.md`.
3. Read `docs/OPERATIONS_LOG.md` when recent implementation or smoke-test history may matter.
4. Read `skills/chat-mode/SKILL.md` and the relevant file under `skills/chat-mode/references/` for the mode being changed.
5. Treat `skills/chat-mode/SKILL.md` and its referenced files as protocol source of truth over summaries.

## Chat mode

- Use the filesystem mailbox plus Windows UI Automation workflow documented by the skill.
- Do not recreate or call the retired root `tools/` runner.
- Keep Claude contractually read-only unless the user explicitly authorizes implementation or host setup.
- For isolated implementation, require a clean main worktree and use the bundled worktree helper.
- For explicit non-isolated access, require a clean main worktree and use `chat-mode-direct-main.ps1`; Claude becomes the exclusive writer until inspected handback.
- Treat the user's task as delegated authority for necessary project-local reads, in-scope writes, and declared validation commands.
- Record the exact worktree, branch, base commit, `write_scope`, and authorized actions and commands; set Claude to `Accept edits` without a second confirmation when they remain inside the original request.
- Let Codex verify and approve exact contract-matching prompts through guarded UIA actions. Escalate scope expansion, destructive actions, credentials, production or deployment access, and unexpected network access.
- Default review sessions to `Bypass permissions` under the guarded `review-readonly` contract, regardless of dirty Git status; keep the mailbox authority read-only and reject any new repository mutation relative to the recorded baseline.
- Enable writable `Bypass permissions` only for explicit `direct-main-exclusive` authority and only through the guarded warning-confirmation action.
- After a successful `review-readonly` session with no new mutation relative to baseline, leave Claude in `Bypass permissions` so later reviews can reuse it without another mode transition.
- Restore Claude to `Manual` after implementation or host-setup handback, on review failure or ambiguity, or when the user explicitly requests `Manual`.
- Never let Codex and Claude edit tracked files in the same worktree concurrently.
- Enforce the declared `write_scope` before integrating Claude's changes.
- Approve workspace trust only when the accessible path exactly matches the recorded contract.
- Do not use screen coordinates when UIA exposes a named control.
- Stop on ambiguous controls, unexpected mutation, timeout, malformed completion markers, or `.chat-mode/STOP`.
- Do not remove worktrees or branches without separate user authorization after verified integration.

## Repository changes

- Update the skill, bundled references, and relevant helpers together when the protocol changes.
- Validate `skills/chat-mode` with the skill-creator validator before committing.
- Test UIA changes with read-only actions against Claude Desktop when available.
- Run `pwsh -NoProfile -File .\tests\worktree-smoke.ps1` after changing isolated-worktree behavior.
- Run `pwsh -NoProfile -File .\tests\direct-main-smoke.ps1` after changing direct-main behavior.
