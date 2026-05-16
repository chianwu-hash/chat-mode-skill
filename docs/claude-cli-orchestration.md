# Claude CLI Orchestration Proposal

This document captures a proposed next workflow for `chat-mode-skill`: one agent can run the other agent through a local CLI, so the default collaboration path no longer needs file polling between two independently running agents.

The primary target is Codex running Claude Code through `claude -p`. The same idea can work in reverse when Claude Code starts the session and invokes `codex exec`.

The existing file-sync protocol remains useful as a fallback for environments where Claude CLI is unavailable, where another agent is already running independently, or where a human wants to copy prompts manually.

## Goals

- Make Codex the orchestrator for bounded Codex/Claude collaboration.
- Call Claude CLI directly for each Claude round instead of waiting for Claude to poll shared files.
- Keep a durable markdown transcript for audit, recovery, and user visibility.
- Keep permission behavior explicit, especially whether Claude may write files.
- Preserve the old polling protocol as a fallback mode.
- Allow either agent to be the orchestrator while preventing recursive agent spawning.

## Non-Goals

- Do not assume Claude CLI can always run without authentication prompts.
- Do not make full write access the default.
- Do not treat Claude's local session store as the source of truth.
- Do not remove the existing file-sync workflow until the orchestrated path is proven.
- Do not allow the worker agent to start a nested chat-mode loop unless the user explicitly asks for that.

## Workflow Modes

### `orchestrated`

One agent starts and controls the whole exchange.

When Codex is the orchestrator:

1. Codex creates the chat-mode state file and session markdown.
2. Codex writes its own round when needed.
3. Codex invokes `claude -p` for Claude's round.
4. Codex captures Claude's stdout/stderr and exit code.
5. Codex appends Claude's response to the session markdown.
6. Codex updates state and continues until a turn, time, or manual stop condition is reached.

When Claude is the orchestrator:

1. Claude creates or asks Codex to create the chat-mode state file and session markdown.
2. Claude writes its own round when needed.
3. Claude invokes `codex exec` for Codex's round.
4. Claude captures Codex stdout/stderr and exit code.
5. Claude appends Codex's response to the session markdown.
6. Claude updates state and continues until a turn, time, or manual stop condition is reached.

This mode does not require ScheduleWakeup polling on the happy path because the worker agent is a subprocess, not an independently scheduled peer.

Use `tools/chat-mode-run.ps1` for this mode:

```powershell
pwsh -NoProfile -File .\tools\chat-mode-run.ps1 `
  -NewSession `
  -Topic "<task>" `
  -TaskSummary "<ascii-task-summary>" `
  -MaxTurns 4 `
  -FirstMover claude
```

When this runner is available, do not manually roleplay the other agent. If a worker CLI cannot be invoked, stop or fall back explicitly; do not simulate worker output.

An orchestrated worker turn is complete only when:

1. The worker CLI exits with code `0`.
2. Worker stdout is non-empty after trimming whitespace.
3. Worker stdout has been appended to the session markdown.
4. Post-call `git diff --stat` and `git status --short` checks have been recorded.
5. The state file has been updated.

If any step fails, stop the session with `status=interrupted`.

## Orchestrator Rule

The agent that receives the user's chat-mode trigger owns the loop for that session.

- If the user starts with Codex, Codex is the orchestrator and Claude is the worker.
- If the user starts with Claude, Claude is the orchestrator and Codex is the worker.
- The worker must not start the other agent again.
- The worker may read files, suggest changes, or edit files only within its assigned permission profile.
- The worker must return control to the orchestrator after its round.

This prevents nested loops such as Codex starting Claude, Claude starting Codex, and Codex starting Claude again.

## Reverse Direction: Claude Invokes Codex

Claude Code can invoke Codex CLI when `codex` is installed and Claude has permission to run shell commands.

### First-Run Guardrail

The first orchestration setup should start from Codex. Codex can discover its own executable path, verify that it is the OpenAI Codex agent CLI, and write that path into a local chat-mode config.

Run from the host project:

```powershell
pwsh -NoProfile -File .\tools\chat-mode-setup.ps1
```

If the user starts from Claude before this setup exists, Claude should not guess, should not use `npx codex`, and should not continue with a simulated Codex round. It should stop and tell the user:

```text
Codex CLI path is not configured for Claude-orchestrated chat-mode.
Please run the first chat-mode setup from Codex so Codex can discover and record its CLI path.
After setup, retry from Claude.
```

Suggested local config shape:

```json
{
  "codex_exe": "C:\\Users\\user\\.vscode\\extensions\\openai.chatgpt-...\\bin\\windows-x86_64\\codex.exe",
  "claude_exe": "claude"
}
```

This config is host-local and should live under `.chat-mode/config.json`.

The setup script may also accept explicit executable paths:

```powershell
pwsh -NoProfile -File .\tools\chat-mode-setup.ps1 `
  -CodexExe "C:\path\to\codex.exe" `
  -ClaudeExe "claude"
