#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# Create new Azure Function App and/or ACA Job for SharePoint sync.
# Resources get timestamped names so you can spin up disposable test instances.
#
# Usage:  TARGET={func|aca|both}  ./deploy-new.sh
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
LOCATION="${LOCATION:-francecentral}"
TIMER_SCHEDULE="${TIMER_SCHEDULE:-0 0 2 * * *}"

# Generate unique names
RUN_ID="${RUN_ID:-$(date +%Y%m%d%H%M%S)}"
SUFFIX="${RUN_ID: -8}"

FUNCTION_APP_NAME="${FUNCTION_APP_NAME:-func-spsync-${SUFFIX}}"
FUNCTION_STORAGE_ACCOUNT="${FUNCTION_STORAGE_ACCOUNT:-stfuncsp${SUFFIX}}"
FUNCTION_STORAGE_ACCOUNT="${FUNCTION_STORAGE_ACCOUNT:0:24}"

ACA_ENV_NAME="${ACA_ENV_NAME:-acae-spsync-${SUFFIX}}"
ACA_JOB_NAME="${ACA_JOB_NAME:-acaj-spsync-${SUFFIX}}"
ACA_JOB_SCHEDULE="${ACA_JOB_SCHEDULE:-$TIMER_SCHEDULE}"
ACA_JOB_TRIGGER_TYPE="${ACA_JOB_TRIGGER_TYPE:-Schedule}"

# ACA cron: convert 6-field → 5-field
ACA_CRON="$ACA_JOB_SCHEDULE"
[[ $(echo "$ACA_CRON" | wc -w) -eq 6 ]] && ACA_CRON="$(echo "$ACA_CRON" | cut -d' ' -f2-6)"

# Image config (ACA)
ACR_NAME="${ACR_NAME:-}"
ACR_IMAGE_REPO="${ACR_IMAGE_REPO:-sharepoint-sync}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
IMAGE_NAME="${IMAGE_NAME:-}"

# ── Validation ──────────────────────────────────────────────────────────────
for var in SUBSCRIPTION_ID SHAREPOINT_SITE_URL AZURE_STORAGE_ACCOUNT_NAME AZURE_BLOB_CONTAINER_NAME; do
    [[ -z "${!var:-}" ]] && { echo "[ERROR] $var is required" >&2; exit 1; }
done

[[ "$TARGET" != "func" && -z "$IMAGE_NAME" && -z "$ACR_NAME" ]] && \
    { echo "[ERROR] For ACA: set IMAGE_NAME or ACR_NAME" >&2; exit 1; }

command -v az >/dev/null 2>&1 || { echo "[ERROR] az CLI required" >&2; exit 1; }
[[ "$TARGET" != "aca" ]] && {
    command -v func >/dev/null 2>&1 || { echo "[ERROR] func CLI required for Function deploy" >&2; exit 1; }
}

echo "[INFO] TARGET=$TARGET  RUN_ID=$RUN_ID"
[[ "$TARGET" != "aca" ]] && echo "[INFO] Function App: $FUNCTION_APP_NAME"
[[ "$TARGET" != "func" ]] && echo "[INFO] ACA Job: $ACA_JOB_NAME  Image source: ${IMAGE_NAME:-ACR $ACR_NAME}"

if [[ "$VALIDATE_ONLY" = "true" ]]; then
    echo "[OK] Validation passed"; exit 0
fi

az account set --subscription "$SUBSCRIPTION_ID"
az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none

# Shared app settings (used by both Function and ACA)
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

