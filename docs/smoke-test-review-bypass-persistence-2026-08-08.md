# Review Bypass Persistence Smoke Test — 2026-08-08

## Result

Passed on Windows with Claude Desktop Code. The guarded `review-readonly` action enabled `Bypass permissions`, a second guarded call reused the already-enabled state without another selector transition, and the successful close deliberately did not call `DisableBypass`.

## Baseline

- Repository: `D:\projects\chat-mode-review-bypass-live-20260808`
- Branch: `main`
- HEAD: `36e291e8ffcc88470628b6f509cb11d9e15c204e`
- Status: clean
- Initial Claude permission mode: `Manual`

## Procedure

1. Record the clean repository status, named branch, HEAD, and latest commit.
2. Run `EnableBypass -BypassContract 'review-readonly'`.
3. Observe the helper fail closed when Claude is not foreground and its guarded keyboard fallback would otherwise be required.
4. Activate the exact Claude packaged-app ID, then repeat the guarded action without using screen coordinates.
5. Run the same guarded action again to model the start of a later review session.
6. Verify the second call reports `already enabled: Bypass permissions (review-readonly)`.
7. Inspect the permission control and confirm it remains `Bypass permissions`.
8. Recheck repository status, branch, HEAD, and latest commit.
9. End the successful review lifecycle without calling `DisableBypass`.

## Verification

- Claude final permission mode: `Bypass permissions`
- Repeated enable action: idempotent
- Permission dialog or repeated mode transition on reuse: none
- Repository status: clean
- Branch: unchanged
- HEAD and latest commit: unchanged
- Coordinates used: none

## Conclusion

A successful clean `review-readonly` close can safely retain the Claude application mode for later reviews. The mailbox contract and Git baseline still enforce read-only authority; persistent Bypass changes only the permission-prompt lifecycle. Failures, ambiguity, contract violations, host setup, and implementation handback still restore `Manual`.
