#!/bin/bash
set -euo pipefail

# =============================================================================
# TinyCloud Backup Validation Script
# =============================================================================
# This script validates that backups are present, fresh, and restorable.
# It does NOT restore data to production — it only validates in a temp directory.
#
# Run manually:     /opt/tinycloud/backup/validate.sh
# Run via cron:     30 3 * * * /opt/tinycloud/backup/validate.sh
# =============================================================================

BUCKET_NAME="tinycloud-backups"
NAMESPACE="idzghas4xwzv"
OCI="/home/ubuntu/bin/oci --config-file /home/ubuntu/.oci/config"
VALIDATION_LOG="/var/log/tinycloud-backup-validation.log"
TEMP_DIR=$(mktemp -d /tmp/tinycloud-backup-validation.XXXXXX)

# Ensure log file is writable
sudo touch "$VALIDATION_LOG" 2>/dev/null || true
sudo chown "$(id -u):$(id -g)" "$VALIDATION_LOG" 2>/dev/null || true

# Cleanup temp dir on exit
trap 'rm -rf "$TEMP_DIR"' EXIT

# Threshold: backup must be newer than this many hours
MAX_AGE_HOURS=25

ERRORS=0
WARNINGS=0

log() {
    echo "[$(date -Iseconds)] $1" | sudo tee -a "$VALIDATION_LOG"
}

error() {
    log "ERROR: $1"
    ((ERRORS++)) || true
}

warn() {
    log "WARNING: $1"
    ((WARNINGS++)) || true
}

pass() {
    log "PASS: $1"
}

# =============================================================================
# 1. List recent backups in OCI Object Storage
# =============================================================================
log "=== TinyCloud Backup Validation Started ==="
log "Checking OCI Object Storage bucket: ${BUCKET_NAME}"

# Get latest SQLite backup
SQLITE_LIST=$($OCI os object list \
    --namespace-name "$NAMESPACE" \
    --bucket-name "$BUCKET_NAME" \
    --prefix "sqlite/" \
    --limit 20 2>/dev/null) || {
    error "Failed to list SQLite backups from OCI"
    exit 1
}

