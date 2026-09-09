#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/demo.env}"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  source "$ENV_FILE"
  set +a
fi

SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-00000000-0000-0000-0000-000000000000}"
LOCATION="${LOCATION:-swedencentral}"
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-aigw-shgw-demo}"
SUFFIX="${SUFFIX:-demo1234}"
PUBLISHER_NAME="${PUBLISHER_NAME:-AI Gateway Demo}"
PUBLISHER_EMAIL="${PUBLISHER_EMAIL:-admin@example.com}"
APIM_NAME="apim-aigw-shgw-${SUFFIX}"
GATEWAY_NAME="shgw-demo"
DEPLOYMENT_NAME="aigw-shgw-demo"
REGISTRY_NAME="acraigwshgw${SUFFIX}"
UI_IMAGE_REPOSITORY="aigw-demo-ui"
CONTENT_SAFETY_CONTAINER_ACCOUNT_NAME="csc-aigw-shgw-${SUFFIX}"
CONTENT_SAFETY_APP_NAME="ca-content-safety"
CONTENT_SAFETY_PROFILE_NAME="cs-d4"
CONTAINER_ENVIRONMENT_NAME="cae-aigw-shgw-${SUFFIX}"
MODE="${1:-all}"

case "$MODE" in
  infra|gateway|ui|assign|safety-container|safety-local|all) ;;
  *) echo "Usage: $0 [infra|gateway|ui|assign|safety-container|safety-local|all]" >&2; exit 2 ;;
esac

for command_name in az jq curl; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "[ERROR] Required command not found: $command_name" >&2
    exit 1
  }
done

az account set --subscription "$SUBSCRIPTION_ID"
actual_subscription="$(az account show --query id -o tsv)"
[[ "$actual_subscription" == "$SUBSCRIPTION_ID" ]] || {
  echo "[ERROR] Active subscription mismatch: $actual_subscription" >&2
  exit 1
}

deploy_infrastructure() {
  echo "[INFO] Deploying base resources to $SUBSCRIPTION_ID / $LOCATION"
  az deployment sub create \
    --name "$DEPLOYMENT_NAME" \
    --location "$LOCATION" \
    --template-file "$SCRIPT_DIR/main.bicep" \
    --parameters "$SCRIPT_DIR/main.bicepparam" \
    --parameters \
      location="$LOCATION" \
      resourceGroupName="$RESOURCE_GROUP" \
      suffix="$SUFFIX" \
      publisherName="$PUBLISHER_NAME" \
      publisherEmail="$PUBLISHER_EMAIL" \
      deployGatewayContainer=false \
    --output none

  echo "[OK] Base resources deployed. APIM is configured for the Preview release channel."
}

deploy_gateway_container() {
  local deploy_ui="${1:-false}"
  local gateway_url token_expiry gateway_token gateway_auth
  local ui_image='' registry_server='' registry_username='' registry_password='' ui_api_key=''
  gateway_url="https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.ApiManagement/service/${APIM_NAME}/gateways/${GATEWAY_NAME}"
  token_expiry="$(date -u -v+7d '+%Y-%m-%dT%H:%M:%SZ')"

  if [[ "$deploy_ui" == 'true' ]]; then
    : "${APIM_SUBSCRIPTION_ID:?Set APIM_SUBSCRIPTION_ID in $ENV_FILE after Foundry association}"
    local ui_image_tag="${UI_IMAGE_TAG:-$(date -u '+%Y%m%d%H%M%S')}"

    if ! az acr show --name "$REGISTRY_NAME" --resource-group "$RESOURCE_GROUP" --output none 2>/dev/null; then
      echo "[INFO] Creating the private demo UI registry"
      az deployment sub create \
        --name "${DEPLOYMENT_NAME}-registry" \
        --location "$LOCATION" \
        --template-file "$SCRIPT_DIR/main.bicep" \
        --parameters "$SCRIPT_DIR/main.bicepparam" \
        --parameters deployGatewayContainer=false deployDemoUi=false \
        --output none
    fi

    echo "[INFO] Building the end-user demo UI image in Azure Container Registry"
    az acr build \
      --registry "$REGISTRY_NAME" \
      --image "${UI_IMAGE_REPOSITORY}:${ui_image_tag}" \
      "$SCRIPT_DIR/ui" \
      --output none

    registry_server="$(az acr show --name "$REGISTRY_NAME" --query loginServer --output tsv)"
    registry_username="$(az acr credential show --name "$REGISTRY_NAME" --query username --output tsv)"
    registry_password="$(az acr credential show --name "$REGISTRY_NAME" --query 'passwords[0].value' --output tsv)"
    ui_image="${registry_server}/${UI_IMAGE_REPOSITORY}:${ui_image_tag}"
    ui_api_key="$(az rest --method post \
      --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.ApiManagement/service/${APIM_NAME}/subscriptions/${APIM_SUBSCRIPTION_ID}/listSecrets?api-version=2024-05-01" \
      --query primaryKey --output tsv)"
  fi

  echo "[INFO] Generating a seven-day self-hosted gateway bootstrap token in memory"
  gateway_token="$(az rest \
    --method post \
    --url "${gateway_url}/generateToken?api-version=2024-05-01" \
    --headers 'Content-Type=application/json' \
    --body "{\"keyType\":\"primary\",\"expiry\":\"${token_expiry}\"}" \
    --query value \
    --output tsv)"
  [[ -n "$gateway_token" ]] || { echo "[ERROR] Gateway token generation returned no value" >&2; exit 1; }
  gateway_auth="GatewayKey ${gateway_token}"

  echo "[INFO] Deploying the self-hosted gateway to Azure Container Apps"
  az deployment sub create \
    --name "${DEPLOYMENT_NAME}-container" \
    --location "$LOCATION" \
    --template-file "$SCRIPT_DIR/main.bicep" \
    --parameters "$SCRIPT_DIR/main.bicepparam" \
    --parameters \
      location="$LOCATION" \
      resourceGroupName="$RESOURCE_GROUP" \
      suffix="$SUFFIX" \
      publisherName="$PUBLISHER_NAME" \
      publisherEmail="$PUBLISHER_EMAIL" \
      deployGatewayContainer=true \
      deployDemoUi="$deploy_ui" \
      gatewayAuthValue="$gateway_auth" \
      uiImage="$ui_image" \
      registryServer="$registry_server" \
      registryUsername="$registry_username" \
      registryPassword="$registry_password" \
      uiApiKey="$ui_api_key" \
    --output none

  unset gateway_auth gateway_token registry_password ui_api_key
  local fqdn
  fqdn="$(az containerapp show --name ca-shgw-demo --resource-group "$RESOURCE_GROUP" --query properties.configuration.ingress.fqdn -o tsv)"
  echo "[OK] Gateway endpoint: https://${fqdn}"
}

