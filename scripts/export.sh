#!/usr/bin/env bash
# =============================================================================
# export.sh — create a consistent state snapshot for openclaw-hermes-deploy
# =============================================================================
# Usage: scripts/export.sh [--tag <tag>] [--keep-stopped]
#   --tag           Optional custom snapshot tag (default: snapshot-YYYYMMDD-HHMMSSZ)
#   --keep-stopped  Do not restart gateways after export (for demote.sh)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

KEEP_STOPPED=false
CUSTOM_TAG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) CUSTOM_TAG="$2"; shift 2 ;;
    --keep-stopped) KEEP_STOPPED=true; shift ;;
    *) die "Unknown option: $1" ;;
  esac
done

# -----------------------------------------------------------------------------
# 1.  Preflight — must be active
# -----------------------------------------------------------------------------
log_info "=== OpenClaw + Hermes State Snapshot Export ==="
require_clean_git
require_host_active

HOST_ID=$(get_control_field host_id)
GEN=$(get_control_field generation)

# -----------------------------------------------------------------------------
# 2.  Record running gateways
# -----------------------------------------------------------------------------
record_running_gateways

# -----------------------------------------------------------------------------
# 3.  Secure temp directory
# -----------------------------------------------------------------------------
umask 077
WORKDIR=$(create_secure_tmpdir)
trap 'rm -rf "$WORKDIR"' EXIT
log_info "Working directory: $WORKDIR"

SNAPSHOT_DIR="${WORKDIR}/snapshot"
mkdir -p "$SNAPSHOT_DIR"

# -----------------------------------------------------------------------------
# 4.  Stop gateways
# -----------------------------------------------------------------------------
stop_all_gateways
sleep 2
verify_no_gateway_processes
verify_no_cron_schedulers

# -----------------------------------------------------------------------------
# 5.  Collect state by allowlist
# -----------------------------------------------------------------------------
log_info "Collecting state…"

SRC_HOME="/home/luckyang"
OC_DIR="${SRC_HOME}/.openclaw"
HM_DIR="${SRC_HOME}/.hermes"

# --- OpenClaw agent data ---
for agent in main coding job-hunter fitness; do
  log_info "  OpenClaw agent: $agent"
  if [[ -d "${OC_DIR}/agents/${agent}" ]]; then
    cp -a "${OC_DIR}/agents/${agent}" "${SNAPSHOT_DIR}/openclaw-agents-${agent}"
  fi
done

# --- OpenClaw workspaces ---
for ws in workspace workspace-coding workspace-job-hunter workspace-fitness; do
  if [[ -d "${OC_DIR}/${ws}" ]]; then
    log_info "  OpenClaw workspace: $ws"
    cp -a "${OC_DIR}/${ws}" "${SNAPSHOT_DIR}/${ws}"
  fi
done

# --- OpenClaw config ---
if [[ -f "${OC_DIR}/openclaw.json" ]]; then
  cp -a "${OC_DIR}/openclaw.json" "${SNAPSHOT_DIR}/openclaw.json"
fi

# --- OpenClaw credentials, identity, devices ---
for dir in credentials identity devices; do
  if [[ -d "${OC_DIR}/${dir}" ]]; then
    cp -a "${OC_DIR}/${dir}" "${SNAPSHOT_DIR}/${dir}"
  fi
done

# --- OpenClaw extensions and hooks ---
for dir in extensions hooks; do
  if [[ -d "${OC_DIR}/${dir}" ]]; then
    cp -a "${OC_DIR}/${dir}" "${SNAPSHOT_DIR}/${dir}"
  fi
done

# --- OpenClaw plugin-skills ---
if [[ -d "${OC_DIR}/plugin-skills" ]]; then
  cp -a "${OC_DIR}/plugin-skills" "${SNAPSHOT_DIR}/plugin-skills"
fi

# --- OpenClaw memory ---
if [[ -d "${OC_DIR}/memory" ]]; then
  cp -a "${OC_DIR}/memory" "${SNAPSHOT_DIR}/memory"
fi

# --- OpenClaw state ---
if [[ -d "${OC_DIR}/state" ]]; then
  cp -a "${OC_DIR}/state" "${SNAPSHOT_DIR}/state-oc"
fi

# --- OpenClaw node identity ---
if [[ -f "${OC_DIR}/node.json" ]]; then
  cp -a "${OC_DIR}/node.json" "${SNAPSHOT_DIR}/node.json"
fi

# --- OpenClaw media ---
if [[ -d "${OC_DIR}/media" ]]; then
  cp -a "${OC_DIR}/media" "${SNAPSHOT_DIR}/media"
