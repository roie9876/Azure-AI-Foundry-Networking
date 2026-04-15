#!/bin/bash
set -euo pipefail

###############################################################################
# 3-deploy-sharepoint-sync.sh — SharePoint → Blob → AI Search Sync Pipeline
#
# Deploys on top of an existing hub-spoke + Foundry environment:
#   1. Creates func-subnet with VNet integration delegation
#   2. Creates a Blob container for SharePoint sync in existing storage
#   3. Deploys Azure Function App (Elastic Premium, Python, VNet-integrated)
#   4. Locks down Function App storage (private endpoints)
#   5. Deploys Key Vault (private) with SPN secrets
#   6. Configures Function App settings (KV refs + AI Search + OpenAI)
#   7. Grants RBAC: Function App → Storage, Key Vault
#   8. Creates Shared Private Link: AI Search → Storage (blob indexer)
#   9. Creates AI Search index, data source, and indexer (blob-based)
#  10. Adds firewall rules for Graph API + SharePoint + Entra ID
#  11. Clones sync code and publishes to Function App
#
# Based on: https://github.com/Azure-Samples/sharepoint-foundryIQ-secure-sync
# Credit: Sidali Kadouche (@sidkadouc)
#
# Prerequisites:
#   - Hub + Spoke deployed (1-deploy-hub.sh, 2-deploy-spoke.sh)
#   - Foundry deployed via Bicep (Template 15)
#   - App Registration (SPN) with Sites.Read.All + Files.Read.All
#   - Azure Functions Core Tools (npm i -g azure-functions-core-tools@4)
#   - Copy sharepoint-sync.env.example → sharepoint-sync.env
#
# Usage:
#   cp sharepoint-sync.env.example sharepoint-sync.env   # edit values
#   ./3-deploy-sharepoint-sync.sh
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/sharepoint-sync.env"

if [ ! -f "$ENV_FILE" ]; then
  echo "❌ Missing sharepoint-sync.env — copy sharepoint-sync.env.example and fill in values"
  exit 1
fi

echo "Loading config from sharepoint-sync.env ..."
set -a
source "$ENV_FILE"
set +a

# Validate required variables
REQUIRED_VARS=(
  AZURE_CLIENT_ID AZURE_CLIENT_SECRET AZURE_TENANT_ID
  SHAREPOINT_SITE_URL SHAREPOINT_DRIVE_NAME
  AZURE_STORAGE_ACCOUNT_NAME AZURE_BLOB_CONTAINER_NAME
  SEARCH_SERVICE_NAME
  OPENAI_RESOURCE_URI EMBEDDING_DEPLOYMENT_ID EMBEDDING_MODEL_NAME EMBEDDING_DIMENSIONS
  SUBSCRIPTION_ID LOCATION SPOKE_RG SPOKE_VNET_NAME HUB_RG FW_PRIVATE_IP
)
MISSING=()
for VAR in "${REQUIRED_VARS[@]}"; do
  if [ -z "${!VAR:-}" ] || [[ "${!VAR}" == "<"* ]]; then
    MISSING+=("$VAR")
  fi