# ── Function App ────────────────────────────────────────────────────────────
if [[ "$TARGET" = "func" || "$TARGET" = "both" ]]; then
    echo ""
    echo "═══ Creating Function App ═══"

    echo "[INFO] Creating function storage account: $FUNCTION_STORAGE_ACCOUNT"
    az storage account create \
        --name "$FUNCTION_STORAGE_ACCOUNT" \
        --resource-group "$RESOURCE_GROUP" \
        --location "$LOCATION" \
        --sku Standard_LRS --kind StorageV2 \
        --allow-shared-key-access true --output none

    az storage account update \
        --name "$FUNCTION_STORAGE_ACCOUNT" \
        --resource-group "$RESOURCE_GROUP" \
        --allow-shared-key-access true --output none

    DEPLOY_CONTAINER="app-package-${FUNCTION_APP_NAME}"
    az storage container create \
        --name "$DEPLOY_CONTAINER" \
        --account-name "$FUNCTION_STORAGE_ACCOUNT" \
        --auth-mode login --output none

    echo "[INFO] Creating function app (flex consumption, identity-based storage)"
    az functionapp create \
        --name "$FUNCTION_APP_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --flexconsumption-location "$LOCATION" \
        --storage-account "$FUNCTION_STORAGE_ACCOUNT" \
        --deployment-storage-name "$FUNCTION_STORAGE_ACCOUNT" \
        --deployment-storage-container-name "$DEPLOY_CONTAINER" \
        --deployment-storage-auth-type SystemAssignedIdentity \
        --runtime python --runtime-version 3.11 \
        --functions-version 4 --os-type Linux \
        --assign-identity '[system]' --output none

    PRINCIPAL_ID=$(az functionapp identity assign \
        --name "$FUNCTION_APP_NAME" --resource-group "$RESOURCE_GROUP" \
        --query principalId -o tsv)

    echo "[INFO] Assigning Storage Blob Data Contributor"
    TARGET_STORAGE_ID=$(az storage account show \
        --name "$AZURE_STORAGE_ACCOUNT_NAME" --query id -o tsv)
    FUNC_STORAGE_ID=$(az storage account show \
        --name "$FUNCTION_STORAGE_ACCOUNT" --resource-group "$RESOURCE_GROUP" \
        --query id -o tsv)

    az role assignment create --assignee "$PRINCIPAL_ID" \
        --role "Storage Blob Data Contributor" --scope "$TARGET_STORAGE_ID" \
        --output none 2>/dev/null || true
    az role assignment create --assignee "$PRINCIPAL_ID" \
        --role "Storage Blob Data Contributor" --scope "$FUNC_STORAGE_ID" \
        --output none 2>/dev/null || true

    echo "[INFO] Configuring app settings"
    az functionapp config appsettings set \
        --name "$FUNCTION_APP_NAME" --resource-group "$RESOURCE_GROUP" \
        --settings "${APP_SETTINGS[@]}" "TIMER_SCHEDULE=$TIMER_SCHEDULE" \
        --output none

    echo "[INFO] Publishing function code"
    cd "$SYNC_DIR"
    MAX_ATTEMPTS=5; ATTEMPT=1
    while true; do
        set +e
        OUTPUT=$(func azure functionapp publish "$FUNCTION_APP_NAME" --python 2>&1)
        RC=$?; set -e; echo "$OUTPUT"

        [[ $RC -eq 0 ]] && break

        if echo "$OUTPUT" | grep -q "Uploaded package to storage successfully"; then
            echo "[WARN] Package uploaded but health check unhealthy — continuing."
            break
        fi

        if echo "$OUTPUT" | grep -q "not authorized to perform this operation" && [[ $ATTEMPT -lt $MAX_ATTEMPTS ]]; then
            echo "[WARN] RBAC propagation delay, retry $ATTEMPT/$MAX_ATTEMPTS in 20s..."
            ATTEMPT=$((ATTEMPT + 1)); sleep 20; continue
        fi

        exit $RC
    done

    echo "[OK] Function App ready: $FUNCTION_APP_NAME  Schedule: $TIMER_SCHEDULE"
fi

