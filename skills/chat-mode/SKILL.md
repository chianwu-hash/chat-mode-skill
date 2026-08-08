---
name: chat-mode
description: Coordinate bounded Codex and Claude Desktop collaboration on Windows through a filesystem mailbox and background Windows UI Automation, including read-only review, isolated Git-worktree implementation, and explicitly authorized direct main-worktree handoff. Use when the user asks for chat-mode, 暢聊模式, Codex/Claude discussion or review, Claude-assisted large file or code changes, equal AI assistant access, non-isolated Claude operation, or background Claude Desktop operation.
---

# Chat Mode

Run Codex as the orchestrator and Claude Desktop Code as a bounded reviewer, isolated implementer, or explicitly authorized exclusive writer of the current main worktree. Keep the user's desktop available by controlling Claude through Windows UI Automation (UIA), not screen coordinates.

## Core rules

1. Keep Codex as the only orchestrator. Claude must not invoke Codex or start a nested chat-mode loop.
2. Use files for durable requests and transcripts. Use UIA as the control plane and as the tested response-reading path.
3. Treat the user's task as delegated authority for necessary project-local reads, in-scope writes, and declared validation. Let Codex verify and approve matching Claude prompts; ask the user only when authority would expand or risk materially changes.
4. For review or discussion, default Claude Desktop to guarded `Bypass permissions` under a `review-readonly` contract. Keep Codex as the sole writer and explicitly forbid edits, commits, pushes, destructive commands, network access, credentials, deployment, and external paths.
5. Bound every session by turns, time, and response size. Default to 3 turns and a 5-minute limit per Claude turn.
6. Use one writer per working tree. In review mode, Codex is the sole project writer. In implementation modes, hand the selected working tree exclusively to Claude and freeze Codex writes until handback.
7. Require a Git repository, clean selected worktree, baseline commit and branch, explicit `write_scope`, and authorized action and command sets before implementation.
8. For host setup, plugin installation, or machine-level configuration, use the guarded `host-setup-delegated` Bypass contract only when the user explicitly asks Claude to perform the setup. It must list exact non-secret commands and config writes, keep credential handling with the user or local UI, and forbid secrets in chat, request files, transcripts, and Memory.

Read [references/protocol.md](references/protocol.md) before starting a real session. On Windows, read [references/windows-uia.md](references/windows-uia.md) before controlling Claude Desktop.

When the user asks for review or discussion, read [references/review-bypass-readonly.md](references/review-bypass-readonly.md) before enabling the default read-only Bypass profile.

When the user asks Claude to install plugins, configure host tools, or perform machine-level setup without project file edits, read [references/host-setup-delegated.md](references/host-setup-delegated.md) before enabling guarded setup Bypass.

When the user asks Claude to modify files, read [references/isolated-implementer.md](references/isolated-implementer.md) before creating an isolated worktree. When the user explicitly requests the same main worktree, no isolation, equal project access, or Bypass on main, read [references/direct-main-exclusive.md](references/direct-main-exclusive.md) before granting write access.

## Workflow

### 1. Establish the contract

Confirm or infer:

- repository root;
- task and Claude's role;
- maximum turns and per-turn timeout;
- `review`, `host-setup-delegated`, `isolated-implementer`, or `direct-main-exclusive` mode;
- write scope when implementation is requested;
- actions and commands delegated by the user's request;
- completion marker unique to the turn.

Default to `review` with a read-only mailbox contract and the guarded `review-readonly` Bypass profile. Do not confuse Claude Desktop's permission UI with task authority, and do not expand authority merely to keep the loop moving.

Use `host-setup-delegated` only for user-requested host setup such as installing a Claude plugin or configuring a local tool. This mode may authorize exact setup commands and non-secret config writes, but it must not authorize project edits, Git mutation, deployment, destructive commands, or credential disclosure.

### 2. Select the working tree

