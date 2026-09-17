<#
    medal-patcher - TUI patcher for the Medal desktop app (Electron).

    Run:  irm https://raw.githubusercontent.com/<you>/medal-patcher/main/medal-patcher.ps1 | iex
    or:   .\medal-patcher.ps1

    How it works: Medal's resources\app.asar has the ASAR-integrity and
    only-load-from-asar fuses disabled, so the entry point can be swapped.
    Dropping a resources\app\ folder does NOT work (Electron ignores it here),
    so this flips the top-level index.js header entry to "unpacked" - an
    in-place edit of the same byte length, leaving every other file offset
    untouched - and serves the shim from app.asar.unpacked\index.js.
#>

$ErrorActionPreference = 'Stop'

$script:HomeDir    = Join-Path $env:LOCALAPPDATA 'medal-patcher'
$script:ConfigPath = Join-Path $script:HomeDir 'config.json'

$script:State = @{
    Root      = $null
    Ads       = $true      # block ad traffic + hide the empty ad slots
    Telemetry = $true      # block analytics endpoints (Amplitude, Sentry, ...)
}

# ---------------------------------------------------------------- helpers ---

function Write-Ok   ($m) { Write-Host "  [ok]   $m" -ForegroundColor Green }
function Write-Info ($m) { Write-Host "  [--]   $m" -ForegroundColor Gray }
function Write-Warn ($m) { Write-Host "  [!!]   $m" -ForegroundColor Yellow }
function Write-Err  ($m) { Write-Host "  [xx]   $m" -ForegroundColor Red }

function Pause-Key {
    Write-Host ''
    Write-Host '  Press any key to continue...' -ForegroundColor DarkGray
    [void]$Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
}

function Write-Utf8NoBom ($Path, $Text) {
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding $false))
}

function Find-MedalRoot {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Medal\current\resources'),
        (Join-Path $env:LOCALAPPDATA 'Medal\resources'),
        'C:\Program Files\Medal\resources'
    )
    foreach ($c in $candidates) {
        if (Test-Path (Join-Path $c 'app.asar')) { return $c }
    }
    # Squirrel-style app-<version> folders
    $sq = Join-Path $env:LOCALAPPDATA 'Medal'
    if (Test-Path $sq) {
        $hit = Get-ChildItem $sq -Directory -Filter 'app-*' -ErrorAction SilentlyContinue |
               Sort-Object Name -Descending |
               ForEach-Object { Join-Path $_.FullName 'resources' } |
               Where-Object { Test-Path (Join-Path $_ 'app.asar') } |
               Select-Object -First 1
        if ($hit) { return $hit }
    }
    return $null
}

# Killing Medal ourselves trips its watchdog ("Medal has become unresponsive")
# and leaves orphaned children holding the asar, so just wait for the user.
# Returns $true once Medal is closed, $false if they pressed Esc to cancel.
function Test-FileUnlocked ($Path) {
    try { $fs = [IO.File]::Open($Path, 'Open', 'ReadWrite', 'None'); $fs.Dispose(); return $true }
    catch { return $false }
}

