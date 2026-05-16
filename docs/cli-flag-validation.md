# CLI Flag Validation

This document records local CLI checks for the proposed chat-mode orchestration flow. Re-run these checks before implementing or changing `tools/chat-mode-run.ps1`.

## Environment

- Date: 2026-05-16
- OS shell: PowerShell via `pwsh`
- Repo: `c:\Users\user\projects\it-class-tcwu\chat-mode-skill`

## Claude Code

Validation commands:

```powershell
claude --version
claude --help
```

Observed version:

```text
2.1.71 (Claude Code)
```

Relevant supported flags observed in `claude --help`:

- `-p`, `--print`
- `--tools <tools...>`
- `--allowedTools`, `--allowed-tools <tools...>`
- `--permission-mode <mode>`
- `--output-format <format>`
- `--session-id <uuid>`
- `--resume [value]`
- `--continue`

Observed permission mode choices:

```text
acceptEdits, bypassPermissions, default, dontAsk, plan, auto
```

Validated read-only review shape:

```powershell
claude -p `
  --tools "Read,Glob,Grep" `
  --allowedTools "Read,Glob,Grep" `
  --permission-mode dontAsk `
  --output-format text `
  "Read docs/claude-cli-orchestration.md and summarize the proposed workflow. Do not edit files."
```

This command returned non-empty output in this environment.

## Codex CLI

Validation commands:

```powershell
codex --version
codex exec --help
```

Observed version:

```text
codex-cli 0.131.0-alpha.9
```

Relevant supported flags observed in `codex --help` and `codex exec --help`:

- `-C`, `--cd <DIR>`
- `--sandbox <read-only|workspace-write|danger-full-access>`
- `--ask-for-approval <policy>` as a top-level option before `exec`
- `--output-last-message <FILE>`
- `--json`
- `--ephemeral`

Validated read-only review shape:

```powershell
codex --ask-for-approval never exec `
  -C "." `
  --sandbox read-only `
  "Read docs/claude-cli-orchestration.md and summarize the proposed workflow. Do not edit files."
```

On Windows, Codex sandbox modes may block file/shell tools with errors such as `CreateProcessAsUserW failed: 5` or sandbox setup refresh failures. The runner defaults Codex to `--dangerously-bypass-approvals-and-sandbox` on Windows for operability, then enforces review-mode behavior by failing if `git diff --stat` or `git status --short` changes.

## Path Caveat

Codex may be available to Codex-hosted tools but not visible in Claude Code's shell `PATH`. In one Claude-orchestrated test, `codex exec` returned command-not-found while this Codex environment resolved `codex` to:

```text
c:\Users\user\.vscode\extensions\openai.chatgpt-26.513.21555-win32-x64\bin\windows-x86_64\codex.exe
```

Future runner scripts should accept explicit executable path parameters such as `-ClaudeExe` and `-CodexExe`, and should verify agent identity with `claude --version` or `codex exec --help` rather than relying on executable name alone.

## First-Run Setup Requirement

For Claude-orchestrated sessions, the first setup should be run from Codex. Codex should discover and verify its own executable path, then write a host-local `.chat-mode/config.json` with:

```powershell
pwsh -NoProfile -File .\tools\chat-mode-setup.ps1
```

```json
{
  "codex_exe": "<verified-codex-exe>",
  "claude_exe": "claude"
}
```

If Claude starts first and no verified `codex_exe` is configured, it should stop and ask the user to run first setup from Codex.
