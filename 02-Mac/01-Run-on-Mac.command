#!/bin/bash
# Double-click to scan this Mac for git repos and open the report in your browser.
# Needs PowerShell 7. If it is missing, this offers to install it with Homebrew first.

cd "$(dirname "$0")" || { echo "Cannot open the script folder."; read -r -p "Press Enter to close..." _; exit 1; }
ROOT="$(cd .. && pwd)"
SCRIPT="$ROOT/99-app/repoatlas.ps1"

finish() {   # finish <exit code>: keep the window open so the message can be read
  echo
  read -r -p "Press Enter to close..." _
  exit "$1"
}

if [ ! -f "$SCRIPT" ]; then
  echo "Cannot find 99-app/repoatlas.ps1. Keep the 01-Windows, 02-Mac, 03-my-settings and 99-app folders together, and do not run from inside the zip."
  finish 1
fi

# A double-clicked window often has a short PATH, so look in the usual Homebrew places too
find_tool() {
  local t="$1" p
  command -v "$t" 2>/dev/null && return 0
  for p in "/opt/homebrew/bin/$t" "/usr/local/bin/$t" "$HOME/.dotnet/tools/$t"; do
    [ -x "$p" ] && { echo "$p"; return 0; }
  done
  return 1
}

yes_flag=0; no_install=0
for a in "$@"; do
  case "$a" in
    -Yes|-yes) yes_flag=1 ;;
    -NoInstall|-noinstall) no_install=1 ;;
  esac
done

PWSH="$(find_tool pwsh)"

if [ -z "$PWSH" ]; then
  echo "RepoAtlas needs PowerShell 7, which is not installed on this Mac."
  BREW="$(find_tool brew)"
  if [ "$no_install" = 1 ]; then
    echo "Install it from https://aka.ms/powershell and run this again."
    finish 1
  fi
  if [ -z "$BREW" ]; then
    echo "Homebrew (the Mac package installer) was not found either, so it cannot be installed automatically."
    echo "Install PowerShell from https://aka.ms/powershell"
    echo "(or install Homebrew from https://brew.sh and run this again)."
    finish 1
  fi
  if [ "$yes_flag" = 1 ]; then
    answer="y"
  elif [ -t 0 ]; then
    read -r -p "Install PowerShell now with Homebrew? macOS will ask for your password. [Y/n] " answer
  else
    echo "Run this in a normal Terminal window to be offered the install."
    finish 1
  fi
  case "$answer" in
    ""|[Yy]|[Yy][Ee][Ss]) ;;
    *) echo "Not installed. Install PowerShell from https://aka.ms/powershell and run this again."; finish 1 ;;
  esac
  "$BREW" install --cask powershell
  PWSH="$(find_tool pwsh)"
  if [ -z "$PWSH" ]; then
    echo
    echo "PowerShell could not be installed. Install it from https://aka.ms/powershell and run this again."
    finish 1
  fi
fi

"$PWSH" -NoProfile -File "$SCRIPT" "$@"
code=$?
if [ "$code" -ne 0 ]; then
  echo
  echo "Something went wrong - see the message above."
  finish "$code"
fi
exit 0
