# Operations Log

This file records significant chat-mode-skill changes for future AI handoff. It is not a full transcript.

## 2026-08-09 Add guarded SendPrompt workflow

Status: completed
Changed by: Codex
Related task: Claude Desktop composer send failures during chat-mode review

Summary:

- Added `SendPrompt` to `skills/chat-mode/scripts/claude-desktop-uia.ps1`.
- Updated `skills/chat-mode/SKILL.md`, `references/protocol.md`, and `references/windows-uia.md` so chat-mode no longer treats raw `InvokePattern` on `Send` as proof that a message was submitted.
- Added a bounded Send ladder with pre-flight overlay checks, post-send verification, failure classifications, and retry limits.
- Documented visible Computer Use and manual send as later escalation paths, not as unbounded retry loops.

Important notes captured:

- The observed failure was caused by Claude Desktop exposing an enabled `Send` button while a workspace/menu overlay held focus.
- Whole-document text search is not enough to prove a prompt remains in the composer because sent user messages also remain in the conversation transcript.
- Automatic send attempts should stop after a small bounded budget and return a clear `send_not_submitted`, `send_blocked_by_overlay`, or `send_ambiguous` diagnosis.

Validation:

- PowerShell parser check passed for `claude-desktop-uia.ps1`.
- `git diff --check` passed with only CRLF conversion warnings.

## 2026-08-08 Add repo-local AI memory entrypoint

Status: completed
Changed by: Codex
Related task: AI memory system project onboarding

Summary:

- Added `docs/PROJECT_MEMORY.md` to summarize durable chat-mode architecture, authority contracts, safety invariants, and validated evidence.
- Added `docs/RUNBOOK.md` for maintenance routing, validation commands, mode-specific checks, and memory update rules.
- Added this `docs/OPERATIONS_LOG.md`.
- Updated `AGENTS.md` and `CLAUDE.md` so future agents read repo-local memory docs before changing this repository.

Important notes captured:

- `skills/chat-mode/SKILL.md` and files under `skills/chat-mode/references/` remain source of truth.
- Review Bypass is the default for clean read-only review and may persist after successful clean review.
- Host setup, isolated implementation, and direct-main exclusive handoff are separate authority models.
- Bypass is UI permission behavior, not an OS sandbox or general authority expansion.

Validation:

- New memory docs were based on `README.md`, `AGENTS.md`, `CLAUDE.md`, `skills/chat-mode/SKILL.md`, and the canonical reference files.
- No runtime scripts or protocol behavior were changed in this onboarding commit.
