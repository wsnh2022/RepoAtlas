@echo off
rem Double-click to scan this PC for git repos and open the report in your browser.
rem The first run may offer to install missing tools (git, fd, GitHub CLI). Answer in this window.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\99-app\repoatlas.ps1" %*
if errorlevel 1 (
  echo.
  echo Something went wrong - see the message above.
  pause
)
