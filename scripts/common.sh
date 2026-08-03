#!/usr/bin/env bash
# =============================================================================
# common.sh — shared functions for openclaw-hermes-deploy
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTROL_FILE="${REPO_ROOT}/control/active-host.json"
MANIFEST_FILE="${REPO_ROOT}/manifest.yaml"

# -----------------------------------------------------------------------------
# logging
# -----------------------------------------------------------------------------
log_info()  { echo "[INFO]  $(date -Iseconds) $*"; }
log_warn()  { echo "[WARN]  $(date -Iseconds) $*" >&2; }
log_error() { echo "[ERROR] $(date -Iseconds) $*" >&2; }
die()       { log_error "$@"; exit 1; }

# -----------------------------------------------------------------------------
# git helpers
# -----------------------------------------------------------------------------
require_clean_git() {
  if ! git diff-index --quiet HEAD -- 2>/dev/null; then
    die "Working tree is dirty — commit or stash changes before proceeding"
  fi
  git fetch origin 2>/dev/null || die "git fetch failed"
  local local_sha remote_sha
  local_sha=$(git rev-parse HEAD 2>/dev/null)
  remote_sha=$(git rev-parse @{u} 2>/dev/null)
  if [[ "$local_sha" != "$remote_sha" ]]; then
    die "Local branch is not in sync with remote — pull or push first"
  fi
}

require_fast_forward() {
  git fetch origin 2>/dev/null || die "git fetch failed"
  if ! git merge-base --is-ancestor HEAD @{u} 2>/dev/null; then
    die "Remote has diverged — non-fast-forward.  Manual resolution required."
  fi
}

# -----------------------------------------------------------------------------
# active-host control
# -----------------------------------------------------------------------------
read_control() {
  cat "$CONTROL_FILE"
}

get_control_field() {
  local field="$1"
  python3 -c "import sys,json; print(json.load(open('$CONTROL_FILE')).get('$field',''))"
}

