#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# Deploy sync code to an existing Azure Function App and/or ACA Job.
# Updates app settings + publishes code / rebuilds container image.
#
# Usage:  TARGET={func|aca|both}  ./deploy-existing.sh
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$SYNC_DIR/.." && pwd)"

[[ -f "$ROOT_DIR/.env" ]] && { set -a; source "$ROOT_DIR/.env"; set +a; }
[[ -f "$SYNC_DIR/.env" ]] && { set -a; source "$SYNC_DIR/.env"; set +a; }

TARGET="${TARGET:-both}"
VALIDATE_ONLY="${VALIDATE_ONLY:-false}"

case "$TARGET" in
    func|aca|both) ;;
    *) echo "[ERROR] TARGET must be: func, aca, both" >&2; exit 1 ;;
esac

# ── Config ──────────────────────────────────────────────────────────────────
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-}"
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-sharepoint-sync}"
TIMER_SCHEDULE="${TIMER_SCHEDULE:-0 0 2 * * *}"

FUNCTION_APP_NAME="${FUNCTION_APP_NAME:-}"
ACA_JOB_NAME="${ACA_JOB_NAME:-}"
ACA_JOB_SCHEDULE="${ACA_JOB_SCHEDULE:-$TIMER_SCHEDULE}"
ACA_JOB_TRIGGER_TYPE="${ACA_JOB_TRIGGER_TYPE:-Schedule}"

# ACA cron: convert 6-field → 5-field
ACA_CRON="$ACA_JOB_SCHEDULE"
[[ $(echo "$ACA_CRON" | wc -w) -eq 6 ]] && ACA_CRON="$(echo "$ACA_CRON" | cut -d' ' -f2-6)"

# Image config (ACA)
ACR_NAME="${ACR_NAME:-}"
ACR_IMAGE_REPO="${ACR_IMAGE_REPO:-sharepoint-sync}"
IMAGE_TAG="${IMAGE_TAG:-$(date +%Y%m%d%H%M%S)}"
IMAGE_NAME="${IMAGE_NAME:-}"

# ── Validation ──────────────────────────────────────────────────────────────
for var in SUBSCRIPTION_ID SHAREPOINT_SITE_URL AZURE_STORAGE_ACCOUNT_NAME AZURE_BLOB_CONTAINER_NAME; do
    [[ -z "${!var:-}" ]] && { echo "[ERROR] $var is required" >&2; exit 1; }
done

[[ "$TARGET" != "aca" && -z "$FUNCTION_APP_NAME" ]] && \
    { echo "[ERROR] FUNCTION_APP_NAME required for func target" >&2; exit 1; }
[[ "$TARGET" != "func" && -z "$ACA_JOB_NAME" ]] && \
    { echo "[ERROR] ACA_JOB_NAME required for aca target" >&2; exit 1; }
[[ "$TARGET" != "func" && -z "$IMAGE_NAME" && -z "$ACR_NAME" ]] && \
    { echo "[ERROR] Set IMAGE_NAME or ACR_NAME for ACA" >&2; exit 1; }

command -v az >/dev/null 2>&1 || { echo "[ERROR] az CLI required" >&2; exit 1; }
[[ "$TARGET" != "aca" ]] && {
    command -v func >/dev/null 2>&1 || { echo "[ERROR] func CLI required" >&2; exit 1; }
}

echo "[INFO] TARGET=$TARGET"
[[ "$TARGET" != "aca" ]] && echo "[INFO] Function App: $FUNCTION_APP_NAME"
[[ "$TARGET" != "func" ]] && echo "[INFO] ACA Job: $ACA_JOB_NAME"

if [[ "$VALIDATE_ONLY" = "true" ]]; then
    echo "[OK] Validation passed"; exit 0
fi

az account set --subscription "$SUBSCRIPTION_ID"

