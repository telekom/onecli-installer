#!/usr/bin/env bash
#
# Installer for the 'one' CLI (macOS / Linux).
#
# Two modes:
#   1. Web install (curl | bash):
#        curl -fsSL https://raw.githubusercontent.com/telekom/onecli-installer/main/install.sh | bash
#      Authenticates against GitLab via OAuth 2.0 device flow (falls back
#      to a PAT prompt), downloads the latest platform-specific release,
#      installs it, and seeds the OS keychain so `one auth login` is not
#      needed on first use.
#
#   2. Local install from a downloaded tarball:
#        bash install.sh one-1.17.1-darwin-arm64.tar.gz
#      Skips auth and networking; just extracts and symlinks.
#
# For Windows, use install.ps1 (same repo).

set -euo pipefail

# --- constants ---
GITLAB_URL="https://gitlab.devops.telekom.de"
GITLAB_PROJECT_ID="452386"
GITLAB_CLIENT_ID="cc421c2bb511f08109854cd7f93de401909fc8228999a20394cd8634a6266928"
GITLAB_SCOPES="api openid read_user"
KEYCHAIN_SERVICE="de.telekom.one"
KEYCHAIN_ACCOUNT="oauth"
NODE_MIN_MAJOR=24
DEVICE_FLOW_TIMEOUT_S=900

# --- defaults (overridable via flags / env) ---
INSTALL_DIR="${ONE_INSTALL_DIR:-${HOME}/.one}"
BIN_DIR="${ONE_BIN_DIR:-${HOME}/.local/bin}"
TARBALL=""

# --- arg parsing (preserves the previous script's flags) ---
while [ $# -gt 0 ]; do
  case "$1" in
    --install-dir) INSTALL_DIR="$2"; shift 2 ;;
    --bin-dir)     BIN_DIR="$2";     shift 2 ;;
    -h|--help)
      cat <<EOF
Usage:
  curl -fsSL <url>/install.sh | bash           # web install
  bash install.sh [TARBALL] [OPTIONS]          # local install

Arguments:
  TARBALL                 Path to a one-*.tar.gz; if omitted, installer
                          authenticates and downloads the latest release.

Options:
  --install-dir DIR       Install location (default: ~/.one)
  --bin-dir DIR           Symlink location (default: ~/.local/bin)
  -h, --help              Show this help

Environment:
  ONE_INSTALL_DIR         Same as --install-dir
  ONE_BIN_DIR             Same as --bin-dir
  ONE_TOKEN               Skip interactive auth; use this GitLab token
                          (PAT or OAuth access token) for the download.
EOF
      exit 0
      ;;
    -*) echo "Unknown option: $1" >&2; exit 1 ;;
    *)  TARBALL="$1"; shift ;;
  esac
done
BIN_LINK="${BIN_DIR}/one"

# --- tty-safe reads (stdin is the script when invoked via curl | bash) ---
if [ -r /dev/tty ]; then TTY=/dev/tty; else TTY=/dev/null; fi

# --- colors ---
if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "${TERM:-dumb}" != "dumb" ]; then
  BOLD=$(tput bold); DIM=$(tput dim); GREEN=$(tput setaf 2)
  RED=$(tput setaf 1); YELLOW=$(tput setaf 3); RESET=$(tput sgr0)
else
  BOLD=""; DIM=""; GREEN=""; RED=""; YELLOW=""; RESET=""