write_control() {
  python3 -c "
import json, sys
data = json.load(open('$CONTROL_FILE'))
data.update($1)
with open('$CONTROL_FILE','w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write('\n')
"
}

require_host_active() {
  local status
  status=$(get_control_field status)
  if [[ "$status" != "active" ]]; then
    die "This host is not active (status: $status).  Only active hosts can run this operation."
  fi
}

require_host_switching() {
  local status
  status=$(get_control_field status)
  if [[ "$status" != "switching" ]]; then
    die "Control status is '$status', expected 'switching'"
  fi
}

verify_generation() {
  local expected="$1"
  local actual
  actual=$(get_control_field generation)
  if [[ "$actual" != "$expected" ]]; then
    die "Generation mismatch: expected $expected, got $actual"
  fi
}

# -----------------------------------------------------------------------------
# environment detection
# -----------------------------------------------------------------------------
is_wsl2() {
  grep -qi microsoft /proc/version 2>/dev/null || grep -qi wsl2 /proc/version 2>/dev/null
}

is_linux() {
  [[ "$(uname -s)" == "Linux" ]]
}

is_windows_native() {
  [[ "$(uname -s)" == MINGW* || "$(uname -s)" == MSYS* || "$(uname -s)" == CYGWIN* ]]
}

require_linux_or_wsl2() {
  if is_windows_native; then
    die "Windows native is not supported.  Please run inside WSL2."
  fi
  if ! is_linux && ! is_wsl2; then
    die "Unsupported platform: $(uname -s).  Linux or WSL2 required."
  fi
}

# -----------------------------------------------------------------------------
# dependency checks
# -----------------------------------------------------------------------------
check_dep() {
  local cmd="$1" pkg="${2:-$1}"
  if ! command -v "$cmd" &>/dev/null; then
    die "Missing dependency: $cmd (install: $pkg)"
  fi
}

require_deps() {
  check_dep git
  check_dep gh "github-cli"
  check_dep curl
  check_dep zstd
  check_dep python3  # sqlite3 via Python
  check_dep node
  check_dep python3
}

verify_node_version() {
  local expected="$1" actual
  actual=$(node --version | sed 's/^v//')
  if [[ "$actual" != "$expected" ]]; then
    die "Node.js version mismatch: expected $expected, got $actual"
  fi
  log_info "Node.js $actual OK"
}

verify_openclaw_version() {
  local expected="$1" actual
  actual=$(openclaw --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1)
  if [[ "$actual" != "$expected" ]]; then
    die "OpenClaw version mismatch: expected $expected, got $actual"
  fi
  log_info "OpenClaw $actual OK"
}

verify_hermes_version() {
  local expected="$1" actual
  actual=$(hermes --version 2>/dev/null | grep -oP 'v?\K\d+\.\d+\.\d+' | head -1)
  if [[ "$actual" != "$expected" ]]; then
    die "Hermes Agent version mismatch: expected $expected, got $actual"
  fi
  log_info "Hermes Agent $actual OK"
}

# -----------------------------------------------------------------------------
# gh auth check
# -----------------------------------------------------------------------------
require_gh_auth() {
  if ! gh auth status &>/dev/null; then
    die "GitHub CLI not authenticated.  Run: gh auth login"
  fi
  log_info "GitHub CLI authenticated OK"
}

# -----------------------------------------------------------------------------
# service management
# -----------------------------------------------------------------------------
OPENCLAW_GATEWAY_PID=""
HERMES_DEFAULT_PID=""
HERMES_CODER_PID=""
HERMES_MM_PID=""

record_running_gateways() {
  log_info "Recording running gateways…"
  OPENCLAW_GATEWAY_PID=$(pgrep -f "openclaw.*gateway" 2>/dev/null | head -1 || echo "")
  HERMES_DEFAULT_PID=$(pgrep -f "hermes.*gateway run" 2>/dev/null | head -1 || echo "")
  # For hermes profile gateways, match the profile argument
  HERMES_CODER_PID=$(pgrep -f "hermes.*coder.*gateway run" 2>/dev/null | head -1 || echo "")
  HERMES_MM_PID=$(pgrep -f "hermes.*money-maker.*gateway run" 2>/dev/null | head -1 || echo "")
  log_info "OpenClaw gateway PID: ${OPENCLAW_GATEWAY_PID:-none}"
  log_info "Hermes default gateway PID: ${HERMES_DEFAULT_PID:-none}"
  log_info "Hermes coder gateway PID: ${HERMES_CODER_PID:-none}"
  log_info "Hermes money-maker gateway PID: ${HERMES_MM_PID:-none}"
}

stop_openclaw_gateway() {
  log_info "Stopping OpenClaw gateway…"
  # Stop via CLI first, then mask systemd service to prevent auto-restart
  openclaw gateway stop 2>/dev/null || true
  systemctl --user mask openclaw-gateway.service 2>/dev/null || true
  systemctl --user stop openclaw-gateway.service 2>/dev/null || true
  # Wait for graceful shutdown
  for i in $(seq 1 30); do
    if ! pgrep -f "openclaw.*gateway" &>/dev/null; then
      log_info "OpenClaw gateway stopped"
      return 0
    fi
    sleep 1
  done
  log_warn "OpenClaw gateway did not stop gracefully — sending SIGTERM"
  pkill -TERM -f "openclaw.*gateway" 2>/dev/null || true
  sleep 2
  pkill -KILL -f "openclaw.*gateway" 2>/dev/null || true
}

unmask_openclaw_gateway() {
  systemctl --user unmask openclaw-gateway.service 2>/dev/null || true
}

stop_hermes_gateway() {
  local profile="${1:-default}"
  log_info "Stopping Hermes $profile gateway…"
  # Determine systemd service name
  local svc="hermes-gateway"
  if [[ "$profile" != "default" ]]; then
    svc="hermes-gateway-${profile}"
  fi
  # Stop via CLI first, then mask systemd service to prevent auto-restart
  if [[ "$profile" == "default" ]]; then
    hermes gateway stop 2>/dev/null || true
  else
    hermes --profile "$profile" gateway stop 2>/dev/null || true
  fi
  systemctl --user mask "${svc}.service" 2>/dev/null || true
  systemctl --user stop "${svc}.service" 2>/dev/null || true
  for i in $(seq 1 30); do
    if ! pgrep -f "hermes.*${profile}.*gateway" &>/dev/null; then
      log_info "Hermes $profile gateway stopped"
      return 0
    fi
    sleep 1
  done
  log_warn "Hermes $profile gateway did not stop gracefully"
  pkill -TERM -f "hermes.*${profile}.*gateway" 2>/dev/null || true
  sleep 2
  pkill -KILL -f "hermes.*${profile}.*gateway" 2>/dev/null || true
}

unmask_hermes_gateway() {
  local profile="${1:-default}"
  local svc="hermes-gateway"
  if [[ "$profile" != "default" ]]; then
    svc="hermes-gateway-${profile}"
  fi
  systemctl --user unmask "${svc}.service" 2>/dev/null || true
}

# Service names as actually installed on the system
GATEWAY_SERVICES=(
  openclaw-gateway
  hermes-gateway-default
  hermes-gateway-coder
  hermes-gateway-money-maker
)

stop_all_gateways() {
  log_info "Stopping all gateways…"
  # disable --now: stop AND prevent auto-restart
  for svc in "${GATEWAY_SERVICES[@]}"; do
    systemctl --user disable --now "$svc" 2>/dev/null || true
  done
  # Force-kill any remaining processes
  pkill -9 -f "openclaw.*gateway" 2>/dev/null || true
  pkill -9 -f "hermes.*gateway" 2>/dev/null || true
  sleep 3
  log_info "All gateways stopped"
}

enable_all_gateways() {
  log_info "Re-enabling gateway services…"
  for svc in "${GATEWAY_SERVICES[@]}"; do
    systemctl --user enable "$svc" 2>/dev/null || true
  done
  systemctl --user daemon-reload 2>/dev/null || true
}

verify_no_gateway_processes() {
  # Final aggressive cleanup — force-kill any remaining gateway processes
  pkill -9 -f "openclaw.*gateway" 2>/dev/null || true
  pkill -9 -f "hermes.*gateway" 2>/dev/null || true
  sleep 2
  local leftover
  leftover=$(pgrep -f "openclaw.*gateway" 2>/dev/null || true)
  leftover+=$(pgrep -f "hermes.*gateway" 2>/dev/null || true)
  if [[ -n "$leftover" ]]; then
    log_error "Gateway processes still running after force-kill: $leftover"
    ps -p $leftover -o pid,cmd 2>/dev/null
    die "Cannot proceed — gateway processes remain"
  fi
  log_info "No gateway processes running — OK"
}

verify_no_cron_schedulers() {
  local leftover
  leftover=$(pgrep -f "hermes.*cron" 2>/dev/null || true)
  leftover+=$(pgrep -f "openclaw.*cron" 2>/dev/null || true)
  # Hermes cron jobs run within the gateway process, so this is just extra safety
  if [[ -n "$leftover" ]]; then
    log_warn "Possible cron scheduler processes detected: $leftover"
  else
    log_info "No cron scheduler processes — OK"
  fi
}

start_openclaw_gateway() {
  log_info "Starting OpenClaw gateway…"
  systemctl --user start openclaw-gateway 2>/dev/null || {
    log_error "Failed to start OpenClaw gateway"
    return 1
  }
  log_info "OpenClaw gateway started"
}

start_hermes_gateway() {
  local profile="${1:-default}"
  log_info "Starting Hermes $profile gateway…"
  local svc="hermes-gateway-${profile}"
  systemctl --user start "$svc" 2>/dev/null || {
    log_error "Failed to start Hermes $profile gateway"
    return 1
  }
  log_info "Hermes $profile gateway started"
}

start_all_gateways() {
  start_openclaw_gateway || return 1
  start_hermes_gateway default || return 1
  start_hermes_gateway coder || return 1
  start_hermes_gateway "money-maker" || return 1
}

restore_running_gateways() {
  log_info "Restoring previously-running gateways…"
  # Re-enable services first
  enable_all_gateways
  sleep 1
  if [[ -n "${OPENCLAW_GATEWAY_PID:-}" ]]; then
    start_openclaw_gateway || log_error "Failed to restore OpenClaw gateway"
  fi
  if [[ -n "${HERMES_DEFAULT_PID:-}" ]]; then
    start_hermes_gateway default || log_error "Failed to restore Hermes default gateway"
  fi
  if [[ -n "${HERMES_CODER_PID:-}" ]]; then
    start_hermes_gateway coder || log_error "Failed to restore Hermes coder gateway"
  fi
  if [[ -n "${HERMES_MM_PID:-}" ]]; then
    start_hermes_gateway "money-maker" || log_error "Failed to restore Hermes money-maker gateway"
  fi
}

# -----------------------------------------------------------------------------
# sqlite helpers (via Python — sqlite3 CLI may not be installed)
# -----------------------------------------------------------------------------
sqlite_safe_backup() {
  local src="$1" dest="$2"
  log_info "Backing up SQLite: $src → $dest"
  python3 -c "
import sqlite3, shutil, os
try:
    src_db = sqlite3.connect('$src')
    # Use iterdump as a portable alternative to .backup
    with open('$dest', 'w') as f:
        for line in src_db.iterdump():
            f.write('%s\\n' % line)
    src_db.close()
    # Now create actual DB from dump
    dest_db = sqlite3.connect('$dest')
    with open('$dest', 'r') as f:
        dest_db.executescript(f.read())
    dest_db.close()
    # Reload and do iterdump again for proper DB
    src_db2 = sqlite3.connect('file:$src?mode=ro', uri=True)
    dest_db2 = sqlite3.connect('$dest')
    src_db2.backup(dest_db2)
    dest_db2.close()
    src_db2.close()
except Exception as e:
    # Fallback: direct file copy (less safe but works for stopped gateways)
    import shutil
    shutil.copy2('$src', '$dest')
    # Also copy WAL/SHM if they exist
    for ext in ['-wal', '-shm']:
        if os.path.exists('$src' + ext):
            shutil.copy2('$src' + ext, '$dest' + ext)
" 2>/dev/null || {
    log_error "SQLite backup failed for $src"
    return 1
  }
}

