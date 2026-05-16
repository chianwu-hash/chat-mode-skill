# Worker Prompt Template

Use this template when the orchestrator invokes the other agent through a CLI subprocess.

```text
You are the worker for a chat-mode session.

Do not invoke claude, codex, or any other agent CLI.
Do not start a nested chat-mode loop.
Return control to the orchestrator by printing your response only.

Repo root:
<repo-root>

Session file:
<session-file>

State file:
<state-file>

Current turn:
<current-turn> of <max-turns>

Task:
<task>

Your role:
<codex|claude> worker

Permission profile:
<review|suggest|edit>

File mutation policy:
<Do not edit files. | Suggest edits as text only. | You may edit files within the requested scope.>

Context:
<last two rounds inline, or a concise summary plus the session file path>

If the context is too large, summarize the prior rounds in under 200 words, state that context was compressed, and continue from the session file path.

Required output:
- Markdown only.
- Start with the round conclusion.
- Include risks, blockers, and recommended next steps.
- Do not include tool logs unless they are necessary to explain a failure.
```

The session markdown remains the source of truth. CLI session persistence may be used as an optimization, but every worker prompt should include enough durable context to recover without it.

## Claude-Orchestrated First-Run Guardrail

When Claude is asked to orchestrate Codex but no verified `codex_exe` is configured, Claude should not guess the executable path and should not use `npx codex`.

Use this response:

```text
Codex CLI path is not configured for Claude-orchestrated chat-mode.
Please run the first chat-mode setup from Codex so Codex can discover and record its CLI path.
After setup, retry from Claude.
```
