# Isolated Claude Implementer Mode

## Contents

- Invariants
- Prepare and request contract
- Handoff and inspection
- Integration and failure states

Use this mode only when the user explicitly asks Claude to create or modify many files. Keep review mode as the default.

## Invariants

- Require a Git repository, a clean main worktree, and a baseline commit.
- Create a new sibling worktree and a dedicated `chat-mode/claude-*` branch.
- Let Claude write only inside the isolated worktree.
- Do not let Codex edit tracked files in that worktree while Claude owns the turn.
- Do not let Claude access or modify the main worktree, manage worktrees, switch branches, commit, push, or invoke another agent.
- Keep trust and permission dialogs as human decisions.
- Treat edit consent as specific to one exact worktree, branch, base commit, `write_scope`, and authorized command set.
- Do not integrate changes merely because Claude produced a completion marker.

## Prepare

Choose an ASCII session id, then run:

```powershell
$helper = '.\skills\chat-mode\scripts\chat-mode-worktree.ps1'

pwsh -NoProfile -File $helper `
  -Action Prepare `
  -RepoRoot . `
  -SessionId 'feature-docs-001' `
  -WriteScope 'docs/**', 'src/**'
```

The helper fails closed when the main worktree is dirty, `.chat-mode/` is not ignored, the branch already exists, the target exists, the requested worktree is inside the main repository, or `WriteScope` is missing or unsafe.

By default it creates:

```text
<repo-parent>/.chat-mode-worktrees/<repo-name>-<session-id>/
```

with branch:

```text
chat-mode/claude-<session-id>
```

It also records `.chat-mode/session.json` inside the isolated worktree.

## Session-level edit consent

After preparation, show the user exactly:

- the isolated worktree path;
- branch and base commit;
- declared `write_scope`;
- requested validation commands;
- that `Accept edits` is UI permission rather than an OS path sandbox.

Ask once for approval of that tuple. After explicit approval, use background UIA to set the isolated Claude session to `Accept edits`. Do not require `Allow once` for every file edit.

Consent expires when the session ends or when the worktree, branch, base commit, scope, or requested command set changes. Any such change requires a new user approval.

Keep `Manual` instead when the user requests per-edit approval, secrets or production credentials are present, or the isolated worktree is not an adequate risk boundary.

Even after session consent, never auto-approve:

- workspace trust dialogs;
- shell or Git commands;
- access outside the isolated workspace;
- credential, network, deployment, or other unexpected permission prompts.

`write_scope` is enforced after changes are made. A violation makes the result ineligible for integration; it does not prove the out-of-scope write never occurred.

## Request contract

Write the request under the isolated worktree, not the main tree:

```text
<worktree>/.chat-mode/exchange/<session-id>/turn-0001.request.md
```

Use these envelope fields:

```yaml
mode: isolated-implementer
permission: isolated-write
main_repo: <absolute-main-repo>
worktree_path: <absolute-isolated-worktree>
worktree_branch: chat-mode/claude-<session-id>
base_commit: <sha>
write_scope:
  - docs/**
  - src/**
```

Tell Claude:

- modify only paths matched by `write_scope` inside `worktree_path`;
- treat all other paths as read-only;
- do not open or modify `main_repo`;
- do not run Git worktree, branch, commit, reset, clean, checkout, push, or force commands;
- run only the tests and build commands listed in the request;
- report changed files, commands, test results, unresolved risks, and the exact completion marker.

Open Claude Desktop Code with `folder=<worktree_path>`. A new worktree may produce a new trust dialog; ask the user to verify the exact path.

Use `Accept edits` only after the session-level consent above. Unexpected shell or permission dialogs still require the user.

## Handoff and inspection

After Claude emits the completion marker, freeze its turn. Do not send another prompt until inspection finishes.

Run:

```powershell
pwsh -NoProfile -File $helper `
  -Action Inspect `
  -WorktreePath '<absolute-worktree-path>'
```

Require:

- `MainStatus` remains empty;
- the branch and base commit match `.chat-mode/session.json`;
- `ScopePassed` is true and `ScopeViolations` is empty;
- `DiffCheckPassed` is true;
- no secrets, generated junk, unrelated files, nested repositories, or submodules were added;
- relevant tests pass in the isolated worktree.

Codex then reviews the full diff. A completion marker means only that Claude stopped; it is not approval to integrate.

Switch the Claude session back to `Manual` after the handoff is captured, including when inspection fails.

## Integration

Integrate only after review and within the user's original modification authority.

Preferred sequence:

1. Confirm the main worktree is still clean and based on the expected commit.
2. Preserve Claude's diff as an auditable patch or commit on the isolated branch.
3. Apply or cherry-pick into the main worktree.
4. Resolve conflicts in the main worktree, not concurrently in Claude's worktree.
5. Run the complete validation suite again from the main worktree.
6. Show the final diff to the user before any commit or push unless those actions were already requested.

Do not delete the worktree or branch automatically. Cleanup is destructive and must wait until integration is verified and the user has authorized removal.

## Failure states

Stop without integrating when:

- the main worktree changes during Claude's turn;
- Claude writes outside `write_scope`;
- branch, path, or base metadata differs;
- tests fail or cannot be reproduced;
- the diff contains unexplained generated files or secrets;
- Claude commits, pushes, rewrites history, or modifies worktree metadata;
- UIA state becomes ambiguous or the deadline expires.
