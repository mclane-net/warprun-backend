# GitLab Dynamic Child Pipeline Router for WarpRun

## Overview

This configuration enables WarpRun to trigger different pipelines from a single GitLab repository using the **Dynamic Child Pipeline** pattern. Instead of maintaining separate `.gitlab-ci.yml` configurations or multiple repositories, all pipeline definitions are stored in a `pipelines/` folder and dynamically selected at runtime.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        WarpRun Portal                           │
│                              │                                  │
│                    POST /api/pipeline-runs                      │
│                    WARPRUN_PIPELINE_NAME=hello-world            │
└──────────────────────────────┬──────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│                    GitLab Trigger API                           │
│              POST /api/v4/projects/:id/trigger/pipeline         │
│              variables[WARPRUN_PIPELINE_NAME]=hello-world       │
└──────────────────────────────┬──────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│                   .gitlab-ci.yml (Router)                       │
│                                                                 │
│  ┌─────────────┐    ┌──────────────────┐    ┌────────────────┐ │
│  │  validate   │───▶│ generate-child   │───▶│   execute      │ │
│  │  -pipeline  │    │ -config          │    │   -pipeline    │ │
│  └─────────────┘    └──────────────────┘    └───────┬────────┘ │
│                                                     │          │
│  Stage: validate ──────────────────────────  Stage: execute    │
└─────────────────────────────────────────────────────┬──────────┘
                                                      │
                               trigger:include:local  │
                                                      ▼
┌─────────────────────────────────────────────────────────────────┐
│              pipelines/hello-world.yml (Child)                  │
│                                                                 │
│  ┌─────────────┐    ┌──────────────────┐    ┌────────────────┐ │
│  │   build     │───▶│     test         │───▶│    deploy      │ │
│  └─────────────┘    └──────────────────┘    └────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

## Repository Structure

```
repository/
├── .gitlab-ci.yml              # Router (this file)
└── pipelines/
    ├── hello-world.yml         # Child pipeline: hello-world
    ├── deploy-prod.yml         # Child pipeline: deploy-prod
    ├── backup.yml              # Child pipeline: backup
    └── cleanup.yml             # Child pipeline: cleanup
```

## Router Configuration (.gitlab-ci.yml)

```yaml
# .gitlab-ci.yml
# WarpRun Dynamic Pipeline Router

workflow:
  name: "WarpRun: $WARPRUN_PIPELINE_NAME"  
  rules:
    - if: $CI_PIPELINE_SOURCE == "trigger"   # API/trigger token (WarpRun)
    - if: $CI_PIPELINE_SOURCE == "web"       # Manual from GitLab UI
    - if: $CI_PIPELINE_SOURCE == "schedule" && $WARPRUN_PIPELINE_NAME  # Scheduled
    - when: never                            # Block push, merge_request, etc.

stages:
  - validate
  - execute

# Validate that the requested pipeline exists
validate-pipeline:
  stage: validate
  script:
    - echo "Requested pipeline - $WARPRUN_PIPELINE_NAME"
    - echo "Correlation ID - $WARPRUN_CORRELATION_ID"
    - if [ -z "$WARPRUN_PIPELINE_NAME" ]; then echo "ERROR - WARPRUN_PIPELINE_NAME variable is not set"; exit 1; fi
    - if [ ! -f "pipelines/${WARPRUN_PIPELINE_NAME}.yml" ]; then echo "ERROR - Pipeline file not found"; ls -la pipelines/; exit 1; fi
    - echo "Pipeline file found. Proceeding..."
  rules:
    - if: $WARPRUN_PIPELINE_NAME
  artifacts:
    reports:
      dotenv: pipeline.env

# Generate the pipeline path for child trigger
generate-child-config:
  stage: validate
  needs: [validate-pipeline]
  script:
    - echo "CHILD_PIPELINE_FILE=pipelines/${WARPRUN_PIPELINE_NAME}.yml" >> pipeline.env
    - cat pipeline.env
  artifacts:
    reports:
      dotenv: pipeline.env
  rules:
    - if: $WARPRUN_PIPELINE_NAME

# Trigger the child pipeline with explicit include path
execute-pipeline:
  stage: execute
  needs: [generate-child-config]
  trigger:
    include:
      - local: $CHILD_PIPELINE_FILE
    strategy: depend
    forward:
      pipeline_variables: true
  rules:
    - if: $WARPRUN_PIPELINE_NAME

# Fallback when no pipeline name is provided
no-pipeline-specified:
  stage: validate
  script:
    - echo "No WARPRUN_PIPELINE_NAME provided."
    - echo "This pipeline is designed to be triggered by WarpRun."
    - ls -la pipelines/ || echo "No pipelines folder found"
    - exit 1
  rules:
    - if: $WARPRUN_PIPELINE_NAME == null
```

