# Local Agent Instructions

## PowerShell Runtime

- Use PowerShell 7.6.1 or newer for this repository. Invoke it as `pwsh`.
- Do not use Windows PowerShell 5.1 (`powershell.exe`) for project scripts except when explicitly checking legacy compatibility.
- When a `.ps1` script only works in Windows PowerShell 5.1, convert it for PowerShell 7.6.1 before running it for normal project work.
- Prefer commands shaped like `pwsh -NoProfile -File .\path\to\script.ps1`.
- Keep PowerShell scripts ASCII-only when practical and use explicit UTF-8 file encoding for text I/O.

## Chat-Mode Trigger

- When the user asks for `chat-mode`, `暢聊模式`, or bounded Codex/Claude collaboration, prefer `pwsh -NoProfile -File .\tools\chat-mode-run.ps1` when it exists.
- Do not manually roleplay the other agent's rounds when the runner is available.
- If `.chat-mode/config.json` is missing, run `pwsh -NoProfile -File .\tools\chat-mode-setup.ps1` from Codex first.
- If the runner fails, report the failure and stop instead of simulating worker output.
