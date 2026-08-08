---
name: chat-mode
description: Coordinate bounded Codex and Claude Desktop collaboration on Windows through a filesystem mailbox and background Windows UI Automation. Use when the user asks for chat-mode, 暢聊模式, a Codex/Claude design discussion or review, or wants Codex to operate Claude Desktop without taking over the foreground desktop.
---

# Chat Mode

Run Codex as the orchestrator and Claude Desktop Code as a bounded review worker. Keep the user's desktop available by controlling Claude through Windows UI Automation (UIA), not screen coordinates.

## Core rules

1. Keep Codex as the only orchestrator. Claude must not invoke Codex or start a nested chat-mode loop.
2. Use files for durable requests and transcripts. Use UIA as the control plane and as the tested response-reading path.
3. Never approve a workspace trust or permission dialog automatically. Stop and ask the user.
4. For review or discussion, set Claude to `Manual` and explicitly forbid edits, commits, pushes, and destructive commands.
5. Bound every session by turns, time, and response size. Default to 3 turns and a 5-minute limit per Claude turn.
6. If tracked files may change, require a Git repository and a baseline commit first. Keep Claude read-only; Codex is the sole project writer.

Read [references/protocol.md](references/protocol.md) before starting a real session. On Windows, read [references/windows-uia.md](references/windows-uia.md) before controlling Claude Desktop.

## Workflow

### 1. Establish the contract

Confirm or infer:

- repository root;
- task and Claude's role;
- maximum turns and per-turn timeout;
- read-only or edit-enabled session;
- completion marker unique to the turn.

Default to read-only. Do not expand authority merely to keep the loop moving.

### 2. Prepare a durable request

Create a request under:

```text
.chat-mode/exchange/<session-id>/turn-0001.request.md
```

Include the envelope defined in the protocol reference. Keep `.chat-mode/` ignored by Git.

For a minimal session, Claude may answer in its chat while ending with the unique marker. For very large responses, request a response file only when the user has authorized Claude to write inside the exchange directory.

### 3. Open Claude Desktop Code

Prefer the deep link:

```text
claude://code/new?q=<url-encoded-poke>&folder=<url-encoded-repo-root>
```

The poke should be short, for example:

```text
Read .chat-mode/exchange/<session-id>/turn-0001.request.md, follow its contract, respond here, and end with <marker>.
```

If Claude displays `Trust this workspace?`, ask the user to verify the path and click `Trust Workspace`. Do not click it for them.

### 4. Configure Claude without taking foreground focus

Use `scripts/claude-desktop-uia.ps1` or equivalent native UIA calls.

- Select the strongest available Opus model for the first architecture or adversarial review.
- Use Sonnet for repeated routine turns when speed or usage matters.
- Set `Manual` for discussion and review.
- Identify controls by accessible name and control type.
- Fail on zero or multiple matches instead of guessing.

Do not use hard-coded screen coordinates unless the user explicitly accepts a fragile, visible fallback.

### 5. Send and monitor

Invoke the accessible `Send` button. Poll the Claude document text for the unique completion marker in intervals shorter than 60 seconds. Share progress with the user between waits.

Treat any of the following as a hard stop:

- unexpected permission or trust dialog;
- malformed or missing marker;
- focus-sensitive behavior that could type into the wrong application;
- timeout or output-size limit;
- unexpected project mutation;
- user-created `.chat-mode/STOP` file.

### 6. Bring the result back

Read the complete Claude document through `TextPattern.DocumentRange`, extract the response associated with the current request, and preserve it in the session transcript. Do not rely on screenshots or OCR for long text.

Codex evaluates Claude's recommendations; it does not automatically execute them. Continue only while the bounded contract permits another turn.

### 7. Close cleanly

Record the final result and stop reason. Return control to the user. Report whether any files changed and whether the completion marker was observed.

## Fallback order

1. Filesystem request plus background UIA control and response reading.
2. Filesystem request plus a user-approved response file.
3. Visible Computer Use only for controls UIA cannot expose.
4. Manual user action for trust and permission decisions.

Never fall back to the removed PowerShell CLI runner, polling state machine, coordinate clicking, or simulated worker output.