fi
info() { printf '%s\n' "$*"; }
ok()   { printf '%s✓%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%s!%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
err()  { printf '%s✗%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

# --- preflight ---
command -v curl >/dev/null 2>&1 || err "curl is required"
command -v tar  >/dev/null 2>&1 || err "tar is required"
command -v node >/dev/null 2>&1 || err "Node.js >= ${NODE_MIN_MAJOR} is required. Install from https://nodejs.org"
NODE_MAJOR=$(node -e 'process.stdout.write(process.versions.node.split(".")[0])')
[ "${NODE_MAJOR}" -ge "${NODE_MIN_MAJOR}" ] || err "Node.js >= ${NODE_MIN_MAJOR} required (found ${NODE_MAJOR})"

# --- JSON helper (reads JSON from stdin, prints value at dotted path; exit 1 if missing) ---
json_get() {
  node -e '
    let d = ""; process.stdin.on("data", c => d += c);
    process.stdin.on("end", () => {
      let cur;
      try { cur = JSON.parse(d) } catch { process.exit(2) }
      for (const k of process.argv[1].split(".")) {
        if (cur == null) break;
        cur = cur[k];
      }
      if (cur == null) process.exit(1);
      process.stdout.write(typeof cur === "string" ? cur : JSON.stringify(cur));
    });
  ' "$1"
}

open_url() {
  if   command -v open     >/dev/null 2>&1; then open     "$1" >/dev/null 2>&1 || true
  elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$1" >/dev/null 2>&1 || true
  fi
}

# --- mode detection ---
if [ -n "$TARBALL" ]; then
  MODE="local"
  [ -f "$TARBALL" ] || err "File not found: $TARBALL"
else
  MODE="web"
fi

# --- web mode: platform detection + auth + download ---
ACCESS_TOKEN=""
TOKEN_JSON=""
DOWNLOADED_TARBALL=""

auth_device_flow() {
  info "Authenticating via GitLab device flow..."
  local resp http_code
  resp=$(curl -sS -w '\n%{http_code}' -X POST "${GITLAB_URL}/oauth/authorize_device" \
    --data-urlencode "client_id=${GITLAB_CLIENT_ID}" \
    --data-urlencode "scope=${GITLAB_SCOPES}" 2>/dev/null || true)
  http_code=$(printf '%s' "$resp" | tail -n1)
  resp=$(printf '%s' "$resp" | sed '$d')
  case "$http_code" in 200|201) ;; *) return 1 ;; esac

  local device_code user_code verification_uri interval deadline
  device_code=$(printf '%s'      "$resp" | json_get device_code)       || return 1
  user_code=$(printf '%s'        "$resp" | json_get user_code)         || return 1
  verification_uri=$(printf '%s' "$resp" | json_get verification_uri)  || return 1
  interval=$(printf '%s'         "$resp" | json_get interval 2>/dev/null || echo 5)

  info ""
  info "  Open:        ${BOLD}${verification_uri}${RESET}"
  info "  Enter code:  ${BOLD}${user_code}${RESET}"
  info ""
  open_url "$verification_uri"
  info "Waiting for authorization..."

  deadline=$(( $(date +%s) + DEVICE_FLOW_TIMEOUT_S ))
  local tok err_code
  while [ "$(date +%s)" -lt "$deadline" ]; do
    sleep "$interval"
    tok=$(curl -sS -X POST "${GITLAB_URL}/oauth/token" \
      --data-urlencode "client_id=${GITLAB_CLIENT_ID}" \
      --data-urlencode "device_code=${device_code}" \
      --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:device_code" 2>/dev/null || echo "")
    err_code=$(printf '%s' "$tok" | json_get error 2>/dev/null || true)
    if [ -z "$err_code" ]; then
      ACCESS_TOKEN=$(printf '%s' "$tok" | json_get access_token 2>/dev/null || true)
      if [ -n "$ACCESS_TOKEN" ]; then TOKEN_JSON="$tok"; return 0; fi
    fi
    case "$err_code" in
      authorization_pending) : ;;
      slow_down)             interval=$((interval + 5)) ;;
      access_denied|expired_token) err "Authorization ${err_code}." ;;
      *) : ;;
    esac
  done
  err "Device flow timed out after $((DEVICE_FLOW_TIMEOUT_S / 60)) minutes."
}

auth_pat_prompt() {
  warn "Device flow unavailable — falling back to Personal Access Token."
  info "Create a PAT with scope ${BOLD}read_api${RESET} at:"
  info "  ${GITLAB_URL}/-/user_settings/personal_access_tokens"
  printf "Paste token: " >&2
  IFS= read -rs PAT < "$TTY"
  printf "\n" >&2
  [ -n "${PAT:-}" ] || err "Empty token."
  ACCESS_TOKEN="$PAT"
}

