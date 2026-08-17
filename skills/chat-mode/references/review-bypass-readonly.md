# Review Read-Only Mode

## Contents

- Purpose and boundary
- CLI contract
- Mutation check
- Desktop fallback
- Failure states

Use this profile for ordinary review and discussion. The default transport is the Claude CLI supervisor; guarded Claude Desktop Bypass is a fallback.

## Purpose and boundary

- Keep Codex as the sole project writer.
- Let Claude read, list, and search project files without shell or write tools.
- Record branch, HEAD, upstream, and `git status --porcelain=v1 --untracked-files=all` before the turn.
- Allow a pre-existing dirty baseline but reject any new Git state.
- Keep network, credentials, deployment, destructive commands, and external paths disabled unless the user's research request explicitly lists allowed public hosts.

## Confidentiality boundary

CLI review is mutation-resistant, not path-confined. `Read`, `Glob`, and `Grep` may read any file accessible to the current Windows account, including paths outside `repo_root`. Git comparison detects repository mutation but cannot prevent or detect disclosure from unrelated paths.

Disclose this residual risk once before the first review turn. Do not start the worker when the account can access unrelated secrets or sensitive files that the user has not accepted exposing to Claude. Stronger confinement requires a separate OS boundary such as a restricted account, container, or sandbox; do not imply the current supervisor provides one.

## CLI contract

Use:

```yaml
transport: claude-cli
mode: review
permission: read-only
authority: delegated
approval_policy: cli-supervised
edit_mode: dont-ask
repo_root: <absolute-repo>
repo_branch: <current-branch>
repo_head: <sha>
repo_upstream: <ref-or-empty>
repo_upstream_head: <sha-or-empty>
baseline_status: <empty-or-literal-block>
write_scope: []
authorized_actions:
  - read-project
  - list-and-search-project
authorized_commands: []
git_authority: read-only
network_authority: <none-or-explicit-public-hosts>
credential_authority: none
deployment_authority: none
external_paths: []
```

Do not put Git commands in `authorized_commands`; the supervisor captures Git state outside Claude. Review workers receive Read, Glob, and Grep only. They cannot use Bash, Edit, Write, browser, MCP, project skills, or project/local `CLAUDE.md`.

Run the supervisor as described in [claude-cli.md](claude-cli.md). The supervisor writes response and transcript artifacts under ignored `.chat-mode/`; Claude remains project-read-only.

## Mutation check

The supervisor captures Git before and after the Claude process. It rejects changes to:

- tracked or untracked status;
- branch or HEAD;
- upstream ref or remote-tracking commit.

After the run, Codex independently verifies the same fields against the request baseline. Ignored `.chat-mode/` artifacts are orchestration state, not project mutation.

The Git status check does not see arbitrary writes into other ignored paths. Review mode therefore withholds all write and shell tools; do not treat Git comparison alone as containment, and do not treat tool selection as read-path confinement.

## Desktop fallback

Use Desktop only when the user requests visibility or the CLI is unavailable after bounded recovery. Set:

```yaml
transport: desktop
approval_policy: bypass-default
edit_mode: bypass-permissions
```

Record the same baseline and authority. Enable guarded `review-readonly` Bypass through Computer Use or the exact UIA helper. Bypass is application behavior, not write authority. After a successful unchanged review, it may remain enabled; restore Manual on failure, ambiguity, mutation, or user request.

## Failure states

Stop when:

- version or subscription authentication is unavailable;
- API credential variables are present;
- the request contract or resume fingerprint changes;
- Claude output is empty, oversized, malformed, or missing its trailing marker;
- Claude attempts a tool outside Read, Glob, and Grep;
- project Git state changes;
- Claude accesses credentials, deployment targets, undeclared paths, or undeclared network hosts;
- `.chat-mode/STOP` exists.