For review mode, use the main repository and keep Claude contractually read-only. Require a clean Git baseline for the default Bypass profile so any mutation is detectable. Fall back to `Manual` review when the worktree is dirty, unversioned, detached, or unusually sensitive.

For host-setup-delegated mode, use the repository only as an orchestration anchor and keep project files read-only. Require a clean Git baseline so project mutation is detectable. Record exact host setup targets, commands, non-secret config paths, restart authority, network hosts, and credential boundaries. Keep Access Anywhere URLs, API keys, passwords, tokens, and private keys out of all chat-mode artifacts.

For isolated-implementer mode, require explicit user intent, then use `scripts/chat-mode-worktree.ps1 -Action Prepare` with one or more `-WriteScope` patterns. Open the resulting sibling worktree in Claude. Do not let Claude write in the main worktree and do not let Codex edit tracked files in Claude's worktree during its turn.

For direct-main-exclusive mode, require explicit user intent to skip isolation and grant Claude equivalent task-level project access. Use `scripts/chat-mode-direct-main.ps1 -Action Prepare` against the clean main worktree. Record the baseline branch, commit, upstream, scope, actions, and commands. Freeze all Codex writes and Git operations in that worktree until Claude hands it back.

### 3. Prepare a durable request

Create a request under:

```text
.chat-mode/exchange/<session-id>/turn-0001.request.md
```

Include the envelope defined in the protocol reference. Keep `.chat-mode/` ignored by Git.

In host setup mode, place the request in the main repository's `.chat-mode/exchange/` directory and include exact setup scope, authorized commands, non-secret config paths, allowed network hosts, credential handling instructions, and restart authority. Do not place secrets or remote access URLs in the request.

In either implementation mode, place the request in the selected worktree's `.chat-mode/exchange/` directory and include its absolute path, branch, base commit, `write_scope`, and explicit Git, network, credential, deployment, and external-path authority.

For a minimal session, Claude may answer in its chat while ending with the unique marker. For very large responses, request a response file only when the user has authorized Claude to write inside the exchange directory.

### 4. Open Claude Desktop Code

Prefer the deep link:

```text
claude://code/new?q=<url-encoded-poke>&folder=<url-encoded-repo-root>
```

The poke should be short, for example:

```text
Read .chat-mode/exchange/<session-id>/turn-0001.request.md, follow its contract, respond here, and end with <marker>.
```

Use the main repository as `folder` for review, host-setup-delegated, and direct-main-exclusive modes, and the isolated worktree as `folder` for isolated implementation.

If Claude displays `Trust this workspace?`, compare the accessible path with the exact repository or isolated worktree in the contract. Use the guarded `ApproveWorkspaceTrust` action when it matches uniquely. Stop and ask the user on mismatch or ambiguity.

### 5. Configure Claude without taking foreground focus

Use `scripts/claude-desktop-uia.ps1` or equivalent native UIA calls.

- Select the strongest available Opus model for the first architecture or adversarial review.
- Use Sonnet for repeated routine turns when speed or usage matters.
- For clean review and discussion sessions, use `EnableBypass -BypassContract review-readonly` by default. Record the clean branch, HEAD, upstream state, read-only actions, and declared inspection commands first.
- For user-authorized host setup, use `EnableBypass -BypassContract host-setup-delegated` only after recording the clean project baseline, exact setup commands, non-secret config paths, allowed network hosts, credential boundaries, and restart authority.
- Record and report the exact worktree path, branch, base commit, `write_scope`, and authorized actions and commands before implementation.
- When the user's task already authorizes those in-scope writes, set `Accept edits` for the isolated Claude session without requesting another confirmation.
- Only when the user explicitly authorizes direct non-isolated access, use `EnableBypass -BypassContract direct-main-exclusive`. Verify Claude's fixed destructive-command warning and confirmation controls through UIA.
- Keep `Manual` for dirty, unversioned, detached, or unusually sensitive review workspaces and when the user requests per-action confirmation.
- Identify controls by accessible name and control type.
- Fail on zero or multiple matches instead of guessing.