```

Suggested read-only shape:

```powershell
& "<codex-exe>" --ask-for-approval never exec `
  -C "<repo-root>" `
  --sandbox read-only `
  "Review the current chat-mode session. Do not edit files."
```

Suggested workspace-write shape:

```powershell
& "<codex-exe>" --ask-for-approval never exec `
  -C "<repo-root>" `
  --sandbox workspace-write `
  "Continue the current chat-mode session and make only the requested edits."
```

Higher-risk options exist, including:

```powershell
& "<codex-exe>" --ask-for-approval never exec `
  -C "<repo-root>" `
  --sandbox danger-full-access `
  "<prompt>"
```

and:

```powershell
& "<codex-exe>" exec `
  -C "<repo-root>" `
  --dangerously-bypass-approvals-and-sandbox `
  "<prompt>"
```

These should not be defaults. Use them only in a deliberately isolated sandbox.

Codex worker prompts should include the same durable context as Claude worker prompts:

- The repo root.
- The session markdown path.
- The current turn number.
- The expected role for this Codex round.
- Whether Codex may edit files.
- A clear instruction not to spawn Claude or start a nested chat-mode loop.
- The required output format.

### `file-sync`

The existing protocol remains available.

1. Agents coordinate through `.chat-mode/agent-sync-state.json`.
2. Round content goes into `.chat-mode/sessions/*.md`.
3. Each agent updates ownership and schedules wakeup/polling.

This mode is useful when Codex cannot invoke Claude CLI, when Claude is running elsewhere, or when the user wants manual copy/paste control.

## Permission Profiles

Claude CLI can be started with different permissions. The orchestrator should expose profiles rather than hard-code one policy.

All profiles must run the worker CLI from the repo root. Relative state and session paths are resolved from that working directory.

Runner scripts should accept explicit executable path parameters, such as `-ClaudeExe` and `-CodexExe`, because the worker CLI may be installed but not visible in the orchestrator's `PATH`.

When Claude is the orchestrator and no verified `codex_exe` is available, the runner should stop with the first-run guardrail message instead of falling back to `npx codex` or simulating a Codex response.

All profiles must run post-call `git diff --stat` and `git status --short` checks. This is mandatory even for read-only profiles, because it is the simplest way to detect accidental or unexpected workspace mutation.

### `review`

Claude can inspect context and respond, but must not write files.

Suggested shape:

```powershell
claude -p "<prompt>" `
  --tools "Read,Glob,Grep" `
  --allowedTools "Read,Glob,Grep" `
  --permission-mode dontAsk
```

### `suggest`

Claude can propose patches or commands in text, but Codex applies any accepted changes.

Suggested shape:

```powershell
claude -p "<prompt>" `
  --tools "Read,Glob,Grep" `
  --allowedTools "Read,Glob,Grep" `
  --permission-mode dontAsk
```

The prompt should say that Claude must return proposed edits as text and must not mutate files.

`review` and `suggest` intentionally use the same read-only CLI permissions. The difference is semantic and must be enforced by the prompt and by the post-call `git diff --stat` check.

### `edit`

Claude may directly edit files in the shared working tree.

Suggested shape:

```powershell
claude -p "<prompt>" `
  --tools "Read,Glob,Grep,Edit,Write,Bash" `
  --allowedTools "Read,Glob,Grep,Edit,Write,Bash(git diff:*),Bash(git status:*)" `
  --permission-mode acceptEdits
```

This should be opt-in and should not be part of the first implementation. Codex should inspect `git diff` after the call and record Claude-authored changes in the transcript.

### `bypass` Appendix

Claude bypasses permission checks.

Suggested shape:

```powershell
claude -p "<prompt>" `
  --permission-mode bypassPermissions
```

This should not be implemented in v0.1 and should never be the default. Use it only in a deliberately isolated sandbox.

## Claude Session Handling

Codex has one conversation context with the user. Claude CLI has its own session context. Each `claude -p` invocation is a separate process, so continuity must be explicit.

Recommended state additions:

```json
{
  "orchestration_mode": "orchestrated | file-sync",
  "orchestrator_agent": "codex | claude",
  "worker_agent": "codex | claude",
  "claude_permission_profile": "review | suggest | edit | bypass",
  "claude_session_id": "UUID or null",
  "claude_resume_mode": "session-id | transcript-only",
  "claude_timeout_seconds": 300,
  "claude_last_exit_code": 0,
  "claude_last_error": null,
  "codex_permission_profile": "review | suggest | edit | bypass",
  "codex_session_id": "UUID or null",
  "codex_resume_mode": "session-id | transcript-only",
  "codex_timeout_seconds": 300,
  "codex_last_exit_code": 0,
  "codex_last_error": null
}
```

`claude_resume_mode=session-id` means Codex attempts to reuse Claude's local session context with an explicit session id. `claude_resume_mode=transcript-only` means Codex does not rely on Claude session persistence and instead reconstructs enough context from the session markdown each round.

`codex_resume_mode=session-id` means Claude attempts to reuse Codex's local session context if supported by the selected Codex CLI flow. `codex_resume_mode=transcript-only` means Claude reconstructs enough context from the session markdown each round.

### Preferred Rule

The session markdown is the source of truth. CLI-specific session persistence is an optimization.

Codex may reuse a Claude session with `--session-id` or `--resume`, but every Claude prompt should still include enough durable context to recover from a missing or stale Claude session. By default, pass the session markdown path plus the last two rounds inline. Do not pass the full transcript inline unless the session is very small.

Claude may similarly reuse a Codex session when the Codex CLI supports a suitable resume flow, but it should not rely on that as the only context.

Use [Worker Prompt Template](worker-prompt-template.md) as the canonical prompt shape for CLI worker calls.

At minimum, the prompt should identify:

- The repo root.
- The session markdown path.
- The current turn number.
- The expected role for this Claude round.
- Whether Claude may edit files.
- The required output format.

## Transcript Format

The session markdown should record both agents and subprocess metadata.

Example:

```markdown
## Round 2 - Claude

Invocation:
- mode: orchestrated
- orchestrator: codex
- worker: claude
- permission_profile: review
- session_id: 550e8400-e29b-41d4-a716-446655440000
- timeout_seconds: 300
- stdout_temp_file: .chat-mode/tmp/claude-round-2.stdout.txt
- exit_code: 0
- diff_stat_after: clean

Response:
...
```

If Claude edits files directly, Codex should append a short change summary and the relevant `git diff --stat`.

## Error Handling

- If `claude` is missing, fall back to `file-sync` or report that Claude CLI is unavailable.
- If `codex` is missing in a Claude-orchestrated session, fall back to `file-sync` or report that Codex CLI is unavailable.
- If Claude exits nonzero, append stdout/stderr references or summaries to the transcript and stop with `status=interrupted`.
- If Codex exits nonzero, append stdout/stderr references or summaries to the transcript and stop with `status=interrupted`.
- If Claude times out, stop with `status=interrupted` and `stop_reason=claude_timeout`. Default timeout: `300` seconds for `review` and `suggest`; `600` seconds for future `edit` support.
- If Codex times out, stop with `status=interrupted` and `stop_reason=codex_timeout`. Default timeout: `300` seconds for `review` and `suggest`; `600` seconds for future `edit` support.
- If the worker edits files in `review` or `suggest` mode, stop and report a permission violation.
- If worker output is empty after trimming whitespace, treat it as interrupted unless the prompt explicitly allowed empty output.
- Capture worker stdout to a temporary file before appending to the transcript. Append from that file only after the process exits successfully.
- Record the temp stdout path, exit code, timeout, and post-call diff summary in the transcript.

## Validation Plan

Test in small layers. Do not start with write-enabled profiles.

Validation steps 1 and 2 are prerequisites before implementing `tools/chat-mode-run.ps1`. Record the exact local results in [CLI Flag Validation](cli-flag-validation.md).

Before testing Claude-orchestrated Codex calls, run the first setup from Codex and write `.chat-mode/config.json` with a verified `codex_exe` path.

### 1. CLI Availability

Confirm both CLIs exist and support non-interactive execution.

```powershell
claude --version
claude --help
codex --version
codex exec --help
```

Expected result:

- `claude` supports `-p` / `--print`.
- `claude` exposes permission controls such as `--permission-mode`, `--tools`, and `--allowedTools`.
- `codex` supports `exec`.
- `codex exec` exposes `-C` and `--sandbox`.
- `codex --help` exposes top-level `--ask-for-approval`, which must be placed before `exec`.

### 2. Claude Read-Only Probe

Run Claude from the repo root with read-only tools and ask it to summarize one file.

```powershell
claude -p `
  --tools "Read,Glob,Grep" `
  --allowedTools "Read,Glob,Grep" `
  --permission-mode dontAsk `
  "Read docs/claude-cli-orchestration.md and summarize the proposed workflow. Do not edit files."
```

Then verify the workspace did not change.

```powershell
git diff --stat
git status --short
```

Expected result:

- Claude returns a non-empty response.
- No new file changes appear.

### 3. Codex Read-Only Probe

Run Codex from the repo root with read-only sandbox and ask it to summarize one file.

```powershell
codex --ask-for-approval never exec `
  -C "." `
  --sandbox read-only `
  "Read docs/claude-cli-orchestration.md and summarize the proposed workflow. Do not edit files."
```

Then verify the workspace did not change.

```powershell
git diff --stat
git status --short
```

Expected result:

- Codex returns a non-empty response.
- No new file changes appear.

### 4. Transcript Capture Probe

Before implementing a full loop, test the subprocess capture shape manually:

1. Create a temporary stdout path under `.chat-mode/tmp/`.
2. Run `claude -p` and redirect stdout to that temp file.
3. Confirm the temp file is non-empty after trimming whitespace.
4. Append the temp file content to a scratch session markdown.
5. Record `git diff --stat` after the call.

Expected result:

- Output is preserved even if transcript append is a separate step.
- The scratch transcript has invocation metadata plus worker response.

Runner scripts must create `.chat-mode/tmp/` before invoking a worker.

### 5. Permission Violation Probe

Use the read-only profile and intentionally ask Claude to edit a file.

```powershell
claude -p `
  --tools "Read,Glob,Grep" `
  --allowedTools "Read,Glob,Grep" `
  --permission-mode dontAsk `
  "Try to edit README.md by adding one sentence. This should fail or be refused because you have no write tools."
```

Expected result:

- Claude cannot edit files.
- `git diff --stat` remains unchanged.
- If any file changes, treat it as a profile failure.

### 6. Orchestrator Rule Probe

Ask the worker to continue a round but explicitly forbid nested agent spawning.

Worker prompt must include:

```text
You are the worker for this chat-mode round. Do not invoke claude, codex, or start another chat-mode loop. Return your response to the orchestrator only.
```

Expected result:

- Worker returns text only.
- Worker does not start a nested CLI call.

### 7. Timeout Probe

Use a short timeout in the future `chat-mode-run.ps1` implementation and prompt the worker to do a long task.

Expected result:

- The orchestrator stops the worker process.
- State becomes `interrupted`.
- `stop_reason` is `claude_timeout` or `codex_timeout`.
- Any captured stdout/stderr path is recorded in the transcript.

### 8. Fallback Probe

Temporarily make the worker CLI unavailable by running with a bad executable name or isolated PATH in a test script.

Expected result:

- The orchestrator does not crash.
- It reports that the worker CLI is unavailable.
- It either falls back to `file-sync` or exits with an actionable message.

### 9. First Automated Tests

After `tools/chat-mode-run.ps1` exists, add tests for:

- Missing state file.
- Missing session file.
- Worker command returns nonzero.
- Worker stdout is empty after trimming whitespace.
- Read-only worker creates no diff.
- Read-only worker mutation is detected if a fixture intentionally changes a file.
- Transcript append includes invocation metadata.
- State is updated only after transcript append succeeds.

## Open Questions

1. Should Claude's response be free-form markdown, structured JSON, or markdown plus a small metadata envelope?
2. What exact CLI flag combination is most reliable across supported Claude Code versions?
3. Should v0.1 use Claude session persistence by default, or start with `transcript-only` for determinism?
4. Should Claude-orchestrated Codex calls be implemented in this repository, or only documented as the symmetric protocol for Claude-side tooling?

## Proposed First Implementation

Start conservatively:

1. `tools/chat-mode-run.ps1` runs orchestrated sessions.
2. `tools/chat-mode-setup.ps1` writes `.chat-mode/config.json` with verified CLI paths.
3. Direct worker writes are not supported in the first pass.
4. Runner parameters may override `-ClaudeExe` and `-CodexExe`, with config lookup before `PATH` lookup.
5. Worker prompts are generated from the session markdown and [Worker Prompt Template](worker-prompt-template.md).
6. Workers run from the repo root with read-only tools and a configurable timeout.
7. Runner creates `.chat-mode/tmp/` and captures stdout/stderr there before transcript append.
8. Runner appends worker output and invocation metadata to the session markdown.
9. Runner compares `git diff --stat` and `git status --short` before and after every worker call.
10. `file-sync` and polling behavior remain available as fallback.

This gives the project a smoother default path while preserving the older distributed protocol for cases where a direct CLI subprocess is not appropriate.

`chat-mode-start.ps1` should remain bootstrap-only. `chat-mode-run.ps1` should own subprocess management, timeout handling, transcript appending, permission profiles, and recovery.

The reverse direction can use the same protocol shape, but the first implementation in this repository should focus on Codex orchestrating Claude. Claude-orchestrated Codex can be documented and validated next, ideally from a Claude-side script or prompt template.
