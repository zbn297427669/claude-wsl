---
description: 打开或关闭 WSL 的 Claude 完成通知，选择铃声（Mail / Reminder 等），或让某个终端应用自己通知
argument-hint: on|off|toggle|status|sound|mute|unmute|apps
allowed-tools: ["Bash"]
---

```!
"$HOME/.local/share/claude-wsl/notify-ctl.sh" ${ARGUMENTS:-status}
```

把上面命令的输出用一句中文告诉用户。不要改其他文件。