fi

# --- OpenClaw exec-approvals ---
if [[ -f "${OC_DIR}/exec-approvals.json" ]]; then
  cp -a "${OC_DIR}/exec-approvals.json" "${SNAPSHOT_DIR}/exec-approvals.json"
fi

# --- OpenClaw workspace-attestations ---
if [[ -d "${OC_DIR}/workspace-attestations" ]]; then
  cp -a "${OC_DIR}/workspace-attestations" "${SNAPSHOT_DIR}/workspace-attestations"
fi

# --- Hermes default profile (root .hermes) ---
log_info "  Hermes default profile"
for item in .env config.yaml auth.json SOUL.md channel_directory.json gateway_state.json; do
  if [[ -f "${HM_DIR}/${item}" ]]; then
    cp -a "${HM_DIR}/${item}" "${SNAPSHOT_DIR}/hermes-default-${item##*/}"
  fi
done

for dir in cron memories pairing sessions skills state; do
  if [[ -d "${HM_DIR}/${dir}" ]]; then
    cp -a "${HM_DIR}/${dir}" "${SNAPSHOT_DIR}/hermes-default-${dir}"
  fi
done

# --- Hermes databases (using SQLite backup API) ---
for db in "${HM_DIR}/state.db" "${HM_DIR}/projects.db" "${HM_DIR}/kanban.db"; do
  if [[ -f "$db" ]]; then
    dbname=$(basename "$db")
    log_info "  Backing up $dbname via SQLite backup API…"
    sqlite_safe_backup "$db" "${SNAPSHOT_DIR}/hermes-default-${dbname}"
  fi
done

# --- Hermes cron execution DB ---
if [[ -f "${HM_DIR}/cron/executions.db" ]]; then
  sqlite_safe_backup "${HM_DIR}/cron/executions.db" "${SNAPSHOT_DIR}/hermes-default-cron-executions.db"
fi

# --- Hermes profile: coder ---
log_info "  Hermes coder profile"
CODER_DIR="${HM_DIR}/profiles/coder"
if [[ -d "$CODER_DIR" ]]; then
  for item in .env config.yaml auth.json SOUL.md channel_directory.json gateway_state.json profile.yaml; do
    if [[ -f "${CODER_DIR}/${item}" ]]; then
      cp -a "${CODER_DIR}/${item}" "${SNAPSHOT_DIR}/hermes-coder-${item##*/}"
    fi
  done
  for dir in cron memories pairing sessions skills state plans platforms skins workspace home hooks; do
    if [[ -d "${CODER_DIR}/${dir}" ]]; then
      cp -a "${CODER_DIR}/${dir}" "${SNAPSHOT_DIR}/hermes-coder-${dir}"
    fi
  done
  for db in "${CODER_DIR}/state.db" "${CODER_DIR}/projects.db"; do
    if [[ -f "$db" ]]; then
      dbname=$(basename "$db")
      sqlite_safe_backup "$db" "${SNAPSHOT_DIR}/hermes-coder-${dbname}"
    fi
  done
  if [[ -f "${CODER_DIR}/cron/executions.db" ]]; then
    sqlite_safe_backup "${CODER_DIR}/cron/executions.db" "${SNAPSHOT_DIR}/hermes-coder-cron-executions.db"
  fi
fi

# --- Hermes profile: money-maker ---
log_info "  Hermes money-maker profile"
MM_DIR="${HM_DIR}/profiles/money-maker"
if [[ -d "$MM_DIR" ]]; then
  for item in .env config.yaml auth.json SOUL.md channel_directory.json gateway_state.json profile.yaml; do
    if [[ -f "${MM_DIR}/${item}" ]]; then
      cp -a "${MM_DIR}/${item}" "${SNAPSHOT_DIR}/hermes-mm-${item##*/}"
    fi
  done
  for dir in cron memories pairing sessions skills state plans platforms skins workspace home hooks; do
    if [[ -d "${MM_DIR}/${dir}" ]]; then
      cp -a "${MM_DIR}/${dir}" "${SNAPSHOT_DIR}/hermes-mm-${dir}"
    fi
  done
  for db in "${MM_DIR}/state.db" "${MM_DIR}/projects.db"; do
    if [[ -f "$db" ]]; then
      dbname=$(basename "$db")
      sqlite_safe_backup "$db" "${SNAPSHOT_DIR}/hermes-mm-${dbname}"
    fi
  done
  if [[ -f "${MM_DIR}/cron/executions.db" ]]; then
    sqlite_safe_backup "${MM_DIR}/cron/executions.db" "${SNAPSHOT_DIR}/hermes-mm-cron-executions.db"
  fi
