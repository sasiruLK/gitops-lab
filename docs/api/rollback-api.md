# TinyCloud Rollback API Design

> Future API specification for the TinyCloud platform dashboard.
> This is a design document — not yet implemented as a running service.

---

## Overview

The TinyCloud Rollback API provides a RESTful interface for operators to trigger and manage rollbacks without manually running shell scripts. Under the hood, the API server calls the same `scripts/rollback.sh` and `scripts/restore.sh` primitives — Git and `kubectl` remain the actual execution layer.

---

## Base URL

```
https://api.tinycloud.local/v1
```

---

## Endpoints

### 1. List Rollback History

```http
GET /apps/{name}/rollbacks
```

**Path Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `name` | string | Application name (must match Argo CD Application name) |

**Response:**
```json
{
  "app": "tinycloud-demo",
  "currentStatus": "normal",
  "activeRollback": null,
  "history": [
    {
      "id": "rb-tinycloud-demo-20260523-101500",
      "type": "rollback",
      "timestamp": "2026-05-23T10:15:00Z",
      "targetRevision": "a948f7fed3fedceccdfb52dc94dbc2d509a8aaa4",
      "targetImage": "ghcr.io/sasirulk/tinycloud-demo-app:a948f7fed3fedceccdfb52dc94dbc2d509a8aaa4",
      "previousRevision": "89d78fd165b011d948128dfa880b66c494870aad",
      "previousImage": "ghcr.io/sasirulk/tinycloud-demo-app:999274c96e8315e4556f910aff30a081486f0cda",
      "reason": "performance regression in v4",
      "rollbackBranch": "rollback/tinycloud-demo",
      "initiatedBy": "sasiru",
      "links": {
        "commit": "https://github.com/sasiruLK/gitops-lab/commit/89d78fd...",
        "argoCdApp": "https://argocd.tinycloud.local/applications/tinycloud-demo"
      }
    },
    {
      "id": "rs-tinycloud-demo-20260523-110000",
      "type": "restore",
      "timestamp": "2026-05-23T11:00:00Z",
      "restoredToRevision": "0955600386dadaa5d34cfab1b33f916d94381340",
      "restoredToImage": "ghcr.io/sasirulk/tinycloud-demo-app:a5fc64046b5424f4bbd73fcb883cdc2c0b0f064c",
      "reason": "incident resolved",
      "initiatedBy": "sasiru"
    }
  ]
}
```

**Status Codes:**
| Code | Meaning |
|------|---------|
| 200 | OK |
| 404 | App not found |

---

### 2. Trigger Rollback

```http
POST /apps/{name}/rollback
```

**Request Body:**
```json
{
  "targetRevision": "a948f7fed3fedceccdfb52dc94dbc2d509a8aaa4",
  "reason": "performance regression in v4",
  "initiatedBy": "sasiru"
}
```

**Field Descriptions:**
| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `targetRevision` | string | yes | Full Git SHA to rollback to |
| `reason` | string | yes | Human-readable reason for the rollback |
| `initiatedBy` | string | yes | Username or service account triggering the rollback |

**Response (202 Accepted):**
```json
{
  "rollbackId": "rb-tinycloud-demo-20260523-101500",
  "app": "tinycloud-demo",
  "rollbackBranch": "rollback/tinycloud-demo",
  "targetRevision": "a948f7fed3fedceccdfb52dc94dbc2d509a8aaa4",
  "targetImage": "ghcr.io/sasirulk/tinycloud-demo-app:a948f7fed3fedceccdfb52dc94dbc2d509a8aaa4",
  "previousRevision": "0955600386dadaa5d34cfab1b33f916d94381340",
  "previousImage": "ghcr.io/sasirulk/tinycloud-demo-app:a5fc64046b5424f4bbd73fcb883cdc2c0b0f064c",
  "argoCdSyncStatus": "syncing",
  "healthStatus": "progressing",
  "status": "active",
  "createdAt": "2026-05-23T10:15:00Z",
  "links": {
    "argoCdApp": "https://argocd.tinycloud.local/applications/tinycloud-demo",
    "rollbackBranch": "https://github.com/sasiruLK/gitops-lab/tree/rollback/tinycloud-demo"
  }
}
```

**Status Codes:**
| Code | Meaning |
|------|---------|
| 202 | Rollback accepted and in progress |
| 400 | Invalid targetRevision or missing required field |
| 404 | App not found |
| 409 | App is already in rollback state |
| 422 | Target revision is not a known-good commit |

---

### 3. Trigger Restore

```http
POST /apps/{name}/restore
```

**Request Body:**
```json
{
  "reason": "incident resolved, restoring main",
  "initiatedBy": "sasiru"
}
```

**Field Descriptions:**
| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `reason` | string | yes | Reason for restoring normal flow |
| `initiatedBy` | string | yes | Username or service account |

**Response (202 Accepted):**
```json
{
  "restoreId": "rs-tinycloud-demo-20260523-110000",
  "app": "tinycloud-demo",
  "restoredToRevision": "0955600386dadaa5d34cfab1b33f916d94381340",
  "restoredToImage": "ghcr.io/sasirulk/tinycloud-demo-app:a5fc64046b5424f4bbd73fcb883cdc2c0b0f064c",
  "argoCdSyncStatus": "syncing",
  "healthStatus": "progressing",
  "status": "restoring",
  "createdAt": "2026-05-23T11:00:00Z"
}
```

