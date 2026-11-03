# claude-wsl

**Visual notifications when Claude Code finishes in WSL.**

![Demo](https://vhs.charm.sh/vhs-U1KWu1eYz5Qr4lTrtT89n.gif)

spent way too long clicking between tabs to check if Claude was done processing. Windows Terminal has progress indicators and toast notifications built in, but Claude Code doesn't use them in WSL. so I fixed it.

## what this does

- **orange circle** when Claude Code is running
- **orange spinner** when Claude is processing
- **bell emoji in tab title** when Claude finishes
- **Windows toast notification** when response is ready
- **status-line lamp** (🔔 on / 🔕 off) — display only; toggle with `/wsl-notify`
- **toast sound** — `/wsl-notify sound Mail` (also IM, Reminder, SMS, Default, silent)
- **directory inheritance** for new tabs (they open where you actually are)

basically: you can work in another tab and get notified when Claude is done. no more compulsive tab checking.

## installation

```bash
npm install -g claude-wsl
claude-wsl install
```

that's it. installer hooks into Claude Code's lifecycle events and adds shell integration to your `.bashrc`. shell integration loads automatically on next terminal start.

if you already have a `statusLine` command (a pet bar, etc.), install wraps it: the existing command is saved to `~/.local/share/claude-wsl/statusline-inner` and Claude Code runs `statusline.sh` instead. lamp only, not a click target. `/wsl-notify` still toggles toasts. to point the inner command yourself:

```bash
echo '/path/to/your-statusline.sh' > ~/.local/share/claude-wsl/statusline-inner
```


## requirements

- Windows (native or WSL) — any terminal
- Claude Code installed
- Node.js 18+
- Bash shell

if you're using zsh or fish, this won't work. PRs welcome but I use bash.

## how notifications reach you

Two independent channels, so it works whichever terminal you run Claude Code in:

- **Windows toast** — delivered by PowerShell (`send-notification.ps1`) through
  WinRT. Terminal-independent and shown even when the window is focused, which
  is the only way to get a notification while you are actually looking at it.
- **Tab indicator** — OSC 9;4 (spinner / orange circle) plus the tab title.
  Under WSL this is written straight to the shell's PTY. Everywhere else the
  hook returns `{"terminalSequence": ...}` and Claude Code emits it, because
  hook stdout is piped and never reaches the terminal on its own.

Put together: native Windows and WSL behave the same, and no terminal needs to
be on a list for it to work.

On native Windows the hook is a small `notify-wrapper.cmd`. It starts Git Bash's
console-subsystem `bash.exe` with the window hidden, so a bare `.sh` command
cannot fall through to the `.sh` file association and flash a console window.
When the terminal has its own notifications (next section), the wrapper leaves
before it starts any shell at all.

### terminals with their own notifications

We never speak a terminal's private notification protocol (ELYTerminal's
OSC 7501, or OSC 777 / OSC 9 for others). Those can only fire when a program
sends them or when a command finishes, so staying silent means the terminal has
nothing to announce and cannot duplicate our toast. `indicator.sh` also skips
OSC 9;4 on terminals known to ignore it, so the sequence is not wasted.

### sound

`/wsl-notify sound Mail` (also IM, Reminder, SMS, Default, silent, Alarm, Call).
The choice is stored in `~/.local/share/claude-wsl/sound` and passed to the
toast. `silent` mutes the sound while keeping the toast.

### terminals that already notify

Some terminals announce agent completion themselves — Orca does today, and IDE
panes are moving that way. Being notified twice for one turn is worse than not
being notified, so a terminal can be muted by name:

```bash
/wsl-notify mute          # mute the terminal you are running in
/wsl-notify mute Orca     # or name it explicitly
/wsl-notify apps          # what am I running in, and what is muted
/wsl-notify unmute Orca
```

Muted means this hook steps aside completely: no toast, no bell marker, no
OSC 9;4 progress — the terminal's own notification is the only one. The list
lives in `~/.local/share/claude-wsl/mute-apps`, one app per line (`#` comments
allowed, case-insensitive), and the status-line lamp turns 🔕 so it never
claims a toast that will not arrive. `/wsl-notify off` still silences
everything regardless of the list.

The app is identified from `TERM_PROGRAM`, falling back to per-terminal
variables (`ORCA_TERMINAL_HANDLE`, `WT_SESSION`, `WEZTERM_PANE`, …). Under WSL
these come only from the Windows side, so set them in `.bashrc` to use
per-app muting there:

```bash
export WSLENV="$WSLENV:TERM_PROGRAM/u:ORCA_TERMINAL_HANDLE/u"
```

## troubleshooting

if something's not working, check [the troubleshooting guide](https://github.com/fullstacktard/claude-wsl#readme).

## license

MIT
