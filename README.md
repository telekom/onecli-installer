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
iwr -useb https://raw.githubusercontent.com/telekom/onecli-installer/main/install.ps1 | iex
```

Requires Node.js ≥ 24 and Windows 10 1803+ (for the built-in `tar`).

## License

MIT