fi

# --- Hermes kanban db ---
if [[ -f "${HM_DIR}/kanban.db" ]]; then
  sqlite_safe_backup "${HM_DIR}/kanban.db" "${SNAPSHOT_DIR}/hermes-default-kanban.db"
fi

# -----------------------------------------------------------------------------
# 6.  Explicit exclusions
# -----------------------------------------------------------------------------
log_info "Removing explicitly excluded paths…"
EXCLUDE_PATTERNS=(
  "venv" "node_modules" "npm" "browser" "cache" "logs" "backups"
  "completions" "sandboxes" "webui" "weixin" "openclaw-weixin" "canvas"
  "bin" "home" "audio_cache" "image_cache" "images" "models_dev_cache.json"
  "models_dev_cache*.tmp" "provider_models_cache.json"
  "ollama_cloud_models_cache.json" "context_length_cache.yaml"
  ".skills_prompt_snapshot.json" ".update_check" ".hermes_history"
  "gateway.lock" "gateway.pid" "gateway-starts.log" ".jobs.lock" ".tick.lock"
  "ticker_heartbeat" "ticker_last_success" "processes.json" "auth.lock"
  "feishu_seen_message_ids.json" "hindsight" "plugins" "kanban"
  "*.bak" "*.bak.*" "*.clobbered.*" "*.jsonl.reset.*" "*.jsonl.deleted.*"
  "resume-bot" "weizhen" "openclaw-agent.sqlite.reindex-lock.sqlite"
)

for pat in "${EXCLUDE_PATTERNS[@]}"; do
  find "${SNAPSHOT_DIR}" -name "$pat" -exec rm -rf {} + 2>/dev/null || true
done

# Also remove any -wal and -shm files (we used .backup, not raw copy)
find "${SNAPSHOT_DIR}" -type f \( -name "*-wal" -o -name "*-shm" \) -exec rm -f {} + 2>/dev/null || true

# -----------------------------------------------------------------------------
# 7.  SQLite integrity check on all snapshot DBs
# -----------------------------------------------------------------------------
log_info "Running integrity checks on snapshot databases…"
while IFS= read -r -d '' db; do
  sqlite_integrity_check "$db"
done < <(find "${SNAPSHOT_DIR}" -type f \( -name "*.db" -o -name "*.sqlite" \) -print0)

# -----------------------------------------------------------------------------
# 8.  Generate archive
# -----------------------------------------------------------------------------
log_info "Creating agent-state.tar.zst…"
ARCHIVE_NAME="agent-state.tar.zst"
ARCHIVE_PATH="${WORKDIR}/${ARCHIVE_NAME}"

cd "${SNAPSHOT_DIR}"
tar cf - . | zstd -o "${ARCHIVE_PATH}" || die "Archive creation failed"
cd "${REPO_ROOT}"

# -----------------------------------------------------------------------------
# 9.  Generate checksum
# -----------------------------------------------------------------------------
CHECKSUM_PATH="${ARCHIVE_PATH}.sha256"
sha256_file "${ARCHIVE_PATH}" > "${CHECKSUM_PATH}"

# -----------------------------------------------------------------------------
# 10. File listing and size summary
# -----------------------------------------------------------------------------
log_info "=== Snapshot Summary ==="
log_info "Archive: ${ARCHIVE_PATH}"
log_info "Checksum: ${CHECKSUM_PATH}"
log_info "Archive size: $(du -h "${ARCHIVE_PATH}" | cut -f1)"
log_info "SHA-256: $(cat "${CHECKSUM_PATH}")"
log_info "File count in archive: $(tar -tf "${ARCHIVE_PATH}" | wc -l)"

# List top-level directories in archive (no content)
log_info "Archive contents (top-level):"
tar -tf "${ARCHIVE_PATH}" | head -50

# -----------------------------------------------------------------------------
# 11. Verify archive
# -----------------------------------------------------------------------------
log_info "Verifying archive integrity…"
if ! zstd -t "${ARCHIVE_PATH}" 2>/dev/null; then
  die "Archive verification failed: zstd decompression test failed"
fi

if ! tar -tzf "${ARCHIVE_PATH}" >/dev/null 2>&1; then
  # tar.zst needs pipe
  if ! zstd -d -c "${ARCHIVE_PATH}" | tar tf - >/dev/null 2>&1; then
    die "Archive verification failed: tar listing failed"
  fi
fi

