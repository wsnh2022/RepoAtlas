# repoatlas.ps1 - RepoAtlas: builds an HTML report of every local git repo (status, work state, disk space) and opens it in your browser.
# RepoAtlas 1.0, created by datacraft.yogi.
# Works on Windows, macOS and Linux (PowerShell 5.1 or 7+).
# Needs git. fd (fast scan) and gh (GitHub CLI) are installed for you on first run, after you say yes.
#
# Each setting is resolved in this order: command-line parameter > repoatlas.config.json
# (placed next to this script) > auto-detection.
#   -Root      folders or drives to scan    auto: every fixed drive on Windows, your home folder elsewhere
#   -Skip      extra folder names to ignore (added to the built-in list: node_modules, caches, system folders)
#   -User      your GitHub username         auto: gh login, then git config github.user, then the most common owner
#   -Owners    extra GitHub owners or orgs to count as yours
#   -Strip     path prefix hidden in the Folder column   auto: the folder that all repos share
#   -Setup     ask again about missing tools / GitHub sign-in (answers are remembered otherwise)
#   -Yes       answer yes to the install questions
#   -NoInstall never install anything
#   -Redact    write a shareable copy (repos-shared.html) in which names, folders and accounts are placeholders;
#              the real values are not in that file. (The normal report has a "Hide private details" button too.)
#   -NoStatus  skip the pending-to-commit / pending-to-push / unpulled check (a little faster; the report then has no work state)
#   -Fetch     run "git fetch" in each repo that has a remote first, so "unpulled" is current. Needs the network;
#              repos that need a password or are offline show "fetch failed". Off by default.
#   -IgnoreUntracked  do not count new files that were never added to git as pending to commit
#   -NoSize    do not measure how much disk space each repo uses (the measuring reads every file, so it can take a while on big drives)
#              (config file keys: "ignoreUntracked": true, "noStatus": true, "noSize": true)
# Several folders: separate them with commas:  -Root D:\Code,E:\Work
# Examples:  .\repoatlas.ps1 -Root D:\            |  pwsh ./repoatlas.ps1 -Root ~/dev -User octocat
[CmdletBinding(PositionalBinding = $false)]   # a stray second value is an error, instead of silently landing in another option
param(
    [string[]]$Root,
    [string[]]$Skip,
    [string]$User,
    [string[]]$Owners,
    [string]$Strip,
    [switch]$Setup,
    [switch]$Yes,
    [switch]$NoInstall,
    [switch]$Redact,
    [switch]$NoStatus,
    [switch]$Fetch,
    [switch]$IgnoreUntracked,
    [switch]$NoSize
)

$appVersion = '1.0'
$onWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or [bool]$IsWindows
$sep       = [IO.Path]::DirectorySeparatorChar
$here      = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

# Folder layout: when this script sits in a "99-app" folder, settings live in ..\03-my-settings and the report goes
# to ..\04-reports. When it sits anywhere else (a single copied file), everything stays next to the script.
$inAppDir    = ((Split-Path -Leaf $here) -eq '99-app')
$base        = if ($inAppDir) { Split-Path -Parent $here } else { $here }
$settingsDir = if ($inAppDir) { Join-Path $base '03-my-settings' } else { $here }
$reportDir   = if ($inAppDir) { Join-Path $base '04-reports' }     else { $here }

# ---- settings: parameter > config file > auto-detect ----
$cfg     = $null
# repoatlas.config.json; a settings file with the tool's earlier name (findrepos.config.json) is still read
$cfgFile = Join-Path $settingsDir 'repoatlas.config.json'
foreach ($cand in @((Join-Path $settingsDir 'findrepos.config.json'), (Join-Path $here 'repoatlas.config.json'), (Join-Path $here 'findrepos.config.json'))) {
    if (Test-Path -LiteralPath $cfgFile) { break }
    $cfgFile = $cand
}
if (Test-Path -LiteralPath $cfgFile) {
    try   { $cfg = Get-Content -LiteralPath $cfgFile -Raw | ConvertFrom-Json }
    catch { Write-Warning "Could not read $cfgFile : $_" }
}
if (-not $Root   -and $cfg.root)   { $Root   = @($cfg.root) }
if (-not $Skip   -and $cfg.skip)   { $Skip   = @($cfg.skip) }
if (-not $User   -and $cfg.user)   { $User   = [string]$cfg.user }
if (-not $Owners -and $cfg.owners) { $Owners = @($cfg.owners) }
if (-not $Strip  -and $cfg.strip)  { $Strip  = [string]$cfg.strip }
if (-not $NoStatus        -and $cfg.noStatus        -eq $true) { $NoStatus        = [switch]$true }
if (-not $IgnoreUntracked -and $cfg.ignoreUntracked -eq $true) { $IgnoreUntracked = [switch]$true }
if (-not $NoSize          -and $cfg.noSize          -eq $true) { $NoSize          = [switch]$true }

# "-Root a,b" arrives as ONE string when the script is started with -File (the .bat does this), so split on commas.
# A folder that really exists with a comma in its name is kept as it is.
function Split-List([string[]]$items, [bool]$checkPath) {
    foreach ($it in @($items | Where-Object { $_ })) {
        if ($checkPath -and (Test-Path -LiteralPath $it)) { $it }
        else { $it -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } }
    }
}
$Root = @(Split-List $Root $true); $Skip = @(Split-List $Skip $false); $Owners = @(Split-List $Owners $false)

if (-not $Root) {
    if ($onWindows) {
        $Root = [IO.DriveInfo]::GetDrives() |
                Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady } |
                ForEach-Object { $_.RootDirectory.FullName }
    } else { $Root = @($HOME) }
}
# Built-in skip list (always applied); -Skip / the config "skip" list adds to it
$baseSkip = @('node_modules', '.cache', '.npm', '.nuget', '.cargo', '.rustup', '.gradle', '.m2', '.terraform', '.venv', 'venv', '__pycache__', 'site-packages')
if ($onWindows)   { $baseSkip += '$Recycle.Bin', 'System Volume Information', 'Windows', 'Program Files', 'Program Files (x86)', 'AppData' }
elseif ($IsMacOS) { $baseSkip += 'Library', '.Trash' }
$Skip = @(($baseSkip + @($Skip)) | Where-Object { $_ } | Select-Object -Unique)

# ---- tools: find them, offer to install what is missing ----
$exeExt = if ($onWindows) { '.exe' } else { '' }
$knownDirs = @{
    git = @("$env:ProgramFiles\Git\cmd", "${env:ProgramFiles(x86)}\Git\cmd", "$env:LOCALAPPDATA\Programs\Git\cmd", '/opt/homebrew/bin', '/usr/local/bin')
    fd  = @("$env:LOCALAPPDATA\Microsoft\WinGet\Links", '/opt/homebrew/bin', '/usr/local/bin')
    gh  = @("$env:ProgramFiles\GitHub CLI", "$env:LOCALAPPDATA\Programs\GitHub CLI", "$env:LOCALAPPDATA\Microsoft\WinGet\Links", '/opt/homebrew/bin', '/usr/local/bin')
}
$toolInfo = @{
    git = @{ why = 'required';                                      link = 'https://git-scm.com/downloads' }
    fd  = @{ why = 'makes the scan much faster';                    link = 'https://github.com/sharkdp/fd#installation' }
    gh  = @{ why = 'GitHub CLI: publish and repo-list commands';    link = 'https://cli.github.com' }
}

# Windows only: pick up PATH changes made by an installer without restarting this window
function Update-EnvPath {
    if (-not $onWindows) { return }
    $all = @($env:PATH -split ';') +
           @([Environment]::GetEnvironmentVariable('Path', 'Machine') -split ';') +
           @([Environment]::GetEnvironmentVariable('Path', 'User') -split ';')
    $env:PATH = (($all | Where-Object { $_ }) | Select-Object -Unique) -join ';'
}

# Returns the command if the tool works, else $null. Also looks in the usual install folders,
# because a tool installed a moment ago may not be on PATH yet.
function Test-Tool([string]$name) {
    $cmd = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cmd -and $name -eq 'fd') { $cmd = Get-Command fdfind -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1 }
    if (-not $cmd) {
        foreach ($d in $knownDirs[$name]) {
            if ($d -and (Test-Path -LiteralPath (Join-Path $d "$name$exeExt"))) {
                $env:PATH = "$d$([IO.Path]::PathSeparator)$env:PATH"
                $cmd = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($cmd) { break }
            }
        }
    }
    if ($cmd -and $name -eq 'git') {
        & $cmd.Source --version *> $null
        if ($LASTEXITCODE -ne 0) { return $null }     # e.g. the macOS shim that appears before developer tools are installed
    }
    return $cmd
}

function Install-Tool([string]$name) {
    if ($onWindows) {
        $id = @{ git = 'Git.Git'; fd = 'sharkdp.fd'; gh = 'GitHub.cli' }[$name]
        Write-Host "  Installing $name ($id) with winget..."
        & winget install --id $id -e --source winget --accept-package-agreements --accept-source-agreements --silent
    } elseif ($IsMacOS) {
        Write-Host "  Installing $name with Homebrew..."
        & brew install $name
    }
    Update-EnvPath
    return [bool](Test-Tool $name)
}

$interactive = [Environment]::UserInteractive
try { if ([Console]::IsInputRedirected) { $interactive = $false } } catch { }

# Remember "no" answers so a friend is not asked on every run
$stateFile = Join-Path $here 'repoatlas.state.json'
$declined  = @()
$oldState  = Join-Path $here 'findrepos.state.json'      # answers saved under the tool's earlier name still count
$readState = if (Test-Path -LiteralPath $stateFile) { $stateFile } else { $oldState }
if (Test-Path -LiteralPath $readState) {
    try { $declined = @((Get-Content -LiteralPath $readState -Raw | ConvertFrom-Json).declined | Where-Object { $_ }) } catch { }
}
function Save-Declined { try { (@{ declined = @($declined) } | ConvertTo-Json) | Set-Content -LiteralPath $stateFile -Encoding UTF8 } catch { } }
function Ask-YesNo([string]$question) {
    if ($Yes) { return $true }
    if (-not $interactive) { return $false }
    $a = Read-Host "$question [Y/n]"
    return ([string]::IsNullOrWhiteSpace($a) -or $a -match '^\s*(y|yes)\s*$')
}

$canInstall = ($onWindows -and (Get-Command winget -ErrorAction SilentlyContinue)) -or
              ($IsMacOS   -and (Get-Command brew   -ErrorAction SilentlyContinue))
$missing = @('git', 'fd', 'gh' | Where-Object { -not (Test-Tool $_) })

if ($missing.Count -gt 0 -and -not $NoInstall) {
    # git is always offered; fd and gh are not asked again after a "no" (use -Setup to be asked again)
    $offer = @($missing | Where-Object { $_ -eq 'git' -or $Setup -or ($declined -notcontains $_) })
    if ($offer.Count -gt 0) {
        Write-Host ''
        Write-Host 'Missing tools:' -ForegroundColor Yellow
        foreach ($t in $offer) { Write-Host ('  {0,-4} {1}' -f $t, $toolInfo[$t].why) }
        if (-not $canInstall) {
            Write-Host 'Automatic install needs winget (Windows) or Homebrew (macOS), which was not found. Install manually:'
            foreach ($t in $offer) { Write-Host ('  {0}: {1}' -f $t, $toolInfo[$t].link) }
        }
        elseif ($interactive -or $Yes) {
            $core = @($offer | Where-Object { $_ -eq 'git' -or $_ -eq 'fd' })
            if ($core.Count -gt 0 -and (Ask-YesNo ('Install ' + ($core -join ' and ') + ' now?' + $(if ($onWindows) { ' (Windows may ask for permission)' } else { '' })))) {
                foreach ($t in $core) {
                    if (-not (Install-Tool $t)) { Write-Warning "$t could not be installed. Manual install: $($toolInfo[$t].link)" }
                }
            }
            elseif ($core -contains 'fd') { $declined += 'fd'; Save-Declined }
            if ($offer -contains 'gh') {
                if (Ask-YesNo 'Install the GitHub CLI (gh) too?') {
                    if (-not (Install-Tool 'gh')) { Write-Warning "gh could not be installed. Manual install: $($toolInfo.gh.link)" }
                } else { $declined += 'gh'; Save-Declined }
            }
        }
        else { Write-Host 'Run this in a normal terminal window to be offered the install, or install them manually.' }
    }
}

# gh needs a one-time browser sign-in before it is useful
$gh = Test-Tool 'gh'
$ghAuthed = $false
if ($gh) {
    $env:GH_PROMPT_DISABLED = '1'
    & $gh.Source auth status *> $null
    $ghAuthed = ($LASTEXITCODE -eq 0)
    if (-not $ghAuthed -and -not $NoInstall -and $interactive -and ($Setup -or $declined -notcontains 'gh-login')) {
        Write-Host ''
        Write-Host 'The GitHub CLI is installed but not signed in.' -ForegroundColor Yellow
        if (Ask-YesNo 'Sign in to GitHub now? (a browser window will open)') {
            Remove-Item Env:GH_PROMPT_DISABLED -ErrorAction SilentlyContinue
            & $gh.Source auth login --hostname github.com --git-protocol https --web
            $env:GH_PROMPT_DISABLED = '1'
            & $gh.Source auth status *> $null
            $ghAuthed = ($LASTEXITCODE -eq 0)
        } else { $declined += 'gh-login'; Save-Declined }
    }
}

$git = Test-Tool 'git'
if (-not $git) { Write-Error "git is required but was not found. Install it from $($toolInfo.git.link) and run this again."; exit 1 }
$fd = Test-Tool 'fd'
if (-not $fd) { Write-Warning 'fd not found - using the slower built-in scan. (Run with -Setup to be offered the install again.)' }

# Built-in scanner, used only when fd is missing. Skips excluded names and links, never enters .git folders.
function Find-GitDirs([string[]]$roots, [string[]]$skipNames) {
    $stack = [System.Collections.Generic.Stack[string]]::new()
    foreach ($r in $roots) { $stack.Push($r) }
    while ($stack.Count -gt 0) {
        $d = $stack.Pop()
        try { $subs = [IO.Directory]::GetDirectories($d) } catch { continue }
        foreach ($sd in $subs) {
            $leaf = [IO.Path]::GetFileName($sd)
            if ($leaf -eq '.git') { "$sd/"; continue }
            if ($skipNames -contains $leaf) { continue }
            try { if ([IO.File]::GetAttributes($sd) -band [IO.FileAttributes]::ReparsePoint) { continue } } catch { continue }
            $stack.Push($sd)
        }
    }
}