done
if [ ${#MISSING[@]} -gt 0 ]; then
  echo "❌ Missing or placeholder values in sharepoint-sync.env:"
  printf '   %s\n' "${MISSING[@]}"
  exit 1
fi

# Map variables
SUBSCRIPTION="$SUBSCRIPTION_ID"
FW_POLICY_NAME="${FW_POLICY_NAME:-hub-fw-policy}"
SPOKE_PE_SUBNET_NAME="pe-subnet"
UDR_NAME="spoke-to-fw-udr"
AI_SEARCH_NAME="$SEARCH_SERVICE_NAME"
STORAGE_NAME="$AZURE_STORAGE_ACCOUNT_NAME"
SP_TENANT_ID="$AZURE_TENANT_ID"
SP_CLIENT_ID="$AZURE_CLIENT_ID"
SP_CLIENT_SECRET="$AZURE_CLIENT_SECRET"
SP_SITE_URL="$SHAREPOINT_SITE_URL"

# Generated resource names
FUNC_SUBNET_NAME="func-subnet"
FUNC_SUBNET_PREFIX="10.100.6.0/24"
FUNC_APP_NAME="sp-sync-func-$(openssl rand -hex 3)"
FUNC_PLAN_NAME="${FUNC_APP_NAME}-plan"
FUNC_STORAGE_NAME="fnstor$(openssl rand -hex 4)"
KV_NAME="kv-spsync-$(openssl rand -hex 3)"
BLOB_CONTAINER_NAME="$AZURE_BLOB_CONTAINER_NAME"

# Sync code repo
SYNC_REPO_URL="https://github.com/Azure-Samples/sharepoint-foundryIQ-secure-sync.git"
SYNC_CLONE_DIR="${SCRIPT_DIR}/.sharepoint-sync-repo"

echo "============================================"
echo " SharePoint Sync Pipeline Deployment"
echo "============================================"
echo " Spoke RG:       $SPOKE_RG"
echo " VNet:           $SPOKE_VNET_NAME"
echo " Func Subnet:    $FUNC_SUBNET_PREFIX"
echo " AI Search:      $AI_SEARCH_NAME"
echo " Storage:        $STORAGE_NAME"
echo " Function App:   $FUNC_APP_NAME"
echo " Key Vault:      $KV_NAME"
echo "============================================"
echo ""

az account set --subscription "$SUBSCRIPTION"

###############################################################################
# 1. Create func-subnet with Microsoft.Web/serverFarms delegation
###############################################################################
echo "──── Step 1: Creating Function Subnet ────"

az network vnet subnet create \
  --resource-group "$SPOKE_RG" \
  --vnet-name "$SPOKE_VNET_NAME" \
  --name "$FUNC_SUBNET_NAME" \
  --address-prefix "$FUNC_SUBNET_PREFIX" \
  --delegations "Microsoft.Web/serverFarms" \
  --output none

# Apply existing UDR so func traffic routes through firewall
az network vnet subnet update \
  --resource-group "$SPOKE_RG" \
  --vnet-name "$SPOKE_VNET_NAME" \
  --name "$FUNC_SUBNET_NAME" \
  --route-table "$UDR_NAME" \
  --output none

echo "  ✅ Subnet: $FUNC_SUBNET_NAME ($FUNC_SUBNET_PREFIX) with UDR → $FW_PRIVATE_IP"
echo ""

###############################################################################
# 2. Create Blob Container for SharePoint sync
###############################################################################
echo "──── Step 2: Creating Blob Container ────"

STORAGE_KEY=$(az storage account keys list \
  --account-name "$STORAGE_NAME" \
  --resource-group "$SPOKE_RG" \
  --query '[0].value' -o tsv)

az storage container create \
  --name "$BLOB_CONTAINER_NAME" \
  --account-name "$STORAGE_NAME" \
  --account-key "$STORAGE_KEY" \
  --auth-mode key \
  --output none 2>/dev/null || echo "  (container may already exist)"

echo "  ✅ Container: $BLOB_CONTAINER_NAME in $STORAGE_NAME"
echo ""

###############################################################################
# 3. Create Function App Storage (with pre-created file share)
###############################################################################
echo "──── Step 3: Creating Function App Storage ────"

az storage account create \
  --name "$FUNC_STORAGE_NAME" \
  --resource-group "$SPOKE_RG" \
  --location "$LOCATION" \
  --sku Standard_LRS \
  --kind StorageV2 \
  --allow-blob-public-access false \
  --min-tls-version TLS1_2 \
  --output none

az storage share-rm create \
  --storage-account "$FUNC_STORAGE_NAME" \
  --resource-group "$SPOKE_RG" \
  --name "$FUNC_APP_NAME" \
  --quota 1 \
  --output none

echo "  ✅ Function Storage: $FUNC_STORAGE_NAME"
echo ""

###############################################################################
# 4. Deploy Azure Function App (VNet-integrated, managed identity)
###############################################################################
echo "──── Step 4: Deploying Function App ────"

az functionapp plan create \
  --name "$FUNC_PLAN_NAME" \
  --resource-group "$SPOKE_RG" \
  --location "$LOCATION" \
  --sku EP1 \
  --is-linux true \
  --output none

FUNC_SUBNET_ID=$(az network vnet subnet show \
  --resource-group "$SPOKE_RG" \
  --vnet-name "$SPOKE_VNET_NAME" \
  --name "$FUNC_SUBNET_NAME" \
  --query id -o tsv)

PLAN_ID=$(az functionapp plan show \
  --name "$FUNC_PLAN_NAME" \
  --resource-group "$SPOKE_RG" \
  --query id -o tsv)

# Create via ARM REST API (bypasses shared key validation issues)
az rest --method PUT \
  --url "https://management.azure.com/subscriptions/$SUBSCRIPTION/resourceGroups/$SPOKE_RG/providers/Microsoft.Web/sites/${FUNC_APP_NAME}?api-version=2023-12-01" \
  --body "{
    \"location\": \"$LOCATION\",
    \"kind\": \"functionapp,linux\",
    \"identity\": {\"type\": \"SystemAssigned\"},
    \"properties\": {
      \"serverFarmId\": \"$PLAN_ID\",
      \"reserved\": true,
      \"virtualNetworkSubnetId\": \"$FUNC_SUBNET_ID\",
      \"vnetRouteAllEnabled\": true,
      \"siteConfig\": {
        \"linuxFxVersion\": \"PYTHON|3.11\",
        \"appSettings\": [
          {\"name\": \"FUNCTIONS_EXTENSION_VERSION\", \"value\": \"~4\"},
          {\"name\": \"FUNCTIONS_WORKER_RUNTIME\", \"value\": \"python\"},
          {\"name\": \"AzureWebJobsStorage__accountName\", \"value\": \"$FUNC_STORAGE_NAME\"},
          {\"name\": \"WEBSITE_CONTENTSHARE\", \"value\": \"$FUNC_APP_NAME\"},
          {\"name\": \"WEBSITE_DNS_SERVER\", \"value\": \"$FW_PRIVATE_IP\"}
        ]
      }
    }
  }" \
  --output none

FUNC_PRINCIPAL_ID=$(az functionapp identity show \
  --name "$FUNC_APP_NAME" \
  --resource-group "$SPOKE_RG" \
  --query principalId -o tsv)

# Grant Function App RBAC on its own storage
FUNC_STORAGE_ID=$(az storage account show \
  --name "$FUNC_STORAGE_NAME" \
  --resource-group "$SPOKE_RG" \
  --query id -o tsv)

for ROLE in "Storage Blob Data Owner" "Storage Account Contributor" \
            "Storage File Data Privileged Contributor" "Storage Queue Data Contributor"; do
  az role assignment create \
    --assignee-object-id "$FUNC_PRINCIPAL_ID" \
    --assignee-principal-type ServicePrincipal \
    --role "$ROLE" \
    --scope "$FUNC_STORAGE_ID" \
    --output none 2>/dev/null || true
done

echo "  ✅ Function App: $FUNC_APP_NAME (identity: $FUNC_PRINCIPAL_ID)"
echo ""

###############################################################################
# 5. Lock down Function Storage (private endpoints)
###############################################################################
echo "──── Step 5: Locking down Function Storage ────"

az storage account update \
  --name "$FUNC_STORAGE_NAME" \
  --resource-group "$SPOKE_RG" \
  --default-action Deny \
  --public-network-access Disabled \
  --output none

# Blob PE
az network private-endpoint create \
  --name "pe-${FUNC_STORAGE_NAME}-blob" \
  --resource-group "$SPOKE_RG" \
  --vnet-name "$SPOKE_VNET_NAME" \
  --subnet "$SPOKE_PE_SUBNET_NAME" \
  --private-connection-resource-id "$FUNC_STORAGE_ID" \
  --group-id blob \
  --connection-name "pe-${FUNC_STORAGE_NAME}-blob-conn" \
  --location "$LOCATION" \
  --output none

az network private-endpoint dns-zone-group create \
  --resource-group "$SPOKE_RG" \
  --endpoint-name "pe-${FUNC_STORAGE_NAME}-blob" \
  --name "default" \
  --private-dns-zone "/subscriptions/$SUBSCRIPTION/resourceGroups/$HUB_RG/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net" \
  --zone-name "privatelink-blob-core-windows-net" \
  --output none

# File PE (Functions need file shares)
az network private-endpoint create \
  --name "pe-${FUNC_STORAGE_NAME}-file" \
  --resource-group "$SPOKE_RG" \
  --vnet-name "$SPOKE_VNET_NAME" \
  --subnet "$SPOKE_PE_SUBNET_NAME" \
  --private-connection-resource-id "$FUNC_STORAGE_ID" \
  --group-id file \
  --connection-name "pe-${FUNC_STORAGE_NAME}-file-conn" \
  --location "$LOCATION" \
  --output none

az network private-endpoint dns-zone-group create \
  --resource-group "$SPOKE_RG" \
  --endpoint-name "pe-${FUNC_STORAGE_NAME}-file" \
  --name "default" \
  --private-dns-zone "/subscriptions/$SUBSCRIPTION/resourceGroups/$HUB_RG/providers/Microsoft.Network/privateDnsZones/privatelink.file.core.windows.net" \
  --zone-name "privatelink-file-core-windows-net" \
  --output none

echo "  ✅ Function Storage locked down (blob + file PEs)"
echo ""

###############################################################################
# 6. Deploy Key Vault (private, RBAC-enabled)
###############################################################################
echo "──── Step 6: Deploying Key Vault ────"

az keyvault create \
  --name "$KV_NAME" \
  --resource-group "$SPOKE_RG" \
  --location "$LOCATION" \
  --sku standard \
  --enable-rbac-authorization true \
  --output none

KV_ID=$(az keyvault show --name "$KV_NAME" --resource-group "$SPOKE_RG" --query id -o tsv)

# RBAC: Function App → Key Vault Secrets User
az role assignment create \
  --assignee-object-id "$FUNC_PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Key Vault Secrets User" \
  --scope "$KV_ID" \
  --output none

# RBAC: Current user → Key Vault Secrets Officer (to write secrets)
CURRENT_USER_ID=$(az ad signed-in-user show --query id -o tsv)
az role assignment create \
  --assignee-object-id "$CURRENT_USER_ID" \
  --assignee-principal-type User \
  --role "Key Vault Secrets Officer" \
  --scope "$KV_ID" \
  --output none

echo "  Waiting 30s for RBAC propagation..."
sleep 30

# Store secrets
az keyvault secret set --vault-name "$KV_NAME" --name "sp-tenant-id" --value "$SP_TENANT_ID" --output none
az keyvault secret set --vault-name "$KV_NAME" --name "sp-client-id" --value "$SP_CLIENT_ID" --output none
az keyvault secret set --vault-name "$KV_NAME" --name "sp-client-secret" --value "$SP_CLIENT_SECRET" --output none

SEARCH_KEY=$(az search admin-key show \
  --service-name "$AI_SEARCH_NAME" \
  --resource-group "$SPOKE_RG" \
  --query primaryKey -o tsv)
az keyvault secret set --vault-name "$KV_NAME" --name "search-api-key" --value "$SEARCH_KEY" --output none

# Get secret URIs for KV references
SP_TENANT_ID_URI=$(az keyvault secret show --vault-name "$KV_NAME" --name "sp-tenant-id" --query id -o tsv)
SP_CLIENT_ID_URI=$(az keyvault secret show --vault-name "$KV_NAME" --name "sp-client-id" --query id -o tsv)
SP_CLIENT_SECRET_URI=$(az keyvault secret show --vault-name "$KV_NAME" --name "sp-client-secret" --query id -o tsv)
SEARCH_KEY_URI=$(az keyvault secret show --vault-name "$KV_NAME" --name "search-api-key" --query id -o tsv)

echo "  ✅ Secrets stored: sp-tenant-id, sp-client-id, sp-client-secret, search-api-key"

# Lock down KV: PE + disable public access
az network private-endpoint create \
  --name "pe-${KV_NAME}" \
  --resource-group "$SPOKE_RG" \
  --vnet-name "$SPOKE_VNET_NAME" \
  --subnet "$SPOKE_PE_SUBNET_NAME" \
  --private-connection-resource-id "$KV_ID" \
  --group-id vault \
  --connection-name "pe-${KV_NAME}-conn" \
  --location "$LOCATION" \
  --output none

az network private-endpoint dns-zone-group create \
  --resource-group "$SPOKE_RG" \
  --endpoint-name "pe-${KV_NAME}" \
  --name "default" \
  --private-dns-zone "/subscriptions/$SUBSCRIPTION/resourceGroups/$HUB_RG/providers/Microsoft.Network/privateDnsZones/privatelink.vaultcore.azure.net" \
  --zone-name "privatelink-vaultcore-azure-net" \
  --output none

az keyvault update --name "$KV_NAME" --public-network-access Disabled --output none

echo "  ✅ Key Vault: $KV_NAME (private, RBAC-enabled)"
echo ""

###############################################################################
# 7. Configure Function App settings (KV refs + AI Search + OpenAI)
###############################################################################
echo "──── Step 7: Configuring Function App ────"

az functionapp config appsettings set \
  --name "$FUNC_APP_NAME" \
  --resource-group "$SPOKE_RG" \
  --settings \
    "SHAREPOINT_SITE_URL=$SP_SITE_URL" \
    "SHAREPOINT_DRIVE_NAME=${SHAREPOINT_DRIVE_NAME}" \
    "SHAREPOINT_FOLDER_PATH=${SHAREPOINT_FOLDER_PATH:-/}" \
    "AZURE_TENANT_ID=@Microsoft.KeyVault(SecretUri=${SP_TENANT_ID_URI})" \
    "AZURE_CLIENT_ID=@Microsoft.KeyVault(SecretUri=${SP_CLIENT_ID_URI})" \
    "AZURE_CLIENT_SECRET=@Microsoft.KeyVault(SecretUri=${SP_CLIENT_SECRET_URI})" \
    "AZURE_STORAGE_ACCOUNT_NAME=$STORAGE_NAME" \
    "AZURE_BLOB_CONTAINER_NAME=$BLOB_CONTAINER_NAME" \
    "AZURE_BLOB_PREFIX=${AZURE_BLOB_PREFIX:-}" \
    "SYNC_PERMISSIONS=${SYNC_PERMISSIONS:-true}" \
    "PERMISSIONS_DELTA_MODE=${PERMISSIONS_DELTA_MODE:-hash}" \
    "DELETE_ORPHANED_BLOBS=${DELETE_ORPHANED_BLOBS:-true}" \
    "DRY_RUN=${DRY_RUN:-false}" \
    "SYNC_PURVIEW_PROTECTION=${SYNC_PURVIEW_PROTECTION:-false}" \
    "SEARCH_SERVICE_NAME=$AI_SEARCH_NAME" \
    "SEARCH_RESOURCE_GROUP=$SPOKE_RG" \
    "SEARCH_API_KEY=@Microsoft.KeyVault(SecretUri=${SEARCH_KEY_URI})" \
    "API_VERSION=${API_VERSION:-2025-11-01}" \
    "INDEX_NAME=${INDEX_NAME:-sharepoint-index}" \
    "INDEXER_NAME=${INDEXER_NAME:-sharepoint-blob-indexer}" \
    "SKILLSET_NAME=${SKILLSET_NAME:-sharepoint-sync-skillset}" \
    "DATASOURCE_NAME=${DATASOURCE_NAME:-sharepoint-blob-ds}" \
    "OPENAI_RESOURCE_URI=${OPENAI_RESOURCE_URI}" \
    "EMBEDDING_DEPLOYMENT_ID=${EMBEDDING_DEPLOYMENT_ID}" \
    "EMBEDDING_MODEL_NAME=${EMBEDDING_MODEL_NAME}" \
    "EMBEDDING_DIMENSIONS=${EMBEDDING_DIMENSIONS}" \
    "SUBSCRIPTION_ID=$SUBSCRIPTION" \
  --output none

echo "  ✅ Function App settings configured"
echo ""

###############################################################################
# 8. RBAC: Function App → Foundry Storage
###############################################################################
echo "──── Step 8: RBAC — Function App → Storage ────"

STORAGE_ID=$(az storage account show \
  --name "$STORAGE_NAME" \
  --resource-group "$SPOKE_RG" \
  --query id -o tsv)

az role assignment create \
  --assignee-object-id "$FUNC_PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Storage Blob Data Contributor" \
  --scope "$STORAGE_ID" \
  --output none

echo "  ✅ Function App → Storage Blob Data Contributor"
echo ""

###############################################################################
# 9. Shared Private Link: AI Search → Storage (for blob indexer)
###############################################################################
echo "──── Step 9: Shared Private Link (AI Search → Storage) ────"

az rest --method PUT \
  --url "https://management.azure.com/subscriptions/$SUBSCRIPTION/resourceGroups/$SPOKE_RG/providers/Microsoft.Search/searchServices/$AI_SEARCH_NAME/sharedPrivateLinkResources/spl-storage-blob?api-version=2024-06-01-preview" \
  --body "{
    \"properties\": {
      \"privateLinkResourceId\": \"$STORAGE_ID\",
      \"groupId\": \"blob\",
      \"requestMessage\": \"AI Search indexer needs access to SharePoint sync blobs\"
    }
  }" \
  --output none

echo "  ⏳ SPL created. Waiting 30s for provisioning..."
sleep 30

# Auto-approve the PE connection
PE_CONN_ID=$(az network private-endpoint-connection list \
  --id "$STORAGE_ID" \
  --query "[?contains(properties.privateEndpoint.id, 'searchServices')].id" -o tsv 2>/dev/null | head -1)

if [ -n "$PE_CONN_ID" ]; then
  az network private-endpoint-connection approve \
    --id "$PE_CONN_ID" \
    --description "Approved for AI Search indexer" \
    --output none 2>/dev/null || echo "  (auto-approve failed)"
  echo "  ✅ Shared Private Link approved"
else
  echo "  ⚠️  PE connection not found — approve manually in portal:"
  echo "     Portal → $STORAGE_NAME → Networking → Private endpoint connections"
fi
echo ""

###############################################################################
# 10. AI Search Index, Data Source, Indexer
###############################################################################
echo "──── Step 10: Creating AI Search Artifacts ────"

SEARCH_ENDPOINT="https://${AI_SEARCH_NAME}.search.windows.net"

# Temporarily enable public access (required to create data-plane objects)
echo "  Temporarily enabling AI Search public access..."
az search service update --name "$AI_SEARCH_NAME" --resource-group "$SPOKE_RG" \
  --public-access enabled --output none
sleep 15

# Index
curl -s -X PUT "${SEARCH_ENDPOINT}/indexes/${INDEX_NAME:-sharepoint-index}?api-version=2024-06-01-preview" \
  -H "Content-Type: application/json" \
  -H "api-key: $SEARCH_KEY" \
  -d '{
    "name": "'"${INDEX_NAME:-sharepoint-index}"'",
    "fields": [
      {"name": "id", "type": "Edm.String", "key": true, "filterable": true},
      {"name": "content", "type": "Edm.String", "searchable": true, "filterable": false, "sortable": false},
      {"name": "metadata_storage_path", "type": "Edm.String", "filterable": true, "sortable": true},
      {"name": "metadata_storage_name", "type": "Edm.String", "searchable": true, "filterable": true, "sortable": true},
      {"name": "metadata_storage_last_modified", "type": "Edm.DateTimeOffset", "filterable": true, "sortable": true},
      {"name": "metadata_storage_size", "type": "Edm.Int64", "filterable": true, "sortable": true},
      {"name": "metadata_storage_content_type", "type": "Edm.String", "filterable": true},
      {"name": "metadata_content_type", "type": "Edm.String", "filterable": true},
      {"name": "sp_permissions", "type": "Collection(Edm.String)", "filterable": true, "searchable": false},
      {"name": "sp_site_url", "type": "Edm.String", "filterable": true},
      {"name": "sp_item_url", "type": "Edm.String", "filterable": true},
      {"name": "sp_last_modified_by", "type": "Edm.String", "filterable": true}
    ]
  }' > /dev/null
