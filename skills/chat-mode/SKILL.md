---
name: chat-mode
description: Coordinate bounded Codex and Claude Desktop collaboration on Windows through a filesystem mailbox and Computer Use controlled Claude Desktop, including read-only review, isolated Git-worktree implementation, and explicitly authorized direct main-worktree handoff. Use when the user asks for chat-mode, 暢聊模式, Codex/Claude discussion or review, Claude-assisted large file or code changes, equal AI assistant access, non-isolated Claude operation, or Claude Desktop operation.
---

# Chat Mode

Run Codex as the orchestrator and Claude Desktop Code as a bounded reviewer, isolated implementer, or explicitly authorized exclusive writer of the current main worktree. Use Computer Use as the default Claude Desktop control plane for visible window state, workspace selection, sending prompts, and resolving stuck UI. Use UIA only as a secondary aid for exact-text reads or guarded permission checks when it is clearly simpler and already stable.

## Core rules

1. Keep Codex as the only orchestrator. Claude must not invoke Codex or start a nested chat-mode loop.
2. Use files for durable requests and transcripts. Use Computer Use as the primary Claude Desktop control plane; use UIA as an optional text-reading or exact-control helper, not as the default send path.
3. Treat the user's task as delegated authority for necessary project-local reads, in-scope writes, and declared validation. Let Codex verify and approve matching Claude prompts; ask the user only when authority would expand or risk materially changes.
4. Default Claude Desktop to `Manual` plus Computer Use for ordinary review/discussion. Use guarded `Bypass permissions` only when the user requests prompt-free operation or the session mode clearly benefits from it; the mailbox contract remains the authority boundary. For review or discussion, `review-readonly` keeps Codex as the sole writer and explicitly forbids edits, commits, pushes, destructive commands, network access, credentials, deployment, and external paths. For tool installation or machine setup, use `host-setup-delegated` with exact declared setup commands and non-secret config writes.
5. Bound every session by turns, time, and response size. Default to 3 turns and a 5-minute limit per Claude turn.
6. Use one writer per working tree. In review mode, Codex is the sole project writer. In implementation modes, hand the selected working tree exclusively to Claude and freeze Codex writes until handback.
7. Require a Git repository, clean selected worktree, baseline commit and branch, explicit `write_scope`, and authorized action and command sets before implementation.
8. For host setup, plugin installation, or machine-level configuration, use the guarded `host-setup-delegated` Bypass contract only when the user explicitly asks Claude to perform the setup. It must list exact non-secret commands and config writes, keep credential handling with the user or local UI, and forbid secrets in chat, request files, transcripts, and Memory.

Read [references/protocol.md](references/protocol.md) before starting a real session. On Windows, read [references/windows-uia.md](references/windows-uia.md) only when you plan to use the UIA helper; ordinary Claude Desktop operation should use Computer Use.

When the user asks for prompt-free review or repeated Claude permission prompts make Bypass worthwhile, read [references/review-bypass-readonly.md](references/review-bypass-readonly.md) before enabling the read-only Bypass profile.

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

Default to `review` with a read-only mailbox contract, `Manual` permission mode, and Computer Use operation. Use the guarded `review-readonly` Bypass profile only when the user requests prompt-free review or repeated permission prompts materially slow a clear session. Do not confuse Claude Desktop's permission UI with task authority, and do not expand authority merely to keep the loop moving.

Use `host-setup-delegated` only for user-requested host setup such as installing a Claude plugin or configuring a local tool. This mode may authorize exact setup commands and non-secret config writes, but it must not authorize project edits, Git mutation, deployment, destructive commands, or credential disclosure.

### 2. Select the working tree

For review mode, use the main repository and keep Claude contractually read-only. Capture the current Git baseline when available; if the worktree is dirty, record the dirty status in the request and in the handback check instead of falling back to `Manual`. Use `Manual` only when the user explicitly requests per-action approval or the workspace cannot be identified reliably.

For host-setup-delegated mode, use the repository only as an orchestration anchor and keep project files read-only. Record the current Git baseline so project mutation is detectable, even when unrelated dirty files already exist. Record exact host setup targets, commands, non-secret config paths, restart authority, network hosts, and credential boundaries. Keep Access Anywhere URLs, API keys, passwords, tokens, and private keys out of all chat-mode artifacts.

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

### 5. Configure Claude with Computer Use first

Use Computer Use to target the Claude window, inspect the screenshot, close visible overlays, select the intended workspace, and click clearly visible controls. UIA is secondary and should not be used to repair a visually stuck Claude UI.

- Select the strongest available Opus model for the first architecture or adversarial review.
- Use Sonnet for repeated routine turns when speed or usage matters.
- Prefer `Manual` for ordinary review/discussion unless the user explicitly wants prompt-free Bypass or repeated permission prompts are materially slowing an otherwise clear session. When using Bypass, keep the mailbox contract authoritative and record branch, HEAD, upstream state when available, dirty status, read-only actions, and declared inspection commands first.
- For user-authorized host setup, use Bypass only after recording the current project baseline, exact setup commands, non-secret config paths, allowed network hosts, credential boundaries, and restart authority.
- Record and report the exact worktree path, branch, base commit, `write_scope`, and authorized actions and commands before implementation.
- When the user's task already authorizes those in-scope writes, set `Accept edits` for the isolated Claude session without requesting another confirmation.
- Only when the user explicitly authorizes direct non-isolated access, enable the direct-main-exclusive permission mode after visually verifying Claude's destructive-command warning and confirmation controls.
- Keep or restore `Manual` when the Claude workspace cannot be matched to the contract, a trust/permission state is ambiguous, or Bypass controls look stale or inconsistent.
- Use visible evidence first: one Claude window, intended workspace label/path, prompt text in composer, visible Send/Stop state, and completion marker in the response.

