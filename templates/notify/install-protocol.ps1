# install-protocol.ps1
# Copy click-to-focus files to a stable Windows path and register claude-wsl:// (HKCU, no admin).
# ASCII-only: Windows PowerShell 5.1 misreads UTF-8-without-BOM.
$ErrorActionPreference = 'Stop'
$dest = Join-Path $env:LOCALAPPDATA 'claude-wsl'
[void][System.IO.Directory]::CreateDirectory($dest)
[void][System.IO.Directory]::CreateDirectory((Join-Path $dest 'sessions'))

$src = $PSScriptRoot
foreach ($name in @('focus-session.ps1', 'focus-launch.vbs', 'capture-hwnd.ps1', 'send-notification.ps1')) {
    $from = Join-Path $src $name
    $to = Join-Path $dest $name
    if (Test-Path $from) {
        Copy-Item -Force $from $to
    }
}

$vbs = Join-Path $dest 'focus-launch.vbs'
$cmd = "wscript.exe `"$vbs`" `"%1`""
$root = 'HKCU:\Software\Classes\claude-wsl'
if (-not (Test-Path $root)) {
    New-Item -Path $root -Force | Out-Null
}
New-ItemProperty -Path $root -Name '(Default)' -Value 'URL:Claude WSL Protocol' -PropertyType String -Force | Out-Null
New-ItemProperty -Path $root -Name 'URL Protocol' -Value '' -PropertyType String -Force | Out-Null
$open = Join-Path $root 'shell\open\command'
if (-not (Test-Path $open)) {
    New-Item -Path $open -Force | Out-Null
}
New-ItemProperty -Path $open -Name '(Default)' -Value $cmd -PropertyType String -Force | Out-Null
Write-Output "registered claude-wsl:// -> $vbs"
exit 0
