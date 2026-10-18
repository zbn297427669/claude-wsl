# Notification Templates

**These files ARE used by the installer** (`lib/commands/install.js`)

## Purpose

This directory contains the actual template files that get copied during installation when users run:

```bash
npm install -g @fullstacktard/claude-wsl-integration
claude-wsl-integration install
```

## Files

### Shell Scripts

- **`notify.sh`** - Main notification hook called by Claude Code hooks
- **`notify-wrapper.sh`** - Wrapper script that routes hook events
- **`claude-notify-wrapper.sh`** - Shell integration for .bashrc
- **`config.sh`** - Configuration file for notification settings
- **`statusline.sh`** - Display-only 🔔/🔕 for Claude Code `statusLine`
- **`notify-ctl.sh`** - `/wsl-notify` on|off|toggle|status

### PowerShell Scripts

- **`send-notification.ps1`** - Windows toast notification sender

### Test Scripts

- **`test-workflow.sh`** - Manual testing script for workflow verification

## Installation Flow

1. User runs `claude-wsl-integration install`
2. Installer copies ALL files from this directory to `~/.local/share/claude-wsl/`
3. Shell scripts are made executable (chmod 755)
4. PowerShell scripts remain as-is

## Path Portability

**CRITICAL: These files must NOT contain hardcoded user paths!**

All paths should be:
- Dynamically resolved (using `$HOME`, `$PWD`, etc.)
- Passed as parameters from the installer
- Never hardcoded (like `/home/fullstacktard/`)

The installer uses `os.homedir()` and `path.join()` to construct user-specific paths.

## Testing

Portability is verified by automated tests:

```bash
npm test tests/portability.test.js
```

This test ensures:
- No hardcoded paths in any notify template files
- No user-specific directories in the code
- Installation works for any username

## See Also

- **`templates/shell-config/`** - Backup files NOT used by installer
- **`lib/commands/install.js`** - The installer that uses these templates