# Verify excluded paths are NOT in archive
log_info "Verifying excluded paths are absent…"
ARCHIVE_LIST="${WORKDIR}/archive-file-list.txt"
zstd -d -c "${ARCHIVE_PATH}" 2>/dev/null | tar tf - > "${ARCHIVE_LIST}" 2>/dev/null || true
for excluded in "resume-bot" "weizhen" "venv/" "node_modules/" ".bak" "-wal" "-shm"; do
  if grep -qi "$excluded" "${ARCHIVE_LIST}" 2>/dev/null; then
    log_warn "Found potentially excluded path in archive: $excluded"
  fi
done
log_info "Archive verification complete"

# -----------------------------------------------------------------------------
# 12. Determine snapshot tag
# -----------------------------------------------------------------------------
if [[ -n "$CUSTOM_TAG" ]]; then
  SNAPSHOT_TAG="$CUSTOM_TAG"
else
  SNAPSHOT_TAG="snapshot-$(date -u +%Y%m%d-%H%M%SZ)"
fi

SNAPSHOT_SHA256=$(cat "${CHECKSUM_PATH}" | awk '{print $1}')

# -----------------------------------------------------------------------------
# 13. Update manifest
# -----------------------------------------------------------------------------
log_info "Updating manifest…"
python3 -c "
import yaml, os
with open('${MANIFEST_FILE}') as f:
    m = yaml.safe_load(f)
m['snapshot_tag'] = '${SNAPSHOT_TAG}'
m['snapshot_filename'] = '${ARCHIVE_NAME}'
m['snapshot_sha256'] = '${SNAPSHOT_SHA256}'
m['created_at'] = '$(date -Iseconds)'
with open('${MANIFEST_FILE}','w') as f:
    yaml.dump(m, f, default_flow_style=False, allow_unicode=True)
" 2>/dev/null || {
  # Fallback if yaml module not available
  sed -i "s/^snapshot_tag:.*/snapshot_tag: ${SNAPSHOT_TAG}/" "${MANIFEST_FILE}"
  sed -i "s/^snapshot_sha256:.*/snapshot_sha256: ${SNAPSHOT_SHA256}/" "${MANIFEST_FILE}"
}

# -----------------------------------------------------------------------------
# 14. Copy archive and checksum to repo root for release upload
# -----------------------------------------------------------------------------
cp "${ARCHIVE_PATH}" "${REPO_ROOT}/"
cp "${CHECKSUM_PATH}" "${REPO_ROOT}/"

# -----------------------------------------------------------------------------
# 15. Create GitHub Release
# -----------------------------------------------------------------------------
log_info "Creating GitHub Release: ${SNAPSHOT_TAG}"

# Create a lightweight tag
git tag -f "${SNAPSHOT_TAG}" 2>/dev/null || true
git push origin "${SNAPSHOT_TAG}" 2>/dev/null || log_warn "Tag push warning (non-fatal)"

# Create the release
gh release create "${SNAPSHOT_TAG}" \
  "${REPO_ROOT}/${ARCHIVE_NAME}" \
  "${REPO_ROOT}/${ARCHIVE_NAME}.sha256" \
  --title "${SNAPSHOT_TAG}" \
  --notes "OpenClaw + Hermes state snapshot
- Host: ${HOST_ID}
- Generation: ${GEN}
- Created: $(date -Iseconds)
- SHA-256: ${SNAPSHOT_SHA256}
- Size: $(du -h "${ARCHIVE_PATH}" | cut -f1)
" \
  --prerelease \
  2>/dev/null || die "Failed to create GitHub Release"

log_info "Release created: ${SNAPSHOT_TAG}"

# -----------------------------------------------------------------------------
# 16. Update active-host.json with snapshot tag
# -----------------------------------------------------------------------------
write_control "{\"snapshot_tag\": \"${SNAPSHOT_TAG}\", \"updated_at\": \"$(date -Iseconds)\"}"

# Commit and push control file update
git add "${CONTROL_FILE}" "${MANIFEST_FILE}" 2>/dev/null || true
git commit -m "chore: update manifest and control after snapshot ${SNAPSHOT_TAG}" 2>/dev/null || true
git push origin main 2>/dev/null || log_warn "Push control update warning (non-fatal)"

# Clean up archive copies from repo root (they're in the release)
rm -f "${REPO_ROOT}/${ARCHIVE_NAME}" "${REPO_ROOT}/${ARCHIVE_NAME}.sha256"

# -----------------------------------------------------------------------------
# 17. Restore gateways (unless keep-stopped for demote.sh)
# -----------------------------------------------------------------------------
if $KEEP_STOPPED; then
  log_info "Gateways kept stopped (--keep-stopped mode)"
else
  restore_running_gateways
fi

log_info "=== Export complete: ${SNAPSHOT_TAG} ==="
