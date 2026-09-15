#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/demo.env}"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  source "$ENV_FILE"
  set +a
fi

SUBSCRIPTION_ID="${SUBSCRIPTION_ID:?Set SUBSCRIPTION_ID in $ENV_FILE}"
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-aigw-shgw-demo}"
SUFFIX="${SUFFIX:?Set SUFFIX in $ENV_FILE}"
CONTAINER_APP_NAME="ca-shgw-demo"
TOKEN_STORE_ACCOUNT_NAME="staigwshgw${SUFFIX}"
TOKEN_STORE_CONTAINER_NAME="auth-tokens"
APP_DISPLAY_NAME="AI Gateway Self-Hosted Demo"
LIMITED_GROUP_NAME="AI Gateway Demo Limited"
UNLIMITED_GROUP_NAME="AI Gateway Demo Unlimited"
LIMITED_ROLE_ID="8f0d2e8c-a5a8-4c18-a111-cf908e101001"
UNLIMITED_ROLE_ID="8f0d2e8c-a5a8-4c18-a111-cf908e101002"
KEYCHAIN_SERVICE="aigw-self-hosted-demo"

for command_name in az jq openssl security; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "[ERROR] Required command not found: $command_name" >&2
    exit 1
  }
done

az account set --subscription "$SUBSCRIPTION_ID"
tenant_id="$(az account show --query tenantId --output tsv)"
signed_in_upn="$(az ad signed-in-user show --query userPrincipalName --output tsv)"
tenant_domain="${ENTRA_DEMO_DOMAIN:-${signed_in_upn#*@}}"
app_url="https://$(az containerapp show --name "$CONTAINER_APP_NAME" --resource-group "$RESOURCE_GROUP" --query properties.configuration.ingress.fqdn --output tsv)"
redirect_uri="${app_url}/.auth/login/aad/callback"

upsert_env() {
  local key="$1" value="$2" temp_file
  temp_file="$(mktemp)"
  awk -v key="$key" -v value="$value" '
    BEGIN { updated = 0 }
    $0 ~ "^" key "=" { print key "=" value; updated = 1; next }
    { print }
    END { if (!updated) print key "=" value }
  ' "$ENV_FILE" > "$temp_file"
  mv "$temp_file" "$ENV_FILE"
}

get_or_create_group() {
  local display_name="$1" mail_nickname="$2" group_id
  group_id="$(az ad group list --filter "displayName eq '$display_name'" --query '[0].id' --output tsv)"
  if [[ -z "$group_id" ]]; then
    group_id="$(az ad group create --display-name "$display_name" --mail-nickname "$mail_nickname" --query id --output tsv)"
  fi
  printf '%s' "$group_id"
}

get_or_create_user() {
  local display_name="$1" upn="$2" user_id temporary_password
  user_id="$(az ad user show --id "$upn" --query id --output tsv 2>/dev/null || true)"
  if [[ -z "$user_id" ]]; then
    temporary_password="Aa1!$(openssl rand -hex 16)"
    user_id="$(az ad user create \
      --display-name "$display_name" \
      --user-principal-name "$upn" \
      --password "$temporary_password" \
      --force-change-password-next-sign-in false \
      --query id --output tsv)"
    security add-generic-password -U -a "$upn" -s "$KEYCHAIN_SERVICE" -w "$temporary_password" >/dev/null
    unset temporary_password
  fi
  printf '%s' "$user_id"
}

assign_group_role() {
  local group_id="$1" role_id="$2" assignment_count
  assignment_count="$(az rest --method get \
    --url "https://graph.microsoft.com/v1.0/servicePrincipals/${service_principal_id}/appRoleAssignedTo" \
    --query "value[?principalId=='${group_id}' && appRoleId=='${role_id}'] | length(@)" \
    --output tsv)"
  if [[ "$assignment_count" -eq 0 ]]; then
    az rest --method post \
      --url "https://graph.microsoft.com/v1.0/servicePrincipals/${service_principal_id}/appRoleAssignedTo" \
      --headers 'Content-Type=application/json' \
      --body "$(jq -n --arg principalId "$group_id" --arg resourceId "$service_principal_id" --arg appRoleId "$role_id" '{principalId:$principalId,resourceId:$resourceId,appRoleId:$appRoleId}')" \
      --output none
  fi
}

