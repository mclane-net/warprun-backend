#!/usr/bin/env bash
# =============================================================================
# WarpRun Feedback Script
# Authenticates with Keycloak (M2M) and POSTs pipeline result to WarpRun API.
#
# Called by: notify-warprun job in .gitlab-ci.yml
#
# Required CI/CD Group Variables (set in GitLab Group Settings):
#   WARPRUN_API_URL          e.g. https://api.warprun.example.com
#   KEYCLOAK_URL             e.g. https://auth.example.com
#   KEYCLOAK_REALM           e.g. warprun
#   KEYCLOAK_CLIENT_ID       e.g. warprun-pipeline-sa
#   KEYCLOAK_CLIENT_SECRET   service account secret (Masked + Protected)
#
# Required pipeline variables (forwarded from WarpRun trigger):
#   WARPRUN_REQUEST_ID       UUID of the WarpRun Request
#   WARPRUN_CORRELATION_ID   tracing ID
#   WARPRUN_PIPELINE_STATUS  set by notify-warprun job: success|failed|cancelled
#
# Optional (set by notify-warprun fallback logic):
#   FEEDBACK_ERROR_CONTEXT   human-readable error reason (missing/unknown pipeline name)
#                            when set, takes priority over generic CI_PIPELINE_URL message
# =============================================================================

set -euo pipefail

# ── Validate required variables ───────────────────────────────────────────────
required_vars=(
  WARPRUN_API_URL
  KEYCLOAK_URL
  KEYCLOAK_REALM
  KEYCLOAK_CLIENT_ID
  KEYCLOAK_CLIENT_SECRET
  WARPRUN_REQUEST_ID
  WARPRUN_PIPELINE_STATUS
)

for var in "${required_vars[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    echo "[warprun-feedback] ERROR: Required variable '$var' is not set."
    exit 1
  fi
done

echo "[warprun-feedback] Request ID    : $WARPRUN_REQUEST_ID"
echo "[warprun-feedback] Status        : $WARPRUN_PIPELINE_STATUS"
echo "[warprun-feedback] Pipeline ID   : ${CI_PIPELINE_ID:-n/a}"
echo "[warprun-feedback] Error context : ${FEEDBACK_ERROR_CONTEXT:-<none>}"

# ── Map status → PipelineRunStatus enum ──────────────────────────────────────
# WarpRun: Pending=0, Running=1, Success=2, Failed=3, Cancelled=4
case "$WARPRUN_PIPELINE_STATUS" in
  success)   STATUS_CODE=2 ;;
  failed)    STATUS_CODE=3 ;;
  cancelled) STATUS_CODE=4 ;;
  *)
    echo "[warprun-feedback] ERROR: Unknown status '$WARPRUN_PIPELINE_STATUS'"
    exit 1
    ;;
esac

# ── Acquire Keycloak M2M token ────────────────────────────────────────────────
echo "[warprun-feedback] Acquiring Keycloak token..."

TOKEN_RESPONSE=$(curl --silent --fail \
  --request POST \
  --url "${KEYCLOAK_URL}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token" \
  --header "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "grant_type=client_credentials" \
  --data-urlencode "client_id=${KEYCLOAK_CLIENT_ID}" \
  --data-urlencode "client_secret=${KEYCLOAK_CLIENT_SECRET}") || {
  echo "[warprun-feedback] ERROR: Keycloak token request failed."
  exit 1
}

ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.access_token // empty')

if [[ -z "$ACCESS_TOKEN" ]]; then
  echo "[warprun-feedback] ERROR: access_token missing in Keycloak response."
  exit 1
fi

echo "[warprun-feedback] Token acquired."

# ── Build JSON payload ────────────────────────────────────────────────────────
EXTERNAL_RUN_ID="${CI_PIPELINE_ID:-}"

