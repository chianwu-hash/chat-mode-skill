# Direct Main Bypass Smoke Test - 2026-08-08

## Result

Passed on Windows with Claude Desktop Code, Opus 5, and High effort. Claude wrote directly in the current main worktree under an explicit `direct-main-exclusive` contract. No isolated worktree was used, no `Allow once` prompt appeared, and Claude was restored to `Manual` before Codex inspected the result.

## Contract

```text
repo/worktree: D:\projects\chat-mode-direct-live-20260808-142047
session:       direct-main-20260808-142047
branch:        main
base commit:   1a6621fd54e9551dd789506ae15a6d6a5975d30f
write_scope:   smoke/**
git:           none
network:       none
credentials:   none
deployment:    none
external paths:none
```

The only authorized command was:

```powershell
pwsh -NoProfile -Command "Get-Content -LiteralPath '.\smoke\direct-main-bypass.md' -Raw -Encoding utf8"
```

The expected completion marker was `CHAT_MOD_DIRECT_MAIN_20260808_142047_DONE`.

## Procedure

1. Codex prepared a clean temporary main worktree with `chat-mode-direct-main.ps1 -Action Prepare` and recorded the branch, base commit, upstream state, scope, and exclusive writer.
2. Claude displayed `Trust this workspace?` for the exact contracted path. Codex approved the uniquely matching accessible control.
3. The first Bypass attempt failed closed because the permission radio controls had not populated yet. The UIA helper was changed to wait for one unique Bypass control before selecting it.
4. Codex ran guarded `EnableBypass -BypassContract direct-main-exclusive`. The helper verified `Bypass all permissions?`, Claude's destructive-command warning, one Cancel control, and one confirmation control before enabling Bypass.
5. Claude read the mailbox request, created the requested file, ran the exact authorized validation command with exit code 0, returned its operation log, and emitted the completion marker. No permission prompt appeared.
6. A first marker wait exposed that Claude Desktop also rendered the marker inside the sent request. `WaitText` was changed to support `-MinimumTextMatches`; callers now require two matches when the prompt itself contains the marker.
7. Codex disabled Bypass, verified `Manual`, and inspected the handback before resuming writes.
8. Codex closed the direct session, archiving its metadata and inspection without changing or deleting the project result.

## Independent inspection

```text
BranchChanged:   False
HeadChanged:     False
UpstreamChanged: False
ChangedPaths:    smoke/direct-main-bypass.md
WriteScope:      smoke/**
ScopePassed:     True
DiffCheckPassed: True
Commits:         none
```

The created file was exact UTF-8 without BOM and with a trailing LF:

```markdown
# Direct Main Exclusive Smoke Test

status: passed
mode: direct-main-exclusive
permission: bypass
owner: claude-desktop
```

## Conclusion

Codex can hand the current project directly to Claude with task-equivalent authority and no repeated user approvals. Equality is implemented as serial exclusive ownership: Claude owns writes during its turn, Codex freezes its own writes and Git operations, then Codex restores `Manual` and verifies the complete handback. Bypass removes Claude's application prompts but is not an OS sandbox and does not expand the recorded contract.

The temporary repository and untracked smoke artifact remain preserved for inspection. No commit, push, deployment, branch change, history rewrite, or cleanup occurred.
