# RepoAtlas full guide

RepoAtlas 1.0, created by datacraft.yogi.

## What it does
Scans for git repos, reads each repo's remote, and writes one HTML report with these groups:

| Group | Meaning |
|---|---|
| My GitHub repos | Remote is a GitHub repo owned by you (or one of your listed owners) |
| Someone else's repo | Remote is someone else's GitHub repo |
| On another site | Remote is on another host (GitLab, Bitbucket, a private server) |
| Only on this computer | No remote at all |
| Broken | `.git` exists but git cannot read it |
| Error | Git reported a problem (for example "dubious ownership"); the report shows the fix |

Each repo also shows its work state (see below). The top of the report reads in three steps. **Backup status** is the total and a coloured bar with one segment per group; click a segment to filter the list, or click "duplicate copies" to see repos that exist in more than one place. **Start here** is one line naming the most urgent problem (for example repos that were never pushed and have uncommitted files); click it to see those repos. **Work state** has a tile each for pending to commit, pending to push, unpulled, all good and, when something could not be read, couldn't check; click a tile to filter. Use the **How it works** button for a short explanation. The search box and your active filters (shown as chips you can remove with their x) stay at the top of the screen while you scroll.

Each repo has copy-ready commands filled in for its own problem. Repos that share the same remote are flagged as duplicates.

## Options
Add after the launcher (`01-Run-on-Windows.bat` or `bash 01-Run-on-Mac.command`):

| Option | Effect |
|---|---|
| `-Root a,b` | Scan only these folders. Separate with commas, no spaces |
| `-Skip x,y` | Extra folder names to ignore (added to the built-in list) |
| `-User name` | Your GitHub name (normally detected) |
| `-Owners org1,org2` | Extra GitHub owners to count as yours |
| `-Setup` | Ask about missing tools again |
| `-Yes` | Answer yes to every install question |
| `-NoInstall` | Never install anything |
| `-Fetch` | Run `git fetch` in every repo that has a remote before checking, so "unpulled" is up to date. Needs the network and takes longer. Off by default |
| `-NoStatus` | Skip the pending-to-commit / pending-to-push / unpulled check (faster; the report then has no work state) |
| `-NoSize` | Do not measure how much disk space each repo uses. Measuring reads every file, so it is the slowest part on drives with huge `node_modules` folders |
| `-IgnoreUntracked` | Do not count new files that were never added to git as pending to commit |
| `-Redact` | Write a shareable copy, `04-reports/repos-shared.html`, with placeholders instead of real names, folders and accounts |

A folder name with spaces needs quotes and must not end with a backslash: `-Root "D:\My Projects"`.

## Settings file (optional)
Copy `03-my-settings/01-repoatlas.config.example.json` to `03-my-settings/repoatlas.config.json` and edit it:

    {
      "root":   ["D:\\Projects"],
      "skip":   ["old"],
      "user":   "your-github-name",
      "owners": ["my-org"],
      "ignoreUntracked": false,
      "noStatus": false,
      "noSize": false
    }

A settings file saved under the tool's earlier name, `findrepos.config.json`, is still read if there is no `repoatlas.config.json`.

On a Mac use paths like `"~/Code"`. Priority: option typed in the terminal, then the settings file, then automatic detection.

## Work state
Each repo gets one read-only `git status`. Nothing in your repos is changed. The report shows the branch and these tags when they apply:

| Tag | Meaning |
|---|---|
| `pending to commit` | (git: uncommitted) Changed files plus new files not yet added to git. Hover for the split (staged, not staged, new). A new folder counts once |
| `pending to push` | (git: unpushed) Commits not on the remote. With no upstream branch (or after the remote branch was deleted) it counts commits that exist on no remote branch at all |
| `unpulled` | Commits on the upstream branch that you do not have. **As of the repo's last fetch**: git only knows what it fetched. Use `-Fetch` for a current number |
| `clashing edits` | Files with unresolved merge conflicts |
| `not linked to remote` / `remote branch deleted` (git: no upstream / upstream gone) | The branch follows no remote branch, or the one it followed was deleted |
| `not on a branch` (git: detached) | HEAD is not on a branch; commits made there are easy to lose |
| `(no commits yet)` | A brand-new repo with nothing committed |
| `couldn't reach remote` | With `-Fetch`: the remote could not be reached (offline, or it needs a password). The unpulled count may be out of date |
| `couldn't check` | Git did not answer in 30 seconds (huge repo, slow or sleeping drive) |
| `owned by another user` | Git refuses to run in folders owned by another account. The Commands panel shows how to mark it safe |

If some repos could not be checked, a **Couldn't check** tile appears in Work state with the reason (owned by another user, too slow to answer, or unreadable); click it to list them.