assign_foundry_api() {
  local api_id="${FOUNDRY_API_ID:-}"
  if [[ -z "$api_id" ]]; then
    echo "[ERROR] Set FOUNDRY_API_ID in $ENV_FILE after the Foundry AI Gateway association." >&2
    echo "[INFO] Current APIs:"
    az apim api list --service-name "$APIM_NAME" --resource-group "$RESOURCE_GROUP" \
      --query '[].{id:name,displayName:displayName,path:path}' --output table
    exit 1
  fi

  echo "[INFO] Assigning API $api_id to self-hosted gateway $GATEWAY_NAME"
  az rest \
    --method put \
    --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.ApiManagement/service/${APIM_NAME}/gateways/${GATEWAY_NAME}/apis/${api_id}?api-version=2024-05-01" \
    --headers 'Content-Type=application/json' \
    --body '{"properties":{"provisioningState":"created"}}' \
    --output none
  echo "[OK] API assigned. Allow up to two minutes for gateway synchronization."
}

deploy_content_safety_container() {
  local content_safety_key billing_endpoint latest_revision stale_revision revision_suffix

  echo "[INFO] Deploying the tagged container-only Content Safety metering account"
  az deployment group create \
    --name "${DEPLOYMENT_NAME}-content-safety-container-account" \
    --resource-group "$RESOURCE_GROUP" \
    --template-file "$SCRIPT_DIR/content-safety-container-account.bicep" \
    --parameters location="$LOCATION" suffix="$SUFFIX" \
    --output none

  if [[ "${ROTATE_CONTENT_SAFETY_KEY:-false}" == 'true' ]]; then
    echo "[INFO] Regenerating Key1 after enabling local authentication"
    az cognitiveservices account keys regenerate \
      --resource-group "$RESOURCE_GROUP" \
      --name "$CONTENT_SAFETY_CONTAINER_ACCOUNT_NAME" \
      --key-name Key1 \
      --output none
  fi

  if [[ "$(az containerapp env workload-profile list --name "$CONTAINER_ENVIRONMENT_NAME" --resource-group "$RESOURCE_GROUP" --query "[?name=='${CONTENT_SAFETY_PROFILE_NAME}'] | length(@)" --output tsv)" -eq 0 ]]; then
    echo "[INFO] Adding the D4 workload profile for the large Content Safety image"
    az containerapp env workload-profile add \
      --name "$CONTAINER_ENVIRONMENT_NAME" \
      --resource-group "$RESOURCE_GROUP" \
      --workload-profile-name "$CONTENT_SAFETY_PROFILE_NAME" \
      --workload-profile-type D4 \
      --min-nodes 0 \
      --max-nodes 1 \
      --output none
  fi

  if az containerapp show --name "$CONTENT_SAFETY_APP_NAME" --resource-group "$RESOURCE_GROUP" --output none 2>/dev/null; then
    latest_revision="$(az containerapp show --name "$CONTENT_SAFETY_APP_NAME" --resource-group "$RESOURCE_GROUP" --query properties.latestRevisionName --output tsv)"
    while IFS= read -r stale_revision; do
      [[ -z "$stale_revision" || "$stale_revision" == "$latest_revision" ]] && continue
      az containerapp revision deactivate \
        --name "$CONTENT_SAFETY_APP_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --revision "$stale_revision" \
        --output none
    done < <(az containerapp revision list --name "$CONTENT_SAFETY_APP_NAME" --resource-group "$RESOURCE_GROUP" --query '[?properties.active].name' --output tsv)
  fi

  content_safety_key="$(az cognitiveservices account keys list --resource-group "$RESOURCE_GROUP" --name "$CONTENT_SAFETY_CONTAINER_ACCOUNT_NAME" --query key1 --output tsv)"
  billing_endpoint="$(az cognitiveservices account show --resource-group "$RESOURCE_GROUP" --name "$CONTENT_SAFETY_CONTAINER_ACCOUNT_NAME" --query properties.endpoint --output tsv)"
  revision_suffix="$(date -u '+%Y%m%d%H%M%S')"
  echo "[INFO] Deploying the internal Content Safety container on D4"
  az deployment group create \
    --name "${DEPLOYMENT_NAME}-content-safety-container" \
    --resource-group "$RESOURCE_GROUP" \
    --template-file "$SCRIPT_DIR/content-safety-container.bicep" \
    --parameters \
      location="$LOCATION" \
      containerEnvironmentName="$CONTAINER_ENVIRONMENT_NAME" \
      workloadProfileName="$CONTENT_SAFETY_PROFILE_NAME" \
      contentSafetyKey="$content_safety_key" \
      contentSafetyBillingEndpoint="$billing_endpoint" \
      revisionSuffix="$revision_suffix" \
    --output none
  unset content_safety_key

  latest_revision="$(az containerapp show --name "$CONTENT_SAFETY_APP_NAME" --resource-group "$RESOURCE_GROUP" --query properties.latestRevisionName --output tsv)"
  while IFS= read -r stale_revision; do
    [[ -z "$stale_revision" || "$stale_revision" == "$latest_revision" ]] && continue
    az containerapp revision deactivate \
      --name "$CONTENT_SAFETY_APP_NAME" \
      --resource-group "$RESOURCE_GROUP" \
      --revision "$stale_revision" \
      --output none
  done < <(az containerapp revision list --name "$CONTENT_SAFETY_APP_NAME" --resource-group "$RESOURCE_GROUP" --query '[?properties.active].name' --output tsv)

  echo "[OK] Content Safety container deployment submitted. Managed APIM safety routing is unchanged."
}

