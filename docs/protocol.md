# Protocol Location

The installable, canonical protocol now lives with the skill:

- [Mailbox protocol](../skills/chat-mode/references/protocol.md)
- [Claude CLI supervisor](../skills/chat-mode/references/claude-cli.md)
- [Windows UI Automation adapter](../skills/chat-mode/references/windows-uia.md)
- [Default read-only review](../skills/chat-mode/references/review-bypass-readonly.md)
- [Desktop host setup](../skills/chat-mode/references/host-setup-delegated.md)
- [Isolated Claude implementer mode](../skills/chat-mode/references/isolated-implementer.md)
- [Direct main exclusive mode](../skills/chat-mode/references/direct-main-exclusive.md)

Keeping the protocol inside `skills/chat-mode/` ensures the installer copies every instruction required at runtime.
