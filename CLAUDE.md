# Claude Project Instructions

## PowerShell Runtime

- Use PowerShell 7.6.1 or newer for this repository. Invoke it as `pwsh`.
- Prefer commands shaped like `pwsh -NoProfile -File .\path\to\script.ps1`.
- Do not use Windows PowerShell 5.1 (`powershell.exe`) for project scripts except when explicitly checking legacy compatibility.

## Chat-Mode Trigger

When the user asks to start `chat-mode`, `暢聊模式`, or a bounded multi-round Codex/Claude collaboration, use the real CLI orchestration runner when it exists.

Do not manually roleplay Codex rounds. Do not simulate worker output.
Do not treat `tests\smoke.ps1` or `tests\run-smoke.ps1` as the chat-mode session. They are test helpers only.

Default command shape:

```powershell
pwsh -NoProfile -File .\tools\chat-mode-run.ps1 `
  -NewSession `
  -Topic "<user task>" `
  -TaskSummary "<ascii task summary>" `
  -MaxTurns 4 `
  -FirstMover claude
```

If `.chat-mode/config.json` is missing or does not contain a verified `codex_exe`, stop and tell the user to run first setup from Codex:

```powershell
pwsh -NoProfile -File .\tools\chat-mode-setup.ps1
```

If `tools\chat-mode-run.ps1` fails, report the error and stop. Do not continue by pretending to be Codex.

After the runner completes, inspect the session file and state file it reports. Only commit and push when the user requested it and the verification results support doing so.
