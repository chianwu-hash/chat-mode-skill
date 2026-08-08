# Review Bypass Read-Only Mode

## Contents

- Purpose and boundary
- Contract
- Bypass lifecycle
- Mutation check
- Failure states

Use this access profile as the default for fast Claude review and discussion. Claude Desktop runs in `Bypass permissions`, while the mailbox contract grants read-only project authority.

## Purpose and boundary

- Keep Codex as the sole project writer.
- Let Claude read, list, and search project files without permission prompts.
- Allow only declared read-only inspection commands.
- Require a clean Git worktree, named branch, and baseline commit before enabling Bypass.
- Fall back to `Manual` review when the worktree is dirty, unversioned, detached, or unusually sensitive.
- Treat any project mutation as a contract violation.
- Leave Claude in `Bypass permissions` after a successful clean review so later review sessions can reuse the state.
- Restore `Manual` on any failed or ambiguous review, or when the user explicitly requests it.

`Bypass permissions` is an application capability, not a read-only sandbox. The read-only boundary comes from the request contract, the clean baseline, and post-turn mutation inspection.

## Contract

Use an envelope such as:

```yaml
mode: review
permission: read-only
authority: delegated
approval_policy: bypass-default
edit_mode: bypass-permissions
repo_root: <absolute-repo>
repo_branch: <current-branch>
repo_head: <sha>
write_scope: []
authorized_actions:
  - read-project
  - list-and-search-project
  - inspect-git-state
authorized_commands:
  - <exact-or-bounded-read-only-command>
git_authority: read-only
network_authority: none
credential_authority: none
deployment_authority: none
external_paths: []
```

Explicitly forbid file creation or modification, Git mutation, destructive commands, network access, credentials, deployment, and paths outside the repository. Claude must respond in chat; do not authorize a response file.

## Bypass lifecycle

After writing the ignored mailbox request, capture the clean baseline and enable Bypass through the guarded action:

```powershell
pwsh -NoProfile -File .\skills\chat-mode\scripts\claude-desktop-uia.ps1 `
  -Action EnableBypass `
  -BypassContract 'review-readonly'
```

The helper accepts an already-enabled Bypass state or verifies the fixed warning and confirmation controls before enabling it. Keep the review contract read-only even though the application mode exposes broader capability.

Use Bypass across bounded turns and later clean review sessions. After a successful review, first complete the mutation check, then leave Claude in Bypass. A later `EnableBypass -BypassContract 'review-readonly'` call is an idempotent guard check and accepts the already-enabled state without opening the selector.

On failure, ambiguity, or an explicit user request for Manual, restore Manual:

```powershell
pwsh -NoProfile -File .\skills\chat-mode\scripts\claude-desktop-uia.ps1 `
  -Action DisableBypass
```

## Mutation check

Before sending, record:

- the clean `git status --porcelain=v1 --untracked-files=all` result;
- branch and `HEAD`;
- upstream ref and remote-tracking commit when configured.

After every Claude turn, verify:

- tracked and untracked project status is still clean;
- branch and `HEAD` are unchanged;
- no commit was created;
- upstream state is unchanged;
- Claude's operation log contains only authorized reads and inspections.

Ignored `.chat-mode/` request and transcript files are orchestration state, not project mutation.

## Failure states

Stop and restore Manual when:

- the worktree is not clean at baseline;
- Claude creates, modifies, deletes, renames, stages, or commits a project file;
- Claude runs an undeclared or mutating command;
- Claude accesses the network, credentials, deployment targets, external paths, nested repositories, or submodules without explicit authority;
- the Bypass dialog or mode state is ambiguous;
- the completion marker is missing or malformed;
- `.chat-mode/STOP` exists.