echo "  ✅ Index: ${INDEX_NAME:-sharepoint-index}"

# Data Source (ResourceId connection — managed identity, no shared keys)
STORAGE_RESOURCE_ID="/subscriptions/$SUBSCRIPTION/resourceGroups/$SPOKE_RG/providers/Microsoft.Storage/storageAccounts/$STORAGE_NAME"
STORAGE_CONN="ResourceId=${STORAGE_RESOURCE_ID};"

curl -s -X PUT "${SEARCH_ENDPOINT}/datasources/${DATASOURCE_NAME:-sharepoint-blob-ds}?api-version=2024-06-01-preview" \
  -H "Content-Type: application/json" \
  -H "api-key: $SEARCH_KEY" \
  -d "{
    \"name\": \"${DATASOURCE_NAME:-sharepoint-blob-ds}\",
    \"type\": \"azureblob\",
    \"credentials\": {\"connectionString\": \"$STORAGE_CONN\"},
    \"container\": {\"name\": \"$BLOB_CONTAINER_NAME\"}
  }" > /dev/null
echo "  ✅ Data Source: ${DATASOURCE_NAME:-sharepoint-blob-ds}"

# Indexer (private execution environment, hourly schedule)
curl -s -X PUT "${SEARCH_ENDPOINT}/indexers/${INDEXER_NAME:-sharepoint-blob-indexer}?api-version=2024-06-01-preview" \
  -H "Content-Type: application/json" \
  -H "api-key: $SEARCH_KEY" \
  -d '{
    "name": "'"${INDEXER_NAME:-sharepoint-blob-indexer}"'",
    "dataSourceName": "'"${DATASOURCE_NAME:-sharepoint-blob-ds}"'",
    "targetIndexName": "'"${INDEX_NAME:-sharepoint-index}"'",
    "parameters": {
      "configuration": {
        "executionEnvironment": "private",
        "dataToExtract": "contentAndMetadata",
        "indexedFileNameExtensions": ".pdf,.docx,.doc,.pptx,.ppt,.xlsx,.xls,.txt,.md,.html,.csv,.json,.rtf,.eml,.msg",
        "failOnUnsupportedContentType": false,
        "failOnUnprocessableDocument": false,
        "indexStorageMetadataOnlyForOversizedDocuments": true
      }
    },
    "schedule": {"interval": "PT1H"},
    "fieldMappings": [
      {"sourceFieldName": "metadata_storage_path", "targetFieldName": "id", "mappingFunction": {"name": "base64Encode"}},
      {"sourceFieldName": "metadata_storage_path", "targetFieldName": "metadata_storage_path"}
    ]
  }' > /dev/null
