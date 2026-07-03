# TinyCloud GitOps Rollback System

> GitOps-native rollback for the TinyCloud platform.
> Every change goes through Git. Nothing is done via `kubectl set image`.

---

## 1. Architecture Overview

### The Problem

With Argo CD Image Updater continuously writing `.argocd-source-*.yaml` to `main`, a simple `git revert` of an auto-update commit is fragile — Image Updater will likely re-apply the newer image on its next cycle.

### The Solution: Branch Isolation

Instead of reverting commits on `main`, we **create a rollback branch** pinned at a known-good commit and **point Argo CD at that branch**.

```
Normal Flow:
  main ──●────●────●────●────●────►  (Image Updater writes here)
         ↑
      Argo CD tracks main

Rollback Flow:
  main ──●────●────●────●────●────►  (Image Updater keeps writing here — ignored)
         ↑
         └── rollback/tinycloud-demo  (Argo CD tracks this branch)
```

**Image Updater is never paused.** It continues its normal job on `main`. Argo CD simply stops looking at `main` during the rollback.

---

## 2. Rollback Methods Compared

| Method | How It Works | Pros | Cons | Verdict |
|--------|--------------|------|------|---------|
| **Git revert** | Revert the auto-update commit on `main` | Simple, preserves history | Reverts ALL changes in that commit; Image Updater may re-apply on next cycle | ❌ Fragile for automated repos |
| **Manual SHA edit** | Edit `kustomization.yaml` or sidecar directly | Precise control | Bypasses sidecar; Image Updater overrides on next cycle unless paused | ❌ Requires pausing automation |
| **Argo CD UI rollback** | Click "Rollback" in Argo CD UI | Fast, one click | **Bypasses Git** — creates live state drift from repo; not reproducible | ❌ Never use in production |
| **Branch isolation** (ours) | Create `rollback/<app>` branch, point Argo CD at it | GitOps-native, no pausing, audit trail, fully reversible | Requires branch management | ✅ **Recommended** |

---

## 3. How It Works with Image Updater

Image Updater's sole job is to:
1. Poll OCIR for new SHA tags
2. Write `.argocd-source-*.yaml` to the branch configured in `writeBackConfig.gitConfig.branch` (`main`)
3. Push the commit

With branch isolation:
- Image Updater keeps doing its job on `main`
- Argo CD Application `targetRevision` points to `rollback/<app>`
- Argo CD syncs from the rollback branch, ignoring new commits on `main`
- When ready, restore by pointing `targetRevision` back to `main`

**No pause mechanism is required.** This is the key design win.

---

## 4. How to Pause Image Updater (If Ever Needed)

Although our architecture avoids pausing, here are three ways to do it:

### 4.1 Scale Controller to Zero (Global Pause)
```bash
kubectl scale deployment argocd-image-updater-controller -n argocd --replicas=0
# Resume:
kubectl scale deployment argocd-image-updater-controller -n argocd --replicas=1
```

### 4.2 Change Write-Back Method to `none` (Per-CR Pause)
```bash
kubectl patch imageupdater tinycloud-demo -n argocd --type=merge -p \
  '{"spec":{"writeBackConfig":{"method":"none"}}}'
```

### 4.3 Pin `imageName` to Exact SHA in ImageUpdater CR
```yaml
images:
  - alias: tinycloud
    imageName: iad.ocir.io/idzghas4xwzv/tinycloud/tinycloud-demo-app:999274c96e8315e4556f910aff30a081486f0cda
```
Image Updater sees this as "already current" and stops proposing updates.

---

## 5. Scripts Reference

### 5.1 Rollback

```bash
./scripts/rollback.sh <app-name> <target-git-sha> "<reason>"
```

**Example:**
```bash
./scripts/rollback.sh tinycloud-demo a948f7fed3fedceccdfb52dc94dbc2d509a8aaa4 \
  "performance regression in v4"
```

**What it does:**
1. Validates the target SHA exists in the repo
2. Creates/updates `rollback/tinycloud-demo` branch at target SHA
3. Patches Argo CD Application `targetRevision` → `rollback/tinycloud-demo`
4. Waits for `Synced` + `Healthy`
5. Records rollback in `rollbacks/rollbacks.yaml`
6. Commits and pushes tracking file to `main`

### 5.2 Restore

```bash
./scripts/restore.sh <app-name> ["<reason>"]
```

**Example:**
```bash
./scripts/restore.sh tinycloud-demo "incident resolved, restoring main"
```

**What it does:**
1. Patches Argo CD Application `targetRevision` → `main`
2. Waits for `Synced` + `Healthy` on `main`
3. Fast-forwards `rollback/tinycloud-demo` branch to `main` (cleanup)
4. Records restore in `rollbacks/rollbacks.yaml`
5. Commits and pushes tracking file to `main`

---

## 6. Git Commands Reference

### Create Rollback Branch Manually
```bash
git fetch origin
git branch rollback/tinycloud-demo a948f7fed3fedceccdfb52dc94dbc2d509a8aaa4
git push origin rollback/tinycloud-demo --force-with-lease
```

### Point Argo CD to Rollback Branch
```bash
kubectl patch application tinycloud-demo -n argocd --type=merge -p \
  '{"spec":{"source":{"targetRevision":"rollback/tinycloud-demo"}}}'
```

