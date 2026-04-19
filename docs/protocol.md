# Chat-Mode Protocol

This protocol coordinates two agents through a shared state file and a per-session markdown transcript.

## Default Host Layout

```text
.chat-mode/
  agent-sync-state.json
  sessions/
    YYYY-MM-DD-{slug}.md
  wakeup-logs/
```

Scripts may override these paths with `-StatePath`, `-SessionDir`, and `-LogDir`.

## Read Order

Agents read in this order:

1. Shared state JSON
2. The markdown file pointed to by `session_file`

Round content belongs in the session file. Do not use a handoff file for active session content.

## State Fields

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

Keep state values machine-friendly and ASCII where practical. Put user-facing prose in the session markdown.

## Startup

1. Parse topic, limit, mode, and first mover.
2. Show the mirrored prompt to the user before long-running work.
3. Create the state file.
4. Create the session file skeleton.
5. If this agent is the first mover, write round 1 immediately in the same response.
6. Update state, schedule wakeup, and enter polling.

If this agent is not the first mover, stop after prompt/setup. Do not write round 1 on behalf of the first mover. If a local wakeup mechanism is available, schedule a passive recheck so this agent can resume after the first mover updates state; the passive recheck must not create round content until `current_agent` is self.

## Round Completion

After writing a round:

1. Append the round to the session file.
2. Update state ownership, turn number, timestamps, and polling fields.
3. Schedule wakeup using the same interval as `poll_interval_seconds`.
4. Run at least the first in-turn poll.
5. Re-read state and session after polling.

Round content written without polling is not a complete turn.

## Polling Defaults

| Next task type | Interval | Max retries |
| --- | --- | --- |
| Trivial / acknowledgement | 60 s | 3 |
| Reasoning / planning | 90 s | 4 |
| File inspection / verification | 120 s | 4 |

## End State

When the limit is reached:

```json
{
  "status": "done",
  "current_agent": "user",
  "stop_reason": "turn_limit_reached"
}
```

Always reset `current_agent` to `user` when closing.

## Recovery Rules

- If `session_file` is missing or unreadable, stop and report.
- If state turn count and session rounds disagree, report mismatch and pause.
- If `updated_at` is more than 30 minutes old and status is `in_progress`, surface a warning before writing; do not treat stale state as an automatic stop.
- If wakeup fires but the expected round is absent, do not infer or repair.
- If polling retries are exhausted, set `status=interrupted`, `stop_reason={agent}_timeout`, and `current_agent=user`.