Avoid hard-coded coordinates when accessible element targeting or screenshot-backed targeting is available. If coordinates are used, they must be derived from the current screenshot and followed by a visible-state check.

Neither `Accept edits` nor `Bypass permissions` is an OS-level path sandbox. Use Bypass only with the guarded `review-readonly`, `host-setup-delegated`, or `direct-main-exclusive` contract. The review profile is contractually read-only even though the UI mode is capable of mutation. Baseline status, textual scope, and post-turn inspection detect violations but cannot prevent external access.

### 6. Send and monitor

Send the prefilled prompt with Computer Use. Verify the screenshot shows the correct workspace and the expected request text or marker in the composer, close any visible workspace/model/mode overlay, then click the visible Send control. Do not treat a click as success; require post-send evidence such as a visible user message, visible `Stop`, an emptied composer, or Claude beginning to respond. Poll for the unique completion marker with bounded waits. Share progress with the user between waits.

When Claude opens a permission prompt, compare its accessible text with the recorded contract. Use `ApprovePrompt` only for an exact, expected action and only when the helper finds one `Allow once` and one `Deny` control. This may include in-scope file access or a validation command already authorized by the task. Reject or escalate prompts for Git operations assigned to Codex, out-of-scope paths, undeclared commands, credentials, production or deployment access, destructive actions, or unexpected network access.

Treat any of the following as a hard stop:

- unexpected, ambiguous, or contract-expanding permission or trust dialog;
- repeated `send_not_submitted` or ambiguous send state after the bounded Send ladder;
- malformed or missing marker;
- focus-sensitive behavior that could type into the wrong application;
- timeout or output-size limit;
- mutation outside the active writer's selected worktree or writes outside `write_scope`;
- user-created `.chat-mode/STOP` file.

### 7. Bring the result back

Read the complete Claude document through `TextPattern.DocumentRange`, extract the response associated with the current request, and preserve it in the session transcript. Do not rely on screenshots or OCR for long text.

In review mode, verify branch, HEAD, commits, upstream state, and project status against the recorded baseline, allowing only pre-existing dirty paths. After a successful handback, leave Claude in its current safe state; restore `Manual` whenever Bypass state is ambiguous or the session failed. Codex evaluates Claude's recommendations; it does not automatically execute them.

In host-setup-delegated mode, restore `Manual` at session close, verify project status against the recorded baseline with unchanged branch, HEAD, commits, and upstream state, and verify only the recorded host setup state changed. Reject the turn if project files changed beyond the baseline, secrets appeared in artifacts, or Claude exceeded the exact command, network, credential, restart, or config authority.

In isolated-implementer mode, freeze Claude's turn and run `scripts/chat-mode-worktree.ps1 -Action Inspect`. Require `ScopePassed`, review every changed path and the complete diff, reproduce tests, and verify the main worktree stayed clean. A completion marker is not permission to integrate. Apply or cherry-pick only within the user's original modification authority.

In direct-main-exclusive mode, freeze Claude's turn, immediately run `scripts/chat-mode-direct-main.ps1 -Action Inspect`, and review scope, branch, HEAD, commits, upstream state, tracked and untracked paths, and the full baseline diff. Accept only changes and Git operations authorized by the original task. Codex resumes writing only after inspection and handback.

Continue only while the bounded contract permits another turn.

### 8. Close cleanly

Record the final result and stop reason. Return control to the user. Report the completion marker, changed worktree, branch, diff status, tests, integration status, and any remaining cleanup. Leave Claude in `Manual` for ordinary reviews. Restore `Manual` after host-setup or implementation handback, after any failed or ambiguous review, or when Bypass is no longer needed. For direct-main-exclusive mode, inspect before running `chat-mode-direct-main.ps1 -Action Close` to archive the handoff metadata. Never delete an isolated worktree or branch automatically.

## Fallback order

1. Filesystem request plus Computer Use: open/reuse Claude, visually select the workspace, paste or use the deep-linked poke, close overlays, click Send, and verify response progress.
2. If Claude's composer is still not submitted, classify the visible failure (`workspace_overlay_open`, `permission_dialog`, `send_not_clicked`, `submitted_no_response`, or `send_ambiguous`) and try at most one visible correction.
3. Use UIA only for exact-text reading, guarded permission approval, or clipboard/accessible response extraction when Computer Use has already established the correct visible state.
4. Filesystem request plus a user-approved response file.
5. Manual user action when authority expansion, repeated send failure, or ambiguous UI state requires a decision.

Do not retry the same send method indefinitely. Keep automatic send attempts to a small bounded budget, normally no more than two visible corrections or about 2-3 minutes. Never fall back to the removed PowerShell CLI runner, polling state machine, blind coordinate clicking, or simulated worker output.
