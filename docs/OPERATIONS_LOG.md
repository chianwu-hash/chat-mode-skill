# Operations Log

This file records significant chat-mode-skill changes for future AI handoff. It is not a full transcript.

## 2026-08-17 Restore supervised Claude CLI transport

Status: completed
Changed by: Codex
Related task: Replace fragile Claude Desktop sending with a proven subscription-authenticated `claude -p` path

Summary:

- Confirmed the pre-change `main` baseline was clean, committed, and synchronized with `origin/main` at `8ee63aa18b6429b0f70302cbd7ac30555ede3a61`.
- Updated Claude Code from 2.1.71 to 2.1.233 and verified Claude Pro OAuth login without an Anthropic API key.
- Added a CLI supervisor that enforces request envelopes, minimum version/auth checks, user-only settings, bounded tools, STOP/timeout termination, Git baselines, structured output, response caps, completion markers, and durable artifacts.
- Added persistent multi-turn memory through Claude session IDs and `--resume`; resume is rejected when the stable authority-contract fingerprint changes.
- Made CLI transport the default for review and isolated implementation. Retained Claude Desktop for host setup, direct-main-exclusive handoff, explicit visible sessions, and bounded fallback.

Validation evidence:

- Real one-turn Pro OAuth MVP: 8.24 seconds; project `CLAUDE.md` was not loaded.
- Real resumed two-turn MVP: same session ID, nonce recalled, 9.86 and 5.69 seconds.
- Real end-to-end supervisor turns: 20.36 seconds initially and 8.00 seconds resumed, with the same Claude session ID, unchanged contract fingerprint, and unchanged dirty Git baseline.
- Fake-worker supervisor smoke passed first turn, resume, same-session, changed-contract rejection, response artifacts, and unchanged Git status.

Important decision:

- Use `--setting-sources user`, not `--bare`. Current `--bare` behavior does not use subscription OAuth and would require the API route the user rejected.
- A two-turn independent Claude review endorsed the CLI-first direction after live evidence resolved its flag and npm-shim concerns. Before commit, Codex added exact request-path/session matching, flow-style list parsing, prominent host-wide read-risk disclosure, and negative-path smoke coverage.

## 2026-08-11 Reuse trusted projects for new Claude conversations

Status: completed
Changed by: Codex
Related task: Repeated workspace-trust prompts and stale Manual defaults during review research

Summary:

- Synchronized the installable skill with the repository decision that ordinary review uses guarded `Bypass permissions` by default.
- Changed session startup so an existing Claude project uses `New session in <workspace>` and receives the mailbox poke in that conversation.
- Reserved `folder=` deep links for genuinely new or unavailable paths, especially isolated worktrees.
- Allowed explicitly authorized public-web research to declare bounded public hosts while keeping review project access read-only.

Expected effect:

- Ordinary new conversations in an already trusted project should no longer re-enter workspace trust flow.
- Review research should not stall on repeated permission prompts when the guarded Bypass contract is active.

Validation:

- Skill-creator validation passed and the UIA PowerShell script parsed successfully.
- A live Claude Desktop check used `New session in chat-mode-skill`, selected the expected workspace, and did not display `Trust this workspace?`.
- The live check exposed a retained unsent composer draft, so the protocol now requires clearing or fully replacing any stale draft before sending.

## 2026-08-09 Make Bypass default and harden send overlay handling

Status: completed
Changed by: Codex
Related task: User decision to prioritize Claude response efficiency and recurring workspace dropdown send failures

Summary:

- Updated the authority model so review sessions use guarded `Bypass permissions` even when a repository is already dirty; the request contract remains read-only by default, and Codex records baseline status to reject new mutation.
- Kept host setup as the writable setup path for plugin/tool installation: exact setup commands, declared non-secret config paths, and no project edits or credentials.
- Added UIA `Diagnose` and `ClearOverlay` actions and hardened `SendPrompt` around state-based overlay detection.
- Replaced focus-based overlay detection with expanded controls, desktop-root Claude popups, trust/permission dialog detection, `Send` hit-testing, composer text where exposed, and marker-count postconditions.
- Added `send_blocked_by_dialog` for trust, permission, or Bypass dialogs that must not be dismissed from the Send ladder.

Important notes captured:

- Dirty Git status is no longer a reason to fall back to Manual for read-only review. It is baseline evidence.
- Bypass changes Claude Desktop prompt behavior; it does not expand review authority.
- The observed send failure was a workspace dropdown overlay that could block sending even when focus was not on a menu.

Validation:

- PowerShell parser check passed for `claude-desktop-uia.ps1`.

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
- Review Bypass is the default for read-only review and may persist after successful review.
- Host setup, isolated implementation, and direct-main exclusive handoff are separate authority models.
- Bypass is UI permission behavior, not an OS sandbox or general authority expansion.

Validation:

- New memory docs were based on `README.md`, `AGENTS.md`, `CLAUDE.md`, `skills/chat-mode/SKILL.md`, and the canonical reference files.
- No runtime scripts or protocol behavior were changed in this onboarding commit.