if [[ "$STATUS_CODE" -eq 3 ]]; then
  # ── Failed: resolve errorMessage ────────────────────────────────────────────
  # Priority:
  #   1. FEEDBACK_ERROR_CONTEXT — specific reason (missing/unknown pipeline name)
  #   2. CI_PIPELINE_URL        — generic "pipeline failed, see logs" with link
  if [[ -n "${FEEDBACK_ERROR_CONTEXT:-}" ]]; then
    ERROR_MESSAGE="${FEEDBACK_ERROR_CONTEXT}"
  else
    ERROR_MESSAGE="Pipeline failed. See: ${CI_PIPELINE_URL:-N/A}"
  fi

  # outputData: GitLab diagnostic context (always included on failure)
  OUTPUT_DATA=$(jq -n \
    --arg pipeline_id    "${CI_PIPELINE_ID:-}" \
    --arg pipeline_url   "${CI_PIPELINE_URL:-}" \
    --arg job_id         "${CI_JOB_ID:-}" \
    --arg project_path   "${CI_PROJECT_PATH:-}" \
    --arg runner         "${CI_RUNNER_DESCRIPTION:-}" \
    --arg pipeline_name  "${WARPRUN_PIPELINE_NAME:-}" \
    --arg error_context  "${FEEDBACK_ERROR_CONTEXT:-}" \
    '{
      gitlab_pipeline_id:    $pipeline_id,
      gitlab_pipeline_url:   $pipeline_url,
      gitlab_job_id:         $job_id,
      gitlab_project_path:   $project_path,
      runner_description:    $runner,
      warprun_pipeline_name: $pipeline_name,
      error_context:         $error_context
    }')

  PAYLOAD=$(jq -n \
    --arg  requestId     "$WARPRUN_REQUEST_ID" \
    --arg  externalRunId "$EXTERNAL_RUN_ID" \
    --argjson status     "$STATUS_CODE" \
    --argjson outputData "$OUTPUT_DATA" \
    --arg  errorMessage  "$ERROR_MESSAGE" \
    '{
      requestId:     $requestId,
      externalRunId: $externalRunId,
      status:        $status,
      outputData:    $outputData,
      errorMessage:  $errorMessage
    }')
else
  # Success or Cancelled: no outputData, no errorMessage
  PAYLOAD=$(jq -n \
    --arg  requestId     "$WARPRUN_REQUEST_ID" \
    --arg  externalRunId "$EXTERNAL_RUN_ID" \
    --argjson status     "$STATUS_CODE" \
    '{
      requestId:     $requestId,
      externalRunId: $externalRunId,
      status:        $status,
      outputData:    null,
      errorMessage:  null
    }')
fi

# ── Debug: print target URL and full payload ──────────────────────────────────
FEEDBACK_URL="${WARPRUN_API_URL}/api/backend-feedback"

echo ""
echo "[warprun-feedback] ┌─────────────────────────────────────────┐"
echo "[warprun-feedback] │           REQUEST DETAILS               │"
echo "[warprun-feedback] └─────────────────────────────────────────┘"
echo "[warprun-feedback] URL    : POST ${FEEDBACK_URL}"
echo "[warprun-feedback] Header : X-Correlation-Id: ${WARPRUN_CORRELATION_ID:-}"
echo "[warprun-feedback] Payload:"
echo "$PAYLOAD" | jq .
echo ""

# ── POST to WarpRun backend-feedback endpoint ─────────────────────────────────
echo "[warprun-feedback] Sending..."

HTTP_STATUS=$(curl --silent \
  --output /tmp/warprun_response.json \
  --write-out "%{http_code}" \
  --request POST \
  --url "${FEEDBACK_URL}" \
  --header "Authorization: Bearer ${ACCESS_TOKEN}" \
  --header "Content-Type: application/json" \
  --header "X-Correlation-Id: ${WARPRUN_CORRELATION_ID:-}" \
  --data "${PAYLOAD}")

RESPONSE_BODY=$(cat /tmp/warprun_response.json 2>/dev/null || echo "")

echo "[warprun-feedback] ┌─────────────────────────────────────────┐"
echo "[warprun-feedback] │           RESPONSE DETAILS              │"
echo "[warprun-feedback] └─────────────────────────────────────────┘"
echo "[warprun-feedback] HTTP Status : $HTTP_STATUS"
echo "[warprun-feedback] Body        :"
echo "$RESPONSE_BODY" | jq . 2>/dev/null || echo "$RESPONSE_BODY"
echo ""

case "$HTTP_STATUS" in
  200)
    echo "[warprun-feedback] ✅ Feedback accepted."
    ;;
  409)
    # Already in terminal state — safe to ignore (idempotency)
    echo "[warprun-feedback] ⚠️  Already in terminal state (409). Skipping."
    ;;
  404)
    echo "[warprun-feedback] ❌ RequestId not found (404): ${WARPRUN_REQUEST_ID}"
    exit 1
    ;;
  401|403)
    echo "[warprun-feedback] ❌ Auth error (${HTTP_STATUS}). Check KEYCLOAK_CLIENT_SECRET and pipelines.feedback permission."
    exit 1
    ;;
  *)
    echo "[warprun-feedback] ❌ Unexpected HTTP ${HTTP_STATUS}"
    exit 1
    ;;
esac
