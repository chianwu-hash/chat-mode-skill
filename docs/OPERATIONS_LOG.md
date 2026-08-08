# Operations Log

This file records significant chat-mode-skill changes for future AI handoff. It is not a full transcript.

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
