#!/bin/bash
set -euo pipefail

# Portable python: Linux/macOS usually have `python3`, Windows Git Bash often
# has only `python` or `py` (Python Launcher for Windows from python.org).
if command -v python3 >/dev/null 2>&1; then
  PY="python3"
elif command -v python >/dev/null 2>&1; then
  PY="python"
elif command -v py >/dev/null 2>&1; then
  PY="py -3"
else
  echo "ERROR: need 'python3', 'python', or 'py' on PATH (used for JSON parsing)." >&2
  echo "  Windows: install Python from https://www.python.org/downloads/ and check" >&2
  echo "  'Add python.exe to PATH' during install. Then restart your Git Bash shell." >&2
  exit 1
fi

###############################################################################
# 3-deploy-sharepoint-sync-existing-env.sh
#
# SharePoint → Blob → AI Search Sync Pipeline — EXISTING ENVIRONMENT variant
#
# Assumes ALL infrastructure already exists:
#   - Hub + Spoke VNet, subnets, UDR, firewall
#   - Function App (.NET 10 isolated worker, Linux — Flex Consumption / EP /
#     Consumption all supported) with VNet integration + identity storage
#   - Function App storage account with private endpoints
#   - Key Vault (RBAC-enabled, private)
#   - Foundry storage account + blob container
#   - AI Search, AI Services / OpenAI
#
# This script only does configuration and wiring:
#   0. Validates all existing infrastructure
#   1. Stores SPN secrets in Key Vault + RBAC
#   2. Configures Function App settings (KV refs + AI Search + OpenAI)
#   3. RBAC: Function App → Foundry Storage
#   4. Shared Private Links: AI Search → Storage + AI Services  (SKIP_SHARED_PRIVATE_LINKS=true to skip)
#   5. RBAC: AI Search → AI Services
#   6. AI Search artifacts (index, data source, skillset, indexer)
#   6b. Patches all indexers to Private execution
#   7. Firewall rules (Graph + SharePoint + Entra ID + App Insights) (SKIP_FIREWALL_RULES=true to skip)
#   8. Publishes sync code to Function App
#   9. Configures Foundry Agent (azure_ai_search tool)
#   9b. Agentic Retrieval (opt-in)
#
# Usage:
#   cp sharepoint-sync-existing.env.example sharepoint-sync-existing.env
#   # edit values — provide names of ALL existing resources
#   ./3-deploy-sharepoint-sync-existing-env.sh
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/sharepoint-sync-existing.env"

if [ ! -f "$ENV_FILE" ]; then
  echo "❌ Missing sharepoint-sync-existing.env — copy sharepoint-sync-existing.env.example and fill in values"
  exit 1
fi

echo "Loading config from sharepoint-sync-existing.env ..."
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
  SUBSCRIPTION_ID LOCATION SPOKE_RG SPOKE_VNET_NAME
  FUNC_APP_NAME FUNC_STORAGE_NAME KV_NAME
)
# FW-related vars only required when firewall management is enabled
if [ "${SKIP_FIREWALL_RULES:-false}" != "true" ] && [ "${FW_MODE:-azure}" = "azure" ]; then
  REQUIRED_VARS+=(HUB_RG FW_PRIVATE_IP)
fi
MISSING=()
for VAR in "${REQUIRED_VARS[@]}"; do
  if [ -z "${!VAR:-}" ] || [[ "${!VAR}" == "<"* ]]; then
    MISSING+=("$VAR")
  fi
done
if [ ${#MISSING[@]} -gt 0 ]; then
  echo "❌ Missing or placeholder values in sharepoint-sync-existing.env:"
  printf '   %s\n' "${MISSING[@]}"
  exit 1
fi

###############################################################################
# RAG tuning defaults (same as original script)
###############################################################################
: "${CHUNK_SPLIT_MODE:=pages}"
: "${CHUNK_UNIT:=characters}"
: "${CHUNK_SIZE:=2000}"
: "${CHUNK_OVERLAP:=200}"
: "${VECTOR_METRIC:=cosine}"
: "${HNSW_M:=4}"
: "${HNSW_EF_CONSTRUCTION:=400}"
: "${HNSW_EF_SEARCH:=500}"
: "${SEMANTIC_CONFIG_ENABLED:=true}"
: "${INDEXER_MAX_FAILED_ITEMS:=-1}"
: "${INDEXER_MAX_FAILED_PER_BATCH:=-1}"
: "${INDEXER_SCHEDULE_INTERVAL:=PT1H}"
: "${AGENT_QUERY_TYPE:=semantic}"
: "${USE_AGENTIC_RETRIEVAL:=false}"
: "${AGENTIC_KS_NAME:=sharepoint-ks}"
: "${AGENTIC_KB_NAME:=sharepoint-kb}"
: "${AGENTIC_AGENT_NAME:=sharepoint-agentic}"
: "${AGENTIC_PROJECT_CONN_NAME:=sharepoint-kb-mcp}"
: "${AGENTIC_PLANNER_MODEL:=${FOUNDRY_AGENT_MODEL:-gpt-4.1}}"
: "${AGENTIC_REASONING_EFFORT:=low}"
: "${AGENTIC_OUTPUT_MODE:=extractiveData}"

# Validate enums
_validate_enum() {
  local name="$1"; local value="$2"; shift 2
  local allowed=("$@")
  for v in "${allowed[@]}"; do [ "$value" = "$v" ] && return 0; done
  echo "❌ Invalid $name='$value' — expected one of: ${allowed[*]}"; exit 1
}
_validate_enum CHUNK_SPLIT_MODE       "$CHUNK_SPLIT_MODE"       pages sentences
_validate_enum CHUNK_UNIT             "$CHUNK_UNIT"             characters azureOpenAITokens
_validate_enum VECTOR_METRIC          "$VECTOR_METRIC"          cosine euclidean dotProduct
_validate_enum SEMANTIC_CONFIG_ENABLED "$SEMANTIC_CONFIG_ENABLED" true false
_validate_enum AGENT_QUERY_TYPE       "$AGENT_QUERY_TYPE"       simple semantic vector vectorSemanticHybrid
_validate_enum USE_AGENTIC_RETRIEVAL  "$USE_AGENTIC_RETRIEVAL"  true false
_validate_enum AGENTIC_REASONING_EFFORT "$AGENTIC_REASONING_EFFORT" minimal low medium
_validate_enum AGENTIC_OUTPUT_MODE    "$AGENTIC_OUTPUT_MODE"    extractiveData answerSynthesis
case "$INDEXER_SCHEDULE_INTERVAL" in
  PT[0-9]*M|PT[0-9]*H|P[0-9]*D|P[0-9]*DT[0-9]*H) ;;
  *) echo "❌ Invalid INDEXER_SCHEDULE_INTERVAL='$INDEXER_SCHEDULE_INTERVAL'"; exit 1 ;;
esac

# Map variables
SUBSCRIPTION="$SUBSCRIPTION_ID"
DNS_SUBSCRIPTION="${DNS_SUBSCRIPTION:-$SUBSCRIPTION_ID}"
DNS_ZONE_RG="${DNS_ZONE_RG:-$SPOKE_RG}"
SKIP_FIREWALL_RULES="${SKIP_FIREWALL_RULES:-false}"
SKIP_SHARED_PRIVATE_LINKS="${SKIP_SHARED_PRIVATE_LINKS:-false}"
# START_STEP: skip already-completed setup steps on re-runs. 0=run everything.
# Example: START_STEP=6 skips Steps 0-5 (validation, KV, app settings, RBAC, SPLs)
# and jumps straight to Step 6 (AI Search artifacts). Variable lookups (KV URIs,
# Search admin key) still run unconditionally so downstream steps have what they need.
START_STEP="${START_STEP:-0}"
FW_MODE="${FW_MODE:-azure}"
FW_POLICY_NAME="${FW_POLICY_NAME:-hub-fw-policy}"
FW_POLICY_RG="${FW_POLICY_RG:-${HUB_RG:-}}"
FW_RCG_NAME="${FW_RCG_NAME:-DefaultAppRuleGroup}"
SPOKE_PE_SUBNET_NAME="${SPOKE_PE_SUBNET_NAME:-pe-subnet}"
FUNC_SUBNET_NAME="${FUNC_SUBNET_NAME:-func-subnet}"
AI_SEARCH_NAME="$SEARCH_SERVICE_NAME"
STORAGE_NAME="$AZURE_STORAGE_ACCOUNT_NAME"
SP_TENANT_ID="$AZURE_TENANT_ID"
SP_CLIENT_ID="$AZURE_CLIENT_ID"
SP_CLIENT_SECRET="$AZURE_CLIENT_SECRET"
SP_SITE_URL="$SHAREPOINT_SITE_URL"
BLOB_CONTAINER_NAME="$AZURE_BLOB_CONTAINER_NAME"
# Default to 'private' for existing-env variant: the customer's network is locked
# down by definition; we should NOT toggle public access on AI Search without an
# explicit opt-in. Operator must run this script from inside the VNet (VPN/Bastion).
SEARCH_ACCESS_MODE="${SEARCH_ACCESS_MODE:-private}"

SYNC_SRC_DIR="${SCRIPT_DIR}/sharepoint-sync-func"

echo "============================================"
echo " SharePoint Sync — Existing Environment"
echo "============================================"
echo " Spoke RG:       $SPOKE_RG"
echo " VNet:           $SPOKE_VNET_NAME"
echo " AI Search:      $AI_SEARCH_NAME"
echo " Storage:        $STORAGE_NAME"
echo " Function App:   $FUNC_APP_NAME   (existing)"
echo " Func Storage:   $FUNC_STORAGE_NAME  (existing)"
echo " Key Vault:      $KV_NAME   (existing)"
echo "============================================"
echo ""

az account set --subscription "$SUBSCRIPTION"

###############################################################################
# 0. Validate ALL existing infrastructure
#    Fails fast if any required resource is missing.
###############################################################################
echo "──── Step 0: Validating Existing Infrastructure ────"
VALIDATION_ERRORS=()

# --- Function App ---
if az functionapp show -n "$FUNC_APP_NAME" -g "$SPOKE_RG" -o none 2>/dev/null; then
  FUNC_PRINCIPAL_ID=$(az functionapp identity show \
    --name "$FUNC_APP_NAME" --resource-group "$SPOKE_RG" \
    --query principalId -o tsv 2>/dev/null || true)
  if [ -z "$FUNC_PRINCIPAL_ID" ]; then
    VALIDATION_ERRORS+=("Function App '$FUNC_APP_NAME' has no system-assigned identity. Enable it first.")
  else
    echo "  ✅ Function App: $FUNC_APP_NAME (identity: $FUNC_PRINCIPAL_ID)"
  fi
else
  VALIDATION_ERRORS+=("Function App '$FUNC_APP_NAME' not found in RG '$SPOKE_RG'")
fi

# --- Function App Storage ---
if az storage account show -n "$FUNC_STORAGE_NAME" -g "$SPOKE_RG" -o none 2>/dev/null; then
  FUNC_STORAGE_ID=$(az storage account show -n "$FUNC_STORAGE_NAME" -g "$SPOKE_RG" --query id -o tsv)
  echo "  ✅ Function Storage: $FUNC_STORAGE_NAME"
else
  VALIDATION_ERRORS+=("Function storage account '$FUNC_STORAGE_NAME' not found in RG '$SPOKE_RG'")
fi

# --- Key Vault ---
if az keyvault show --name "$KV_NAME" --resource-group "$SPOKE_RG" -o none 2>/dev/null; then
  KV_ID=$(az keyvault show --name "$KV_NAME" --resource-group "$SPOKE_RG" --query id -o tsv)
  echo "  ✅ Key Vault: $KV_NAME"
else
  VALIDATION_ERRORS+=("Key Vault '$KV_NAME' not found in RG '$SPOKE_RG'")
fi

# --- Foundry Storage Account ---
if az storage account show -n "$STORAGE_NAME" -g "$SPOKE_RG" -o none 2>/dev/null; then
  STORAGE_ID=$(az storage account show -n "$STORAGE_NAME" -g "$SPOKE_RG" --query id -o tsv)
  echo "  ✅ Storage Account: $STORAGE_NAME"
