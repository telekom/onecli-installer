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
#>
[CmdletBinding()]
param(
    [string]$Tarball,
    [string]$InstallDir = (Join-Path $env:USERPROFILE '.one'),
    [string]$BinDir = (Join-Path $env:USERPROFILE '.local\bin'),
    [string]$Token
)

# Everything runs inside a script block + try/catch so that:
#   - `throw` from helpers unwinds the block (below) instead of calling `exit`,
#     which would close the caller's shell when invoked via `irm | iex`.
#   - $ErrorActionPreference changes don't leak into the user's session.
try {
& {
$ErrorActionPreference = 'Stop'

# --- proxy splat: forwarded to every internal Invoke-RestMethod /
# Invoke-WebRequest call so corporate proxies that require explicit
# credentials are happy. No-op when HTTPS_PROXY isn't set.
$ProxyArgs = @{}
if ($env:HTTPS_PROXY) {
    $ProxyArgs.Proxy = $env:HTTPS_PROXY
    $ProxyArgs.ProxyUseDefaultCredentials = $true
}

# --- constants ---
$GitLabUrl = 'https://gitlab.devops.telekom.de'
$GitLabProjectId = '452386'
$GitLabClientId = 'cc421c2bb511f08109854cd7f93de401909fc8228999a20394cd8634a6266928'
$GitLabScopes = 'api openid read_user'
$NodeMinMajor = 24
$DeviceFlowTimeoutSec = 900

if (-not $Token -and $env:ONE_TOKEN) { $Token = $env:ONE_TOKEN }
if ($env:ONE_INSTALL_DIR) { $InstallDir = $env:ONE_INSTALL_DIR }
if ($env:ONE_BIN_DIR) { $BinDir = $env:ONE_BIN_DIR }

# --- output helpers ---
function Write-Info($msg) { Write-Host $msg }
function Write-Ok($msg) { Write-Host "✓ $msg" -ForegroundColor Green }
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
$accessToken = $null
$tokenResponse = $null
$downloadedTarball = $null
$tag = $null

# --- auth: device flow ---
function Invoke-DeviceFlow {
    Write-Info 'Authenticating via GitLab device flow...'
    try {
        $resp = Invoke-RestMethod -Method Post -Uri "$GitLabUrl/oauth/authorize_device" `
            -Body @{ client_id = $GitLabClientId; scope = $GitLabScopes } `
            -ContentType 'application/x-www-form-urlencoded' @ProxyArgs
    } catch {
        return $false
    }

    if (-not $resp.device_code) { return $false }

    $interval = if ($resp.interval) { [int]$resp.interval } else { 5 }
    Write-Info ''
    Write-Info "  Open:        $($resp.verification_uri)"
    Write-Info "  Enter code:  $($resp.user_code)"
    Write-Info ''
    try { Start-Process $resp.verification_uri | Out-Null } catch { }
    Write-Info 'Waiting for authorization...'

    $deadline = (Get-Date).AddSeconds($DeviceFlowTimeoutSec)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $interval
        try {
            $tok = Invoke-RestMethod -Method Post -Uri "$GitLabUrl/oauth/token" `
                -Body @{
                    client_id   = $GitLabClientId
                    device_code = $resp.device_code
                    grant_type  = 'urn:ietf:params:oauth:grant-type:device_code'
                } `
                -ContentType 'application/x-www-form-urlencoded' @ProxyArgs
        } catch {
            $tok = $null
            if ($_.Exception.Response) {
                try {
                    $stream = $_.Exception.Response.GetResponseStream()
                    $reader = New-Object System.IO.StreamReader($stream)
                    $body = $reader.ReadToEnd()
                    $tok = $body | ConvertFrom-Json
                } catch { $tok = $null }
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
    Write-Warn2 'Device flow unavailable — falling back to Personal Access Token.'
    Write-Info "Create a PAT with scope read_api at:"
    Write-Info "  $GitLabUrl/-/user_settings/personal_access_tokens"
    $secure = Read-Host -AsSecureString 'Paste token'
    $plain = [System.Net.NetworkCredential]::new('', $secure).Password
    if (-not $plain) { Write-Err 'Empty token.' }
    $script:accessToken = $plain
}

# --- web mode: platform + auth + download ---
if ($mode -eq 'web') {
    $arch = $env:PROCESSOR_ARCHITECTURE
    if ($env:PROCESSOR_ARCHITEW6432) { $arch = $env:PROCESSOR_ARCHITEW6432 }
    switch ($arch.ToUpperInvariant()) {
        'ARM64' { $target = 'win32-arm64' }
        'AMD64' { $target = 'win32-x64' }
        'X86'   { $target = 'win32-x64' }  # 32-bit process on 64-bit Windows — use x64 package
        default { Write-Err "Unsupported arch: $arch" }
    }

    Write-Info "Installing one-cli ($target)"

    if ($Token) {
        $accessToken = $Token
    } elseif (-not (Invoke-DeviceFlow)) {
        Read-PatPrompt
    }

    Write-Info 'Fetching latest release...'
    # Manually follow the 302 from /releases/permalink/latest so the
    # Authorization header survives (PS 5.1's Invoke-RestMethod strips it
    # across redirects — -PreserveAuthorizationOnRedirect is PS 7.3+).
    $permalinkUrl = "$GitLabUrl/api/v4/projects/$GitLabProjectId/releases/permalink/latest"
    $release = $null
    try {
        $headers = @{ Authorization = "Bearer $accessToken" }
        $resp = Invoke-WebRequest -Headers $headers -Uri $permalinkUrl -MaximumRedirection 0 `
            -UseBasicParsing -ErrorAction Stop @ProxyArgs
        # Not a redirect — endpoint returned the release directly.
        $release = $resp.Content | ConvertFrom-Json
    } catch {
        $statusCode = 0
        $location = $null
        if ($_.Exception.Response) {
            try { $statusCode = [int]$_.Exception.Response.StatusCode } catch {}
            try { $location = $_.Exception.Response.Headers['Location'] } catch {}
        }

        if ($statusCode -in 301, 302, 303, 307, 308 -and $location) {
            if ($location -notmatch '^https?://') { $location = "$GitLabUrl$location" }
            try {
                $release = Invoke-RestMethod -Headers @{ Authorization = "Bearer $accessToken" } -Uri $location @ProxyArgs
            } catch {
                $rStatus = ''
                if ($_.Exception.Response) {
                    try { $rStatus = " [HTTP $([int]$_.Exception.Response.StatusCode)]" } catch {}
                }
                Write-Err "Failed to fetch release at $location$rStatus : $($_.Exception.Message)"
            }
        } else {
            $s = if ($statusCode) { " [HTTP $statusCode]" } else { '' }
            Write-Err "Failed to fetch latest release from $permalinkUrl$s : $($_.Exception.Message)"
        }
    }

    if (-not $release) { Write-Err "Could not resolve a release object from $permalinkUrl." }
    $tag = $release.tag_name
    if (-not $tag) { Write-Err 'Release response missing tag_name.' }

    $suffix = "$target.tar.gz"
    $link = $release.assets.links | Where-Object { $_.name.EndsWith($suffix) } | Select-Object -First 1
    if (-not $link) { Write-Err "No tarball for $target in release $tag" }

    $tmp = New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) ("one-install-" + [Guid]::NewGuid().ToString('N')))
    $downloadedTarball = Join-Path $tmp 'pkg.tar.gz'
    Write-Info "Downloading $tag ($target)..."
    try {
        Invoke-WebRequest -Headers @{ Authorization = "Bearer $accessToken" } `
            -Uri $link.url -OutFile $downloadedTarball -UseBasicParsing @ProxyArgs
    } catch {
        Write-Err "Download failed: $($_.Exception.Message)"
    }
    $Tarball = $downloadedTarball
} else {
    Write-Info "Installing one-cli (from $(Split-Path $Tarball -Leaf))"
}

# --- extract + move into place ---
$extractDir = New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) ("one-extract-" + [Guid]::NewGuid().ToString('N')))

try {
    Write-Info 'Extracting...'
    & tar -xzf $Tarball -C $extractDir
    if ($LASTEXITCODE -ne 0) { Write-Err "tar failed with exit code $LASTEXITCODE" }

    $extracted = Get-ChildItem -Path $extractDir -Directory | Where-Object { $_.Name -like 'one*' } | Select-Object -First 1
    if (-not $extracted) { Write-Err "Unexpected archive structure — no 'one*' directory found." }

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
        # Some oclif tarball shapes ship bin\one only — synthesize a .cmd launcher
        $oneLauncher = Join-Path $InstallDir 'bin\one'
        if (-not (Test-Path $oneLauncher)) { Write-Err "Installed archive is missing bin\one.cmd or bin\one" }
    }

    if (-not (Test-Path $BinDir)) { New-Item -ItemType Directory -Path $BinDir -Force | Out-Null }
    $shimPath = Join-Path $BinDir 'one.cmd'
    $shimBody = "@echo off`r`n`"$oneLauncher`" %*`r`n"
    Set-Content -Path $shimPath -Value $shimBody -Encoding ASCII -NoNewline

    # --- PATH ---
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $pathEntries = if ($userPath) { $userPath -split ';' } else { @() }
    if (-not ($pathEntries -contains $BinDir)) {
        $newPath = if ($userPath) { "$userPath;$BinDir" } else { $BinDir }
        [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
        Write-Warn2 "Added $BinDir to your user PATH. Open a new terminal for the change to take effect."
    }

    Write-Info ''
    if ($mode -eq 'web') {
        Write-Ok "Installed one $tag → $shimPath"
    } else {
        Write-Ok "Installed one → $shimPath"
    }
    if ($tokenResponse) {
        Write-Info 'Run `one auth login` once to save credentials to Credential Manager, then try `one --help`.'
    } else {
        Write-Info "Run `one auth login` (if you haven't), then try `one --help`."
    }
} finally {
    if (Test-Path $extractDir) { Remove-Item -Recurse -Force $extractDir -ErrorAction SilentlyContinue }
    if ($downloadedTarball -and (Test-Path (Split-Path $downloadedTarball -Parent))) {
        Remove-Item -Recurse -Force (Split-Path $downloadedTarball -Parent) -ErrorAction SilentlyContinue
    }
}
} # end of & { ... } installer block
} catch {
    # Pretty-print the error and keep the shell alive. When invoked via
    # `irm | iex` we cannot call `exit` — it would close the host.
    Write-Host "✗ $($_.Exception.Message)" -ForegroundColor Red
}
