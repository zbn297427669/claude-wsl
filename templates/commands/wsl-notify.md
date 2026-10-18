---
description: 打开或关闭 WSL 的 Claude 完成通知（Windows toast + 标签指示）
argument-hint: on|off|toggle|status
allowed-tools: ["Bash"]
---

```!
"$HOME/.local/share/claude-wsl/notify-ctl.sh" ${ARGUMENTS:-status}
```

把上面命令的输出用一句中文告诉用户。不要改其他文件。
