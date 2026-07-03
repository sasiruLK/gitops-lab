#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# TinyCloud Rollback Scripts — Common Library
# -----------------------------------------------------------------------------

set -euo pipefail

GITOPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROLLBACKS_FILE="${GITOPS_DIR}/rollbacks/rollbacks.yaml"
IMAGE_RE='(ghcr\.io|iad\.ocir\.io)/[^[:space:]]*'

# ---------------------------------------------------------------------------
# validate_sha <sha>
#   Ensure the SHA exists in the repo.
# ---------------------------------------------------------------------------
validate_sha() {
    local sha="$1"
    if ! git cat-file -e "${sha}^{commit}" 2>/dev/null; then
        echo "❌ ERROR: SHA '$sha' is not a valid commit in this repository."
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# ensure_app_exists <app-name>
#   Ensure the Argo CD Application CR exists in the cluster.
# ---------------------------------------------------------------------------
ensure_app_exists() {
    local app="$1"
    if ! ssh control "sudo kubectl get application ${app} -n argocd" >/dev/null 2>&1; then
        echo "❌ ERROR: Argo CD Application '$app' not found in namespace 'argocd'."
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# get_current_image <app-name>
#   Extract the current deployed image from the sidecar file in the
#   working tree (or from origin/main if working tree is dirty).
# ---------------------------------------------------------------------------
get_current_image() {
    local app="$1"
    local sidecar="apps/${app}/.argocd-source-${app}.yaml"
    if [[ -f "${GITOPS_DIR}/${sidecar}" ]]; then
        grep -Eo "$IMAGE_RE" "${GITOPS_DIR}/${sidecar}" | head -1 || true
    else
        git show "origin/main:${sidecar}" 2>/dev/null | grep -Eo "$IMAGE_RE" | head -1 || true
    fi
}

# ---------------------------------------------------------------------------
# get_image_at_sha <app-name> <sha>
#   Extract the image that was deployed at a specific git SHA.
# ---------------------------------------------------------------------------
get_image_at_sha() {
    local app="$1"
    local sha="$2"
    local sidecar="apps/${app}/.argocd-source-${app}.yaml"
    git show "${sha}:${sidecar}" 2>/dev/null | grep -Eo "$IMAGE_RE" | head -1 || true
}

# ---------------------------------------------------------------------------
# get_app_status <app-name>
#   Returns "Synced Healthy" or error message.
# ---------------------------------------------------------------------------
get_app_status() {
    local app="$1"
    ssh control "sudo kubectl get application ${app} -n argocd -o jsonpath='{.status.sync.status} {.status.health.status}'" 2>/dev/null || echo "unknown"
}

# ---------------------------------------------------------------------------
# wait_for_sync <app-name> [timeout-seconds]
#   Poll Argo CD until the app is Synced and Healthy.
#   Default timeout: 300 seconds (5 minutes).
# ---------------------------------------------------------------------------
wait_for_sync() {
    local app="$1"
    local timeout="${2:-300}"
    local elapsed=0
    local interval=5

    echo "   Polling every ${interval}s (max ${timeout}s)..."

    while true; do
        local status
        status="$(ssh control "sudo kubectl get application ${app} -n argocd -o jsonpath='{.status.sync.status} {.status.health.status}'" 2>/dev/null || echo "Unknown Unknown")"

        if [[ "$status" == "Synced Healthy" ]]; then
            echo "   ✅ Application is Synced and Healthy."
            return 0
        fi

        if (( elapsed >= timeout )); then
            echo ""
            echo "❌ ERROR: Timeout after ${timeout}s. Application status: $status"
            echo "   Check Argo CD UI or logs for details."
            exit 1
        fi

        printf "   ... status: %s (elapsed %ds)\n" "$status" "$elapsed"
        sleep "$interval"
        ((elapsed += interval))
    done
}

# ---------------------------------------------------------------------------
# record_rollback <app> <target-sha> <reason> <branch> <from-sha> <from-image> <to-image>
#   Append a rollback record to rollbacks/rollbacks.yaml.
# ---------------------------------------------------------------------------
record_rollback() {
    local app="$1"
    local target_sha="$2"
    local reason="$3"
    local branch="$4"
    local from_sha="$5"
    local from_image="$6"
    local to_image="$7"
    local timestamp
    timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    local id="rb-${app}-$(date -u +"%Y%m%d-%H%M%S")"

    # Use Python to safely mutate YAML (avoids fragile sed/awk)
    python3 -c '
import yaml, sys

file_path = sys.argv[1]
app = sys.argv[11]
record = {
    "id": sys.argv[2],
    "type": "rollback",
    "timestamp": sys.argv[3],
    "targetRevision": sys.argv[4],
    "targetImage": sys.argv[7],
    "previousRevision": sys.argv[5],
    "previousImage": sys.argv[6],
    "reason": sys.argv[8],
    "rollbackBranch": sys.argv[9],
    "initiatedBy": sys.argv[10],
}

with open(file_path, "r") as f:
    data = yaml.safe_load(f)

# Ensure nested keys exist
if "apps" not in data:
    data["apps"] = {}
if app not in data["apps"]:
    data["apps"][app] = {"currentStatus": "normal", "activeRollback": None, "history": []}

app_data = data["apps"][app]
app_data["currentStatus"] = "rollback"
app_data["activeRollback"] = record["id"]
app_data["history"].append(record)

with open(file_path, "w") as f:
    yaml.dump(data, f, default_flow_style=False, sort_keys=False)
' "$ROLLBACKS_FILE" "$id" "$timestamp" "$target_sha" "$from_sha" "$from_image" "$to_image" "$reason" "$branch" "$(git config user.name || echo 'unknown')" "$app"
}

# ---------------------------------------------------------------------------
# record_restore <app> <reason>
#   Append a restore record to rollbacks/rollbacks.yaml.
# ---------------------------------------------------------------------------
record_restore() {
    local app="$1"
    local reason="$2"
    local timestamp
    timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    local id="rs-${app}-$(date -u +"%Y%m%d-%H%M%S")"
    local current_sha
    current_sha="$(git rev-parse origin/main)"
    local current_image
    current_image="$(get_current_image "$app")"

    python3 -c '
import yaml, sys

file_path = sys.argv[1]
record = {
    "id": sys.argv[2],
    "type": "restore",
    "timestamp": sys.argv[3],
    "restoredToRevision": sys.argv[4],
    "restoredToImage": sys.argv[5],
    "reason": sys.argv[6],
    "initiatedBy": sys.argv[7],
}

with open(file_path, "r") as f:
    data = yaml.safe_load(f)

app_data = data["apps"][sys.argv[8]]
app_data["currentStatus"] = "normal"
app_data["activeRollback"] = None
app_data["history"].append(record)

with open(file_path, "w") as f:
    yaml.dump(data, f, default_flow_style=False, sort_keys=False)
' "$ROLLBACKS_FILE" "$id" "$timestamp" "$current_sha" "$current_image" "$reason" "$(git config user.name || echo 'unknown')" "$app"
}
