#!/bin/bash
set -euo pipefail

K3S_DB="/var/lib/rancher/k3s/server/db/state.db"
BACKUP_DIR="/var/lib/rancher/k3s/server/db/snapshots"
BUCKET_NAME="tinycloud-backups"
NAMESPACE="idzghas4xwzv"
RETENTION_DAYS=7
LOG_FILE="/var/log/tinycloud-backup.log"
OCI="/home/ubuntu/bin/oci --config-file /home/ubuntu/.oci/config"

mkdir -p "$BACKUP_DIR"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_NAME="k3s-sqlite-${TIMESTAMP}"
BACKUP_FILE="${BACKUP_DIR}/${BACKUP_NAME}.db"

echo "[$(date -Iseconds)] Starting backup: ${BACKUP_NAME}" | tee -a "$LOG_FILE"

# Create consistent SQLite backup
echo "[$(date -Iseconds)] Creating SQLite backup..." | tee -a "$LOG_FILE"
sqlite3 "$K3S_DB" ".backup ${BACKUP_FILE}"

if [[ ! -f "$BACKUP_FILE" ]]; then
    echo "[$(date -Iseconds)] ERROR: Backup file not created" | tee -a "$LOG_FILE"
    exit 1
fi

# Also backup gitops-lab manifests
echo "[$(date -Iseconds)] Backing up gitops-lab manifests..." | tee -a "$LOG_FILE"
GITOPS_BACKUP="/tmp/gitops-lab-${TIMESTAMP}.tar.gz"
tar -czf "$GITOPS_BACKUP" -C /home/ubuntu gitops-lab 2>/dev/null || echo "[$(date -Iseconds)] Warning: Could not backup gitops-lab" | tee -a "$LOG_FILE"

# Upload to OCI Object Storage
echo "[$(date -Iseconds)] Uploading to OCI Object Storage..." | tee -a "$LOG_FILE"
export SUPPRESS_LABEL_WARNING=True
export OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING=True

$OCI os object put \
    --namespace-name "$NAMESPACE" \
    --bucket-name "$BUCKET_NAME" \
    --file "$BACKUP_FILE" \
    --name "sqlite/${BACKUP_NAME}.db" \
    --force 2>&1 | tee -a "$LOG_FILE"

if [[ -f "$GITOPS_BACKUP" ]]; then
    $OCI os object put \
        --namespace-name "$NAMESPACE" \
        --bucket-name "$BUCKET_NAME" \
        --file "$GITOPS_BACKUP" \
        --name "gitops/gitops-lab-${TIMESTAMP}.tar.gz" \
        --force 2>&1 | tee -a "$LOG_FILE"
    rm -f "$GITOPS_BACKUP"
fi

# Clean up local backups older than retention period
echo "[$(date -Iseconds)] Cleaning up old local backups..." | tee -a "$LOG_FILE"
find "$BACKUP_DIR" -name "k3s-sqlite-*.db" -type f -mtime +${RETENTION_DAYS} -delete

echo "[$(date -Iseconds)] Backup completed successfully" | tee -a "$LOG_FILE"