else
  VALIDATION_ERRORS+=("Storage account '$STORAGE_NAME' not found in RG '$SPOKE_RG'")
fi

# --- Blob Container ---
CONTAINER_EXISTS=$(az rest --method GET \
  --url "https://management.azure.com${STORAGE_ID:-/invalid}/blobServices/default/containers/${BLOB_CONTAINER_NAME}?api-version=2023-05-01" \
  --query "name" -o tsv 2>/dev/null || true)
if [ -n "$CONTAINER_EXISTS" ]; then
  echo "  ✅ Blob Container: $BLOB_CONTAINER_NAME"
else
  echo "  ⚠️  Blob Container '$BLOB_CONTAINER_NAME' not found — will create it"
fi

# --- AI Search ---
if az search service show --name "$AI_SEARCH_NAME" --resource-group "$SPOKE_RG" -o none 2>/dev/null; then
  SEARCH_IDENTITY=$(az search service show --name "$AI_SEARCH_NAME" --resource-group "$SPOKE_RG" \
    --query "identity.principalId" -o tsv)
  echo "  ✅ AI Search: $AI_SEARCH_NAME (identity: $SEARCH_IDENTITY)"
else
  VALIDATION_ERRORS+=("AI Search service '$AI_SEARCH_NAME' not found in RG '$SPOKE_RG'")
fi

# --- AI Services ---
AI_SERVICES_NAME_DERIVED=$(echo "$OPENAI_RESOURCE_URI" | sed -E 's|https://([^.]+)\..*|\1|')
AI_SERVICES_NAME="${AI_SERVICES_NAME:-$AI_SERVICES_NAME_DERIVED}"
if az cognitiveservices account show --name "$AI_SERVICES_NAME" --resource-group "$SPOKE_RG" -o none 2>/dev/null; then
  AI_SERVICES_ID=$(az cognitiveservices account show --name "$AI_SERVICES_NAME" \
    --resource-group "$SPOKE_RG" --query id -o tsv)
  echo "  ✅ AI Services: $AI_SERVICES_NAME"
else
  VALIDATION_ERRORS+=("AI Services account '$AI_SERVICES_NAME' not found in RG '$SPOKE_RG'")
fi

# --- VNet + Subnets ---
if az network vnet show -g "$SPOKE_RG" -n "$SPOKE_VNET_NAME" -o none 2>/dev/null; then
  echo "  ✅ VNet: $SPOKE_VNET_NAME"
else
  VALIDATION_ERRORS+=("VNet '$SPOKE_VNET_NAME' not found in RG '$SPOKE_RG'")
fi

if az network vnet subnet show -g "$SPOKE_RG" --vnet-name "$SPOKE_VNET_NAME" -n "$FUNC_SUBNET_NAME" -o none 2>/dev/null; then
  echo "  ✅ Function Subnet: $FUNC_SUBNET_NAME"
else
  VALIDATION_ERRORS+=("Function subnet '$FUNC_SUBNET_NAME' not found in VNet '$SPOKE_VNET_NAME'")
fi

if az network vnet subnet show -g "$SPOKE_RG" --vnet-name "$SPOKE_VNET_NAME" -n "$SPOKE_PE_SUBNET_NAME" -o none 2>/dev/null; then
  echo "  ✅ PE Subnet: $SPOKE_PE_SUBNET_NAME"
else
  VALIDATION_ERRORS+=("PE subnet '$SPOKE_PE_SUBNET_NAME' not found in VNet '$SPOKE_VNET_NAME'")
fi

# --- Fail fast if any resource is missing ---
if [ ${#VALIDATION_ERRORS[@]} -gt 0 ]; then
  echo ""
  echo "❌ Validation failed — the following resources are missing:"
  for ERR in "${VALIDATION_ERRORS[@]}"; do
    echo "   • $ERR"
  done
  echo ""
  echo "This script requires all infrastructure to already exist."
  echo "Use 3-deploy-sharepoint-sync.sh instead to create resources automatically."
  exit 1
fi

# --- DNS zone validation ---
# This script does NOT create PEs or DNS records, so DNS zones are only
# validated as a sanity check. If zones live in a different subscription,
# set DNS_SUBSCRIPTION in the env file. If the operator doesn't have
# Reader on the DNS subscription, set SKIP_DNS_VALIDATION=true.
SKIP_DNS_VALIDATION="${SKIP_DNS_VALIDATION:-false}"

if [ "$SKIP_DNS_VALIDATION" = "true" ]; then
  echo "  ℹ️  SKIP_DNS_VALIDATION=true — DNS zone check skipped"
  echo "     Ensure these private DNS zones exist and are linked to $SPOKE_VNET_NAME:"
  echo "       privatelink.blob.core.windows.net"
  echo "       privatelink.vaultcore.azure.net"
  echo "       privatelink.search.windows.net"
  echo "       privatelink.cognitiveservices.azure.com"
  echo "       privatelink.openai.azure.com"
else
  DNS_ZONE_CACHE_DIR="$(mktemp -d)"
  trap 'rm -rf "$DNS_ZONE_CACHE_DIR"' EXIT

  dns_zone_rg() {
    local ZONE="$1"
    local CACHE_FILE="$DNS_ZONE_CACHE_DIR/${ZONE//\//_}"
    if [ -f "$CACHE_FILE" ]; then cat "$CACHE_FILE"; return; fi
    local RG
    RG=$(az network private-dns zone list --subscription "$DNS_SUBSCRIPTION" \
      --query "[?name=='$ZONE'] | [0].resourceGroup" -o tsv 2>/dev/null || true)
    printf '%s' "$RG" > "$CACHE_FILE"
    printf '%s' "$RG"
  }

  REQUIRED_ZONES="privatelink.blob.core.windows.net privatelink.vaultcore.azure.net privatelink.search.windows.net privatelink.cognitiveservices.azure.com privatelink.openai.azure.com"
  MISSING_ZONES=""
  for ZONE in $REQUIRED_ZONES; do
    RG=$(dns_zone_rg "$ZONE")
    if [ -n "$RG" ] && [ "$RG" != "null" ]; then
      echo "  ✅ DNS zone: $ZONE → $RG (sub: $DNS_SUBSCRIPTION)"
    else
      MISSING_ZONES="$MISSING_ZONES $ZONE"
      echo "  ⚠️  DNS zone $ZONE NOT FOUND in subscription $DNS_SUBSCRIPTION"
    fi
  done
  if [ -n "$MISSING_ZONES" ]; then
    echo ""
    echo "  ⚠️  Could not find these private DNS zones in subscription $DNS_SUBSCRIPTION:"
    for Z in $MISSING_ZONES; do echo "     $Z"; done
    echo ""
    echo "  If DNS zones live in a different subscription, set DNS_SUBSCRIPTION in your env file."
    echo "  If you don't have Reader on the DNS subscription, set SKIP_DNS_VALIDATION=true."
    echo "  This script does not create DNS records — zones are only checked as a sanity test."
    echo "  Continuing — operator confirmed DNS records are managed out-of-band."
  fi
fi

# --- Firewall policy check ---
if [ "$SKIP_FIREWALL_RULES" = "true" ]; then
  echo "  ℹ️  SKIP_FIREWALL_RULES=true — firewall rules will not be touched"
elif [ "$FW_MODE" = "azure" ]; then
  if az network firewall policy show -n "$FW_POLICY_NAME" -g "$FW_POLICY_RG" -o none 2>/dev/null; then
    echo "  ✅ Firewall policy: $FW_POLICY_NAME"
  else
    echo "  ⚠️  Firewall policy '$FW_POLICY_NAME' not found — FW rules will be skipped"
    FW_MODE="external"
  fi
else
  echo "  ℹ️  FW_MODE=external — firewall rules will be skipped"
fi

echo ""
echo "  ✅ All infrastructure validated"
echo ""

###############################################################################
# 1. Key Vault: Store SPN Secrets + RBAC
###############################################################################
if (( START_STEP <= 1 )); then
echo "──── Step 1: Key Vault — Secrets + RBAC ────"

# RBAC: Function App → Key Vault Secrets User
az role assignment create \
  --assignee-object-id "$FUNC_PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Key Vault Secrets User" \
  --scope "$KV_ID" \
  --output none 2>/dev/null || true
echo "  ✅ Function App → Key Vault Secrets User"

# RBAC: Current user → Key Vault Secrets Officer (to write secrets)
CURRENT_USER_ID=$(az ad signed-in-user show --query id -o tsv)
az role assignment create \
  --assignee-object-id "$CURRENT_USER_ID" \
  --assignee-principal-type User \
  --role "Key Vault Secrets Officer" \
  --scope "$KV_ID" \
  --output none 2>/dev/null || true

echo "  Waiting 30s for RBAC propagation..."
sleep 30

# Store secrets (idempotent — overwrites existing)
az keyvault secret set --vault-name "$KV_NAME" --name "sp-tenant-id" --value "$SP_TENANT_ID" --output none
az keyvault secret set --vault-name "$KV_NAME" --name "sp-client-id" --value "$SP_CLIENT_ID" --output none
az keyvault secret set --vault-name "$KV_NAME" --name "sp-client-secret" --value "$SP_CLIENT_SECRET" --output none
echo "  ✅ Secrets stored: sp-tenant-id, sp-client-id, sp-client-secret"
else
echo "──── Step 1: Key Vault — Secrets + RBAC (SKIPPED: START_STEP=$START_STEP) ────"
fi

# Get secret URIs for KV references (always run — downstream steps need them)
SP_TENANT_ID_URI=$(az keyvault secret show --vault-name "$KV_NAME" --name "sp-tenant-id" --query id -o tsv)
SP_CLIENT_ID_URI=$(az keyvault secret show --vault-name "$KV_NAME" --name "sp-client-id" --query id -o tsv)
SP_CLIENT_SECRET_URI=$(az keyvault secret show --vault-name "$KV_NAME" --name "sp-client-secret" --query id -o tsv)

# Search admin key for artifact creation
SEARCH_KEY=$(az search admin-key show \
  --service-name "$AI_SEARCH_NAME" \
  --resource-group "$SPOKE_RG" \
  --query primaryKey -o tsv)

echo ""

###############################################################################
# 2. Configure Function App Settings
###############################################################################
# Artifact names (used by both Step 2 settings and Step 6 search artifacts)
IDX="${INDEX_NAME:-sharepoint-index}"
DS="${DATASOURCE_NAME:-sharepoint-blob-ds}"
SS="${SKILLSET_NAME:-sharepoint-sync-skillset}"
IDXR="${INDEXER_NAME:-sharepoint-blob-indexer}"

if (( START_STEP <= 2 )); then
echo "──── Step 2: Configuring Function App Settings ────"

az functionapp config appsettings set \
  --name "$FUNC_APP_NAME" \
  --resource-group "$SPOKE_RG" \
  --settings \
    "SHAREPOINT_SITE_URL=$SP_SITE_URL" \
    "SHAREPOINT_DRIVE_NAME=${SHAREPOINT_DRIVE_NAME}" \
    "SHAREPOINT_FOLDER_PATH=${SHAREPOINT_FOLDER_PATH:-/}" \
    "SHAREPOINT_INCLUDE_EXTENSIONS=${SHAREPOINT_INCLUDE_EXTENSIONS:-}" \
    "SHAREPOINT_EXCLUDE_EXTENSIONS=${SHAREPOINT_EXCLUDE_EXTENSIONS:-}" \
    "AZURE_TENANT_ID=@Microsoft.KeyVault(SecretUri=${SP_TENANT_ID_URI})" \
    "AZURE_CLIENT_ID=@Microsoft.KeyVault(SecretUri=${SP_CLIENT_ID_URI})" \
    "AZURE_CLIENT_SECRET=@Microsoft.KeyVault(SecretUri=${SP_CLIENT_SECRET_URI})" \
    "AZURE_STORAGE_ACCOUNT_NAME=$STORAGE_NAME" \
    "AZURE_BLOB_CONTAINER_NAME=$BLOB_CONTAINER_NAME" \
    "AZURE_BLOB_PREFIX=${AZURE_BLOB_PREFIX:-}" \
    "SYNC_PERMISSIONS=${SYNC_PERMISSIONS:-true}" \
    "PERMISSIONS_DELTA_MODE=${PERMISSIONS_DELTA_MODE:-hash}" \
    "DELETE_ORPHANED_BLOBS=${DELETE_ORPHANED_BLOBS:-true}" \
    "SOFT_DELETE_ORPHANED_BLOBS=${SOFT_DELETE_ORPHANED_BLOBS:-true}" \
    "DRY_RUN=${DRY_RUN:-false}" \
    "SYNC_PURVIEW_PROTECTION=${SYNC_PURVIEW_PROTECTION:-false}" \
    "SEARCH_SERVICE_NAME=$AI_SEARCH_NAME" \
    "SEARCH_RESOURCE_GROUP=$SPOKE_RG" \
    "API_VERSION=${API_VERSION:-2025-11-01}" \
    "INDEX_NAME=${IDX}" \
    "INDEXER_NAME=${IDXR}" \
    "SKILLSET_NAME=${SS}" \
    "DATASOURCE_NAME=${DS}" \
    "OPENAI_RESOURCE_URI=${OPENAI_RESOURCE_URI}" \
    "EMBEDDING_DEPLOYMENT_ID=${EMBEDDING_DEPLOYMENT_ID}" \
    "EMBEDDING_MODEL_NAME=${EMBEDDING_MODEL_NAME}" \
    "EMBEDDING_DIMENSIONS=${EMBEDDING_DIMENSIONS}" \
    "SUBSCRIPTION_ID=$SUBSCRIPTION" \
    "TIMER_SCHEDULE=${TIMER_SCHEDULE:-0 0 * * * *}" \
    "TIMER_SCHEDULE_FULL=${TIMER_SCHEDULE_FULL:-0 0 3 * * *}" \
  --output none

echo "  ✅ Function App settings configured"
else
echo "──── Step 2: Configuring Function App Settings (SKIPPED: START_STEP=$START_STEP) ────"
fi
echo ""

###############################################################################
# 3. RBAC: Function App → Foundry Storage + its own Storage
###############################################################################
if (( START_STEP <= 3 )); then
echo "──── Step 3: RBAC — Function App → Storage ────"

# Function App → Foundry Storage (for blob read/write)
az role assignment create \
  --assignee-object-id "$FUNC_PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Storage Blob Data Contributor" \
  --scope "$STORAGE_ID" \
  --output none 2>/dev/null || true
echo "  ✅ Function App → Storage Blob Data Contributor ($STORAGE_NAME)"

# Function App → its own Function storage (may already be set, idempotent)
for ROLE in "Storage Blob Data Owner" "Storage Account Contributor" \
            "Storage File Data Privileged Contributor" "Storage Queue Data Contributor"; do
  az role assignment create \
    --assignee-object-id "$FUNC_PRINCIPAL_ID" \
    --assignee-principal-type ServicePrincipal \
    --role "$ROLE" \
    --scope "$FUNC_STORAGE_ID" \
    --output none 2>/dev/null || true
done
echo "  ✅ Function App → RBAC on Function Storage ($FUNC_STORAGE_NAME)"
else
echo "──── Step 3: RBAC — Function App → Storage (SKIPPED: START_STEP=$START_STEP) ────"
fi
echo ""

###############################################################################
# 3b. Create Blob Container (if missing)
###############################################################################
if (( START_STEP <= 3 )) && [ -z "$CONTAINER_EXISTS" ]; then
  echo "──── Step 3b: Creating Blob Container ────"
  az rest --method PUT \
    --url "https://management.azure.com${STORAGE_ID}/blobServices/default/containers/${BLOB_CONTAINER_NAME}?api-version=2023-05-01" \
    --body '{"properties":{}}' \
    --output none 2>/dev/null || echo "  (container may already exist)"
  echo "  ✅ Container: $BLOB_CONTAINER_NAME in $STORAGE_NAME"
  echo ""
fi

###############################################################################
# 4. Shared Private Links: AI Search → Storage + AI Services
###############################################################################
if (( START_STEP > 4 )); then
  echo "──── Step 4: Shared Private Links (SKIPPED: START_STEP=$START_STEP) ────"
elif [ "$SKIP_SHARED_PRIVATE_LINKS" = "true" ]; then
  echo "──── Step 4: Shared Private Links (SKIPPED — SKIP_SHARED_PRIVATE_LINKS=true) ────"
  echo "  ℹ️  Assumes SPLs already exist: AI Search → Storage (blob), AI Search → AI Services (openai_account + cognitiveservices_account)"
  echo ""
else
echo "──── Step 4: Shared Private Links ────"

SEARCH_MGMT_API="2025-05-01"

# Fetch existing SPLs once
EXISTING_SPLS=$(az rest --method GET \
  --url "https://management.azure.com/subscriptions/$SUBSCRIPTION/resourceGroups/$SPOKE_RG/providers/Microsoft.Search/searchServices/$AI_SEARCH_NAME/sharedPrivateLinkResources?api-version=${SEARCH_MGMT_API}" \
  -o json 2>/dev/null || echo '{"value":[]}')
SPL_COUNT=$(echo "$EXISTING_SPLS" | $PY -c "import json,sys; print(len(json.load(sys.stdin).get('value',[])))" 2>/dev/null || echo 0)
echo "  Found $SPL_COUNT existing shared private link(s)"

spl_exists() {
  local TARGET_ID="$1" GROUP_ID="$2"
  $PY -c "
import json,sys
data = json.loads(sys.argv[1])
tid = sys.argv[2].lower()
gid = sys.argv[3]
for v in data.get('value',[]):
    p = v.get('properties',{})
    if p.get('privateLinkResourceId','').lower() == tid and p.get('groupId') == gid:
        print(v['name'])
        sys.exit(0)
sys.exit(1)
" "$EXISTING_SPLS" "$TARGET_ID" "$GROUP_ID" 2>/dev/null
}

# --- SPL: AI Search → Storage (blob) ---
EXISTING_BLOB_SPL=$(spl_exists "$STORAGE_ID" "blob" || true)
if [ -n "$EXISTING_BLOB_SPL" ]; then
  echo "  ✅ SPL for Storage/blob already exists: $EXISTING_BLOB_SPL (skipping)"
else
  SPL_RESULT=$(az rest --method PUT \
    --url "https://management.azure.com/subscriptions/$SUBSCRIPTION/resourceGroups/$SPOKE_RG/providers/Microsoft.Search/searchServices/$AI_SEARCH_NAME/sharedPrivateLinkResources/spl-storage-blob?api-version=${SEARCH_MGMT_API}" \
    --body "{
      \"properties\": {
        \"privateLinkResourceId\": \"$STORAGE_ID\",
        \"groupId\": \"blob\",
        \"requestMessage\": \"AI Search indexer needs access to SharePoint sync blobs\"
      }
    }" \
    --output none 2>&1) || {
    if echo "$SPL_RESULT" | grep -qi "already exists\|conflict"; then
      echo "  ✅ SPL spl-storage-blob already exists (skipping)"
      EXISTING_BLOB_SPL="spl-storage-blob"
    else
      echo "  ⚠️  SPL spl-storage-blob creation failed: $SPL_RESULT"
      echo "     Continuing — it may already exist under a different name"
    fi
  }

  if [ -z "${EXISTING_BLOB_SPL:-}" ]; then
  echo "  ⏳ SPL spl-storage-blob created. Waiting 30s for provisioning..."
  sleep 30

  PE_CONN_ID=$(az network private-endpoint-connection list \
    --id "$STORAGE_ID" \
    --query "[?contains(properties.privateEndpoint.id, 'searchServices') && properties.privateLinkServiceConnectionState.status=='Pending'].id" -o tsv 2>/dev/null | head -1)
  if [ -n "$PE_CONN_ID" ]; then
    az network private-endpoint-connection approve \
      --id "$PE_CONN_ID" \
      --description "Approved for AI Search indexer" \
      --output none 2>/dev/null || echo "  (auto-approve failed)"
    echo "  ✅ SPL spl-storage-blob approved"
  else
    echo "  ⚠️  PE connection not found or already approved"
  fi
  fi
