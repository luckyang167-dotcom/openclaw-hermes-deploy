#!/usr/bin/env bash
# =============================================================================
# deploy.sh — deploy an OpenClaw + Hermes state snapshot to target machine
# =============================================================================
# Usage: scripts/deploy.sh --snapshot <tag> --host-id <id>
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

SNAPSHOT_TAG=""
HOST_ID=""
ROLLBACK_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --snapshot) SNAPSHOT_TAG="$2"; shift 2 ;;
    --host-id)  HOST_ID="$2"; shift 2 ;;
    *) die "Unknown option: $1" ;;
  esac
done

[[ -z "$SNAPSHOT_TAG" ]] && die "--snapshot <tag> is required"
[[ -z "$HOST_ID" ]] && die "--host-id <id> is required"

# -----------------------------------------------------------------------------
# 1.  Platform checks
# -----------------------------------------------------------------------------
log_info "=== OpenClaw + Hermes Deploy ==="
log_info "Snapshot: $SNAPSHOT_TAG"
log_info "Host ID: $HOST_ID"

require_linux_or_wsl2

if is_wsl2; then
  log_info "WSL2 detected — OK"
else
  log_info "Native Linux detected — OK"
fi

# -----------------------------------------------------------------------------
# 2.  Dependency checks
# -----------------------------------------------------------------------------
require_deps
require_gh_auth

# Verify versions match manifest
MANIFEST_OC=$(python3 -c "import yaml; print(yaml.safe_load(open('${MANIFEST_FILE}'))['openclaw_version'])" 2>/dev/null || echo "2026.6.11")
MANIFEST_HM=$(python3 -c "import yaml; print(yaml.safe_load(open('${MANIFEST_FILE}'))['hermes_version'])" 2>/dev/null || echo "0.19.0")
MANIFEST_NODE=$(python3 -c "import yaml; print(yaml.safe_load(open('${MANIFEST_FILE}'))['node_version'])" 2>/dev/null || echo "24.15.0")

verify_node_version "$MANIFEST_NODE"
verify_openclaw_version "$MANIFEST_OC"
verify_hermes_version "$MANIFEST_HM"

# -----------------------------------------------------------------------------
# 3.  Verify GitHub access
# -----------------------------------------------------------------------------
log_info "Verifying GitHub access to repository…"
REPO=$(git remote get-url origin 2>/dev/null | sed 's|.*github.com[:/]||; s|\.git$||')
gh repo view "$REPO" &>/dev/null || die "Cannot access GitHub repo $REPO"

# -----------------------------------------------------------------------------
# 4.  Download release
# -----------------------------------------------------------------------------
WORKDIR=$(create_secure_tmpdir)
trap 'rm -rf "$WORKDIR"' EXIT
log_info "Downloading release $SNAPSHOT_TAG…"

cd "$WORKDIR"
gh release download "$SNAPSHOT_TAG" --repo "$REPO" --pattern "agent-state.tar.zst" --pattern "*.sha256" 2>/dev/null || {
  die "Failed to download release $SNAPSHOT_TAG"
}

# -----------------------------------------------------------------------------
# 5.  Verify SHA-256
# -----------------------------------------------------------------------------
log_info "Verifying SHA-256…"
ARCHIVE="${WORKDIR}/agent-state.tar.zst"
CHECKSUM="${WORKDIR}/agent-state.tar.zst.sha256"
verify_sha256 "$ARCHIVE" "$CHECKSUM"

# -----------------------------------------------------------------------------
# 6.  Extract to temp directory
# -----------------------------------------------------------------------------
EXTRACT_DIR="${WORKDIR}/extract"
mkdir -p "$EXTRACT_DIR"
log_info "Extracting archive…"
zstd -d -c "$ARCHIVE" | tar xf - -C "$EXTRACT_DIR"

# -----------------------------------------------------------------------------
# 7.  Create local rollback backup
# -----------------------------------------------------------------------------
ROLLBACK_DIR="${REPO_ROOT}/.rollback/pre-deploy-${SNAPSHOT_TAG}-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$ROLLBACK_DIR"
log_info "Creating local rollback backup at $ROLLBACK_DIR…"

# Backup current OpenClaw state (if exists)
if [[ -d "${HOME}/.openclaw" ]]; then
  tar cf - -C "${HOME}" .openclaw 2>/dev/null | zstd -o "${ROLLBACK_DIR}/openclaw-backup.tar.zst" || true
  log_info "  OpenClaw backup: $(du -h "${ROLLBACK_DIR}/openclaw-backup.tar.zst" 2>/dev/null | cut -f1 || echo 'skipped')"
fi

if [[ -d "${HOME}/.hermes" ]]; then
  tar cf - -C "${HOME}" .hermes 2>/dev/null | zstd -o "${ROLLBACK_DIR}/hermes-backup.tar.zst" || true
  log_info "  Hermes backup: $(du -h "${ROLLBACK_DIR}/hermes-backup.tar.zst" 2>/dev/null | cut -f1 || echo 'skipped')"
