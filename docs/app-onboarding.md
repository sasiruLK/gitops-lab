# App Onboarding Guide

Self-service app onboarding via TinyCloud Platform (Phase 4).

## Prerequisites

1. **GitHub source repository** containing a Node.js or Go app
2. **Build coordinator** reachable from TinyCloud API
3. **GitHub PAT** on the coordinator with write access to `gitops-lab`
4. **Argo CD ApplicationSet controller** running (`applicationsets.argoproj.io` CRD)
5. **`ghcr-creds` secret** in the app namespace (see below)

## How It Works

```
POST /v1/apps  →  API enqueues build  →  Coordinator  →  Runner builds + pushes GHCR image
                                                              ↓
Coordinator commits manifests  →  ApplicationSet  →  Argo CD Application  →  sync
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
| Image tags | Immutable source commit SHA |

## API Usage

```bash
curl -X POST https://tinycloud-platform.duckdns.org/api/v1/apps \
  -H "Content-Type: application/json" \
  -d '{
    "name": "my-app",
    "repoUrl": "https://github.com/user/my-app",
    "ref": "main",
    "replicas": 1,
    "port": 8080
  }'
```

Response:

```json
{
  "data": {
    "appName": "my-app",
    "buildId": "8e3d7e96-9124-4012-ae80-65fb48a9215f",
    "status": "queued"
  }
}
```

Poll `GET /v1/builds/{buildId}` and `GET /v1/builds/{buildId}/logs` until the build succeeds. After the coordinator commits manifests, poll `GET /v1/apps/my-app` until ApplicationSet creates the Argo CD Application.

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

- Subdomain-per-app routing
- `DELETE /v1/apps/{name}`
- Kyverno automatic secret replication
