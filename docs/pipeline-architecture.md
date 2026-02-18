# WarpRun Pipeline Architecture

This document describes how WarpRun processes pipeline execution requests end-to-end — from the frontend trigger through GitLab CI to the feedback callback.

## Table of Contents

- [Overview](#overview)
- [Components](#components)
- [Execution Flow](#execution-flow)
- [Variable Passing](#variable-passing)
- [Pipeline Stages](#pipeline-stages)
- [Child Pipelines](#child-pipelines)
- [Status Reporting](#status-reporting)
- [Error Scenarios](#error-scenarios)

---

## Overview

WarpRun uses a **dynamic parent-child pipeline** pattern in GitLab CI. The WarpRun frontend sends a trigger request to GitLab with all required parameters. A parent pipeline (router) validates the request, selects the correct child pipeline definition, executes it, and reports the final status back to WarpRun via a secured API callback.

```
┌─────────────────┐        trigger         ┌──────────────────────────┐
│  WarpRun        │ ─────────────────────► │  GitLab CI               │
│  Frontend       │                        │  Parent Pipeline (router) │
│                 │ ◄─────────────────────  │  └─ Child Pipeline       │
│                 │   POST /backend-feedback│                          │
└─────────────────┘                        └──────────────────────────┘
```

---

## Components

| Component | Description |
|---|---|
| **WarpRun Frontend** | Initiates pipeline runs via GitLab trigger API, tracks status |
| **`.gitlab-ci.yml`** | Parent pipeline — validates, routes, and monitors execution |
| **`pipelines/*.yml`** | Child pipeline definitions — one file per automation type |
| **`scripts/warprun-feedback.sh`** | Sends execution result back to WarpRun API using Keycloak M2M auth |
| **Keycloak** | Issues M2M access tokens for the feedback service account |
| **WarpRun API** | Receives status updates at `POST /api/backend-feedback` |

---

## Execution Flow

```
1. WarpRun Frontend
   └─► POST https://gitlab.com/api/v4/projects/{id}/trigger/pipeline
         variables:
           WARPRUN_PIPELINE_NAME    = "azure-deploy-vm"
           WARPRUN_REQUEST_ID       = "<uuid>"
           WARPRUN_PIPELINE_RUN_ID  = "<uuid>"
           WARPRUN_CORRELATION_ID   = "<uuid>"
           + all domain variables   (region, vm_name, subscription_id, ...)

2. GitLab starts Parent Pipeline (.gitlab-ci.yml)
   │
   ├─ Stage: validate
   │   ├─ validate-pipeline
   │   │    checks WARPRUN_PIPELINE_NAME is set and pipelines/{name}.yml exists
   │   └─ generate-child-config
   │        writes CHILD_PIPELINE_FILE=pipelines/azure-deploy-vm.yml → dotenv artifact
   │
   ├─ Stage: execute
   │   └─ execute-pipeline (trigger job)
   │        triggers pipelines/azure-deploy-vm.yml as child pipeline
   │        forwards ALL variables (pipeline + yaml)
   │        waits for child to complete (strategy: depend)
   │
   └─ Stage: feedback
       └─ notify-warprun (when: always)
            resolves child pipeline status via GitLab API
            maps to WarpRun enum: Success=2 / Failed=3 / Cancelled=4
            POST /api/backend-feedback  ← authenticated with Keycloak M2M token

3. WarpRun Frontend
   receives status update and updates PipelineRun record
```

---

## Variable Passing

### Variables forwarded to child pipeline

The parent pipeline forwards **all** variables to child pipelines via `trigger: forward`:

```yaml
trigger:
  forward:
    pipeline_variables: true   # all variables passed at trigger time
    yaml_variables: true       # all GitLab Group/Project CI/CD variables
```

**`pipeline_variables: true`** forwards every variable sent by WarpRun in the trigger request:

| Variable | Description |
|---|---|
| `WARPRUN_REQUEST_ID` | UUID identifying the WarpRun Request |
| `WARPRUN_PIPELINE_RUN_ID` | UUID identifying this pipeline execution |
| `WARPRUN_PIPELINE_NAME` | Name of the pipeline to run (maps to `pipelines/{name}.yml`) |
| `WARPRUN_CORRELATION_ID` | Distributed tracing ID |
| `region` | Azure region |
| `vm_name` | Target VM name |
| `vm_size` | Azure VM SKU |
| `subscription_id` | Azure Subscription ID |
| `resource_group` | Azure Resource Group |
| `environment` | Deployment environment (e.g. `Development`, `Production`) |
| `vnet_name` / `vnet_cidr` | Virtual network configuration |
| `subnet_name` / `subnet_cidr` | Subnet configuration |
| `os_disk_sku` / `os_disk_size_gb` | OS disk configuration |
| `data_disk_count` / `data_disk_specs` | Data disk configuration |
| `lifecycle_auto_delete` | Whether to auto-delete the VM after `lifecycle_delete_after` |
| `lifecycle_delete_after` | Date after which VM may be auto-deleted (ISO 8601) |

**`yaml_variables: true`** forwards GitLab Group/Project CI/CD variables:

| Variable | Description |
|---|---|
| `WARPRUN_API_URL` | WarpRun API base URL |
| `KEYCLOAK_URL` | Keycloak base URL |
| `KEYCLOAK_REALM` | Keycloak realm name |
| `KEYCLOAK_CLIENT_ID` | Service account client ID |
| `KEYCLOAK_CLIENT_SECRET` | Service account client secret (Masked) |

> **Note:** `TRIGGER_PAYLOAD` (the raw JSON blob injected by GitLab) is **not** forwarded — it is a GitLab-internal variable, not a pipeline variable.

---

## Pipeline Stages

### Stage 1: `validate`

| Job | Purpose | Runs when |
|---|---|---|
| `validate-pipeline` | Validates `WARPRUN_PIPELINE_NAME` is set and the corresponding `.yml` file exists in `pipelines/` | Always |
| `generate-child-config` | Writes `CHILD_PIPELINE_FILE` path to a dotenv artifact consumed by `execute-pipeline` | Only when `WARPRUN_PIPELINE_NAME` is set |

### Stage 2: `execute`

| Job | Purpose | Runs when |
|---|---|---|
| `execute-pipeline` | Triggers the child pipeline using `CHILD_PIPELINE_FILE`. Uses `strategy: depend` — parent waits and inherits the child's final status. | Only when `WARPRUN_PIPELINE_NAME` is set |

### Stage 3: `feedback`

| Job | Purpose | Runs when |
|---|---|---|
| `notify-warprun` | Resolves final status via GitLab API, then POSTs to WarpRun `/api/backend-feedback` | **Always** (including on failure and cancellation) |

---

## Child Pipelines

Child pipeline files live in the `pipelines/` directory. The file is selected dynamically based on `WARPRUN_PIPELINE_NAME`:

```
pipelines/
├── azure-deploy-vm.yml       ← WARPRUN_PIPELINE_NAME=azure-deploy-vm
├── deploy-vm.yml             ← WARPRUN_PIPELINE_NAME=deploy-vm
└── <your-pipeline>.yml       ← WARPRUN_PIPELINE_NAME=<your-pipeline>
```

### Creating a new child pipeline

1. Create `pipelines/<your-pipeline-name>.yml`
2. All WarpRun trigger variables are available automatically — no extra configuration needed
3. Register the pipeline name in WarpRun `ServiceCatalogItem`

### Available variables in child pipelines

All variables listed in [Variable Passing](#variable-passing) are available as standard environment variables:

```yaml
# Example usage in child pipeline
jobs:
  deploy:
    script:
      - echo "Deploying $vm_name to $region ($subscription_id)"
      - echo "Correlation: $WARPRUN_CORRELATION_ID"
```

---

## Status Reporting

The `notify-warprun` job resolves the pipeline status and sends it to WarpRun. Status resolution logic:

```
notify-warprun
 │
 ├─ WARPRUN_REQUEST_ID missing?
 │   └─► exit 0  (not a WarpRun-triggered pipeline, skip silently)
 │
 ├─ execute-pipeline ran?
 │   ├─ success   → WarpRun status: Success (2)
 │   ├─ failed    → WarpRun status: Failed  (3)
 │   └─ cancelled → WarpRun status: Cancelled (4)
 │
 └─ execute-pipeline was skipped? (validate-pipeline failed)
     ├─ WARPRUN_PIPELINE_NAME empty/null
     │   └─► Failed (3) + errorMessage: "Pipeline name was not provided"
     └─ Pipeline file not found
         └─► Failed (3) + errorMessage: "Pipeline 'X' was not found in pipelines/"
```

### WarpRun PipelineRun status enum

| Value | Name | Description |
|---|---|---|
| `0` | Pending | Request received, not yet started |
| `1` | Running | Pipeline is currently executing |
| `2` | Success | Pipeline completed successfully |
| `3` | Failed | Pipeline failed (see `errorMessage` and `outputData`) |
| `4` | Cancelled | Pipeline was cancelled |

### Feedback payload (POST `/api/backend-feedback`)

```json
// Success
{
  "requestId":     "4a0a62bd-edef-4394-a8be-7f308c86318d",
  "externalRunId": "123456789",
  "status":        2,
  "outputData":    null,
  "errorMessage":  null
}

// Failed (execution error)
{
  "requestId":     "4a0a62bd-edef-4394-a8be-7f308c86318d",
  "externalRunId": "123456789",
  "status":        3,
  "outputData": {
    "gitlab_pipeline_id":    "123456789",
    "gitlab_pipeline_url":   "https://gitlab.com/.../pipelines/123456789",
    "gitlab_job_id":         "987654321",
    "gitlab_project_path":   "mygroup/warprun-backend",
    "runner_description":    "shared-runner-linux",
    "warprun_pipeline_name": "azure-deploy-vm",
    "error_context":         ""
  },
  "errorMessage": "Pipeline failed. See: https://gitlab.com/.../pipelines/123456789"
}

// Failed (unknown pipeline name)
{
  "requestId":     "4a0a62bd-edef-4394-a8be-7f308c86318d",
  "externalRunId": "123456789",
  "status":        3,
  "outputData": {
    "error_context": "Pipeline 'vmcreatex' was not found in pipelines/ directory.",
    ...
  },
  "errorMessage": "Pipeline 'vmcreatex' was not found in pipelines/ directory."
}
```

---

## Error Scenarios

| Scenario | What happens | Frontend receives |
|---|---|---|
| `WARPRUN_PIPELINE_NAME` not set | `validate-pipeline` fails, `execute-pipeline` skipped | `Failed` + `"Pipeline name was not provided"` |
| Pipeline file does not exist | `validate-pipeline` fails, `execute-pipeline` skipped | `Failed` + `"Pipeline 'X' was not found"` |
| Child pipeline job fails | `execute-pipeline` inherits `failed` status | `Failed` + GitLab pipeline URL |
| Child pipeline is cancelled | `execute-pipeline` inherits `cancelled` status | `Cancelled` |
| Keycloak token acquisition fails | `notify-warprun` exits with error | No feedback sent (GitLab job fails) |
| WarpRun API returns 409 | Already in terminal state | Ignored (idempotent) |
