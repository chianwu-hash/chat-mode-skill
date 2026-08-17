# Project Memory

Last reviewed: 2026-08-17

This is durable context, not protocol source of truth. Runtime authority lives in `skills/chat-mode/SKILL.md` and its references.

## Identity and architecture

- Repository: `D:\projects\chat-mode-skill`
- GitHub: `chianwu-hash/chat-mode-skill`; main branch: `main`
- CLI migration baseline: `8ee63aa18b6429b0f70302cbd7ac30555ede3a61`
- Codex is always the orchestrator; requests, results, state, and transcripts are ignored artifacts under `.chat-mode/`.
- `review` and `isolated-implementer` default to `claude-cli-supervisor.ps1`.
- `host-setup-delegated` and `direct-main-exclusive` remain Claude Desktop modes.
- Isolated writes use a clean sibling worktree; Codex owns preparation, inspection, Git integration, and cleanup authorization.

## CLI decisions

- Require Claude Code 2.1.233+ and subscription OAuth (`authMethod: claude.ai`); reject API-key authentication.
- Use `--setting-sources user`; never use `--bare` or raw `claude -p` for real turns.
- Review exposes only `Read`, `Glob`, and `Grep`. Isolated mode adds `Edit` and `Write`; Bash exists only for declared validation commands.
- Store Claude's session ID and use `--resume` for later turns.
- Resume requires an unchanged SHA-256 fingerprint of stable authority fields. Turn text, deadline, response cap, and marker may change.
- STOP and timeout terminate the child process tree. Validate JSON, response size, session ID, and exact trailing marker.
- Claude stdout uses official partial-message `stream-json`; parsed text deltas append to a non-authoritative `live.md`, while only the final result can complete a turn.
- Ordinary review uses medium effort/300 seconds; explicit deep review uses high effort/600 seconds. Idle gaps warn at 90/150 seconds but never kill without stronger timing evidence.
- Started turns atomically publish sanitized status and always write success or failure run records. Failure invalidates resume state; timeout retry uses a narrower new chat-mode session.
- Git baselines and isolated-worktree inspection remain mandatory because CLI permission rules are not an OS sandbox.
- CLI review prevents writes but does not confine Read/Glob/Grep to the repository. Disclose that Claude may read any file accessible to the current account.
- Request-path session segments must exactly match frontmatter `session_id`; flow-style and block-style YAML lists are both parsed.

## Desktop decisions retained

- Host setup is explicit and limited to exact commands, declared non-secret config, and declared hosts; secrets remain user-handled.
- Direct-main access is explicit, clean, serial, and exclusive; Codex freezes writes until inspected handback.
- Computer Use is the visible controller; UIA is a guarded exact-control helper.
- Desktop returns to `Manual` after writable handback, failure, or ambiguity.

## Evidence

- 2026-08-17: Claude Code updated from 2.1.71 to 2.1.233.
- A real Pro OAuth one-turn MVP completed in 8.24 seconds with project/local settings excluded.
- A real two-turn session reused one Claude session ID and recalled a nonce; turns completed in 9.86 and 5.69 seconds.
- A real streaming MVP produced 99 partial/final events and exposed 4,501 bytes of Claude text before completion; the final live and response artifacts both reached 8,329 bytes with unchanged Git state.
- Windows Terminal viewer launch requires `wt -w -1 new-tab`; both `new-window` and `-w new` failed on this installation. The user visibly confirmed the corrected replay, and a real turn streamed 108 events before completing with the window configured to wait for Enter.
- A hardened medium-effort Pro OAuth turn completed in 13.556 seconds with 51 events, sanitized completed status, resumable validated state, and unchanged Git state.
- The fake-worker supervisor smoke test verifies effort selection, first turn/resume, timeout and STOP failure artifacts, failed-session resume rejection, viewer states, response caps, malformed output, markers, Claude errors, and unchanged Git state.
- Earlier Desktop evidence remains in the `docs/smoke-test-2026-08-08*.md` family.

## Safety invariants

1. Codex owns the loop; Claude never launches a nested agent.
2. One writer per worktree; review is read-only regardless of transport permissions.
3. Host setup is not implementation; direct main is explicit, serial, and exclusive.
4. Git, network, credential, deployment, destructive, and external-path authority must be explicit.
5. Completion is handback, not integration approval; `.chat-mode/STOP` aborts.
6. Secrets never enter requests, transcripts, repo docs, or memory.
7. Worktrees and branches are not deleted without separate authorization.
