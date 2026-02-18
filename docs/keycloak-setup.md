# Keycloak Configuration Guide

This guide describes how to configure Keycloak to issue M2M (machine-to-machine) access tokens used by the WarpRun GitLab pipeline to authenticate against the WarpRun API.

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [1. Create a Realm](#1-create-a-realm)
- [2. Create the Service Account Client](#2-create-the-service-account-client)
- [3. Copy the Client Secret](#3-copy-the-client-secret)
- [4. Assign Roles](#4-assign-roles)
- [5. Verify — Test the Token](#5-verify---test-the-token)
- [6. Configure GitLab Group Variables](#6-configure-gitlab-group-variables)
- [Token Flow Reference](#token-flow-reference)
- [Security Considerations](#security-considerations)

---

## Overview

The WarpRun feedback script (`scripts/warprun-feedback.sh`) authenticates using the **OAuth 2.0 Client Credentials Grant** (also known as M2M or service account flow). This flow is designed for server-to-server communication with no user interaction.

```
GitLab Runner (notify-warprun job)
   │
   ├─► POST /realms/warprun/protocol/openid-connect/token
   │       grant_type=client_credentials
   │       client_id=warprun-pipeline-sa
   │       client_secret=<secret>
   │
   │   Keycloak validates credentials and returns:
   │   { "access_token": "eyJ...", "expires_in": 300 }
   │
   └─► POST /api/backend-feedback
           Authorization: Bearer eyJ...
           { requestId, externalRunId, status, ... }
```

---

## Prerequisites

- Keycloak 19+ (Quarkus-based) or Keycloak 17+ (legacy)
- Admin access to Keycloak Admin Console
- WarpRun API configured to validate Keycloak-issued tokens

---

## 1. Create a Realm

A dedicated realm isolates WarpRun authentication from other applications.

1. Open **Keycloak Admin Console**: `https://<your-keycloak-host>/admin`
2. Click the realm dropdown (top-left) → **Create Realm**
3. Set:
   - **Realm name**: `warprun`
   - **Enabled**: ON
4. Click **Create**

> If you already have an existing realm you want to reuse, skip this step and use your existing realm name as `KEYCLOAK_REALM`.

---

## 2. Create the Service Account Client

1. Navigate to: **Realm `warprun` → Clients → Create client**

### Step A — General Settings

| Field | Value |
|---|---|
| Client type | `OpenID Connect` |
| Client ID | `warprun-pipeline-sa` |
| Name | `WarpRun Pipeline Service Account` |
| Description | `Used by GitLab CI to post pipeline status to WarpRun API` |

Click **Next**.

### Step B — Capability Config

| Option | Value |
|---|---|
| Client authentication | **ON** (makes it a confidential client) |
| Authorization | OFF |
| Standard flow | **OFF** |
| Implicit flow | OFF |
| Direct access grants | **OFF** |
| Service accounts roles | **ON** ← enables `client_credentials` grant |

Click **Next** → **Save**.

> **Why disable Standard flow and Direct access grants?**  
> This client is a machine service account. Disabling interactive flows reduces the attack surface — the only valid flow is `client_credentials`.

---

## 3. Copy the Client Secret

1. Go to: **Clients → `warprun-pipeline-sa` → Credentials tab**
2. Verify **Client Authenticator** is set to `Client Id and Secret`
3. Copy the value from the **Client secret** field

This value will be stored as `KEYCLOAK_CLIENT_SECRET` in GitLab.

> To rotate the secret: click **Regenerate** on the Credentials tab, then update the GitLab Group variable.

---

## 4. Assign Roles

The WarpRun API validates that the incoming token carries the correct role before accepting the feedback callback.

### Option A — Realm Role (recommended)

1. Navigate to: **Realm roles → Create role**
2. Set **Role name**: `pipeline-feedback`
3. Click **Save**
4. Navigate to: **Clients → `warprun-pipeline-sa` → Service accounts roles tab**
5. Click **Assign role**
6. Filter by `Filter by realm roles`
7. Select `pipeline-feedback` → **Assign**

### Option B — Client Role

If WarpRun API uses client-scoped roles:

1. Navigate to: **Clients → `warprun-api` → Roles tab → Create role**
2. Set **Role name**: `pipeline-feedback`
3. Navigate to: **Clients → `warprun-pipeline-sa` → Service accounts roles tab**
4. Click **Assign role** → filter by client `warprun-api`
5. Select `pipeline-feedback` → **Assign**

> Ask your WarpRun API administrator which role name is expected and whether it is a realm role or client role.

---

## 5. Verify — Test the Token

Test the complete M2M flow from your terminal before configuring GitLab:

```bash
# 1. Request a token
TOKEN=$(curl -s -X POST \
  "https://<KEYCLOAK_URL>/realms/warprun/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials" \
  -d "client_id=warprun-pipeline-sa" \
  -d "client_secret=<YOUR_CLIENT_SECRET>" \
  | jq -r '.access_token')

echo "Token acquired: ${TOKEN:0:50}..."

# 2. Inspect token claims
echo $TOKEN | cut -d'.' -f2 | base64 -d 2>/dev/null | jq '{
  sub,
  iss,
  realm_access,
  resource_access,
  exp
}'

# 3. Test the WarpRun feedback endpoint (dry-run with a fake requestId)
curl -s -X POST \
  "https://<WARPRUN_API_URL>/api/backend-feedback" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"requestId":"00000000-0000-0000-0000-000000000000","externalRunId":"test","status":3}' \
  | jq .
```

Expected token claims should include:
```json
{
  "sub": "...",
  "iss": "https://<KEYCLOAK_URL>/realms/warprun",
  "realm_access": {
    "roles": ["pipeline-feedback"]
  }
}
```

> A `404` response from WarpRun for the fake `requestId` is expected and confirms authentication is working correctly.

---

## 6. Configure GitLab Group Variables

Once Keycloak is configured, set the following variables in **GitLab → Group → Settings → CI/CD → Variables**:

| Variable | Example Value | Masked | Protected | Notes |
|---|---|---|---|---|
| `WARPRUN_API_URL` | `https://api.warprun.example.com` | ❌ | ✅ | No trailing slash |
| `KEYCLOAK_URL` | `https://auth.example.com` | ❌ | ✅ | Base URL only, no `/realms/...` |
| `KEYCLOAK_REALM` | `warprun` | ❌ | ✅ | Realm name from Step 1 |
| `KEYCLOAK_CLIENT_ID` | `warprun-pipeline-sa` | ❌ | ✅ | Client ID from Step 2 |
| `KEYCLOAK_CLIENT_SECRET` | `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` | ✅ | ✅ | Secret from Step 3 |

> **Variable scope:** Set all variables at **Group level** so they are available in both the parent pipeline and all child pipelines (forwarded via `yaml_variables: true`).

---

## Token Flow Reference

```
notify-warprun job
   │
   │  POST /realms/{KEYCLOAK_REALM}/protocol/openid-connect/token
   │  body: grant_type=client_credentials
   │        client_id={KEYCLOAK_CLIENT_ID}
   │        client_secret={KEYCLOAK_CLIENT_SECRET}
   │
   ▼
Keycloak
   │  validates client credentials
   │  checks service account is enabled
   │  issues JWT signed with realm private key
   │
   │  response: { access_token, expires_in: 300, token_type: "Bearer" }
   │
   ▼
notify-warprun job
   │
   │  POST {WARPRUN_API_URL}/api/backend-feedback
   │  Authorization: Bearer {access_token}
   │  X-Correlation-Id: {WARPRUN_CORRELATION_ID}
   │  body: { requestId, externalRunId, status, outputData, errorMessage }
   │
   ▼
WarpRun API
   validates JWT signature against Keycloak JWKS
   validates role claim (pipeline-feedback)
   updates PipelineRun status
   response: 200 OK
```

---

## Security Considerations

| Topic | Recommendation |
|---|---|
| **Client Secret rotation** | Rotate every 90 days. Use Keycloak → Credentials → Regenerate, then update GitLab variable. |
| **Token lifetime** | Default 300s (5 min) is sufficient. Do not increase unnecessarily. |
| **Masked variable** | `KEYCLOAK_CLIENT_SECRET` must be Masked in GitLab — it will never appear in job logs. |
| **Protected variable** | Mark all Keycloak variables as Protected — they are only injected into protected branches. |
| **Minimal roles** | Assign only the `pipeline-feedback` role — no admin, no read access to other resources. |
| **Network access** | GitLab Runner must reach both Keycloak and WarpRun API. Consider IP allowlisting on both. |
| **Audit log** | Keycloak logs all token issuances. WarpRun API should log all `/backend-feedback` calls with `X-Correlation-Id`. |
