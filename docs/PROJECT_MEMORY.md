# Project Memory

Last reviewed: 2026-08-08

This file records durable project knowledge for future Codex / Claude sessions. It is not the full protocol. The source of truth remains:

- `skills/chat-mode/SKILL.md`
- `skills/chat-mode/references/protocol.md`
- `skills/chat-mode/references/windows-uia.md`
- mode-specific reference files under `skills/chat-mode/references/`

## Project identity

- Project name: `chat-mode-skill`
- Local repo path: `D:\projects\chat-mod`
- GitHub repo: `chianwu-hash/chat-mode-skill`
- Main branch: `main`
- Current known source commit during onboarding: `0dc6841` (`Keep Claude Bypass after successful reviews`)
- Purpose: let Codex coordinate bounded collaboration with Claude Desktop Code on Windows through filesystem mailbox files and Windows UI Automation.

## Architecture summary

- Codex is always the orchestrator.
- Claude Desktop Code is a bounded worker: reviewer, host-setup worker, isolated implementer, or direct-main exclusive writer.
- Requests and transcripts are durable filesystem artifacts under ignored `.chat-mode/`.
- UIA controls Claude Desktop in the background and reads accessible document text.
- Screenshots and OCR are not source of truth for long responses.
- The retired root PowerShell CLI runner / polling toolkit must not be recreated.

## Critical active decisions

### Source of truth lives inside the installable skill

Status: active
Scope: protocol and runtime behavior
Primary source: `README.md`, `docs/protocol.md`, `skills/chat-mode/SKILL.md`

Decision:

- Canonical protocol instructions live under `skills/chat-mode/` so installation copies runtime instructions with the skill.
- `docs/protocol.md` is only a pointer to the canonical reference files.
- Repository memory docs summarize decisions but must not override the skill or references.

### Review mode always defaults to guarded read-only Bypass

Status: active
Scope: `review` / discussion sessions
Primary source: `skills/chat-mode/references/review-bypass-readonly.md`

Decision:

- Review sessions default Claude Desktop to `Bypass permissions` under a `review-readonly` contract, even when the repository already has dirty files.
- Claude may read, list, search, and run only declared read-only inspection commands.
- Codex remains the sole writer.
- Codex records branch, HEAD, upstream state when available, and dirty status before sending.
- Successful review leaves Claude in Bypass for later reuse when status has no new mutation relative to the recorded baseline.
- Failure, ambiguity, mutation, or explicit user request restores `Manual`.

Reason:

- Bypass removes repeated permission prompts for routine review without granting task authority.
- Read-only authority is contractual and verified by baseline / post-turn inspection; Bypass is not an OS sandbox.

### Send overlay detection is state-based, not focus-based

Status: active
Scope: `SendPrompt`, `Diagnose`, `ClearOverlay`
Primary source: `skills/chat-mode/references/windows-uia.md`

Decision:

- `SendPrompt` must not rely on focused control type as the primary proof that an overlay is open or closed.
- Detect blocking state with expanded controls, desktop-root Claude popups, trust/permission dialogs, composer state, marker-count baselines, and `FromPoint` hit-testing at the center of `Send`.
- Workspace dropdowns should be cleared with `ExpandCollapsePattern.Collapse()` first, then by re-selecting the already-selected expected workspace row when safe, then guarded `Escape` only when focus is provably not the composer.
- A trust, permission, or Bypass dialog is `send_blocked_by_dialog` and must be handled by contract-specific approval, not by the Send ladder.

### Host setup has its own guarded Bypass contract

Status: active
Scope: plugin installation and machine-local setup
Primary source: `skills/chat-mode/references/host-setup-delegated.md`

Decision:

- Use `host-setup-delegated` only when the user explicitly asks Claude to perform host setup.
- Allow only exact declared non-secret setup commands, declared non-secret config paths, declared network hosts, and declared restart authority.
- Project files remain read-only and Codex remains project writer.
- Secrets stay outside chat-mode artifacts and memory.
- Claude must not ask for, print, store, or transmit Access Anywhere URLs, API keys, passwords, tokens, private keys, or one-time codes.
- Host setup ends by restoring `Manual`.

### Isolated implementation is the default write mode

Status: active
Scope: Claude file modifications
Primary source: `skills/chat-mode/references/isolated-implementer.md`

Decision:

- When Claude is asked to modify files, use a clean sibling worktree and dedicated `chat-mode/claude-*` branch by default.
- Claude writes only inside the isolated worktree and declared `write_scope`.
- Codex must not edit tracked files in Claude's worktree during the turn.
- Codex inspects scope, diff, tests, main worktree cleanliness, and metadata before integration.
- Completion marker is handback only; it is not approval to integrate.
- Worktree / branch cleanup is separate and requires user authorization.

### Direct main access is explicit and exclusive

Status: active
Scope: non-isolated Claude work on the current main worktree
Primary source: `skills/chat-mode/references/direct-main-exclusive.md`

Decision:

- Use `direct-main-exclusive` only when the user explicitly asks for same-worktree / non-isolated / equal task-level access.
- Require clean main worktree, named branch, baseline commit, write scope, and exact authority contract.
- Claude temporarily owns main worktree writes; Codex freezes its own writes and Git operations until handback inspection completes.
- Restore `Manual` before Codex resumes writing.
- Equal access means serial equivalent task authority, not concurrent writes.

### UIA actions must fail closed

Status: active
Scope: Claude Desktop automation
Primary source: `skills/chat-mode/references/windows-uia.md`

Decision:

- Identify controls by accessible name and type, not coordinates.
- Approve prompts only when accessible text exactly matches the recorded contract.
- Bypass enable accepts only `review-readonly`, `host-setup-delegated`, or `direct-main-exclusive`.
- A guarded Space fallback is allowed only when process, focused element, native window handle, and foreground checks all match.
- Ambiguity, missing controls, unexpected UI state, timeout, or malformed marker stops the session.

## Current validated evidence

- `docs/smoke-test-2026-08-08.md`: first end-to-end background UIA review.
- `docs/smoke-test-isolated-write-2026-08-08.md`: first real isolated Claude write.
- `docs/smoke-test-delegated-authority-2026-08-08.md`: Codex-controlled prompt approval.
- `docs/smoke-test-direct-main-bypass-2026-08-08.md`: explicit non-isolated direct-main Bypass handoff.
- `docs/smoke-test-review-bypass-readonly-2026-08-08.md`: default read-only Bypass review and selector fallback.
- `docs/smoke-test-review-bypass-persistence-2026-08-08.md`: successful review can retain Bypass and reuse it idempotently.

## Safety invariants

1. Codex owns the loop.
2. Claude never starts another agent loop.
3. One writer per worktree.
4. Review is read-only even when Claude UI is in Bypass.
5. Host setup is not project implementation.
6. Direct main is explicit, serial, and exclusive.
7. Git, network, credential, deployment, destructive, and external-path authority must be explicit in the request.
8. Completion markers do not approve integration.
9. `.chat-mode/STOP` aborts.
10. Never put secrets into request files, transcripts, repo docs, Nowledge Memory, or chat.

## Common next-time warnings

- Do not treat Bypass as sandboxing or as permission to exceed the recorded contract.
- Do not approve broad prompts such as `.*`; derive prompt regex from the exact contract.
- Do not treat dirty status alone as a reason to avoid Bypass for read-only review; record the baseline and reject new mutation.
- Do not delete `.chat-mode-worktrees` or branches without explicit cleanup authorization.
- When protocol behavior changes, update `skills/chat-mode/SKILL.md`, relevant references, helper scripts, AGENTS / CLAUDE if needed, README, tests, and this memory file together.
