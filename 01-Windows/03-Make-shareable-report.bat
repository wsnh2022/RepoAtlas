@echo off
rem Double-click to make a copy of the report that is safe to share: names, folders and accounts are
rem replaced with placeholders, and the real values are not in the file. Saved as 04-reports\repos-shared.html
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\99-app\repoatlas.ps1" -Redact %*
if errorlevel 1 (
  echo.
  echo Something went wrong - see the message above.
  pause
)
