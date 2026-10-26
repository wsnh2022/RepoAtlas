# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

RepoAtlas scans a computer for git repos and writes one self-contained HTML report (backup status, work state, disk usage). The whole program is a single PowerShell script, `99-app/repoatlas.ps1` (~1950 lines). Everything else is launchers and docs. There is no build, lint or test setup, and no package manifest. The folder is a git repo (`main`, remote `wsnh2022/RepoAtlas`); `gitsync.bat` in the root is a generic fetch/pull/push helper (it writes `deploy-log.txt` and a `.gitsync.lock`, all git-ignored), not part of the tool.

User-facing behaviour is documented in `README.md` (plain-English overview) and `05-docs/01-full-guide.md` (every option and tag). Keep both in sync when changing options, tags or report groups.

## Running it

Run from the repo root. The launchers just call the script with the right flags and pass extra args through.

```powershell
# Normal run (scans all fixed drives, opens the report)
powershell -NoProfile -ExecutionPolicy Bypass -File 99-app\repoatlas.ps1

# Faster iteration on a small tree; skip the slow parts
powershell -NoProfile -ExecutionPolicy Bypass -File 99-app\repoatlas.ps1 -Root D:\Library\Code_Env -NoSize -NoInstall

# Shareable (redacted) copy -> 04-reports\repos-shared.html
powershell -NoProfile -ExecutionPolicy Bypass -File 99-app\repoatlas.ps1 -Redact
```

`01-Windows/*.bat` and `02-Mac/*.command` wrap this (`03-Make-shareable-report` just adds `-Redact`). Linux uses `pwsh ./99-app/repoatlas.ps1`. Test hooks: env vars `REPOATLAS_TIMEOUT_SEC` (git status/fetch timeout) and `REPOATLAS_SIZE_TIMEOUT_SEC` (per-repo size limit). The old `FINDREPOS_*` names and `findrepos.config.json` are still honoured for backward compatibility.

The script must keep working on Windows PowerShell 5.1 as well as PowerShell 7 (hence `[switch]$true` casts, `2>$null` rather than `2>&1`, and `-File` comma-list quirks handled by `Split-List`). Do not use PS7-only syntax.

## Architecture (repoatlas.ps1, in execution order)

1. **Settings** (`param` block, ~line 27): each setting resolves as CLI parameter > `03-my-settings/repoatlas.config.json` > auto-detect. Paths are derived from `$inAppDir`: when the script lives in a folder named `99-app`, config is read from `../03-my-settings` and the report is written to `../04-reports`; a lone copied script keeps everything beside itself.
2. **Tools**: finds `git` (required), `fd` and `gh` (optional), offers to install missing ones, and remembers declined installs in `99-app/repoatlas.state.json`.
3. **Scan**: `fd` (or the built-in `Find-GitDirs` fallback) finds `.git` directories while honouring a built-in skip list. Each repo gets one `[pscustomobject]` record (`name, path, remote, status, st, sz, ...`). `status` is set from the remote: `Mine on GitHub` / `Third-party clone` / `Other remote` / `Local only` / `Broken` / `Error`. The GitHub user is resolved from `-User`/config, then `gh`, then git config, then the most common owner. Repos sharing a remote are flagged `dup`.
4. **Work state** (`$statusWorker`): one read-only `git status` per repo, run in a runspace pool (max 8). Fills `st` (ahead/behind/uncommitted/conflicts/upstream info). With `-Fetch` it runs `git fetch` first. Every git call has a timeout, stdin closed and credential prompts off.
5. **Size** (`$sizeWorker`): same pool pattern. Splits each repo into own files, `.git`, and git-ignored files (the ignored list comes from git itself); capped at 60s per repo and then reported as "at least". Measured in that order (own files, `.git`, then ignored) so a time-out only cuts the later parts; the result's `cut` lists which. Links are never entered, and repos nested inside another listed repo are passed in and skipped so they are not counted twice.
6. **Privacy masking** (`Get-MaskedRepos`): builds a second, placeholder-only copy of every record (`repo-01`, `folder-01`, `owner-01`...). Same real value always maps to the same placeholder. In a normal run this copy is attached to each record as `m` so the in-page "Hide private details" toggle can swap it in; with `-Redact` only the masked copy is emitted and the real values never reach the file.
7. **Report**: a large single-quoted here-string (`$template`, HTML + CSS + vanilla JS, no external dependencies) with `__DATA__`, `__META__` and `__DATE__` placeholders. The repo array is serialized to JSON, `</` is escaped to `<\/`, and placeholders are filled in a single `[regex]::Replace` pass so data can never be mistaken for a placeholder. The file is written to `04-reports/repos.html` (or `repos-shared.html`), falling back to the temp folder if that fails, then opened in the browser.

## Git rules

- After every commit, push it to `origin` straight away, without asking again.
- Commits and pushes look like the user's own: no `Co-Authored-By` line, no "Generated with Claude" text, and no mention of Claude in commit messages or PR descriptions. Plain `git commit` / `git push` as the configured git user.
- Still never force-push, and still never commit a real report, user config or `repoatlas.state.json` (see below).

## Things to keep in mind

- **The tool must stay read-only toward the scanned repos.** It never commits, pushes, edits or deletes. The per-repo "Commands" panel (`cheatFor` in the template JS) only generates commands for the user to copy.
- **Secrets never reach the report.** Credentials embedded in remote URLs are stripped with a regex in the scan step; anything that adds new fields from git output must go through the same masking path (`Get-MaskedRepos` / `Hide-ErrText`) or it will leak in the shareable copy.
- Report client code lives inside the PowerShell here-string, so there is no `$`-interpolation (it is single-quoted), but a line consisting of `'@` would end it. Edit the HTML/JS as a string literal, not as separate files.
- `.gitignore` deliberately excludes the generated reports (`repos.html`, `repos-shared.html`), user config and `repoatlas.state.json` (they contain real repo names, paths and accounts). The `04-reports/` folder is tracked only for `repos-public-demo.html`; never commit a real report. Running the tool from this folder regenerates `04-reports/repos.html` (ignored), so a run never dirties `git status`.