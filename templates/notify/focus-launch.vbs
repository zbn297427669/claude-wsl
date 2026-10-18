' Hidden launcher for focus-session.ps1 (avoids a PowerShell console flash).
Option Explicit
Dim sh, dir, ps, uri, cmd
Set sh = CreateObject("WScript.Shell")
dir = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))
ps = dir & "focus-session.ps1"
uri = ""
If WScript.Arguments.Count > 0 Then uri = WScript.Arguments(0)
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps & """ """ & uri & """"
sh.Run cmd, 0, False
