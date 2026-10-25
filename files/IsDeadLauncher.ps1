# IsDead WoW Launcher
# Keeps this World of Warcraft folder in step with the IsDead WoW server
# (the patch files and the addons), then starts the game.
# Lives next to Wow.exe. Started by "IsDead Launcher.bat".
# Windows PowerShell 5.1 or newer.

param(
    [switch]$NoLaunch,      # update only, don't start the game
    [switch]$Repair,        # check every file again, even ones that look current
    [string]$Source = '',   # a plain URL to read the files from instead of GitHub (testing, mirrors)
    [switch]$SelfUpdated    # set by the launcher itself after it replaced itself
)

# Filled in by publish.ps1 from config.json:
$Owner  = 'sumogopher'
$Repo   = 'IsDead-Client'
$Branch = 'main'

$ErrorActionPreference = 'Stop'
$Game      = Split-Path -Parent $MyInvocation.MyCommand.Path
$StateFile = Join-Path $Game 'IsDeadLauncher.state.json'
$Self      = $MyInvocation.MyCommand.Path

try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
try { $Host.UI.RawUI.WindowTitle = 'IsDead WoW Launcher' } catch { }

function Say([string]$text, [string]$color = 'Gray') { Write-Host $text -ForegroundColor $color }

function New-Client {
    $c = New-Object System.Net.WebClient
    $c.Headers.Add('User-Agent', 'IsDead-Launcher')
    $c.Encoding = [System.Text.Encoding]::UTF8
    return $c
}

function Get-Sha256([string]$file) {
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $file).Hash.ToLowerInvariant()
}

function Start-Game {
    if ($NoLaunch) { return }
    $exe = Join-Path $Game 'Wow.exe'
    if (-not (Test-Path -LiteralPath $exe)) {
        Say 'Wow.exe is not in this folder. Put the launcher in your World of Warcraft folder (next to Wow.exe).' 'Red'
        Read-Host 'Press Enter to close' | Out-Null
        exit 1
    }
    Say 'Starting World of Warcraft...' 'Green'
    Start-Process -FilePath $exe -WorkingDirectory $Game
}

function Wait-NoGame {
    while (Get-Process -Name 'Wow' -ErrorAction SilentlyContinue) {
        Say 'World of Warcraft is running. Close it to update, then press Enter (or type S and Enter to skip the update).' 'Yellow'
        $a = Read-Host
        if ($a -match '^[sS]') { return $false }
    }
    return $true
}

# The client's language folder (Data\enUS, Data\enGB, ...)
function Get-Locale {
    $data = Join-Path $Game 'Data'
    if (Test-Path -LiteralPath $data) {
        foreach ($d in (Get-ChildItem -LiteralPath $data -Directory)) {
            if ($d.Name -cmatch '^[a-z]{2}[A-Z]{2}$' -and (Get-ChildItem -LiteralPath $d.FullName -Filter 'locale-*.MPQ' -ErrorAction SilentlyContinue)) {
                return $d.Name
            }
        }
    }
    return 'enUS'
}

function Get-LocalPath([object]$entry, [string]$locale) {
    $p = [string]$entry.path
    if ($entry.localized -and $locale -ne 'enUS') { $p = $p.Replace('enUS', $locale) }
    return $p
}

function Read-State {
    if (Test-Path -LiteralPath $StateFile) {
        try { return (Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json) } catch { }
    }
    return $null
}

function Set-Realmlist([string]$realmlist, [string]$locale) {
    if (-not $realmlist) { return }
    $line = "set realmlist $realmlist"
    $targets = @()
    $locDir = Join-Path (Join-Path $Game 'Data') $locale
    if (Test-Path -LiteralPath $locDir) { $targets += (Join-Path $locDir 'realmlist.wtf') }
    $rootFile = Join-Path $Game 'realmlist.wtf'
    if (Test-Path -LiteralPath $rootFile) { $targets += $rootFile }
    foreach ($f in $targets) {
        $old = ''
        if (Test-Path -LiteralPath $f) { $old = [string](Get-Content -LiteralPath $f -Raw) }
        if ($old.Trim() -ne $line) { Set-Content -LiteralPath $f -Value $line -Encoding ASCII; Say "  realmlist set to $realmlist" }
    }
    # Config.wtf can hold its own realmlist, which wins over realmlist.wtf
    $cfg = Join-Path (Join-Path $Game 'WTF') 'Config.wtf'
    if (Test-Path -LiteralPath $cfg) {
        $want = 'SET realmList "' + $realmlist + '"'
        $changed = $false
        $out = foreach ($l in @(Get-Content -LiteralPath $cfg)) {
            if ($l -match '^SET realmList ' -and $l -ne $want) { $changed = $true; $want } else { $l }
        }
        if ($changed) { Set-Content -LiteralPath $cfg -Value $out -Encoding ASCII }
    }
}

