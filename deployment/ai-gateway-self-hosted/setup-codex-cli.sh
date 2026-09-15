#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/demo.env}"

set -a
source "$ENV_FILE"
set +a

APIM_NAME="apim-aigw-shgw-${SUFFIX}"
GATEWAY_NAME="shgw-demo"
CONTAINER_APP_NAME="ca-shgw-demo"
APP_DISPLAY_NAME="Codex CLI Self-Hosted AI Gateway"
SCOPE_ID="4b902428-a636-4a90-b384-66309077a101"
ROLE_ID="4b902428-a636-4a90-b384-66309077a102"
AZURE_CLI_CLIENT_ID="04b07795-8ddb-461a-bbee-02f9e1bf7b46"
CODEX_API_ID="codex-cli-foundry"
CODEX_PROFILE_NAME="foundry-gateway"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
FOUNDRY_PROJECT_NAME="${FOUNDRY_PROJECT_NAME:-proj-aigw-shgw-demo}"
CODEX_MODEL_DEPLOYMENT="${CODEX_MODEL_DEPLOYMENT:-gpt-5.1-codex}"
CODEX_TOKENS_PER_MINUTE="${CODEX_TOKENS_PER_MINUTE:-500000}"
CODEX_ACCESS_GROUP="${CODEX_ACCESS_GROUP:-}"

for command_name in az jq python3; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "[ERROR] Required command not found: $command_name" >&2
    exit 1
  }
done

az account set --subscription "$SUBSCRIPTION_ID"
tenant_id="$(az account show --query tenantId --output tsv)"
signed_in_user_id="$(az ad signed-in-user show --query id --output tsv)"

echo '[INFO] Creating the Codex gateway API registration'
app_object_id="$(az ad app list --filter "displayName eq '$APP_DISPLAY_NAME'" --query '[0].id' --output tsv)"
if [[ -z "$app_object_id" ]]; then
  app_object_id="$(az ad app create --display-name "$APP_DISPLAY_NAME" --sign-in-audience AzureADMyOrg --query id --output tsv)"
fi
app_id="$(az ad app show --id "$app_object_id" --query appId --output tsv)"
audience="api://${app_id}"

az rest --method patch \
  --url "https://graph.microsoft.com/v1.0/applications/${app_object_id}" \
  --headers 'Content-Type=application/json' \
  --body "$(jq -n \
    --arg audience "$audience" \
    --arg scopeId "$SCOPE_ID" \
    --arg roleId "$ROLE_ID" \
    --arg cliId "$AZURE_CLI_CLIENT_ID" \
    '{
      identifierUris:[$audience],
      api:{
        requestedAccessTokenVersion:2,
        oauth2PermissionScopes:[{
          id:$scopeId,
          adminConsentDescription:"Invoke the organization AI gateway as the signed-in user.",
          adminConsentDisplayName:"Invoke AI Gateway",
          isEnabled:true,
          type:"User",
          userConsentDescription:"Invoke the organization AI gateway.",
          userConsentDisplayName:"Invoke AI Gateway",
          value:"AiGateway.Invoke"
        }]
      },
      appRoles:[{
        allowedMemberTypes:["User"],
        description:"Allows assigned users and groups to invoke the AI gateway.",
        displayName:"AI Gateway Invoke",
        id:$roleId,
        isEnabled:true,
        value:"Gateway.Invoke"
      }]
    }')" \
  --output none

az rest --method patch \
  --url "https://graph.microsoft.com/v1.0/applications/${app_object_id}" \
  --headers 'Content-Type=application/json' \
  --body "$(jq -n \
    --arg scopeId "$SCOPE_ID" \
    --arg cliId "$AZURE_CLI_CLIENT_ID" \
    '{api:{
      requestedAccessTokenVersion:2,
      oauth2PermissionScopes:[{
        id:$scopeId,
        adminConsentDescription:"Invoke the organization AI gateway as the signed-in user.",
        adminConsentDisplayName:"Invoke AI Gateway",
        isEnabled:true,
        type:"User",
        userConsentDescription:"Invoke the organization AI gateway.",
        userConsentDisplayName:"Invoke AI Gateway",
        value:"AiGateway.Invoke"
      }],
      preAuthorizedApplications:[{appId:$cliId,delegatedPermissionIds:[$scopeId]}]
    }}')" \
  --output none

service_principal_id="$(az ad sp list --filter "appId eq '$app_id'" --query '[0].id' --output tsv)"
if [[ -z "$service_principal_id" ]]; then
  service_principal_id="$(az ad sp create --id "$app_id" --query id --output tsv)"
fi
az rest --method patch \
  --url "https://graph.microsoft.com/v1.0/servicePrincipals/${service_principal_id}" \
  --headers 'Content-Type=application/json' \
  --body '{"appRoleAssignmentRequired":true}' \
  --output none

assignment_count="$(az rest --method get \
  --url "https://graph.microsoft.com/v1.0/servicePrincipals/${service_principal_id}/appRoleAssignedTo" \
  --query "value[?principalId=='${signed_in_user_id}' && appRoleId=='${ROLE_ID}'] | length(@)" \
  --output tsv)"