echo '[INFO] Creating the Entra application and policy roles'
app_object_id="$(az ad app list --filter "displayName eq '$APP_DISPLAY_NAME'" --query '[0].id' --output tsv)"
if [[ -z "$app_object_id" ]]; then
  app_object_id="$(az ad app create \
    --display-name "$APP_DISPLAY_NAME" \
    --sign-in-audience AzureADMyOrg \
    --web-redirect-uris "$redirect_uri" \
    --enable-id-token-issuance true \
    --query id --output tsv)"
fi
app_id="$(az ad app show --id "$app_object_id" --query appId --output tsv)"

az ad app update --id "$app_id" --web-redirect-uris "$redirect_uri" --enable-id-token-issuance true --output none
role_count="$(az ad app show --id "$app_id" --query "appRoles[?value=='AI.Limited' || value=='AI.Unlimited'] | length(@)" --output tsv)"
if [[ "$role_count" -ne 2 ]]; then
  az rest --method patch \
    --url "https://graph.microsoft.com/v1.0/applications/${app_object_id}" \
    --headers 'Content-Type=application/json' \
    --body "$(jq -n \
      --arg limitedRoleId "$LIMITED_ROLE_ID" \
      --arg unlimitedRoleId "$UNLIMITED_ROLE_ID" \
      '{appRoles:[
        {allowedMemberTypes:["User"],description:"Hate threshold 1 and one token per minute",displayName:"AI Gateway Limited",id:$limitedRoleId,isEnabled:true,value:"AI.Limited"},
        {allowedMemberTypes:["User"],description:"Hate threshold 7 and no LLM token limit",displayName:"AI Gateway Unlimited",id:$unlimitedRoleId,isEnabled:true,value:"AI.Unlimited"}
      ]}')" \
    --output none
fi

service_principal_id="$(az ad sp list --filter "appId eq '$app_id'" --query '[0].id' --output tsv)"
if [[ -z "$service_principal_id" ]]; then
  service_principal_id="$(az ad sp create --id "$app_id" --query id --output tsv)"
fi
az rest --method patch \
  --url "https://graph.microsoft.com/v1.0/servicePrincipals/${service_principal_id}" \
  --headers 'Content-Type=application/json' \
  --body '{"appRoleAssignmentRequired":true}' \
  --output none

echo '[INFO] Creating groups, users, and role assignments'
limited_group_id="$(get_or_create_group "$LIMITED_GROUP_NAME" 'aigw-demo-limited')"
unlimited_group_id="$(get_or_create_group "$UNLIMITED_GROUP_NAME" 'aigw-demo-unlimited')"
limited_upn="${ENTRA_LIMITED_USER_UPN:-aigw-limited@${tenant_domain}}"
unlimited_upn="${ENTRA_UNLIMITED_USER_UPN:-aigw-unlimited@${tenant_domain}}"
limited_user_id="$(get_or_create_user 'AI Gateway Limited User' "$limited_upn")"
unlimited_user_id="$(get_or_create_user 'AI Gateway Unlimited User' "$unlimited_upn")"
if [[ "$(az ad group member check --group "$limited_group_id" --member-id "$limited_user_id" --query value --output tsv)" != 'true' ]]; then
  az ad group member add --group "$limited_group_id" --member-id "$limited_user_id"
fi
if [[ "$(az ad group member check --group "$unlimited_group_id" --member-id "$unlimited_user_id" --query value --output tsv)" != 'true' ]]; then
  az ad group member add --group "$unlimited_group_id" --member-id "$unlimited_user_id"
fi
assign_group_role "$limited_group_id" "$LIMITED_ROLE_ID"
assign_group_role "$unlimited_group_id" "$UNLIMITED_ROLE_ID"

