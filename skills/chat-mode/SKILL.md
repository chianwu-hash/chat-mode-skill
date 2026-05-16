# Skill: chat-mode

Use this skill when the user asks two coding agents, such as Codex and Claude Code, to collaborate for a bounded number of turns or a bounded time window. The skill defines a file-backed turn protocol using a shared state file, per-session markdown transcripts, ScheduleWakeup-style polling, and copyable mirrored prompts.

---

## Quick Reference

### Trigger Decision

When the user says `chat-mode`, `暢聊模式`, or asks for a bounded Codex/Claude multi-round session, this is a request to run the chat-mode protocol, not just smoke tests.

If `tools/chat-mode-run.ps1` exists, run it. Smoke tests are only verification helpers and are not a substitute for a chat-mode session.

### Preferred Local Runner

If the host project contains `tools/chat-mode-run.ps1` and the user asks for CLI orchestration or a natural-language "chat-mode" / "暢聊模式" run, the runner is mandatory:

```powershell
pwsh -NoProfile -File .\tools\chat-mode-run.ps1 `
  -NewSession `
  -Topic "<task>" `
  -TaskSummary "<ascii-task-summary>" `
  -MaxTurns 4 `
  -FirstMover codex
```

The runner invokes both worker CLIs as subprocesses, writes the transcript, and updates state. Do not simulate the other agent's rounds when the runner is available. Do not replace the runner with `tests/smoke.ps1` or `tests/run-smoke.ps1`.

If `.chat-mode/config.json` is missing, run `tools/chat-mode-setup.ps1` from Codex first. If setup cannot be run from the current agent, stop and tell the user to start setup from Codex.

If the runner fails, report the error and stop. Do not continue by roleplaying the missing worker output.

### Priority Rule

In chat-mode, polling is the primary responsibility after each round.

A round is not complete until:

1. Round content is written to the session file at `session_file`.
2. The shared state file is updated.
3. ScheduleWakeup has been scheduled.
4. The first scheduled poll has actually executed.
5. The state file and session file have been re-read after that poll.

Do not send a final or completion-style user message before step 4.
If round content is written but polling has not started, the turn is still incomplete.

### Default Layout

The companion scripts default to this host-project layout:

```text
.chat-mode/
  agent-sync-state.json
  sessions/
    YYYY-MM-DD-{slug}.md
  wakeup-logs/