### Restore to Main
```bash
kubectl patch application tinycloud-demo -n argocd --type=merge -p \
  '{"spec":{"source":{"targetRevision":"main"}}}'
```

### View Rollback History
```bash
git log --grep="rollback(" --oneline --all
git log --grep="restore(" --oneline --all
```

### Inspect Image at a Specific Commit
```bash
git show a948f7f:apps/tinycloud-demo/.argocd-source-tinycloud-demo.yaml
```

---

## 7. Kubernetes / Argo CD Commands Reference

### Check Application Status
```bash
kubectl get application tinycloud-demo -n argocd -o jsonpath='{.status.sync.status} {.status.health.status}'
```

### Watch Application
```bash
kubectl get application tinycloud-demo -n argocd -w
```

### Get Deployment History
```bash
kubectl get application tinycloud-demo -n argocd -o json | \
  jq -r '.status.history[] | "\(.revision) \(.deployedAt)"' | head -10
```

### Check Pods
```bash
kubectl get pods -n demo -o wide
```

### Test App Response
```bash
curl -H "Host: app.sasiru.local" http://150.136.8.120:31952
```

### Force Refresh (if auto-sync seems stuck)
```bash
kubectl patch application tinycloud-demo -n argocd --type=merge -p \
  '{"operation":{"sync":{"revision":"HEAD","prune":true}}}'
```

---

## 8. Scaling to Multiple Apps

The scripts and pattern are parameterized by `<app-name>`:

```bash
./scripts/rollback.sh nginx-demo 7fcf7a4 "revert nginx config change"
./scripts/rollback.sh api-gateway abc1234 "bad deployment"
```

Each app gets:
- `rollback/<app-name>` branch
- Entry in `rollbacks/rollbacks.yaml`
- Independent lifecycle

### Platform-Wide Rollback (App of Apps)

If you use an **App of Apps** pattern:

```bash
# Parent application tracks rollback/platform
git branch rollback/platform a948f7f
git push origin rollback/platform --force-with-lease
kubectl patch application platform-apps -n argocd --type=merge -p \
  '{"spec":{"source":{"targetRevision":"rollback/platform"}}}'
```

All child apps follow automatically.

---

## 9. Best Practices (Platform Engineering)

1. **Never `kubectl set image`** — violates GitOps; no audit trail.
2. **Never use Argo CD UI rollback in production** — creates live state drift from Git.
3. **Use immutable SHA tags** — already doing this ✅.
4. **Branch isolation for rollbacks** — separates automated updates from operator decisions.
5. **Tag known-good releases** — `git tag release/tinycloud-demo/v1.2.3 <sha>`.
6. **Require PRs for rollback branch merges back to main** — prevents accidental re-introduction of bad code.
7. **Test rollbacks in CI** — chaos engineering: periodically rollback staging and verify.
8. **Monitor rollback duration** — time from trigger to healthy pods is a key SLO.
9. **RBAC on rollback branches** — protect `rollback/*` branches from force-push by unauthorized users.
10. **Auto-cleanup old rollback branches** — delete after 30 days via CI cron job.

---

## 10. Rollback History Visibility

The `rollbacks/rollbacks.yaml` file is the single source of truth for rollback history.

### Current Structure
```yaml
apps:
  tinycloud-demo:
    currentStatus: normal        # normal | rollback
    activeRollback: null           # null or active rollback ID
    history:
      - id: rb-tinycloud-demo-20260523-101500
        type: rollback
        timestamp: "2026-05-23T10:15:00Z"
        targetRevision: a948f7f...
        targetImage: iad.ocir.io/idzghas4xwzv/tinycloud/tinycloud-demo-app:a948f7f...
        previousRevision: 89d78fd...
        previousImage: iad.ocir.io/idzghas4xwzv/tinycloud/tinycloud-demo-app:999274c...
        reason: "performance regression in v4"
        rollbackBranch: rollback/tinycloud-demo
        initiatedBy: sasiru
      - id: rs-tinycloud-demo-20260523-110000
        type: restore
        timestamp: "2026-05-23T11:00:00Z"
        restoredToRevision: 0955600...
        restoredToImage: iad.ocir.io/idzghas4xwzv/tinycloud/tinycloud-demo-app:a5fc640...
        reason: "incident resolved"
        initiatedBy: sasiru
```

### Future Dashboard / API Integration

A future TinyCloud dashboard or API can simply:
1. Read `rollbacks/rollbacks.yaml` from the GitOps repo
2. Render history tables
3. Expose `POST /apps/{name}/rollback` which calls `scripts/rollback.sh`
4. Expose `POST /apps/{name}/restore` which calls `scripts/restore.sh`

See `docs/api/rollback-api.md` for the full API design.

---

## 11. Troubleshooting

### Image Updater still proposes updates during rollback
Expected. It writes to `main`, but Argo CD is tracking `rollback/<app>`. The updates are harmless and ignored.

### Rollback branch doesn't exist
The script creates it with `git branch -f`. If creation fails, check SSH keys and push permissions.

### Argo CD doesn't auto-sync to rollback branch
Argo CD may take up to 3 minutes to detect the branch change. Use `kubectl patch application ... --type=merge -p '{"operation":{"sync":...}}'` to force it.

### App stays "Progressing" after rollback
Check pod events: `kubectl describe pod -n demo <pod-name>`. Common issues: image pull backoff (check `ocir-creds` secret) or ARM64 platform mismatch.

---

*Last updated: 2026-05-23*