fi

# --- SPL: AI Search → AI Services (OpenAI) ---
EXISTING_OPENAI_SPL=$(spl_exists "$AI_SERVICES_ID" "openai_account" || true)
if [ -n "$EXISTING_OPENAI_SPL" ]; then
  echo "  ✅ SPL for AI Services/openai_account already exists: $EXISTING_OPENAI_SPL (skipping)"
else
  SPL_RESULT=$(az rest --method PUT \
    --url "https://management.azure.com/subscriptions/$SUBSCRIPTION/resourceGroups/$SPOKE_RG/providers/Microsoft.Search/searchServices/$AI_SEARCH_NAME/sharedPrivateLinkResources/spl-openai?api-version=${SEARCH_MGMT_API}" \
    --body "{
      \"properties\": {
        \"privateLinkResourceId\": \"$AI_SERVICES_ID\",
        \"groupId\": \"openai_account\",
        \"requestMessage\": \"AI Search skillset needs access to OpenAI embeddings\"
      }
    }" \
    --output none 2>&1) && echo "  ✅ SPL spl-openai created" || {
    if echo "$SPL_RESULT" | grep -qi "already exists\|conflict"; then
      echo "  ✅ SPL spl-openai already exists (skipping)"
      EXISTING_OPENAI_SPL="spl-openai"
    else
      echo "  ⚠️  SPL spl-openai creation failed: $SPL_RESULT"
      echo "     Continuing — it may already exist under a different name"
    fi
  }
fi

# --- SPL: AI Search → AI Services (Cognitive Services) ---
EXISTING_COG_SPL=$(spl_exists "$AI_SERVICES_ID" "cognitiveservices_account" || true)
if [ -n "$EXISTING_COG_SPL" ]; then
  echo "  ✅ SPL for AI Services/cognitiveservices_account already exists: $EXISTING_COG_SPL (skipping)"
else
  SPL_RESULT=$(az rest --method PUT \
    --url "https://management.azure.com/subscriptions/$SUBSCRIPTION/resourceGroups/$SPOKE_RG/providers/Microsoft.Search/searchServices/$AI_SEARCH_NAME/sharedPrivateLinkResources/spl-cognitive?api-version=${SEARCH_MGMT_API}" \
    --body "{
      \"properties\": {
        \"privateLinkResourceId\": \"$AI_SERVICES_ID\",
        \"groupId\": \"cognitiveservices_account\",
        \"requestMessage\": \"AI Search skillset needs access to Cognitive Services (OCR)\"
      }
    }" \
    --output none 2>&1) && echo "  ✅ SPL spl-cognitive created" || {
    if echo "$SPL_RESULT" | grep -qi "already exists\|conflict"; then
      echo "  ✅ SPL spl-cognitive already exists (skipping)"
      EXISTING_COG_SPL="spl-cognitive"
    else
      echo "  ⚠️  SPL spl-cognitive creation failed: $SPL_RESULT"
      echo "     Continuing — it may already exist under a different name"
    fi
  }
fi

# Wait + auto-approve any new SPLs
NEW_SPL_CREATED=false
[ -z "$EXISTING_OPENAI_SPL" ] || [ -z "$EXISTING_COG_SPL" ] && NEW_SPL_CREATED=true
if [ "$NEW_SPL_CREATED" = true ]; then
  echo "  ⏳ Waiting 60s for AI Services SPL provisioning..."
  sleep 60
  for PE_CONN_ID in $(az network private-endpoint-connection list \
    --id "$AI_SERVICES_ID" \
    --query "[?properties.privateLinkServiceConnectionState.status=='Pending'].id" -o tsv 2>/dev/null); do
    az network private-endpoint-connection approve \
      --id "$PE_CONN_ID" \
      --description "Approved for AI Search skillset" \
      --output none 2>/dev/null || true
  done
fi
echo "  ✅ All Shared Private Links in place"
echo ""
fi  # end SKIP_SHARED_PRIVATE_LINKS check

###############################################################################
# 5. RBAC: AI Search → AI Services
###############################################################################
if (( START_STEP <= 5 )); then
echo "──── Step 5: RBAC — AI Search → AI Services ────"

