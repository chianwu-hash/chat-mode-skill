# Review Bypass Read-Only Smoke Test - 2026-08-08

## Result

Passed on Windows with Claude Desktop Code, Opus 5, and High effort. Chat-mode enabled `Bypass permissions` under a `review-readonly` contract, Claude completed a project-reading task without permission prompts, and Codex restored `Manual` before accepting the result.

## Contract

```text
repo:          D:\projects\chat-mode-review-bypass-live-20260808
branch:        main
baseline HEAD: 36e291e8ffcc88470628b6f509cb11d9e15c204e
permission:    read-only
write_scope:   []
commands:      none
Git mutation:  none
network:       none
credentials:   none
deployment:    none
external paths:none
```

Claude was authorized to read `README.md`, add the values `alpha: 7` and `beta: 11`, report the result, and return `CHAT_MOD_REVIEW_BYPASS_20260808_DONE`. The contract prohibited every file mutation and command.

## Procedure

1. Codex created a clean temporary Git repository and recorded branch, HEAD, status, actions, and authorities.
2. A Claude Code deep link opened the exact repository with a mailbox pointer.
3. Codex approved `Trust this workspace?` only after matching the exact accessible path.
4. Codex enabled Bypass through `EnableBypass -BypassContract review-readonly` and invoked the named Send control.
5. `WaitText` required two marker matches so the marker echoed in the request could not signal completion.
6. Claude read the request and `README.md`, reported `7 + 11 = 18`, reported no commands or mutations, and returned the marker.
7. Codex restored `Manual` and independently compared repository status, branch, HEAD, and commits with the clean baseline.

## UIA compatibility finding

The current Claude Desktop build sometimes reports a permission selector as expanded after its popup has disappeared, and sometimes ignores `ExpandCollapse.Expand()` while genuinely collapsed. The helper now:

- cycles stale expanded state through `Collapse` then `Expand`;
- searches top-level UIA popups belonging to Claude processes;
- falls back to one Space key only after exact element name, Button type, Claude PID, focused element, native window handle, and existing foreground checks;
- accepts either the fully verified warning modal or an exact `Bypass permissions` mode transition when Claude has already recorded the warning acknowledgement;
- fails closed on every ambiguity.

No coordinate click or unguarded input was used. Repeated Manual → Bypass → Manual tests passed after the fix.

## Independent inspection

```text
git status entries: 0
branch:             main
HEAD:               36e291e8ffcc88470628b6f509cb11d9e15c204e
new commits:        0
final Claude mode:  Manual
```

## Conclusion

Claude can use Bypass as the default permission UI for fast read-only review without turning review into write authority. This is contractual read-only rather than OS-enforced read-only, so chat-mode requires a clean baseline, forbids mutation explicitly, restores Manual, and rejects any changed Git state.

The temporary repository remains preserved for inspection. No cleanup, commit beyond its baseline, push, network access, or deployment occurred.
