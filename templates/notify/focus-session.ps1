# focus-session.ps1
# Protocol handler for claude-wsl://focus?hwnd=...&sid=...
# ASCII-only: Windows PowerShell 5.1 misreads UTF-8-without-BOM.
param([string]$Uri)

Add-Type @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
public static class WslFocus {
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int n);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern int GetWindowTextLength(IntPtr h);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr extra);
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);

    const int SW_RESTORE = 9;
    const int SW_SHOW = 5;
    const uint KEYEVENTF_KEYUP = 2;
    const byte VK_MENU = 0x12;

    // Deny-list rather than allow-list: a new terminal must not need a code
    // change to be focusable. These are processes that never own the window we
    // want (our own helpers, the console host, and Claude Code itself).
    static readonly HashSet<string> Skip = new HashSet<string>(StringComparer.OrdinalIgnoreCase) {
        "powershell", "pwsh", "WindowsPowerShell", "wscript", "cscript",
        "conhost", "OpenConsole", "cmd", "conime",
        "claude", "claude-2.1.310-win32-x64", "node"
    };

    // Known terminal host window classes, used to pick a fallback window.
    static readonly HashSet<string> TerminalClasses = new HashSet<string>(StringComparer.OrdinalIgnoreCase) {
        "CASCADIA_HOSTING_WINDOW_CLASS", "ConsoleWindowClass", "mintty",
        "org.wezfurlong.wezterm", "GLFW30", "Alacritty", "VirtualConsole",
        "TabbyWndClass", "Chrome_WidgetWin_1", "SunAwtFrame"
    };

    static string ProcName(IntPtr h) {
        uint pid;
        GetWindowThreadProcessId(h, out pid);
        if (pid == 0) return "";
        try { return Process.GetProcessById((int)pid).ProcessName; }
        catch { return ""; }
    }

    public static bool IsAlive(IntPtr h) {
        return h != IntPtr.Zero && IsWindow(h);
    }

    public static void Force(IntPtr hWnd) {
        if (!IsAlive(hWnd)) return;
        if (IsIconic(hWnd)) ShowWindow(hWnd, SW_RESTORE);
        IntPtr fg = GetForegroundWindow();
        uint pid;
        uint fgThread = GetWindowThreadProcessId(fg, out pid);
        uint thisThread = GetCurrentThreadId();
        bool attached = false;
        if (fgThread != 0 && fgThread != thisThread) {
            attached = AttachThreadInput(thisThread, fgThread, true);
        }
        keybd_event(VK_MENU, 0, 0, UIntPtr.Zero);
        SetForegroundWindow(hWnd);
        BringWindowToTop(hWnd);
        ShowWindow(hWnd, SW_SHOW);
        keybd_event(VK_MENU, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
        if (attached) AttachThreadInput(thisThread, fgThread, false);
    }

    static string ClassName(IntPtr h) {
        var sb = new StringBuilder(256);
        GetClassName(h, sb, 256);
        return sb.ToString();
    }

    // A stored HWND can be stale or belong to a different app by the time the
    // toast is clicked; only raise it if it still looks like a user window we
    // did not exclude.
    public static bool IsUsable(IntPtr h) {
        if (!IsAlive(h) || !IsWindowVisible(h)) return false;
        string n = ProcName(h);
        if (string.IsNullOrEmpty(n) || Skip.Contains(n)) return false;
        if (GetWindowTextLength(h) > 0) return true;
        return TerminalClasses.Contains(ClassName(h));
    }

    public static IntPtr FirstTerminal() {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) => {
            if (!IsWindowVisible(h)) return true;
            string n = ProcName(h);
            if (string.IsNullOrEmpty(n) || Skip.Contains(n)) return true;
            if (TerminalClasses.Contains(ClassName(h))) { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }
}
'@

function Get-StoredHwnd([string]$Sid) {
    if ([string]::IsNullOrWhiteSpace($Sid)) { return [IntPtr]::Zero }
    $Sid = ($Sid -replace '[^A-Za-z0-9._-]', '_')
    $p = Join-Path $env:LOCALAPPDATA "claude-wsl\sessions\$Sid.txt"
    if (-not (Test-Path $p)) { return [IntPtr]::Zero }
    $n = 0L
    if ([long]::TryParse((Get-Content -Raw $p).Trim(), [ref]$n) -and $n -ne 0) {
        return [IntPtr]$n
    }
    return [IntPtr]::Zero
}

$target = [IntPtr]::Zero
if ($Uri -match 'hwnd=(\d+)') {
    $candidate = [IntPtr][long]$Matches[1]
    if ([WslFocus]::IsUsable($candidate)) { $target = $candidate }
}
if ($target -eq [IntPtr]::Zero -and $Uri -match 'sid=([^&]+)') {
    $stored = Get-StoredHwnd $Matches[1]
    if ([WslFocus]::IsUsable($stored)) { $target = $stored }
}
if ($target -eq [IntPtr]::Zero) {
    $target = [WslFocus]::FirstTerminal()
}
if ($target -ne [IntPtr]::Zero) {
    [WslFocus]::Force($target)
}

# Tell the WSL-side shell integration to drop its bell (best-effort, WSL only).
# Under Git Bash there is no wsl.exe in PATH, so this stays a no-op.
if ($Uri -match 'sid=([^&]+)') {
    $sid = ($Matches[1] -replace '[^A-Za-z0-9._-]', '_')
    try {
        $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
        if ($wsl) {
            Start-Process -FilePath $wsl.Source -ArgumentList @('-e', 'bash', '-lc', "touch /tmp/claude-focus-$sid") -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null
        }
    } catch {}
}
exit 0
