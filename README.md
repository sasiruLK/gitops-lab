# GitOps Lab

GitOps source of truth for the OCI Always Free platform lab.

## Target Platform

- `k3s-control` on ARM
- `k3s-worker-1` on ARM
- `k3s-worker-2` on ARM
- dedicated ARM `build-vm` outside the cluster for native ARM image builds
- OCI Bastion for admin access
- OCIR for images and BuildKit cache
- Argo CD for cluster reconciliation

## Repo Layout

```text
argocd/                  Argo CD Applications, ApplicationSets, ImageUpdater objects
apps/tinycloud-api/      Platform API deployment
apps/tinycloud-ui/       Platform UI deployment
apps/tinycloud-platform/ Shared ingress, oauth2-proxy, network policy, TLS
apps/_template/          App template used by TinyCloud self-service workflows
docs/                    App onboarding and rollback notes
rollbacks/               Rollback audit log
scripts/                 Manual rollback and backup helpers
```

## Base Delivery Flow

```text
GitHub repo -> CI build on ARM build-vm -> OCIR image push
          -> GitOps repo update -> Argo CD sync -> k3s deploy
```

The base platform is intentionally **pure GitOps first**. `tinycloud-platform` can be layered back on later, but Argo CD and this repo remain the deployment source of truth.

## Required Cluster Prerequisites

- k3s cluster already running
- Argo CD installed
- Traefik installed
- cert-manager installed
- `ocir-creds` present in `argocd`, `tinycloud`, and each app namespace

## Conventions

- App namespaces match app names
- Public app URLs use `https://{app}.sasiru.lk/`
- Runtime contract is port `8080` and `/healthz`
- Platform images live under `iad.ocir.io/idzghas4xwzv/tinycloud/*`

## First Validation Target

Use this repo to prove one end-to-end deployment:

1. Push image to OCIR
2. Update manifest or sidecar tag in this repo
3. Let Argo CD sync
4. Verify the app is reachable on its public hostname
