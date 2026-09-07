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
MODE="${1:-all}"

case "$MODE" in
  infra|gateway|ui|assign|all) ;;
  *) echo "Usage: $0 [infra|gateway|ui|assign|all]" >&2; exit 2 ;;
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

case "$MODE" in
  infra) deploy_infrastructure ;;
  gateway) deploy_gateway_container false ;;
  ui) deploy_gateway_container true ;;
  assign) assign_foundry_api ;;
  all)
    deploy_infrastructure
    deploy_gateway_container false
    echo "[ACTION] Complete the Foundry AI Gateway association described in README.md, then run:"
    echo "         $0 assign"
    ;;
esac