```

Scripts may override paths with `-StatePath`, `-SessionDir`, and `-LogDir`.

### Round Completion Checklist

After writing round content, complete these steps in order before ending the response:

1. Write round content to the session file at `session_file`.
2. Update `current_turn`, `current_agent`, `poll_interval_seconds`, `next_check_at`, and `updated_at` in the shared state file.
3. Schedule ScheduleWakeup using the same interval as `poll_interval_seconds`.
4. Announce in commentary: `Round written. State updated. Wakeup scheduled. Entering polling loop now.`
5. If the turn limit has not been reached, start the polling retry loop and do not end the response before the first poll.
6. Re-read the shared state file and the session file at `session_file` after the first poll.
7. If the turn limit has been reached, set `status=done`, `current_agent=user`, and `stop_reason=turn_limit_reached`.

Skipping any step means the other agent cannot proceed autonomously.

---

## Activation Checklist

Activation must show the mirrored prompt before any long-running work, then continue the session in the same response when the receiving agent is the first mover. This lets the user copy the prompt immediately without delaying round 1.

### Immediate Prompt And Setup

- [ ] Parse: mode, turn/time limit, first mover, topic.
- [ ] Generate the mirrored start line and display it to the user before writing round content.
- [ ] Write the shared state file with `status: in_progress`, `current_turn: 0`, and `current_agent` set to the first mover.
- [ ] Create the session file skeleton.
- [ ] Treat setup as bootstrap only; do not imply round 1 exists until it is present in the session file.

### If This Agent Is The First Mover

- [ ] Re-read the shared state file to confirm `current_agent` is still self.
- [ ] Write round 1 content to the session file.
- [ ] Choose the next polling interval based on the next agent's expected work.
- [ ] Update `current_turn`, `current_agent`, `poll_interval_seconds`, `next_check_at`, and `updated_at` in state.
- [ ] Schedule ScheduleWakeup using the same interval as `poll_interval_seconds`.
- [ ] Announce: `Round 1 written. State updated. Wakeup scheduled. Entering polling loop now.`
- [ ] Enter the polling retry loop.

If this agent is not the first mover, end after prompt/setup. Do not write round 1 on behalf of the first mover. If a local wakeup mechanism is available, schedule a passive recheck so this agent can resume after the first mover updates state; the passive recheck must only read state/session and must not create round content until `current_agent` is self.

Do not proceed if any step cannot be completed.

---

## Mirrored-Start Rule

When the user starts a session with one agent, generate a copy-ready message for the other agent.

- Preserve the original first mover.
- Mirror only the addressee and agent names.
- Keep the user's chat-mode trigger phrase verbatim when one is provided.
- Wrap the message in a code block so it is copy-pasteable.
- Display the mirrored prompt before writing round content.

If the receiving agent is the first mover, display the mirrored prompt first, then continue in the same response to write round 1 and start polling.

---

## State File

The companion starter writes a JSON file like this:

```json
{
  "current_agent": "codex | claude | user",
  "status": "waiting | in_progress | done | interrupted",
  "task": "English one-line task summary",
  "session_file": ".chat-mode/sessions/YYYY-MM-DD-slug.md",
  "conversation_mode": "turn-based | timed | hybrid",
  "limit_minutes": null,
  "max_turns": 4,
  "current_turn": 0,
  "poll_interval_seconds": 90,
  "next_check_at": "YYYY-MM-DDTHH:MM:SS+08:00",
  "last_checked_at": "YYYY-MM-DDTHH:MM:SS+08:00",
  "started_at": "YYYY-MM-DDTHH:MM:SS+08:00",
  "stop_reason": null,
  "updated_by": "codex | claude",
  "updated_at": "YYYY-MM-DDTHH:MM:SS+08:00"
}
```

Keep all machine-oriented JSON values in English / ASCII. Put user-facing prose in the session markdown file.

---

## Polling Defaults

Choose the interval based on what the next agent is expected to do:

| Next task type | Interval | Max retries | Total wait |
| --- | --- | --- | --- |
| Trivial / acknowledgement | 60 s | 3 | about 3 min |
| Reasoning / planning | 90 s | 4 | about 6 min |
| File inspection / verify | 120 s | 4 | about 8 min |

After completing a turn, run this retry loop:

1. Choose the interval for the next agent's expected task.
2. Write `poll_interval_seconds` and `next_check_at` to state.
3. Schedule ScheduleWakeup using that same interval.
4. Announce that the wakeup is scheduled and polling is starting.
5. Wait the interval in-turn; do not end the response before polling.
6. Re-read the state file and the session file at `session_file`.
7. If `current_agent == self`, act on the session and close if the turn limit has been reached.
8. If `current_agent != self` and retry < max, increment retry and continue polling.
9. If retry == max, set `status=interrupted`, `stop_reason={agent}_timeout`, and `current_agent=user`.

Do not stop after one wait. Repeat until ownership changes or retries are exhausted.
Do not treat "round content written" as the turn boundary. Polling is the real turn boundary.
Wakeup interval must match `poll_interval_seconds`; do not use an independent timer.

Wakeup prompt pattern:

```text
[Retry N/MAX, Xs] Read the shared state file, then open session_file. If my turn, respond. If not my turn and retry < max, wait Xs and recheck. Else timeout.
```

---

## End State

When the turn limit, time limit, or manual stop is reached:

```json
{
  "status": "done",
  "current_agent": "user",
  "stop_reason": "turn_limit_reached | time_limit_reached | manual_stop"
}
```

Always reset `current_agent` to `user` when closing.

---

## Known Failure Modes

1. **Mirrored start accidentally changes first mover** - check that the mirrored message names the same first mover as the original.
2. **Mirrored start claims round 1 exists before it is written** - bootstrap only creates state and session files; the current agent must verify the session before continuing.
3. **Single wait instead of retry loop** - waiting once and reporting back to the user is not enough.
4. **Non-ASCII state JSON values** - keep task and all state fields in English / ASCII.
5. **Session closes without resetting current_agent to user** - always set `current_agent: user` on close.
6. **Polling before other agent finishes** - read the session file to confirm what was done before acting.
7. **Mistaking content completion for turn completion** - if the first poll has not run, the turn is not complete.
8. **`session_file` missing or unreadable** - stop and report; do not fall back to another file.
9. **`current_turn` in state does not match round count in session file** - report mismatch and pause for resolution; do not auto-repair.
10. **`updated_at` is stale and status is `in_progress`** - if `updated_at` is more than 30 minutes old, surface a warning before writing anything; do not treat it as an automatic stop.
11. **ScheduleWakeup fires but expected round is absent from session file** - if `current_turn` is N but the session file does not contain a completed Round N, do not infer, continue, or repair; report the mismatch and pause for resolution.
