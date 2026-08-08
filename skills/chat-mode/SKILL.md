---
name: chat-mode
description: Coordinate bounded Codex and Claude Desktop collaboration on Windows through a filesystem mailbox and background Windows UI Automation, including read-only review and isolated Git-worktree implementation. Use when the user asks for chat-mode, 暢聊模式, Codex/Claude discussion or review, Claude-assisted large file or code changes, or background Claude Desktop operation.
---

# Chat Mode

Run Codex as the orchestrator and Claude Desktop Code as either a bounded reviewer or an explicitly authorized isolated implementer. Keep the user's desktop available by controlling Claude through Windows UI Automation (UIA), not screen coordinates.

## Core rules

1. Keep Codex as the only orchestrator. Claude must not invoke Codex or start a nested chat-mode loop.
2. Use files for durable requests and transcripts. Use UIA as the control plane and as the tested response-reading path.
3. Never approve a workspace trust or permission dialog automatically. Stop and ask the user.
4. For review or discussion, set Claude to `Manual` and explicitly forbid edits, commits, pushes, and destructive commands.
5. Bound every session by turns, time, and response size. Default to 3 turns and a 5-minute limit per Claude turn.
6. Use one writer per working tree. In review mode, Codex is the sole project writer. In isolated-implementer mode, Claude writes only in its dedicated worktree while the main worktree remains untouched.
7. Require a Git repository, clean main worktree, baseline commit, dedicated branch, and explicit `write_scope` before isolated implementation.

Read [references/protocol.md](references/protocol.md) before starting a real session. On Windows, read [references/windows-uia.md](references/windows-uia.md) before controlling Claude Desktop.

When the user asks Claude to modify files, read [references/isolated-implementer.md](references/isolated-implementer.md) before creating a worktree or granting write access.

## Workflow

### 1. Establish the contract

Confirm or infer:

- repository root;
- task and Claude's role;
- maximum turns and per-turn timeout;
- `review` or `isolated-implementer` mode;
- write scope when implementation is requested;
- completion marker unique to the turn.

Default to read-only. Do not expand authority merely to keep the loop moving.

### 2. Select the working tree

For review mode, use the main repository and keep Claude read-only.

For isolated-implementer mode, require explicit user intent, then use `scripts/chat-mode-worktree.ps1 -Action Prepare` with one or more `-WriteScope` patterns. Open the resulting sibling worktree in Claude. Do not let Claude write in the main worktree and do not let Codex edit tracked files in Claude's worktree during its turn.

### 3. Prepare a durable request

Create a request under:

```text
.chat-mode/exchange/<session-id>/turn-0001.request.md
```

Include the envelope defined in the protocol reference. Keep `.chat-mode/` ignored by Git.

In isolated-implementer mode, place the request in the isolated worktree's `.chat-mode/exchange/` directory and include the absolute worktree path, branch, base commit, and `write_scope`.

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

Use the main repository as `folder` for review mode and the isolated worktree as `folder` for implementation mode.

If Claude displays `Trust this workspace?`, ask the user to verify the exact path and click `Trust Workspace`. Do not click it for them.

### 5. Configure Claude without taking foreground focus

Use `scripts/claude-desktop-uia.ps1` or equivalent native UIA calls.

- Select the strongest available Opus model for the first architecture or adversarial review.
- Use Sonnet for repeated routine turns when speed or usage matters.
- Set `Manual` for discussion and review.
- Default to `Manual` for implementation. Set `Accept edits` only after the user explicitly approves the isolated worktree and declared `write_scope`.
- Identify controls by accessible name and control type.
- Fail on zero or multiple matches instead of guessing.

Do not use hard-coded screen coordinates unless the user explicitly accepts a fragile, visible fallback.

### 6. Send and monitor

Invoke the accessible `Send` button. Poll the Claude document text for the unique completion marker in intervals shorter than 60 seconds. Share progress with the user between waits.

Treat any of the following as a hard stop:

- unexpected permission or trust dialog;
- malformed or missing marker;
- focus-sensitive behavior that could type into the wrong application;
- timeout or output-size limit;
- unexpected main-worktree mutation or isolated-worktree writes outside `write_scope`;
- user-created `.chat-mode/STOP` file.

### 7. Bring the result back

Read the complete Claude document through `TextPattern.DocumentRange`, extract the response associated with the current request, and preserve it in the session transcript. Do not rely on screenshots or OCR for long text.

In review mode, Codex evaluates Claude's recommendations; it does not automatically execute them.

In isolated-implementer mode, freeze Claude's turn and run `scripts/chat-mode-worktree.ps1 -Action Inspect`. Require `ScopePassed`, review every changed path and the complete diff, reproduce tests, and verify the main worktree stayed clean. A completion marker is not permission to integrate. Apply or cherry-pick only within the user's original modification authority.

Continue only while the bounded contract permits another turn.

### 8. Close cleanly

Record the final result and stop reason. Return control to the user. Report the completion marker, changed worktree, branch, diff status, tests, integration status, and any remaining cleanup. Never delete an isolated worktree or branch automatically.

## Fallback order

1. Filesystem request plus background UIA control and response reading.
2. Filesystem request plus a user-approved response file.
3. Visible Computer Use only for controls UIA cannot expose.
4. Manual user action for trust and permission decisions.

Never fall back to the removed PowerShell CLI runner, polling state machine, coordinate clicking, or simulated worker output.