Do not use hard-coded screen coordinates unless the user explicitly accepts a fragile, visible fallback.

Neither `Accept edits` nor `Bypass permissions` is an OS-level path sandbox. Use Bypass only with the guarded `review-readonly`, `host-setup-delegated`, or `direct-main-exclusive` contract. The review profile is contractually read-only even though the UI mode is capable of mutation. Clean baselines, textual scope, and post-turn inspection detect violations but cannot prevent external access.

### 6. Send and monitor

Invoke the accessible `Send` button. Poll the Claude document text for the unique completion marker in intervals shorter than 60 seconds. When the sent prompt contains the marker, require at least two document matches so the echoed request cannot masquerade as Claude's handback. Share progress with the user between waits.

When Claude opens a permission prompt, compare its accessible text with the recorded contract. Use `ApprovePrompt` only for an exact, expected action and only when the helper finds one `Allow once` and one `Deny` control. This may include in-scope file access or a validation command already authorized by the task. Reject or escalate prompts for Git operations assigned to Codex, out-of-scope paths, undeclared commands, credentials, production or deployment access, destructive actions, or unexpected network access.

Treat any of the following as a hard stop:

- unexpected, ambiguous, or contract-expanding permission or trust dialog;
- malformed or missing marker;
- focus-sensitive behavior that could type into the wrong application;
- timeout or output-size limit;
- mutation outside the active writer's selected worktree or writes outside `write_scope`;
- user-created `.chat-mode/STOP` file.

### 7. Bring the result back

Read the complete Claude document through `TextPattern.DocumentRange`, extract the response associated with the current request, and preserve it in the session transcript. Do not rely on screenshots or OCR for long text.

In review mode, restore `Manual` at session close and verify the repository remains clean with unchanged branch, HEAD, commits, and upstream state. Any mutation rejects the turn. Codex evaluates Claude's recommendations; it does not automatically execute them.

In host-setup-delegated mode, restore `Manual` at session close, verify the project repository remains clean with unchanged branch, HEAD, commits, and upstream state, and verify only the recorded host setup state changed. Reject the turn if project files changed, secrets appeared in artifacts, or Claude exceeded the exact command, network, credential, restart, or config authority.

In isolated-implementer mode, freeze Claude's turn and run `scripts/chat-mode-worktree.ps1 -Action Inspect`. Require `ScopePassed`, review every changed path and the complete diff, reproduce tests, and verify the main worktree stayed clean. A completion marker is not permission to integrate. Apply or cherry-pick only within the user's original modification authority.

In direct-main-exclusive mode, freeze Claude's turn, immediately run `scripts/chat-mode-direct-main.ps1 -Action Inspect`, and review scope, branch, HEAD, commits, upstream state, tracked and untracked paths, and the full baseline diff. Accept only changes and Git operations authorized by the original task. Codex resumes writing only after inspection and handback.

Continue only while the bounded contract permits another turn.

### 8. Close cleanly

Record the final result and stop reason. Return control to the user. Report the completion marker, changed worktree, branch, diff status, tests, integration status, and any remaining cleanup. Switch Claude back to `Manual` after every chat-mode session. For direct-main-exclusive mode, inspect before running `chat-mode-direct-main.ps1 -Action Close` to archive the handoff metadata. Never delete an isolated worktree or branch automatically.

## Fallback order

1. Filesystem request plus background UIA control and response reading.
2. For a permission selector that ignores `ExpandCollapse`, one guarded Space key on the uniquely focused Claude control only when process, focus, native handle, and existing foreground all match.
3. Filesystem request plus a user-approved response file.
4. Visible Computer Use only for controls UIA cannot expose.
5. Manual user action when authority expansion or ambiguous UI state requires a decision.

Never fall back to the removed PowerShell CLI runner, polling state machine, coordinate clicking, or simulated worker output.