**Filters.** The buttons in the top band (pending to commit, pending to push, unpulled, all good) can be combined with each other and with a colour. `all good` replaces the other three. Search also matches branch names.

**Commands.** The Commands panel adds steps for the repo's own situation: review and commit or stash, see and push the commits pending to push, see what you have not pulled.

**Notes**
- Broken and Error repos are not checked.
- Untracked build folders (for example `dist/`) count as pending to commit unless they are in `.gitignore`. Use `-IgnoreUntracked` to leave new files out.
- On Windows, files with different line endings can show as modified when they were not really edited (a git setting called `core.autocrlf`).
- Submodules: a modified submodule counts as one pending-to-commit change in its parent repo.
- `-Fetch` never asks for a password. Repos that need one are marked `couldn't reach remote`. Fetch updates a repo's remote-tracking branches only; your files and branches are not touched.
- Stashes, merges in progress and last-commit dates are not shown.

## Size on disk
Each repo shows the space its folder uses, split three ways:

| Part | Meaning |
|---|---|
| Your files | Everything except `.git` and ignored files |
| Git history | The `.git` folder |
| Ignored by git | Files and folders matched by the repo's own `.gitignore` rules (`node_modules`, build output, `.env`, logs). The names `node_modules`, `dist`, `build`, `venv`, `target` and similar are listed in the breakdown; everything else is grouped as "other" |

- The numbers add up file sizes, like the folder size Explorer or Finder shows. The space the drive reserves is a little higher.
- Reading only: nothing is changed. Links and shortcuts are not followed, so a folder is never counted twice.
- A repo that sits inside another listed repo is not counted in the outer repo; it has its own row, so nothing is counted twice.
- Each repo has 60 seconds. Your files are measured first, then git history, then ignored files, so a slow `node_modules` can only cut its own number short. If a part takes longer (or some folders cannot be read) that part, and the total, is shown as **at least** (≥).
- A repo git will not open (owned by another user, or broken) is shown as one number without the ignored-files split.
- Sizes stay visible in the private view, because they do not identify anything.
- **Sort > Largest first** orders repos by size inside each group. The **Disk space** card under the work-state tiles shows the total, the split (your files, git history, ignored by git, not split), a **By category** list with the space each category uses (click a row to list those repos) and the three heaviest repos.
- Use `-NoSize` (or `"noSize": true`) to skip it.

## Hiding private details
- **In the report:** the **Hide private details** button (top right) swaps every repo name, folder path, GitHub account and remote for a placeholder: `repo-01`, `folder-01`, `you`, `owner-01`, `host-01`, and branch names become `branch-01` (main and master stay as they are). The folder shared by all repos becomes `<root>`. The same real name always gets the same placeholder, so duplicates still line up. Hover text and git error messages are cleaned too, and the search box is cleared. **Copy still copies the real command** to your clipboard, so the report stays useful on your own machine. The real values are still inside the file, so use `-Redact` before sending the file itself.
- **A copy that is safe to send:** run with `-Redact`, or double-click `03-Make-shareable-report`. The file `04-reports/repos-shared.html` contains only placeholders. There is nothing to reveal, so the toggle button is not shown, and Copy copies placeholder commands.
- **What stays visible:** counts (including pending to commit / pending to push / unpulled), statuses, group names and the duplicate badges. Remote hosts other than github.com become `host-01`.
- **Limits:** the browser address bar and window title can still show your username in a screenshot. A git error message that still contains a known name after cleaning is replaced by "Details hidden."

## Defaults
- Windows scans every fixed drive. Mac and Linux scan your home folder. External and network drives are only scanned if you name them with `-Root`.
- Always skipped: `node_modules`, caches, virtual environments and system folders.

## Files the program creates
- `04-reports/repos.html`, overwritten each run (and `04-reports/repos-shared.html` when you ask for a shareable copy). If that folder is read-only, the report goes to your temp folder and its path is printed.
- `99-app/repoatlas.state.json` remembers which installs you declined. Delete it or run with `-Setup` to be asked again.

## Privacy
Passwords or tokens inside a remote URL are removed before they reach the report.

## Limits
- Work state needs git to answer within 30 seconds per repo and refuses to run in folders owned by another user.
- Git worktrees and submodules (where `.git` is a file) are not listed.
- Windows paths over 260 characters may be skipped unless long paths are enabled. Sizes then show as "at least".

## Linux
Install PowerShell 7, then run `pwsh ./99-app/repoatlas.ps1` from the `repoatlas` folder.

## Using the script on its own
`99-app/repoatlas.ps1` works as a single file too. If it is not inside a folder named `99-app`, its settings and report stay next to it, as before.
