@echo off
setlocal EnableExtensions

if defined GENKI_CONFIG_CLAUDE_PS1_URL (
  set "INSTALL_PS1_URL=%GENKI_CONFIG_CLAUDE_PS1_URL%"
) else (
  set "INSTALL_PS1_URL=https://raw.githubusercontent.com/genkisystem/config-genki-ai-tools/main/claude/config.ps1"
)

set "INSTALL_PS1=%TEMP%\genki-config-claude-%RANDOM%-%RANDOM%.ps1"
curl.exe -fsSL --retry 3 --connect-timeout 15 "%INSTALL_PS1_URL%" -o "%INSTALL_PS1%"
if errorlevel 1 (
  echo Error: could not download the Claude PowerShell installer. 1>&2
  exit /b 1
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%INSTALL_PS1%"
set "INSTALL_EXIT_CODE=%ERRORLEVEL%"
del /f /q "%INSTALL_PS1%" >nul 2>&1
exit /b %INSTALL_EXIT_CODE%