for ROLE in "Cognitive Services OpenAI User" "Cognitive Services User"; do
  az role assignment create \
    --assignee-object-id "$SEARCH_IDENTITY" \
    --assignee-principal-type ServicePrincipal \
    --role "$ROLE" \
    --scope "$AI_SERVICES_ID" \
    --output none 2>/dev/null || true
  echo "  ✅ AI Search → $ROLE"
done

# Enable trusted service bypass on AI Services
az rest --method PATCH \
  --url "https://management.azure.com${AI_SERVICES_ID}?api-version=2024-10-01" \
  --body '{"properties": {"networkAcls": {"bypass": "AzureServices"}}}' \
  --output none
echo "  ✅ AI Services: trusted service bypass enabled"
else
echo "──── Step 5: RBAC — AI Search → AI Services (SKIPPED: START_STEP=$START_STEP) ────"
fi
echo ""

###############################################################################
# 6. AI Search: Vector Index, Data Source, Skillset, Indexer
###############################################################################
echo "──── Step 6: Creating AI Search Artifacts ────"

SEARCH_ENDPOINT="https://${AI_SEARCH_NAME}.search.windows.net"
OPENAI_URI="${OPENAI_RESOURCE_URI}"
EMB_DEPLOY="${EMBEDDING_DEPLOYMENT_ID}"
EMB_MODEL="${EMBEDDING_MODEL_NAME}"
EMB_DIM="${EMBEDDING_DIMENSIONS}"
API_VER="2024-11-01-preview"

if [ "$SEARCH_ACCESS_MODE" = "private" ]; then
  echo "  SEARCH_ACCESS_MODE=private — using private endpoint."
  # Best-effort DNS resolution for diagnostics only — never fail the script
  # if the local tooling can't resolve (Git Bash on Windows has no getent
  # and may not have python3). The real test is the HTTP probe below.
  SEARCH_HOST="${AI_SEARCH_NAME}.search.windows.net"
  set +e
  RESOLVED_IP=""
  if command -v getent >/dev/null 2>&1; then
    RESOLVED_IP=$(getent hosts "$SEARCH_HOST" 2>/dev/null | awk '{print $1}' | head -n1)
  fi
  if [ -z "$RESOLVED_IP" ] && command -v python3 >/dev/null 2>&1; then
    RESOLVED_IP=$($PY -c "import socket;print(socket.gethostbyname('$SEARCH_HOST'))" 2>/dev/null)
  fi
  if [ -z "$RESOLVED_IP" ] && command -v python >/dev/null 2>&1; then
    RESOLVED_IP=$(python -c "import socket;print(socket.gethostbyname('$SEARCH_HOST'))" 2>/dev/null)
  fi
  if [ -z "$RESOLVED_IP" ] && command -v nslookup >/dev/null 2>&1; then
    RESOLVED_IP=$(nslookup "$SEARCH_HOST" 2>/dev/null | awk '/^Address: /{print $2; exit}')
  fi
  set -e
  if [ -n "$RESOLVED_IP" ]; then
    echo "  DNS: ${SEARCH_HOST} → ${RESOLVED_IP}"
    if [[ "$RESOLVED_IP" =~ ^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.) ]]; then
      echo "  ✅ Resolves to private IP (private endpoint)."
    else
      echo "  ⚠️  Resolves to a PUBLIC IP. The service is either reachable over the"
      echo "     public internet (public access enabled) or DNS is not pointing to the PE."
    fi
  else
    echo "  (DNS resolution skipped — no local resolver tool found; relying on curl probe.)"
  fi
  # Probe TCP/443 + TLS — accept any HTTP response (even 401/403/404) as reachable.
  set +e
  HTTP_CODE=$(curl -sS --max-time 10 -o /dev/null -w "%{http_code}" \
      "${SEARCH_ENDPOINT}/servicestats?api-version=${API_VER}" \
      -H "api-key: $SEARCH_KEY" 2>/dev/null)
  CURL_RC=$?
  set -e
  [ -z "$HTTP_CODE" ] && HTTP_CODE="000"
  if [ "$HTTP_CODE" = "000" ]; then
    echo "  ❌ Cannot reach ${SEARCH_ENDPOINT} from this machine (curl exit=${CURL_RC})."
    echo "     Connect to the VNet (VPN/bastion) or use SEARCH_ACCESS_MODE=toggle-public."
    exit 1
  fi
  echo "  ✅ Endpoint reachable (HTTP ${HTTP_CODE})."
else
  echo "  ⚠️  SEARCH_ACCESS_MODE=toggle-public — will temporarily enable AI Search public access."
  echo "     This may violate the customer's network policy. Prefer SEARCH_ACCESS_MODE=private"
  echo "     and run this script from inside the VNet (VPN/Bastion)."
  read -r -p "     Continue and toggle public access? [y/N]: " CONFIRM_TOGGLE
  if [[ ! "$CONFIRM_TOGGLE" =~ ^[Yy]$ ]]; then
    echo "  Aborted by operator. Re-run with SEARCH_ACCESS_MODE=private from inside the VNet."
    exit 1
  fi
  echo "  Temporarily enabling AI Search public access..."
  if ! az search service update --name "$AI_SEARCH_NAME" --resource-group "$SPOKE_RG" \
      --public-access enabled --output none 2>/tmp/search-toggle.err; then
    echo "  ❌ Failed to enable public access on AI Search."
    cat /tmp/search-toggle.err
    echo "     Set SEARCH_ACCESS_MODE=private and run from inside the VNet."
    exit 1
  fi
  sleep 15
fi

# Clean up old artifacts
echo "  Cleaning up old artifacts..."
curl -s -X DELETE "${SEARCH_ENDPOINT}/indexers/${IDXR}?api-version=${API_VER}" \
  -H "api-key: $SEARCH_KEY" > /dev/null 2>&1 || true
curl -s -X DELETE "${SEARCH_ENDPOINT}/skillsets/${SS}?api-version=${API_VER}" \
  -H "api-key: $SEARCH_KEY" > /dev/null 2>&1 || true
curl -s -X DELETE "${SEARCH_ENDPOINT}/indexes/${IDX}?api-version=${API_VER}" \
  -H "api-key: $SEARCH_KEY" > /dev/null 2>&1 || true
curl -s -X DELETE "${SEARCH_ENDPOINT}/datasources/${DS}?api-version=${API_VER}" \
  -H "api-key: $SEARCH_KEY" > /dev/null 2>&1 || true
sleep 5

# Helper: PUT a Search artifact
search_put() {
  local SUFFIX="$1" LABEL="$2" BODY="$3"
  local RESP_FILE="/tmp/search-put-resp.$$"
  local CODE
  CODE=$(curl -sS -o "$RESP_FILE" -w "%{http_code}" -X PUT \
    "${SEARCH_ENDPOINT}/${SUFFIX}?api-version=${API_VER}" \
    -H "Content-Type: application/json" \
    -H "api-key: $SEARCH_KEY" \
    -d "$BODY")
  if [ "$CODE" != "200" ] && [ "$CODE" != "201" ] && [ "$CODE" != "204" ]; then
    echo "  ❌ $LABEL create failed (HTTP $CODE):"
    cat "$RESP_FILE"; echo ""
    rm -f "$RESP_FILE"
    exit 1
  fi
  rm -f "$RESP_FILE"
}

# --- Index ---
if [ "$SEMANTIC_CONFIG_ENABLED" = "true" ]; then
  SEMANTIC_JSON=',
  "semantic":{
    "defaultConfiguration":"'"${IDX}"'-semantic-configuration",
    "configurations":[{
      "name":"'"${IDX}"'-semantic-configuration",
      "prioritizedFields":{
        "titleField":{"fieldName":"title"},
        "prioritizedContentFields":[{"fieldName":"chunk"}],
        "prioritizedKeywordsFields":[]
      }
    }]
  }'
else
  SEMANTIC_JSON=""
fi

search_put "indexes/${IDX}" "Index ${IDX}" '{
  "name": "'"${IDX}"'",
  "fields": [
    {"name":"chunk_id","type":"Edm.String","key":true,"searchable":true,"filterable":false,"retrievable":true,"stored":true,"sortable":true,"analyzer":"keyword"},
    {"name":"acl_user_ids","type":"Edm.String","searchable":true,"filterable":true,"retrievable":true,"stored":true,"sortable":false},
    {"name":"acl_group_ids","type":"Edm.String","searchable":true,"filterable":true,"retrievable":true,"stored":true,"sortable":false},
    {"name":"purview_label_name","type":"Edm.String","searchable":false,"filterable":true,"retrievable":true,"stored":true,"facetable":true},
    {"name":"purview_is_encrypted","type":"Edm.String","searchable":false,"filterable":true,"retrievable":true,"stored":true,"facetable":true},
    {"name":"purview_protection_status","type":"Edm.String","searchable":false,"filterable":true,"retrievable":true,"stored":true,"facetable":true},
    {"name":"text_parent_id","type":"Edm.String","searchable":false,"filterable":true,"retrievable":true,"stored":true},
    {"name":"chunk","type":"Edm.String","searchable":true,"filterable":false,"retrievable":true,"stored":true},
    {"name":"title","type":"Edm.String","searchable":true,"filterable":false,"retrievable":true,"stored":true},
    {"name":"text_vector","type":"Collection(Edm.Single)","searchable":true,"filterable":false,"retrievable":true,"stored":true,"dimensions":'"${EMB_DIM}"',"vectorSearchProfile":"'"${IDX}"'-azureOpenAi-text-profile"},
    {"name":"case_id","type":"Edm.String","searchable":false,"filterable":true,"retrievable":true,"stored":true},
    {"name":"original_file_name","type":"Edm.String","searchable":true,"filterable":false,"retrievable":true,"stored":true},
    {"name":"url","type":"Edm.String","searchable":false,"filterable":false,"retrievable":true,"stored":true}
  ],
  "similarity":{"@odata.type":"#Microsoft.Azure.Search.BM25Similarity"}'"${SEMANTIC_JSON}"',
  "vectorSearch":{
    "algorithms":[{
      "name":"'"${IDX}"'-algorithm",
      "kind":"hnsw",
      "hnswParameters":{"metric":"'"${VECTOR_METRIC}"'","m":'"${HNSW_M}"',"efConstruction":'"${HNSW_EF_CONSTRUCTION}"',"efSearch":'"${HNSW_EF_SEARCH}"'}
    }],
    "profiles":[{
      "name":"'"${IDX}"'-azureOpenAi-text-profile",
      "algorithm":"'"${IDX}"'-algorithm",
      "vectorizer":"'"${IDX}"'-azureOpenAi-text-vectorizer"
    }],
    "vectorizers":[{
      "name":"'"${IDX}"'-azureOpenAi-text-vectorizer",
      "kind":"azureOpenAI",
      "azureOpenAIParameters":{
        "resourceUri":"'"${OPENAI_URI}"'",
        "deploymentId":"'"${EMB_DEPLOY}"'",
        "modelName":"'"${EMB_MODEL}"'"
      }
    }],
    "compressions":[]
  }
}'
echo "  ✅ Index: ${IDX} (HNSW m=${HNSW_M} efC=${HNSW_EF_CONSTRUCTION} efS=${HNSW_EF_SEARCH}, semantic=${SEMANTIC_CONFIG_ENABLED})"

# --- Data Source ---
STORAGE_RESOURCE_ID="/subscriptions/$SUBSCRIPTION/resourceGroups/$SPOKE_RG/providers/Microsoft.Storage/storageAccounts/$STORAGE_NAME"
STORAGE_CONN="ResourceId=${STORAGE_RESOURCE_ID};"

search_put "datasources/${DS}" "Data Source ${DS}" "{
  \"name\": \"${DS}\",
  \"type\": \"azureblob\",
  \"credentials\": {\"connectionString\": \"${STORAGE_CONN}\"},
  \"container\": {\"name\": \"${BLOB_CONTAINER_NAME}\"},
  \"dataDeletionDetectionPolicy\": {
    \"@odata.type\": \"#Microsoft.Azure.Search.SoftDeleteColumnDeletionDetectionPolicy\",
    \"softDeleteColumnName\": \"IsDeleted\",
    \"softDeleteMarkerValue\": \"true\"
  }
}"
echo "  ✅ Data Source: ${DS} (managed identity, soft-delete detection)"

