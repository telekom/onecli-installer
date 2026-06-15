#Requires -Version 5.1
<#
.SYNOPSIS
  Installer for the 'one' CLI on Windows (x64 or arm64).

.DESCRIPTION
  Two modes:

    1. Web install (irm | iex):
         irm https://raw.githubusercontent.com/telekom/onecli-installer/main/install.ps1 | iex

       Behind a corporate proxy, forward $env:HTTPS_PROXY explicitly:
         $u = 'https://raw.githubusercontent.com/telekom/onecli-installer/main/install.ps1'
         $a = @{ Uri = $u }
         if ($env:HTTPS_PROXY) { $a.Proxy = $env:HTTPS_PROXY; $a.ProxyUseDefaultCredentials = $true }
         iex (irm @a)

       Authenticates against GitLab via OAuth 2.0 device flow (falls back
       to a Personal Access Token prompt), downloads the latest Windows
       release tarball, installs it, and wires up a shim on PATH.

    2. Local install from a downloaded tarball:
         .\install.ps1 -Tarball one-1.17.1-win32-x64.tar.gz

       Skips auth and networking; just extracts and installs.

  Requires Node.js >= 24 and Windows 10 1803+ (for the built-in `tar`).

.PARAMETER Tarball
  Path to a one-*.tar.gz. If omitted, the installer authenticates and
  downloads the latest release.

.PARAMETER InstallDir
  Install location. Default: %USERPROFILE%\.one

.PARAMETER BinDir
  Directory for the `one.cmd` shim. Default: %USERPROFILE%\.local\bin

.PARAMETER Token
  Skip interactive auth; use this GitLab token (PAT or OAuth access
  token) for the download. Also honored via the ONE_TOKEN env var.

.ENVIRONMENT
  ONE_AUTH_SKIP_BROWSER_PROMPT=1 opens the browser immediately during
  GitLab device-flow auth.
#>
[CmdletBinding()]
param(
    [string]$Tarball,
    [string]$InstallDir = (Join-Path $env:USERPROFILE '.one'),
    [string]$BinDir = (Join-Path $env:USERPROFILE '.local\bin'),
    [string]$Token
)

# `throw` from helpers is handled by a trap instead of `exit`, which would
# close the caller's shell when invoked via `irm | iex`.
$PreviousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Stop'
trap {
    Write-Host "ERROR $($_.Exception.Message)" -ForegroundColor Red
    if ($extractDir -and (Test-Path $extractDir)) { Remove-Item -Recurse -Force $extractDir -ErrorAction SilentlyContinue }
    if ($downloadedTarball -and (Test-Path (Split-Path $downloadedTarball -Parent))) {
        Remove-Item -Recurse -Force (Split-Path $downloadedTarball -Parent) -ErrorAction SilentlyContinue
    }
    $ErrorActionPreference = $PreviousErrorActionPreference
    return
}

# --- proxy helper: forwarded to every internal Invoke-RestMethod /
# Invoke-WebRequest call so corporate proxies that require explicit
# credentials are happy. No-op when HTTPS_PROXY isn't set.
function Add-ProxyArgs([hashtable]$RequestArgs) {
    if ($env:HTTPS_PROXY) {
        $RequestArgs['Proxy'] = $env:HTTPS_PROXY
        $RequestArgs['ProxyUseDefaultCredentials'] = $true
    }
}

# --- constants ---
$GitLabUrl = 'https://gitlab.devops.telekom.de'
$GitLabProjectId = '452386'
$GitLabClientId = 'cc421c2bb511f08109854cd7f93de401909fc8228999a20394cd8634a6266928'
$GitLabScopes = 'read_api openid read_user'
$NodeMinMajor = 24
$DeviceFlowTimeoutSec = 900