## Child Pipeline Example (pipelines/hello-world.yml)

```yaml
# pipelines/hello-world.yml
workflow:
  name: "Hello World Pipeline"

stages:
  - run

hello:
  stage: run
  script:
    - echo "Hello from dynamic child pipeline!"
    - echo "Correlation ID: $WARPRUN_CORRELATION_ID"
    - echo "Pipeline Name: $WARPRUN_PIPELINE_NAME"
```

## Key Components Explained

### 1. Workflow Rules (Pipeline Filtering)

| Source | Description | Allowed |
|--------|-------------|---------|
| `trigger` | API call with trigger token (WarpRun) | ✅ |
| `web` | Manual run from GitLab UI | ✅ |
| `schedule` | Scheduled pipeline (requires variable) | ✅ |
| `push` | Git push to repository | ❌ |
| `merge_request_event` | Merge request | ❌ |

### 2. Stages (Required for Variable Propagation)

```yaml
stages:
  - validate    # validate-pipeline, generate-child-config
  - execute     # execute-pipeline
```

**Why stages are required:** The `trigger:include:local: $CHILD_PIPELINE_FILE` needs the dotenv artifact variable to be loaded **between stages**. Without explicit stages, variable propagation is unreliable.

### 3. Dotenv Artifacts

```yaml
artifacts:
  reports:
    dotenv: pipeline.env
```

The `generate-child-config` job writes `CHILD_PIPELINE_FILE=pipelines/xxx.yml` to `pipeline.env`. GitLab automatically loads this as a CI/CD variable for subsequent jobs.

### 4. Variable Forwarding

```yaml
forward:
  pipeline_variables: true
```

This ensures `WARPRUN_CORRELATION_ID`, `WARPRUN_PIPELINE_NAME`, and any custom variables are passed to the child pipeline.

### 5. Strategy: Depend

```yaml
strategy: depend
```

The parent pipeline waits for the child to complete and inherits its status (pass/fail).

## WarpRun Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `WARPRUN_PIPELINE_NAME` | Pipeline to execute (without .yml) | `hello-world` |
| `WARPRUN_CORRELATION_ID` | Unique ID for tracing | `abc-123-def` |
| Custom variables | Passed from ServiceCatalogItem | `ENVIRONMENT=prod` |

## Adding a New Pipeline

1. Create `pipelines/my-new-pipeline.yml`:
   ```yaml
   workflow:
     name: "My New Pipeline"
   
   my-job:
     script:
       - echo "Running my pipeline"
       - echo "Correlation: $WARPRUN_CORRELATION_ID"
   ```

2. Trigger from WarpRun with `WARPRUN_PIPELINE_NAME=my-new-pipeline`

3. Or test manually in GitLab UI:
   - Go to Build → Pipelines → Run pipeline
   - Add variable: `WARPRUN_PIPELINE_NAME` = `my-new-pipeline`
   - Click "Run pipeline"

## Scheduling Pipelines

1. Go to Build → Pipeline schedules → New schedule
2. Set cron expression (e.g., `0 2 * * *` for daily at 2 AM)
3. Add variable: `WARPRUN_PIPELINE_NAME` = `backup`
4. Save

The router will trigger `pipelines/backup.yml` on schedule.

## Troubleshooting

### Pipeline shows only "validate-pipeline" job
- Check if `pipelines/{name}.yml` file exists
- Verify `WARPRUN_PIPELINE_NAME` variable is set correctly

### Child pipeline not receiving variables
- Ensure `forward: pipeline_variables: true` is set
- Check if variables are defined in parent trigger

### Pipeline runs on every push
- Verify `workflow:rules` blocks unwanted sources
- Check that `- when: never` is the last rule

### "Pipeline file not found" error
- File must be in `pipelines/` folder
- Extension must be `.yml` (not `.yaml` unless you update the script)
- Filename must match exactly (case-sensitive)

## GitLab UI Display

With `workflow:name: "WarpRun: $WARPRUN_PIPELINE_NAME"`, pipelines display as:

| Pipeline Name | Triggered By |
|---------------|--------------|
| WarpRun: hello-world | WarpRun API |
| WarpRun: deploy-prod | WarpRun API |
| WarpRun: backup | Schedule |

## Security Considerations

1. **Trigger Token** - Store securely, rotate periodically
2. **Project Access Token** - Use `Reporter` role with `read_api` scope only
3. **Variable validation** - Router validates file existence before trigger
4. **Workflow rules** - Blocks unauthorized pipeline sources