' Hidden launcher for focus-session.ps1 (avoids a PowerShell console flash).
'
' No -ExecutionPolicy Bypass: this script and focus-session.ps1 are copied to
' %LOCALAPPDATA%\claude-wsl by install-protocol.ps1, so they carry no
' Zone.Identifier mark and the default RemoteSigned policy already runs them.
Option Explicit
Dim sh, dir, ps, uri, cmd
Set sh = CreateObject("WScript.Shell")
dir = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))
ps = dir & "focus-session.ps1"
uri = ""
If WScript.Arguments.Count > 0 Then uri = WScript.Arguments(0)
cmd = "powershell.exe -NoProfile -WindowStyle Hidden -File """ & ps & """ """ & uri & """"
sh.Run cmd, 0, False
