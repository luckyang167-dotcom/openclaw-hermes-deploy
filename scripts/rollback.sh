#!/usr/bin/env bash
# =============================================================================
# rollback.sh — restore target machine to pre-deployment state
# =============================================================================
# Usage: scripts/rollback.sh [--archive <path>]
#   If --archive is omitted, the most recent rollback is used.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

ROLLBACK_ARCHIVE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --archive) ROLLBACK_ARCHIVE="$2"; shift 2 ;;
    *) die "Unknown option: $1" ;;
  esac
done

log_info "=== Rollback ==="

# -----------------------------------------------------------------------------
# 1.  List or select rollback archive
# -----------------------------------------------------------------------------
ROLLBACK_ROOT="${REPO_ROOT}/.rollback"

if [[ ! -d "$ROLLBACK_ROOT" ]]; then
  die "No rollback archives found at $ROLLBACK_ROOT"
fi

if [[ -z "$ROLLBACK_ARCHIVE" ]]; then
  # Select most recent
  ROLLBACK_ARCHIVE=$(ls -dt "${ROLLBACK_ROOT}"/pre-deploy-* 2>/dev/null | head -1)
  if [[ -z "$ROLLBACK_ARCHIVE" ]]; then
    die "No rollback archives found"
  fi
  log_info "Using most recent rollback: $(basename "$ROLLBACK_ARCHIVE")"
else
  if [[ ! -d "$ROLLBACK_ARCHIVE" ]]; then
    die "Rollback archive not found: $ROLLBACK_ARCHIVE"
  fi
fi

log_info "Rollback archive: $ROLLBACK_ARCHIVE"

# List available archives for reference
log_info "Available rollback archives:"
ls -dt "${ROLLBACK_ROOT}"/pre-deploy-* 2>/dev/null | while read -r dir; do
  echo "  $(basename "$dir")"
done

# -----------------------------------------------------------------------------
# 2.  Stop services before copying the tree we are about to delete
# -----------------------------------------------------------------------------
# Same hazard as deploy: tar of a live WAL database can drop commits that a
# checkpoint folded into the main file between the db read and the WAL read.
log_info "Stopping all services…"
stop_all_gateways || true
sleep 2
verify_no_gateway_processes

# -----------------------------------------------------------------------------
# 3.  Create emergency backup of current (failed) state
# -----------------------------------------------------------------------------
EMERGENCY_DIR="${ROLLBACK_ROOT}/emergency-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$EMERGENCY_DIR"
log_info "Creating emergency backup of current state at $EMERGENCY_DIR…"

if [[ -d "${HOME}/.openclaw" ]]; then
  tar cf - -C "${HOME}" .openclaw | zstd -o "${EMERGENCY_DIR}/openclaw-emergency.tar.zst" \
    || die "Emergency OpenClaw backup failed — current state was not deleted"
fi
if [[ -d "${HOME}/.hermes" ]]; then
  tar cf - -C "${HOME}" .hermes | zstd -o "${EMERGENCY_DIR}/hermes-emergency.tar.zst" \
    || die "Emergency Hermes backup failed — current state was not deleted"
fi
log_info "Emergency backup complete"

# -----------------------------------------------------------------------------
# 4.  Restore from rollback
# -----------------------------------------------------------------------------
log_info "Restoring from rollback archive…"

if [[ -f "${ROLLBACK_ARCHIVE}/openclaw-backup.tar.zst" ]]; then
  log_info "Restoring OpenClaw state…"
  rm -rf "${HOME}/.openclaw" 2>/dev/null || true
  mkdir -p "${HOME}/.openclaw"
  zstd -d -c "${ROLLBACK_ARCHIVE}/openclaw-backup.tar.zst" | tar xf - -C "${HOME}"
  log_info "  OpenClaw restored"
else
  log_warn "No OpenClaw backup found in rollback archive"
fi

if [[ -f "${ROLLBACK_ARCHIVE}/hermes-backup.tar.zst" ]]; then
  log_info "Restoring Hermes state…"
  rm -rf "${HOME}/.hermes" 2>/dev/null || true
  mkdir -p "${HOME}/.hermes"
  zstd -d -c "${ROLLBACK_ARCHIVE}/hermes-backup.tar.zst" | tar xf - -C "${HOME}"
  log_info "  Hermes restored"
else
  log_warn "No Hermes backup found in rollback archive"
fi

# -----------------------------------------------------------------------------
# 5.  Fix permissions
# -----------------------------------------------------------------------------
fix_permissions "${HOME}/.openclaw" 2>/dev/null || true
fix_permissions "${HOME}/.hermes" 2>/dev/null || true

# -----------------------------------------------------------------------------
# 6.  Validate
# -----------------------------------------------------------------------------
log_info "Validating restored state…"

DB_ERRORS=0
while IFS= read -r -d '' db; do
  if ! sqlite_integrity_check "$db"; then
    ((DB_ERRORS++))
  fi
done < <(find "${HOME}/.openclaw" "${HOME}/.hermes" -type f \( -name "*.db" -o -name "*.sqlite" \) -print0 2>/dev/null)

if [[ $DB_ERRORS -gt 0 ]]; then
  log_error "$DB_ERRORS database(s) failed integrity check after rollback"
  log_error "Emergency backup available at: $EMERGENCY_DIR"
  die "Database integrity check failed after rollback"
fi

log_info "Restored database integrity — OK"

# -----------------------------------------------------------------------------
# 7.  Start services only if this host is active
# -----------------------------------------------------------------------------
STATUS=$(get_control_field status)
if [[ "$STATUS" == "active" ]]; then
  HOST_CTL=$(get_control_field host_id)
  log_info "Host is active ($HOST_CTL) — restarting gateways…"
  start_all_gateways || log_error "Failed to start gateways after rollback"
else
  log_info "Host status is '$STATUS' — gateways NOT started"
fi

# -----------------------------------------------------------------------------
# 8.  Done — do NOT delete rollback archive
# -----------------------------------------------------------------------------
log_info "=== Rollback complete ==="
log_info "Rollback archive preserved: $ROLLBACK_ARCHIVE"
log_info "Emergency backup preserved: $EMERGENCY_DIR"
