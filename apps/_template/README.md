# TinyCloud App Template

Parametrized manifests for self-service app onboarding. The TinyCloud API generates
`apps/{name}/` from this template via `POST /v1/apps`.

## Placeholders

| Placeholder | Description |
|-------------|-------------|
| `{{APP_NAME}}` | DNS-1123 app name (= namespace = service = deployment) |
| `{{IMAGE}}` | Full container image without tag (e.g. `iad.ocir.io/ns/tinycloud/my-app`) |
| `{{TAG}}` | Semver image tag (e.g. `1.0.0`) |
| `{{REPLICAS}}` | Deployment replica count |
| `{{PORT}}` | Container port |
| `{{ENV_VARS}}` | Optional YAML env block for deployment |

## Conventions

- No per-app Ingress — platform nginx routes app subdomains and keeps `/apps/{name}/` as a compatibility path during cutover
- Namespace created via GitOps (`namespace.yaml`)
- Runtime contract: container listens on `8080` and serves `/healthz`
- Image pull secret `ocir-creds` must exist in the app namespace (see `docs/app-onboarding.md`)

## Do not deploy directly

This directory is excluded from the ApplicationSet generator.