if (-not $Token -and $env:ONE_TOKEN) { $Token = $env:ONE_TOKEN }
if ($env:ONE_INSTALL_DIR) { $InstallDir = $env:ONE_INSTALL_DIR }
if ($env:ONE_BIN_DIR) { $BinDir = $env:ONE_BIN_DIR }

# Data directory used by the CLI for settings and keychain fallback.
# Must match the default in src/services/config/paths.ts (overridable via ONE_DATA_DIR).
if ($env:ONE_DATA_DIR) {
    $OneDataDir = $env:ONE_DATA_DIR
} elseif ($env:LOCALAPPDATA) {
    $OneDataDir = Join-Path $env:LOCALAPPDATA 'onecli'
} else {
    $OneDataDir = Join-Path $env:USERPROFILE 'AppData\Local\onecli'
}

# --- output helpers ---
function Write-Info($msg) { Write-Host $msg }
function Write-Ok($msg) { Write-Host "OK $msg" -ForegroundColor Green }
function Write-Warn2($msg) { Write-Host "! $msg" -ForegroundColor Yellow }
function Write-Err($msg) {
    # `throw` unwinds the enclosing script block so the caller sees a clean
    # error instead of their shell closing (which is what `exit` would do).
    throw $msg
}

# --- preflight ---
$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) {
    Write-Err "Node.js >= $NodeMinMajor is required. Install from https://nodejs.org"
}
# Parse `node --version` (e.g. "v24.14.0") in PowerShell to avoid
# PowerShell's argument-rewriting quirk that strips embedded double quotes
# when calling external executables with `node -e '...".".."'`.
$nodeVersion = (& node --version).TrimStart('v', 'V')
$nodeMajor = [int]($nodeVersion.Split('.')[0])
if ($nodeMajor -lt $NodeMinMajor) {
    Write-Err "Node.js >= $NodeMinMajor required (found $nodeVersion)"
}
$tar = Get-Command tar -ErrorAction SilentlyContinue
if (-not $tar) {
    Write-Err "tar is required (ships with Windows 10 1803+). Please update Windows."
}

# --- mode detection ---
if ($Tarball) {
    if (-not (Test-Path $Tarball)) { Write-Err "File not found: $Tarball" }
    $mode = 'local'
} else {
    $mode = 'web'
}

# --- state ---
$script:accessToken = $null
$script:tokenResponse = $null
$downloadedTarball = $null
$tag = $null

# --- auth: device flow ---
function Invoke-DeviceFlow {
    Write-Info 'Authenticating via GitLab device flow...'
    try {
        $deviceArgs = @{
            Method = 'Post'
            Uri = "$GitLabUrl/oauth/authorize_device"
            Body = @{ client_id = $GitLabClientId; scope = $GitLabScopes }
            ContentType = 'application/x-www-form-urlencoded'
        }
        Add-ProxyArgs $deviceArgs
        $resp = Invoke-RestMethod @deviceArgs
    } catch {
        return $false
    }

    if (-not $resp.device_code) { return $false }

    $interval = 5
    if ($resp.interval) { $interval = [int]$resp.interval }
    Write-Info ''
    Write-Info "  Open:        $($resp.verification_uri)"
    Write-Info "  You will need this code in the browser: $($resp.user_code)"
    Write-Info ''
    if ($env:ONE_AUTH_SKIP_BROWSER_PROMPT -ne '1') {
        try {
            [void](Read-Host 'Press Enter to open GitLab in your browser')
        } catch {
            <# best-effort for non-interactive hosts #>
        }
    }
    try {
        Start-Process $resp.verification_uri | Out-Null
    } catch {
        <# best-effort #>
    }
    Write-Info 'Waiting for authorization...'

    $deadline = (Get-Date).AddSeconds($DeviceFlowTimeoutSec)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $interval
        try {
            $tokenArgs = @{
                Method = 'Post'
                Uri = "$GitLabUrl/oauth/token"
                Body = @{
                    client_id = $GitLabClientId
                    device_code = $resp.device_code
                    grant_type = 'urn:ietf:params:oauth:grant-type:device_code'
                }
                ContentType = 'application/x-www-form-urlencoded'
            }
            Add-ProxyArgs $tokenArgs
            $tok = Invoke-RestMethod @tokenArgs
        } catch {
            $tok = $null
            if ($_.Exception.Response) {
                try {
                    $stream = $_.Exception.Response.GetResponseStream()
                    $reader = New-Object System.IO.StreamReader($stream)
                    $body = $reader.ReadToEnd()
                    $tok = $body | ConvertFrom-Json
                } catch {
                    $tok = $null
                }
            }
        }

        if ($tok -and $tok.access_token) {
            $script:accessToken = $tok.access_token
            $script:tokenResponse = $tok
            return $true
        }

        if ($tok -and $tok.error) {
            switch ($tok.error) {
                'authorization_pending' { continue }
                'slow_down' { $interval += 5; continue }
                'access_denied' { Write-Err "Authorization access_denied." }
                'expired_token' { Write-Err "Authorization expired_token." }
                default { continue }
            }
        }
    }

    Write-Err "Device flow timed out after $([int]($DeviceFlowTimeoutSec / 60)) minutes."
}

