# capture-hwnd.ps1
# Synchronous. Records the terminal window that is in front, so a later toast
# click can raise it again.
#
# Terminal-agnostic: instead of an allowlist of known terminals (which misses
# every new one), this walks up from the foreground window's process and skips
# anything that is clearly not a terminal: our own PowerShell, the console host
# that owns no user-facing window, and Claude Code itself.
#
# ASCII-only: Windows PowerShell 5.1 misreads UTF-8-without-BOM.
param([Parameter(Mandatory = $true)][string]$SessionId)

$ErrorActionPreference = 'SilentlyContinue'
if ([string]::IsNullOrWhiteSpace($SessionId)) { exit 0 }
$SessionId = ($SessionId -replace '[^A-Za-z0-9._-]', '_')

Add-Type @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
public static class HwndCap {
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern int GetWindowTextLength(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);

    // Never a terminal: our own helpers, the console host, and the app whose
    // hook is running. A conhost window belongs to the console, not the shell.
    static readonly HashSet<string> Skip = new HashSet<string>(StringComparer.OrdinalIgnoreCase) {
        "powershell", "pwsh", "WindowsPowerShell", "wscript", "cscript",
        "conhost", "OpenConsole", "cmd", "conime",
        "claude", "claude-2.1.310-win32-x64", "node"
    };

    // Terminal host classes we know by name. Used only to prefer a window when
    // the foreground one is unusable -- not as a hard allowlist.
    static readonly HashSet<string> TerminalClasses = new HashSet<string>(StringComparer.OrdinalIgnoreCase) {
        "CASCADIA_HOSTING_WINDOW_CLASS", "ConsoleWindowClass", "mintty",
        "org.wezfurlong.wezterm", "GLFW30", "Alacritty", "VirtualConsole",
        "TabbyWndClass", "Chrome_WidgetWin_1", "SunAwtFrame"
    };

    static string ProcName(IntPtr h) {
        uint pid; GetWindowThreadProcessId(h, out pid);
        if (pid == 0) return "";
        try { return Process.GetProcessById((int)pid).ProcessName; }
        catch { return ""; }
    }

    static string ClassName(IntPtr h) {
        var sb = new StringBuilder(256);
        GetClassName(h, sb, 256);
        return sb.ToString();
    }

    // A window worth raising: visible, titled or of a known terminal class,
    // and not owned by a process we must skip.
    static bool Usable(IntPtr h) {
        if (!IsWindowVisible(h)) return false;
        string n = ProcName(h);
        if (string.IsNullOrEmpty(n) || Skip.Contains(n)) return false;
        if (GetWindowTextLength(h) > 0) return true;
        return TerminalClasses.Contains(ClassName(h));
    }

    static IntPtr Foreground() {
        IntPtr fg = GetForegroundWindow();
        if (Usable(fg)) return fg;
        return IntPtr.Zero;
    }

    // Any visible console/terminal window, used when nothing is focused (the
    // user may be in a browser when Claude finishes).
    static IntPtr AnyTerminal() {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) => {
            if (!Usable(h)) return true;
            if (TerminalClasses.Contains(ClassName(h))) { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public static IntPtr Find() {
        IntPtr h = Foreground();
        if (h != IntPtr.Zero) return h;
        return AnyTerminal();
    }
}
'@

$h = [HwndCap]::Find()
if ($h -eq [IntPtr]::Zero) { exit 0 }

$dir = Join-Path $env:LOCALAPPDATA 'claude-wsl\sessions'
[void][System.IO.Directory]::CreateDirectory($dir)
[System.IO.File]::WriteAllText((Join-Path $dir "$SessionId.txt"), $h.ToInt64().ToString())
Write-Output $h.ToInt64().ToString()
exit 0