function Wait-MedalClosed {
    $asar = Join-Path $script:State.Root 'app.asar'
    if (-not (Get-Process -Name 'Medal', 'MedalEncoder' -ErrorAction SilentlyContinue)) { return $true }

    Write-Host ''
    Write-Warn 'Medal must be fully closed before patching.'
    Write-Host ''
    Write-Host '         Clicking X only hides Medal in the tray - it keeps running.' -ForegroundColor White
    Write-Host '         Find the Medal icon in the tray (bottom-right, under the ^ arrow),' -ForegroundColor White
    Write-Host '         right-click it and choose Quit.' -ForegroundColor White
    Write-Host ''
    Write-Host '         This continues by itself the moment Medal exits.' -ForegroundColor DarkGray
    Write-Host '         Esc cancels. Enter patches anyway (applies on next start).' -ForegroundColor DarkGray
    Write-Host ''

    $spin = '|/-'; $i = 0
    while ($true) {
        $procs = @(Get-Process -Name 'Medal', 'MedalEncoder' -ErrorAction SilentlyContinue)
        if ($procs.Count -eq 0) {
            Write-Host ("`r" + (' ' * 78) + "`r") -NoNewline
            Write-Ok 'Medal closed.'
            Start-Sleep -Milliseconds 500      # let Windows release the file
            return $true
        }
        $names = ($procs | Select-Object -First 4 | ForEach-Object { "$($_.Name):$($_.Id)" }) -join ' '
        Write-Host ("`r  [{0}]    still running ({1}): {2}   " -f $spin[$i % 4], $procs.Count, $names) -NoNewline -ForegroundColor Yellow
        $i++

        # [Console] is used instead of $Host.UI.RawUI: the latter can block or
        # throw depending on the host, which looks like a frozen script.
        $code = 0
        try { if ([Console]::KeyAvailable) { $code = [int][Console]::ReadKey($true).Key } } catch { }
        if ($code) {
            Write-Host ("`r" + (' ' * 78) + "`r") -NoNewline
            if ($code -eq 27) {
                Write-Warn 'Cancelled - nothing was changed.'
                return $false
            }
            if ($code -eq 13) {
                if (Test-FileUnlocked $asar) {
                    Write-Warn "Continuing with $($procs.Count) Medal processes still running."
                    return $true
                }
                Write-Err 'Medal still has app.asar open - it cannot be patched yet.'
            }
        }
        Start-Sleep -Milliseconds 250
    }
}

# Windows keeps the asar mapped for a moment after the processes die.
function Wait-FileUnlocked ($Path, $TimeoutSec = 30) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-FileUnlocked $Path) { return }
        Start-Sleep -Milliseconds 400
    }
    throw "Timed out waiting for $Path to be released. Close Medal fully (tray icon -> Quit) and retry."
}

function Start-Medal {
    $exe = Join-Path $env:LOCALAPPDATA 'Medal\Medal.exe'
    if (-not (Test-Path $exe)) { $exe = Join-Path (Split-Path $script:State.Root) 'Medal.exe' }
    if (Test-Path $exe) { Start-Process $exe; Write-Ok 'Medal relaunched.' }
    else { Write-Warn 'Could not find Medal.exe - start it yourself.' }
}

# ----------------------------------------------------------------- config ---

function Import-Config {
    if (-not (Test-Path $script:ConfigPath)) { return }
    try {
        $c = Get-Content $script:ConfigPath -Raw | ConvertFrom-Json
        if ($null -ne $c.Ads)       { $script:State.Ads       = [bool]$c.Ads }
        if ($null -ne $c.Telemetry) { $script:State.Telemetry = [bool]$c.Telemetry }
    } catch { }
}

function Export-Config {
    New-Item -ItemType Directory -Path $script:HomeDir -Force | Out-Null
    [pscustomobject]@{
        Ads = $script:State.Ads; Telemetry = $script:State.Telemetry
    } | ConvertTo-Json | Set-Content $script:ConfigPath -Encoding UTF8
}

# ------------------------------------------------------------ asar surgery ---

# Returns @{ JsonLength; ContentBase; Json } for an asar file.
function Get-AsarHeader ($AsarPath) {
    $fs = [IO.File]::OpenRead($AsarPath)
    try {
        $buf = New-Object byte[] 16
        [void]$fs.Read($buf, 0, 16)
        $sizeOfPickle = [BitConverter]::ToUInt32($buf, 4)
        $jsonLength   = [BitConverter]::ToUInt32($buf, 12)
        $jsonBytes    = New-Object byte[] $jsonLength
        [void]$fs.Read($jsonBytes, 0, $jsonLength)
        return @{
            JsonLength  = [int]$jsonLength
            ContentBase = [int]($sizeOfPickle + 8)
            Json        = [Text.Encoding]::UTF8.GetString($jsonBytes)
        }
    } finally { $fs.Dispose() }
}

