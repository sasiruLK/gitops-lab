# GitOps Lab

A simple GitOps lab for deploying an Nginx demo app with Argo CD.

## Structure

```
apps/nginx/
├── namespace.yaml    # Creates the "demo" namespace
├── deployment.yaml   # nginx-demo Deployment (2 replicas)
├── service.yaml      # ClusterIP Service on port 80
└── ingress.yaml      # Ingress for nginx.sasiru.local (Traefik)
```

## Prerequisites

- A Kubernetes cluster
- Argo CD installed in the cluster
- Traefik (or another Ingress controller) installed
- `nginx.sasiru.local` resolving to your cluster Ingress IP (update your `/etc/hosts` if needed)

## Deploy with Argo CD

### 1. Log in to Argo CD

```bash
argocd login <ARGOCD_SERVER>
```

### 2. Create the Application

```bash
argocd app create nginx-demo \
  --repo https://github.com/<your-username>/gitops-lab.git \
  --path apps/nginx \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace demo \
  --sync-policy automated \
  --auto-prune \
  --self-heal
```

> Replace `<your-username>` with your actual GitHub username or repository URL.

### 3. Sync the Application

If not using automated sync:

```bash
argocd app sync nginx-demo
```

### 4. Access the App

Add the host to your local `/etc/hosts` if necessary:

```
<INGRESS_IP> nginx.sasiru.local
```

Then open [http://nginx.sasiru.local](http://nginx.sasiru.local) in your browser.