echo "  ✅ Indexer: ${INDEXER_NAME:-sharepoint-blob-indexer} (hourly, private execution)"

# Lock down AI Search again
az search service update --name "$AI_SEARCH_NAME" --resource-group "$SPOKE_RG" \
  --public-access disabled --output none
echo "  ✅ AI Search locked down"
echo ""

###############################################################################
# 11. Firewall Rules: Graph API + SharePoint + Entra ID
###############################################################################
echo "──── Step 11: Adding Firewall Rules ────"

# Ensure rule collection group exists
az network firewall policy rule-collection-group show \
  --resource-group "$HUB_RG" \
  --policy-name "$FW_POLICY_NAME" \
  --name "FoundryAppRules" \
  --output none 2>/dev/null || \
az network firewall policy rule-collection-group create \
  --resource-group "$HUB_RG" \
  --policy-name "$FW_POLICY_NAME" \
  --name "FoundryAppRules" \
  --priority 300 \
  --output none

az network firewall policy rule-collection-group collection add-filter-collection \
  --resource-group "$HUB_RG" \
  --policy-name "$FW_POLICY_NAME" \
  --rule-collection-group-name "FoundryAppRules" \
  --name "AllowSharePointSync" \
  --collection-priority 400 \
  --action Allow \
  --rule-type ApplicationRule \
  --rule-name "SharePointGraph" \
  --source-addresses "10.100.0.0/16" \
  --protocols Https=443 \
  --target-fqdns "graph.microsoft.com" "login.microsoftonline.com" "*.sharepoint.com" \
  --output none 2>/dev/null || echo "  (rule may already exist)"