if [ "$MODE" = "web" ]; then
  case "$(uname -s)" in
    Darwin) PLATFORM="darwin" ;;
    Linux)  PLATFORM="linux"  ;;
    *)      err "Unsupported OS: $(uname -s)" ;;
  esac
  case "$(uname -m)" in
    arm64|aarch64) ARCH="arm64" ;;
    x86_64|amd64)  ARCH="x64"   ;;
    *)             err "Unsupported arch: $(uname -m)" ;;
  esac
  TARGET="${PLATFORM}-${ARCH}"
  info "${BOLD}Installing one-cli${RESET} ${DIM}(${TARGET})${RESET}"

  if [ -n "${ONE_TOKEN:-}" ]; then
    ACCESS_TOKEN="$ONE_TOKEN"
  elif ! auth_device_flow; then
    auth_pat_prompt
  fi

  info "Fetching latest release..."
  RELEASE=$(curl -fsSL -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    "${GITLAB_URL}/api/v4/projects/${GITLAB_PROJECT_ID}/releases/permalink/latest") \
    || err "Failed to fetch release — ensure the token has read_api scope."
  TAG=$(printf '%s' "$RELEASE" | json_get tag_name) || err "Release response missing tag_name."

  ASSET_URL=$(printf '%s' "$RELEASE" | node -e '
    let d = ""; process.stdin.on("data", c => d += c);
    process.stdin.on("end", () => {
      const r = JSON.parse(d);
      const suffix = process.argv[1] + ".tar.gz";
      const link = (r.assets && r.assets.links || []).find(l => l.name.endsWith(suffix));
      if (!link) process.exit(1);
      process.stdout.write(link.url);
    });
  ' "$TARGET") || err "No tarball for ${TARGET} in release ${TAG}"

  TMP_DOWNLOAD=$(mktemp -d)
  trap 'rm -rf "$TMP_DOWNLOAD"' EXIT
  DOWNLOADED_TARBALL="${TMP_DOWNLOAD}/pkg.tar.gz"
  info "Downloading ${TAG} ${DIM}(${TARGET})${RESET}..."
  curl -fsSL -H "Authorization: Bearer ${ACCESS_TOKEN}" -o "$DOWNLOADED_TARBALL" "$ASSET_URL"
  TARBALL="$DOWNLOADED_TARBALL"
else
  info "${BOLD}Installing one-cli${RESET} ${DIM}(from $(basename "$TARBALL"))${RESET}"
fi

# --- extract + move into place ---
TMP_EXTRACT=$(mktemp -d)
# Preserve download temp-dir cleanup if it exists
if [ -n "${TMP_DOWNLOAD:-}" ]; then
  trap 'rm -rf "$TMP_DOWNLOAD" "$TMP_EXTRACT"' EXIT
else
  trap 'rm -rf "$TMP_EXTRACT"' EXIT
fi

info "Extracting..."
tar -xzf "$TARBALL" -C "$TMP_EXTRACT"

EXTRACTED_DIR=$(find "$TMP_EXTRACT" -maxdepth 1 -mindepth 1 -type d -name 'one*' | head -n1)
[ -n "$EXTRACTED_DIR" ] && [ -d "$EXTRACTED_DIR" ] || err "Unexpected archive structure — no 'one*' directory found."

if [ -d "$INSTALL_DIR" ]; then
  info "Removing previous installation at ${INSTALL_DIR}..."
  rm -rf "$INSTALL_DIR"
fi
info "Installing to ${INSTALL_DIR}..."
mkdir -p "$(dirname "$INSTALL_DIR")"
mv "$EXTRACTED_DIR" "$INSTALL_DIR"

# --- symlink ---
BIN_PATH="${INSTALL_DIR}/bin/one"
[ -f "$BIN_PATH" ] || err "Installed archive is missing ${BIN_PATH}"
chmod +x "$BIN_PATH"
mkdir -p "$BIN_DIR"
ln -sf "$BIN_PATH" "$BIN_LINK"

# --- seed keychain (web mode + OAuth token only; a PAT has no refresh_token) ---
if [ -n "$TOKEN_JSON" ]; then
  info "Saving credentials to OS keychain..."
  AUTH_CONFIG=$(printf '%s' "$TOKEN_JSON" | node -e '
    let d = ""; process.stdin.on("data", c => d += c);
    process.stdin.on("end", () => {
      const t = JSON.parse(d);
      process.stdout.write(JSON.stringify({
        oauth: {
          accessToken:  t.access_token,
          refreshToken: t.refresh_token,
          createdAt:    t.created_at,
          expiresIn:    t.expires_in,
          tokenType:    "Bearer",
        },
      }));
    });
  ')
  case "$(uname -s)" in
    Darwin)
      security add-generic-password \
        -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" -w "$AUTH_CONFIG" -U >/dev/null
      ;;
    Linux)
      if command -v secret-tool >/dev/null 2>&1; then
        printf '%s' "$AUTH_CONFIG" | secret-tool store \
          --label "${KEYCHAIN_SERVICE} - ${KEYCHAIN_ACCOUNT}" \
          service "$KEYCHAIN_SERVICE" account "$KEYCHAIN_ACCOUNT"
      else
        warn "secret-tool (libsecret) not found — run 'one auth login' once to save credentials."
      fi
      ;;
  esac
fi

# --- PATH hint ---
case ":${PATH}:" in
  *:"${BIN_DIR}":*) ;;
  *)
    case "$(basename "${SHELL:-bash}")" in
      zsh)  RCFILE="~/.zshrc" ;;
      bash) RCFILE="~/.bashrc (or ~/.bash_profile on macOS)" ;;
      fish) RCFILE="~/.config/fish/config.fish" ;;
      *)    RCFILE="your shell rc file" ;;
    esac
    warn "${BIN_DIR} is not on your PATH."
    info "Add this to ${RCFILE}:"
    info "  ${BOLD}export PATH=\"${BIN_DIR}:\$PATH\"${RESET}"
    ;;
esac

info ""
if [ "$MODE" = "web" ]; then
  ok "Installed one ${TAG} → ${BIN_LINK}"
  if [ -n "$TOKEN_JSON" ]; then
    info "You're already authenticated. Try: ${BOLD}one --help${RESET}"
  else
    info "Run ${BOLD}one auth login${RESET} next, then try ${BOLD}one --help${RESET}."
  fi
else
  ok "Installed one → ${BIN_LINK}"
  info "Run ${BOLD}one auth login${RESET} (if you haven't), then try ${BOLD}one --help${RESET}."
fi
