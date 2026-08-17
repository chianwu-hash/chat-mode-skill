# Claude CLI Supervisor

## Contents

- Purpose and requirements
- Invocation model
- Tools and permissions
- Session memory
- Artifacts and completion
- Failure states and limits

## Purpose and requirements

Use `scripts/claude-cli-supervisor.ps1` as the only supported `claude -p` entrypoint for chat-mode. It replaces the Desktop transport for review and isolated implementation while preserving the mailbox, authority envelope, STOP file, Git baselines, worktree helpers, transcript, and handback inspection.

Requirements:

- Claude Code 2.1.233 or newer;
- `claude auth status` reports `authMethod: claude.ai` and a subscription type;
- `ANTHROPIC_API_KEY` and `ANTHROPIC_AUTH_TOKEN` are absent;
- the request lives under the selected tree at `.chat-mode/exchange/<session-id>/turn-<id>.request.md`;
- `.chat-mode/` is ignored by Git;
- mode is `review` or `isolated-implementer`.

Do not use `--bare`. Bare mode avoids Claude configuration discovery but skips subscription OAuth and therefore requires API billing. The supervisor uses `--setting-sources user` so project/local `CLAUDE.md`, rules, skills, hooks, and settings are not loaded while the user's authenticated subscription remains available.

The supervisor also passes `--strict-mcp-config`, `--disable-slash-commands`, and `--no-chrome`. It supplies no MCP configuration, so project MCP servers are not started.

## Invocation model

Check readiness:

```powershell
pwsh -NoProfile -File .\skills\chat-mode\scripts\claude-cli-supervisor.ps1 `
  -Action Status `
  -WorkingTree '<absolute-working-tree>'
```

Run a turn:

```powershell
pwsh -NoProfile -File .\skills\chat-mode\scripts\claude-cli-supervisor.ps1 `
  -Action Invoke `
  -WorkingTree '<absolute-working-tree>' `
  -RequestPath '<absolute-request-path>' `
  -TimeoutSeconds 300 `
  -ClaudeEffort medium `
  -IdleWarningSeconds 90 `
  -MaxResponseBytes 50000 `
  -MaxAgentTurns 12 `
  -ShowConversationViewer