# Locates a file entry that is a DIRECT member of the asar root (depth 2 in the
# JSON: root object -> "files" object -> entry). Regex can't do this safely
# because node_modules contains dozens of other index.js entries.
function Find-RootEntry ($Json, $Name) {
    $depth = 0; $inStr = $false; $esc = $false
    $keyStart = -1; $pendingKey = $null
    for ($i = 0; $i -lt $Json.Length; $i++) {
        $ch = $Json[$i]
        if ($inStr) {
            if ($esc) { $esc = $false; continue }
            if ($ch -eq '\') { $esc = $true; continue }
            if ($ch -eq '"') {
                $inStr = $false
                if ($depth -eq 2) { $pendingKey = $Json.Substring($keyStart + 1, $i - $keyStart - 1) }
            }
            continue
        }
        if ($ch -eq '"') { $inStr = $true; $keyStart = $i }
        elseif ($ch -eq '{') {
            $depth++
            if ($depth -eq 3 -and $pendingKey -eq $Name) {
                # scan to the matching close brace
                $d = 0; $s = $false; $e = $false
                for ($j = $i; $j -lt $Json.Length; $j++) {
                    $c = $Json[$j]
                    if ($s) {
                        if ($e) { $e = $false } elseif ($c -eq '\') { $e = $true } elseif ($c -eq '"') { $s = $false }
                        continue
                    }
                    if ($c -eq '"') { $s = $true }
                    elseif ($c -eq '{') { $d++ }
                    elseif ($c -eq '}') { $d--; if ($d -eq 0) { return @{ Start = $keyStart; End = $j + 1 } } }
                }
            }
        }
        elseif ($ch -eq '}') { $depth-- }
    }
    return $null
}

function Get-AsarFileBytes ($AsarPath, $ContentBase, $Offset, $Size) {
    $fs = [IO.File]::OpenRead($AsarPath)
    try {
        [void]$fs.Seek([int64]$ContentBase + [int64]$Offset, 'Begin')
        $b = New-Object byte[] $Size
        [void]$fs.Read($b, 0, $Size)
        return $b
    } finally { $fs.Dispose() }
}

function Set-AsarBytes ($AsarPath, $ByteOffset, [byte[]]$Bytes) {
    $fs = [IO.File]::Open($AsarPath, 'Open', 'Write')
    try {
        [void]$fs.Seek([int64]$ByteOffset, 'Begin')
        $fs.Write($Bytes, 0, $Bytes.Length)
    } finally { $fs.Dispose() }
}

# ------------------------------------------------------------------- shim ---

function New-ShimSource ($Ads, $Telemetry) {
    $js = @'
// Installed by medal-patcher. Original entry point is index-orig.js.
// Revert: run the patcher and pick Restore, or copy app.asar.bak over app.asar.
const fs = require('fs');
const os = require('os');
const path = require('path');
const { app, session } = require('electron');

const CONFIG = __CONFIG__;

const LOG = path.join(os.tmpdir(), 'medal-patcher.log');
const log = (m) => { try { fs.appendFileSync(LOG, new Date().toISOString() + ' ' + m + '\n'); } catch {} };
log('shim loaded');

// Every ad slot renders as <div data-fallback-reason="..."> in Medal's renderer.
const CSS = 'div[data-fallback-reason]{display:none!important}';

// The slot sits inside a card wrapper with no stable class name, so climb while
// the ad is its parent's only child and hide that - removes the empty placeholder.
const SWEEP = `(() => {
  if (window.__medalAdHide) return; window.__medalAdHide = 1;
  const sweep = () => {
    for (const el of document.querySelectorAll('div[data-fallback-reason]')) {
      let n = el;
      while (n.parentElement && n.parentElement !== document.body &&
             n.parentElement.childElementCount === 1) n = n.parentElement;
      if (n.dataset.medalAdHidden) continue;
      n.dataset.medalAdHidden = '1';
      n.style.display = 'none';
    }
  };
  let queued = false;
  new MutationObserver(() => {
    if (queued) return; queued = true;
    requestAnimationFrame(() => { queued = false; sweep(); });
  }).observe(document.documentElement, { childList: true, subtree: true });
  sweep();
})()`;

// Analytics endpoints only - Medal's own api-gateway / cdn hosts are untouched.
const TELEMETRY_URLS = [
  '*://*.amplitude.com/*',
  '*://*.sentry.io/*',
  '*://sentry.medal.tv/*',
  '*://*.honeycomb.io/*',
  '*://*.mixpanel.com/*',
  '*://*.google-analytics.com/*',
  '*://*.doubleclick.net/*'
];

app.once('ready', () => {
  if (CONFIG.ads) {
    // Medal renders every ad in a <webview partition="persist:ads">.
    let blocked = 0;
    session.fromPartition('persist:ads').webRequest.onBeforeRequest((d, cb) => {
      blocked++;
      cb({ cancel: true });
    });
    setInterval(() => log('blocked=' + blocked), 60000).unref();
    log('ad network blocking armed');
  }

  if (CONFIG.telemetry) {
    let dropped = 0;
    const filter = { urls: TELEMETRY_URLS };
    const block = (d, cb) => { dropped++; cb({ cancel: true }); };
    app.on('session-created', (ses) => { try { ses.webRequest.onBeforeRequest(filter, block); } catch {} });
    session.defaultSession.webRequest.onBeforeRequest(filter, block);
    setInterval(() => log('telemetry dropped=' + dropped), 60000).unref();
    log('telemetry blocking armed');
  }

  // Optional user stylesheet, injected into every window if it exists.
  const userCssPath = path.join(app.getPath('userData'), 'user.css');

  app.on('web-contents-created', (_e, wc) => {
    // Stop the in-game ad webviews attaching at all, so they cost no GPU /
    // compositor time instead of just rendering blank.
    if (CONFIG.ads) {
      wc.on('will-attach-webview', (e, _prefs, params) => {
        if (params.partition === 'persist:ads') { e.preventDefault(); }
      });
    }

    wc.on('dom-ready', () => {
      if (CONFIG.ads) {
        wc.insertCSS(CSS).catch(() => {});
        wc.executeJavaScript(SWEEP).catch(() => {});
      }
      try {
        if (fs.existsSync(userCssPath)) { wc.insertCSS(fs.readFileSync(userCssPath, 'utf8')).catch(() => {}); }
      } catch {}
    });
  });
  if (CONFIG.ads) { log('ad element hiding armed'); }
});

// Run Medal's real entry point as if it were this file, so __dirname stays
// inside the asar and all of its relative requires resolve normally.
const orig = path.join(process.resourcesPath, 'app.asar.unpacked', 'index-orig.js');
module._compile(fs.readFileSync(orig, 'utf8'), __filename);
'@
    $cfg = "{ ads: $($Ads.ToString().ToLower()), telemetry: $($Telemetry.ToString().ToLower()) }"
    return $js.Replace('__CONFIG__', $cfg)
}

# ---------------------------------------------------------------- actions ---

function Get-PatchStatus {
    $root = $script:State.Root
    if (-not $root) { return 'No install found' }
    $asar = Join-Path $root 'app.asar'
    $hdr  = Get-AsarHeader $asar
    $e    = Find-RootEntry $hdr.Json 'index.js'
    if (-not $e) { return 'Unknown (no index.js entry)' }
    $txt = $hdr.Json.Substring($e.Start, $e.End - $e.Start)
    if ($txt -match '"unpacked"\s*:\s*true') { return 'PATCHED' }
    return 'Clean'
}

function Invoke-Restore ([switch]$Quiet) {
    $root = $script:State.Root
    $asar = Join-Path $root 'app.asar'
    $bak  = Join-Path $root 'app.asar.bak'
    if (-not (Test-Path $bak)) {
        if (-not $Quiet) { Write-Warn 'No backup found - nothing to restore.' }
        return
    }
    Wait-FileUnlocked $asar
    Copy-Item $bak $asar -Force
    Remove-Item (Join-Path $root 'app.asar.unpacked\index.js')      -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $root 'app.asar.unpacked\index-orig.js') -Force -ErrorAction SilentlyContinue
    # a stray resources\app\ from older attempts confuses nothing, but tidy it
    $stray = Join-Path $root 'app'
    if (Test-Path (Join-Path $stray 'index.js')) {
        if ((Get-Content (Join-Path $stray 'index.js') -Raw) -match 'medal-patcher|Medal patch shim') {
            Remove-Item $stray -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    if (-not $Quiet) { Write-Ok 'Original app.asar restored.' }
}

function Invoke-Patch {
    $root = $script:State.Root
    $asar = Join-Path $root 'app.asar'
    $bak  = Join-Path $root 'app.asar.bak'
    $unp  = Join-Path $root 'app.asar.unpacked'

    if (-not (Wait-MedalClosed)) { return }
    $running = @(Get-Process -Name 'Medal' -ErrorAction SilentlyContinue).Count -gt 0
    Wait-FileUnlocked $asar

    if (-not (Test-Path $bak)) {
        Write-Info 'Backing up app.asar -> app.asar.bak'
        Copy-Item $asar $bak -Force
    } else {
        # always patch from a clean asar so re-running is idempotent
        Copy-Item $bak $asar -Force
    }

    $hdr = Get-AsarHeader $asar
    $e   = Find-RootEntry $hdr.Json 'index.js'
    if (-not $e) { throw 'Could not locate the top-level index.js entry in app.asar.' }

    $entryText = $hdr.Json.Substring($e.Start, $e.End - $e.Start)
    if ($entryText -notmatch '"offset"\s*:\s*"(\d+)"' ) { throw "Unexpected index.js entry: $entryText" }
    $offset = [int64]$Matches[1]
    if ($entryText -notmatch '"size"\s*:\s*(\d+)') { throw "Unexpected index.js entry: $entryText" }
    $size = [int]$Matches[1]

    # 1. preserve the real entry point next to the asar
    New-Item -ItemType Directory -Path $unp -Force | Out-Null
    $origBytes = Get-AsarFileBytes $asar $hdr.ContentBase $offset $size
    [IO.File]::WriteAllBytes((Join-Path $unp 'index-orig.js'), $origBytes)
    Write-Ok "Preserved original entry point ($size bytes)."

    # 2. write the shim
    $shim = New-ShimSource $script:State.Ads $script:State.Telemetry
    Write-Utf8NoBom (Join-Path $unp 'index.js') $shim
    $shimSize = (Get-Item (Join-Path $unp 'index.js')).Length
    Write-Ok "Wrote shim ($shimSize bytes)."

    # 3. flip the header entry to unpacked, padded to the exact same byte length
    #    so every other file's offset in the archive stays valid.
    $newEntry = '"index.js":{"size":' + $shimSize + ',"unpacked":true,"pad":"'
    $padLen = $entryText.Length - $newEntry.Length - 2
    if ($padLen -lt 0) { throw 'Header entry too small to rewrite in place.' }
    $newEntry = $newEntry + ('x' * $padLen) + '"}'
    if ($newEntry.Length -ne $entryText.Length) { throw 'Entry length mismatch.' }

    $byteOffset = 16 + [Text.Encoding]::UTF8.GetByteCount($hdr.Json.Substring(0, $e.Start))
    Set-AsarBytes $asar $byteOffset ([Text.Encoding]::UTF8.GetBytes($newEntry))
    Write-Ok 'Patched app.asar header in place.'

    Export-Config

    # 4. verify
    if ((Get-PatchStatus) -ne 'PATCHED') { throw 'Verification failed - restoring backup.' }
    Write-Ok 'Verified.'

    Write-Host ''
    if ($running) { Write-Warn 'Restart Medal (tray icon -> Quit, then reopen) to activate the patch.' }
    else { Start-Medal }
}

# -------------------------------------------------------------------- TUI ---

function Show-Banner {
    Clear-Host
    Write-Host ''
    Write-Host '   ##     ##  ######  ######      ###    ##       ' -ForegroundColor Cyan
    Write-Host '   ###   ### ##      ##    ##    ## ##   ##       ' -ForegroundColor Cyan
    Write-Host '   ## ### ## ######  ##    ##   ##   ##  ##       ' -ForegroundColor Cyan
    Write-Host '   ##     ## ##      ##    ##  ######### ##       ' -ForegroundColor Cyan
    Write-Host '   ##     ## ######  ######   ##     ## ######## ' -ForegroundColor Cyan
    Write-Host '                    p a t c h e r' -ForegroundColor DarkCyan
    Write-Host ''

    $status = Get-PatchStatus
    $color  = switch ($status) { 'PATCHED' { 'Green' } 'Clean' { 'Yellow' } default { 'Red' } }
    Write-Host '   Install : ' -NoNewline -ForegroundColor DarkGray
    Write-Host $(if ($script:State.Root) { $script:State.Root } else { 'not found' }) -ForegroundColor White
    Write-Host '   Status  : ' -NoNewline -ForegroundColor DarkGray
    Write-Host $status -ForegroundColor $color
    Write-Host '   Options : ' -NoNewline -ForegroundColor DarkGray
    Write-Host ("remove ads [{0}]   block telemetry [{1}]" -f `
        $(if ($script:State.Ads)       { 'on' } else { 'off' }),
        $(if ($script:State.Telemetry) { 'on' } else { 'off' })) -ForegroundColor White
    Write-Host ''
    Write-Host '  ------------------------------------------------------------' -ForegroundColor DarkGray
}

function Show-Menu {
    Write-Host ''
    Write-Host '   [1] ' -NoNewline -ForegroundColor Cyan; Write-Host 'Apply patch'
    Write-Host '   [2] ' -NoNewline -ForegroundColor Cyan; Write-Host 'Restore original (undo)'
    Write-Host '   [3] ' -NoNewline -ForegroundColor Cyan; Write-Host 'Toggle: remove ads'
    Write-Host '   [4] ' -NoNewline -ForegroundColor Cyan; Write-Host 'Toggle: block telemetry'
    Write-Host '   [5] ' -NoNewline -ForegroundColor Cyan; Write-Host 'Edit custom CSS (user.css)'
    Write-Host '   [6] ' -NoNewline -ForegroundColor Cyan; Write-Host 'Show patch log'
    Write-Host '   [0] ' -NoNewline -ForegroundColor Cyan; Write-Host 'Exit'
    Write-Host ''
    Write-Host '   Choose: ' -NoNewline -ForegroundColor Yellow
}

function Edit-UserCss {
    $css = Join-Path $env:APPDATA 'Medal\user.css'
    if (-not (Test-Path $css)) {
        Write-Utf8NoBom $css "/* Custom CSS for Medal, injected into every window by medal-patcher.`r`n   Restart Medal to apply changes. Example:`r`n`r`n   div[data-fallback-reason] { display: none !important; }`r`n*/`r`n"
        Write-Ok "Created $css"
    }
    Write-Info 'Opening in Notepad. Save it, then restart Medal to apply.'
    Start-Process notepad.exe $css
    Pause-Key
}

function Show-Log {
    $log = Join-Path $env:TEMP 'medal-patcher.log'
    Write-Host ''
    if (Test-Path $log) { Get-Content $log -Tail 25 }
    else { Write-Info 'No log yet - patch and start Medal first.' }
    Pause-Key
}

function Main {
    Import-Config
    $script:State.Root = Find-MedalRoot
    if (-not $script:State.Root) {
        Show-Banner
        Write-Err 'Could not find Medal. Expected %LOCALAPPDATA%\Medal\current\resources\app.asar'
        Pause-Key
        return
    }

    while ($true) {
        Show-Banner
        Show-Menu
        $choice = Read-Host
        Write-Host ''
        try {
            switch ($choice) {
                '1' { Invoke-Patch; Pause-Key }
                '2' {
                    if (-not (Wait-MedalClosed)) { Pause-Key; break }
                    $wasUp = @(Get-Process -Name 'Medal' -ErrorAction SilentlyContinue).Count -gt 0
                    Invoke-Restore
                    if ($wasUp) { Write-Warn 'Restart Medal (tray icon -> Quit, then reopen) to drop the patch.' }
                    else { Start-Medal }
                    Pause-Key
                }
                '3' { $script:State.Ads       = -not $script:State.Ads;       Export-Config }
                '4' { $script:State.Telemetry = -not $script:State.Telemetry; Export-Config }
                '5' { Edit-UserCss }
                '6' { Show-Log }
                '0' { return }
                default { }
            }
        } catch {
            Write-Err $_.Exception.Message
            Write-Warn 'Attempting to restore the backup...'
            try { Invoke-Restore | Out-Null } catch { Write-Err 'Restore failed - copy app.asar.bak over app.asar manually.' }
            Pause-Key
        }
    }
}

Main
