# GitLab Configuration Guide

This guide covers everything required to configure GitLab for WarpRun pipeline execution — from repository structure to CI/CD variables and trigger token setup.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Repository Structure](#repository-structure)
- [CI/CD Group Variables](#cicd-group-variables)
- [GitLab Trigger Token](#gitlab-trigger-token)
- [Pipeline Trigger API](#pipeline-trigger-api)
- [Adding a New Pipeline](#adding-a-new-pipeline)
- [Testing Manually](#testing-manually)
- [Troubleshooting](#troubleshooting)

---

## Prerequisites

- GitLab instance (self-managed or GitLab.com)
- A GitLab Group containing this repository
- GitLab Runner configured and assigned to the group or project
- Keycloak instance configured (see [keycloak-setup.md](./keycloak-setup.md))
- WarpRun API deployed and accessible from the GitLab Runner

---

## Repository Structure

```
warprun-backend/
├── .gitlab-ci.yml              # Parent pipeline router (do not modify lightly)
├── pipelines/
│   ├── azure-deploy-vm.yml     # Child pipeline: Azure VM deployment
│   └── deploy-vm.yml           # Child pipeline: generic VM deployment
├── scripts/
│   └── warprun-feedback.sh     # Feedback script: Keycloak M2M + POST to WarpRun API
├── terraform/                  # Terraform modules (used by child pipelines)
└── docs/
    ├── pipeline-architecture.md
    ├── gitlab-setup.md         # ← this file
    └── keycloak-setup.md
```

---

## CI/CD Group Variables

Variables must be set at the **GitLab Group level** so they are inherited by all pipelines in the group (including child pipelines via `yaml_variables: true` forwarding).

**Navigation:** `GitLab → Group → Settings → CI/CD → Variables → Add variable`

| Variable | Value | Masked | Protected | Description |
|---|---|---|---|---|
| `WARPRUN_API_URL` | `https://api.warprun.example.com` | ❌ | ✅ | WarpRun API base URL (no trailing slash) |
| `KEYCLOAK_URL` | `https://auth.example.com` | ❌ | ✅ | Keycloak base URL — **no `/realms/...` suffix** |
| `KEYCLOAK_REALM` | `warprun` | ❌ | ✅ | Keycloak realm name |
| `KEYCLOAK_CLIENT_ID` | `warprun-pipeline-sa` | ❌ | ✅ | Service account client ID |
| `KEYCLOAK_CLIENT_SECRET` | `<secret>` | ✅ | ✅ | Service account client secret — keep masked |

> **Important:** `KEYCLOAK_URL` must be the base URL only.  
> ✅ Correct: `https://auth.example.com`  
> ❌ Wrong: `https://auth.example.com/realms/warprun`

### Variable scope

- Set variables at **Group level** — they propagate to all projects and all child pipelines automatically
- Do **not** set them at Project level (they would not be forwarded via `yaml_variables: true`)
- `Protected` = only available on protected branches and tags (recommended for secrets)

---

## GitLab Trigger Token

WarpRun uses a **Pipeline Trigger Token** to start pipelines via the GitLab API.

### Create a Trigger Token

1. Navigate to the repository: **Settings → CI/CD → Pipeline triggers**
2. Enter a description: `WarpRun Trigger`
3. Click **Add trigger**
4. Copy the generated token

### Configure in WarpRun

In WarpRun settings, configure:

| Setting | Value |
|---|---|
| `GitLabProjectId` | Project ID (found in **Settings → General → Project ID**) |
| `GitLabTriggerToken` | The token copied above |
| `GitLabApiUrl` | `https://gitlab.com/api/v4` (or your self-managed URL) |
| `GitLabRef` | `main` (branch to trigger) |

---

## Pipeline Trigger API

WarpRun triggers pipelines using the GitLab Trigger API:

```http
POST https://gitlab.com/api/v4/projects/{PROJECT_ID}/trigger/pipeline
Content-Type: application/x-www-form-urlencoded

token={TRIGGER_TOKEN}
&ref=main
&variables[WARPRUN_PIPELINE_NAME]=azure-deploy-vm
&variables[WARPRUN_REQUEST_ID]=4a0a62bd-edef-4394-a8be-7f308c86318d
&variables[WARPRUN_PIPELINE_RUN_ID]=c875313c-528a-417c-b1b1-f71721b4b949
&variables[WARPRUN_CORRELATION_ID]=581cb0a4f998450899c870403e47190d
&variables[region]=northeurope
&variables[vm_name]=my-vm
&variables[subscription_id]=39978373-df3f-4b7e-8c94-71336003e043
... (all domain variables from ServiceCatalogItem)
```

### Required trigger variables

| Variable | Required | Description |
|---|---|---|
| `WARPRUN_PIPELINE_NAME` | ✅ | Maps to `pipelines/{name}.yml` |
| `WARPRUN_REQUEST_ID` | ✅ | Used for feedback callback |
| `WARPRUN_PIPELINE_RUN_ID` | ✅ | Identifies this specific run |
| `WARPRUN_CORRELATION_ID` | ✅ | Distributed tracing header |
| *(domain variables)* | depends on pipeline | Passed through to child pipeline |

---

## Adding a New Pipeline

To add a new automation pipeline to WarpRun:

1. **Create the pipeline file:**

```bash
touch pipelines/<your-pipeline-name>.yml
```

2. **Implement the pipeline** — all WarpRun variables are automatically available:

```yaml
# pipelines/my-new-pipeline.yml
workflow:
  name: "My New Pipeline | $environment"

stages:
  - run

execute:
  stage: run
  script:
    - echo "Running with request: $WARPRUN_REQUEST_ID"
    - echo "Target environment: $environment"
    - echo "Custom parameter: $my_custom_param"
```

3. **Register in WarpRun** — create a `ServiceCatalogItem` with:
   - `PipelineName` = `my-new-pipeline` (must match the filename without `.yml`)
   - Add all required input parameters as `ServiceCatalogItemParameters`

4. **Commit and push** — the pipeline is immediately available

> No changes to `.gitlab-ci.yml` are needed — the router picks up new files automatically.

---

## Testing Manually

You can trigger a pipeline manually to verify the setup:

```bash
curl -s -X POST \
  "https://gitlab.com/api/v4/projects/{PROJECT_ID}/trigger/pipeline" \
  -F "token={TRIGGER_TOKEN}" \
  -F "ref=main" \
  -F "variables[WARPRUN_PIPELINE_NAME]=azure-deploy-vm" \
  -F "variables[WARPRUN_REQUEST_ID]=test-$(uuidgen)" \
  -F "variables[WARPRUN_PIPELINE_RUN_ID]=test-$(uuidgen)" \
  -F "variables[WARPRUN_CORRELATION_ID]=test-$(uuidgen)" \
  -F "variables[vm_name]=test-vm" \
  -F "variables[region]=northeurope" \
  -F "variables[subscription_id]=00000000-0000-0000-0000-000000000000" \
  -F "variables[resource_group]=test-rg" \
  -F "variables[environment]=Development" \
  | jq '{id, status, web_url}'
```

Then monitor in GitLab: **CI/CD → Pipelines**

---

## Troubleshooting

### Pipeline not starting

- Verify the trigger token is valid: **Settings → CI/CD → Pipeline triggers**
- Verify the project ID is correct: **Settings → General**
- Ensure the `ref` (branch) exists and has a `.gitlab-ci.yml`

### `validate-pipeline` fails with "Pipeline file not found"

- Check that `pipelines/{WARPRUN_PIPELINE_NAME}.yml` exists
- Verify the `WARPRUN_PIPELINE_NAME` value matches the filename exactly (case-sensitive)

### `notify-warprun` fails with Keycloak auth error (401/403)

- Verify all `KEYCLOAK_*` Group variables are set correctly
- Check `KEYCLOAK_URL` has no trailing slash and no `/realms/...` suffix
- Test the token manually (see [keycloak-setup.md — Step 5](./keycloak-setup.md#5-verify---test-the-token))

### WarpRun API returns 404 on feedback

- The `WARPRUN_REQUEST_ID` does not match any active request
- The request may have already been closed

### Child pipeline variables not available

- Ensure `forward: pipeline_variables: true` and `yaml_variables: true` are set in `execute-pipeline`
- Group variables must be set at **Group level**, not Project level
- Protected variables are only available on protected branches