function Read-PatPrompt {
    Write-Warn2 'Device flow unavailable - falling back to Personal Access Token.'
    Write-Info "Create a PAT with scope read_api at:"
    Write-Info "  $GitLabUrl/-/user_settings/personal_access_tokens"
    $secure = Read-Host -AsSecureString 'Paste token'
    $plain = [System.Net.NetworkCredential]::new('', $secure).Password
    if (-not $plain) { Write-Err 'Empty token.' }
    $script:accessToken = $plain
}

# --- web mode: platform + auth + download ---
function Resolve-WebTarball {
    $arch = $env:PROCESSOR_ARCHITECTURE
    if ($env:PROCESSOR_ARCHITEW6432) { $arch = $env:PROCESSOR_ARCHITEW6432 }
    $archUpper = $arch.ToUpperInvariant()
    $target = $null
    if ($archUpper -eq 'ARM64') { $target = 'win32-arm64' }
    if ($archUpper -eq 'AMD64') { $target = 'win32-x64' }
    if ($archUpper -eq 'X86') { $target = 'win32-x64' } # 32-bit process on 64-bit Windows uses x64 package.
    if (-not $target) { Write-Err "Unsupported arch: $arch" }

    Write-Info "Installing one-cli ($target)"

    if ($Token) {
        $script:accessToken = $Token
    }
    if (-not $Token) {
        if (-not (Invoke-DeviceFlow)) {
            Read-PatPrompt
        }
    }

    Write-Info 'Fetching latest release...'
    $releasesUrl = "$GitLabUrl/api/v4/projects/$GitLabProjectId/releases?per_page=1"
    $release = $null
    $releaseArgs = @{
        Headers = @{ Authorization = "Bearer $script:accessToken" }
        Uri = $releasesUrl
    }
    Add-ProxyArgs $releaseArgs
    $releases = Invoke-RestMethod @releaseArgs
    if ($releases -and $releases.Count -gt 0) {
        $release = $releases[0]
    }

    if (-not $release) { Write-Err "Could not resolve a release object from $releasesUrl." }
    $tag = $release.tag_name
    if (-not $tag) { Write-Err 'Release response missing tag_name.' }

    $suffix = "$target.tar.gz"
    $link = $release.assets.links | Where-Object { $_.name.EndsWith($suffix) } | Select-Object -First 1
    if (-not $link) { Write-Err "No tarball for $target in release $tag" }

    $tmp = New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) ("one-install-" + [Guid]::NewGuid().ToString('N')))
    $downloadedTarball = Join-Path $tmp 'pkg.tar.gz'
    Write-Info "Downloading $tag ($target)..."
    $downloadArgs = @{
        Headers = @{ Authorization = "Bearer $script:accessToken" }
        Uri = $link.url
        OutFile = $downloadedTarball
        UseBasicParsing = $true
    }
    Add-ProxyArgs $downloadArgs
    Invoke-WebRequest @downloadArgs
    [pscustomobject]@{
        Tarball = $downloadedTarball
        DownloadedTarball = $downloadedTarball
        Tag = $tag
    }
}

