---
description: 打开或关闭 WSL 的 Claude 完成通知，或选择铃声（Mail / Reminder 等）
argument-hint: on|off|toggle|status|sound
allowed-tools: ["Bash"]
---

```!
"$HOME/.local/share/claude-wsl/notify-ctl.sh" ${ARGUMENTS:-status}
```

把上面命令的输出用一句中文告诉用户。不要改其他文件。
