# AGENTS.md

Scope: this file applies to the entire repository.

## Repository purpose

This repository publishes the public installer scripts for the `one` CLI:

- `install.sh`: macOS/Linux installer for `curl | bash` web installs and local tarball installs.
- `install.ps1`: Windows PowerShell installer for `irm | iex` web installs and local tarball installs.
- `test/`: Node.js built-in test suite with hermetic fake tarballs and stubbed network/keychain commands.
- `.github/workflows/test.yml`: CI matrix for Ubuntu, macOS, and Windows using Node.js 24.
- `README.md`: user-facing install commands, requirements, proxy notes, and test instructions.
- `package.json`: no runtime dependencies; `npm test` runs `node --test`; Node.js >= 24 is required.

There is no build step, generated source, package lockfile, or application code in this repo. The installer scripts are the product.

## Installer behavior to preserve

Both installers support two modes:

- Web mode: authenticate to Telekom GitLab, resolve the latest platform-specific release tarball, download it, extract it, install it, and prepare command lookup.
- Local mode: install from a provided `one-*.tar.gz` without authentication or network access.

Important defaults and overrides:

- Unix install dir: `${HOME}/.one`; Unix bin dir: `${HOME}/.local/bin`.
- Windows install dir: `%USERPROFILE%\.one`; Windows bin dir: `%USERPROFILE%\.local\bin`.
- `ONE_INSTALL_DIR`, `ONE_BIN_DIR`, `ONE_DATA_DIR`, and `ONE_TOKEN` override defaults where supported.
- PowerShell also accepts `-Tarball`, `-InstallDir`, `-BinDir`, and `-Token`.
- Node.js >= 24, `tar`, and platform download tools are hard requirements.

External release contract:

- Release tarballs must contain one top-level directory whose name starts with `one`.
- Unix archives must contain `bin/one`.
- Windows archives should contain `bin/one.cmd`; `install.ps1` can fall back to `bin/one`.
- Asset names must end with the platform suffix used by each installer, such as `linux-x64.tar.gz`, `darwin-arm64.tar.gz`, `win32-x64.tar.gz`, or `win32-arm64.tar.gz`.

## Design decisions and caveats

- Keep `install.sh` executable and Bash-specific. It intentionally uses `set -euo pipefail` plus explicit best-effort guards.
- Keep `install.ps1` CRLF-terminated. Tests assert consistent CRLF line endings.
- Keep generated Windows shim files BOM-free. Tests assert `UTF8Encoding($false)`.
- Do not run `exit` from `install.ps1` error paths. It is designed for `irm | iex`; helper failures should throw into the trap and return without closing the caller's shell.
- Do not read interactive prompts from stdin in `install.sh`. In `curl | bash` mode stdin is the script; prompt reads must use `/dev/tty` when needed.
- Browser launch during device flow is best-effort. Always print the URL and user code so headless, WSL, and locked-down environments still work.
- Personal Access Token fallback must not echo secrets. Do not log tokens, OAuth responses, telemetry tokens, Authorization headers, or Credential Manager/keychain payloads.
- Bash web mode saves OAuth credentials only when the GitLab device flow returns token JSON. PAT mode downloads only; users still need `one auth login`.
- Windows web mode downloads with device/PAT auth and then tells users to run `one auth login`; do not claim OAuth credentials are saved on Windows unless that is implemented and tested.
- Telemetry token priming is strictly best-effort. A missing relay, failed keychain, unavailable `secret-tool`, or `cmdkey` failure must never abort installation.
- The data directory must be created even when telemetry/keychain priming fails.
- Unix PATH setup is intentionally conservative: write bash/zsh rc files idempotently, warn for fish/unknown unsupported syntax, and do nothing when `BIN_DIR` is already on `PATH`.
- Windows PATH setup checks both persisted user PATH and the live session PATH to avoid duplicate `%USERPROFILE%\.local\bin` entries.
- The Windows POSIX-style `one` shim is for Git Bash/MSYS2-like shells and must reject WSL with a clear message; WSL users should install the Linux version.
- PowerShell extraction excludes `node_modules/.bin/*` because Windows tar cannot reliably create Unix symlinks without Developer Mode/admin rights and the CLI does not need those entries at runtime.
- PowerShell internal GitLab web requests must pass through `Add-ProxyArgs` so corporate `HTTPS_PROXY` settings and default credentials are honored.
- Removed telemetry marker files such as `telemetry-notice-shown` and `telemetry-token-check` must not be reintroduced.

## Common failure modes to avoid

- Do not convert `install.ps1` to LF endings or write BOM-prefixed shims.
- Do not add network calls to tests. Tests should use fake tarballs, fake release JSON, and stub commands.
- Do not make telemetry/keychain setup mandatory for a successful install.
- Do not change GitLab API endpoints, OAuth scopes, project id, client id, keychain service/account names, or asset suffixes without updating tests and documenting the release-side impact.
- Do not create duplicate PATH entries or append PATH lines repeatedly across reruns.
- Do not assume Linux desktops have a running Secret Service. `secret-tool` can exist and still fail.
- Do not assume `xdg-open`, `open`, `wslview`, or `Start-Process` succeeds.
- Do not let local mode invoke auth or network tools.
- Do not break piped-script invocation: `bash -s -- ...` and `irm | iex` are first-class paths.
- Do not add dependencies casually; the repo is intentionally dependency-light and the installer itself must remain standalone.

## Testing expectations

Run before opening a PR:

```sh
npm test
```

CI runs the same command on Ubuntu, macOS, and Windows with Node.js 24. On non-Windows hosts, the Windows local-install e2e test is skipped but static PowerShell safety tests still run. On Windows, Bash installer tests are skipped.

Add or update tests when changing:

- release lookup, asset naming, platform detection, or archive layout expectations;
- PATH mutation behavior;
- proxy propagation;
- shim generation;
- line endings or encoding behavior;
- telemetry/keychain/data-dir behavior;
- local vs web mode boundaries;
- user-facing install requirements in `README.md`.

For shell-only changes, at minimum keep or add syntax/static coverage. Prefer hermetic tests over tests that depend on live GitLab, local keychains, user PATH, or machine-global state.

## PR workflow for code changes

1. Start from an up-to-date `main` branch and create a focused branch.
2. Keep changes small and platform-aware. If changing one installer, check whether the other installer and README need matching updates.
3. Preserve file modes and encodings: `install.sh` executable, `install.ps1` CRLF, generated Windows shims BOM-free.
4. Update tests with the behavior change, then run `npm test`.
5. Review the diff for accidental secret exposure, endpoint churn, line-ending churn, broad formatting noise, and unrelated edits.
6. Commit with a short conventional-style message used in this repo, e.g. `fix: ...`, `feat: ...`, `test: ...`, or `docs: ...`.
7. Open a GitHub PR against `main`.

PR body should include:

- Summary: what changed and which platform(s) are affected.
- Test plan: exact commands run, plus any platform coverage gap such as "Windows e2e not run locally; covered by CI".
- Compatibility notes: any user-facing change to install commands, requirements, release asset naming, PATH behavior, proxy handling, auth, keychain, or telemetry.

Do not merge until the full GitHub Actions matrix is green or any failing platform is understood and explicitly documented.