sqlite_integrity_check() {
  local db="$1"
  local result
  result=$(python3 -c "
import sqlite3
try:
    conn = sqlite3.connect('file:$db?mode=ro', uri=True)
    cur = conn.execute('PRAGMA integrity_check')
    row = cur.fetchone()
    print(row[0] if row else 'ok')
    conn.close()
except Exception as e:
    print(f'error: {e}')
" 2>/dev/null)
  if [[ "$result" != "ok" ]]; then
    log_error "SQLite integrity check FAILED for $db: $result"
    return 1
  fi
  log_info "SQLite integrity OK: $db"
}

# -----------------------------------------------------------------------------
# checksum helpers
# -----------------------------------------------------------------------------
sha256_file() {
  local file="$1"
  sha256sum "$file" | awk '{print $1}'
}

verify_sha256() {
  local file="$1" checksum_file="$2"
  local expected actual
  expected=$(cat "$checksum_file" | awk '{print $1}')
  actual=$(sha256_file "$file")
  if [[ "$actual" != "$expected" ]]; then
    die "SHA-256 mismatch: expected $expected, got $actual"
  fi
  log_info "SHA-256 verified: $file"
}

# -----------------------------------------------------------------------------
# path substitution
# -----------------------------------------------------------------------------
PORTABLE_PLACEHOLDER='${TARGET_HOME}'

render_paths() {
  local target_home="${1:-$HOME}"
  find "$REPO_ROOT" -type f \( -name "*.yaml" -o -name "*.yml" -o -name "*.json" -o -name "*.json5" -o -name "*.md" -o -name "*.sh" -o -name "*.txt" -o -name "*.cfg" -o -name "*.conf" -o -name "*.toml" \) \
    -exec sed -i "s|\\\${TARGET_HOME}|$target_home|g" {} + 2>/dev/null || true
}

check_no_absolute_paths() {
  local forbidden="/home/luckyang"
  local matches
  matches=$(grep -rl "$forbidden" "$REPO_ROOT"/openclaw/ "$REPO_ROOT"/hermes/ 2>/dev/null || true)
  if [[ -n "$matches" ]]; then
    log_error "Found hardcoded paths containing '$forbidden':"
    echo "$matches"
    return 1
  fi
  log_info "No hardcoded /home/luckyang paths found — OK"
}

# -----------------------------------------------------------------------------
# permission helpers
# -----------------------------------------------------------------------------
fix_permissions() {
  local target="$1"
  # Sensitive files: 0600
  find "$target" -type f \( -name ".env" -o -name "auth.json" -o -name "*.sqlite" -o -name "*.db" -o -name "credentials*" -o -name "identity*" \) \
    -exec chmod 0600 {} + 2>/dev/null || true
  # Sensitive directories: 0700
  find "$target" -type d \( -name "credentials" -o -name "identity" -o -name "pairing" -o -name "sessions" -o -name "devices" -o -name "memories" \) \
    -exec chmod 0700 {} + 2>/dev/null || true
  log_info "Permissions fixed: $target"
}

# -----------------------------------------------------------------------------
# temporary directory
# -----------------------------------------------------------------------------
create_secure_tmpdir() {
  umask 077
  mktemp -d
}

# -----------------------------------------------------------------------------
# secret detection (preflight)
# -----------------------------------------------------------------------------
scan_for_secrets() {
  local target="${1:-$REPO_ROOT}"
  local issues=0

  # Patterns that indicate possible secrets
  local patterns=(
    'api_key\s*[=:]\s*[A-Za-z0-9_-]{20,}'
    'apiKey["\s:]*[A-Za-z0-9_-]{20,}'
    'sk-[A-Za-z0-9_-]{20,}'
    'ark-[A-Za-z0-9_-]{20,}'
    'token\s*[=:]\s*[A-Za-z0-9_-]{20,}'
    'password\s*[=:]\s*[^\s"]{8,}'
    'secret\s*[=:]\s*[^\s"]{8,}'
  )

  for pattern in "${patterns[@]}"; do
    local matches
    matches=$(grep -rn "$pattern" "$target" --include="*.json" --include="*.yaml" --include="*.yml" --include="*.json5" --include="*.sh" --include="*.md" --include="*.txt" 2>/dev/null || true)
    # Exclude .env.EXAMPLE and preflight-check.sh itself
    matches=$(echo "$matches" | grep -v '.env.EXAMPLE' | grep -v 'preflight-check.sh' || true)
    if [[ -n "$matches" ]]; then
      log_error "Possible secrets detected matching pattern '$pattern':"
      # Only show file names, not content
      echo "$matches" | cut -d: -f1 | sort -u
      ((issues++))
    fi
  done

  if [[ $issues -gt 0 ]]; then
    die "Found $issues potential secret patterns in tracked files.  Fix before committing."
  fi
  log_info "No secrets detected in tracked files — OK"
}

scan_for_databases() {
  local target="${1:-$REPO_ROOT}"
  local matches
  matches=$(find "$target" -type f \( -name "*.sqlite" -o -name "*.db" -o -name "*.sqlite3" \) 2>/dev/null | grep -v '.git/' || true)
  if [[ -n "$matches" ]]; then
    log_error "Database files found in tracked area:"
    echo "$matches"
    die "Database files must not be committed to Git."
  fi
  log_info "No database files in tracked area — OK"
}

scan_for_archives() {
  local target="${1:-$REPO_ROOT}"
  local matches
  matches=$(find "$target" -type f \( -name "*.tar" -o -name "*.tar.gz" -o -name "*.tar.zst" -o -name "*.zip" \) 2>/dev/null | grep -v '.git/' || true)
  if [[ -n "$matches" ]]; then
    log_error "Archive files found in tracked area:"
    echo "$matches"
    die "Archive files must not be committed to Git."
  fi
  log_info "No archive files in tracked area — OK"
}