# --- Skillset ---
AI_SERVICES_KEY=$(az cognitiveservices account keys list \
  --name "$AI_SERVICES_NAME" --resource-group "$SPOKE_RG" --query key1 -o tsv)
AI_SERVICES_SUBDOMAIN="https://${AI_SERVICES_NAME}.cognitiveservices.azure.com"

search_put "skillsets/${SS}" "Skillset ${SS}" '{
  "name": "'"${SS}"'",
  "description": "Skillset with OCR, text chunking, and Azure OpenAI embeddings via Foundry",
  "cognitiveServices": {
    "@odata.type": "#Microsoft.Azure.Search.AIServicesByKey",
    "description": "AI Services via trusted service bypass",
    "key": "'"${AI_SERVICES_KEY}"'",
    "subdomainUrl": "'"${AI_SERVICES_SUBDOMAIN}"'"
  },
  "skills": [
    {
      "@odata.type": "#Microsoft.Skills.Vision.OcrSkill",
      "name": "ocr-skill",
      "description": "OCR skill to extract text from images",
      "context": "/document/normalized_images/*",
      "lineEnding": "Space",
      "defaultLanguageCode": "en",
      "detectOrientation": true,
      "inputs": [{"name":"image","source":"/document/normalized_images/*"}],
      "outputs": [{"name":"text","targetName":"text"}]
    },
    {
      "@odata.type": "#Microsoft.Skills.Text.MergeSkill",
      "name": "merge-skill",
      "description": "Merge OCR text from images with document content",
      "context": "/document",
      "insertPreTag": " ",
      "insertPostTag": " ",
      "inputs": [
        {"name":"text","source":"/document/content"},
        {"name":"itemsToInsert","source":"/document/normalized_images/*/text"},
        {"name":"offsets","source":"/document/normalized_images/*/contentOffset"}
      ],
      "outputs": [{"name":"mergedText","targetName":"mergedText"}]
    },
    {
      "@odata.type": "#Microsoft.Skills.Text.SplitSkill",
      "name": "split-skill",
      "description": "Split skill to chunk documents",
      "context": "/document",
      "defaultLanguageCode": "en",
      "textSplitMode": "'"${CHUNK_SPLIT_MODE}"'",
      "unit": "'"${CHUNK_UNIT}"'",
      "maximumPageLength": '"${CHUNK_SIZE}"',
      "pageOverlapLength": '"${CHUNK_OVERLAP}"',
      "inputs": [{"name":"text","source":"/document/mergedText"}],
      "outputs": [{"name":"textItems","targetName":"pages"}]
    },
    {
      "@odata.type": "#Microsoft.Skills.Text.AzureOpenAIEmbeddingSkill",
      "name": "text-embedding-skill",
      "description": "Azure OpenAI Embedding skill for text chunks via Foundry",
      "context": "/document/pages/*",
      "resourceUri": "'"${OPENAI_URI}"'",
      "deploymentId": "'"${EMB_DEPLOY}"'",
      "dimensions": '"${EMB_DIM}"',
      "modelName": "'"${EMB_MODEL}"'",
      "inputs": [{"name":"text","source":"/document/pages/*"}],
      "outputs": [{"name":"embedding","targetName":"text_vector"}]
    }
  ],
  "indexProjections": {
    "selectors": [{
      "targetIndexName": "'"${IDX}"'",
      "parentKeyFieldName": "text_parent_id",
      "sourceContext": "/document/pages/*",
      "mappings": [
        {"name":"text_vector","source":"/document/pages/*/text_vector"},
        {"name":"chunk","source":"/document/pages/*"},
        {"name":"title","source":"/document/metadata_storage_name"},
        {"name":"original_file_name","source":"/document/sharepoint_web_url"},
        {"name":"acl_user_ids","source":"/document/user_ids"},
        {"name":"acl_group_ids","source":"/document/group_ids"},
        {"name":"purview_label_name","source":"/document/purview_label_name"},
        {"name":"purview_is_encrypted","source":"/document/purview_is_encrypted"},
        {"name":"purview_protection_status","source":"/document/purview_protection_status"},
        {"name":"url","source":"/document/sharepoint_web_url"}
      ]
    }],
    "parameters": {"projectionMode":"skipIndexingParentDocuments"}
  }
}'
echo "  ✅ Skillset: ${SS} (OCR → merge → chunk → embed)"

# --- Indexer ---
search_put "indexers/${IDXR}" "Indexer ${IDXR}" '{
  "name": "'"${IDXR}"'",
  "dataSourceName": "'"${DS}"'",
  "skillsetName": "'"${SS}"'",
  "targetIndexName": "'"${IDX}"'",
  "parameters": {
    "maxFailedItems": '"${INDEXER_MAX_FAILED_ITEMS}"',
    "maxFailedItemsPerBatch": '"${INDEXER_MAX_FAILED_PER_BATCH}"',
    "configuration": {
      "executionEnvironment": "private",
      "dataToExtract": "contentAndMetadata",
      "imageAction": "generateNormalizedImages",
      "parsingMode": "default",
      "indexedFileNameExtensions": ".pdf,.docx,.doc,.pptx,.ppt,.xlsx,.xls,.txt,.md,.html,.csv,.json,.rtf,.eml,.msg",
      "failOnUnsupportedContentType": false,
      "failOnUnprocessableDocument": false,
      "indexStorageMetadataOnlyForOversizedDocuments": true
    }
  },
  "schedule": {"interval": "'"${INDEXER_SCHEDULE_INTERVAL}"'"},
  "fieldMappings": [
    {"sourceFieldName":"metadata_storage_name","targetFieldName":"title"},
    {"sourceFieldName":"caseId","targetFieldName":"case_id"},
    {"sourceFieldName":"sharepoint_web_url","targetFieldName":"original_file_name"},
    {"sourceFieldName":"sharepoint_web_url","targetFieldName":"url"}
  ],
  "outputFieldMappings": []
}'
echo "  ✅ Indexer: ${IDXR} (schedule=${INDEXER_SCHEDULE_INTERVAL}, private execution)"

# Re-lock AI Search if toggled
if [ "$SEARCH_ACCESS_MODE" != "private" ]; then
  az search service update --name "$AI_SEARCH_NAME" --resource-group "$SPOKE_RG" \
    --public-access disabled --output none
  echo "  ✅ AI Search locked down"
fi
echo ""

###############################################################################
# 6b. Patch all indexers to Private execution
###############################################################################
echo "──── Step 6b: Ensuring all indexers use Private execution ────"
SEARCH_KEY=$(az search admin-key show --service-name "$AI_SEARCH_NAME" -g "$SPOKE_RG" --query primaryKey -o tsv)
# NOTE: $select is intentionally omitted — Git Bash on Windows mangles the
# '$' in the URL ("curl: (3) URL rejected: Malformed input to a URL function").
# We parse names client-side anyway, so dropping it is harmless.
IDX_LIST=$(curl -sS -H "api-key: $SEARCH_KEY" \
  "https://${AI_SEARCH_NAME}.search.windows.net/indexers?api-version=2024-07-01" 2>/dev/null \
  | $PY -c "import sys,json; sys.stdout.write('\n'.join(i['name'] for i in json.load(sys.stdin).get('value',[])))" 2>/dev/null \
  | tr -d '\r' || true)
