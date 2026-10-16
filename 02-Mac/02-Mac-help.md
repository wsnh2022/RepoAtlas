# Mac help

**Run:** double-click `01-Run-on-Mac.command`. A Terminal window opens, asks any questions, then your browser shows the report.

## First time only
- macOS may say the file cannot be opened because it is from the internet. **Right-click the file, choose Open, then Open again.** This is needed once.
- If double-clicking does nothing (the file lost its "executable" mark), open Terminal and run:

      bash /path/to/repoatlas/02-Mac/01-Run-on-Mac.command

  (Type `bash ` then drag the file into the Terminal window and press Enter.)

## What it installs
1. **PowerShell 7** is needed to run the program. If it is missing, the launcher offers to install it with Homebrew. macOS asks for your password once.
2. Then the program offers **git** (required), **fd** (faster scan) and **gh** (GitHub CLI). It asks before each install.
- No Homebrew? The window prints download links instead (https://aka.ms/powershell and https://brew.sh).
- A Mac without developer tools may show an Apple "install command line tools" popup for git. You can dismiss it. The program installs git with Homebrew instead.

## Problems
| What you see | What to do |
|---|---|
| "PowerShell could not be installed" | Install it from https://aka.ms/powershell, then run again |
| "Cannot find 99-app/repoatlas.ps1" | Keep the `02-Mac`, `99-app` and `03-my-settings` folders together |
| A repo says "couldn't check" | Git took too long (a sleeping or network drive) or the folder belongs to another user. Hover the tag, and see the Commands panel |
| Browser did not open | The path of `repos.html` is printed. Open that file yourself |
| Only your home folder is scanned | By design. Add `-Root` to choose folders |

## Sharing
- **Screenshot:** open the report and press **Hide private details**, top right. Press **Show real details** to switch back. Crop to the page, because the browser's address bar can show your Mac username (Shift+Command+4).
- **Sending the file:** double-click `03-Make-shareable-report.command`. It saves `04-reports/repos-shared.html` with placeholders only. Send that file, not `repos.html`.

## Options
Open Terminal in the `02-Mac` folder and add options after the launcher:

    bash 01-Run-on-Mac.command -Root ~/Code
    bash 01-Run-on-Mac.command -Root ~/Code,~/Work
    bash 01-Run-on-Mac.command -Fetch

`-Fetch` refreshes each repo from its remote first, so the "unpulled" tags are current. `-NoStatus` skips the work-state check. `-NoSize` skips measuring disk space, which is faster on very large drives.

More in `05-docs/01-full-guide.md`.