use_content_safety_container() {
  : "${APIM_SUBSCRIPTION_ID:?Set APIM_SUBSCRIPTION_ID in $ENV_FILE after Foundry association}"
  local subscription_scope foundry_product_id safety_fqdn latest_ready_revision
  latest_ready_revision="$(az containerapp show --name "$CONTENT_SAFETY_APP_NAME" --resource-group "$RESOURCE_GROUP" --query properties.latestReadyRevisionName --output tsv)"
  [[ -n "$latest_ready_revision" ]] || { echo '[ERROR] Content Safety container has no ready revision' >&2; exit 1; }
  [[ "$(az containerapp revision show --name "$CONTENT_SAFETY_APP_NAME" --resource-group "$RESOURCE_GROUP" --revision "$latest_ready_revision" --query properties.healthState --output tsv)" == 'Healthy' ]] || {
    echo "[ERROR] Content Safety revision $latest_ready_revision is not healthy" >&2
    exit 1
  }

  subscription_scope="$(az rest --method get \
    --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.ApiManagement/service/${APIM_NAME}/subscriptions/${APIM_SUBSCRIPTION_ID}?api-version=2024-05-01" \
    --query properties.scope --output tsv)"
  [[ "$subscription_scope" == */products/* ]]
  foundry_product_id="${subscription_scope##*/}"
  safety_fqdn="$(az containerapp show --name "$CONTENT_SAFETY_APP_NAME" --resource-group "$RESOURCE_GROUP" --query properties.configuration.ingress.fqdn --output tsv)"

  echo "[INFO] Routing APIM Content Safety checks to the internal container"
  az deployment group create \
    --name "${DEPLOYMENT_NAME}-content-safety" \
    --resource-group "$RESOURCE_GROUP" \
    --template-file "$SCRIPT_DIR/content-safety.bicep" \
    --parameters \
      apimName="$APIM_NAME" \
      foundryProductId="$foundry_product_id" \
      contentSafetyEndpoint="https://${safety_fqdn}" \
    --output none
  echo "[OK] APIM now uses the customer-hosted Content Safety container."
}

case "$MODE" in
  infra) deploy_infrastructure ;;
  gateway) deploy_gateway_container false ;;
  ui) deploy_gateway_container true ;;
  assign) assign_foundry_api ;;
  safety-container) deploy_content_safety_container ;;
  safety-local) use_content_safety_container ;;
  all)
    deploy_infrastructure
    deploy_gateway_container false
    echo "[ACTION] Complete the Foundry AI Gateway association described in README.md, then run:"
    echo "         $0 assign"
    ;;
esac
