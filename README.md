# OneCLI installer

Public installer scripts for the OneCLI command-line tool.

## Install

### macOS / Linux

```sh
curl -fsSL https://raw.githubusercontent.com/telekom/onecli-installer/main/install.sh | bash
```

Requires Node.js ≥ 24, `curl`, and `tar`.

### Windows

```powershell
irm https://raw.githubusercontent.com/telekom/onecli-installer/main/install.ps1 | iex
```

Behind the Telekom corporate proxy, set the proxy env vars first:

```powershell
$env:HTTPS_PROXY = 'http://sia-lb.telekom.de:8080'
$env:HTTP_PROXY = 'http://sia-lb.telekom.de:8080'

$u = 'https://raw.githubusercontent.com/telekom/onecli-installer/main/install.ps1'
$a = @{ Uri = $u }
if ($env:HTTPS_PROXY) { $a.Proxy = $env:HTTPS_PROXY; $a.ProxyUseDefaultCredentials = $true }
iex (irm @a)
```

The script forwards `$env:HTTPS_PROXY` to all internal GitLab API calls.

Requires Node.js ≥ 24 and Windows 10 1803+ (for the built-in `tar`).

## License

MIT