fi

# Record rollback metadata
cat > "${ROLLBACK_DIR}/metadata.json" <<METAEOF
{
  "snapshot_tag": "${SNAPSHOT_TAG}",
  "host_id": "${HOST_ID}",
  "created_at": "$(date -Iseconds)",
  "pre_deploy_generation": "$(get_control_field generation)"
}
METAEOF

# -----------------------------------------------------------------------------
# 8.  Stop target services
# -----------------------------------------------------------------------------
log_info "Stopping all local services before deployment…"
stop_all_gateways || log_warn "Some gateways may not have been running"
sleep 2

# -----------------------------------------------------------------------------
# 9.  Profile-level merge
# -----------------------------------------------------------------------------
log_info "=== Profile-level merge ==="
TARGET_OC="${HOME}/.openclaw"
TARGET_HM="${HOME}/.hermes"

mkdir -p "$TARGET_OC" "$TARGET_HM"

# --- OpenClaw agents: source wins for included agents ---
log_info "Merging OpenClaw agents (source-wins for included)…"
for agent in main coding job-hunter fitness; do
  SRC="${EXTRACT_DIR}/openclaw-agents-${agent}"
  DST="${TARGET_OC}/agents/${agent}"
  if [[ -d "$SRC" ]]; then
    log_info "  Replacing agent: $agent"
    rm -rf "$DST" 2>/dev/null || true
    mkdir -p "$(dirname "$DST")"
    cp -a "$SRC" "$DST"
  fi
done

# --- OpenClaw workspaces ---
for ws in workspace workspace-coding workspace-job-hunter workspace-fitness; do
  SRC="${EXTRACT_DIR}/${ws}"
  DST="${TARGET_OC}/${ws}"
  if [[ -d "$SRC" ]]; then
    log_info "  Replacing workspace: $ws"
    rm -rf "$DST" 2>/dev/null || true
    cp -a "$SRC" "$DST"
  fi
done

# --- OpenClaw config ---
if [[ -f "${EXTRACT_DIR}/openclaw.json" ]]; then
  cp -a "${EXTRACT_DIR}/openclaw.json" "${TARGET_OC}/openclaw.json"
fi

# --- OpenClaw sensitive dirs ---
for dir in credentials identity devices extensions hooks plugin-skills memory media; do
  SRC="${EXTRACT_DIR}/${dir}"
  DST="${TARGET_OC}/${dir}"
  if [[ -d "$SRC" ]]; then
    rm -rf "$DST" 2>/dev/null || true
    cp -a "$SRC" "$DST"
  fi
done

for dir in state workspace-attestations; do
  SRC="${EXTRACT_DIR}/${dir}"
  DST="${TARGET_OC}/${dir}"
  if [[ -d "$SRC" ]]; then
    rm -rf "$DST" 2>/dev/null || true
    cp -a "$SRC" "$DST"
  fi
done

# Node identity and exec-approvals
for f in node.json exec-approvals.json; do
  if [[ -f "${EXTRACT_DIR}/$f" ]]; then
    cp -a "${EXTRACT_DIR}/$f" "${TARGET_OC}/$f"
  fi
done

# --- Hermes default profile ---
log_info "Merging Hermes default profile…"
for item in .env config.yaml auth.json SOUL.md channel_directory.json gateway_state.json; do
  SRC="${EXTRACT_DIR}/hermes-default-${item##*/}"
  if [[ -f "$SRC" ]]; then
    cp -a "$SRC" "${TARGET_HM}/${item##*/}"
  fi
done

for dir in cron memories pairing sessions skills state; do
  SRC="${EXTRACT_DIR}/hermes-default-${dir}"
  DST="${TARGET_HM}/${dir}"
  if [[ -d "$SRC" ]]; then
    rm -rf "$DST" 2>/dev/null || true
    cp -a "$SRC" "$DST"
  fi
done

# Hermes default databases. install_sqlite_file drops leftover -wal/-shm so a
# SIGKILL'd local writer cannot replay onto the snapshot.
for db in state.db projects.db kanban.db; do
  SRC="${EXTRACT_DIR}/hermes-default-${db}"
  if [[ -f "$SRC" ]]; then
    install_sqlite_file "$SRC" "${TARGET_HM}/${db}"
  fi
done
if [[ -f "${EXTRACT_DIR}/hermes-default-cron-executions.db" ]]; then
  install_sqlite_file "${EXTRACT_DIR}/hermes-default-cron-executions.db" "${TARGET_HM}/cron/executions.db"
fi