echo "  ✅ Firewall rules: graph.microsoft.com, *.sharepoint.com, login.microsoftonline.com"
echo ""

###############################################################################
# 12. Clone & Publish Sync Code
###############################################################################
echo "──── Step 12: Cloning & Publishing Sync Code ────"

if [ -d "$SYNC_CLONE_DIR" ]; then
  echo "  Repo already cloned — pulling latest..."
  git -C "$SYNC_CLONE_DIR" pull --ff-only || true
else
  git clone "$SYNC_REPO_URL" "$SYNC_CLONE_DIR"
fi

# Find the Python function app source
FUNC_SRC_DIR=""
for CANDIDATE in \
  "$SYNC_CLONE_DIR/src/sync" \
  "$SYNC_CLONE_DIR/src/python" \
  "$SYNC_CLONE_DIR/src/function_app" \
  "$SYNC_CLONE_DIR/src"; do
  if [ -f "$CANDIDATE/function_app.py" ] || [ -f "$CANDIDATE/host.json" ]; then
    FUNC_SRC_DIR="$CANDIDATE"
    break
  fi
done

if [ -z "$FUNC_SRC_DIR" ]; then
  echo "  ⚠️  Could not detect function source directory."
  echo "  Check: $SYNC_CLONE_DIR and publish manually:"
  echo "    cd <source-dir> && func azure functionapp publish $FUNC_APP_NAME"