for IDXR_NAME in $IDX_LIST; do
  # Strip any stray CR (Windows Python text-mode stdout adds \r\n; for-loop split keeps the \r)
  IDXR_NAME="${IDXR_NAME%$'\r'}"
  [ -z "$IDXR_NAME" ] && continue
  IDXR_JSON=$(curl -sS -H "api-key: $SEARCH_KEY" \
    "https://${AI_SEARCH_NAME}.search.windows.net/indexers/${IDXR_NAME}?api-version=2024-07-01")
  NEW_JSON=$(echo "$IDXR_JSON" | $PY -c "
import sys,json
d=json.load(sys.stdin)
params=d.setdefault('parameters',{})
conf=params.setdefault('configuration',{})
if conf.get('executionEnvironment','').lower() != 'private':
    conf['executionEnvironment']='Private'
    print(json.dumps(d))
")
  if [ -n "$NEW_JSON" ]; then
    HTTP=$(curl -sS -o /dev/null -w "%{http_code}" -X PUT \
      -H "api-key: $SEARCH_KEY" -H "Content-Type: application/json" \
      "https://${AI_SEARCH_NAME}.search.windows.net/indexers/${IDXR_NAME}?api-version=2024-07-01" \
      -d "$NEW_JSON")
    echo "  ✅ ${IDXR_NAME}: patched to Private (HTTP $HTTP)"
  else
    echo "  ℹ️  ${IDXR_NAME}: already Private"
  fi
done
echo ""

###############################################################################
# 7. Firewall Rules
###############################################################################
SP_SYNC_FQDNS=(
  "graph.microsoft.com"
  "login.microsoftonline.com"
  "*.sharepoint.com"
  "*.applicationinsights.azure.com"
  "*.in.applicationinsights.azure.com"
  "*.livediagnostics.monitor.azure.com"
  "dc.services.visualstudio.com"
  "*.services.visualstudio.com"
)

if [ "$SKIP_FIREWALL_RULES" = "true" ]; then
  echo "──── Step 7: Firewall Rules (SKIPPED — SKIP_FIREWALL_RULES=true) ────"
  echo "  ℹ️  Assumes the following egress FQDNs are already allowed:"
  for FQDN in "${SP_SYNC_FQDNS[@]}"; do
    echo "     - $FQDN"
  done
  echo ""
elif [ "$FW_MODE" != "azure" ]; then
  echo "──── Step 7: Firewall Rules (SKIPPED — FW_MODE=$FW_MODE) ────"
  echo "  ⚠️  You must allow the following egress FQDNs on your firewall"
  echo "  (source: ${SPOKE_ADDRESS_SPACE:-<spoke-cidr>}, dest: HTTPS/443):"
  for FQDN in "${SP_SYNC_FQDNS[@]}"; do
    echo "     - $FQDN"
  done
  echo ""
else
  echo "──── Step 7: Adding Firewall Rules ────"

  az network firewall policy rule-collection-group show \
    --resource-group "$FW_POLICY_RG" \
    --policy-name "$FW_POLICY_NAME" \
    --name "FoundryAppRules" \
    --output none 2>/dev/null || \
  az network firewall policy rule-collection-group create \
    --resource-group "$FW_POLICY_RG" \
    --policy-name "$FW_POLICY_NAME" \
    --name "FoundryAppRules" \
    --priority 300 \
    --output none

  az network firewall policy rule-collection-group collection add-filter-collection \
    --resource-group "$FW_POLICY_RG" \
    --policy-name "$FW_POLICY_NAME" \
    --rule-collection-group-name "FoundryAppRules" \
    --name "AllowSharePointSync" \
    --collection-priority 400 \
    --action Allow \
    --rule-type ApplicationRule \
    --rule-name "SharePointGraph" \
    --source-addresses "${SPOKE_ADDRESS_SPACE:-10.100.0.0/16}" \
    --protocols Https=443 \
    --target-fqdns "${SP_SYNC_FQDNS[@]}" \
    --output none 2>/dev/null || echo "  (rule may already exist)"

  echo "  ✅ Firewall rules: ${SP_SYNC_FQDNS[*]}"
  echo ""
fi

###############################################################################
# 8. Publish Sync Code (.NET 10 isolated worker)
###############################################################################
echo "──── Step 8: Publishing Sync Code ────"

if [ ! -f "$SYNC_SRC_DIR/SharePointSyncFunc.csproj" ]; then
  echo "  ❌ Vendored .NET project not found at $SYNC_SRC_DIR"
  echo "     Expected deployment/sharepoint-sync-func/SharePointSyncFunc.csproj"
  echo "     (this script targets the .NET 10 isolated worker build of the sync"
  echo "      function — the Python source has been removed.)"
  exit 1
fi

FUNC_SRC_DIR="$SYNC_SRC_DIR"
echo "  Source:        $FUNC_SRC_DIR (vendored, .NET 10 isolated)"

# Require dotnet SDK
if ! command -v dotnet >/dev/null 2>&1; then
  echo "  ❌ dotnet SDK is required to build the .NET 10 Function App."
  echo "     Install: https://learn.microsoft.com/dotnet/core/install/"
  exit 1
fi
DOTNET_VER=$(dotnet --version 2>/dev/null || echo "?")
echo "  dotnet SDK:    $DOTNET_VER"

# Verify the customer's Function App is actually .NET 10 isolated.
FUNC_LINUX_FX=$(az functionapp config show -g "$SPOKE_RG" -n "$FUNC_APP_NAME" \
  --query "linuxFxVersion" -o tsv 2>/dev/null || echo "")
FUNC_WORKER_RT=$(az functionapp config appsettings list -g "$SPOKE_RG" -n "$FUNC_APP_NAME" \
  --query "[?name=='FUNCTIONS_WORKER_RUNTIME'].value | [0]" -o tsv 2>/dev/null || echo "")
echo "  FA linuxFxVersion:        ${FUNC_LINUX_FX:-<unset>}"
echo "  FA FUNCTIONS_WORKER_RUNTIME: ${FUNC_WORKER_RT:-<unset>}"

if [ -n "$FUNC_WORKER_RT" ] && ! echo "$FUNC_WORKER_RT" | grep -qi "dotnet-isolated"; then
  echo ""
  echo "  ⚠️  Function App FUNCTIONS_WORKER_RUNTIME='${FUNC_WORKER_RT}', expected 'dotnet-isolated'."
  echo "     This script publishes a .NET 10 isolated worker — runtime stack must match."
  echo "     Either recreate the FA with --runtime dotnet-isolated --runtime-version 10.0,"
  echo "     or set FORCE_PUBLISH=1 to attempt the publish anyway."
  if [ "${FORCE_PUBLISH:-0}" != "1" ]; then
    exit 1
  fi
  echo "     FORCE_PUBLISH=1 set — continuing."
fi

# Remove stale build-flag settings that interfere with prebuilt .NET publish.
az functionapp config appsettings delete \
  --name "$FUNC_APP_NAME" -g "$SPOKE_RG" \
  --setting-names SCM_DO_BUILD_DURING_DEPLOYMENT ENABLE_ORYX_BUILD \
  --output none 2>/dev/null || true

# Build & publish .NET project to a staging dir.
PKG_DIR=$(mktemp -d -t sp-sync-pub-XXXX)
echo "  Publishing to: $PKG_DIR"
if ! dotnet publish "$FUNC_SRC_DIR/SharePointSyncFunc.csproj" \
      -c Release -o "$PKG_DIR" \
      -p:UseAppHost=false \
      --nologo -v minimal 2>/tmp/pub-err.txt; then
  echo "  ❌ dotnet publish failed:"
  head -c 2000 /tmp/pub-err.txt
  exit 1
fi
echo "  ✅ dotnet publish complete"

DEPLOY_ZIP="/tmp/sp-sync-deploy-$$.zip"
(cd "$PKG_DIR" && zip -rq "$DEPLOY_ZIP" . -x ".git/*" ".env")
echo "  Zip size: $(du -h "$DEPLOY_ZIP" | cut -f1)"

# Detect Function App SKU (Flex vs Consumption/EP) — affects /api/publish flags.
FUNC_SKU=$(az functionapp show -g "$SPOKE_RG" -n "$FUNC_APP_NAME" \
  --query "[properties.sku, sku]" -o tsv 2>/dev/null | tr -d '\r\n\t' || true)
FUNC_KIND=$(az functionapp show -g "$SPOKE_RG" -n "$FUNC_APP_NAME" --query "kind" -o tsv 2>/dev/null || true)
IS_FLEX=0
if echo "${FUNC_SKU}${FUNC_KIND}" | grep -qi "flex"; then
  IS_FLEX=1
fi
echo "  Function App kind: $FUNC_KIND (Flex=$IS_FLEX)"

PUBLISH_OK=0
PUBLISH_LAST_ERR=""

# Primary path: az CLI's deployment API.
#
# Why az CLI first (and not the raw curl /api/publish that the eli-tectika
# script uses): az CLI is a Python program and honors WinHTTP / system proxy
# settings out of the box. Customers in corporate environments (forced web
# proxy, TLS interception, restricted egress) routinely have working az but
# a curl that gets HTTP 000 (connection refused / TLS handshake failure /
# proxy required). az also retries internally and handles SCM's quirks across
# Flex / EP / Consumption.
for ATTEMPT in 1 2 3; do
  echo "  Publish attempt $ATTEMPT/3 (az functionapp deployment source config-zip)..."
  if az functionapp deployment source config-zip \
      -g "$SPOKE_RG" -n "$FUNC_APP_NAME" \
      --src "$DEPLOY_ZIP" \
      --build-remote false \
      --timeout 900 \
      --output none 2>/tmp/pub-err.txt; then
    echo "  ✅ Accepted (az CLI)"
    PUBLISH_OK=1
    break
  fi
  PUBLISH_LAST_ERR=$(head -c 600 /tmp/pub-err.txt 2>/dev/null || echo "")
  echo "  ⚠️  $PUBLISH_LAST_ERR"
  [ "$ATTEMPT" -lt 3 ] && sleep 20
done

# Backup path: raw POST to SCM /api/publish with an ARM bearer token. Useful
# when az CLI gets a transient failure but the underlying endpoint works.
# Skipped immediately on HTTP 000 (no point retrying network errors).
if [ "$PUBLISH_OK" != "1" ]; then
  echo ""
  echo "  az CLI publish failed. Trying raw SCM /api/publish..."
  SCM_HOST="${FUNC_APP_NAME}.scm.azurewebsites.net"
  ARM_TOKEN=$(az account get-access-token --resource https://management.azure.com/ \
    --query accessToken -o tsv 2>/dev/null || echo "")
  if [ -z "$ARM_TOKEN" ]; then
    echo "  ⚠️  Could not obtain ARM access token — skipping SCM curl path."
  else
    # Hint corporate-proxy users.
    if [ -n "${HTTPS_PROXY:-}${HTTP_PROXY:-}${https_proxy:-}${http_proxy:-}" ]; then
      echo "  (using proxy from HTTPS_PROXY/HTTP_PROXY env var)"
    fi

    for ATTEMPT in 1 2 3; do
      echo "  curl attempt $ATTEMPT/3 (POST https://${SCM_HOST}/api/publish?RemoteBuild=false&Deployer=az_cli)..."
      # Capture http_code and curl exit code separately. Without this, a
      # failed curl writes "000" to stdout AND `|| echo "000"` fires, yielding
      # "000000" which never matches "200/202/201".
      HTTP_CODE=$(curl -sS -o /tmp/pub-resp.txt -w "%{http_code}" \
        --max-time 900 \
        -X POST "https://${SCM_HOST}/api/publish?RemoteBuild=false&Deployer=az_cli" \
        -H "Authorization: Bearer $ARM_TOKEN" \
        -H "Content-Type: application/zip" \
        --data-binary "@${DEPLOY_ZIP}" 2>/tmp/pub-err.txt) || HTTP_CODE="000"

      if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "202" ] || [ "$HTTP_CODE" = "201" ]; then
        echo "  ✅ Accepted (HTTP $HTTP_CODE)"
        PUBLISH_OK=1
        break
      fi

      PUBLISH_LAST_ERR="HTTP $HTTP_CODE — $(head -c 500 /tmp/pub-resp.txt 2>/dev/null)$(head -c 200 /tmp/pub-err.txt 2>/dev/null)"
      echo "  ⚠️  $PUBLISH_LAST_ERR"

      # HTTP 000 = curl couldn't reach the endpoint at all (DNS/TCP/TLS/proxy).
      # No point retrying — go straight to the blob fallback.
      if [ "$HTTP_CODE" = "000" ]; then
        echo "  (curl could not reach SCM endpoint — likely corporate proxy"
        echo "   or private-endpoint-only. Skipping to blob fallback.)"
        break
      fi

      [ "$ATTEMPT" -lt 3 ] && sleep 30
    done
  fi
fi

# Fallback path: blob-based Run-From-Package. This is the most reliable deploy
# method for locked-down apps where Kudu's SCM /api/publish controller is
# broken (e.g. Linux Elastic Premium with WEBSITE_RUN_FROM_PACKAGE already set,
# private-endpoint-isolated SCM, or Kudu Lite). It uploads the zip to the
# Function App's existing storage account and points the app at it via SAS.
if [ "$PUBLISH_OK" != "1" ]; then
  echo ""
  echo "  ⚠️  SCM zip-deploy did not succeed. Falling back to blob-based"
  echo "     Run-From-Package (WEBSITE_RUN_FROM_PACKAGE)."
  echo "     Last SCM error:"
  echo "$PUBLISH_LAST_ERR" | head -3 | sed 's/^/       /'
  echo ""

  RFP_CONTAINER="scm-releases"
  RFP_BLOB="sp-sync-$(date +%Y%m%d-%H%M%S).zip"

  # Use the FA's runtime storage account for the package.
  RFP_STORAGE="${FUNC_STORAGE_NAME}"
  if [ -z "$RFP_STORAGE" ]; then
    echo "  ❌ FUNC_STORAGE_NAME is not set — cannot stage deployment package."
    exit 1
  fi
  echo "  Storage account: $RFP_STORAGE"
  echo "  Container:       $RFP_CONTAINER"
  echo "  Blob:            $RFP_BLOB"

  # Get storage account key (works if caller has Storage Account Contributor
  # or Reader+Data role with key-list permission). If key listing is blocked
  # by policy, surface a clear error.
  STG_KEY=$(az storage account keys list -g "$SPOKE_RG" -n "$RFP_STORAGE" \
    --query "[0].value" -o tsv 2>/tmp/stg-err.txt || true)
  if [ -z "$STG_KEY" ]; then
    echo "  ❌ Could not retrieve storage account key for $RFP_STORAGE."
    echo "     $(head -c 400 /tmp/stg-err.txt 2>/dev/null)"
    echo ""
    echo "     Either grant 'Storage Account Key Operator' on the account, or"
    echo "     disable the 'allow shared key access = false' policy temporarily."
    exit 1
  fi

  # Create container (idempotent). --account-key uses the data plane, which
  # requires the caller's IP to reach the storage account. If the SA has
  # private endpoints only, run this script from inside the VNet.
  az storage container create \
    --account-name "$RFP_STORAGE" --account-key "$STG_KEY" \
    --name "$RFP_CONTAINER" --output none 2>/tmp/stg-err.txt || {
      echo "  ❌ Could not create/access container '$RFP_CONTAINER':"
      head -c 400 /tmp/stg-err.txt 2>/dev/null
      echo ""
      echo "     If the storage account is private-endpoint-only, run this"
      echo "     script from inside the VNet (jumpbox/bastion/VPN)."
      exit 1
    }

  echo "  Uploading $(du -h "$DEPLOY_ZIP" | cut -f1) zip to blob storage..."
  if ! az storage blob upload \
        --account-name "$RFP_STORAGE" --account-key "$STG_KEY" \
        --container-name "$RFP_CONTAINER" --name "$RFP_BLOB" \
        --file "$DEPLOY_ZIP" --overwrite --output none 2>/tmp/stg-err.txt; then
    echo "  ❌ Blob upload failed:"
    head -c 400 /tmp/stg-err.txt 2>/dev/null
    exit 1
  fi

  # Generate read-only SAS valid 10 years (long-lived; FA needs it to fetch
  # the package on every cold start).
  SAS_EXPIRY=$(date -u -v+10y +%Y-%m-%dT%H:%MZ 2>/dev/null || \
               date -u -d '+10 years' +%Y-%m-%dT%H:%MZ 2>/dev/null || \
               date -u -d '+3650 days' +%Y-%m-%dT%H:%MZ)
  SAS=$(az storage blob generate-sas \
    --account-name "$RFP_STORAGE" --account-key "$STG_KEY" \
    --container-name "$RFP_CONTAINER" --name "$RFP_BLOB" \
    --permissions r --expiry "$SAS_EXPIRY" --https-only -o tsv 2>/tmp/stg-err.txt)
  if [ -z "$SAS" ]; then
    echo "  ❌ Could not generate SAS:"
    head -c 400 /tmp/stg-err.txt 2>/dev/null
    exit 1
  fi

  # Build the blob URL. Use the private-DNS-resolvable .blob.core.windows.net
  # hostname so the FA fetches via its VNet integration / private endpoint.
  PKG_URL="https://${RFP_STORAGE}.blob.core.windows.net/${RFP_CONTAINER}/${RFP_BLOB}?${SAS}"

  echo "  Setting WEBSITE_RUN_FROM_PACKAGE on Function App..."
  az functionapp config appsettings set \
    -g "$SPOKE_RG" -n "$FUNC_APP_NAME" \
    --settings "WEBSITE_RUN_FROM_PACKAGE=${PKG_URL}" \
    --output none

  # WEBSITE_RUN_FROM_PACKAGE=1 (local) and =<url> (blob) are mutually
  # exclusive. If the app was previously on =1, the URL form now wins, but
  # we explicitly clear the legacy ENABLE_ORYX_BUILD/SCM_DO_BUILD_DURING_DEPLOYMENT
  # to avoid any conflicting build step.
  az functionapp config appsettings delete \
    --name "$FUNC_APP_NAME" -g "$SPOKE_RG" \
    --setting-names SCM_DO_BUILD_DURING_DEPLOYMENT ENABLE_ORYX_BUILD \
    --output none 2>/dev/null || true

  PUBLISH_OK=1
  echo "  ✅ Package staged at: ${RFP_STORAGE}/${RFP_CONTAINER}/${RFP_BLOB}"
  rm -f /tmp/stg-err.txt
