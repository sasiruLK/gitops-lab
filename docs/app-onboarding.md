# App Onboarding Guide

Self-service app onboarding via TinyCloud Platform (Phase 4).

## Prerequisites

1. **Container image already exists** in GHCR (or another registry TinyCloud can pull from)
2. **GitHub PAT** on the API with write access to `gitops-lab`
3. **Argo CD ApplicationSet controller** running (`applicationsets.argoproj.io` CRD)
4. **`ghcr-creds` secret** in the app namespace (see below)

## How It Works

```
POST /v1/apps  →  API validates + generates manifests  →  Git commit
                                                              ↓
ApplicationSet detects apps/{name}/  →  Argo CD Application  →  sync
                                                              ↓
nginx-proxy routes /apps/{name}/  →  {name}.{name}.svc:80
```

**Architectural rule:** Git is the source of truth. ApplicationSet owns Applications. The API only validates and commits to Git.

## Conventions

| Field | Value |
|-------|-------|
| App name | DNS-1123, max 63 chars |
| Namespace | Same as app name |
| Service | Same as app name, port 80 → container port |
| Public URL | `https://tinycloud-platform.duckdns.org/apps/{name}/` |
| Image tags | Semver for user apps (`1.0.0`, `v1.2.3`) |

## API Usage

```bash
curl -X POST https://tinycloud-platform.duckdns.org/api/v1/apps \
  -H "Content-Type: application/json" \
  -d '{
    "name": "my-app",
    "image": "ghcr.io/user/my-app",
    "tag": "1.0.0",
    "replicas": 2,
    "port": 8080
  }'
```

Response:

```json
{
  "data": {
    "name": "my-app",
    "url": "https://tinycloud-platform.duckdns.org/apps/my-app/",
    "repo": "gitops-lab",
    "path": "apps/my-app",
    "status": "pending_gitops_sync"
  }
}
```

Poll `GET /v1/apps/my-app` until the ApplicationSet creates the Argo CD Application (typically 1–2 minutes).

## Image Pull Secret (MVP Manual Step)

After Argo CD creates the app namespace, copy `ghcr-creds` from `argocd`:

```bash
kubectl get secret ghcr-creds -n argocd -o yaml \
  | sed 's/namespace: argocd/namespace: MY-APP/' \
  | kubectl apply -f -
```

**Phase 5+:** Kyverno policy to auto-replicate `ghcr-creds` into app namespaces.

## Suspend an App

```bash
curl -X POST https://tinycloud-platform.duckdns.org/api/v1/apps/my-app/suspend
```

Sets `replicas: 0` in Git. App history and Argo CD Application are preserved.

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| UI shows "Waiting for GitOps sync" | ApplicationSet hasn't picked up new dir yet | Wait 1–2 min; check ApplicationSet controller logs |
| `ImagePullBackOff` | Missing `ghcr-creds` in app namespace | Run manual secret copy above |
| 502 on `/apps/{name}/` | App not running or wrong service name | Check pods in `{name}` namespace |
| App not in Argo CD | ApplicationSet exclude or git push failed | Verify `apps/{name}/` exists on `main` branch |

## Out of Scope (Phase 5+)

- GitHub repo → build → GHCR → deploy pipeline
- Subdomain-per-app routing
- `DELETE /v1/apps/{name}`
- Kyverno automatic secret replication