if ($mode -eq 'web') {
    $webPackage = Resolve-WebTarball
    $Tarball = $webPackage.Tarball
    $downloadedTarball = $webPackage.DownloadedTarball
    $tag = $webPackage.Tag
}
if ($mode -ne 'web') {
    Write-Info "Installing one-cli (from $(Split-Path $Tarball -Leaf))"
}

# --- extract + move into place ---
$extractDir = New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) ("one-extract-" + [Guid]::NewGuid().ToString('N')))

    Write-Info 'Extracting...'
    # Skip node_modules/.bin/* - those are Unix-style symlinks produced on the
    # Linux CI runner. Windows tar cannot create them without Developer Mode /
    # admin, and the CLI does not need them at runtime (bin\one.cmd invokes
    # node on dist/index.js directly).
    & tar -xzf $Tarball -C $extractDir --exclude='*/node_modules/.bin/*'
    if ($LASTEXITCODE -ne 0) { Write-Err "tar failed with exit code $LASTEXITCODE" }

    $extracted = Get-ChildItem -Path $extractDir -Directory | Where-Object { $_.Name -like 'one*' } | Select-Object -First 1
    if (-not $extracted) { Write-Err "Unexpected archive structure - no 'one*' directory found." }

    if (Test-Path $InstallDir) {
        Write-Info "Removing previous installation at $InstallDir..."
        Remove-Item -Recurse -Force $InstallDir
    }
    Write-Info "Installing to $InstallDir..."
    $parent = Split-Path $InstallDir -Parent
    if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Move-Item -Path $extracted.FullName -Destination $InstallDir

    # --- shim on PATH ---
    $oneLauncher = Join-Path $InstallDir 'bin\one.cmd'
    if (-not (Test-Path $oneLauncher)) {
        # Some oclif tarball shapes ship bin\one only - synthesize a .cmd launcher
        $oneLauncher = Join-Path $InstallDir 'bin\one'
        if (-not (Test-Path $oneLauncher)) { Write-Err "Installed archive is missing bin\one.cmd or bin\one" }
    }

    if (-not (Test-Path $BinDir)) { New-Item -ItemType Directory -Path $BinDir -Force | Out-Null }
    $shimPath = Join-Path $BinDir 'one.cmd'
    $shimBody = "@echo off`r`n`"$oneLauncher`" %*`r`n"
    if (Test-Path $shimPath) { Set-ItemProperty -Path $shimPath -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue }
    [System.IO.File]::WriteAllText($shimPath, $shimBody, (New-Object System.Text.UTF8Encoding($false)))
    Write-Ok "Created Windows shim -> $shimPath"

    try {
        $oneLauncherUnix = ($oneLauncher -replace '\\', '/') -replace "'", "'\''"
        if ($oneLauncher -like '*.cmd') {
            $execCmd = "'$oneLauncherUnix'"
        } else {
            $execCmd = "node '$oneLauncherUnix'"
        }
        $shShimBody = (@(
            '#!/bin/sh'
            "if grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then"
            '  echo "WSL detected - please install the Linux version." >&2'
            '  exit 1'
            'fi'
            "exec $execCmd `"`$@`""
        ) -join "`n") + "`n"

        $shShimPath = Join-Path $BinDir 'one'
        # Clear read-only from a prior install so the overwrite doesn't fail.
        if (Test-Path $shShimPath) { Set-ItemProperty -Path $shShimPath -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue }
        [System.IO.File]::WriteAllText($shShimPath, $shShimBody, (New-Object System.Text.UTF8Encoding($false)))
        Write-Ok "Created Unix shim -> $shShimPath"
    } catch {
        Write-Warn2 "Could not create the Unix-style 'one' shim (Git Bash/MSYS2/WSL): $($_.Exception.Message). The Windows 'one.cmd' shim still works."
    }

    # --- PATH ---
    # Persist BinDir to the user PATH, but only when it isn't already reachable.
    # We check both the persisted user PATH and the live session PATH so we don't
    # add a redundant copy when the user already exposes BinDir another way (e.g.
    # an `$env:PATH += ...` line in their PowerShell profile), which would
    # otherwise surface as a duplicate entry on every new shell.
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $persistedEntries = @()
    if ($userPath) { $persistedEntries = $userPath -split ';' | Where-Object { $_ } }
    $sessionEntries = @()
    if ($env:Path) { $sessionEntries = $env:Path -split ';' | Where-Object { $_ } }
    $alreadyOnPath = ($persistedEntries -contains $BinDir) -or ($sessionEntries -contains $BinDir)
    if (-not $alreadyOnPath) {
        if ($userPath) {
            $newPath = "$userPath;$BinDir"
        } else {
            $newPath = $BinDir
        }
        [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
        Write-Warn2 "Added $BinDir to your user PATH. Open a new terminal for the change to take effect."
    }

    # --- prime telemetry token (web mode; best-effort, never aborts install) ---
    # Fetch the OTLP bearer token from the GitLab package registry and cache it
    # so the CLI has a ready token from run #1. The token is stored in Windows
    # Credential Manager under the same target as other CLI credentials.
    # Creates the data directory regardless of whether the keychain write
    # succeeds - the CLI fetches the token lazily on first use if needed.
    if ($mode -eq 'web' -and $script:accessToken) {
        try {
            $telemetryTokenUrl = "$GitLabUrl/api/v4/projects/$GitLabProjectId/packages/generic/telemetry/current/otlp-token-prod"
            $telemetryArgs = @{
                Headers = @{ Authorization = "Bearer $script:accessToken" }
                Uri = $telemetryTokenUrl
            }
            Add-ProxyArgs $telemetryArgs
            $telemetryToken = (Invoke-RestMethod @telemetryArgs).Trim()

            if ($telemetryToken) {
                try {
                    # Store in Windows Credential Manager so the CLI keychain layer can read it.
                    # cmdkey /generic stores a generic credential; the CLI reads this via the
                    # CredentialManager PowerShell module using the same target name format.
                    $credTarget = "de.telekom.one:telemetry-prod"
                    & cmdkey /generic:$credTarget /user:telemetry-prod /pass:$telemetryToken 2>$null | Out-Null
                } catch {
                    <# best-effort #>
                }
            }
        } catch {
            <# best-effort - relay not yet populated or network unavailable #>
        }
    }

    # Create the data dir so the CLI finds it on first use.
    try {
        New-Item -ItemType Directory -Path $OneDataDir -Force | Out-Null
    } catch {
        <# best-effort #>
    }

    Write-Info ''
    if ($mode -eq 'web') {
        Write-Ok "Installed one $tag -> $shimPath"
    } else {
        Write-Ok "Installed one -> $shimPath"
    }
    if ($script:tokenResponse) {
        Write-Info 'Run `one auth login` once to save credentials to Credential Manager, then try `one --help`.'
    } else {
        Write-Info "Run `one auth login` (if you haven't), then try `one --help`."
    }
if (Test-Path $extractDir) { Remove-Item -Recurse -Force $extractDir -ErrorAction SilentlyContinue }
if ($downloadedTarball -and (Test-Path (Split-Path $downloadedTarball -Parent))) {
    Remove-Item -Recurse -Force (Split-Path $downloadedTarball -Parent) -ErrorAction SilentlyContinue
}
$ErrorActionPreference = $PreviousErrorActionPreference
