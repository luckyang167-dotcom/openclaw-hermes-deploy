#!/usr/bin/env bash
# =============================================================================
# promote.sh — promote standby host to active
# =============================================================================
# Usage: scripts/promote.sh --host-id <id> --snapshot <tag>
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

HOST_ID=""
SNAPSHOT_TAG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host-id)  HOST_ID="$2"; shift 2 ;;
    --snapshot) SNAPSHOT_TAG="$2"; shift 2 ;;
    *) die "Unknown option: $1" ;;
  esac
done

[[ -z "$HOST_ID" ]] && die "--host-id <id> is required"
[[ -z "$SNAPSHOT_TAG" ]] && die "--snapshot <tag> is required"

# -----------------------------------------------------------------------------
# 1.  Preflight
# -----------------------------------------------------------------------------
log_info "=== Promote: switching → active ==="
log_info "Host ID: $HOST_ID"
log_info "Snapshot: $SNAPSHOT_TAG"

require_clean_git
require_fast_forward

# -----------------------------------------------------------------------------
# 2.  Verify control state
# -----------------------------------------------------------------------------
require_host_switching

NEXT_HOST_ID=$(get_control_field next_host_id)
GEN=$(get_control_field generation)
CTL_SNAPSHOT=$(get_control_field snapshot_tag)

if [[ "$NEXT_HOST_ID" != "$HOST_ID" ]]; then
  die "next_host_id is '$NEXT_HOST_ID', but this host is '$HOST_ID'.  Refusing to promote."
fi

if [[ "$CTL_SNAPSHOT" != "$SNAPSHOT_TAG" ]]; then
  die "Control snapshot tag '$CTL_SNAPSHOT' does not match requested '$SNAPSHOT_TAG'"
fi

log_info "Control state verified: switching → $HOST_ID, generation=$GEN, snapshot=$SNAPSHOT_TAG"

# -----------------------------------------------------------------------------
# 3.  Verify deployment
# -----------------------------------------------------------------------------
log_info "Running verify.sh…"
"${SCRIPT_DIR}/verify.sh" || die "verify.sh failed"

# -----------------------------------------------------------------------------
# 4.  Update control file
# -----------------------------------------------------------------------------
NEW_GEN=$((GEN + 1))
log_info "Updating control: status=active, host_id=$HOST_ID, generation=$NEW_GEN"

write_control "{
  \"host_id\": \"${HOST_ID}\",
  \"status\": \"active\",
  \"next_host_id\": null,
  \"snapshot_tag\": \"${SNAPSHOT_TAG}\",
  \"generation\": ${NEW_GEN},
  \"updated_at\": \"$(date -Iseconds)\"
}"

# -----------------------------------------------------------------------------
# 5.  Commit and push
# -----------------------------------------------------------------------------
log_info "Committing control file update…"
git add "${CONTROL_FILE}" 2>/dev/null || true
git commit -m "chore: promote ${HOST_ID} → active (gen ${NEW_GEN}, snapshot ${SNAPSHOT_TAG})" 2>/dev/null || true

log_info "Pushing promotion state…"
if ! git push origin main; then
  log_error "PUSH FAILED!"
  log_error "Reverting control to switching state…"
  write_control "{
    \"status\": \"switching\",
    \"host_id\": \"\",
    \"next_host_id\": \"${HOST_ID}\",
    \"snapshot_tag\": \"${SNAPSHOT_TAG}\",
    \"generation\": ${GEN},
    \"updated_at\": \"$(date -Iseconds)\"
  }"
  die "Push failed — reverted to switching.  Services NOT started."
fi

# -----------------------------------------------------------------------------
# 6.  Start gateways
# -----------------------------------------------------------------------------
log_info "Starting gateways…"
if ! start_all_gateways; then
  log_error "Gateway start failed!"
  log_error "Reverting control to switching state…"
  # start_all_gateways enables the units. Disable them again while this host
  # is still switching, or a reboot would start gateways that are not active.
  stop_all_gateways || true
  write_control "{
    \"status\": \"switching\",
    \"host_id\": \"\",
    \"next_host_id\": \"${HOST_ID}\",
    \"snapshot_tag\": \"${SNAPSHOT_TAG}\",
    \"generation\": ${GEN},
    \"updated_at\": \"$(date -Iseconds)\"
  }"
  # Commit and push revert
  git add "${CONTROL_FILE}" 2>/dev/null || true
  git commit -m "chore: revert to switching — gateway start failed" 2>/dev/null || true
  git push origin main 2>/dev/null || true
  die "Gateway start failed — reverted to switching"
fi

# -----------------------------------------------------------------------------
# 7.  Health check
# -----------------------------------------------------------------------------
log_info "Waiting for gateways to stabilize…"
sleep 5

HEALTH_OK=true

if ! pgrep -f "openclaw.*gateway" &>/dev/null; then
  log_error "OpenClaw gateway not running"
  HEALTH_OK=false
else
  log_info "OpenClaw gateway running — OK"
fi

for profile in default coder "money-maker"; do
  if pgrep -f "hermes.*${profile}.*gateway" &>/dev/null; then
    log_info "Hermes $profile gateway running — OK"
  else
    log_error "Hermes $profile gateway not running"
    HEALTH_OK=false
  fi
done

if ! $HEALTH_OK; then
  log_error "Health check failed — some gateways not running"
  log_error "Reverting to switching state…"
  stop_all_gateways || true
  write_control "{
    \"status\": \"switching\",
    \"host_id\": \"\",
    \"next_host_id\": \"${HOST_ID}\",
    \"snapshot_tag\": \"${SNAPSHOT_TAG}\",
    \"generation\": ${GEN},
    \"updated_at\": \"$(date -Iseconds)\"
  }"
  git add "${CONTROL_FILE}" 2>/dev/null || true
  git commit -m "chore: revert to switching — health check failed" 2>/dev/null || true
  git push origin main 2>/dev/null || true
  die "Health check failed — reverted to switching"
fi

# -----------------------------------------------------------------------------
# 8.  Done
# -----------------------------------------------------------------------------
log_info "=== Promotion complete ==="
log_info "Host: $HOST_ID"
log_info "Status: active"
log_info "Generation: $NEW_GEN"
log_info "Snapshot: $SNAPSHOT_TAG"
