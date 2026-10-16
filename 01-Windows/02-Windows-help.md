# Windows help

**Run:** double-click `01-Run-on-Windows.bat`. A black window opens, asks any questions, then your browser shows the report.

## First run
- It checks for **git** (required), **fd** (faster scan) and **gh** (GitHub CLI) and offers to install what is missing with `winget`. It asks before installing.
- Windows may ask for permission while installing git. Click Yes.
- `gh` also offers a one-time browser sign-in so it can find your GitHub username.
- Say no to anything you do not want. The report still works, and "no" answers are remembered.

## Problems
| What you see | What to do |
|---|---|
| Blue "Windows protected your PC" screen | Click **More info**, then **Run anyway** |
| "git is required" | Install it from https://git-scm.com/downloads, then run again |
| The window closes too fast | Open Command Prompt, drag `01-Run-on-Windows.bat` into it, press Enter |
| No automatic install offered | `winget` is missing. The window prints manual download links instead |
| A repo says "couldn't check" | Git took too long (a sleeping or network drive) or the folder belongs to another user. Hover the tag, and see the Commands panel |
| Browser did not open | The path of `repos.html` is printed. Open that file yourself |
| Very long folder names are skipped | Windows limits paths to 260 characters unless long paths are enabled |

## Sharing
- **Screenshot:** open the report and press **Hide private details**, top right. Press **Show real details** to switch back. Crop to the page, because the browser's address bar can show your Windows username (Win+Shift+S).
- **Sending the file:** double-click `03-Make-shareable-report.bat`. It saves `04-reports\repos-shared.html` with placeholders only. Send that file, not `repos.html`.

## Options
Open Command Prompt in the `01-Windows` folder and add options after the launcher name:

    01-Run-on-Windows.bat -Root D:\Projects
    01-Run-on-Windows.bat -Root D:\Code,E:\Work
    01-Run-on-Windows.bat -Fetch

`-Fetch` refreshes each repo from its remote first, so the "unpulled" tags are current. `-NoStatus` skips the work-state check. `-NoSize` skips measuring disk space, which is faster on very large drives.

More in `05-docs/01-full-guide.md`.
