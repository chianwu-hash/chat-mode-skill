# Direct Main Exclusive Mode

## Contents

- Purpose and invariants
- Prepare and authority contract
- Bypass handoff
- Inspection and close
- Failure states

Use this mode only when the user explicitly asks Claude to operate in the current main worktree without isolation or asks for equal task-level project access. It trades containment for shared project context.

## Invariants

- Require a Git repository, clean main worktree, named branch, and baseline commit.
- Give Claude exclusive writer ownership of the main worktree for the turn.
- Freeze Codex file edits and Git operations in that worktree from handoff until inspection completes.
- Record `write_scope`, authorized commands, Git authority, network authority, credential authority, deployment authority, and external paths before handoff.
- Treat Bypass as UI permission, not an OS sandbox or unlimited authority.
- Do not infer permission to commit, push, reset, clean, deploy, use credentials, access unexpected networks, or leave the repository.
- Restore `Manual` before Codex resumes writing.

Equal assistant access means Codex and Claude may receive equivalent authority from the user's task. It does not mean concurrent writes or self-expansion of authority. Codex remains the chat-mode orchestrator and ownership transfers serially.

## Prepare

Run:

```powershell
$direct = '.\skills\chat-mode\scripts\chat-mode-direct-main.ps1'

pwsh -NoProfile -File $direct `
  -Action Prepare `
  -RepoRoot . `
  -SessionId 'direct-feature-001' `
  -WriteScope '**'
```

The helper fails closed for a dirty worktree, detached HEAD, missing `.chat-mode/` ignore rule, unsafe scope, or another active direct session. It records:

- repository and selected worktree path;
- branch and baseline commit;
- upstream ref and current remote-tracking commit when configured;
- write scope and exclusive writer;
- creation time.

It writes ignored active metadata to:

```text
.chat-mode/direct-main.active.json
```

## Authority contract

Use an envelope such as:

```yaml
mode: direct-main-exclusive
permission: direct-main-write
authority: delegated
approval_policy: bypass-explicit
edit_mode: bypass-permissions
repo_root: <absolute-main-repo>
worktree_path: <absolute-main-repo>
worktree_branch: <current-branch>
base_commit: <sha>
write_scope:
  - '**'
authorized_actions:
  - read-project
  - write-scope
authorized_commands:
  - <exact-or-bounded-command>
git_authority: <none-or-explicit-actions>
network_authority: <none-or-explicit-hosts-and-actions>
credential_authority: <none-or-explicit-use>
deployment_authority: <none-or-explicit-target>
external_paths: []
```

Full project access normally means `write_scope: ['**']`; it does not include paths outside the repository. State broader machine access separately and explicitly.

The request must tell Claude that Codex has frozen its writes, identify every allowed Git or external action, require a complete operation log, and include a unique completion marker.

## Bypass handoff

Open Claude Desktop Code with `folder=<repo_root>`. Approve workspace trust only when the accessible path exactly matches `repo_root`.

Enable Bypass through the guarded action:

```powershell
pwsh -NoProfile -File .\skills\chat-mode\scripts\claude-desktop-uia.ps1 `
  -Action EnableBypass `
  -BypassContract 'direct-main-exclusive'
```

The helper requires the accessible Bypass option, the `Bypass all permissions?` dialog, Claude's fixed warning about destructive commands, one Cancel button, and one Bypass confirmation button. Stop if any element is absent or ambiguous.

Do not edit the selected worktree while Claude owns it. Monitoring, UIA control, read-only Git inspection after the marker, and user updates remain allowed.

## Inspection and close

After the marker, freeze Claude and restore Manual first:

```powershell
pwsh -NoProfile -File .\skills\chat-mode\scripts\claude-desktop-uia.ps1 `
  -Action DisableBypass
```

Inspect before any Codex mutation:

```powershell
pwsh -NoProfile -File $direct -Action Inspect -RepoRoot .
```

Review:

- every tracked and untracked path since `base_commit`;
- `ScopePassed`, `ScopeViolations`, and `DiffCheckPassed`;
- current branch and `BranchChanged`;
- current HEAD, `HeadChanged`, and commits since baseline;
- upstream ref/head and `UpstreamChanged`;
- complete diff, test results, secrets, generated files, submodules, and nested repositories.

Reject or escalate any change not authorized by the original request. A marker is handback, not acceptance.

After inspection is recorded, archive and close the session:

```powershell
pwsh -NoProfile -File $direct `
  -Action Close `
  -RepoRoot . `
  -SessionId 'direct-feature-001'
```

Close archives metadata and inspection under `.chat-mode/sessions/`; it does not modify, revert, commit, push, or delete project changes.

## Failure states

Stop before Codex resumes writing when:

- Claude has not returned to `Manual`;
- UIA state, marker, branch, HEAD, upstream, or operation log is ambiguous;
- changes leave `write_scope` or the repository without explicit authority;
- Git, network, credential, deployment, or destructive actions exceed the contract;
- diff inspection fails, secrets appear, or validation cannot be reproduced;
- `.chat-mode/STOP` exists.