fi

rm -rf "$PKG_DIR" "$DEPLOY_ZIP" /tmp/pub-err.txt

echo "  Restarting Function App (forces it to pull the new package)..."
az functionapp restart -g "$SPOKE_RG" -n "$FUNC_APP_NAME" --output none
echo "  ✅ Sync code deployed"
echo ""

###############################################################################
# 9. Foundry Agent: Configure with Azure AI Search Tool
###############################################################################
echo "──── Step 9: Configuring Foundry Agent ────"

AI_SERVICES="${AI_SERVICES_NAME:-$(echo "$OPENAI_RESOURCE_URI" | sed -E 's|https://([^.]+)\..*|\1|')}"
PROJECT="${FOUNDRY_PROJECT_NAME:-}"
AGENT_NAME="${FOUNDRY_AGENT_NAME:-sharepoint-search-agent}"
AGENT_MODEL="${FOUNDRY_AGENT_MODEL:-gpt-4.1}"
DEFAULT_AGENT_INSTRUCTIONS=$'You are a grounded assistant over the SharePoint knowledge source (Azure AI Search index `sharepoint-index`).\n\n- For EVERY user question, call the `azure_ai_search` tool first.\n- Answer ONLY from the tool results. Never answer from general knowledge or the internet.\n- If the tool returns no relevant results, reply exactly: "I don\'t know — the answer is not in the knowledge source."\n\nHow to extract the SharePoint URL for citations:\nEach search result has a `content` field. The LAST two non-empty lines of `content` always are:\n  <document filename>\n  <SharePoint URL starting with https://...sharepoint.com/...>\nUse that trailing URL as the citation target. This is the ONLY correct URL. Ignore the `url` field (it always points to the search service endpoint) and ignore any intranet URLs (http://rimonp.mod.int/..., http://portalp3.mod.int/...) that appear earlier inside the content body.\n\nCitation output format — CRITICAL (Foundry post-processes your output and will break anything it recognizes as a citation anchor):\n- DO NOT use markdown link syntax [text](url). Foundry overwrites the URL.\n- DO NOT use markdown bold or italic (**text** or *text*). Foundry replaces styled text with a citation marker (%CITATION_N%).\n- DO NOT wrap the URL in backticks (that makes it non-clickable).\n- DO print the URL as a bare, plain URL on its own line. The Playground markdown renderer auto-linkifies bare URLs, and the citation rewriter leaves them alone.\n\nAt the end of your answer, on a new paragraph, write the exact heading line:\nמקורות:\n\nThen, for each distinct document you cited, print TWO consecutive lines:\n  Line 1: the plain document title (no markdown, no bold, no backticks).\n  Line 2: the bare SharePoint URL (no markdown, no backticks, no surrounding text — just the URL).\nLeave a blank line between sources.\n\nRules:\n- The SharePoint URL must be the last line of the result\'s `content`, must start with https://, and must contain `sharepoint.com`.\n- If a result\'s last content line does not start with `https://` and contain `sharepoint.com`, omit that source (do not invent URLs).\n- De-duplicate sources by URL.\n- Reply in the same language as the user\'s question (Hebrew in → Hebrew out).'
AGENT_INSTRUCTIONS="${FOUNDRY_AGENT_INSTRUCTIONS:-$DEFAULT_AGENT_INSTRUCTIONS}"

if [ -z "$PROJECT" ]; then
  echo "  ⚠️  FOUNDRY_PROJECT_NAME not set — skipping agent configuration."