# ── ACA Job ─────────────────────────────────────────────────────────────────
if [[ "$TARGET" = "aca" || "$TARGET" = "both" ]]; then
    echo ""
    echo "═══ Creating ACA Job ═══"

    # Build image if not provided
    if [[ -z "$IMAGE_NAME" ]]; then
        echo "[INFO] Building image via ACR: $ACR_NAME"
        az acr build --registry "$ACR_NAME" \
            --image "$ACR_IMAGE_REPO:$IMAGE_TAG" "$SYNC_DIR"
        LOGIN_SERVER=$(az acr show --name "$ACR_NAME" --query loginServer -o tsv)
        IMAGE_NAME="$LOGIN_SERVER/$ACR_IMAGE_REPO:$IMAGE_TAG"
    fi

    echo "[INFO] Creating ACA environment: $ACA_ENV_NAME"
    az containerapp env create \
        --name "$ACA_ENV_NAME" --resource-group "$RESOURCE_GROUP" \
        --location "$LOCATION" --output none 2>/dev/null || true

    # Step 1: Create job with a placeholder image (no registry auth needed)
    #         so the system-assigned identity gets created first.
    PLACEHOLDER_IMAGE="mcr.microsoft.com/k8se/quickstart:latest"
    CREATE_ARGS=(
        --name "$ACA_JOB_NAME"
        --resource-group "$RESOURCE_GROUP"
        --environment "$ACA_ENV_NAME"
        --trigger-type "$ACA_JOB_TRIGGER_TYPE"
        --image "$PLACEHOLDER_IMAGE"
        --replica-timeout 1800
        --replica-retry-limit 1
        --replica-completion-count 1
        --parallelism 1
        --cpu 0.5 --memory 1.0Gi
        --mi-system-assigned
    )

    [[ "$ACA_JOB_TRIGGER_TYPE" = "Schedule" ]] && \
        CREATE_ARGS+=(--cron-expression "$ACA_CRON")

    CREATE_ARGS+=(--env-vars "${APP_SETTINGS[@]}" --output none)

    echo "[INFO] Creating ACA job with placeholder image"
    az containerapp job create "${CREATE_ARGS[@]}"

    # Step 2: Assign RBAC (AcrPull on ACR + Storage Blob Data Contributor)
    ACA_PRINCIPAL_ID=$(az containerapp job identity show \
        --name "$ACA_JOB_NAME" --resource-group "$RESOURCE_GROUP" \
        --query principalId -o tsv)

    if [[ -n "$ACR_NAME" ]]; then
        ACR_ID=$(az acr show --name "$ACR_NAME" --query id -o tsv)
        echo "[INFO] Assigning AcrPull to ACA identity on $ACR_NAME"
        az role assignment create --assignee "$ACA_PRINCIPAL_ID" \
            --role "AcrPull" --scope "$ACR_ID" --output none 2>/dev/null || true
    fi

    ACA_TARGET_STORAGE_ID=$(az storage account show \
        --name "$AZURE_STORAGE_ACCOUNT_NAME" --query id -o tsv)
    echo "[INFO] Assigning Storage Blob Data Contributor to ACA identity"
    az role assignment create --assignee "$ACA_PRINCIPAL_ID" \
        --role "Storage Blob Data Contributor" --scope "$ACA_TARGET_STORAGE_ID" \
        --output none 2>/dev/null || true

    echo "[INFO] Waiting 30s for RBAC propagation..."
    sleep 30

    # Step 3: Update job with the real ACR image
    if [[ -n "$ACR_NAME" ]]; then
        REGISTRY_SERVER=$(az acr show --name "$ACR_NAME" --query loginServer -o tsv)
        echo "[INFO] Configuring registry on ACA job: $REGISTRY_SERVER"
        az containerapp job registry set \
            --name "$ACA_JOB_NAME" --resource-group "$RESOURCE_GROUP" \
            --server "$REGISTRY_SERVER" --identity system \
            --output none
    fi

    echo "[INFO] Updating ACA job with real image: $IMAGE_NAME"
    az containerapp job update \
        --name "$ACA_JOB_NAME" --resource-group "$RESOURCE_GROUP" \
        --image "$IMAGE_NAME" --output none

    echo "[OK] ACA Job ready: $ACA_JOB_NAME  Image: $IMAGE_NAME"
    echo "     Start manually: az containerapp job start --name $ACA_JOB_NAME --resource-group $RESOURCE_GROUP"
fi

echo ""
echo "[SUCCESS] New resources deployed (TARGET=$TARGET)"
