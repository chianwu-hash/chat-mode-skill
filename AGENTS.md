# Local Agent Instructions

## Runtime

- Use PowerShell 7 through `pwsh` for repository scripts.
- Keep PowerShell scripts ASCII-only when practical and use explicit UTF-8 for text files.
- Treat `skills/chat-mode/SKILL.md` as the source of truth.

## Chat mode

- Use the filesystem mailbox plus Windows UI Automation workflow documented by the skill.
- Do not recreate or call the retired root `tools/` runner.
- Keep Claude read-only unless the user explicitly authorizes a broader mode.
- Never auto-approve workspace trust or permission dialogs.
- Do not use screen coordinates when UIA exposes a named control.
- Stop on ambiguous controls, unexpected mutation, timeout, malformed completion markers, or `.chat-mode/STOP`.

## Repository changes

- Update the skill, its bundled references, and its UIA helper together when the protocol changes.
- Validate `skills/chat-mode` with the skill-creator validator before committing.
- Test UIA changes with read-only actions against Claude Desktop when available.
