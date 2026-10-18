# Claude Code WSL Notification Script
# ASCII-only: Windows PowerShell 5.1 misreads UTF-8-without-BOM.
param(
    [string]$Title = "Claude Code Update",
    [string]$Message = "New activity detected",
    [string]$SessionId = "",
    [string]$Hwnd = "",
    [string]$TabTitle = "",
    [string]$WtSession = ""
)

$ErrorActionPreference = 'SilentlyContinue'

function Ensure-Protocol {
    $root = 'HKCU:\Software\Classes\claude-wsl\shell\open\command'
    $vbs = Join-Path $env:LOCALAPPDATA 'claude-wsl\focus-launch.vbs'
    if ((Test-Path $root) -and (Test-Path $vbs)) { return }
    $installer = Join-Path $PSScriptRoot 'install-protocol.ps1'
    if (Test-Path $installer) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer | Out-Null
    }
}

function Get-StoredHwnd([string]$Sid) {
    if ([string]::IsNullOrWhiteSpace($Sid)) { return '' }
    $Sid = ($Sid -replace '[^A-Za-z0-9._-]', '_')
    $p = Join-Path $env:LOCALAPPDATA "claude-wsl\sessions\$Sid.txt"
    if (Test-Path $p) {
        return ((Get-Content -Raw $p).Trim())
    }
    return ''
}

Ensure-Protocol

if ([string]::IsNullOrWhiteSpace($Hwnd) -and $SessionId) {
    $Hwnd = Get-StoredHwnd $SessionId
}

Add-Type -AssemblyName System.Runtime.WindowsRuntime
$null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
$null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]

$Title = $Title -replace '\\[nrt]', ' ' -replace '\s+', ' ' -replace '[\x00-\x1F\x7F]', '' -replace '^\s+|\s+$', ''
$Message = $Message -replace '\\[nrt]', ' ' -replace '\s+', ' ' -replace '[\x00-\x1F\x7F]', '' -replace '^\s+|\s+$', ''

if ([string]::IsNullOrWhiteSpace($Message)) {
    $Message = "Response ready"
}

$Message = $Message -replace '\*\*([^\*]+)\*\*', '$1'
$Message = $Message -replace '\*([^\*]+)\*', '$1'
$Message = $Message -replace '__([^_]+)__', '$1'
$Message = $Message -replace '_([^_]+)_', '$1'
$Message = $Message -replace '`([^`]+)`', '$1'
$Message = $Message -replace '\[([^\]]+)\]\([^\)]+\)', '$1'

$TitleEscaped = [System.Security.SecurityElement]::Escape($Title)
$MessageEscaped = [System.Security.SecurityElement]::Escape($Message)

$launch = 'claude-wsl://focus'
$qs = @()
if ($Hwnd -match '^\d+$') { $qs += "hwnd=$Hwnd" }
if ($SessionId) { $qs += "sid=$([uri]::EscapeDataString($SessionId))" }
if ($qs.Count -gt 0) { $launch = $launch + '?' + ($qs -join '&') }
$LaunchEscaped = [System.Security.SecurityElement]::Escape($launch)

$template = @"
<toast activationType="protocol" launch="$LaunchEscaped">
    <visual>
        <binding template="ToastGeneric">
            <text hint-style="title">$TitleEscaped</text>
            <text hint-maxLines="3">$MessageEscaped</text>
        </binding>
    </visual>
    <audio src="ms-winsoundevent:Notification.Default" />
</toast>
"@

$xml = New-Object Windows.Data.Xml.Dom.XmlDocument
$xml.LoadXml($template)

$toast = New-Object Windows.UI.Notifications.ToastNotification $xml
$timestamp = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
$toast.Tag = "ClaudeCode-$timestamp"
$toast.ExpirationTime = [DateTimeOffset]::Now.AddSeconds(10)
$toast.SuppressPopup = $false

$appIds = @(
    'Windows.SystemToast.ClaudeCode',
    'Microsoft.WindowsTerminal_8wekyb3d8bbwe!App',
    '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
)

$success = $false
$usedAppId = $null
foreach ($appId in $appIds) {
    try {
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
        $success = $true
        $usedAppId = $appId
        break
    } catch {
        continue
    }
}

if (-not $success) { exit 1 }

$debugLog = "$env:TEMP\claude-notification-debug.log"
"$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - toast AppID=$usedAppId launch=$launch" | Out-File -Append -FilePath $debugLog
exit 0
