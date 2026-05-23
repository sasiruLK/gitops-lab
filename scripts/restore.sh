#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# TinyCloud Restore Script
# -----------------------------------------------------------------------------
# Usage: ./scripts/restore.sh <app-name> ["<reason>"]
#
# Example:
#   ./scripts/restore.sh tinycloud-demo "incident resolved, restoring main"
#
# What it does:
#   1. Patches Argo CD Application targetRevision back to 'main'
#   2. Polls Argo CD until the app is Synced and Healthy on main
#   3. Fast-forwards the rollback/<app-name> branch to catch up with main
#   4. Records the restore in rollbacks/rollbacks.yaml
#   5. Commits the tracking file and pushes to origin/main
# -----------------------------------------------------------------------------

set -euo pipefail

APP_NAME="${1:-}"
REASON="${2:-restoring normal update flow}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# ---------------------------------------------------------------------------
# Validate inputs
# ---------------------------------------------------------------------------
if [[ -z "$APP_NAME" ]]; then
    echo "Usage: $0 <app-name> [\"<reason>\"]"
    echo ""
    echo "Example:"
    echo "  $0 tinycloud-demo \"incident resolved, restoring main\""
    exit 1
fi

ensure_app_exists "$APP_NAME"

# ---------------------------------------------------------------------------
# Patch Argo CD Application back to main
# ---------------------------------------------------------------------------
echo "🔄 Restoring '$APP_NAME' to track main branch..."
echo ""

ssh control "sudo kubectl patch application ${APP_NAME} -n argocd --type=merge -p '{\"spec\":{\"source\":{\"targetRevision\":\"main\"}}}'"

# ---------------------------------------------------------------------------
# Wait for sync to main
# ---------------------------------------------------------------------------
echo "⏳ Waiting for Argo CD to sync to main and become healthy..."
wait_for_sync "$APP_NAME"

# ---------------------------------------------------------------------------
# Fast-forward rollback branch to main (cleanup)
# ---------------------------------------------------------------------------
ROLLBACK_BRANCH="rollback/${APP_NAME}"
echo "🧹 Fast-forwarding rollback branch '$ROLLBACK_BRANCH' to main..."
git fetch origin
git branch -f "$ROLLBACK_BRANCH" "origin/main"
git push origin "$ROLLBACK_BRANCH" --force-with-lease

# ---------------------------------------------------------------------------
# Record restore in tracking file
# ---------------------------------------------------------------------------
echo "📝 Recording restore in rollbacks/rollbacks.yaml..."
record_restore "$APP_NAME" "$REASON"

# ---------------------------------------------------------------------------
# Commit tracking file to main
# ---------------------------------------------------------------------------
git add rollbacks/rollbacks.yaml
git commit -m "restore(${APP_NAME}): return to main branch

Restore-Reason: ${REASON}
Restored-By: $(git config user.name || echo 'unknown')
"
git push origin main

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
echo ""
echo "✅ Restore complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "   App:           $APP_NAME"
echo "   Tracking:      main"
echo "   Current Image: $(get_current_image "$APP_NAME")"
echo "   Status:        $(get_app_status "$APP_NAME")"
echo ""
echo "   Test command:"
echo "     curl -H 'Host: app.sasiru.local' http://150.136.8.120:31952"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
