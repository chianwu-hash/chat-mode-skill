# Local Agent Instructions

## Runtime

- Use PowerShell 7 through `pwsh` for repository scripts.
- Keep PowerShell scripts ASCII-only when practical and use explicit UTF-8 for text files.
- Treat `skills/chat-mode/SKILL.md` as the source of truth.

## Chat mode

- Use the filesystem mailbox plus Windows UI Automation workflow documented by the skill.
- Do not recreate or call the retired root `tools/` runner.
- Keep Claude read-only unless the user explicitly authorizes isolated-implementer mode.
- For isolated implementation, require a clean main worktree and use the bundled worktree helper.
- Show the exact worktree, branch, base commit, `write_scope`, and authorized commands; after one explicit session approval, set Claude to `Accept edits`.
- Keep shell, Git, trust, network, credential, deployment, and unexpected permission dialogs under human control.
- Restore Claude to `Manual` after the isolated session ends.
- Never let Codex and Claude edit tracked files in the same worktree concurrently.
- Enforce the declared `write_scope` before integrating Claude's changes.
- Never auto-approve workspace trust or permission dialogs.
- Do not use screen coordinates when UIA exposes a named control.
- Stop on ambiguous controls, unexpected mutation, timeout, malformed completion markers, or `.chat-mode/STOP`.
- Do not remove worktrees or branches without separate user authorization after verified integration.

## Repository changes

- Update the skill, bundled references, and relevant helpers together when the protocol changes.
- Validate `skills/chat-mode` with the skill-creator validator before committing.
- Test UIA changes with read-only actions against Claude Desktop when available.
- Run `pwsh -NoProfile -File .\tests\worktree-smoke.ps1` after changing isolated-worktree behavior.
