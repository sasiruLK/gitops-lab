#!/bin/bash
set -euo pipefail

K3S_DB="/var/lib/rancher/k3s/server/db/state.db"
BACKUP_DIR="/var/lib/rancher/k3s/server/db/snapshots"
BUCKET_NAME="tinycloud-backups"
NAMESPACE="idzghas4xwzv"
RETENTION_DAYS=7
LOG_FILE="/var/log/tinycloud-backup.log"
OCI="/home/ubuntu/bin/oci --config-file /home/ubuntu/.oci/config"

# Ensure backup dir exists (needs sudo since /var/lib/rancher is root-owned)
sudo mkdir -p "$BACKUP_DIR"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_NAME="k3s-sqlite-${TIMESTAMP}"
BACKUP_FILE="${BACKUP_DIR}/${BACKUP_NAME}.db"

log() {
    echo "[$(date -Iseconds)] $1" | sudo tee -a "$LOG_FILE"
}

log "Starting backup: ${BACKUP_NAME}"

# Create consistent SQLite backup (needs sudo to read k3s DB and write to snapshots)
log "Creating SQLite backup..."
sudo sqlite3 "$K3S_DB" ".backup ${BACKUP_FILE}"

if ! sudo test -f "$BACKUP_FILE"; then
    log "ERROR: Backup file not created"
    exit 1
fi

BACKUP_SIZE=$(sudo stat -c%s "$BACKUP_FILE")
log "SQLite backup created: ${BACKUP_SIZE} bytes"

# Stage backup in temp dir for OCI upload (ubuntu can't traverse /var/lib/rancher/k3s/server)
STAGING_DIR="/tmp/tinycloud-backup-staging"
mkdir -p "$STAGING_DIR"
STAGED_BACKUP="${STAGING_DIR}/$(basename "$BACKUP_FILE")"
sudo cp "$BACKUP_FILE" "$STAGED_BACKUP"
sudo chown "$(id -u):$(id -g)" "$STAGED_BACKUP"

# Also backup gitops-lab manifests
log "Backing up gitops-lab manifests..."
GITOPS_BACKUP="/tmp/gitops-lab-${TIMESTAMP}.tar.gz"
tar -czf "$GITOPS_BACKUP" -C /home/ubuntu gitops-lab 2>/dev/null || log "Warning: Could not backup gitops-lab"

if [[ -f "$GITOPS_BACKUP" ]]; then
    GITOPS_SIZE=$(stat -c%s "$GITOPS_BACKUP")
    log "GitOps backup created: ${GITOPS_SIZE} bytes"
fi

# Upload to OCI Object Storage
log "Uploading to OCI Object Storage..."
export SUPPRESS_LABEL_WARNING=True
export OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING=True

$OCI os object put \
    --namespace-name "$NAMESPACE" \
    --bucket-name "$BUCKET_NAME" \
    --file "$STAGED_BACKUP" \
    --name "sqlite/${BACKUP_NAME}.db" \
    --force 2>&1 | sudo tee -a "$LOG_FILE"

if [[ -f "$GITOPS_BACKUP" ]]; then
    $OCI os object put \
        --namespace-name "$NAMESPACE" \
        --bucket-name "$BUCKET_NAME" \
        --file "$GITOPS_BACKUP" \
        --name "gitops/gitops-lab-${TIMESTAMP}.tar.gz" \
        --force 2>&1 | sudo tee -a "$LOG_FILE"
    rm -f "$GITOPS_BACKUP"
fi

# Push backup success metric to VictoriaMetrics
log "Pushing backup success metric to VictoriaMetrics..."
curl -s -X POST \
  --data-binary "backup_last_success_timestamp_seconds $(date +%s)" \
  "http://150.136.96.152:8428/api/v1/import/prometheus" >/dev/null 2>&1 || log "Warning: Could not push backup metric to VM"

# Clean up local backups older than retention period
log "Cleaning up old local backups..."
sudo find "$BACKUP_DIR" -name "k3s-sqlite-*.db" -type f -mtime +${RETENTION_DAYS} -delete

log "Backup completed successfully"