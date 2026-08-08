# Claude Desktop Background UIA Smoke Test

- Date: 2026-08-08
- Platform: Windows 11
- Repository: `D:\projects\chat-mod`
- Claude configuration: Opus 5, High effort, Manual mode
- Result: passed

## Goal

Test whether Codex can open the same local project in Claude Desktop Code, send a bounded architecture-review request, and retrieve Claude's complete response without occupying the foreground desktop.

The request explicitly prohibited edits, destructive commands, commits, and pushes. It required the final marker `CHAT_MOD_SMOKE_DONE`.

## What happened

1. Codex opened a Claude Code deep link containing the repository path and a prefilled prompt.
2. Claude displayed `Trust this workspace?` for `D:\projects\chat-mod`.
3. The user verified the path and clicked `Trust Workspace` manually.
4. The bundled Computer Use API could list the Claude window, but state and action calls failed with `node_repl exec context not found`.
5. A background `PrintWindow` capture initially confirmed the project and prefilled prompt. Later GPU captures returned a black image, showing that screenshot capture was not reliable enough for the transport.
6. Codex switched to native Windows UI Automation through `System.Windows.Automation`.
7. UIA discovered the live Claude controls and their supported patterns:
   - current model button: `ExpandCollapse`;
   - `Opus 5` radio option: `SelectionItem`;
   - permission-mode button and `Manual` option: `ExpandCollapse` and `SelectionItem`;
   - `Send` button: `Invoke`;
   - conversation document: `TextPattern`.
8. Codex selected Opus 5, preserved High effort, changed `Accept edits` to `Manual`, and invoked `Send` while Claude remained in the background.
9. Claude inspected the repository read-only, produced its review, and ended with `CHAT_MOD_SMOKE_DONE`.
10. Codex extracted the complete 8,027-character accessible document with `TextPattern.DocumentRange.GetText(-1)`.

No project files were changed during the live discussion.

## Claude's design review

Claude judged the coordination concept feasible but warned against placing pixel-based Computer Use on the content path. Its main recommendation was:

> Demote Computer Use from transport to doorbell.

The proposed direction is:

- store durable requests and transcripts in a filesystem mailbox;
- use the GUI only to open Claude, point it at a request, send, and detect completion;
- prefer UIA text over screenshots or OCR when reading chat responses;
- allow only Codex to modify tracked project files;
- never auto-click permission dialogs;
- bound turns, response size, and wall-clock time;
- provide a `STOP` file checked before every action;
- initialize Git and create a baseline commit before allowing either agent to edit;
- test the mailbox independently before depending on GUI automation;
- measure at least 20 consecutive automated pokes and treat less than roughly 95% success as a reliability warning.

## Conclusions adopted by the repository

1. The old root `tools/` PowerShell CLI runner and polling state machine are retired.
2. Windows UI Automation is the preferred Claude Desktop control plane.
3. Files are the durable request and transcript transport.
4. UIA document text is the tested default response path; an exchange response file is optional and requires explicit write authorization.
5. Trust and permission dialogs remain human checkpoints.
6. Coordinate clicking and OCR are last-resort visible fallbacks, never silent defaults.
7. The protocol is bounded and fail-closed: ambiguous UI, unexpected mutation, missing markers, timeouts, or `.chat-mode/STOP` end the run.

## Follow-up validation

- Run the mailbox contract against a fake worker without Claude Desktop.
- Repeat one-turn background UIA runs 20 times and record success rate and failure causes.
- Test locked screen, detached remote desktop, app update, focus stealing, oversized output, and malformed markers.
- Validate the optional file-response path separately before making it the default.