if [[ "$assignment_count" -eq 0 ]]; then
  az rest --method post \
    --url "https://graph.microsoft.com/v1.0/servicePrincipals/${service_principal_id}/appRoleAssignedTo" \
    --headers 'Content-Type=application/json' \
    --body "$(jq -n --arg principalId "$signed_in_user_id" --arg resourceId "$service_principal_id" --arg appRoleId "$ROLE_ID" '{principalId:$principalId,resourceId:$resourceId,appRoleId:$appRoleId}')" \
    --output none
fi

if [[ -n "$CODEX_ACCESS_GROUP" ]]; then
  access_group_id="$(az ad group show --group "$CODEX_ACCESS_GROUP" --query id --output tsv)"
  group_assignment_count="$(az rest --method get \
    --url "https://graph.microsoft.com/v1.0/servicePrincipals/${service_principal_id}/appRoleAssignedTo" \
    --query "value[?principalId=='${access_group_id}' && appRoleId=='${ROLE_ID}'] | length(@)" \
    --output tsv)"
  if [[ "$group_assignment_count" -eq 0 ]]; then
    az rest --method post \
      --url "https://graph.microsoft.com/v1.0/servicePrincipals/${service_principal_id}/appRoleAssignedTo" \
      --headers 'Content-Type=application/json' \
      --body "$(jq -n --arg principalId "$access_group_id" --arg resourceId "$service_principal_id" --arg appRoleId "$ROLE_ID" '{principalId:$principalId,resourceId:$resourceId,appRoleId:$appRoleId}')" \
      --output none
  fi
fi

echo '[INFO] Deploying the Entra-only Codex API to APIM'
az deployment group create \
  --name codex-cli-self-hosted-gateway \
  --resource-group "$RESOURCE_GROUP" \
  --template-file "$SCRIPT_DIR/codex-cli-api.bicep" \
  --parameters \
    apimName="$APIM_NAME" \
    foundryBackendId="$FOUNDRY_API_ID" \
    foundryProjectName="$FOUNDRY_PROJECT_NAME" \
    entraTenantId="$tenant_id" \
    entraAudience="$app_id" \
    modelDeploymentName="$CODEX_MODEL_DEPLOYMENT" \
    tokensPerMinute="$CODEX_TOKENS_PER_MINUTE" \
  --output none

az rest --method put \
  --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.ApiManagement/service/${APIM_NAME}/gateways/${GATEWAY_NAME}/apis/${CODEX_API_ID}?api-version=2024-05-01" \
  --headers 'Content-Type=application/json' \
  --body '{"properties":{"provisioningState":"created"}}' \
  --output none

echo '[INFO] Allowing the Codex API audience through Container Apps authentication'
auth_config_url="https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.App/containerApps/${CONTAINER_APP_NAME}/authConfigs/current?api-version=2024-03-01"
current_auth="$(az rest --method get --url "$auth_config_url" --output json)"
updated_auth="$(printf '%s' "$current_auth" | jq --arg audience "$audience" --arg clientId "$app_id" '
  .properties.identityProviders.azureActiveDirectory.validation.allowedAudiences = (((.properties.identityProviders.azureActiveDirectory.validation.allowedAudiences // []) + [$audience, $clientId]) | unique)
  | .properties.globalValidation.excludedPaths = ((((.properties.globalValidation.excludedPaths // []) - ["/codex/*"]) + ["/codex/openai/v1/responses"]) | unique)
  | {properties:.properties}')"
az rest --method put --url "$auth_config_url" --headers 'Content-Type=application/json' --body "$updated_auth" --output none

fqdn="$(az containerapp show --name "$CONTAINER_APP_NAME" --resource-group "$RESOURCE_GROUP" --query properties.configuration.ingress.fqdn --output tsv)"
mkdir -p "$CODEX_HOME"
profile_path="$CODEX_HOME/${CODEX_PROFILE_NAME}.config.toml"
cat > "$profile_path" <<EOF
model = "$CODEX_MODEL_DEPLOYMENT"
model_provider = "foundry_gateway"
model_reasoning_effort = "medium"

[model_providers.foundry_gateway]
name = "Microsoft Foundry through self-hosted APIM"
base_url = "https://${fqdn}/codex/openai/v1"
wire_api = "responses"
requires_openai_auth = false
supports_websockets = false

[model_providers.foundry_gateway.auth]
command = "az"
args = ["account", "get-access-token", "--resource", "${audience}", "--query", "accessToken", "--output", "tsv"]
timeout_ms = 15000
refresh_interval_ms = 300000
EOF
chmod 600 "$profile_path"

echo '[OK] Codex CLI gateway configuration is ready.'
echo "[INFO] Entra application ID: $app_id"
echo "[INFO] Entra scope: ${audience}/AiGateway.Invoke"
echo "[INFO] Codex profile: $profile_path"
echo '[INFO] Start with: codex --profile foundry-gateway'