echo '[INFO] Scoping Conditional Access exclusions to the demo application'
mfa_exclusion_group_id="$(get_or_create_group 'AI Gateway Demo MFA Exclusion' 'aigw-demo-mfa-exclusion')"
for user_id in "$limited_user_id" "$unlimited_user_id"; do
  if [[ "$(az ad group member check --group "$mfa_exclusion_group_id" --member-id "$user_id" --query value --output tsv)" != 'true' ]]; then
    az ad group member add --group "$mfa_exclusion_group_id" --member-id "$user_id"
  fi
done
conditional_access_policies="$(az rest --method get --url 'https://graph.microsoft.com/beta/identity/conditionalAccess/policies' --output json)"
printf '%s' "$conditional_access_policies" | jq -r '.value[] | select(((.grantControls.builtInControls // []) | index("mfa")) and (((.grantControls.builtInControls // []) | index("passwordChange")) | not)) | .id' | while IFS= read -r policy_id; do
  policy_json="$(az rest --method get --url "https://graph.microsoft.com/beta/identity/conditionalAccess/policies/${policy_id}" --output json)"
  patch_body="$(printf '%s' "$policy_json" | jq --arg appId "$app_id" --arg groupId "$mfa_exclusion_group_id" '.conditions.applications.excludeApplications = (((.conditions.applications.excludeApplications // []) + [$appId]) | unique) | .conditions.users.excludeGroups = (((.conditions.users.excludeGroups // []) + [$groupId]) | unique) | {conditions:.conditions}')"
  az rest --method patch --url "https://graph.microsoft.com/beta/identity/conditionalAccess/policies/${policy_id}" --headers 'Content-Type=application/json' --body "$patch_body" --output none
done
printf '%s' "$conditional_access_policies" | jq -r '.value[] | select(((.grantControls.builtInControls // []) | index("mfa")) and ((.grantControls.builtInControls // []) | index("passwordChange"))) | .id' | while IFS= read -r policy_id; do
  policy_json="$(az rest --method get --url "https://graph.microsoft.com/beta/identity/conditionalAccess/policies/${policy_id}" --output json)"
  patch_body="$(printf '%s' "$policy_json" | jq --arg groupId "$mfa_exclusion_group_id" '.conditions.users.excludeGroups = (((.conditions.users.excludeGroups // []) + [$groupId]) | unique) | {conditions:.conditions}')"
  az rest --method patch --url "https://graph.microsoft.com/beta/identity/conditionalAccess/policies/${policy_id}" --headers 'Content-Type=application/json' --body "$patch_body" --output none
done
printf '%s' "$conditional_access_policies" | jq -r '.value[] | select((.conditions.applications.includeUserActions // []) | index("urn:user:registersecurityinfo")) | .id' | while IFS= read -r policy_id; do
  policy_json="$(az rest --method get --url "https://graph.microsoft.com/beta/identity/conditionalAccess/policies/${policy_id}" --output json)"
  patch_body="$(printf '%s' "$policy_json" | jq --arg groupId "$mfa_exclusion_group_id" '.conditions.users.excludeGroups = (((.conditions.users.excludeGroups // []) + [$groupId]) | unique) | {conditions:.conditions}')"
  az rest --method patch --url "https://graph.microsoft.com/beta/identity/conditionalAccess/policies/${policy_id}" --headers 'Content-Type=application/json' --body "$patch_body" --output none
done

upsert_env ENABLE_ENTRA_AUTH true
upsert_env ENTRA_TENANT_ID "$tenant_id"
upsert_env ENTRA_CLIENT_ID "$app_id"
upsert_env ENTRA_LIMITED_GROUP_ID "$limited_group_id"
upsert_env ENTRA_UNLIMITED_GROUP_ID "$unlimited_group_id"
upsert_env ENTRA_MFA_EXCLUSION_GROUP_ID "$mfa_exclusion_group_id"
upsert_env ENTRA_LIMITED_USER_UPN "$limited_upn"
upsert_env ENTRA_UNLIMITED_USER_UPN "$unlimited_upn"