# Shared app settings
APP_SETTINGS=(
    "SHAREPOINT_SITE_URL=$SHAREPOINT_SITE_URL"
    "SHAREPOINT_DRIVE_NAME=${SHAREPOINT_DRIVE_NAME:-Documents}"
    "SHAREPOINT_FOLDER_PATH=${SHAREPOINT_FOLDER_PATH:-/}"
    "AZURE_STORAGE_ACCOUNT_NAME=$AZURE_STORAGE_ACCOUNT_NAME"
    "AZURE_BLOB_CONTAINER_NAME=$AZURE_BLOB_CONTAINER_NAME"
    "AZURE_BLOB_PREFIX=${AZURE_BLOB_PREFIX:-}"
    "DELETE_ORPHANED_BLOBS=${DELETE_ORPHANED_BLOBS:-false}"
    "DRY_RUN=${DRY_RUN:-false}"
    "SYNC_PERMISSIONS=${SYNC_PERMISSIONS:-false}"
    "FORCE_FULL_SYNC=${FORCE_FULL_SYNC:-false}"
    "AZURE_CLIENT_ID=${AZURE_CLIENT_ID:-}"
    "AZURE_CLIENT_SECRET=${AZURE_CLIENT_SECRET:-}"
    "AZURE_TENANT_ID=${AZURE_TENANT_ID:-}"
)

# Build ACA image early (before any updates)
if [[ "$TARGET" != "func" && -z "$IMAGE_NAME" ]]; then
    echo "[INFO] Building image via ACR: $ACR_NAME"
    az acr build --registry "$ACR_NAME" \
        --image "$ACR_IMAGE_REPO:$IMAGE_TAG" "$SYNC_DIR"
    LOGIN_SERVER=$(az acr show --name "$ACR_NAME" --query loginServer -o tsv)
    IMAGE_NAME="$LOGIN_SERVER/$ACR_IMAGE_REPO:$IMAGE_TAG"
fi

# ── Function App ────────────────────────────────────────────────────────────
if [[ "$TARGET" = "func" || "$TARGET" = "both" ]]; then
    echo ""
    echo "═══ Updating Function App: $FUNCTION_APP_NAME ═══"

    az functionapp show \
        --name "$FUNCTION_APP_NAME" --resource-group "$RESOURCE_GROUP" \
        --output none

    echo "[INFO] Updating app settings"
    az functionapp config appsettings set \
        --name "$FUNCTION_APP_NAME" --resource-group "$RESOURCE_GROUP" \
        --settings "${APP_SETTINGS[@]}" "TIMER_SCHEDULE=$TIMER_SCHEDULE" \
        --output none

    echo "[INFO] Publishing code"
    cd "$SYNC_DIR"
    func azure functionapp publish "$FUNCTION_APP_NAME" --python

    echo "[OK] Function App updated: $FUNCTION_APP_NAME"
fi

# ── ACA Job ─────────────────────────────────────────────────────────────────
if [[ "$TARGET" = "aca" || "$TARGET" = "both" ]]; then
    echo ""
    echo "═══ Updating ACA Job: $ACA_JOB_NAME ═══"

    az containerapp job show \
        --name "$ACA_JOB_NAME" --resource-group "$RESOURCE_GROUP" \
        --output none

    UPDATE_ARGS=(
        --name "$ACA_JOB_NAME"
        --resource-group "$RESOURCE_GROUP"
        --image "$IMAGE_NAME"
        --cpu 0.5 --memory 1.0Gi
        --set-env-vars "${APP_SETTINGS[@]}"
        --output none
    )

    [[ "$ACA_JOB_TRIGGER_TYPE" = "Schedule" ]] && \
        UPDATE_ARGS+=(--cron-expression "$ACA_CRON")

    echo "[INFO] Updating job"
    az containerapp job update "${UPDATE_ARGS[@]}"

    echo "[OK] ACA Job updated: $ACA_JOB_NAME  Image: $IMAGE_NAME"
fi

echo ""
echo "[SUCCESS] Existing resources updated (TARGET=$TARGET)"