else
  echo "  Publishing from $FUNC_SRC_DIR ..."
  pushd "$FUNC_SRC_DIR" > /dev/null
  if [ -f "requirements.txt" ]; then
    pip install -r requirements.txt --quiet 2>/dev/null || true
  fi
  func azure functionapp publish "$FUNC_APP_NAME" --python
  popd > /dev/null
  echo "  ✅ Sync code published"
fi
echo ""

###############################################################################
# Summary
###############################################################################
echo ""
echo "============================================"
echo " ✅ SharePoint Sync Pipeline Deployed!"
echo "============================================"
echo ""
echo " Pipeline: SharePoint → Function App → Blob → AI Search"
echo ""
echo " New resources:"
echo "   Subnet:         $FUNC_SUBNET_NAME ($FUNC_SUBNET_PREFIX)"
echo "   Key Vault:      $KV_NAME"
echo "   Function App:   $FUNC_APP_NAME"
echo "   Func Storage:   $FUNC_STORAGE_NAME"
echo "   Blob Container: $BLOB_CONTAINER_NAME (in $STORAGE_NAME)"
echo "   Search Index:   ${INDEX_NAME:-sharepoint-index}"
echo "   Search Indexer: ${INDEXER_NAME:-sharepoint-blob-indexer} (hourly)"
echo "   Shared PL:      AI Search → Storage (blob)"
echo "   FW Rule:        AllowSharePointSync"
echo ""
echo " ⚠️  If auto-approve failed for the SPL:"
echo "   Portal → $STORAGE_NAME → Networking → Private endpoint connections → Approve"
echo ""
echo " Data flow:"
echo "   SharePoint → (Graph API via FW) → Function App (VNet) → Blob (PE)"
echo "   Blob → (Shared Private Link) → AI Search Indexer (private exec)"
echo "   Foundry Agent → AI Search → grounded answers"
echo "============================================"
