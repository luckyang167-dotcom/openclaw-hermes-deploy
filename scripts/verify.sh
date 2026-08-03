#!/usr/bin/env bash
# =============================================================================
# verify.sh — verify deployment integrity
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

log_info "=== Deployment Verification ==="
ERRORS=0

# -----------------------------------------------------------------------------
# 1.  Check OpenClaw agents exist
# -----------------------------------------------------------------------------
log_info "Checking OpenClaw agents…"
for agent in main coding job-hunter fitness; do
  if [[ -d "${HOME}/.openclaw/agents/${agent}" ]]; then
    log_info "  Agent $agent — OK"
  else
    log_error "  Agent $agent — MISSING"
    ((ERRORS++))
  fi
done

# -----------------------------------------------------------------------------
# 2.  Check workspaces
# -----------------------------------------------------------------------------
log_info "Checking workspaces…"
for ws in workspace workspace-coding workspace-job-hunter workspace-fitness; do
  if [[ -d "${HOME}/.openclaw/${ws}" ]]; then
    log_info "  Workspace $ws — OK"
  else
    log_error "  Workspace $ws — MISSING"
    ((ERRORS++))
  fi
done

# -----------------------------------------------------------------------------
# 3.  Check OpenClaw config
# -----------------------------------------------------------------------------
log_info "Checking OpenClaw config…"
if [[ -f "${HOME}/.openclaw/openclaw.json" ]]; then
  log_info "  openclaw.json — OK"
else
  log_error "  openclaw.json — MISSING"
  ((ERRORS++))
fi

# -----------------------------------------------------------------------------
# 4.  Check Hermes profiles
# -----------------------------------------------------------------------------
log_info "Checking Hermes profiles…"
for profile in default coder money-maker; do
  if [[ "$profile" == "default" ]]; then
    if [[ -f "${HOME}/.hermes/config.yaml" ]]; then
      log_info "  Hermes default — OK"
    else
      log_error "  Hermes default — MISSING config.yaml"
      ((ERRORS++))
    fi
  else
    if [[ -f "${HOME}/.hermes/profiles/${profile}/config.yaml" ]]; then
      log_info "  Hermes $profile — OK"
    else
      log_error "  Hermes $profile — MISSING config.yaml"
      ((ERRORS++))
    fi
  fi
done

# -----------------------------------------------------------------------------
# 5.  Database integrity
# -----------------------------------------------------------------------------
log_info "Checking database integrity…"
while IFS= read -r -d '' db; do
  if ! sqlite_integrity_check "$db"; then
    ((ERRORS++))
  fi
done < <(find "${HOME}/.openclaw" "${HOME}/.hermes" -type f \( -name "*.db" -o -name "*.sqlite" \) -print0 2>/dev/null)

# -----------------------------------------------------------------------------
# 6.  No hardcoded paths
# -----------------------------------------------------------------------------
log_info "Checking for hardcoded paths…"
check_no_absolute_paths || ((ERRORS++))

# -----------------------------------------------------------------------------
# 7.  OpenClaw config validation
# -----------------------------------------------------------------------------
log_info "Validating OpenClaw config…"
openclaw config validate 2>/dev/null && log_info "  OpenClaw config validate — OK" || {
  log_warn "  OpenClaw config validate — warnings"
}

# -----------------------------------------------------------------------------
# 8.  Hermes doctor
# -----------------------------------------------------------------------------
log_info "Running Hermes doctor…"
hermes doctor 2>/dev/null && log_info "  Hermes doctor — OK" || {
  log_warn "  Hermes doctor — warnings"
}

# -----------------------------------------------------------------------------
# 9.  Report
# -----------------------------------------------------------------------------
if [[ $ERRORS -eq 0 ]]; then
  log_info "=== Verification PASSED ==="
else
  log_error "=== Verification FAILED with $ERRORS error(s) ==="
  exit 1
fi