```

The supervisor launches one Claude CLI process, captures stderr, parses stdout as newline-delimited `stream-json`, polls `.chat-mode/STOP`, and kills the child process tree on STOP or timeout. Ordinary review uses `medium` effort with a 300-second ceiling. Explicit deep review uses `-ClaudeEffort high -TimeoutSeconds 600 -IdleWarningSeconds 150`. Idle warning thresholds affect status only; they never kill the process. The supervisor retains only the final result line in memory, appends assistant text deltas to `live.md`, and records sanitized event activity separately.

`-ShowConversationViewer` opens a separate read-only Windows Terminal window for the current turn. It shows the request first, tails `live.md`, and renders only sanitized states and counters: running, idle-warning, stopped-timeout, stopped-user, failed, or completed. It never shows tool arguments, file names, raw JSON, or reasoning text. After completion it stays open until Enter. Set `-ViewerHoldSeconds` only for an explicit timed close.

## Tools and permissions

### Review

The supervisor passes:

```text
--permission-mode dontAsk
--tools Read,Glob,Grep
--allowedTools Read,Glob,Grep
```

Claude receives no Edit, Write, Bash, browser, MCP, or project skill tool. The supervisor snapshots Git before and after the run and rejects any branch, HEAD, upstream, tracked, or untracked status change. Ignored `.chat-mode/` artifacts do not affect the snapshot.

### Isolated implementer

The supervisor passes:

```text
--permission-mode acceptEdits
--tools Read,Glob,Grep,Edit,Write[,Bash]
```

Edit and Write are allowed only because the working tree is the dedicated isolated worktree. Bash is exposed only when `authorized_commands` contains a real command, and each listed command becomes an allowed `Bash(<command>)` rule. Do not list broad shells, interpreters, command separators, encoded commands, agent CLIs, or Git mutation commands.

CLI permission rules are not an OS sandbox. After the marker, always run `chat-mode-worktree.ps1 -Action Inspect` and reject out-of-scope changes. The main worktree must remain clean.

## Session memory

The first successful turn stores Claude's `session_id` plus a SHA-256 fingerprint of the authority contract. The fingerprint includes:

- protocol and chat-mode session ID;
- mode, permission, authority, approval, and edit mode;
- repository/worktree paths, branches, HEAD/base commit;
- write scope and setup scope;
- authorized actions and commands;
- allowed config paths;
- Git, network, credential, deployment, external-path, and restart authority.

It excludes `turn_id`, deadline, response-size limit, intent, and completion marker so a later turn can change its question and marker without laundering authority.

Use `-Resume` only after a successful prior turn with the same chat-mode `session_id` and unchanged contract. Failure invalidates session state. Timeout retry must use a new chat-mode session ID with narrower scope; provisional IDs observed before a final result are never valid resume state.

Do not use `--continue`, an unqualified `--resume`, or a session selected from Claude's interactive history. Resume only the exact ID recorded by the supervisor.

## Artifacts and completion

For session `<session-id>` and turn `<turn-id>`, the supervisor writes:

```text
.chat-mode/sessions/<session-id>/claude-cli-state.json
.chat-mode/sessions/<session-id>/turn-<turn-id>.live.md
.chat-mode/sessions/<session-id>/turn-<turn-id>.status.json
.chat-mode/sessions/<session-id>/turn-<turn-id>.response.md
.chat-mode/sessions/<session-id>/turn-<turn-id>.run.json
.chat-mode/sessions/<session-id>.md
```

`claude-cli-state.json` holds the fingerprint and a `resumable` flag. `live.md` is non-authoritative text output. `status.json` atomically records sanitized state, elapsed/activity timestamps, event counts, and advisory Read-call counts. `run.json` is always written after process start: success records include the validated Claude session ID; failure records include the exact stop reason, last activity, Git snapshots, and only a provisional unvalidated ID when available.

Codex may read the new tail of `live.md` during bounded waits and relay brief excerpts to the user. Never relay raw NDJSON, tool arguments, repeated spans, or partial text as a completed conclusion. The final `response.md` is written only after the final result passes all validation.

A turn completes only when:

- process exit is successful and Claude does not report `is_error`;
- response is nonempty and within the byte limit;
- response ends with the exact marker;
- Claude session ID is present and stable on resume;
- review Git state is unchanged;
- artifacts are written successfully;
- isolated handback later passes scope and diff inspection.

## Failure states and limits

Classify and stop on:

```text
version_too_old
auth_required
user_stop
timeout
response_too_large
malformed_response
claude_error
unexpected_mutation
write_scope_violation
handoff_rejected
```

Authentication status can report logged-in while saved OAuth is expired. Claude Code 2.1.233 fails this quickly; tell the user to run `claude auth login` and retry the same contract. Never set an API key as a workaround.

Expired-login classification currently depends on matching `authenticate`, `OAuth`, or `login` in Claude's error result. If future Claude Code wording changes, the supervisor may report `claude_error` instead of `auth_required`; inspect the returned message before retrying or changing transport.

On the validated Windows host, `Get-Command claude` resolves to the npm `claude.ps1` shim and the supervisor launches it through `pwsh -File`. Other npm or PATH configurations may resolve differently; verify with `-Action Status` and use the explicit `-ClaudeExe`/`-ClaudeArgsPrefix` escape hatch only for a known local shim.

The authoritative response-size check still occurs against the final result after stdout completes. Live text stops appending at the same byte threshold and records a truncation notice. Read counts are advisory because the transport cannot guarantee exact tool-result byte visibility. Collect real successful and failed idle-gap distributions before considering any idle-based kill policy.

Use Claude Desktop when the task needs visible secret entry, out-of-repository machine setup, or explicit direct-main-exclusive authority. Do not run Desktop and CLI writers concurrently in one worktree.