# --- Hermes coder profile ---
log_info "Merging Hermes coder profile…"
CODER_DST="${TARGET_HM}/profiles/coder"
mkdir -p "$CODER_DST"
for item in .env config.yaml auth.json SOUL.md channel_directory.json gateway_state.json profile.yaml; do
  SRC="${EXTRACT_DIR}/hermes-coder-${item##*/}"
  if [[ -f "$SRC" ]]; then
    cp -a "$SRC" "${CODER_DST}/${item##*/}"
  fi
done
for dir in cron memories pairing sessions skills state plans platforms skins workspace home hooks; do
  SRC="${EXTRACT_DIR}/hermes-coder-${dir}"
  if [[ -d "$SRC" ]]; then
    rm -rf "${CODER_DST}/${dir}" 2>/dev/null || true
    cp -a "$SRC" "${CODER_DST}/${dir}"
  fi
done
for db in state.db projects.db; do
  SRC="${EXTRACT_DIR}/hermes-coder-${db}"
  if [[ -f "$SRC" ]]; then
    install_sqlite_file "$SRC" "${CODER_DST}/${db}"
  fi
done
if [[ -f "${EXTRACT_DIR}/hermes-coder-cron-executions.db" ]]; then
  install_sqlite_file "${EXTRACT_DIR}/hermes-coder-cron-executions.db" "${CODER_DST}/cron/executions.db"
fi

# --- Hermes money-maker profile ---
log_info "Merging Hermes money-maker profile…"
MM_DST="${TARGET_HM}/profiles/money-maker"
mkdir -p "$MM_DST"
for item in .env config.yaml auth.json SOUL.md channel_directory.json gateway_state.json profile.yaml; do
  SRC="${EXTRACT_DIR}/hermes-mm-${item##*/}"
  if [[ -f "$SRC" ]]; then
    cp -a "$SRC" "${MM_DST}/${item##*/}"
  fi
done
for dir in cron memories pairing sessions skills state plans platforms skins workspace home hooks; do
  SRC="${EXTRACT_DIR}/hermes-mm-${dir}"
  if [[ -d "$SRC" ]]; then
    rm -rf "${MM_DST}/${dir}" 2>/dev/null || true
    cp -a "$SRC" "${MM_DST}/${dir}"
  fi
done
for db in state.db projects.db; do
  SRC="${EXTRACT_DIR}/hermes-mm-${db}"
  if [[ -f "$SRC" ]]; then
    install_sqlite_file "$SRC" "${MM_DST}/${db}"
  fi
done
if [[ -f "${EXTRACT_DIR}/hermes-mm-cron-executions.db" ]]; then
  install_sqlite_file "${EXTRACT_DIR}/hermes-mm-cron-executions.db" "${MM_DST}/cron/executions.db"
fi

# -----------------------------------------------------------------------------
# 10. Render paths
# -----------------------------------------------------------------------------
log_info "Rendering portable paths to $HOME…"
render_paths "$TARGET_OC" "$TARGET_HM"

# -----------------------------------------------------------------------------
# 11. Fix permissions
# -----------------------------------------------------------------------------
log_info "Fixing permissions…"
fix_permissions "$TARGET_OC"
fix_permissions "$TARGET_HM"

# -----------------------------------------------------------------------------
# 12. Config validation
# -----------------------------------------------------------------------------
log_info "Running configuration validation…"

# OpenClaw validate
if openclaw config validate 2>/dev/null; then
  log_info "OpenClaw config validate — OK"
else
  log_warn "OpenClaw config validate — warnings (non-fatal)"
fi

# Hermes doctor
if hermes doctor 2>/dev/null; then
  log_info "Hermes doctor — OK"
else
  log_warn "Hermes doctor — warnings (non-fatal)"
fi

# -----------------------------------------------------------------------------
# 13. Database integrity checks
# -----------------------------------------------------------------------------
log_info "Running database integrity checks…"
DB_ERRORS=0
while IFS= read -r -d '' db; do
  if ! sqlite_integrity_check "$db"; then
    ((DB_ERRORS++))
  fi
done < <(find "$TARGET_OC" "$TARGET_HM" -type f \( -name "*.db" -o -name "*.sqlite" \) -print0 2>/dev/null)

if [[ $DB_ERRORS -gt 0 ]]; then
  log_error "$DB_ERRORS database(s) failed integrity check"
  log_error "Rollback archive available at: $ROLLBACK_DIR"
  die "Database integrity check failed — deployment aborted"
fi

# -----------------------------------------------------------------------------
# 14. Check for hardcoded paths
# -----------------------------------------------------------------------------
check_no_absolute_paths

# -----------------------------------------------------------------------------
# 15. Deployment complete — DO NOT start services
# -----------------------------------------------------------------------------
log_info "=== Deploy complete ==="
log_info "Rollback archive: $ROLLBACK_DIR"
log_info ""
log_info "IMPORTANT: Services are NOT started."
log_info "  - Standby hosts MUST NOT start gateways."
log_info "  - Only promote.sh can start services."
log_info "  - If you need to rollback, run: scripts/rollback.sh"
