# capture-hwnd.ps1
# Synchronous. Records a terminal HWND for later toast-click focus.
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
public static class HwndCap {
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);

    static readonly HashSet<string> Ok = new HashSet<string>(StringComparer.OrdinalIgnoreCase) {
        "WindowsTerminal", "WindowsTerminalPreview", "OpenConsole",
        "Tabby", "wezterm-gui", "Alacritty", "Hyper", "FluentTerminal",
        "mintty", "Cursor", "Code"
    };
    static readonly HashSet<string> Skip = new HashSet<string>(StringComparer.OrdinalIgnoreCase) {
        "powershell", "pwsh", "WindowsPowerShell", "wscript", "cscript"
    };

    static string Name(IntPtr h) {
        uint procId;
        GetWindowThreadProcessId(h, out procId);
        if (procId == 0) return "";
        try { return Process.GetProcessById((int)procId).ProcessName; }
        catch { return ""; }
    }

    public static IntPtr Find() {
        IntPtr fg = GetForegroundWindow();
        string fgName = Name(fg);
        if (!string.IsNullOrEmpty(fgName) && Ok.Contains(fgName) && !Skip.Contains(fgName)) {
            return fg;
        }
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) => {
            if (!IsWindowVisible(h)) return true;
            string n = Name(h);
            if (string.IsNullOrEmpty(n) || Skip.Contains(n)) return true;
            if (Ok.Contains(n)) { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
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
