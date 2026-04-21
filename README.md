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

Behind a corporate proxy, use the proxy-aware variant:

```powershell
$u = 'https://raw.githubusercontent.com/telekom/onecli-installer/main/install.ps1'
$a = @{ Uri = $u }
if ($env:HTTPS_PROXY) { $a.Proxy = $env:HTTPS_PROXY; $a.ProxyUseDefaultCredentials = $true }
iex (irm @a)
```

Requires Node.js ≥ 24 and Windows 10 1803+ (for the built-in `tar`).

## License

MIT
