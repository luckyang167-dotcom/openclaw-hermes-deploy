#!/usr/bin/env bash
# =============================================================================
# demote.sh — demote current active host and prepare for standby takeover
# =============================================================================
# Usage: scripts/demote.sh --next-host <id>
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

NEXT_HOST=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --next-host) NEXT_HOST="$2"; shift 2 ;;
    *) die "Unknown option: $1" ;;
  esac
done

[[ -z "$NEXT_HOST" ]] && die "--next-host <id> is required"

# -----------------------------------------------------------------------------
# 1.  Preflight
# -----------------------------------------------------------------------------
log_info "=== Demote: active → switching ==="
log_info "Next host: $NEXT_HOST"

require_clean_git
require_fast_forward
require_host_active

HOST_ID=$(get_control_field host_id)
GEN=$(get_control_field generation)

# -----------------------------------------------------------------------------
# 2.  Export with keep-stopped
# -----------------------------------------------------------------------------
log_info "Creating final consistency snapshot before demotion…"
"${SCRIPT_DIR}/export.sh" --keep-stopped

# -----------------------------------------------------------------------------
# 3.  Get the snapshot tag from manifest
# -----------------------------------------------------------------------------
SNAPSHOT_TAG=$(python3 -c "
import yaml
with open('${MANIFEST_FILE}') as f:
    print(yaml.safe_load(f).get('snapshot_tag',''))
" 2>/dev/null)

if [[ -z "$SNAPSHOT_TAG" ]]; then
  log_error "Could not determine snapshot tag from manifest"
  log_error "Gateways are STOPPED.  To restore, run:"
  log_error "  scripts/export.sh  (creates new snapshot)"
  log_error "  or manually restart gateways"
  die "Demote failed: no snapshot tag"
fi

# -----------------------------------------------------------------------------
# 4.  Update control file
# -----------------------------------------------------------------------------
NEW_GEN=$((GEN + 1))
log_info "Updating control: status=switching, generation=$NEW_GEN"

write_control "{
  \"status\": \"switching\",
  \"next_host_id\": \"${NEXT_HOST}\",
  \"snapshot_tag\": \"${SNAPSHOT_TAG}\",
  \"generation\": ${NEW_GEN},
  \"updated_at\": \"$(date -Iseconds)\"
}"

# -----------------------------------------------------------------------------
# 5.  Commit and push
# -----------------------------------------------------------------------------
log_info "Committing control file update…"
git add "${CONTROL_FILE}" "${MANIFEST_FILE}" 2>/dev/null || true
git commit -m "chore: demote ${HOST_ID} → switching (next: ${NEXT_HOST}, gen ${NEW_GEN}, snapshot ${SNAPSHOT_TAG})" 2>/dev/null || true

log_info "Pushing demotion state…"
if ! git push origin main; then
  log_error "PUSH FAILED!"
  log_error "Gateways are STOPPED.  Control state is committed locally but not pushed."
  log_error ""
  log_error "Recovery steps:"
  log_error "  1. Fix network / auth issue"
  log_error "  2. Run: git push origin main"
  log_error "  3. Verify: gh repo view"
  log_error "  4. On standby machine, run: scripts/promote.sh --host-id ${NEXT_HOST} --snapshot ${SNAPSHOT_TAG}"
  die "Push failed — manual recovery required"
fi

# -----------------------------------------------------------------------------
# 6.  Done — services remain stopped
# -----------------------------------------------------------------------------
log_info "=== Demotion complete ==="
log_info "Status: switching"
log_info "Next host: $NEXT_HOST"
log_info "Snapshot: $SNAPSHOT_TAG"
log_info "Generation: $NEW_GEN"
log_info ""
log_info "Gateways are STOPPED on this machine."
log_info "On standby machine ($NEXT_HOST), run:"
log_info "  scripts/deploy.sh --snapshot ${SNAPSHOT_TAG} --host-id ${NEXT_HOST}"
log_info "  scripts/promote.sh --host-id ${NEXT_HOST} --snapshot ${SNAPSHOT_TAG}"
