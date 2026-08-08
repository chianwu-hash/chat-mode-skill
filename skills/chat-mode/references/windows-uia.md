# Windows UI Automation Adapter

## Why UIA

Windows UI Automation addresses accessible controls in a background window. It does not require moving the mouse, typing into the foreground application, or reading long responses from pixels.

The 2026-08-08 smoke test confirmed these Claude Desktop patterns:

| Control | UIA type | Pattern |
| --- | --- | --- |
| Current model, such as `Sonnet 5` | Button | ExpandCollapse |
| Model option, such as `Opus 5 2` | RadioButton | SelectionItem |
| Current permission mode | Button | ExpandCollapse |
| `Manual , Always ask before making changes 1` | RadioButton | SelectionItem |
| `Allow once` | Button | Invoke |
| `Deny` | Button | Invoke |
| `Send` | Button | Invoke |
| Claude conversation | Document | Text |

Accessible names may gain numeric shortcut suffixes. Match anchored regular expressions and control types rather than assuming the suffix.

## Helper usage

Run from PowerShell 7:

```powershell
$uia = '.\skills\chat-mode\scripts\claude-desktop-uia.ps1'
```

Inspect model and mode controls:

```powershell
pwsh -NoProfile -File $uia -Action List -NameRegex 'Opus|Sonnet|Manual|Send'
```

Open the current model selector:

```powershell
pwsh -NoProfile -File $uia -Action Expand -NameRegex '^Sonnet 5$' -ControlType Button
```

Select Opus after inspecting the available options:

```powershell
pwsh -NoProfile -File $uia -Action Select -NameRegex '^Opus 5(?:\s+\d+)?$' -ControlType RadioButton
```

For a delegated isolated-implementer session, change `Manual` to `Accept edits`:

```powershell
pwsh -NoProfile -File $uia -Action Expand -NameRegex '^Manual$' -ControlType Button
pwsh -NoProfile -File $uia -Action Select -NameRegex '^Accept edits\b' -ControlType RadioButton
```

Do this after recording and reporting the exact worktree, branch, base commit, `write_scope`, and authorized actions and commands. When the user's implementation request already delegates those writes, do not ask for another confirmation. This avoids repeated file-edit prompts but does not silently expand the contract.

Restore `Manual` when the isolated session ends:

```powershell
pwsh -NoProfile -File $uia -Action Expand -NameRegex '^Accept edits$' -ControlType Button
pwsh -NoProfile -File $uia -Action Select -NameRegex '^Manual\b' -ControlType RadioButton
```

Approve an exact contract-matching prompt while in `Manual` mode:

```powershell
$promptPattern = [regex]::Escape('Allow Claude to write delegated-smoke.md?')
pwsh -NoProfile -File $uia `
  -Action ApprovePrompt `
  -TextRegex $promptPattern
```

`ApprovePrompt` fails unless exactly one currently named UIA control matches `TextRegex` and the window exposes exactly one visible, enabled `Allow once` button and one visible, enabled `Deny` button. It refuses workspace trust dialogs. Use a prompt-specific regular expression derived from the recorded contract; never pass a broad catch-all such as `.*`.

Approve workspace trust only for the exact contracted path:

```powershell
$pathPattern = [regex]::Escape('D:\projects\.chat-mode-worktrees\chat-mod-example')
pwsh -NoProfile -File $uia `
  -Action ApproveWorkspaceTrust `
  -TextRegex $pathPattern
```

This action additionally requires the accessible `Trust this workspace?` text, a unique control matching the exact path expression, exactly one `Trust Workspace` button, and exactly one `Cancel` button. A path mismatch fails closed.

Send the prefilled prompt:

```powershell
pwsh -NoProfile -File $uia -Action Invoke -NameRegex '^Send$' -ControlType Button
```

Read the complete accessible document:

```powershell
pwsh -NoProfile -File $uia -Action ReadDocument
```

Check for a completion marker without holding a single wait longer than 60 seconds:

```powershell
pwsh -NoProfile -File $uia -Action WaitText `
  -TextRegex 'CHAT_MOD_20260808_0001_DONE' `
  -TimeoutSeconds 45 `
  -PollSeconds 5
```

Repeat bounded waits while keeping the user informed.

## Fail-safe behavior

The helper fails when:

- Claude Desktop has no unique main window;
- no control matches;
- multiple controls match;
- prompt text does not match the caller's contract-specific expression;
- the expected paired deny or cancel control is absent;
- the requested UIA pattern is unsupported;
- the document or marker is unavailable;
- the timeout expires.

Inspect the accessibility tree again after Claude updates its UI. Do not substitute hard-coded coordinates silently.

## Known limits

- Codex can approve contract-matching prompts, but accessible text is an application-level guard rather than an OS security boundary.
- Claude may rename accessible controls in future releases.
- Some GPU-rendered surfaces can produce black screenshots even while UIA remains available.
- A locked Windows session, detached RDP session, or app update may suspend UIA behavior.
- UIA changes application state in the background even though it does not take foreground focus.