# Reads the remote URL of a repo. Uses "origin", or the first remote if there is no origin.
# Only stdout counts as the URL, so a git warning on stderr can never end up inside it.
function Get-Remote([string]$path) {
    $rname = 'origin'
    $all   = git -c 'safe.directory=*' -C $path remote get-url origin 2>&1
    $code  = $LASTEXITCODE
    $errs  = (@($all | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
    if ($code -ne 0 -and $errs -match 'No such remote') {
        $names = @(git -c 'safe.directory=*' -C $path remote 2>$null | Where-Object { $_ })
        if ($names.Count -gt 0) {
            $rname = [string]$names[0]
            $all   = git -c 'safe.directory=*' -C $path remote get-url $rname 2>&1
            $code  = $LASTEXITCODE
            $errs  = (@($all | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
        }
    }
    $outs = (@($all | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
    [pscustomobject]@{ code = $code; out = $outs.Trim(); err = $errs.Trim(); rname = $rname }
}

# ---- scan ----
# Only keep folders that exist, as full paths ("~" and "." are expanded; fd would not understand them)
$goodRoots = @()
foreach ($rt in @($Root | Where-Object { $_ })) {
    if (Test-Path -LiteralPath $rt -PathType Container) {
        $full = (Resolve-Path -LiteralPath $rt).ProviderPath
        # no trailing separator (a final backslash before a closing quote breaks native commands on Windows PowerShell 5.1)
        $trim = $full.TrimEnd('\', '/')
        $full = if (-not $trim) { $full } elseif ($trim -match '^[A-Za-z]:$') { $trim + '\' } else { $trim }
        $goodRoots += $full
    }
    else { Write-Warning "Skipping folder that does not exist: $rt" }
}
if ($goodRoots.Count -eq 0) { Write-Error 'None of the folders to scan exist. Use -Root to choose one.'; exit 1 }
$Root = $goodRoots

# Make non-English folder names survive the trip through fd on Windows PowerShell 5.1
$prevEnc = $null
try { $prevEnc = [Console]::OutputEncoding; [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) } catch { }

Write-Host "Scanning: $($Root -join ', ')"
# -I: do not let .gitignore files hide repos, so fd and the built-in scanner give the same answer
$fdArgs  = @('-H', '-I', '-t', 'd', '^\.git$') + ($Skip | ForEach-Object { '-E'; $_ }) + $Root
$gitDirs = @(if ($fd) { & $fd.Source @fdArgs 2>$null } else { Find-GitDirs $Root $Skip })

$ghRe = '^(?:https?://|ssh://(?:git@)?|git@)github\.com[/:](.+?)(?:\.git)?/?$'
$i = 0
$found = @(foreach ($g in $gitDirs) {
    $i++
    if ($i % 5 -eq 0 -or $i -eq $gitDirs.Count) { Write-Progress -Activity 'Reading repos' -Status "$i of $($gitDirs.Count)" -PercentComplete (100 * $i / [Math]::Max(1, $gitDirs.Count)) }
    $path = [IO.Path]::GetDirectoryName("$g".TrimEnd('\', '/'))
    $rm   = Get-Remote $path
    $remote = ''; $url = ''; $owner = ''; $status = 'Error'; $errText = ''

    if ($rm.code -eq 0 -and $rm.out) {
        $raw = (($rm.out -split "`n")[0]).Trim() -replace '(?<=https?://)[^/@\s]+@', ''   # never show embedded passwords or tokens
        $status = 'Remote'     # becomes Mine / Third-party / Other once the GitHub user is known
        if ($raw -match $ghRe) { $remote = $matches[1]; $url = "https://github.com/$remote"; $owner = ($remote -split '/')[0] }
        else { $remote = $raw; if ($raw -match '^https?://') { $url = $raw -replace '\.git/?$', '' } }
    }
    elseif ($rm.code -eq 0)                          { $status = 'Local only' }
    elseif (($rm.err + $rm.out) -match 'not a git repository') { $status = 'Broken' }
    elseif (($rm.err + $rm.out) -match 'No such remote')       { $status = 'Local only' }
    else {
        $errText = (($rm.err + ' ' + $rm.out) -replace 'System\.Management\.Automation\.RemoteException', '' -replace '(?<=https?://)[^/@\s]+@', '').Trim()
    }

    [pscustomobject]@{
        name   = [IO.Path]::GetFileName($path)
        parent = [IO.Path]::GetDirectoryName($path)
        path   = $path
        folder = ''
        remote = $remote
        rname  = $rm.rname
        url    = $url
        owner  = $owner
        status = $status
        dup    = $false
        err    = $errText
        st     = $null      # work state, filled in below
        sz     = $null      # size on disk, filled in below
    }
})
Write-Progress -Activity 'Reading repos' -Completed
try { if ($prevEnc) { [Console]::OutputEncoding = $prevEnc } } catch { }

# The same folder can be found twice when scan folders overlap
$found = @($found | Group-Object path -CaseSensitive:(-not $onWindows) | ForEach-Object { $_.Group[0] })

# ---- GitHub username: parameter/config > gh > git config > most common owner ----
if (-not $User -and $ghAuthed) {
    $u = & $gh.Source api user --jq .login 2>$null
    if ($LASTEXITCODE -eq 0 -and $u) { $User = "$u".Trim() }
}
if (-not $User) {
    $u = git config --global github.user 2>$null
    if ($u) { $User = "$u".Trim() }
}
if (-not $User) {
    $top = $found | Where-Object owner | Group-Object owner | Sort-Object Count -Descending | Select-Object -First 1
    if ($top) { $User = $top.Name }
}
$mine = @(@($User) + @($Owners) | Where-Object { $_ })
foreach ($r in $found) {
    if ($r.status -eq 'Remote') {
        $r.status = if (-not $r.owner) { 'Other remote' }
                    elseif ($mine -contains $r.owner) { 'Mine on GitHub' }
                    else { 'Third-party clone' }
    }
}

# ---- Folder column: hide the part of the path that every repo shares ----
function Get-CommonDir([string[]]$dirs) {
    $parts = @($dirs | ForEach-Object { , ($_ -split '[\\/]') })
    $first = $parts[0]
    $n = $first.Count
    foreach ($p in $parts) {
        $i = 0
        while ($i -lt $n -and $i -lt $p.Count -and $p[$i] -ieq $first[$i]) { $i++ }
        $n = $i
    }
    if ($n -eq 0) { return '' }
    return ($first[0..($n - 1)] -join $sep)
}
if (-not $Strip) { $Strip = if ($found.Count -ge 2) { Get-CommonDir @($found | ForEach-Object { $_.parent }) } else { '' } }
$Strip = "$Strip".TrimEnd('\', '/')
foreach ($r in $found) {
    $rel = $r.parent
    if ($Strip -and $rel.StartsWith($Strip, [StringComparison]::OrdinalIgnoreCase)) {
        $rel = $rel.Substring($Strip.Length).TrimStart('\', '/')
    }
    $r.folder = if ($rel) { $rel } else { '.' }
}

# ---- flag repos that share the same remote ----
$dupRemotes = $found | Where-Object { $_.remote } | Group-Object remote |
              Where-Object Count -gt 1 | ForEach-Object Name
$found | Where-Object { $dupRemotes -contains $_.remote } | ForEach-Object { $_.dup = $true }

# ---- work state: uncommitted / unpushed / unpulled ----
# One read-only "git status" per repo, several at a time. Nothing inside a repo is changed (no optional locks, so a repo
# that is busy with another git command is still readable). Git's own ownership check stays ON here (status can run
# commands named in a repo's config, so it must not run in folders owned by someone else); such repos are marked
# "owned by another user" instead, and the Commands panel shows how to mark one safe. With -Fetch the remote is contacted first so "unpulled"
# is current; without it, "unpulled" is only as fresh as the repo's last fetch. Each git call has a time limit.
$statusTimeoutSec = 30; $fetchTimeoutSec = 30
$tHook = if ($env:REPOATLAS_TIMEOUT_SEC) { $env:REPOATLAS_TIMEOUT_SEC } else { $env:FINDREPOS_TIMEOUT_SEC }
if ($tHook -match '^\d{1,4}$') { $statusTimeoutSec = [int]$tHook; $fetchTimeoutSec = [int]$tHook }   # test hook

$statusWorker = {
    param([string]$gitExe, [string]$path, [bool]$noUntracked, [bool]$doFetch, [bool]$hasRemote, [string]$rname, [bool]$batchSsh, [int]$statusMs, [int]$fetchMs)

    # Runs git in the repo folder with a time limit. Never prompts: stdin is closed and credential prompts are off.
    function Invoke-Git([string]$argLine, [bool]$net, [int]$ms) {
        $res = @{ ok = $false; timeout = $false; out = ''; err = '' }
        $p = $null
        try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $gitExe
            $psi.Arguments = $argLine
            $psi.WorkingDirectory = $path
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $psi.RedirectStandardInput = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
            $ev = $psi.EnvironmentVariables
            foreach ($k in 'GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE') { if ($ev.ContainsKey($k)) { $ev.Remove($k) } }
            $ev['GIT_OPTIONAL_LOCKS'] = '0'
            $ev['GIT_TERMINAL_PROMPT'] = '0'
            if ($net) {
                $ev['GCM_INTERACTIVE'] = 'never'
                if ($batchSsh) { $ev['GIT_SSH_COMMAND'] = 'ssh -o BatchMode=yes -o ConnectTimeout=15' }
            }
            $p = [System.Diagnostics.Process]::Start($psi)
            try { $p.StandardInput.Close() } catch { }
            $outT = $p.StandardOutput.ReadToEndAsync()
            $errT = $p.StandardError.ReadToEndAsync()
            if (-not $p.WaitForExit($ms)) {
                $res.timeout = $true
                try { $p.Kill($true) } catch {
                    try { & taskkill.exe /PID $p.Id /T /F *> $null } catch { }
                    try { $p.Kill() } catch { }
                }
                return $res
            }
            $p.WaitForExit()
            if ($outT.Wait(5000)) { $res.out = [string]$outT.Result } else { return $res }
            if ($errT.Wait(1000)) { $res.err = [string]$errT.Result }      # only used to recognise a problem, never shown
            $res.ok = ($p.ExitCode -eq 0)
        }
        catch { $res.ok = $false }
        finally { if ($p) { try { $p.Dispose() } catch { } } }
        return $res
    }

    function Get-Status {
        $s = @{ state = 'error'; branch = ''; sha = ''; detached = $false; initial = $false; up = ''; upGone = $false
                ahead = $null; behind = $null; tracked = 0; staged = 0; unstaged = 0; conflicts = 0; untracked = 0 }
        $r = Invoke-Git ('-c core.fsmonitor=false -c core.quotePath=false status --porcelain=v2 --branch --untracked-files=' + $(if ($noUntracked) { 'no' } else { 'normal' })) $false $statusMs
        if ($r.timeout) { $s.state = 'timeout'; return $s }
        if (-not $r.ok) { if ($r.err -match 'dubious ownership') { $s.state = 'unsafe' }; return $s }
        $s.state = 'ok'
        foreach ($line in ($r.out -split "`n")) {
            $line = $line.TrimEnd("`r")
            if ($line.Length -lt 2) { continue }
            $c = $line.Substring(0, 1)
            if ($c -ceq '#') {
                if     ($line.StartsWith('# branch.oid '))      { $v = $line.Substring(13); if ($v -eq '(initial)') { $s.initial = $true } else { $s.sha = $v.Substring(0, [Math]::Min(7, $v.Length)) } }
                elseif ($line.StartsWith('# branch.head '))     { $v = $line.Substring(14); if ($v -eq '(detached)') { $s.detached = $true } else { $s.branch = $v } }
                elseif ($line.StartsWith('# branch.upstream ')) { $s.up = $line.Substring(18) }
                elseif ($line -match '^# branch\.ab \+(\d+) -(\d+)') { $s.ahead = [int]$matches[1]; $s.behind = [int]$matches[2] }
            }
            elseif ($c -ceq '1' -or $c -ceq '2') {
                $s.tracked++
                if ($line.Length -ge 4) { if ($line[2] -ne '.') { $s.staged++ }; if ($line[3] -ne '.') { $s.unstaged++ } }
            }
            elseif ($c -ceq 'u') { $s.tracked++; $s.conflicts++ }
            elseif ($c -ceq '?') { $s.untracked++ }
        }
        $s.upGone = ($s.up -ne '' -and $null -eq $s.ahead)
        return $s
    }

    $s = Get-Status
    $fetch = ''
    if ($doFetch -and $s.state -eq 'ok' -and $hasRemote) {
        $fa = '-c core.fsmonitor=false fetch --quiet --no-recurse-submodules'
        if ($s.up -eq '') { $fa += ' "' + ($rname -replace '"', '') + '"' }    # no tracking branch: fetch the repo's remote by name
        $f = Invoke-Git $fa $true $fetchMs
        if     ($f.timeout) { $fetch = 'timeout' }
        elseif (-not $f.ok) { $fetch = 'failed' }
        else   { $fetch = 'ok'; $s2 = Get-Status; if ($s2.state -eq 'ok') { $s = $s2 } }
    }
    # No upstream (or it is gone): count commits that exist on no remote branch at all
    if ($s.state -eq 'ok' -and $hasRemote -and -not $s.initial -and ($s.up -eq '' -or $null -eq $s.ahead)) {
        $c = Invoke-Git '-c core.fsmonitor=false rev-list --count HEAD --not --remotes' $false $statusMs
        if ($c.ok -and ([string]$c.out).Trim() -match '^\d+$') { $s.ahead = [int]([string]$c.out).Trim() }
    }
    $at = ''
    try {
        $fh = [IO.Path]::Combine($path, '.git', 'FETCH_HEAD')
        if ([IO.File]::Exists($fh)) { $at = [IO.File]::GetLastWriteTime($fh).ToString('yyyy-MM-dd') }
    } catch { }
    $s.fetch = $fetch; $s.fetchedAt = $at
    [pscustomobject]$s
}

$workList = @($found | Where-Object { $_.status -ne 'Broken' -and $_.status -ne 'Error' })
if (-not $NoStatus -and $workList.Count -gt 0) {
    $batchSsh = $false
    if ($Fetch -and -not $env:GIT_SSH_COMMAND) { $cs = git config --get core.sshCommand 2>$null; if (-not $cs) { $batchSsh = $true } }   # keep the user's own ssh setup when there is one
    $pool = [runspacefactory]::CreateRunspacePool(1, [Math]::Min(8, [Math]::Max(2, [Environment]::ProcessorCount)))
    $pool.Open()
    $jobs = @()
    try {
        foreach ($r in $workList) {
            $ps = [powershell]::Create(); $ps.RunspacePool = $pool
            [void]$ps.AddScript($statusWorker.ToString()).AddArgument($git.Source).AddArgument($r.path).AddArgument([bool]$IgnoreUntracked).AddArgument([bool]$Fetch).
                      AddArgument([bool]($r.status -ne 'Local only')).AddArgument([string]$r.rname).AddArgument($batchSsh).
                      AddArgument([int]($statusTimeoutSec * 1000)).AddArgument([int]($fetchTimeoutSec * 1000))
            $jobs += [pscustomobject]@{ rec = $r; ps = $ps; handle = $ps.BeginInvoke() }
        }
        $verb = if ($Fetch) { 'Fetching and checking' } else { 'Checking' }
        while ($true) {
            $done = @($jobs | Where-Object { $_.handle.IsCompleted }).Count
            Write-Progress -Activity "$verb work state" -Status "$done of $($jobs.Count)" -PercentComplete (100 * $done / [Math]::Max(1, $jobs.Count))
            if ($done -ge $jobs.Count) { break }
            Start-Sleep -Milliseconds 120
        }
        Write-Progress -Activity "$verb work state" -Completed
        foreach ($j in $jobs) {
            try   { $res = @($j.ps.EndInvoke($j.handle)); if ($res.Count) { $j.rec.st = $res[$res.Count - 1] } }
            catch { }
            if (-not $j.rec.st) { $j.rec.st = [pscustomobject]@{ state = 'error'; fetch = ''; fetchedAt = '' } }
            $j.ps.Dispose()
        }
    }
    finally { try { $pool.Close(); $pool.Dispose() } catch { } }
    $bad = @($workList | Where-Object { $_.st.state -ne 'ok' }).Count
    if ($bad) { Write-Host "Work state: $bad of $($workList.Count) repos could not be checked (too slow to answer, or owned by another user) and are marked as such in the report." }
    if ($Fetch) {
        $ff = @($workList | Where-Object { $_.st.fetch -eq 'failed' -or $_.st.fetch -eq 'timeout' }).Count
        if ($ff) { Write-Host "Fetch: $ff repos could not be reached (offline, or a password is needed). Their 'unpulled' count may be out of date." }
    }
}

# ---- size on disk ----
# How much space each repo uses, split three ways: its own files, git's history (.git) and files git ignores
# (node_modules, build output, .env and so on). Read-only: it only lists folders and adds up file sizes (the size of
# the data, as Explorer and Finder show it, not the disk blocks). It does not follow links (a link as the ignored folder
# itself included), leaves out repos that sit inside another listed repo (they have their own row), and each repo has a
# time limit, after which the number is marked "at least". The parts are measured own files first, then .git, then ignored
# folders, so a time-out cuts the biggest, least important part (and says which). The list of ignored files comes from
# git itself, so it follows each repo's own .gitignore rules.
$sizeTimeoutSec = 60
$sHook = if ($env:REPOATLAS_SIZE_TIMEOUT_SEC) { $env:REPOATLAS_SIZE_TIMEOUT_SEC } else { $env:FINDREPOS_SIZE_TIMEOUT_SEC }
if ($sHook -match '^\d{1,4}$') { $sizeTimeoutSec = [int]$sHook }   # test hook
$sizeWorker = {
    param([string]$gitExe, [string]$path, [bool]$askGit, [int]$limitMs, [string[]]$nestedRepos)
    $clock   = [System.Diagnostics.Stopwatch]::StartNew()
    $cut     = @{}                        # which parts ran out of time or hit an unreadable folder ('own', 'git', 'ign'); a table, so the helper function can set it
    $known   = @('node_modules', 'venv', '.venv', 'env', '__pycache__', 'dist', 'build', 'target', 'out', '.next', '.nuxt', '.gradle', '.cache', 'coverage', 'bin', 'obj', 'vendor', '.tox', '.pytest_cache', 'Pods', 'DerivedData')
    $skip    = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)   # never counted by the folder walk
    $nest    = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)   # other repos inside this one (they are listed, and sized, on their own)

    # sums the files under one folder; returns bytes. Does not enter links or anything in $skip. Stops quietly at the time limit;
    # $phase is remembered when the number is cut short, so the report can say which part is a minimum.
    function Measure-Tree([string]$root, [string]$phase) {
        $sum = [long]0
        $stack = New-Object System.Collections.Generic.Stack[string]
        $stack.Push($root)
        while ($stack.Count -gt 0) {
            if ($clock.ElapsedMilliseconds -gt $limitMs) { $cut[$phase] = $true; break }
            $d = $stack.Pop()
            try {
                foreach ($e in ([System.IO.DirectoryInfo]$d).EnumerateFileSystemInfos()) {
                    if ($e.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }      # links are not followed
                    if ($skip.Contains($e.FullName)) { continue }
                    if ($e.Attributes -band [System.IO.FileAttributes]::Directory) { $stack.Push($e.FullName) }
                    else { $sum += ([System.IO.FileInfo]$e).Length }
                }
            } catch { $cut[$phase] = $true }                                                          # unreadable folder: the number is a minimum
        }
        return $sum
    }

    # git's list of ignored files and folders (folders collapsed to one entry). Not available for repos git will not open.
    $ignored = @()
    $listed  = $false
    if ($askGit) {
        $p = $null
        try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $gitExe
            $psi.Arguments = '-c core.fsmonitor=false -c core.quotePath=false ls-files -z --others --ignored --exclude-standard --directory'
            $psi.WorkingDirectory = $path
            $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
            $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
            $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
            $ev = $psi.EnvironmentVariables
            foreach ($k in 'GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE') { if ($ev.ContainsKey($k)) { $ev.Remove($k) } }
            $ev['GIT_OPTIONAL_LOCKS'] = '0'; $ev['GIT_TERMINAL_PROMPT'] = '0'
            $p = [System.Diagnostics.Process]::Start($psi)
            try { $p.StandardInput.Close() } catch { }
            $outT = $p.StandardOutput.ReadToEndAsync(); $errT = $p.StandardError.ReadToEndAsync()
            if ($p.WaitForExit([Math]::Max(5000, [int]($limitMs / 2)))) {
                $p.WaitForExit()
                if ($p.ExitCode -eq 0 -and $outT.Wait(5000)) { $listed = $true; $ignored = @(([string]$outT.Result) -split "`0" | Where-Object { $_ }) }
            } else { try { $p.Kill($true) } catch { try { $p.Kill() } catch { } } }
        } catch { }
        finally { if ($p) { try { $p.Dispose() } catch { } } }
    }

    try { $path = [IO.Path]::GetFullPath($path) } catch { }     # same spelling as the folder listing gives back, so paths compare equal
    $gitDir = [IO.Path]::Combine($path, '.git')
    $gitIsDir = [IO.Directory]::Exists($gitDir)
    $elsewhere = (-not $gitIsDir) -and [IO.File]::Exists($gitDir)    # a linked worktree or submodule: its history is kept in another folder
    [void]$skip.Add($gitDir)
    foreach ($n in $nestedRepos) { if ($n) { [void]$nest.Add($n); [void]$skip.Add($n) } }

    # ignored paths -> full path set, so the main walk can skip them and they are counted once, under "ignored"
    $entries = New-Object System.Collections.Generic.List[object]
    $ign  = @{}
    $ignBytes = [long]0
    # git can list a folder AND the ignored folders inside it; keep only the innermost entries so nothing is counted twice
    $anc = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($rel in $ignored) { $t = $rel.TrimEnd('/'); $i = $t.LastIndexOf('/'); while ($i -gt 0) { $t = $t.Substring(0, $i); [void]$anc.Add($t); $i = $t.LastIndexOf('/') } }
    $ignored = @($ignored | Where-Object { -not $anc.Contains($_.TrimEnd('/')) })
    foreach ($rel in $ignored) {
        $isDir = $rel.EndsWith('/')
        $full  = [IO.Path]::Combine($path, ($rel.TrimEnd('/') -replace '/', [string][IO.Path]::DirectorySeparatorChar))
        try { $full = [IO.Path]::GetFullPath($full) } catch { }
        [void]$skip.Add($full)
        $entries.Add([pscustomobject]@{ full = $full; isDir = $isDir })
    }

    # Measuring order matters because of the time limit: the repo's own files first (everything except .git, the ignored
    # paths and repos listed separately), then .git, then the ignored folders. A huge node_modules can then only cut
    # short its own number, never the numbers for your files and git history.
    $own = Measure-Tree $path 'own'
    $gitBytes = [long]0
    if ($gitIsDir) { $gitBytes = Measure-Tree $gitDir 'git' }
    $ignBytes = [long]0
    foreach ($en in $entries) {
        $full = $en.full
        $b = [long]0
        try {
            if ([IO.Directory]::Exists($full) -or [IO.File]::Exists($full)) {
                $attr = [IO.File]::GetAttributes($full)
                if ($attr -band [System.IO.FileAttributes]::ReparsePoint) { }                       # a link (junction or symlink): not followed
                elseif ($nest.Contains($full)) { }                                                  # another repo: counted in its own row
                elseif ($en.isDir -or ($attr -band [System.IO.FileAttributes]::Directory)) { $b = Measure-Tree $full 'ign' }
                else { $b = ([System.IO.FileInfo]$full).Length }
            }
        } catch { $cut['ign'] = $true }
        $ignBytes += $b
        $leaf = [IO.Path]::GetFileName($full)
        $key  = if ($known -contains $leaf) { $leaf } else { 'other' }
        if ($ign.ContainsKey($key)) { $ign[$key] += $b } else { $ign[$key] = $b }
    }
    # git would not open this repo, so ignored files could not be told apart: report the files as one unsplit number
    $un = [long]0
    if (-not $listed) { $un = $own; $own = [long]0 }
    [pscustomobject]@{
        total = [long]($own + $un + $gitBytes + $ignBytes); own = [long]$own; un = [long]$un; git = [long]$gitBytes; ign = [long]$ignBytes
        parts = @($ign.GetEnumerator() | Where-Object { $_.Value -gt 0 } | Sort-Object Value -Descending | ForEach-Object { [pscustomobject]@{ n = [string]$_.Key; b = [long]$_.Value } })
        listed = $listed; partial = [bool]$cut.Count; cut = @($cut.Keys); nest = [int]$nest.Count; elsewhere = [bool]$elsewhere
    }
}

if (-not $NoSize -and $found.Count -gt 0) {
    $pool = [runspacefactory]::CreateRunspacePool(1, [Math]::Min(8, [Math]::Max(2, [Environment]::ProcessorCount)))
    $pool.Open()
    $jobs = @()
    # repos that sit inside another listed repo are sized on their own row, so the outer repo leaves them out
    $fullOf = @{}
    foreach ($r in $found) { $fullOf[$r.path] = try { [IO.Path]::GetFullPath($r.path).TrimEnd('\', '/') } catch { [string]$r.path } }
    $dirSep = [string][IO.Path]::DirectorySeparatorChar
    try {
        foreach ($r in $found) {
            $me = $fullOf[$r.path]
            $inside = [string[]]@($fullOf.Values | Where-Object { $_ -ne $me -and $_.StartsWith($me + $dirSep, [StringComparison]::OrdinalIgnoreCase) })
            $ps = [powershell]::Create(); $ps.RunspacePool = $pool
            [void]$ps.AddScript($sizeWorker.ToString()).AddArgument($git.Source).AddArgument($r.path).
                      AddArgument([bool]($r.status -ne 'Broken' -and $r.status -ne 'Error')).AddArgument([int]($sizeTimeoutSec * 1000)).AddArgument($inside)
            $jobs += [pscustomobject]@{ rec = $r; ps = $ps; handle = $ps.BeginInvoke() }
        }
        while ($true) {
            $done = @($jobs | Where-Object { $_.handle.IsCompleted }).Count
            Write-Progress -Activity 'Measuring size on disk' -Status "$done of $($jobs.Count)" -PercentComplete (100 * $done / [Math]::Max(1, $jobs.Count))
            if ($done -ge $jobs.Count) { break }
            Start-Sleep -Milliseconds 150
        }
        Write-Progress -Activity 'Measuring size on disk' -Completed
        foreach ($j in $jobs) {
            try   { $res = @($j.ps.EndInvoke($j.handle)); if ($res.Count) { $j.rec.sz = $res[$res.Count - 1] } } catch { }
            $j.ps.Dispose()
        }
    }
    finally { try { $pool.Close(); $pool.Dispose() } catch { } }
    $cut = @($found | Where-Object { $_.sz -and $_.sz.partial }).Count
    if ($cut) { Write-Host "Size: $cut of $($found.Count) repos were too big to finish in $sizeTimeoutSec seconds (or had unreadable folders). Their sizes are shown as 'at least'." }
}

# ---- private-details view ----
# Every sensitive value gets a stable placeholder: the same name always becomes the same alias, so duplicates still
# line up and the report stays readable. The page switches between real and placeholder values (button in the report);
# with -Redact the real values are left out of the file completely.
$stopTokens = @('git', 'config', 'global', 'add', 'safe', 'directory', 'call', 'fatal', 'error', 'not', 'repository',
                'remote', 'origin', 'ownership', 'dubious', 'detected', 'exception', 'this', 'for', 'the', 'and', 'main', 'master')
function Get-MaskedRepos($Items, [string]$Me, [string]$Strip) {
    $cmp  = [StringComparer]::OrdinalIgnoreCase
    $maps = @{}
    foreach ($k in 'repo', 'dir', 'owner', 'host', 'remote', 'rname', 'branch') { $maps[$k] = [System.Collections.Hashtable]::new($cmp) }
    if (-not $Strip -and @($Items).Count -eq 1) { $Strip = "$(@($Items)[0].parent)" }    # one repo: its folder is the shared root
    $width  = [Math]::Max(2, "$(@($Items).Count)".Length)
    $tokens = [System.Collections.Generic.HashSet[string]]::new($cmp)

    function Get-Placeholder([string]$kind, [string]$value, [string]$prefix) {
        $m = $maps[$kind]
        if (-not $m.ContainsKey($value)) { $m[$value] = '{0}-{1}' -f $prefix, ($m.Count + 1).ToString().PadLeft($width, '0') }
        return $m[$value]
    }
    function Get-OwnerAlias([string]$o) { if ($Me -and $o -ieq $Me) { 'you' } else { Get-Placeholder 'owner' $o 'owner' } }
    function Add-Tokens([string]$text, [string]$splitter) {
        foreach ($s in @($text -split $splitter)) { if ($s.Length -ge 3 -and $s -notmatch '^[A-Za-z]:$' -and $stopTokens -notcontains $s) { [void]$tokens.Add($s) } }
    }
    function Hide-Path([string]$p, [string]$name) {
        # the folder every repo shares becomes one "<root>"; the rest gets a placeholder per folder
        $lead = @(); $rest = $p
        if ($Strip -and $p.StartsWith($Strip, [StringComparison]::OrdinalIgnoreCase) -and
            ($p.Length -eq $Strip.Length -or $p[$Strip.Length] -eq '\' -or $p[$Strip.Length] -eq '/')) {
            $lead = @('<root>'); $rest = $p.Substring($Strip.Length).TrimStart('\', '/')
        }
        $segs = @($rest -split '[\\/]')
        $out  = @(for ($i = 0; $i -lt $segs.Count; $i++) {
            $s = $segs[$i]
            if     ($i -eq $segs.Count - 1)                   { Get-Placeholder 'repo' $name 'repo' }
            elseif ($s -eq '' -or $s -match '^[A-Za-z]:$')    { $s }
            else                                              { Get-Placeholder 'dir' $s 'folder' }
        })
        return ((@($lead) + $out) -join $sep)
    }
    function Hide-Folder([string]$f) {
        if (-not $f -or $f -eq '.') { return $f }
        return ((@($f -split '[\\/]') | ForEach-Object { Get-Placeholder 'dir' $_ 'folder' }) -join $sep)
    }
    # returns @(remote text, url)
    function Hide-Remote($r) {
        if (-not $r.remote) { return @('', '') }
        if ($r.owner) {                                   # GitHub: "owner/repo"
            $parts = @($r.remote -split '/')
            $mid   = @(for ($i = 0; $i -lt $parts.Count - 1; $i++) { if ($i -eq 0) { Get-OwnerAlias $parts[0] } else { Get-Placeholder 'dir' $parts[$i] 'folder' } })
            $m     = (@($mid) + (Get-Placeholder 'repo' $parts[$parts.Count - 1] 'repo')) -join '/'
            return @($m, "https://github.com/$m")
        }
        if ($r.remote -notmatch '^(?:[A-Za-z]:[\\/]|/|\.)' -and
            $r.remote -match '^(?:[A-Za-z][A-Za-z0-9+.\-]*://)?(?:[^@/\s]+@)?(?<h>[^/:\s]+)(?::\d+)?[:/](?<p>.+?)(?:\.git)?/?$') {
            $hn    = Get-Placeholder 'host' $matches.h 'host'
            $segs  = @($matches.p -split '/' | Where-Object { $_ })
            $path  = @(for ($i = 0; $i -lt $segs.Count; $i++) { if ($i -eq $segs.Count - 1) { Get-Placeholder 'repo' $segs[$i] 'repo' } else { Get-Placeholder 'owner' $segs[$i] 'owner' } }) -join '/'
            $m     = "$hn/$path"
            return @($m, $(if ($r.url) { "https://$m" } else { '' }))
        }
        return @((Get-Placeholder 'remote' $r.remote 'remote'), '')    # a local path or anything unusual
    }
    # Branch names can describe private work ("fix-acme-invoice"), so they become placeholders too. Generic names stay.
    function Hide-Branch([string]$b) {
        if (-not $b) { return '' }
        if ($b -in @('main', 'master', 'develop', 'dev', 'trunk')) { return $b }
        return (Get-Placeholder 'branch' $b 'branch')
    }
    function Hide-Upstream([string]$u) {            # "origin/feature-x" -> "origin/branch-02"
        if (-not $u) { return '' }
        $i = $u.IndexOf('/')
        if ($i -lt 1) { return (Hide-Branch $u) }
        $rn = $u.Substring(0, $i)
        $rn = if ($rn -in @('origin', 'upstream')) { $rn } else { Get-Placeholder 'rname' $rn 'remote-name' }
        return ($rn + '/' + (Hide-Branch $u.Substring($i + 1)))
    }
    # the counts are not private and stay; only branch names change
    function Hide-State($st) {
        if (-not $st) { return $null }
        $c = $st.PSObject.Copy()
        if ($c.PSObject.Properties['branch']) { $c.branch = (Hide-Branch ([string]$c.branch)) }
        if ($c.PSObject.Properties['up'])     { $c.up     = (Hide-Upstream ([string]$c.up)) }
        return $c
    }
    # Git messages often contain paths and URLs: remove those, and if a known name is still in there, hide the whole message
    function Hide-ErrText([string]$t) {
        if (-not $t) { return '' }
        $s = $t
        $s = [regex]::Replace($s, '''[^''\r\n]*[\\/][^''\r\n]*''', '''<path>''')
        $s = [regex]::Replace($s, '(?i)\b[a-z][a-z0-9+.\-]*://[^\s''"]+', '<url>')
        $s = [regex]::Replace($s, '[\w.\-]+@[\w.\-]+:[^\s''"]+', '<remote>')
        $s = [regex]::Replace($s, '(?i)\b[a-z]:[\\/][^\s''"]*[^\s''".,:;]', '<path>')
        $s = [regex]::Replace($s, '\\\\[^\s''"]*[^\s''".,:;]', '<path>')
        $s = [regex]::Replace($s, '(?<![\w<])/[^\s''"]*[^\s''".,:;]', '<path>')
        $s = [regex]::Replace($s, '(?i)\b(?!github\.com\b)[a-z0-9][a-z0-9\-]*(?:\.[a-z0-9\-]+)*\.[a-z]{2,}\b', '<host>')   # host names
        foreach ($tok in $tokens) {
            if ([regex]::IsMatch($s, '(?<![\w-])' + [regex]::Escape($tok) + '(?![\w-])', 'IgnoreCase')) { return 'Details hidden.' }
        }
        $s = $s.Trim()
        if ($s.Length -gt 300) { $s = $s.Substring(0, 300) + '...' }
        return $s
    }

    if ($Me.Length -ge 3) { [void]$tokens.Add($Me) }
    $recs = @(foreach ($r in $Items) {
        Add-Tokens $r.path '[\\/]'
        Add-Tokens $r.name '[\\/]'
        Add-Tokens $r.remote '[\\/:@]'
        $rm = Hide-Remote $r
        [pscustomobject]@{
            name   = (Get-Placeholder 'repo' $r.name 'repo')
            remote = $rm[0]
            rname  = $(if ($r.rname -in @('origin', 'upstream')) { $r.rname } else { Get-Placeholder 'rname' $r.rname 'remote-name' })
            url    = $rm[1]
            folder = (Hide-Folder $r.folder)
            path   = (Hide-Path $r.path $r.name)
            status = $r.status
            dup    = $r.dup
            err    = $r.err
            st     = (Hide-State $r.st)
            sz     = $r.sz
        }
    })
    foreach ($x in $recs) { $x.err = Hide-ErrText $x.err }    # after all names are known
    return $recs
}

$sorted = @($found | Sort-Object name)
$repos  = @($sorted | Select-Object name, remote, rname, url, folder, path, status, dup, err, st, sz)
$masked = @(Get-MaskedRepos $sorted "$User" "$Strip")
if ($Redact) { $repos = $masked }
else { for ($i = 0; $i -lt $repos.Count; $i++) { Add-Member -InputObject $repos[$i] -NotePropertyName m -NotePropertyValue $masked[$i] } }
$json  = (ConvertTo-Json -InputObject $repos -Compress -Depth 8) -replace '</', '<\/'

$opener = if ($onWindows) { 'start' } elseif ($IsMacOS) { 'open' } else { 'xdg-open' }
$meta   = [pscustomobject]@{
    sep = "$sep"; open = $opener
    me  = $(if ($Redact) { 'you' } else { "$User" })
    roots = @(if (-not $Redact) { $Root })
    rootsCount = @($Root).Count
    redacted = [bool]$Redact
    work = [pscustomobject]@{ fetch = [bool]$Fetch; noUntracked = [bool]$IgnoreUntracked }
    size = (-not $NoSize)
    version = $appVersion
}
$metaJson = (ConvertTo-Json -InputObject $meta -Compress) -replace '</', '<\/'

$template = @'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>RepoAtlas</title>
<style>
  :root {
    --bg:#f6f7f9; --card:#ffffff; --text:#1c2128; --muted:#6b7280; --line:#e3e6ea;
    --accent:#2563eb; --broken:#dc2626; --local:#b45309; --mine:#15803d; --third:#7c3aed; --other:#0e7490; --error:#6b7280;
    --hbg:#0f1b2a; --hline:#26384e; --htext:#eaf0f7; --hmuted:#a9b8c9; --hsignal:#5ab0ff;
  }
  @media (prefers-color-scheme: dark) {
    :root { --bg:#0f1318; --card:#171c23; --text:#e6e9ee; --muted:#8b95a3; --line:#262d37; --accent:#60a5fa; }
  }
  * { box-sizing:border-box; }
  [hidden] { display:none !important; }
  body { margin:0; background:var(--bg); color:var(--text); font:14px/1.45 system-ui, "Segoe UI", sans-serif; }
  .wrap { max-width:1100px; margin:0 auto; padding:20px 16px 64px; }

  /* ---- top section: dark band with the status strip ---- */
  .hero { background:var(--hbg); color:var(--htext); border-bottom:1px solid var(--hline); }
  .hero-in { max-width:1100px; margin:0 auto; padding:20px 16px 26px; }
  .hero-top { display:flex; flex-wrap:wrap; justify-content:space-between; align-items:flex-start; gap:12px 16px; margin-bottom:20px; }
  .brand { flex:1 1 420px; min-width:0; display:flex; align-items:center; gap:16px; }
  .mark { flex:none; width:56px; height:56px; border-radius:15px; display:inline-flex; align-items:center; justify-content:center;
    color:var(--hsignal); background:rgba(90,176,255,.12); border:1px solid rgba(90,176,255,.35); }
  .bt { min-width:0; }
  .hero h1 { display:flex; align-items:baseline; flex-wrap:wrap; gap:4px 12px; margin:0; font-size:clamp(30px, 4.4vw, 42px); font-weight:700; line-height:1.05; letter-spacing:-.015em; color:#fff; }
  .ver { font-size:12.5px; font-weight:600; letter-spacing:0; color:var(--hsignal); border:1px solid rgba(90,176,255,.45); border-radius:999px; padding:2px 9px; align-self:center; }
  .tag { margin:8px 0 0; color:#d3deea; font-size:clamp(15px, 1.6vw, 17px); line-height:1.4; max-width:62ch; }
  .by { margin:6px 0 0; color:var(--hmuted); font-size:13px; }
  .by b { color:var(--htext); font-weight:600; }
  .credit { margin:44px 0 0; padding-top:16px; border-top:1px solid var(--line); text-align:center; color:var(--muted); font-size:12.5px; }
  .credit b { color:var(--text); font-weight:600; }
  .acts { display:flex; flex-wrap:wrap; gap:8px; }
  .ico { display:inline-flex; flex:none; }
  .howbtn { color:var(--hsignal); }
  .howpanel { margin:0 0 20px; padding:14px 16px; background:var(--panel); border:1px solid #2f455f; border-radius:12px; }
  .howpanel p { margin:0 0 10px; font-size:14px; line-height:1.6; color:#d3deea; max-width:76ch; }
  .howl { margin:0; display:grid; grid-template-columns:auto 1fr; gap:6px 16px; font-size:13px; color:var(--hmuted); }
  .howl dt { color:var(--htext); font-weight:600; }
  .howl dd { margin:0; }

  /* 1. how many, and where they stand */
  .health { display:grid; grid-template-columns:auto minmax(0,1fr); gap:0 28px; align-items:end; }
  .count { display:flex; align-items:baseline; gap:8px; }
  .big { font-family:Bahnschrift, "DIN Alternate", "DIN Condensed", "Avenir Next Condensed", "Arial Narrow", system-ui, sans-serif;
    font-size:clamp(64px,8vw,84px); font-weight:600; font-stretch:85%; line-height:.85; letter-spacing:-.01em;
    font-variant-numeric:tabular-nums; }
  .unit { font-size:15px; color:var(--hmuted); }
  .strip { display:flex; gap:3px; height:42px; }
  .seg { flex:1 1 0; min-width:18px; border:0; border-radius:7px; padding:0 0 0 10px; display:flex; align-items:center;
    color:#fff; font:600 14px/1 system-ui, "Segoe UI", sans-serif; cursor:pointer;
    transition:opacity .15s, filter .15s; }
  .seg.nolabel .segn { display:none; }
  .seg:hover { filter:brightness(1.12); }
  .seg:focus-visible { outline:2px solid #fff; outline-offset:2px; }
  .seg.on { box-shadow:0 0 0 2px var(--hbg), 0 0 0 4px #fff; }
  .seg.dim, .k.dim { opacity:.38; }
  .key { display:flex; flex-wrap:wrap; gap:6px 18px; margin-top:11px; font-size:13px; color:var(--hmuted); }
  .k { display:inline-flex; align-items:center; gap:7px; cursor:pointer; transition:opacity .15s; }
  .k i { width:18px; height:18px; border-radius:5px; flex:none; display:inline-flex; align-items:center; justify-content:center; color:#fff; }
  .k b { color:var(--htext); font-weight:600; }
  .k.twice i { background:#3a5270; }
  .k.twice.on b, .k.twice.on { color:var(--hsignal); }

  /* 2. what to do first */
  .start { display:flex; align-items:center; gap:14px; width:100%; margin:20px 0 22px; text-align:left; font:inherit; color:var(--htext);
    background:rgba(248,113,113,.12); border:1px solid rgba(248,113,113,.45); border-left:4px solid #f87171; border-radius:10px; padding:11px 14px; }
  .start > .ico { color:#f87171; }
  .start p { margin:0; flex:1; font-size:14.5px; line-height:1.45; }
  .start p span { color:var(--hmuted); font-size:13px; margin-left:4px; }
  .start .go { display:inline-flex; align-items:center; gap:6px; flex:none; background:#f87171; color:#2a0b0b; font-weight:600; border-radius:8px; padding:6px 12px; font-size:13px; }
  .start.warn { background:rgba(251,191,36,.10); border-color:rgba(251,191,36,.4); border-left-color:#fbbf24; }
  .start.warn > .ico { color:#fbbf24; }
  .start.warn .go { background:#fbbf24; color:#2b1d02; }
  .start.good { background:rgba(74,222,128,.09); border-color:rgba(74,222,128,.35); border-left-color:#4ade80; }
  .start.good > .ico { color:#4ade80; }
  .start.info { background:transparent; border-color:#2f455f; border-left-color:var(--hsignal); }
  .start.info > .ico { color:var(--hsignal); }
  button.start { cursor:pointer; transition:filter .15s; }
  button.start:hover { filter:brightness(1.15); }
  button.start:focus-visible { outline:2px solid var(--hsignal); outline-offset:2px; }
  button.start.on .go { background:transparent; color:var(--htext); box-shadow:inset 0 0 0 1px currentColor; }

  /* 3. work state: each tile is a filter */
  .lab { display:flex; flex-wrap:wrap; align-items:center; gap:2px 10px; margin:0 0 9px; color:var(--hmuted); font-size:12.5px; }
  .lab h2 { display:flex; align-items:center; gap:7px; margin:0; font-size:12.5px; font-weight:600; }
  .lab h2 svg { color:var(--hsignal); }
  .lab span { white-space:normal; }
  .nw { white-space:nowrap; }
  .tiles { display:grid; grid-template-columns:repeat(auto-fit, minmax(150px, 1fr)); gap:10px; }
  .wt { display:flex; flex-direction:column; justify-content:flex-start; align-items:stretch; width:100%; text-align:left; border:1px solid #2f455f; background:var(--panel); color:var(--htext); border-radius:12px;
    padding:12px 14px; font:inherit; cursor:pointer; transition:background .15s, border-color .15s, opacity .15s; }
  .wt.off { border-style:dashed; background:transparent; }
  .th { display:flex; align-items:center; gap:8px; }
  .ib { width:26px; height:26px; border-radius:8px; display:inline-flex; align-items:center; justify-content:center; background:rgba(255,255,255,.08); color:var(--ic, var(--hsignal)); }
  .tl { font-size:13px; font-weight:600; }
  .tn { margin:8px 0 2px; font:600 32px/1.1 Bahnschrift, "DIN Alternate", "Arial Narrow", system-ui, sans-serif; font-variant-numeric:tabular-nums; }
  .ts { font-size:12px; color:var(--hmuted); line-height:1.35; }
  .wt:hover:not(:disabled) { border-color:var(--hsignal); }
  .wt:focus-visible { outline:2px solid var(--hsignal); outline-offset:2px; }
  .wt.on { background:var(--hsignal); border-color:var(--hsignal); color:#08131f; }
  .wt.on .ib { background:rgba(8,19,31,.14); color:#08131f; }
  .wt.on .ts { color:#16324d; }
  .wt:disabled { opacity:.45; cursor:default; }
  /* 4. disk space: one card, a big total, a bar and a legend */
  #disk { margin-top:24px; }
  .dcard { display:grid; grid-template-columns:auto minmax(0,1fr); gap:6px 28px; align-items:center; background:var(--panel); border:1px solid #2f455f; border-radius:12px; padding:16px 18px; }
  .dtot b { display:block; font:600 34px/1 Bahnschrift, "DIN Alternate", "Arial Narrow", system-ui, sans-serif; font-variant-numeric:tabular-nums; }
  .dtot small { display:block; margin-top:6px; color:var(--hmuted); font-size:12.5px; line-height:1.4; max-width:15ch; }
  .dbar { display:flex; height:16px; border-radius:8px; overflow:hidden; gap:2px; background:#1b2b40; }
  .dbar i { display:block; height:100%; min-width:3px; }
  .dleg { display:grid; grid-template-columns:repeat(auto-fit, minmax(190px, 1fr)); gap:10px 18px; margin-top:14px; }
  .dleg > div { min-width:0; }
  .dleg .dn { display:flex; align-items:baseline; gap:7px; font-size:13px; }
  .dleg .dn i { width:11px; height:11px; border-radius:3px; flex:none; align-self:center; }
  .dleg .dn b { font-size:15px; font-variant-numeric:tabular-nums; }
  .dleg .dn span { color:var(--hmuted); font-size:12px; }
  .dleg p { margin:2px 0 0 18px; color:var(--hmuted); font-size:12px; line-height:1.4; }
  .d-own { background:var(--hsignal); } .d-git { background:#94a3b8; } .d-ign { background:#f59e0b; }
  .d-un { background:repeating-linear-gradient(45deg, #64748b 0 4px, #94a3b8 4px 8px); }
  .dcat { grid-column:1 / -1; padding-top:12px; margin-top:6px; border-top:1px solid var(--hline); }
  .dcat h3 { margin:0 0 8px; font-size:13px; font-weight:600; color:var(--htext); }
  .dcat h3 span { font-weight:400; color:var(--hmuted); margin-left:6px; font-size:12px; }
  .dcr { display:grid; grid-template-columns:250px minmax(0,1fr) 130px; gap:4px 14px; align-items:center; width:100%; text-align:left; background:transparent; border:1px solid transparent; border-radius:8px; padding:7px 8px; color:var(--htext); font:inherit; cursor:pointer; }
  .dcr:hover { background:#1b2b40; }
  .dcr:focus-visible { outline:2px solid var(--hsignal); outline-offset:1px; }
  .dcr.on { border-color:var(--hsignal); background:#1b2b40; }
  .dcr.dim { opacity:.55; }
  .dcr .cn { display:flex; align-items:center; gap:8px; min-width:0; font-size:13.5px; white-space:nowrap; }
  .dcr .cn i { width:11px; height:11px; border-radius:3px; flex:none; }
  .dcr .cn small { color:var(--hmuted); font-size:12px; white-space:nowrap; }
  .dcr .ct { height:10px; border-radius:5px; background:#14233a; overflow:hidden; }
  .dcr .cf { display:flex; height:100%; gap:1px; min-width:3px; }
  .dcr .cf i { display:block; height:100%; min-width:1px; }
  .dcr .cv { text-align:right; font-size:12px; color:var(--hmuted); font-variant-numeric:tabular-nums; white-space:nowrap; }
  .dcr .cv b { font-size:14px; color:var(--htext); margin-right:6px; }
  .dtop { grid-column:1 / -1; display:flex; flex-wrap:wrap; align-items:center; gap:8px; padding-top:12px; margin-top:4px; border-top:1px solid var(--hline); font-size:12.5px; color:var(--hmuted); }
  .dchip { display:inline-flex; align-items:center; gap:7px; border:1px solid #3a5270; background:transparent; color:var(--htext); border-radius:999px; padding:4px 11px; font:inherit; font-size:12.5px; cursor:pointer; }
  .dchip b { font-variant-numeric:tabular-nums; color:var(--hsignal); font-weight:600; }
  .dchip:hover { border-color:var(--hsignal); }
  .dchip:focus-visible { outline:2px solid var(--hsignal); outline-offset:2px; }
  .dgo { margin-left:auto; }
  .foot { display:grid; gap:8px; margin-top:22px; padding-top:14px; border-top:1px solid var(--hline); color:#c4d1e0; font-size:13px; line-height:1.5; }
  .mi { display:flex; align-items:flex-start; gap:9px; min-width:0; overflow-wrap:anywhere; }
  .mi svg { margin-top:3px; color:var(--hsignal); }
  .mi b { color:var(--htext); font-weight:600; margin-right:4px; }
  @media (prefers-reduced-motion:no-preference) {
    .hero.intro .seg { animation:grow .7s cubic-bezier(.2,.7,.2,1) backwards; animation-delay:calc(var(--i) * 70ms); }
  }
  @keyframes grow { from { clip-path:inset(0 100% 0 0 round 7px); } to { clip-path:inset(0 0 0 0 round 7px); } }

  /* search and filters stay in reach while scrolling */
  .toolbar { position:sticky; top:0; z-index:10; background:var(--bg); border-bottom:1px solid transparent;
    transition:border-color .15s, box-shadow .15s; }
  .toolbar.stuck { border-bottom-color:var(--line); box-shadow:0 8px 14px -12px rgba(0,0,0,.45); }
  .toolbar-in { max-width:1100px; margin:0 auto; padding:12px 16px; display:flex; flex-wrap:wrap; gap:8px; align-items:center; }
  .shown { margin-left:auto; color:var(--muted); font-size:12.5px; }
  .priv { display:inline-flex; align-items:center; gap:7px; margin-top:10px; border:1px solid #3a5270; background:transparent; color:var(--htext);
    border-radius:999px; padding:6px 14px; font:inherit; font-size:13px; cursor:pointer; transition:background .15s, border-color .15s; }
  .priv:hover { border-color:var(--hsignal); }
  .priv:focus-visible { outline:2px solid var(--hsignal); outline-offset:2px; }
  .priv.on { background:var(--hsignal); border-color:var(--hsignal); color:#08131f; }
  .privacy { background:#16314d; border-bottom:1px solid var(--hline); color:var(--htext); font-size:13px; }
  .privacy-in { max-width:1100px; margin:0 auto; padding:8px 16px; display:flex; align-items:center; gap:9px; }
  .privacy svg { color:var(--hsignal); flex:none; }
  input[type=search] { flex:1 1 240px; padding:9px 12px; border:1px solid var(--line); border-radius:8px;
    background:var(--card); color:var(--text); font:inherit; }
  .fc { display:inline-flex; align-items:center; gap:6px; border:0; background:var(--accent); color:#fff; border-radius:999px; padding:5px 6px 5px 12px; font:inherit; font-size:13px; cursor:pointer; }
  .fc u { width:18px; height:18px; border-radius:50%; background:rgba(255,255,255,.25); display:inline-flex; align-items:center; justify-content:center; text-decoration:none; font-size:13px; line-height:1; }
  .fc:hover u { background:rgba(255,255,255,.4); }
  .fc:focus-visible { outline:2px solid var(--accent); outline-offset:2px; }
  .fhint { color:var(--muted); font-size:12.5px; }
  .chip { border:1px solid var(--line); background:var(--card); color:var(--text); padding:6px 12px;
    border-radius:999px; cursor:pointer; font:inherit; font-size:13px; }
  .chip.on { background:var(--accent); border-color:var(--accent); color:#fff; }
  .chip b { font-weight:600; opacity:.8; margin-left:4px; }
  section { margin-bottom:26px; }
  .gh { display:flex; align-items:center; gap:12px; margin:0 0 10px; }
  .pill { display:inline-flex; align-items:center; gap:8px; color:#fff; font-size:18px; font-weight:600;
    text-transform:uppercase; letter-spacing:.04em; padding:5px 16px; border-radius:999px; }
  .pill .n { background:rgba(255,255,255,.25); border-radius:999px; padding:0 9px; font-size:14px; }
  .gh small { color:var(--muted); font-size:13px; font-weight:400; }
  .tgs { margin-left:auto; display:flex; gap:8px; }
  .tog { border:1px solid var(--line); background:var(--card); color:var(--text);
    border-radius:999px; padding:5px 12px; font:inherit; font-size:13px; cursor:pointer; }
  .tog:hover { border-color:var(--accent); }
  .tog.on { background:var(--accent); border-color:var(--accent); color:#fff; }
  .dupset { border:1px dashed var(--muted); border-radius:12px; padding:8px 8px 2px; margin-bottom:12px; }
  .dupset .dl { font-size:12px; color:var(--muted); margin:0 4px 6px; }
  .row { display:grid; grid-template-columns:minmax(0,1.1fr) minmax(0,1.4fr) auto; gap:12px; align-items:center;
    background:var(--card); border:1px solid var(--line); border-radius:10px; padding:10px 14px; margin-bottom:6px; }
  .name { font-weight:600; overflow-wrap:anywhere; }
  .badge { font-size:11px; padding:1px 7px; border-radius:6px; margin-left:6px; background:var(--local); color:#fff; font-weight:500; }
  .meta { min-width:0; }
  .meta a { color:var(--accent); text-decoration:none; }
  .meta a:hover { text-decoration:underline; }
  .folder { color:var(--muted); font-size:12px; overflow-wrap:anywhere; }
  .row.hs { grid-template-columns:minmax(0,1.1fr) minmax(0,1.4fr) 104px auto; }
  .sz { min-width:0; cursor:help; }
  .sz b { display:block; font-size:13.5px; font-weight:600; font-variant-numeric:tabular-nums; white-space:nowrap; }
  .sz small { display:block; color:var(--muted); font-size:11px; }
  .sbar { display:flex; height:6px; border-radius:3px; overflow:hidden; background:var(--line); margin-top:4px; gap:1px; }
  .sbar i { display:block; height:100%; min-width:2px; }
  .s-un { background:#94a3b8; opacity:.6; }
  .s-own { background:var(--accent); } .s-git { background:#8b95a3; } .s-ign { background:#d97706; }
  .szbox { margin:0 0 10px; padding:10px 12px; border:1px solid var(--line); border-radius:8px; font-size:13px; }
  .szbox .ch { margin:0 0 6px; }
  .szl { display:grid; grid-template-columns:12px 1fr auto; gap:4px 10px; align-items:center; }
  .szl i { width:12px; height:12px; border-radius:3px; display:block; }
  .szl span:last-child { font-variant-numeric:tabular-nums; font-weight:600; }
  .szbox p { margin:8px 0 0; color:var(--muted); font-size:12px; line-height:1.45; }
  .tbsort { display:inline-flex; align-items:center; gap:6px; color:var(--muted); font-size:13px; }
  .tbsort select { font:inherit; color:var(--text); background:var(--card); border:1px solid var(--line); border-radius:8px; padding:5px 8px; }
  .btns { display:flex; gap:6px; }
  .btn { display:inline-flex; align-items:center; justify-content:center; gap:6px; min-width:98px;
    border:1px solid var(--line); background:transparent; color:var(--text); border-radius:8px;
    padding:6px 10px; font:inherit; font-size:12.5px; cursor:pointer; transition:background .12s, border-color .12s; }
  .btn svg { flex:none; }
  .btn:hover { border-color:var(--accent); color:var(--accent); }
  .btn:focus-visible { outline:2px solid var(--accent); outline-offset:2px; }
  .btn.primary { background:var(--accent); border-color:var(--accent); color:#fff; }
  .btn.primary:hover { filter:brightness(1.1); color:#fff; }
  .btn.done { background:var(--mine); border-color:var(--mine); color:#fff; }
  .btn.on { border-color:var(--accent); color:var(--accent); }
  /* work state on each repo */
  .wstate { display:flex; flex-wrap:wrap; gap:4px 6px; margin-top:6px; }
  .wc { display:inline-flex; align-items:center; gap:4px; border:1px solid var(--line); color:var(--muted); background:transparent;
    border-radius:999px; padding:0 9px; font-size:11.5px; line-height:1.65; white-space:nowrap; cursor:default; }
  .wc.br { color:var(--text); font-family:Consolas, "SF Mono", Menlo, monospace; font-size:11px; }
  .wc.hot { color:var(--text); border-color:var(--muted); }
  .wc.hot b { font-weight:700; }
  .wc.bad { color:var(--broken); border-color:var(--broken); }
  .err { margin:0 0 8px; padding:8px; background:var(--bg); border:1px solid var(--line); border-radius:6px;
    font:12px/1.4 Consolas, monospace; white-space:pre-wrap; overflow-wrap:anywhere; }
  .cheat { background:var(--card); border:1px solid var(--line); border-radius:12px; padding:12px 14px; margin-bottom:12px; }
  .cheat .ch { color:var(--muted); font-size:12px; margin-bottom:6px; }
  .ci { padding:10px 0; border-top:1px solid var(--line); }
  .ch + .ci { border-top:0; }
  .ci .ct { font-weight:600; }
  .ci .cd { color:var(--muted); font-size:12.5px; margin:2px 0 6px; }
  .ci .cc { display:flex; gap:8px; align-items:center; }
  .ci code { flex:1; min-width:0; background:var(--bg); border:1px solid var(--line); border-radius:6px;
    padding:6px 8px; font:12.5px/1.4 Consolas, monospace; overflow-x:auto; white-space:nowrap; }
  .empty { color:var(--muted); text-align:center; padding:40px 0; }
  .toast { position:fixed; bottom:20px; left:50%; transform:translateX(-50%); background:var(--text); color:var(--bg);
    padding:8px 14px; border-radius:8px; font-size:13px; opacity:0; transition:opacity .2s; pointer-events:none; }
  .toast.show { opacity:1; }
  @media (max-width:760px) {
    .health { grid-template-columns:minmax(0,1fr); gap:14px; }
    .mark { width:44px; height:44px; border-radius:12px; }
    .brand { gap:12px; }
    .start { flex-wrap:wrap; }
    .tiles { grid-template-columns:1fr 1fr; }
    .dcard { grid-template-columns:minmax(0,1fr); }
    .dtot small { max-width:none; }
    .dgo { margin-left:0; }
    .dcr { grid-template-columns:minmax(0,1fr) auto; }
    .dcr .ct { grid-column:1 / -1; order:3; }
  }
  @media (max-width:700px) {
    .row, .row.hs { grid-template-columns:1fr; }
    .toolbar { position:static; }
    .shown { margin-left:0; }
  }
</style>
</head>
<body>
<header class="hero intro" id="hero">
  <div class="privacy" id="privacy" role="status" hidden>
    <div class="privacy-in">
      <svg width="15" height="15" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M1.5 8s2.4-4.5 6.5-4.5S14.5 8 14.5 8s-2.4 4.5-6.5 4.5S1.5 8 1.5 8z"/><circle cx="8" cy="8" r="2"/><path d="M2.5 2.5l11 11"/></svg>
      <span id="privtxt"></span>
    </div>
  </div>
  <div class="hero-in">
    <div class="hero-top">
      <div class="brand">
        <span class="mark" aria-hidden="true"><svg width="30" height="30" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M6.5 7.2 17.5 8.6M6.2 8 11 17.3M17.8 10 13 17.3"/><circle cx="5.5" cy="6.5" r="2.4" fill="currentColor" fill-opacity=".18"/><circle cx="18.5" cy="8.8" r="2.4" fill="currentColor" fill-opacity=".18"/><circle cx="12" cy="18.5" r="2.4" fill="currentColor" fill-opacity=".18"/></svg></span>
        <div class="bt">
          <h1>RepoAtlas<span class="ver" id="ver"></span></h1>
          <p class="tag">See every git repo on your computer, and what is at risk.</p>
          <p class="by">Created by <b>datacraft.yogi</b></p>
        </div>
      </div>
      <div class="acts">
        <button type="button" class="priv howbtn" id="howbtn" aria-expanded="false" aria-controls="how"><span class="ico" data-ico="help" data-s="15"></span>How it works</button>
        <button type="button" class="priv" id="priv" aria-pressed="false"></button>
      </div>
    </div>
    <div class="howpanel" id="how" hidden>
      <p>A map of every git repo on this computer, checked against GitHub: what is backed up, what exists only on this computer, what has duplicate copies, and what has work pending to commit or push.</p>
      <dl class="howl">
        <dt>Colours</dt><dd>Click a colour in the bar to show only those repos.</dd>
        <dt>Start here</dt><dd>The red or amber line is the most urgent thing. Click it to see those repos.</dd>
        <dt>Work state</dt><dd>Pending to commit = edits or new files not saved in a commit yet (git calls this uncommitted). Pending to push = saved commits that are not on GitHub yet (unpushed). Unpulled = commits on the remote that you do not have yet.</dd>
        <dt>Size</dt><dd>The number on each repo is the space its folder uses on disk. The bar splits it into your files (blue), git history (grey) and files git ignores, such as node_modules and builds (amber). Use Sort to put the largest first.</dd>
        <dt>Copy cd</dt><dd>Paste in a terminal to jump into that repo.</dd>
        <dt>Copy path</dt><dd>Copies just the folder path.</dd>
        <dt>Commands</dt><dd>Shows commands filled in for that repo, ready to copy.</dd>
        <dt>Duplicates only</dt><dd>Inside a group, shows repos that exist in more than one place.</dd>
      </dl>
    </div>
    <div class="health">
      <div class="count"><span class="big" id="big">0</span><span class="unit" id="unit"></span></div>
      <div>
        <div class="strip" id="strip" role="group" aria-label="Repos by status. Choose one to filter the list."></div>
        <div class="key" id="key"></div>
      </div>
    </div>
    <div id="startbox"></div>
    <div id="work" hidden>
      <div class="lab"><h2 id="h-work"><span class="ico" data-ico="commit" data-s="15"></span>Work state</h2><span id="workn"></span></div>
      <div class="tiles" id="workb" role="group" aria-labelledby="h-work"></div>
    </div>
    <div id="disk" hidden>
      <div class="lab"><h2 id="h-disk"><span class="ico" data-ico="drive" data-s="15"></span>Disk space</h2><span id="diskn"></span></div>
      <div class="dcard">
        <div class="dtot"><b id="dtot"></b><small id="dsub"></small></div>
        <div><div class="dbar" id="dbar" role="img"></div><div class="dleg" id="dleg"></div></div>
        <div class="dcat" id="dcat"></div>
        <div class="dtop" id="dtop"></div>
      </div>
    </div>
    <div class="foot">
      <span class="mi" id="mi1"><span class="ico" data-ico="folder" data-s="14"></span><span><b>Scanned</b><span id="scan1"></span></span></span>
      <span class="mi"><span class="ico" data-ico="clock" data-s="14"></span><span><b>Snapshot</b><span id="scan2"></span></span></span>
    </div>
  </div>
</header>
<div id="sentinel" style="height:1px"></div>
<div class="toolbar" id="toolbar">
  <div class="toolbar-in">
    <input type="search" id="q" placeholder="Search name, remote, branch or folder..." aria-label="Search repos">
    <span id="fchips" style="display:contents"></span>
    <button type="button" class="tog" id="clr" hidden>Clear all</button>
    <label class="tbsort" id="sortbox" hidden>Sort <select id="sort" aria-label="Sort repos within each group"><option value="name">Name</option><option value="size">Largest first</option></select></label>
    <span class="shown" id="shown" aria-live="polite"></span>
  </div>
</div>
<div class="wrap">
  <div id="list"></div>
  <p class="credit">RepoAtlas <span id="ver2"></span>, created by <b>datacraft.yogi</b></p>
</div>
<div class="toast" id="toast"></div>

<script>
const DATA = __DATA__;
const GENERATED = "__DATE__";
const META = __META__;
const SEP = META.sep || "/";
const ME = META.me || "";
// Private-details view: every record may carry "m", a copy with placeholders for names, folders and accounts.
// A shareable copy (META.redacted) holds only placeholders, so there is nothing to reveal.
let HIDE = !!META.redacted;
const V = r => (HIDE && r.m) ? r.m : r;
const GROUPS = [
  { key:'Broken',            label:'Broken',                 color:'var(--broken)', icon:'xcircle', hint:'.git folder exists but git cannot read it' },
  { key:'Local only',        label:'Only on this computer',  color:'var(--local)',  icon:'drive',   hint:'never put on GitHub, so nothing is backed up' },
  { key:'Mine on GitHub',    label:'My GitHub repos',        color:'var(--mine)',   icon:'cloudok', hint:'' },
  { key:'Third-party clone', label:'Someone else\'s repo',   color:'var(--third)',  icon:'people',  hint:'copied from another person on GitHub' },
  { key:'Other remote',      label:'On another site',        color:'var(--other)',  icon:'server',  hint:'GitLab, Bitbucket or another site, not github.com' },
  { key:'Error',             label:'Error',                  color:'var(--error)',  icon:'warn',    hint:'unexpected git error' }
];
const GL = k => { const g = GROUPS.find(x => x.key === k); return g ? g.label : k; };
let active = 'All', query = '', dupOnly = {}, cheatOpen = {};

// Icons for the top section (24-unit outline set). ico(name, size) returns ready SVG markup.
const IC = {
  folder:  '<path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/>',
  clock:   '<circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/>',
  help:    '<circle cx="12" cy="12" r="10"/><path d="M9.09 9a3 3 0 0 1 5.83 1c0 2-3 3-3 3"/><line x1="12" y1="17" x2="12.01" y2="17"/>',
  info:    '<circle cx="12" cy="12" r="10"/><line x1="12" y1="16" x2="12" y2="12"/><line x1="12" y1="8" x2="12.01" y2="8"/>',
  cloud:   '<path d="M18 10h-1.26A8 8 0 1 0 9 20h9a5 5 0 0 0 0-10z"/>',
  cloudok: '<path d="M18 10h-1.26A8 8 0 1 0 9 20h9a5 5 0 0 0 0-10z"/><polyline points="8.5 14.5 11 17 15.5 12"/>',
  up:      '<polyline points="16 16 12 12 8 16"/><line x1="12" y1="12" x2="12" y2="21"/><path d="M20.39 18.39A5 5 0 0 0 18 9h-1.26A8 8 0 1 0 3 16.3"/>',
  down:    '<polyline points="8 17 12 21 16 17"/><line x1="12" y1="12" x2="12" y2="21"/><path d="M20.88 18.09A5 5 0 0 0 18 9h-1.26A8 8 0 1 0 3 16.29"/>',
  edit:    '<path d="M12 20h9"/><path d="M16.5 3.5a2.121 2.121 0 0 1 3 3L7 19l-4 1 1-4L16.5 3.5z"/>',
  check:   '<path d="M22 11.08V12a10 10 0 1 1-5.93-9.14"/><polyline points="22 4 12 14.01 9 11.01"/>',
  commit:  '<circle cx="12" cy="12" r="4"/><line x1="1.05" y1="12" x2="7" y2="12"/><line x1="17.01" y1="12" x2="22.96" y2="12"/>',
  flag:    '<path d="M4 15s1-1 4-1 5 2 8 2 4-1 4-1V3s-1 1-4 1-5-2-8-2-4 1-4 1z"/><line x1="4" y1="22" x2="4" y2="15"/>',
  warn:    '<path d="M10.29 3.86L1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z"/><line x1="12" y1="9" x2="12" y2="13"/><line x1="12" y1="17" x2="12.01" y2="17"/>',
  xcircle: '<circle cx="12" cy="12" r="10"/><line x1="15" y1="9" x2="9" y2="15"/><line x1="9" y1="9" x2="15" y2="15"/>',
  drive:   '<line x1="22" y1="12" x2="2" y2="12"/><path d="M5.45 5.11L2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z"/><line x1="6" y1="16" x2="6.01" y2="16"/><line x1="10" y1="16" x2="10.01" y2="16"/>',
  people:  '<path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M23 21v-2a4 4 0 0 0-3-3.87"/><path d="M16 3.13a4 4 0 0 1 0 7.75"/>',
  server:  '<rect x="2" y="2" width="20" height="8" rx="2" ry="2"/><rect x="2" y="14" width="20" height="8" rx="2" ry="2"/><line x1="6" y1="6" x2="6.01" y2="6"/><line x1="6" y1="18" x2="6.01" y2="18"/>',
  copy:    '<rect x="9" y="9" width="13" height="13" rx="2" ry="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/>',
  lock:    '<rect x="3" y="11" width="18" height="11" rx="2"/><path d="M7 11V7a5 5 0 0 1 10 0v4"/>',
  arrow:   '<line x1="5" y1="12" x2="19" y2="12"/><polyline points="12 5 19 12 12 19"/>',
  shield:  '<path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/><line x1="12" y1="8" x2="12" y2="12"/><line x1="12" y1="16" x2="12.01" y2="16"/>'
};
function ico(name, size) {
  const n = size || 16;
  return '<svg width="' + n + '" height="' + n + '" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" focusable="false">' + (IC[name] || '') + '</svg>';
}
function icoEl(name, size, color) {
  const e = el('span', 'ico'); e.innerHTML = ico(name, size);
  if (color) e.style.setProperty('--ic', color);
  return e;
}
document.querySelectorAll('[data-ico]').forEach(e => { e.innerHTML = ico(e.dataset.ico, +e.dataset.s || 16); });
const WORK = META.work || {};
const HAS_WORK = DATA.some(r => r.st);
const HAS_SIZE = !!META.size && DATA.some(r => r.sz);
let sortBy = 'name';
DATA.forEach((r, i) => { r._i = i; });
let wf = { unc:false, push:false, pull:false, clean:false, unk:false, dup:false };     // work-state filters; they combine with the colour filter

// Work state (counts are not private, so these read the real record even while details are hidden)
const ws      = r => (r.st && r.st.state === 'ok') ? r.st : null;
const nUnc    = r => { const s = ws(r); return s ? s.tracked + s.untracked : 0; };
const nAhead  = r => { const s = ws(r); return s && s.ahead  > 0 ? s.ahead  : 0; };
const nBehind = r => { const s = ws(r); return s && s.behind > 0 ? s.behind : 0; };
function isClean(r) {
  const s = ws(r);
  if (!s) return false;
  if (nUnc(r) || s.conflicts || nAhead(r) || nBehind(r)) return false;
  if (r.status !== 'Local only' && !s.initial && s.ahead === null) return false;    // could not tell what is unpushed
  return true;
}
const anyFilter = () => active !== 'All' || wf.unc || wf.push || wf.pull || wf.clean || wf.unk || wf.dup || !!query;

const $ = id => document.getElementById(id);
function el(tag, cls, text) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text !== undefined) e.textContent = text;
  return e;
}
function toast(msg) {
  const t = $('toast'); t.textContent = msg; t.classList.add('show');
  clearTimeout(toast.id); toast.id = setTimeout(() => t.classList.remove('show'), 1400);
}
function copy(text, label, cb) {
  const done = () => { if (cb) cb(); else toast('Copied ' + label); };
  if (navigator.clipboard && window.isSecureContext !== false) {
    navigator.clipboard.writeText(text).then(done, fallback);
  } else fallback();
  function fallback() {
    const ta = document.createElement('textarea');
    ta.value = text; document.body.appendChild(ta); ta.select();
    try { document.execCommand('copy'); done(); } catch (e) { toast('Copy failed'); }
    ta.remove();
  }
}

const SVG = '<svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round">';
const ICON_TERM  = SVG + '<path d="M2 4l4 4-4 4M8 13h6"/></svg>';
const ICON_CLIP  = SVG + '<rect x="4" y="3" width="9" height="11" rx="1.5"/><path d="M6.5 3V2h4v1"/></svg>';
const ICON_CHECK = SVG + '<path d="M3 8.5l3 3 7-7"/></svg>';
const EYE = '<path d="M1.5 8s2.4-4.5 6.5-4.5S14.5 8 14.5 8s-2.4 4.5-6.5 4.5S1.5 8 1.5 8z"/><circle cx="8" cy="8" r="2"/>';
const ICON_EYE     = SVG + EYE + '</svg>';
const ICON_EYE_OFF = SVG + EYE + '<path d="M2.5 2.5l11 11"/></svg>';

// Button that copies text and flips to "Copied" for a moment
function mkBtn(label, tip, text, cls, icon) {
  const b = el('button', 'btn' + (cls ? ' ' + cls : ''));
  b.type = 'button';
  b.title = HIDE ? tip : tip + ': ' + text;      // no hover text with real values while hidden
  const paint = (ic, txt) => { b.innerHTML = ic; b.appendChild(el('span', '', txt)); };
  paint(icon, label);
  b.onclick = () => copy(text, label, () => {
    b.classList.add('done'); paint(ICON_CHECK, 'Copied');
    setTimeout(() => { b.classList.remove('done'); paint(icon, label); }, 1400);
  });
  return b;
}

// Cheatsheet: commands are generated per repo, based on its status and details
// Quote a path for PowerShell. Single quotes are safest: "$" or a backtick inside double quotes would be expanded.
function qp(s) { return "'" + String(s).replace(/'/g, "''") + "'"; }
// For "cd": plain double quotes work in PowerShell, cmd and bash, unless the path contains $ ` or '
function cdq(s) { return /[$`']/.test(s) ? qp(s) : '"' + s + '"'; }
function slug(s) { return s.replace(/[^A-Za-z0-9._-]+/g, '-').replace(/^-+|-+$/g, ''); }

// view=true builds the commands from the placeholder values (what is shown while details are hidden);
// view=false builds the real ones (what the Copy buttons copy). Which items appear depends only on the real record.
function cheatFor(r, view) {
  const g = x => view ? V(x) : x;
  const v = g(r);
  const p = v.path, n = slug(v.name), url = v.url || '<github-url>';
  const who = (view && HIDE) ? 'you' : ME;
  const me = who || '<your-github-user>';
  const ghList = 'gh repo list ' + (who ? who + ' ' : '') + '--limit 200';
  const opener = META.open || 'open';
  const items = [];
  const add = (t, d, c) => items.push({ t: t, d: d, c: c });

  // what to do about uncommitted / unpushed / unpulled work (which items appear depends on the real state only)
  const s = ws(r), sv = v.st;
  if (r.st && r.st.state === 'unsafe') add('Mark this folder as safe', 'Git did not read this repo\'s state because another user owns the folder. Only do this if you trust it; then run the scan again.', 'git config --global --add safe.directory ' + qp(p.replace(/\\/g, '/')));
  if (s && sv) {
    const P = qp(p), rn = v.rname || 'origin', noUp = !s.up || s.upGone;
    const unc = nUnc(r), ah = nAhead(r), bh = nBehind(r);
    if (s.conflicts) add('Finish the merge', s.conflicts + ' file' + (s.conflicts === 1 ? ' is' : 's are') + ' in conflict. Open them, fix the marked sections, then commit (or continue the rebase).', 'git -C ' + P + ' status');
    if (unc) {
      add('See what changed', unc + ' item' + (unc === 1 ? '' : 's') + ' with work pending to commit. New folders count once.', 'git -C ' + P + ' status -s');
      if (!s.initial) add('Review the edits', 'Lines changed in files git already tracks (new files are not included).', 'git -C ' + P + ' diff HEAD --stat');
      add('Commit it', 'Saves everything as one commit. Change the message first.', 'cd ' + P + '; git add -A; git commit -m "describe the change"');
      add('Or set it aside', 'Stash keeps the work safe without a commit, new files included. Bring it back with: git stash pop', 'git -C ' + P + ' stash push -u -m "wip"');
    }
    if (ah) {
      add('See commits pending to push', noUp ? 'Commits that exist on no remote branch yet.' : 'Commits on this branch that ' + rn + ' does not have.',
          'git -C ' + P + ' log --oneline ' + (noUp ? 'HEAD --not --remotes' : "'@{u}..'"));
      if (s.detached)  add('Keep these commits', 'HEAD is not on a branch, so these commits are easy to lose. This puts them on a new branch.', 'git -C ' + P + ' switch -c my-work');
      else if (noUp)   add('Push this branch', 'Uploads it and links it to ' + rn + ', so pushing and pulling work from now on.', 'git -C ' + P + ' push -u ' + rn + ' ' + qp(sv.branch));
      else             add('Push', 'Uploads the commits pending to push to ' + (sv.up || rn) + '.', 'git -C ' + P + ' push');
    }
    if (bh) add('See what you have not pulled', 'Commits on ' + (sv.up || 'the remote') + ' that you do not have yet. Counted as of the last fetch.', 'git -C ' + P + " log --oneline 'HEAD..@{u}'");
  }

  // "pull" has nothing to merge when the branch follows no remote branch (or HEAD is detached): offer fetch instead
  const noTrack = !!(s && (!s.up || s.upGone));
  const pullIt = (title, desc, flag) => noTrack
    ? add('Fetch the latest', 'This branch follows no remote branch, so pull has nothing to merge. Fetch downloads without touching your files.', 'git -C ' + qp(p) + ' fetch')
    : add(title, desc, 'git -C ' + qp(p) + ' pull' + flag);

  if (r.status === 'Broken') {
    add('See what git complains about', 'Shows the exact error for this folder.', 'git -C ' + qp(p) + ' status');
    add('Inspect the .git folder', 'If it is empty or tiny, the history is lost or damaged.', 'Get-ChildItem -Force ' + qp(p + SEP + '.git'));
    add('Look for the repo on GitHub', 'Searches your GitHub repos for a name like this one.', ghList + ' | Select-String "' + n + '"');
    add('Rebuild and reconnect', 'Only if the files are fine and the repo exists on GitHub. Back up the folder first and fill in the URL.', 'cd ' + qp(p) + '; git init; git remote add origin ' + url + '; git fetch; git reset origin/main');
  }
  else if (r.status === 'Local only') {
    if (!s) add('Check for work pending to commit', 'Decide whether this folder is worth keeping.', 'git -C ' + qp(p) + ' status -sb');
    add('Does GitHub already have it?', 'Searches your GitHub repos for this name before you create a new one.', ghList + ' | Select-String "' + n + '"');
    add('Publish with GitHub CLI', 'Creates the GitHub repo, sets origin and pushes in one go.', 'cd ' + qp(p) + '; gh repo create ' + n + ' --private --source . --push');
    add('Publish manually', 'After creating an empty repo named ' + n + ' on github.com.', 'cd ' + qp(p) + '; git remote add origin https://github.com/' + me + '/' + n + '.git; git branch -M main; git push -u origin main');
  }
  else if (r.status === 'Mine on GitHub') {
    if (!s) add('Anything pending to commit or push?', 'Shows modified files and how far ahead or behind you are.', 'git -C ' + qp(p) + ' status -sb');
    pullIt('Bring it up to date', 'Pulls the latest from ' + v.remote + '.', ' --rebase');
    add('Open on GitHub', 'Opens ' + v.remote + ' in your browser.', opener + ' ' + url);
    const key = (r.remote || '').toLowerCase();
    const sibs = DATA.filter(x => x.remote && x.remote.toLowerCase() === key && x.path !== r.path);
    if (sibs.length) {
      const all = [r].concat(sibs).map(g);
      const list = all.map(x => qp(x.path)).join(', ');
      const where = all.slice(1).map(s => (s.folder && s.folder !== '.' ? s.folder + SEP : '') + s.name).join('  |  ');
      add('Which duplicate is newest?', 'Same repo is also at: ' + where + '. Prints the last commit date of each copy.',
          'foreach ($d in ' + list + ') { "$d  " + (git -C $d log -1 --date=short --format=%cd) }');
      add('Work pending to commit in each copy?', 'Check this before deleting any copy.',
          'foreach ($d in ' + list + ') { "== $d"; git -C $d status -sb }');
    }
  }
  else if (r.status === 'Third-party clone') {
    pullIt('Update the clone', 'Pulls upstream changes from ' + v.remote + '.', '');
    if (!s) add('Any local edits?', 'Check before updating or deleting.', 'git -C ' + qp(p) + ' status -sb');
    add('Fork it to your account', 'Needed before you can push your own changes.', 'cd ' + qp(p) + '; gh repo fork --remote');
    if (r.url) add('Open on GitHub', 'Opens ' + v.remote + ' in your browser.', opener + ' ' + v.url);
  }
  else if (r.status === 'Other remote') {
    pullIt('Update the clone', 'Pulls the latest from the remote.', '');
    if (!s) add('Any local edits?', 'Check before updating or deleting.', 'git -C ' + qp(p) + ' status -sb');
    add('Show the remote', 'This remote is not on github.com, so the GitHub CLI does not apply here.', 'git -C ' + qp(p) + ' remote -v');
    if (r.url) add('Open in browser', 'Opens the remote in your browser.', opener + ' ' + v.url);
  }
  else {
    if (/dubious/i.test(r.err || '')) {
      add('Fix "dubious ownership"', 'Marks only this folder as safe for your user.', 'git config --global --add safe.directory ' + qp(p.replace(/\\/g, '/')));
    }
    add('Retry and show the raw error', 'Reads the remote again without hiding errors.', 'git -C ' + qp(p) + ' remote -v');
  }
  return items;
}

function renderCheat(r) {
  const box = el('div', 'cheat');
  const v = V(r);
  const sb = sizeBox(r); if (sb) box.appendChild(sb);
  if (v.err) {
    box.appendChild(el('div', 'ch', 'Git reported:'));
    box.appendChild(el('pre', 'err', v.err));
  } else {
    box.appendChild(el('div', 'ch', 'Commands filled in for this repo (PowerShell syntax). Click Copy, then paste into a terminal.'));
  }
  const shown = cheatFor(r, true), real = cheatFor(r, false);    // same items; Copy always copies the real command
  shown.forEach((i, ix) => {
    const item = el('div', 'ci');
    item.appendChild(el('div', 'ct', i.t));
    item.appendChild(el('div', 'cd', i.d));
    const line = el('div', 'cc');
    line.appendChild(el('code', '', i.c));
    line.appendChild(mkBtn('Copy', 'Copy command', real[ix].c, '', ICON_CLIP));
    item.appendChild(line);
    box.appendChild(item);
  });
  return box;
}

function matches(r) {
  if (active !== 'All' && r.status !== active) return false;
  if (wf.unc   && !nUnc(r))    return false;
  if (wf.push  && !nAhead(r))  return false;
  if (wf.pull  && !nBehind(r)) return false;
  if (wf.clean && !isClean(r)) return false;
  if (wf.unk   && !(r.st && r.st.state !== 'ok')) return false;
  if (wf.dup   && !r.dup) return false;
  if (!query) return true;
  const v = V(r);
  return (v.name + ' ' + v.remote + ' ' + v.folder + ' ' + ((v.st && v.st.branch) || '')).toLowerCase().includes(query);
}

// Active filters as removable chips in the sticky toolbar (the bar and tiles at the top are where filters are chosen)
function renderFilters() {
  const box = $('fchips'); box.textContent = '';
  const mk = (label, off) => {
    const b = el('button', 'fc', label); b.type = 'button';
    b.title = 'Remove this filter';
    b.appendChild(el('u', '', '\u00d7'));
    b.onclick = off;
    box.appendChild(b);
  };
  if (active !== 'All') mk(GL(active), () => { active = 'All'; render(); });
  FILTER_NAMES.forEach(f => { if (wf[f.key]) mk(f.label, () => { wf[f.key] = false; render(); }); });
  if (!anyFilter() && !query) box.appendChild(el('span', 'fhint', DATA.length ? 'Filters: none. Click a colour or tile at the top.' : ''));
}
const FILTER_NAMES = [
  { key:'unc', label:'Pending to commit' }, { key:'push', label:'Pending to push' }, { key:'pull', label:'Unpulled' },
  { key:'clean', label:'All good' }, { key:'unk', label:'Couldn\'t check' }, { key:'dup', label:'Duplicate copies' }
];

function fmtDay(s) {
  const d = new Date(String(s) + 'T00:00:00');
  return isNaN(d) ? s : d.toLocaleDateString(undefined, { day:'numeric', month:'short', year:'numeric' });
}
// The small line under the remote: branch, then only what needs attention. Hover text never contains real names while hidden.
function renderState(r) {
  const s0 = r.st;
  if (!s0) return null;
  const box = el('div', 'wstate');
  const chip = (cls, text, tip, num) => {
    const c = el('span', 'wc' + (cls ? ' ' + cls : ''));
    if (num !== undefined) c.appendChild(el('b', '', num));
    c.appendChild(document.createTextNode(text));
    if (tip) c.title = tip;
    box.appendChild(c);
  };
  if (s0.state === 'unsafe') { chip('', 'owned by another user', 'Git refuses to run in folders owned by another user, so its state was not read. The Commands panel shows how to mark it safe.'); return box; }
  if (s0.state !== 'ok') {
    chip('', 'couldn\'t check', s0.state === 'timeout' ? 'Git did not answer in time (a very large repo, a slow or offline drive, or a busy disk).' : 'Git could not read this repo\'s state.');
    return box;
  }
  const s = r.st, v = V(r).st || s;
  if (s.detached) chip('br', 'not on a branch' + (s.sha ? ' @ ' + s.sha : ''), 'HEAD is not on a branch (git calls this detached). Commits made here are easy to lose.');
  else chip('br', v.branch + (s.initial ? ' (no commits yet)' : ''), s.initial ? 'Nothing has been committed in this repo yet.' : 'Current branch');
  if (s.conflicts) chip('bad', 'clashing edits', 'Files where two sets of edits clash and must be fixed by hand (git calls this a merge conflict).', s.conflicts + ' ');
  const unc = nUnc(r);
  if (unc) {
    const parts = [];
    if (s.staged)    parts.push(s.staged + ' staged');
    if (s.unstaged)  parts.push(s.unstaged + ' changed but not staged');
    if (s.untracked) parts.push(s.untracked + ' new, not added to git (a new folder counts once)');
    if (s.conflicts) parts.push(s.conflicts + ' in conflict');
    chip('hot', 'pending to commit', 'Not saved in a commit yet (git calls this uncommitted): ' + parts.join(', ') + '.', unc + ' ');
  }
  const noUp = !s.up || s.upGone;
  const ah = nAhead(r), bh = nBehind(r);
  if (ah) chip('hot', 'pending to push \u2191', 'Saved in a commit but not on the remote yet (git calls this unpushed). ' + (s.detached ? 'HEAD is not on a branch. These commits are on no remote branch.'
                         : s.upGone ? 'The remote branch was deleted. These commits are on no remote branch.'
                         : !s.up ? 'This branch has no upstream. These commits are on no remote branch.'
                         : 'Commits ahead of ' + v.up + '.'), ah + ' ');
  if (bh) {
    const when = s.fetch === 'ok' ? 'just fetched' : (s.fetchedAt ? 'the last fetch, ' + fmtDay(s.fetchedAt) : 'the last fetch (date unknown)');
    chip('hot', 'unpulled \u2193', 'Commits on ' + v.up + ' that you do not have yet, as of ' + when + '.', bh + ' ');
  }
  if (s.upGone) chip('', 'remote branch deleted', 'The remote branch this one followed no longer exists (git calls this upstream gone).');
  else if (!s.up && r.status !== 'Local only' && !s.detached && !s.initial) chip('', 'not linked to remote', 'This branch does not follow a remote branch (git calls this no upstream), so pushing and pulling need a branch name.');
  if (r.status !== 'Local only' && !s.initial && s.ahead === null) chip('', 'pending to push: unknown', 'Could not count commits that are missing from the remote.');
  if (s.fetch === 'failed' || s.fetch === 'timeout') chip('', s.fetch === 'timeout' ? 'remote timed out' : 'couldn\'t reach remote', 'The remote could not be reached (offline, or a password is needed), so the unpulled count may be out of date.');
  if (isClean(r)) chip('', '\u2713 all good', r.status === 'Local only' ? 'Nothing pending to commit. This repo has no remote, so it is not backed up anywhere.' : 'Nothing pending to commit or push, and nothing unpulled (as of the last fetch).');
  return box;
}

// sizes: binary units, as Explorer and Finder show them
function fmtSize(n) {
  n = +n || 0;
  if (n < 1024) return n + ' B';
  const u = ['KB', 'MB', 'GB', 'TB']; let i = -1;
  do { n /= 1024; i++; } while (n >= 1000 && i < u.length - 1);    // 1003 KB reads better as 1.0 MB
  return (n >= 100 || i === 0 ? Math.round(n) : n.toFixed(1)) + ' ' + u[i];
}
const sizeLabel = z => (z.partial ? 'at least ' : '') + fmtSize(z.total);
// a part that ran out of time (or had unreadable folders) is shown as a minimum, not as a firm number
const partSize = (z, k, v) => ((z.cut || []).indexOf(k) >= 0 ? '≥ ' : '') + fmtSize(v);
const nestNote = z => z.nest > 0 ? z.nest + (z.nest === 1 ? ' repo' : ' repos') + ' inside this folder ' + (z.nest === 1 ? 'is' : 'are') + ' not counted here (listed on their own)' : '';
function sizeBreakdown(z) {
  const hist = z.elsewhere ? 'git history is kept in another folder' : 'git history ' + partSize(z, 'git', z.git);
  const tail = nestNote(z) ? '. ' + nestNote(z) : '';
  if (z.un > 0) return 'Files ' + partSize(z, 'own', z.un) + ' (git would not open this folder, so they are not split), ' + hist + tail;
  return 'Your files ' + partSize(z, 'own', z.own) + ', ' + hist + ', ignored by git ' + partSize(z, 'ign', z.ign) + tail;
}
function sizeCell(r) {
  const z = r.sz; if (!z) return el('div', 'sz');
  const c = el('div', 'sz');
  c.appendChild(el('b', '', (z.partial ? '\u2265 ' : '') + fmtSize(z.total)));
  const bar = el('div', 'sbar');
  [['s-own', z.own], ['s-un', z.un], ['s-git', z.git], ['s-ign', z.ign]].forEach(x => {
    if (!(x[1] > 0) || !(z.total > 0)) return;
    const i = el('i', x[0]); i.style.width = (100 * x[1] / z.total) + '%'; bar.appendChild(i);
  });
  c.appendChild(bar);
  c.title = (z.partial ? 'At least ' : '') + fmtSize(z.total) + ' on disk. ' + sizeBreakdown(z) + (z.partial ? '. Some folders were too big or unreadable, so this is a minimum.' : '.');
  return c;
}
// the same numbers as a small legend, shown at the top of the Commands panel (works on touch screens too)
function sizeBox(r) {
  const z = r.sz; if (!z) return null;
  const box = el('div', 'szbox');
  box.appendChild(el('div', 'ch', 'Space on disk: ' + sizeLabel(z) + (z.partial ? ' (some folders were too big or unreadable)' : '')));
  const l = el('div', 'szl');
  const row = (cls, name, val) => { const i = el('i', cls); l.appendChild(i); l.appendChild(el('span', '', name)); l.appendChild(el('span', '', val)); };
  if (z.un > 0) row('s-un', 'Files (not split: git would not open this folder)', partSize(z, 'own', z.un));
  else          row('s-own', 'Your files', partSize(z, 'own', z.own));
  if (z.elsewhere) row('s-git', 'Git history (kept in another folder)', '–');
  else             row('s-git', 'Git history (.git folder)', partSize(z, 'git', z.git));
  if (!(z.un > 0)) {
    const parts = (z.parts || []).filter(p => p.b > 0).map(p => p.n + ' ' + fmtSize(p.b)).join(', ');
    row('s-ign', 'Ignored by git' + (parts ? ' (' + parts + ')' : ''), partSize(z, 'ign', z.ign));
  }
  box.appendChild(l);
  if (nestNote(z)) box.appendChild(el('p', '', nestNote(z).charAt(0).toUpperCase() + nestNote(z).slice(1) + ', so no space is counted twice.'));
  if (!(z.un > 0)) box.appendChild(el('p', '', 'Ignored files are things git is told to skip: usually downloads and build output that can be recreated (node_modules, build folders), but sometimes private files such as .env or a local database. Check before deleting.'));
  return box;
}

function renderRow(r, color) {
  const row = el('div', 'row' + (HAS_SIZE ? ' hs' : ''));
  row.style.borderLeft = '4px solid ' + color;
  const v = V(r);

  const left = el('div');
  const name = el('span', 'name', v.name);
  left.appendChild(name);
  if (r.dup) { const b = el('span', 'badge', 'duplicate'); b.title = 'Another local repo has the same remote'; left.appendChild(b); }
  left.appendChild(el('div', 'folder', v.folder));

  const mid = el('div', 'meta');
  if (v.url && !HIDE) { const a = el('a', '', v.remote); a.href = v.url; a.target = '_blank'; a.rel = 'noopener'; mid.appendChild(a); }
  else mid.appendChild(el('span', HIDE && v.remote ? '' : 'folder', v.remote || '-'));
  if (v.rname && v.rname !== 'origin') mid.appendChild(el('span', 'folder', ' (remote: ' + v.rname + ')'));
  const wst = renderState(r);
  if (wst) mid.appendChild(wst);

  const btns = el('div', 'btns');
  btns.appendChild(mkBtn('Copy cd', 'Copy this cd command', 'cd ' + cdq(r.path), 'primary', ICON_TERM));
  btns.appendChild(mkBtn('Copy path', 'Copy the folder path', r.path, '', ICON_CLIP));
  const open = !!cheatOpen[r.path];
  const fx = el('button', 'btn' + (open ? ' on' : ''), open ? 'Hide commands' : 'Commands');
  fx.type = 'button';
  fx.title = 'Ready-to-paste commands for this repo';
  fx.onclick = () => { cheatOpen[r.path] = !open; renderList(); };
  btns.appendChild(fx);

  row.appendChild(left); row.appendChild(mid); if (HAS_SIZE) row.appendChild(sizeCell(r)); row.appendChild(btns);
  const wrap = el('div', 'rw');
  wrap.appendChild(row);
  if (open) wrap.appendChild(renderCheat(r));
  return wrap;
}

function renderList() {
  const list = $('list'); list.textContent = '';
  let shown = 0;
  GROUPS.forEach(g => {
    const all = DATA.filter(r => r.status === g.key && matches(r));
    const dupCount = all.filter(r => r.dup).length;
    if (!dupCount) dupOnly[g.key] = false;
    let items = dupOnly[g.key] ? all.filter(r => r.dup) : all;
    if (sortBy === 'size') items = items.slice().sort((a, b) => ((b.sz ? b.sz.total : -1) - (a.sz ? a.sz.total : -1)) || (a._i - b._i));
    if (!items.length) return;
    shown += items.length;
    const sec = el('section');
    const h = el('div', 'gh');
    const pill = el('span', 'pill'); pill.style.background = g.color;
    pill.appendChild(el('span', '', g.label)); pill.appendChild(el('span', 'n', items.length));
    h.appendChild(pill);
    if (g.hint) h.appendChild(el('small', '', '- ' + g.hint));
    const tgs = el('div', 'tgs');
    if (dupCount) {
      const t = el('button', 'tog' + (dupOnly[g.key] ? ' on' : ''), 'Duplicates only (' + dupCount + ')');
      t.onclick = () => { dupOnly[g.key] = !dupOnly[g.key]; renderList(); };
      tgs.appendChild(t);
    }
    h.appendChild(tgs);
    sec.appendChild(h);
    // duplicate sets first, grouped by shared remote
    const sets = {};
    items.filter(r => r.dup).forEach(r => { const k = r.remote.toLowerCase(); (sets[k] = sets[k] || []).push(r); });
    const dispKey = k => (HIDE ? V(sets[k][0]).remote : k).toLowerCase();
    Object.keys(sets).sort((a, b) => dispKey(a) < dispKey(b) ? -1 : dispKey(a) > dispKey(b) ? 1 : 0).forEach(k => {
      const box = el('div', 'dupset');
      box.appendChild(el('div', 'dl', 'Same remote: ' + V(sets[k][0]).remote + ' - ' + sets[k].length + ' local copies'));
      sets[k].forEach(r => box.appendChild(renderRow(r, g.color)));
      sec.appendChild(box);
    });
    items.filter(r => !r.dup).forEach(r => sec.appendChild(renderRow(r, g.color)));
    list.appendChild(sec);
  });
  if (!shown && DATA.length) list.appendChild(el('div', 'empty', anyFilter() ? 'No repos match these filters.' : 'No repos match.'));
  $('shown').textContent = shown === DATA.length ? '' : 'Showing ' + shown + ' of ' + DATA.length;
  $('clr').hidden = !anyFilter();
}

// ---- top section ----
function fmtWhen(s) {
  const d = new Date(String(s).replace(' ', 'T'));
  if (isNaN(d)) return s;
  return d.toLocaleDateString(undefined, { day:'numeric', month:'short', year:'numeric' }) + ', ' +
         d.toLocaleTimeString(undefined, { hour:'2-digit', minute:'2-digit' });
}
function listJoin(a) { return a.length < 2 ? (a[0] || '') : a.slice(0, -1).join(', ') + ' and ' + a[a.length - 1]; }
function toggleStatus(key) { active = (active === key) ? 'All' : key; render(); }

function paintScan() {
  const roots = [].concat(META.roots || []), n = META.rootsCount || roots.length;
  const t = HIDE ? (n ? n + (n === 1 ? ' folder' : ' folders') : '')
                 : (roots.length ? listJoin(roots) : '');
  $('scan1').textContent = t;
  $('mi1').hidden = !t;
}
function paintSize() {
  const have = DATA.filter(r => r.sz);
  const box = $('disk');
  box.hidden = !HAS_SIZE || !have.length;
  if (box.hidden) return;
  const sum = k => have.reduce((a, r) => a + (+r.sz[k] || 0), 0);
  const total = sum('total'), some = have.some(r => r.sz.partial);
  $('dtot').textContent = (some ? '\u2265 ' : '') + fmtSize(total);
  $('dsub').textContent = 'used by ' + have.length + (have.length === 1 ? ' repo' : ' repos');
  $('diskn').textContent = some ? 'Some repos were too big or unreadable, so this is a minimum.' : 'Space the repos use on this computer.';
  const parts = [
    { c:'d-own', n:'Your files',     v:sum('own'), d:'The code and files in the repos' },
    { c:'d-git', n:'Git history',    v:sum('git'), d:'Hidden .git folders. Grows when large files are committed' },
    { c:'d-ign', n:'Ignored by git', v:sum('ign'), d:'node_modules, builds, .env. Often rebuildable, but check first' },
    { c:'d-un',  n:'Not split',      v:sum('un'),  d:'Repos git would not open, so their files could not be told apart' }
  ].filter(x => x.v > 0);
  const bar = $('dbar'), leg = $('dleg'); bar.textContent = ''; leg.textContent = '';
  bar.setAttribute('aria-label', parts.map(x => x.n + ' ' + fmtSize(x.v)).join(', '));
  parts.forEach(x => {
    const pct = total > 0 ? 100 * x.v / total : 0;
    const seg = el('i', x.c); seg.style.width = pct + '%'; seg.title = x.n + ': ' + fmtSize(x.v) + ' (' + Math.round(pct) + '%)'; bar.appendChild(seg);
    const it = el('div'); const dn = el('div', 'dn');
    dn.appendChild(el('i', x.c)); dn.appendChild(el('b', '', fmtSize(x.v))); dn.appendChild(el('span', '', x.n + ' \u00b7 ' + (pct > 0 && pct < 1 ? '<1' : Math.round(pct)) + '%'));
    it.appendChild(dn); it.appendChild(el('p', '', x.d)); leg.appendChild(it);
  });
  // by category: how much space each kind of repo takes; one click filters the list to it
  const cat = $('dcat'); cat.textContent = '';
  const rows = GROUPS.map(g => {
    const rs = have.filter(r => r.status === g.key);
    const f = k => rs.reduce((a, r) => a + (+r.sz[k] || 0), 0);
    return { g: g, n: rs.length, total: f('total'), own: f('own'), un: f('un'), git: f('git'), ign: f('ign'), part: rs.some(r => r.sz.partial) };
  }).filter(x => x.n).sort((a, b) => b.total - a.total);
  if (rows.length) {
    const h = el('h3', '', 'By category'); h.appendChild(el('span', '', 'Click one to list just those repos')); cat.appendChild(h);
    const mx = Math.max.apply(null, rows.map(x => x.total)) || 1;
    rows.forEach(x => {
      const b = el('button', 'dcr'); b.type = 'button'; b.dataset.key = x.g.key;
      const pct = total > 0 ? 100 * x.total / total : 0;
      const cn = el('span', 'cn'); const dot = el('i'); dot.style.background = x.g.color;
      cn.appendChild(dot); cn.appendChild(document.createTextNode(x.g.label)); cn.appendChild(el('small', '', x.n + (x.n === 1 ? ' repo' : ' repos')));
      const ct = el('span', 'ct'); const cf = el('span', 'cf'); cf.style.width = (100 * x.total / mx) + '%';
      [['d-own', x.own], ['d-un', x.un], ['d-git', x.git], ['d-ign', x.ign]].forEach(p => {
        if (!(p[1] > 0) || !(x.total > 0)) return;
        const i = el('i', p[0]); i.style.width = (100 * p[1] / x.total) + '%'; cf.appendChild(i);
      });
      ct.appendChild(cf);
      const cv = el('span', 'cv'); cv.appendChild(el('b', '', (x.part ? '\u2265 ' : '') + fmtSize(x.total)));
      cv.appendChild(document.createTextNode((pct > 0 && pct < 1 ? '<1' : Math.round(pct)) + '%'));
      b.appendChild(cn); b.appendChild(ct); b.appendChild(cv);
      b.title = x.g.label + ': ' + (x.part ? 'at least ' : '') + fmtSize(x.total) + ' in ' + x.n + (x.n === 1 ? ' repo' : ' repos') + '. ' +
        (x.un > 0 ? 'Files ' + fmtSize(x.un) + ' (not split), git history ' + fmtSize(x.git) : 'Your files ' + fmtSize(x.own) + ', git history ' + fmtSize(x.git) + ', ignored by git ' + fmtSize(x.ign)) + '. Click to list these repos.';
      b.onclick = () => { toggleStatus(x.g.key); window.scrollTo({ top: $('list').getBoundingClientRect().top + window.scrollY - 90, behavior: 'smooth' }); };
      cat.appendChild(b);
    });
  }
  cat.hidden = !rows.length;
  updateDiskCat();
  // the heaviest repos: one click lists that repo
  const top = have.slice().sort((a, b) => b.sz.total - a.sz.total).slice(0, 3).filter(r => r.sz.total > 0);
  const tp = $('dtop'); tp.textContent = '';
  if (top.length > 1) {
    tp.appendChild(el('span', '', 'Heaviest:'));
    top.forEach(r => {
      const c = el('button', 'dchip'); c.type = 'button'; c.title = 'Show only ' + V(r).name;
      c.appendChild(document.createTextNode(V(r).name)); c.appendChild(el('b', '', fmtSize(r.sz.total)));
      c.onclick = () => { query = V(r).name; $('q').value = query; render(); window.scrollTo({ top: $('list').getBoundingClientRect().top + window.scrollY - 90, behavior: 'smooth' }); };
      tp.appendChild(c);
    });
    const go = el('button', 'dchip dgo'); go.type = 'button'; go.appendChild(document.createTextNode('Sort the list by size'));
    go.onclick = () => { sortBy = 'size'; $('sort').value = 'size'; renderList(); window.scrollTo({ top: $('list').getBoundingClientRect().top + window.scrollY - 90, behavior: 'smooth' }); };
    tp.appendChild(go);
  }
  tp.hidden = !tp.childNodes.length;
}
function updateDiskCat() {
  document.querySelectorAll('.dcr').forEach(b => {
    const on = active === b.dataset.key;
    b.classList.toggle('on', on); b.classList.toggle('dim', active !== 'All' && !on);
    b.setAttribute('aria-pressed', on ? 'true' : 'false');
  });
}
function buildHero() {
  const total = DATA.length;
  if (META.version) { $('ver').textContent = 'v' + META.version; $('ver2').textContent = 'v' + META.version; }
  paintScan(); paintSize();
  $('big').textContent = total;
  $('unit').textContent = total === 1 ? 'repo on this computer' : (total ? 'repos on this computer' : 'repos found');
  $('scan2').textContent = fmtWhen(GENERATED) + '. Run the launcher again to refresh.';

  const strip = $('strip'), key = $('key');
  const counts = GROUPS.map(g => ({ g: g, n: DATA.filter(r => r.status === g.key).length })).filter(x => x.n);
  counts.forEach((x, i) => {
    const share = x.n * 100 / total;
    const pct = share < 1 ? 'under 1%' : Math.round(share) + '%';
    const b = el('button', 'seg'); b.type = 'button';
    b.dataset.key = x.g.key; b.dataset.n = x.n;
    b.style.flexGrow = x.n; b.style.background = x.g.color; b.style.setProperty('--i', i);
    b.title = x.n + ' ' + x.g.label + ' (' + pct + ')';
    b.setAttribute('aria-label', x.n + ' ' + x.g.label + ', ' + pct);
    b.setAttribute('aria-pressed', 'false');
    b.appendChild(el('span', 'segn', x.n));
    b.onclick = () => toggleStatus(x.g.key);
    strip.appendChild(b);

    const k = el('span', 'k'); k.dataset.key = x.g.key;
    const sw = el('i'); sw.style.background = x.g.color; sw.innerHTML = ico(x.g.icon, 12);
    k.appendChild(sw); k.appendChild(el('b', '', x.n)); k.appendChild(document.createTextNode(x.g.label));
    k.onclick = () => toggleStatus(x.g.key);
    key.appendChild(k);
  });
  if (!total) { strip.hidden = true; key.hidden = true; $('toolbar').hidden = true; }

  // duplicates: one more item in the legend, a filter like the others
  const dupSets = new Set(DATA.filter(r => r.dup).map(r => r.remote.toLowerCase())).size;
  const nDup = DATA.filter(r => r.dup).length;
  if (dupSets) {
    const k = el('span', 'k twice'); k.dataset.dup = '1';
    const sw = el('i'); sw.innerHTML = ico('copy', 12);
    k.appendChild(sw); k.appendChild(el('b', '', nDup)); k.appendChild(document.createTextNode('duplicate copies'));
    k.title = nDup + ' local copies of ' + dupSets + (dupSets === 1 ? ' repo that is' : ' repos that are') + ' kept in more than one folder';
    k.onclick = () => { wf.dup = !wf.dup; render(); };
    key.appendChild(k);
  }

  buildStart(total);
  buildWork();
  fitLabels();
}
function setWork(key) {
  wf[key] = !wf[key];
  if (wf[key]) { if (key === 'clean') { wf.unc = wf.push = wf.pull = wf.unk = false; } else wf.clean = false; }   // "clean" excludes the others
  render();
}
// "Start here": the single most urgent thing, as one line that applies the matching filter
let START = null;
function buildStart(total) {
  const box = $('startbox'); box.textContent = ''; START = null;
  const c = k => DATA.filter(r => r.status === k).length;
  const nU = DATA.filter(r => nUnc(r) > 0).length, nP = DATA.filter(r => nAhead(r) > 0).length;
  const risky = DATA.filter(r => r.status === 'Local only' && nUnc(r) > 0).length;
  const plural = (n, one, many) => n === 1 ? one : many;
  const none = () => { active = 'All'; wf = { unc:false, push:false, pull:false, clean:false, unk:false, dup:false }; };
  let cls = '', icon = 'shield', head = '', tail = '', on = null, act = null;
  if (!total) { cls = 'info'; icon = 'info'; head = 'Nothing was found in the folders scanned.'; tail = 'Check the folder names, or point the tool at your code folder with -Root.'; }
  else if (risky) {
    head = risky + plural(risky, ' repo exists only on this computer and has work pending to commit.', ' repos exist only on this computer and have work pending to commit.'); tail = 'Nothing is backed up.';
    on = () => active === 'Local only' && wf.unc && !wf.push && !wf.pull && !wf.clean && !wf.unk && !wf.dup;
    act = () => { const was = on(); none(); if (!was) { active = 'Local only'; wf.unc = true; } render(); };
  }
  else if (c('Broken')) {
    icon = 'xcircle'; head = c('Broken') + plural(c('Broken'), ' repo is broken.', ' repos are broken.'); tail = 'Git cannot read the .git folder.';
    on = () => active === 'Broken'; act = () => toggleStatus('Broken');
  }
  else if (nU || nP) {
    cls = 'warn'; icon = 'edit'; head = (nU || nP) + ' ' + plural(nU || nP, 'repo has', 'repos have') + (nU ? ' work pending to commit' : ' work pending to push') + '.'; tail = 'Not saved in a commit, or not on the remote yet.';
    const k = nU ? 'unc' : 'push';
    on = () => wf[k] && active === 'All'; act = () => { const was = on(); none(); if (!was) wf[k] = true; render(); };
  }
  else { cls = 'good'; icon = 'check'; head = 'Nothing needs attention.'; tail = 'Every repo is readable and has a remote' + (HAS_WORK ? ', and nothing is pending to commit or push' : '') + '.'; }
  const it = el(act ? 'button' : 'div', 'start' + (cls ? ' ' + cls : ''));
  if (act) { it.type = 'button'; it.title = 'Show these in the list'; }
  it.appendChild(icoEl(icon, 22));
  const p = el('p'); p.appendChild(document.createTextNode(head)); if (tail) p.appendChild(el('span', '', tail));
  it.appendChild(p);
  if (act) { const g = el('span', 'go'); g.appendChild(el('span', '', 'Show them')); g.appendChild(icoEl('arrow', 14)); it.appendChild(g); it.onclick = act; START = { node: it, on: on, label: g.firstChild }; }
  box.appendChild(it);
}
function updateStart() {
  if (!START) return;
  const on = !!START.on();
  START.node.classList.toggle('on', on); START.node.setAttribute('aria-pressed', on ? 'true' : 'false');
  START.label.textContent = on ? 'Showing them' : 'Show them';
}
// Work state: five tiles, each one a filter
const WORK_DEFS = [
  { key:'unc',   icon:'edit',  color:'#fbbf24', label:'Pending to commit', n: () => DATA.filter(r => nUnc(r) > 0).length,    sub: () => 'edits or new files not saved in a commit', tip:'Edits or new files that are not saved in a commit yet (git calls this uncommitted)' },
  { key:'push',  icon:'up',    color:'#fbbf24', label:'Pending to push', n: () => DATA.filter(r => nAhead(r) > 0).length,  sub: () => 'saved work not on the remote yet',     tip:'Commits that are saved on this computer but not on the remote yet (git calls this unpushed)' },
  { key:'pull',  icon:'down',  color:'#7dd3fc', label:'Unpulled',   n: () => DATA.filter(r => nBehind(r) > 0).length, sub: () => WORK.fetch ? 'new on the remote, just fetched' : 'new on the remote, as of last fetch', tip:'Commits on the remote that you do not have yet (git: behind). Unpulled means not pulled yet.' },
  { key:'clean', icon:'check', color:'#4ade80', label:'All good', n: () => DATA.filter(isClean).length,             sub: () => 'nothing to save, push or pull',        tip:'Nothing pending to commit or push, and nothing unpulled' },
  { key:'unk',   icon:'lock',  color:'#cbd5e1', label:'Couldn\'t check', n: () => DATA.filter(r => r.st && r.st.state !== 'ok').length, off:true,
    sub: () => {
      const cnt = k => DATA.filter(r => r.st && r.st.state === k).length;
      const parts = [[cnt('unsafe'), 'owned by another user'], [cnt('timeout'), 'too slow to answer'], [cnt('error'), 'unreadable']].filter(x => x[0]);
      return parts.length === 1 ? parts[0][1] : parts.map(x => x[0] + ' ' + x[1]).join(', ');
    },
    tip:'Repos whose state could not be read. For one owned by another user, its Commands panel shows how to mark it safe.' }
];
function buildWork() {
  if (!HAS_WORK) return;
  $('work').hidden = false;
  const box = $('workb'); box.textContent = '';
  WORK_DEFS.forEach(d => {
    const n = d.n();
    if (d.off && !n) return;                                  // "Couldn't check" only appears when something was not checked
    const b = el('button', 'wt' + (d.off ? ' off' : '')); b.type = 'button'; b.dataset.key = d.key; b.dataset.n = n;
    const th = el('div', 'th'); const ib = el('span', 'ib'); ib.style.setProperty('--ic', d.color); ib.innerHTML = ico(d.icon, 17);
    th.appendChild(ib); th.appendChild(el('span', 'tl', d.label));
    b.appendChild(th); b.appendChild(el('div', 'tn', n)); b.appendChild(el('div', 'ts', d.sub()));
    b.title = d.tip;
    b.onclick = () => setWork(d.key);
    box.appendChild(b);
  });
  const failed = DATA.filter(r => r.st && (r.st.fetch === 'failed' || r.st.fetch === 'timeout')).length;
  const note = $('workn'); note.textContent = '';
  note.appendChild(document.createTextNode('Click a tile to filter. '));
  if (WORK.fetch) note.appendChild(document.createTextNode('Each repo was fetched when this report was made' + (failed ? ', except ' + failed + (failed === 1 ? ' that' : ' that') + ' could not be reached. ' : '. ')));
  else { note.appendChild(document.createTextNode('Unpulled is as of each repo\'s last fetch; run with ')); note.appendChild(el('span', 'nw', '-Fetch')); note.appendChild(document.createTextNode(' to refresh it. ')); }
  if (WORK.noUntracked) note.appendChild(document.createTextNode('New files never added to git are not counted. '));
}
function updateWork() {
  document.querySelectorAll('.wt').forEach(b => {
    const on = !!wf[b.dataset.key];
    b.classList.toggle('on', on);
    b.setAttribute('aria-pressed', on ? 'true' : 'false');
    b.disabled = (+b.dataset.n === 0) && !on;
  });
  const dk = document.querySelector('.k.twice'); if (dk) dk.classList.toggle('on', !!wf.dup);
}
function clearFilters() {
  active = 'All'; wf = { unc:false, push:false, pull:false, clean:false, unk:false, dup:false }; query = ''; $('q').value = '';
  render();
}
// show a count inside a segment only when it fits
function fitLabels() {
  document.querySelectorAll('.seg').forEach(s => {
    s.classList.toggle('nolabel', s.offsetWidth < 22 + 9 * String(s.dataset.n).length);
  });
}
function updateStrip() {
  document.querySelectorAll('.seg, .k').forEach(s => {
    const on = active === s.dataset.key;
    s.classList.toggle('on', on && s.classList.contains('seg'));
    s.classList.toggle('dim', active !== 'All' && !on);
    if (s.classList.contains('seg')) s.setAttribute('aria-pressed', on ? 'true' : 'false');
  });
}

// Hide private details: switches every name, folder and account on the page to its placeholder
function paintPrivacy() {
  const b = $('priv');
  b.hidden = !!META.redacted;                     // a shareable copy has nothing to reveal
  b.classList.toggle('on', HIDE);
  b.setAttribute('aria-pressed', HIDE ? 'true' : 'false');
  b.innerHTML = HIDE ? ICON_EYE : ICON_EYE_OFF;
  b.appendChild(el('span', '', HIDE ? 'Show real details' : 'Hide private details'));
  b.title = HIDE ? 'Show the real names, folders and accounts again' : 'Replace names, folders and accounts with placeholders, for sharing a screenshot';
  $('privacy').hidden = !HIDE;
  paintSize();
  $('privtxt').textContent = META.redacted
    ? 'This is a shareable copy. Names, folders and accounts are placeholders, and the real values are not in this file.'
    : 'Private details are hidden. Names, folders and accounts are placeholders.';
  paintScan();
}
function render() {
  renderFilters(); renderList(); updateStrip(); updateWork(); updateStart(); updateDiskCat();
}
$('howbtn').onclick = () => { const h = $('how'); h.hidden = !h.hidden; $('howbtn').setAttribute('aria-expanded', h.hidden ? 'false' : 'true'); };
$('clr').onclick = clearFilters;
$('sortbox').hidden = !HAS_SIZE;
$('sort').onchange = () => { sortBy = $('sort').value; renderList(); };
$('q').addEventListener('input', e => { query = e.target.value.trim().toLowerCase(); renderList(); });
buildHero();
paintPrivacy();
render();
if (window.matchMedia && matchMedia('(min-width:1001px)').matches) $('q').focus({ preventScroll: true });   // not on phones: it would scroll past the top section
$('priv').onclick = () => {
  HIDE = !HIDE;
  if (HIDE) { query = ''; $('q').value = ''; }    // what was typed in the search box could be a real name
  paintPrivacy(); renderList();
};
window.addEventListener('resize', fitLabels);
if (document.fonts && document.fonts.ready) document.fonts.ready.then(fitLabels);
if ('IntersectionObserver' in window) {
  new IntersectionObserver(es => {
    $('toolbar').classList.toggle('stuck', !es[0].isIntersecting && es[0].boundingClientRect.top < 0);
  }).observe($('sentinel'));
}
</script>
</body>
</html>
'@

# Fill the template in a single pass, so text inside the data can never be mistaken for a placeholder
$script:map = @{ '__DATA__' = $json; '__META__' = $metaJson; '__DATE__' = (Get-Date -Format 'yyyy-MM-dd HH:mm') }
$html = [regex]::Replace($template, '__(?:DATA|META|DATE)__', [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $script:map[$m.Value] })

$file = Join-Path $reportDir $(if ($Redact) { 'repos-shared.html' } else { 'repos.html' })
try {
    if (-not (Test-Path -LiteralPath $reportDir)) { New-Item -ItemType Directory -Path $reportDir -Force -ErrorAction Stop | Out-Null }
    Set-Content -LiteralPath $file -Value $html -Encoding UTF8 -ErrorAction Stop
}
catch {
    # report folder is read-only (zip preview, Program Files...) or the old report is locked: use the temp folder
    $file = Join-Path ([IO.Path]::GetTempPath()) $(if ($Redact) { 'repoatlas-shared-report.html' } else { 'repoatlas-report.html' })
    Set-Content -LiteralPath $file -Value $html -Encoding UTF8
}

if ($Redact) { Write-Host "Shareable copy saved: $file ($($repos.Count) repos). Names, folders and accounts are placeholders; the real values are not in this file." }
else         { Write-Host "Report saved: $file ($($repos.Count) repos)" }
$openFailed = $false
try {
    if     ($onWindows) { Start-Process -FilePath $file -ErrorAction Stop }
    elseif ($IsMacOS)   { & open $file; if ($LASTEXITCODE -ne 0) { $openFailed = $true } }
    else                { & xdg-open $file 2>$null; if ($LASTEXITCODE -ne 0) { $openFailed = $true } }
} catch { $openFailed = $true }
if ($openFailed) { Write-Host 'Could not open a browser automatically - open the file above manually.'; exit 2 }
