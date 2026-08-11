# Review Bypass Read-Only Mode

## Contents

- Purpose and boundary
- Contract
- Bypass lifecycle
- Mutation check
- Failure states

Use this access profile by default for ordinary review/discussion. Claude Desktop runs in `Bypass permissions`, while the mailbox contract grants read-only project authority and Computer Use keeps the visible workspace and permission state auditable. Use `Manual` only when the user explicitly requests per-action approval, the workspace or Bypass state cannot be verified, or a failed/ambiguous session requires safe recovery.

## Purpose and boundary

- Keep Codex as the sole project writer.
- Let Claude read, list, and search project files without permission prompts.
- Allow only declared read-only inspection commands.
- Enable guarded Bypass for review only after recording the baseline, even when the repository already has dirty files; dirty status is baseline evidence, not authority.
- Record branch, HEAD, upstream state when available, and `git status --porcelain=v1 --untracked-files=all` before sending.
- Treat any new project mutation relative to the recorded baseline as a contract violation.
- Leave guarded Bypass enabled after a successful ordinary review once the mutation check passes.
- Restore `Manual` only on a failed or ambiguous review, an unverifiable workspace/permission state, or when the user explicitly requests per-action approval.

`Bypass permissions` is an application capability, not a read-only sandbox. The read-only boundary comes from the request contract, baseline status, and post-turn mutation inspection.

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
network_authority: <none-or-explicit-allowed-public-hosts>
credential_authority: none
deployment_authority: none
external_paths: []
```

Explicitly forbid file creation or modification, Git mutation, destructive commands, credentials, deployment, and undeclared paths or network access. Default network authority to `none`; when the user's task explicitly requires public-web research, list the allowed public hosts in the request. Claude must respond in chat; do not authorize a response file.

## Bypass lifecycle

After writing the ignored mailbox request, capture the current baseline and enable Bypass through the guarded action:

```powershell
pwsh -NoProfile -File .\skills\chat-mode\scripts\claude-desktop-uia.ps1 `
  -Action EnableBypass `
  -BypassContract 'review-readonly'
```

The helper accepts an already-enabled Bypass state or verifies the fixed warning and confirmation controls before enabling it. Keep the review contract read-only even though the application mode exposes broader capability.

After a successful review, first complete the mutation check, then leave guarded Bypass enabled as the ordinary review default. Restore `Manual` only for the documented exception states.

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

- tracked and untracked project status matches the recorded baseline except for ignored `.chat-mode/` orchestration files;
- branch and `HEAD` are unchanged;
- no commit was created;
- upstream state is unchanged;
- Claude's operation log contains only authorized reads and inspections.

Ignored `.chat-mode/` request and transcript files are orchestration state, not project mutation.

## Failure states

Stop and restore Manual when:

- the baseline cannot be recorded or compared;
- Claude creates, modifies, deletes, renames, stages, or commits a project file;
- Claude runs an undeclared or mutating command;
- Claude accesses credentials, deployment targets, external paths, nested repositories, submodules, or network hosts without explicit authority;
- the Bypass dialog or mode state is ambiguous;
- the completion marker is missing or malformed;
- `.chat-mode/STOP` exists.
