@echo off
setlocal
rem Cursor imports Claude Code hooks too; claude-wsl notifies for Claude Code.
if defined CURSOR_VERSION exit /b 0
rem Orca announces agent completion itself. Leave before starting bash so the
rem hook adds no second notification and no console window.
if defined ORCA_TAB_ID exit /b 0
if defined ORCA_TERMINAL_HANDLE exit /b 0
if /I "%TERM_PROGRAM%"=="Orca" exit /b 0

rem Find Git Bash: Claude Code's own override first, then the default installs,
rem then PATH.
set "BASH="
if defined CLAUDE_CODE_GIT_BASH_PATH if exist "%CLAUDE_CODE_GIT_BASH_PATH%" set "BASH=%CLAUDE_CODE_GIT_BASH_PATH%"
if not defined BASH if exist "%ProgramFiles%\Git\bin\bash.exe" set "BASH=%ProgramFiles%\Git\bin\bash.exe"
if not defined BASH if exist "%ProgramFiles(x86)%\Git\bin\bash.exe" set "BASH=%ProgramFiles(x86)%\Git\bin\bash.exe"
if not defined BASH for %%I in (bash.exe) do set "BASH=%%~$PATH:I"
if not defined BASH exit /b 0

rem stdin and stdout stay connected: notify.sh reads the hook JSON and prints
rem the terminalSequence reply Claude Code emits.
"%BASH%" "%~dp0notify-wrapper.sh"
exit /b %ERRORLEVEL%