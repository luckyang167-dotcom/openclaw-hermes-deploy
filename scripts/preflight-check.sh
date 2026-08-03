#!/usr/bin/env bash
# =============================================================================
# preflight-check.sh — verify no secrets, databases, or archives in Git staged files
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

log_info "=== Preflight Check ==="
ERRORS=0

# -----------------------------------------------------------------------------
# 1.  Scan for secrets in tracked files
# -----------------------------------------------------------------------------
log_info "Scanning for secrets…"
if ! scan_for_secrets "$REPO_ROOT"; then
  ((ERRORS++))
fi

# -----------------------------------------------------------------------------
# 2.  Scan for databases
# -----------------------------------------------------------------------------
log_info "Scanning for databases…"
if ! scan_for_databases "$REPO_ROOT"; then
  ((ERRORS++))
fi

# -----------------------------------------------------------------------------
# 3.  Scan for archives
# -----------------------------------------------------------------------------
log_info "Scanning for archives…"
if ! scan_for_archives "$REPO_ROOT"; then
  ((ERRORS++))
fi

# -----------------------------------------------------------------------------
# 4.  Check gitignore coverage
# -----------------------------------------------------------------------------
log_info "Checking .gitignore coverage…"
# These patterns must be in .gitignore
REQUIRED_PATTERNS=(
  "*.tar.zst"
  ".env"
  "auth.json"
  "*.sqlite"
  "*.db"
  "sessions/"
  "credentials/"
  "identity/"
  "gateway.lock"
)

for pattern in "${REQUIRED_PATTERNS[@]}"; do
  if grep -qF "$pattern" "${REPO_ROOT}/.gitignore" 2>/dev/null; then
    log_info "  .gitignore covers '$pattern' — OK"
  else
    log_error "  .gitignore MISSING pattern: '$pattern'"
    ((ERRORS++))
  fi
done

# -----------------------------------------------------------------------------
# 5.  Check manifest is valid YAML
# -----------------------------------------------------------------------------
log_info "Validating manifest.yaml…"
if python3 -c "import yaml; yaml.safe_load(open('${MANIFEST_FILE}'))" 2>/dev/null; then
  log_info "  manifest.yaml — valid YAML"
else
  log_error "  manifest.yaml — INVALID YAML"
  ((ERRORS++))
fi

# -----------------------------------------------------------------------------
# 6.  Check active-host.json is valid JSON
# -----------------------------------------------------------------------------
log_info "Validating active-host.json…"
if python3 -c "import json; json.load(open('${CONTROL_FILE}'))" 2>/dev/null; then
  log_info "  active-host.json — valid JSON"
else
  log_error "  active-host.json — INVALID JSON"
  ((ERRORS++))
fi

# -----------------------------------------------------------------------------
# 7.  Check all required scripts are present and executable
# -----------------------------------------------------------------------------
log_info "Checking required scripts…"
REQUIRED_SCRIPTS=(
  "common.sh"
  "export.sh"
  "deploy.sh"
  "demote.sh"
  "promote.sh"
  "verify.sh"
  "rollback.sh"
  "preflight-check.sh"
)

for script in "${REQUIRED_SCRIPTS[@]}"; do
  if [[ -x "${REPO_ROOT}/scripts/${script}" ]]; then
    log_info "  scripts/${script} — OK"
  elif [[ -f "${REPO_ROOT}/scripts/${script}" ]]; then
    log_warn "  scripts/${script} — exists but NOT executable"
    ((ERRORS++))
  else
    log_error "  scripts/${script} — MISSING"
    ((ERRORS++))
  fi
done

# -----------------------------------------------------------------------------
# 8.  Check required directories
# -----------------------------------------------------------------------------
log_info "Checking required directories…"
REQUIRED_DIRS=(
  "openclaw/config"
  "openclaw/agents/main"
  "openclaw/agents/job-hunter"
  "openclaw/agents/coding"
  "openclaw/agents/fitness"
  "openclaw/cron"
  "hermes/profiles/default"
  "hermes/profiles/coder"
  "hermes/profiles/money-maker"
  "control"
  "scripts"
)

for dir in "${REQUIRED_DIRS[@]}"; do
  if [[ -d "${REPO_ROOT}/${dir}" ]]; then
    log_info "  ${dir}/ — OK"
  else
    log_error "  ${dir}/ — MISSING"
    ((ERRORS++))
  fi
done

# -----------------------------------------------------------------------------
# 9.  Check README exists
# -----------------------------------------------------------------------------
if [[ -f "${REPO_ROOT}/README.md" ]]; then
  log_info "  README.md — OK"
else
  log_error "  README.md — MISSING"
  ((ERRORS++))
fi

# -----------------------------------------------------------------------------
# 10. Git diff check
# -----------------------------------------------------------------------------
log_info "Checking git working tree…"
if git diff-index --quiet HEAD -- 2>/dev/null; then
  log_info "  Working tree clean — OK"
else
  log_warn "  Working tree has uncommitted changes:"
  git diff --stat HEAD 2>/dev/null
fi

# -----------------------------------------------------------------------------
# 11. Large file check
# -----------------------------------------------------------------------------
log_info "Checking for large files in tracked area…"
LARGE_FILES=$(find "$REPO_ROOT" -type f -size +1M \
  -not -path "*/.git/*" \
  -not -path "*/.rollback/*" \
  -not -name "*.tar.zst" \
  -not -name "*.tar.gz" \
  2>/dev/null || true)
if [[ -n "$LARGE_FILES" ]]; then
  log_warn "Large files (>1MB) found:"
  echo "$LARGE_FILES" | while read -r f; do
    echo "  $f ($(du -h "$f" | cut -f1))"
  done
else
  log_info "  No large files — OK"
fi

# -----------------------------------------------------------------------------
# Final report
# -----------------------------------------------------------------------------
if [[ $ERRORS -eq 0 ]]; then
  log_info "=== Preflight check PASSED ==="
else
  log_error "=== Preflight check FAILED with $ERRORS error(s) ==="
  exit 1
fi