LATEST_SQLITE=$(echo "$SQLITE_LIST" | python3 -c "
import sys, json
data = json.load(sys.stdin).get('data', [])
if data:
    # Sort by time-created descending
    data.sort(key=lambda x: x['time-created'], reverse=True)
    print(data[0]['name'])
" 2>/dev/null)

if [[ -z "$LATEST_SQLITE" ]]; then
    error "No SQLite backups found in OCI bucket"
    exit 1
fi

LATEST_SQLITE_TIME=$(echo "$SQLITE_LIST" | python3 -c "
import sys, json
data = json.load(sys.stdin).get('data', [])
if data:
    data.sort(key=lambda x: x['time-created'], reverse=True)
    print(data[0]['time-created'])
" 2>/dev/null)

pass "Found latest SQLite backup: ${LATEST_SQLITE} (created: ${LATEST_SQLITE_TIME})"

# Get latest GitOps backup
GITOPS_LIST=$($OCI os object list \
    --namespace-name "$NAMESPACE" \
    --bucket-name "$BUCKET_NAME" \
    --prefix "gitops/" \
    --limit 20 2>/dev/null) || {
    error "Failed to list GitOps backups from OCI"
    exit 1
}

LATEST_GITOPS=$(echo "$GITOPS_LIST" | python3 -c "
import sys, json
data = json.load(sys.stdin).get('data', [])
if data:
    data.sort(key=lambda x: x['time-created'], reverse=True)
    print(data[0]['name'])
" 2>/dev/null)

if [[ -z "$LATEST_GITOPS" ]]; then
    warn "No GitOps backups found in OCI bucket"
else
    LATEST_GITOPS_TIME=$(echo "$GITOPS_LIST" | python3 -c "
import sys, json
data = json.load(sys.stdin).get('data', [])
if data:
    data.sort(key=lambda x: x['time-created'], reverse=True)
    print(data[0]['time-created'])
" 2>/dev/null)
    pass "Found latest GitOps backup: ${LATEST_GITOPS} (created: ${LATEST_GITOPS_TIME})"
fi

# =============================================================================
# 2. Check backup freshness
# =============================================================================
log "Checking backup freshness (max age: ${MAX_AGE_HOURS}h)..."

NOW_EPOCH=$(date +%s)
# Parse OCI timestamp: 2026-05-23T10:53:03.300000+00:00 → convert to epoch
SQLITE_EPOCH=$(date -d "${LATEST_SQLITE_TIME}" +%s 2>/dev/null || echo 0)

if [[ "$SQLITE_EPOCH" -eq 0 ]]; then
    error "Could not parse SQLite backup timestamp"
else
    AGE_HOURS=$(( (NOW_EPOCH - SQLITE_EPOCH) / 3600 ))
    if [[ "$AGE_HOURS" -gt "$MAX_AGE_HOURS" ]]; then
        error "SQLite backup is ${AGE_HOURS}h old (max allowed: ${MAX_AGE_HOURS}h)"
    else
        pass "SQLite backup is ${AGE_HOURS}h old (within ${MAX_AGE_HOURS}h threshold)"
    fi
fi

if [[ -n "$LATEST_GITOPS" ]]; then
    GITOPS_EPOCH=$(date -d "${LATEST_GITOPS_TIME}" +%s 2>/dev/null || echo 0)
    if [[ "$GITOPS_EPOCH" -eq 0 ]]; then
        error "Could not parse GitOps backup timestamp"
    else
        AGE_HOURS=$(( (NOW_EPOCH - GITOPS_EPOCH) / 3600 ))
        if [[ "$AGE_HOURS" -gt "$MAX_AGE_HOURS" ]]; then
            error "GitOps backup is ${AGE_HOURS}h old (max allowed: ${MAX_AGE_HOURS}h)"
        else
            pass "GitOps backup is ${AGE_HOURS}h old (within ${MAX_AGE_HOURS}h threshold)"
        fi
    fi
fi

# =============================================================================
# 3. Download and validate SQLite backup
# =============================================================================
log "Downloading SQLite backup for integrity check..."
SQLITE_LOCAL="${TEMP_DIR}/$(basename "$LATEST_SQLITE")"

$OCI os object get \
    --namespace-name "$NAMESPACE" \
    --bucket-name "$BUCKET_NAME" \
    --name "$LATEST_SQLITE" \
    --file "$SQLITE_LOCAL" 2>/dev/null || {
    error "Failed to download SQLite backup from OCI"
    exit 1
}

pass "Downloaded SQLite backup: $(stat -c%s "$SQLITE_LOCAL") bytes"

# Check SQLite header magic bytes
SQLITE_HEADER=$(xxd -l 16 "$SQLITE_LOCAL" 2>/dev/null | head -1)
if [[ "$SQLITE_HEADER" == *"SQLite format 3"* ]]; then
    pass "SQLite header signature valid"
else
    error "SQLite header signature invalid — file may be corrupted"
fi

# Run SQLite integrity check
log "Running SQLite PRAGMA integrity_check..."
INTEGRITY_RESULT=$(sqlite3 "$SQLITE_LOCAL" "PRAGMA integrity_check;" 2>/dev/null) || {
    error "SQLite integrity_check command failed"
    INTEGRITY_RESULT="ERROR"
}

if [[ "$INTEGRITY_RESULT" == "ok" ]]; then
    pass "SQLite PRAGMA integrity_check: ok"
else
    error "SQLite PRAGMA integrity_check failed: ${INTEGRITY_RESULT}"
fi

# Check for expected k3s tables
log "Checking for expected k3s tables..."
EXPECTED_TABLES=("kine" "sqlite_sequence")
for table in "${EXPECTED_TABLES[@]}"; do
    TABLE_COUNT=$(sqlite3 "$SQLITE_LOCAL" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='${table}';" 2>/dev/null || echo 0)
    if [[ "$TABLE_COUNT" -gt 0 ]]; then
        pass "Expected table found: ${table}"
    else
        warn "Expected table missing: ${table}"
    fi
done

# =============================================================================
# 4. Download and validate GitOps tarball
# =============================================================================
if [[ -n "$LATEST_GITOPS" ]]; then
    log "Downloading GitOps backup for integrity check..."
    GITOPS_LOCAL="${TEMP_DIR}/$(basename "$LATEST_GITOPS")"

    $OCI os object get \
        --namespace-name "$NAMESPACE" \
        --bucket-name "$BUCKET_NAME" \
        --name "$LATEST_GITOPS" \
        --file "$GITOPS_LOCAL" 2>/dev/null || {
        error "Failed to download GitOps backup from OCI"
    }

    if [[ -f "$GITOPS_LOCAL" ]]; then
        pass "Downloaded GitOps backup: $(stat -c%s "$GITOPS_LOCAL") bytes"

        # Test tarball integrity
        if tar -tzf "$GITOPS_LOCAL" >/dev/null 2>&1; then
            pass "GitOps tarball integrity: valid"
        else
            error "GitOps tarball is corrupted or incomplete"
        fi

        # Check for expected top-level files
        TOP_FILES=$(tar -tzf "$GITOPS_LOCAL" | head -n 5)
        if echo "$TOP_FILES" | grep -q "gitops-lab/"; then
            pass "GitOps backup contains expected 'gitops-lab/' directory"
        else
            warn "GitOps backup may be missing expected directory structure"
        fi
    fi
else
    warn "Skipping GitOps backup validation — no backup found"
fi

# =============================================================================
# 5. Summary
# =============================================================================
log "=== Validation Summary ==="
log "Errors:   ${ERRORS}"
log "Warnings: ${WARNINGS}"

if [[ "$ERRORS" -eq 0 ]]; then
    log "RESULT: PASS — All backup validations passed"
    exit 0
else
    log "RESULT: FAIL — Backup validation failed with ${ERRORS} error(s)"
    exit 1
fi