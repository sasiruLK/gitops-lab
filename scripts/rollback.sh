#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# TinyCloud Rollback Script
# -----------------------------------------------------------------------------
# Usage: ./scripts/rollback.sh <app-name> <target-git-sha> "<reason>"
#
# Example:
#   ./scripts/rollback.sh tinycloud-demo a948f7f "performance regression in v4"
#
# What it does:
#   1. Validates the target SHA exists in the repo
#   2. Creates (or force-updates) rollback/<app-name> branch at target SHA
#   3. Patches Argo CD Application targetRevision to the rollback branch
#   4. Polls Argo CD until the app is Synced and Healthy
#   5. Records the rollback in rollbacks/rollbacks.yaml
#   6. Commits the tracking file and pushes to origin/main
# -----------------------------------------------------------------------------

set -euo pipefail

APP_NAME="${1:-}"
TARGET_SHA="${2:-}"
REASON="${3:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# ---------------------------------------------------------------------------
# Validate inputs
# ---------------------------------------------------------------------------
if [[ -z "$APP_NAME" || -z "$TARGET_SHA" || -z "$REASON" ]]; then
    echo "Usage: $0 <app-name> <target-git-sha> \"<reason>\""
    echo ""
    echo "Example:"
    echo "  $0 tinycloud-demo a948f7fed3fedceccdfb52dc94dbc2d509a8aaa4 \"performance regression in v4\""
    exit 1
fi

validate_sha "$TARGET_SHA"
ensure_app_exists "$APP_NAME"

# ---------------------------------------------------------------------------
# Gather current state before rollback
# ---------------------------------------------------------------------------
echo "🔄 Initiating rollback for '$APP_NAME'..."
echo ""

CURRENT_GIT_SHA="$(git rev-parse origin/main)"
CURRENT_IMAGE="$(get_current_image "$APP_NAME")"
TARGET_IMAGE="$(get_image_at_sha "$APP_NAME" "$TARGET_SHA")"
ROLLBACK_BRANCH="rollback/${APP_NAME}"

if [[ -z "$TARGET_IMAGE" ]]; then
    echo "❌ ERROR: Could not determine image at SHA '$TARGET_SHA'."
    echo "   Ensure the target commit has a valid .argocd-source-*.yaml file."
    exit 1
fi

# ---------------------------------------------------------------------------
# Create / force-update rollback branch
# ---------------------------------------------------------------------------
echo "📦 Creating rollback branch '$ROLLBACK_BRANCH' at $TARGET_SHA..."
git fetch origin
git branch -f "$ROLLBACK_BRANCH" "$TARGET_SHA"
git push origin "$ROLLBACK_BRANCH" --force-with-lease

# ---------------------------------------------------------------------------
# Patch Argo CD Application to track rollback branch
# ---------------------------------------------------------------------------
echo "🎯 Patching Argo CD Application '$APP_NAME' to track '$ROLLBACK_BRANCH'..."
ssh control "sudo kubectl patch application ${APP_NAME} -n argocd --type=merge -p '{\"spec\":{\"source\":{\"targetRevision\":\"${ROLLBACK_BRANCH}\"}}}'"

# ---------------------------------------------------------------------------
# Wait for sync
# ---------------------------------------------------------------------------
echo "⏳ Waiting for Argo CD to sync and become healthy..."
wait_for_sync "$APP_NAME"

# ---------------------------------------------------------------------------
# Record rollback in tracking file
# ---------------------------------------------------------------------------
echo "📝 Recording rollback in rollbacks/rollbacks.yaml..."
record_rollback "$APP_NAME" "$TARGET_SHA" "$REASON" "$ROLLBACK_BRANCH" "$CURRENT_GIT_SHA" "$CURRENT_IMAGE" "$TARGET_IMAGE"

# ---------------------------------------------------------------------------
# Commit tracking file to main
# ---------------------------------------------------------------------------
git add rollbacks/rollbacks.yaml
git commit -m "rollback(${APP_NAME}): revert to ${TARGET_SHA:0:7}

Rollback-From: ${CURRENT_GIT_SHA}
Rollback-From-Image: ${CURRENT_IMAGE}
Rollback-To: ${TARGET_SHA}
Rollback-To-Image: ${TARGET_IMAGE}
Rollback-Reason: ${REASON}
Rollback-Branch: ${ROLLBACK_BRANCH}
Rollback-By: $(git config user.name || echo 'unknown')
"
git push origin main

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
echo ""
echo "✅ Rollback complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "   App:           $APP_NAME"
echo "   Branch:        $ROLLBACK_BRANCH"
echo "   Target SHA:    $TARGET_SHA"
echo "   Target Image:  $TARGET_IMAGE"
echo "   Status:        $(get_app_status "$APP_NAME")"
echo ""
echo "   Test command:"
echo "     curl -H 'Host: app.sasiru.local' http://150.136.8.120:31952"
echo ""
echo "   To restore normal flow, run:"
echo "     ./scripts/restore.sh $APP_NAME"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