# ---------------------------------------------------------------------------

Say ''
Say '  IsDead WoW Launcher' 'Cyan'
Say ''

if (-not (Test-Path -LiteralPath (Join-Path $Game 'Wow.exe')) -and -not $NoLaunch) {
    Say 'Wow.exe is not in this folder. Put "IsDead Launcher.bat" and IsDeadLauncher.ps1 in your World of Warcraft folder (next to Wow.exe) and run it from there.' 'Red'
    Read-Host 'Press Enter to close' | Out-Null
    exit 1
}

$web = New-Client

# Where the files come from: the newest commit, so the list and the files always match
$root = $Source.TrimEnd('/')
if (-not $root) {
    $ref = $Branch
    try {
        $web.Headers.Add('Accept', 'application/vnd.github.sha')
        $sha = $web.DownloadString("https://api.github.com/repos/$Owner/$Repo/commits/$Branch").Trim()
        if ($sha -match '^[0-9a-f]{40}$') { $ref = $sha }
    } catch { }
    $web = New-Client
    $root = "https://raw.githubusercontent.com/$Owner/$Repo/$ref"
}

try {
    $manifest = $web.DownloadString("$root/manifest.json") | ConvertFrom-Json
} catch {
    Say "Couldn't reach the update server ($($_.Exception.Message))." 'Yellow'
    Say 'Starting the game with the files you have.' 'Yellow'
    Start-Sleep -Seconds 2
    Start-Game
    exit 0
}

# The launcher updates itself first, then starts again as the new version
$me = $manifest.files | Where-Object { $_.path -eq 'IsDeadLauncher.ps1' } | Select-Object -First 1
if ($me -and -not $SelfUpdated -and (Get-Sha256 $Self) -ne $me.sha256) {
    Say 'Updating the launcher...' 'Cyan'
    $tmp = "$Self.new"
    $web.DownloadFile("$root/files/IsDeadLauncher.ps1", $tmp)
    if ((Get-Sha256 $tmp) -eq $me.sha256) {
        Move-Item -LiteralPath $tmp -Destination $Self -Force
        $again = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Self, '-SelfUpdated')
        if ($NoLaunch) { $again += '-NoLaunch' }
        if ($Repair) { $again += '-Repair' }
        if ($Source) { $again += @('-Source', $Source) }
        $ps = (Get-Process -Id $PID).Path
        & $ps @again
        exit $LASTEXITCODE
    }
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
}

$locale = Get-Locale
$state  = Read-State
$known  = @{}
if ($state -and $state.files) { foreach ($p in $state.files.PSObject.Properties) { $known[$p.Name] = [string]$p.Value } }

Say "Server client version $($manifest.version). Checking your files ($locale)..."

# What needs downloading
$todo = @()
foreach ($f in $manifest.files) {
    $local = Get-LocalPath $f $locale
    $full  = Join-Path $Game $local
    if (-not (Test-Path -LiteralPath $full)) { $todo += $f; continue }
    $item = Get-Item -LiteralPath $full
    # quick check: same size and we wrote it last time -> fine (unless -Repair)
    if (-not $Repair -and $item.Length -eq [int64]$f.size -and $known[$local] -eq $f.sha256) { continue }
    if ((Get-Sha256 $full) -ne $f.sha256) { $todo += $f }
}