else
  FOUNDRY_ENDPOINT="https://${AI_SERVICES}.services.ai.azure.com/api/projects/${PROJECT}"
  AGENT_API_VER="2025-05-15-preview"

  AGENT_TOKEN=$(az account get-access-token --resource "https://ai.azure.com" --query accessToken -o tsv 2>/dev/null)

  if [ -z "$AGENT_TOKEN" ]; then
    echo "  ⚠️  Could not get Foundry API token — skipping."
  else
    SEARCH_CONNECTION_NAME="${AI_SEARCH_NAME}"
    SEARCH_CONNECTION=$(curl -sf "${FOUNDRY_ENDPOINT}/connections/${SEARCH_CONNECTION_NAME}?api-version=${AGENT_API_VER}" \
      -H "Authorization: Bearer $AGENT_TOKEN" 2>/dev/null)

    SEARCH_CONNECTION_ID=$(echo "$SEARCH_CONNECTION" | $PY -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)

    if [ -z "$SEARCH_CONNECTION_ID" ]; then
      echo "  ⚠️  Could not find project connection '${SEARCH_CONNECTION_NAME}'."
      echo "     Create it in Foundry portal: Project → Operate → Admin → Add connection → Azure AI Search"
    else
      echo "  Using connection: $SEARCH_CONNECTION_ID"

      AGENT_BODY=$(AGENT_INSTRUCTIONS_ENV="$AGENT_INSTRUCTIONS" \
        AGENT_MODEL_ENV="$AGENT_MODEL" \
        SEARCH_CONNECTION_ID_ENV="$SEARCH_CONNECTION_ID" \
        INDEX_NAME_ENV="$IDX" \
        AGENT_QUERY_TYPE_ENV="$AGENT_QUERY_TYPE" \
        SEMANTIC_CONFIG_NAME_ENV="${IDX}-semantic-configuration" \
        SEMANTIC_CONFIG_ENABLED_ENV="$SEMANTIC_CONFIG_ENABLED" \
        $PY -c "
import json, os
qt = os.environ['AGENT_QUERY_TYPE_ENV']
uses_vector   = qt in ('vector', 'vectorSemanticHybrid')
uses_semantic = qt in ('semantic', 'vectorSemanticHybrid')
if uses_semantic and os.environ['SEMANTIC_CONFIG_ENABLED_ENV'] != 'true':
    raise SystemExit('AGENT_QUERY_TYPE=' + qt + ' requires SEMANTIC_CONFIG_ENABLED=true')
idx_cfg = {
    'project_connection_id': os.environ['SEARCH_CONNECTION_ID_ENV'],
    'index_name': os.environ['INDEX_NAME_ENV'],
    'query_type': qt,
    'fieldsMapping': {
        'urlField': 'url',
        'titleField': 'title',
        'contentFields': ['chunk'],
        'filepathField': 'title',
        'vectorFields': ['text_vector'] if uses_vector else []
    }
}
if uses_semantic:
    idx_cfg['semantic_configuration'] = os.environ['SEMANTIC_CONFIG_NAME_ENV']
body = {
    'definition': {
        'kind': 'prompt',
        'model': os.environ['AGENT_MODEL_ENV'],
        'instructions': os.environ['AGENT_INSTRUCTIONS_ENV'],
        'tools': [{
            'type': 'azure_ai_search',
            'azure_ai_search': {'indexes': [idx_cfg]}
        }]
    }
}
print(json.dumps(body))
")

      AGENT_RESPONSE=$(curl -sf -X POST \
        "${FOUNDRY_ENDPOINT}/agents/${AGENT_NAME}/versions?api-version=${AGENT_API_VER}" \
        -H "Authorization: Bearer $AGENT_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$AGENT_BODY" 2>/dev/null)

      AGENT_VERSION=$(echo "$AGENT_RESPONSE" | $PY -c "import json,sys; print(json.load(sys.stdin).get('version','?'))" 2>/dev/null)

      if [ "$AGENT_VERSION" != "?" ] && [ -n "$AGENT_VERSION" ]; then
        echo "  ✅ Agent '${AGENT_NAME}' version ${AGENT_VERSION} created"
        echo "     Tool: azure_ai_search → ${IDX} (query_type=${AGENT_QUERY_TYPE})"
        echo "     Model: ${AGENT_MODEL}"
      else
        echo "  ⚠️  Agent creation may have failed. Response:"
        echo "     $AGENT_RESPONSE" | head -3
      fi
    fi
  fi
fi
echo ""

###############################################################################
# 9b. Agentic Retrieval (opt-in)
###############################################################################
if [ "$USE_AGENTIC_RETRIEVAL" != "true" ]; then
  echo "──── Step 9b: Agentic Retrieval (SKIPPED — USE_AGENTIC_RETRIEVAL=false) ────"
  echo ""
else
  echo "──── Step 9b: Agentic Retrieval (Knowledge Source + KB + MCP agent) ────"

  if [ -z "${PROJECT:-}" ] || [ -z "${AGENT_TOKEN:-}" ]; then
    echo "  ⚠️  FOUNDRY_PROJECT_NAME not set or auth token missing — skipping."
  else
    KS_NAME="$AGENTIC_KS_NAME"
    KB_NAME="$AGENTIC_KB_NAME"
    KB_AGENT_NAME="$AGENTIC_AGENT_NAME"
    PROJECT_CONN_NAME="$AGENTIC_PROJECT_CONN_NAME"
    KB_API_VER="2025-11-01-preview"
    AOAI_ENDPOINT="https://${AI_SERVICES}.cognitiveservices.azure.com"

    SEARCH_MI=$(az search service show -g "$SPOKE_RG" -n "$AI_SEARCH_NAME" --query identity.principalId -o tsv)
    PROJECT_MI=$(az cognitiveservices account show -g "$SPOKE_RG" -n "$AI_SERVICES" --query identity.principalId -o tsv)
    SEARCH_ID=$(az search service show -g "$SPOKE_RG" -n "$AI_SEARCH_NAME" --query id -o tsv)

    # RBAC for agentic retrieval
    az role assignment create \
      --assignee-object-id "$SEARCH_MI" --assignee-principal-type ServicePrincipal \
      --role "Cognitive Services User" --scope "$AI_SERVICES_ID" \
      --output none 2>/dev/null && echo "  ✅ Search MI → Cognitive Services User" \
      || echo "  ℹ️  Search MI role already present"
    az role assignment create \
      --assignee-object-id "$PROJECT_MI" --assignee-principal-type ServicePrincipal \
      --role "Search Index Data Reader" --scope "$SEARCH_ID" \
      --output none 2>/dev/null && echo "  ✅ Project MI → Search Index Data Reader" \
      || echo "  ℹ️  Project MI role already present"
    az role assignment create \
      --assignee-object-id "$PROJECT_MI" --assignee-principal-type ServicePrincipal \
      --role "Search Service Contributor" --scope "$SEARCH_ID" \
      --output none 2>/dev/null && echo "  ✅ Project MI → Search Service Contributor" \
      || echo "  ℹ️  Project MI role already present"

    # Knowledge Source
    KS_BODY=$(cat <<EOF
{
  "name": "${KS_NAME}",
  "kind": "searchIndex",
  "description": "SharePoint index wrapper for agentic retrieval",
  "searchIndexParameters": {
    "searchIndexName": "${IDX}",
    "sourceDataFields": [
      { "name": "title" },
      { "name": "chunk" },
      { "name": "url" }
    ]
  }
}
EOF
)
    KS_HTTP=$(curl -sS -o /tmp/ks-resp.json -w "%{http_code}" \
      -X PUT "${SEARCH_ENDPOINT}/knowledgesources/${KS_NAME}?api-version=${KB_API_VER}" \
      -H "api-key: $SEARCH_KEY" -H "Content-Type: application/json" --data "$KS_BODY")
    if [[ "$KS_HTTP" =~ ^20[0-9]$ ]]; then
      echo "  ✅ Knowledge Source: ${KS_NAME}"
    else
      echo "  ❌ KS failed (HTTP $KS_HTTP):"; cat /tmp/ks-resp.json; echo; exit 1
    fi

    # Knowledge Base
    KB_BODY=$(cat <<EOF
{
  "name": "${KB_NAME}",
  "description": "Agentic retrieval KB over SharePoint",
  "knowledgeSources": [ { "name": "${KS_NAME}" } ],
  "models": [
    {
      "kind": "azureOpenAI",
      "azureOpenAIParameters": {
        "resourceUri": "${AOAI_ENDPOINT}",
        "deploymentId": "${AGENTIC_PLANNER_MODEL}",
        "modelName": "${AGENTIC_PLANNER_MODEL}"
      }
    }
  ],
  "retrievalReasoningEffort": { "kind": "${AGENTIC_REASONING_EFFORT}" },
  "outputMode": "${AGENTIC_OUTPUT_MODE}"
}
EOF
)
    KB_HTTP=$(curl -sS -o /tmp/kb-resp.json -w "%{http_code}" \
      -X PUT "${SEARCH_ENDPOINT}/knowledgebases/${KB_NAME}?api-version=${KB_API_VER}" \
      -H "api-key: $SEARCH_KEY" -H "Content-Type: application/json" --data "$KB_BODY")
    if [[ "$KB_HTTP" =~ ^20[0-9]$ ]]; then
      echo "  ✅ Knowledge Base: ${KB_NAME} (planner=${AGENTIC_PLANNER_MODEL}, effort=${AGENTIC_REASONING_EFFORT})"
    else
      echo "  ❌ KB failed (HTTP $KB_HTTP):"; cat /tmp/kb-resp.json; echo; exit 1
    fi

    # Project connection → KB MCP endpoint
    MCP_ENDPOINT="${SEARCH_ENDPOINT}/knowledgebases/${KB_NAME}/mcp?api-version=${KB_API_VER}"
    ARM_TOKEN=$(az account get-access-token --resource https://management.azure.com/ --query accessToken -o tsv)
    CONN_BODY=$(cat <<EOF
{
  "name": "${PROJECT_CONN_NAME}",
  "type": "Microsoft.MachineLearningServices/workspaces/connections",
  "properties": {
    "authType": "ProjectManagedIdentity",
    "category": "RemoteTool",
    "target": "${MCP_ENDPOINT}",
    "isSharedToAll": true,
    "audience": "https://search.azure.com/",
    "metadata": { "ApiType": "Azure" }
  }
}
EOF
)
    CONN_URL="https://management.azure.com${AI_SERVICES_ID}/projects/${PROJECT}/connections/${PROJECT_CONN_NAME}?api-version=2025-10-01-preview"
    CONN_HTTP=$(curl -sS -o /tmp/conn-resp.json -w "%{http_code}" \
      -X PUT "$CONN_URL" -H "Authorization: Bearer $ARM_TOKEN" \
      -H "Content-Type: application/json" --data "$CONN_BODY")
    if [[ "$CONN_HTTP" =~ ^20[0-9]$ ]]; then
      CONN_ID=$($PY -c "import json; print(json.load(open('/tmp/conn-resp.json')).get('id',''))")
      echo "  ✅ Project connection: ${PROJECT_CONN_NAME}"
    else
      echo "  ❌ Project connection failed (HTTP $CONN_HTTP):"; cat /tmp/conn-resp.json; echo; exit 1
    fi

    # Second agent using MCP tool
    AGENTIC_INSTRUCTIONS_DEFAULT=$'You are a grounded assistant over the SharePoint knowledge source (AI Search Knowledge Base `sharepoint-kb`).\n\n- For EVERY user question, call the `knowledge_base_retrieve` tool first.\n- Answer ONLY from the tool results. Never answer from general knowledge or the internet.\n- If the tool returns nothing relevant, reply exactly: "I don\'t know — the answer is not in the knowledge source."\n\nHow to extract the SharePoint URL for citations:\nThe tool response contains a `references` array. Each entry has:\n  - `sourceData.title` — the document title\n  - `sourceData.url`   — the SharePoint web URL (starts with https:// and contains `sharepoint.com`)\nUse `sourceData.url` as the citation target. Ignore the auto-generated `doc_0 / doc_1` ref IDs — those are internal.\n\nCitation output format — CRITICAL (Foundry post-processes your output and will break anything it recognizes as a citation anchor):\n- DO NOT use markdown link syntax [text](url). Foundry overwrites the URL with a `doc_N` marker.\n- DO NOT use markdown bold or italic (**text** or *text*). Foundry replaces styled text with a citation marker.\n- DO NOT wrap the URL in backticks (that makes it non-clickable).\n- DO print the URL as a bare, plain URL on its own line. The Playground markdown renderer auto-linkifies bare URLs, and the citation rewriter leaves them alone.\n\nAt the end of your answer, on a new paragraph, write the exact heading line:\nמקורות:\n\nThen, for each distinct document you cited, print TWO consecutive lines:\n  Line 1: the plain document title from `sourceData.title` (no markdown, no bold, no backticks).\n  Line 2: the bare SharePoint URL from `sourceData.url` (no markdown, no backticks, no surrounding text — just the URL).\nLeave a blank line between sources.\n\nRules:\n- The URL must start with https:// and contain `sharepoint.com`. If `sourceData.url` is missing or does not match, omit that source (do not invent URLs).\n- De-duplicate sources by URL.\n- Reply in the same language as the user\'s question (Hebrew in → Hebrew out).'
    AGENTIC_INSTRUCTIONS="${AGENTIC_AGENT_INSTRUCTIONS:-$AGENTIC_INSTRUCTIONS_DEFAULT}"
    AGENTIC_BODY=$(AGENT_INSTR="$AGENTIC_INSTRUCTIONS" \
      AGENT_MODEL_ENV="${AGENTIC_PLANNER_MODEL}" \
      CONN_ID="$CONN_ID" MCP_URL="$MCP_ENDPOINT" \
      $PY -c "
import json, os
body = {
  'definition': {
    'kind': 'prompt',
    'model': os.environ['AGENT_MODEL_ENV'],
    'instructions': os.environ['AGENT_INSTR'],
    'tools': [{
      'type': 'mcp',
      'server_label': 'knowledge_base',
      'server_url': os.environ['MCP_URL'],
      'require_approval': 'never',
      'allowed_tools': ['knowledge_base_retrieve'],
      'project_connection_id': os.environ['CONN_ID']
    }]
  }
}
print(json.dumps(body))")
    AGENTIC_HTTP=$(curl -sS -o /tmp/agentic-resp.json -w "%{http_code}" \
      -X POST "${FOUNDRY_ENDPOINT}/agents/${KB_AGENT_NAME}/versions?api-version=${AGENT_API_VER}" \
      -H "Authorization: Bearer $AGENT_TOKEN" -H "Content-Type: application/json" \
      --data "$AGENTIC_BODY")
    if [[ "$AGENTIC_HTTP" =~ ^20[0-9]$ ]]; then
      AGENTIC_VER=$($PY -c "import json; print(json.load(open('/tmp/agentic-resp.json')).get('version','?'))")
      echo "  ✅ Agent '${KB_AGENT_NAME}' version ${AGENTIC_VER} created"
    else
      echo "  ⚠️  Agent '${KB_AGENT_NAME}' creation failed (HTTP $AGENTIC_HTTP):"
      cat /tmp/agentic-resp.json; echo
    fi
  fi
  echo ""
fi

###############################################################################
# Summary
###############################################################################
echo ""
FA_HOSTNAME=$(az rest --method GET \
  --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${SPOKE_RG}/providers/Microsoft.Web/sites/${FUNC_APP_NAME}?api-version=2023-12-01" \
  --query "properties.defaultHostName" -o tsv 2>/dev/null)
FUNC_MASTER_KEY=$(az functionapp keys list -g "$SPOKE_RG" -n "$FUNC_APP_NAME" --query masterKey -o tsv 2>/dev/null)
SYNC_CONSOLE_URL=""
if [ -n "$FA_HOSTNAME" ] && [ -n "$FUNC_MASTER_KEY" ]; then
  SYNC_CONSOLE_URL="https://${FA_HOSTNAME}/api/sync?code=${FUNC_MASTER_KEY}"
fi

# Persist SYNC_CONSOLE_URL back into env file
if [ -n "$SYNC_CONSOLE_URL" ] && [ -f "$ENV_FILE" ]; then
  AUTO_BEGIN="# >>> auto-populated by 3-deploy-sharepoint-sync-existing-env.sh (do not edit) >>>"
  AUTO_END="# <<< auto-populated by 3-deploy-sharepoint-sync-existing-env.sh <<<"
  TMP_ENV=$(mktemp)
  awk -v b="$AUTO_BEGIN" -v e="$AUTO_END" '
    $0==b {skip=1; next}
    $0==e {skip=0; next}
    skip {next}
    /^SYNC_CONSOLE_URL=/ {next}
    /^FUNC_APP_HOSTNAME=/ {next}
    {print}
  ' "$ENV_FILE" > "$TMP_ENV"
  awk 'BEGIN{n=0} {lines[NR]=$0} END{ for(i=NR;i>=1 && lines[i]=="";i--); for(j=1;j<=i;j++) print lines[j] }' "$TMP_ENV" > "${TMP_ENV}.trim" && mv "${TMP_ENV}.trim" "$TMP_ENV"
  {
    echo ""
    echo "$AUTO_BEGIN"
    echo "FUNC_APP_HOSTNAME=${FA_HOSTNAME}"
    echo "SYNC_CONSOLE_URL=${SYNC_CONSOLE_URL}"
    echo "$AUTO_END"
  } >> "$TMP_ENV"
  mv "$TMP_ENV" "$ENV_FILE"
  echo "  ✅ SYNC_CONSOLE_URL written to $(basename "$ENV_FILE")"
fi

echo "============================================"
echo " ✅ SharePoint Sync — Existing Environment"
echo "============================================"
echo ""
echo " Pipeline: SharePoint → Function App → Blob → AI Search"
echo ""
echo " Configured (all infra was pre-existing):"
echo "   Function App:   $FUNC_APP_NAME"
echo "   Func Storage:   $FUNC_STORAGE_NAME"
echo "   Key Vault:      $KV_NAME"
echo "   Blob Container: $BLOB_CONTAINER_NAME (in $STORAGE_NAME)"
echo "   Search Index:   ${IDX}"
echo "   Search Indexer: ${IDXR} (${INDEXER_SCHEDULE_INTERVAL})"
echo "   Shared PL:      AI Search → Storage (blob) + AI Services"
echo "   Foundry Agent:  ${FOUNDRY_AGENT_NAME:-sharepoint-search-agent}"
echo ""
echo " 🔗 Sync Console URL:"
echo "    ${SYNC_CONSOLE_URL:-N/A}"
echo ""
echo " ⏱️  Schedules:"
echo "    TIMER_SCHEDULE       = ${TIMER_SCHEDULE:-0 0 * * * *}   (delta sync)"
echo "    TIMER_SCHEDULE_FULL  = ${TIMER_SCHEDULE_FULL:-0 0 3 * * *}   (full reconcile)"
echo ""
echo " 📋 View logs:"
echo "    Portal → $FUNC_APP_NAME → Log stream"
echo "============================================"
