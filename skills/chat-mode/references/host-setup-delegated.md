# Host Setup Delegated Mode

## Contents

- Purpose and boundary
- Contract
- Bypass lifecycle
- Host setup checks
- Failure states

Use this access profile when the user explicitly asks Claude to perform machine-level setup, such as installing a Claude plugin, configuring a local tool, or validating a host integration. It is not the default review profile and it is not an implementation mode for project files.

## Purpose and boundary

- Let Claude execute a small, exact set of setup commands without repeated permission prompts.
- Keep repository files contractually read-only; Codex remains the sole project writer.
- Allow only declared non-secret config writes and declared network hosts needed for the setup.
- Keep credentials, API keys, remote access URLs, passwords, tokens, and private keys out of Claude chat, request files, transcripts, Memory, and repo docs.
- Let the user enter secrets directly into a local UI or local command prompt when needed.
- Let Codex take over actions Claude cannot perform, such as closing or restarting Claude itself.
- Require a clean Git worktree, named branch, and baseline commit so project mutation is detectable.
- Restore `Manual` when the chat-mode session ends.

`Bypass permissions` is an application capability, not a host sandbox. The setup boundary comes from the request contract, exact command list, credential boundary, clean project baseline, and post-turn inspection.

## Contract

Use an envelope such as:

```yaml
mode: host-setup-delegated
permission: host-setup
authority: delegated
approval_policy: bypass-host-setup
edit_mode: bypass-permissions
repo_root: <absolute-repo>
repo_branch: <current-branch>
repo_head: <sha>
write_scope: []
setup_scope:
  - install-claude-code-plugin
  - verify-plugin-status
authorized_actions:
  - read-project
  - list-and-search-project
  - inspect-git-state
  - run-declared-setup-commands
  - write-declared-non-secret-config
  - verify-host-tool-status
authorized_commands:
  - <exact setup command>
allowed_config_paths:
  - <exact non-secret config path or directory>
git_authority: read-only
network_authority:
  allowed_hosts:
    - <host needed for plugin download>
credential_authority: user-handled-only
deployment_authority: none
external_paths:
  - <exact host setup path when needed>
restart_authority:
  claude_self_restart: codex-or-user
  other_apps: <none-or-exact-app>
max_response_bytes: 50000
deadline: 2026-08-08T03:48:00Z
completion_marker: CHAT_MOD_20260808_HOST_SETUP_DONE
---
```

Follow the envelope with:

1. exact setup objective;
2. current host facts already verified by Codex;
3. commands Claude may run, exactly as allowed;
4. non-secret config files Claude may inspect or write;
5. explicit credential handling instructions;
6. smoke tests and required output;
7. the instruction to end with the exact completion marker.

## Credential Boundary

Use `credential_authority: user-handled-only` unless the user explicitly defines a narrower non-secret credential workflow. Claude must not ask the user to paste secrets into chat. Claude must not echo, summarize, redact-and-store, or write secrets into any file. If a setup step needs an Access Anywhere URL, API key, password, token, private key, or one-time code, Claude must stop at that step and ask the user or Codex to complete it outside the transcript.

Allowed examples:

- "Open Nowledge Mem settings and paste the API key yourself, then tell me done."
- "Run this command locally after replacing the placeholder yourself."
- "I can verify `nmem status` after you finish the secret entry."

Forbidden examples:

- "Paste the API key here."
- "I will write the API key into the request file."
- "I will print the URL/key so Codex can verify it."

## Bypass lifecycle

After writing the ignored mailbox request, capture the clean baseline and enable Bypass through the guarded action:

```powershell
pwsh -NoProfile -File .\skills\chat-mode\scripts\claude-desktop-uia.ps1 `
  -Action EnableBypass `
  -BypassContract 'host-setup-delegated'
```

The helper accepts an already-enabled Bypass state or verifies the fixed warning and confirmation controls before enabling it. The broad application warning does not expand authority beyond the setup contract.

At session close, restore Manual:

```powershell
pwsh -NoProfile -File .\skills\chat-mode\scripts\claude-desktop-uia.ps1 `
  -Action DisableBypass
```

If Claude must be closed or restarted, Codex or the user performs that step after recording it in the transcript. Claude should not attempt to restart itself in a way that loses the handback.

## Host setup checks

Before sending, record:

- clean `git status --porcelain=v1 --untracked-files=all`;
- branch and `HEAD`;
- upstream ref and remote-tracking commit when configured;
- exact setup commands;
- exact non-secret config paths;
- allowed network hosts;
- credential boundary;
- restart authority.

After every Claude turn, verify:

- tracked and untracked project status is still clean;
- branch and `HEAD` are unchanged;
- no commit was created;
- upstream state is unchanged;
- Claude ran only the declared setup commands;
- network access stayed within declared hosts;
- only declared non-secret host config changed;
- no secret-like value appeared in the request, transcript, response file, or repo docs;
- smoke tests match the requested setup outcome.

Ignored `.chat-mode/` request and transcript files are orchestration state, not project mutation.

## Failure states

Stop and restore Manual when:

- the worktree is not clean at baseline;
- Claude creates, modifies, deletes, renames, stages, or commits a project file;
- Claude runs an undeclared, destructive, deployment, Git-mutating, or broad shell command;
- Claude requests or exposes credentials, remote access URLs, API keys, passwords, tokens, private keys, or one-time codes;
- Claude accesses an undeclared network host or external path;
- Claude tries to change Windows security or privacy settings;
- a required secret-entry step cannot be completed outside the transcript;
- the Bypass dialog or mode state is ambiguous;
- the completion marker is missing or malformed;
- `.chat-mode/STOP` exists.