# Files the launcher put here before that the server no longer ships
$wanted = @{}
foreach ($f in $manifest.files) { $wanted[(Get-LocalPath $f $locale)] = $true }
$stale = @()
foreach ($k in $known.Keys) { if (-not $wanted[$k]) { $stale += $k } }
foreach ($d in @($manifest.managedDirs)) {
    if (-not $d) { continue }
    $full = Join-Path $Game $d
    if (Test-Path -LiteralPath $full) {
        foreach ($x in (Get-ChildItem -LiteralPath $full -Recurse -File)) {
            $rel = $x.FullName.Substring($Game.Length).TrimStart('\', '/').Replace('\', '/')
            if (-not $wanted[$rel] -and $stale -notcontains $rel) { $stale += $rel }
        }
    }
}

$clearCache = (-not $state) -or ([string]$state.cacheVersion -ne [string]$manifest.cacheVersion)

if ($todo.Count -eq 0 -and $stale.Count -eq 0 -and -not $clearCache) {
    Say 'Everything is up to date.' 'Green'
} else {
    if (-not (Wait-NoGame)) { Start-Game; exit 0 }

    $total = ($todo | Measure-Object -Property size -Sum).Sum
    if (-not $total) { $total = 0 }
    if ($todo.Count -gt 0) { Say ("Downloading {0} file(s), {1:N1} MB..." -f $todo.Count, ($total / 1MB)) 'Cyan' }
    $i = 0
    foreach ($f in $todo) {
        $i++
        $local = Get-LocalPath $f $locale
        $full  = Join-Path $Game $local
        $dir   = Split-Path -Parent $full
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $url = "$root/files/" + ((([string]$f.path).Split('/') | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/')
        Write-Progress -Activity 'Updating IsDead WoW' -Status $local -PercentComplete ([int](100 * $i / $todo.Count))
        $tmp = "$full.part"
        $ok = $false
        for ($try = 1; $try -le 3 -and -not $ok; $try++) {
            try {
                $web.DownloadFile($url, $tmp)
                if ((Get-Sha256 $tmp) -eq $f.sha256) { $ok = $true } else { Say "  $local came down damaged, trying again..." 'Yellow' }
            } catch {
                Say "  $local : $($_.Exception.Message) (try $try of 3)" 'Yellow'
                Start-Sleep -Seconds 2
            }
        }
        if (-not $ok) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            Say "Couldn't download $local. Run the launcher again in a minute." 'Red'
            Read-Host 'Press Enter to close' | Out-Null
            exit 1
        }
        Move-Item -LiteralPath $tmp -Destination $full -Force
        Say "  updated $local"
    }
    Write-Progress -Activity 'Updating IsDead WoW' -Completed

    foreach ($rel in $stale) {
        $full = Join-Path $Game $rel
        if (-not (Test-Path -LiteralPath $full)) { continue }
        # a patch file the server no longer ships: only if it is still the one this launcher put there (a file of
        # the same name from somewhere else, an HD pack's Patch-A say, stays)
        if ($known.ContainsKey($rel) -and $known[$rel] -and (Get-Sha256 $full) -ne $known[$rel]) {
            Say "  kept $rel (not ours any more)"
            continue
        }
        Remove-Item -LiteralPath $full -Force; Say "  removed $rel"
    }

    if ($clearCache) {
        $cache = Join-Path $Game 'Cache'
        if (Test-Path -LiteralPath $cache) { Remove-Item -LiteralPath $cache -Recurse -Force -ErrorAction SilentlyContinue; Say '  cleared the Cache folder' }
    }
    Say 'Up to date.' 'Green'
}

Set-Realmlist ([string]$manifest.realmlist) $locale

# Remember what we installed (for removals, the quick check and the Cache)
$files = [ordered]@{}
foreach ($f in $manifest.files) { $files[(Get-LocalPath $f $locale)] = [string]$f.sha256 }
$newState = [ordered]@{ version = [string]$manifest.version; cacheVersion = [string]$manifest.cacheVersion; locale = $locale; files = $files }
$newState | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $StateFile -Encoding UTF8

if ($manifest.news) { Say ''; Say ([string]$manifest.news) 'White' }
Say ''
Start-Game
Start-Sleep -Seconds 1
