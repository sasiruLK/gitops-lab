# TinyCloud App Template

Parametrized manifests for self-service app onboarding. The TinyCloud API generates
`apps/{name}/` from this template via `POST /v1/apps`.

## Placeholders

| Placeholder | Description |
|-------------|-------------|
| `{{APP_NAME}}` | DNS-1123 app name (= namespace = service = deployment) |
| `{{IMAGE}}` | Full container image without tag (e.g. `ghcr.io/user/my-app`) |
| `{{TAG}}` | Semver image tag (e.g. `1.0.0`) |
| `{{REPLICAS}}` | Deployment replica count |
| `{{PORT}}` | Container port |
| `{{ENV_VARS}}` | Optional YAML env block for deployment |

## Conventions

- No per-app Ingress — platform nginx routes `/apps/{name}/` to `{name}.{name}.svc:80`
- Namespace created via GitOps (`namespace.yaml`)
- Image pull secret `ghcr-creds` must exist in the app namespace (see `docs/app-onboarding.md`)

## Do not deploy directly

This directory is excluded from the ApplicationSet generator.