echo '[INFO] Building and deploying the authenticated UI'
bash "$SCRIPT_DIR/deploy.sh" ui

echo '[INFO] Enabling mandatory Container Apps authentication'
client_secret="$(az ad app credential reset \
  --id "$app_id" \
  --display-name "Easy Auth $(date -u '+%Y-%m-%d')" \
  --years 1 --query password --output tsv)"
az containerapp auth microsoft update \
  --name "$CONTAINER_APP_NAME" --resource-group "$RESOURCE_GROUP" \
  --client-id "$app_id" --client-secret "$client_secret" --tenant-id "$tenant_id" \
  --allowed-token-audiences "$app_id" --yes --output none
unset client_secret

if ! az storage account show --name "$TOKEN_STORE_ACCOUNT_NAME" --resource-group "$RESOURCE_GROUP" --output none 2>/dev/null; then
  az storage account create \
    --name "$TOKEN_STORE_ACCOUNT_NAME" --resource-group "$RESOURCE_GROUP" \
    --location "$(az group show --name "$RESOURCE_GROUP" --query location --output tsv)" \
    --sku Standard_LRS --kind StorageV2 --https-only true \
    --allow-blob-public-access false --min-tls-version TLS1_2 \
    --public-network-access Enabled --tags SecurityControl=Ignore --output none
fi
storage_account_id="$(az storage account show \
  --name "$TOKEN_STORE_ACCOUNT_NAME" --resource-group "$RESOURCE_GROUP" \
  --query id --output tsv)"
az tag update --resource-id "$storage_account_id" --operation Merge --tags SecurityControl=Ignore --output none
az storage account update \
  --name "$TOKEN_STORE_ACCOUNT_NAME" --resource-group "$RESOURCE_GROUP" \
  --public-network-access Enabled --output none
operator_id="$(az ad signed-in-user show --query id --output tsv)"
if [[ "$(az role assignment list --assignee "$operator_id" --scope "$storage_account_id" --role 'Storage Blob Data Contributor' --query 'length(@)' --output tsv)" -eq 0 ]]; then
  az role assignment create \
    --assignee-object-id "$operator_id" --assignee-principal-type User \
    --role 'Storage Blob Data Contributor' --scope "$storage_account_id" --output none
fi
az storage container create \
  --name "$TOKEN_STORE_CONTAINER_NAME" --account-name "$TOKEN_STORE_ACCOUNT_NAME" \
  --auth-mode login --public-access off --output none
sas_expiry="$(date -u -v+6d '+%Y-%m-%dT%H:%MZ')"
token_store_sas="$(az storage container generate-sas \
  --name "$TOKEN_STORE_CONTAINER_NAME" --account-name "$TOKEN_STORE_ACCOUNT_NAME" \
  --auth-mode login --as-user --permissions racwdl --https-only \
  --expiry "$sas_expiry" --output tsv)"
token_store_url="https://${TOKEN_STORE_ACCOUNT_NAME}.blob.core.windows.net/${TOKEN_STORE_CONTAINER_NAME}?${token_store_sas}"
unset token_store_sas
az containerapp auth update \
  --name "$CONTAINER_APP_NAME" --resource-group "$RESOURCE_GROUP" \
  --enabled true --unauthenticated-client-action RedirectToLoginPage \
  --redirect-provider AzureActiveDirectory --token-store true --sas-url-secret "$token_store_url" \
  --excluded-paths /healthz --require-https true --yes --output none
unset token_store_url

echo '[INFO] Enabling role-aware policy enforcement at APIM'
bash "$SCRIPT_DIR/deploy.sh" safety-local

echo '[OK] Entra policy demo configured'
echo "[INFO] Limited user:   $limited_upn"
echo "[INFO] Unlimited user: $unlimited_upn"
echo "[INFO] Retrieve each demo password locally with:"
echo "       security find-generic-password -w -s '$KEYCHAIN_SERVICE' -a '<user-UPN>'"
echo "[INFO] Application URL: $app_url"