**Status Codes:**
| Code | Meaning |
|------|---------|
| 202 | Restore accepted and in progress |
| 400 | Missing required field |
| 404 | App not found |
| 409 | App is not in rollback state |

---

### 4. Get Rollback Status

```http
GET /apps/{name}/rollback-status
```

**Response:**
```json
{
  "app": "tinycloud-demo",
  "currentStatus": "rollback",
  "activeRollback": {
    "id": "rb-tinycloud-demo-20260523-101500",
    "targetRevision": "a948f7fed3fedceccdfb52dc94dbc2d509a8aaa4",
    "targetImage": "ghcr.io/sasirulk/tinycloud-demo-app:a948f7fed3fedceccdfb52dc94dbc2d509a8aaa4",
    "rollbackBranch": "rollback/tinycloud-demo",
    "reason": "performance regression in v4",
    "initiatedBy": "sasiru",
    "createdAt": "2026-05-23T10:15:00Z",
    "argoCdSyncStatus": "Synced",
    "healthStatus": "Healthy"
  }
}
```

---

## Implementation Notes

### Backend Architecture (Future)

```
┌─────────────────┐
│  TinyCloud API  │
│   (Go/Node)     │
└────────┬────────┘
         │
         ▼
┌─────────────────────────────────────────┐
│         API Handler Layer               │
│  - Validate request                     │
│  - Check app exists in cluster          │
│  - Check current rollback state         │
└────────┬────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────┐
│         Git + kubectl Primitives        │
│  - exec: git branch -f rollback/<app>   │
│  - exec: git push origin ...            │
│  - exec: kubectl patch application ...│
│  - exec: kubectl wait ...               │
│  - exec: git commit rollbacks/*.yaml    │
└─────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────┐
│         Response Builder                  │
│  - Read rollbacks/rollbacks.yaml          │
│  - Build JSON response                    │
│  - Return 202 + status links              │
└─────────────────────────────────────────┘
```

### Key Design Principles

1. **GitOps remains the source of truth** — The API never mutates cluster state directly. It always goes through Git.
2. **Idempotency** — Calling `POST /apps/{name}/rollback` twice with the same target should be safe (no-op or error if already in rollback).
3. **Async by default** — Rollback and restore return `202 Accepted` immediately. Clients poll `GET /apps/{name}/rollback-status` for completion.
4. **Impersonation** — All Git commits use the `initiatedBy` field as the author or in the commit message.
5. **RBAC** — Only users with `rollback` permission on an app can trigger it. Read-only users can view history.

### Authentication & Authorization

```yaml
# Example RBAC policy (future)
roles:
  - name: rollback-operator
    permissions:
      - resource: apps
        action: rollback
        apps: [tinycloud-demo, nginx-demo]
      - resource: apps
        action: read
        apps: ["*"]

  - name: readonly
    permissions:
      - resource: apps
        action: read
        apps: ["*"]
```

### Error Handling

```json
{
  "error": "AppAlreadyInRollback",
  "message": "App 'tinycloud-demo' is already in rollback state (rb-tinycloud-demo-20260523-101500). Use POST /restore first.",
  "code": 409,
  "details": {
    "activeRollbackId": "rb-tinycloud-demo-20260523-101500"
  }
}
```

---

## OpenAPI Spec (Partial)

```yaml
openapi: 3.0.3
info:
  title: TinyCloud Rollback API
  version: 1.0.0
paths:
  /apps/{name}/rollbacks:
    get:
      summary: List rollback history
      parameters:
        - name: name
          in: path
          required: true
          schema:
            type: string
      responses:
        '200':
          description: OK
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/RollbackHistory'

  /apps/{name}/rollback:
    post:
      summary: Trigger rollback
      parameters:
        - name: name
          in: path
          required: true
          schema:
            type: string
      requestBody:
        required: true
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/RollbackRequest'
      responses:
        '202':
          description: Accepted
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/RollbackResponse'

  /apps/{name}/restore:
    post:
      summary: Trigger restore
      parameters:
        - name: name
          in: path
          required: true
          schema:
            type: string
      requestBody:
        required: true
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/RestoreRequest'
      responses:
        '202':
          description: Accepted
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/RestoreResponse'

components:
  schemas:
    RollbackRequest:
      type: object
      required: [targetRevision, reason, initiatedBy]
      properties:
        targetRevision:
          type: string
          pattern: '^[a-f0-9]{40}$'
        reason:
          type: string
          maxLength: 500
        initiatedBy:
          type: string

    RollbackResponse:
      type: object
      properties:
        rollbackId:
          type: string
        app:
          type: string
        rollbackBranch:
          type: string
        targetRevision:
          type: string
        targetImage:
          type: string
        previousRevision:
          type: string
        previousImage:
          type: string
        argoCdSyncStatus:
          type: string
        healthStatus:
          type: string
        status:
          type: string
          enum: [active, completed, failed]
        createdAt:
          type: string
          format: date-time
        links:
          type: object
          properties:
            argoCdApp:
              type: string
            rollbackBranch:
              type: string

    # ... (schemas truncated for brevity)
```

---

*Last updated: 2026-05-23*
