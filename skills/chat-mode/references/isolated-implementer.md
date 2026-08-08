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
- Let Codex handle contract-matching trust and permission dialogs; reserve user escalation for expanded or materially riskier authority.
- Bind delegated authority to one exact worktree, branch, base commit, `write_scope`, and authorized action and command set.
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

## Delegated authority contract

After preparation, record and report:

- the isolated worktree path;
- branch and base commit;
- declared `write_scope`;
- authorized actions and validation commands;
- that `Accept edits` is UI permission rather than an OS path sandbox.

The user's implementation request delegates ordinary project-local reads, in-scope writes, and necessary validation already implied by the task. Do not request a second confirmation for that same authority. Use background UIA to set the isolated Claude session to `Accept edits`, or keep `Manual` when testing prompt approval or when the contract requires per-action review.

Delegation expires when the session ends. Re-evaluate any change to the worktree, branch, base commit, scope, action set, or command set. Ask the user only when the change expands the original request or materially changes its risk.

Keep `Manual` instead when the user requests per-edit approval, secrets or production credentials are present, or the isolated worktree is not an adequate risk boundary.

Codex may approve a Claude prompt only after accessible text identifies an exact contract-matching action. Examples include an in-scope file write or a declared test command. Use the guarded UIA helper so the text check and button invocation happen in one operation.

Do not approve:

- workspace trust for a path other than the exact recorded worktree;
- Git commands assigned to Codex;
- access outside the isolated workspace;
- undeclared commands, destructive operations, credentials, production or deployment access, or unexpected network prompts.

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
authority: delegated
approval_policy: contract-matched
main_repo: <absolute-main-repo>
worktree_path: <absolute-isolated-worktree>
worktree_branch: chat-mode/claude-<session-id>
base_commit: <sha>
write_scope:
  - docs/**
  - src/**
authorized_actions:
  - read-project
  - write-scope
authorized_commands:
  - <exact-validation-command>
```

Tell Claude:

- modify only paths matched by `write_scope` inside `worktree_path`;
- treat all other paths as read-only;
- do not open or modify `main_repo`;
- do not run Git worktree, branch, commit, reset, clean, checkout, push, or force commands;
- run only the tests and build commands listed in the request;
- report changed files, commands, test results, unresolved risks, and the exact completion marker.

Open Claude Desktop Code with `folder=<worktree_path>`. If a new trust dialog appears, approve it only when its accessible path exactly matches `worktree_path`; otherwise stop.

Use `Accept edits` under the delegated contract above. When Claude still prompts, let Codex approve only exact matches and stop on ambiguity or authority expansion.

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
