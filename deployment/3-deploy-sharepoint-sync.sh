#!/bin/bash
set -euo pipefail

###############################################################################
# 3-deploy-sharepoint-sync.sh — SharePoint → Blob → AI Search Sync Pipeline
#
# Deploys on top of an existing hub-spoke + Foundry environment:
#   1. Creates func-subnet with VNet integration delegation
#   2. Creates a Blob container for SharePoint sync in existing storage
#   3. Creates Function App storage (with pre-created file share)
#   4. Deploys Azure Function App (Elastic Premium, Python, VNet-integrated)
#   5. Locks down Function App storage (private endpoints: blob+file+queue+table)
#      + Links private DNS zones to spoke VNet
#   6. Deploys Key Vault (private) with SPN secrets
#   7. Configures Function App settings (KV refs + AI Search + OpenAI)
#   8. Grants RBAC: Function App → Storage, Key Vault
#   9. Creates Shared Private Links: AI Search → Storage + AI Services
#  10. Grants RBAC: AI Search → AI Services (for embedding/OCR skills)
#  11. Creates AI Search vector index, data source, skillset, and indexer
#  12. Adds firewall rules for Graph API + SharePoint + Entra ID
#  13. Clones sync code and publishes to Function App (zip + Oryx remote build)
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
  SUBSCRIPTION_ID LOCATION SPOKE_RG SPOKE_VNET_NAME FW_PRIVATE_IP
)
# HUB_RG is only required when FW_MODE=azure (default). With FW_MODE=external
# (3rd-party firewall) the script does not touch any Azure Firewall policy.
if [ "${FW_MODE:-azure}" = "azure" ]; then
  REQUIRED_VARS+=(HUB_RG)
fi
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
# DNS_SUBSCRIPTION: private DNS zones are often in a central hub/connectivity
# subscription. Defaults to the deployment subscription; override in .env.
DNS_SUBSCRIPTION="${DNS_SUBSCRIPTION:-$SUBSCRIPTION_ID}"
# DNS_ZONE_RG: where to place AUTO-CREATED private DNS zones (queue/table).
# Enterprise customers typically centralize all privatelink.* zones in a single
# hub/connectivity RG managed by the network team. Set this to that RG so the
# zones created here follow the same governance. If unset, zones are created in
# SPOKE_RG (workload-local) to preserve backward compatibility.
DNS_ZONE_RG="${DNS_ZONE_RG:-$SPOKE_RG}"
# FW_MODE: 'azure' applies rules to the Azure Firewall policy;
#          'external' skips Azure FW steps (for 3rd-party NVAs e.g. Fortinet,
#           Palo Alto) and prints the FQDNs that must be allowed manually.
FW_MODE="${FW_MODE:-azure}"
FW_POLICY_NAME="${FW_POLICY_NAME:-hub-fw-policy}"
FW_POLICY_RG="${FW_POLICY_RG:-${HUB_RG:-}}"
FW_RCG_NAME="${FW_RCG_NAME:-DefaultAppRuleGroup}"
FW_RCG_PRIORITY="${FW_RCG_PRIORITY:-300}"
SPOKE_PE_SUBNET_NAME="${SPOKE_PE_SUBNET_NAME:-pe-subnet}"
UDR_NAME="${UDR_NAME:-}"  # auto-discovered below if empty
AI_SEARCH_NAME="$SEARCH_SERVICE_NAME"
STORAGE_NAME="$AZURE_STORAGE_ACCOUNT_NAME"
SP_TENANT_ID="$AZURE_TENANT_ID"
SP_CLIENT_ID="$AZURE_CLIENT_ID"
SP_CLIENT_SECRET="$AZURE_CLIENT_SECRET"
SP_SITE_URL="$SHAREPOINT_SITE_URL"

# Generated resource names
FUNC_SUBNET_NAME="func-subnet"
FUNC_SUBNET_PREFIX="${FUNC_SUBNET_PREFIX:-10.230.4.0/24}"

# Resource names are STABLE across re-runs:
#   1. If set in env (FUNC_APP_NAME / FUNC_STORAGE_NAME / KV_NAME) → use it.
#   2. Else try to reuse an existing resource in SPOKE_RG that matches our prefix.
#   3. Else derive a deterministic suffix from a hash of SPOKE_RG (same RG → same names).
# This prevents the "every run creates new objects" problem.
_stable_suffix() {
  # 6 hex chars deterministic hash of "${SPOKE_RG}-${1}"
  echo -n "${SPOKE_RG}-$1" | shasum -a 256 | cut -c1-6
}
_find_existing() {
  # $1 = resource type, $2 = name prefix → prints first match in SPOKE_RG or empty
  az resource list -g "$SPOKE_RG" --resource-type "$1" \
    --query "[?starts_with(name, '$2')].name | [0]" -o tsv 2>/dev/null
}

if [ -z "${FUNC_APP_NAME:-}" ]; then
  FUNC_APP_NAME="$(_find_existing Microsoft.Web/sites sp-sync-func-)"
  [ -z "$FUNC_APP_NAME" ] && FUNC_APP_NAME="sp-sync-func-$(_stable_suffix func)"
fi
FUNC_PLAN_NAME="${FUNC_PLAN_NAME:-${FUNC_APP_NAME}-plan}"

if [ -z "${FUNC_STORAGE_NAME:-}" ]; then
  FUNC_STORAGE_NAME="$(_find_existing Microsoft.Storage/storageAccounts fnstor)"
  [ -z "$FUNC_STORAGE_NAME" ] && FUNC_STORAGE_NAME="fnstor$(_stable_suffix fnstor)$(_stable_suffix fnstor2 | cut -c1-2)"
fi

if [ -z "${KV_NAME:-}" ]; then
  KV_NAME="$(_find_existing Microsoft.KeyVault/vaults kv-spsync-)"
  [ -z "$KV_NAME" ] && KV_NAME="kv-spsync-$(_stable_suffix kv)"
fi

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
# 0. Auto-Discovery — find existing infra (customer env compatible)
#
# Discovers resources that vary by environment:
#   - UDR_NAME: inherit from an existing spoke subnet that routes through FW
#   - SPOKE_PE_SUBNET_NAME: verify it exists
#   - Private DNS zone RGs: zones may live in different RGs (network team vs hub)
#   - Firewall policy location: may not be in HUB_RG
#
# Any value already set in .env is respected; discovery only fills gaps.
###############################################################################
echo "──── Step 0: Auto-Discovery ────"

# --- UDR: find existing UDR that routes through the firewall ---
if [ -z "$UDR_NAME" ]; then
  # Try to inherit UDR from an existing spoke subnet (e.g. vm-subnet, pe-subnet)
  for CANDIDATE_SUBNET in vm-subnet "$SPOKE_PE_SUBNET_NAME" agent-subnet; do
    UDR_ID=$(az network vnet subnet show \
      --name "$CANDIDATE_SUBNET" --vnet-name "$SPOKE_VNET_NAME" -g "$SPOKE_RG" \
      --query "routeTable.id" -o tsv 2>/dev/null || true)
    if [ -n "$UDR_ID" ] && [ "$UDR_ID" != "null" ]; then
      UDR_NAME=$(basename "$UDR_ID")
      echo "  ✅ UDR discovered: $UDR_NAME (inherited from $CANDIDATE_SUBNET)"
      break
    fi
  done
  if [ -z "$UDR_NAME" ]; then
    # Fallback: find any UDR in the spoke RG that points 0.0.0.0/0 → FW
    UDR_NAME=$(az network route-table list -g "$SPOKE_RG" \
      --query "[?routes[?addressPrefix=='0.0.0.0/0' && nextHopIpAddress=='$FW_PRIVATE_IP']].name | [0]" -o tsv 2>/dev/null || true)
    if [ -n "$UDR_NAME" ]; then
      echo "  ✅ UDR discovered: $UDR_NAME (matched default-route-to-firewall)"
    else
      echo "  ⚠️  No UDR found. Set UDR_NAME in sharepoint-sync.env or create a route table first."
      exit 1
    fi
  fi
else
  echo "  ℹ️  UDR_NAME override: $UDR_NAME"
fi

# --- PE subnet: verify it exists ---
if ! az network vnet subnet show -n "$SPOKE_PE_SUBNET_NAME" --vnet-name "$SPOKE_VNET_NAME" -g "$SPOKE_RG" -o none 2>/dev/null; then
  echo "  ⚠️  PE subnet '$SPOKE_PE_SUBNET_NAME' not found in $SPOKE_VNET_NAME."
  echo "     Set SPOKE_PE_SUBNET_NAME in sharepoint-sync.env."
  exit 1
fi
echo "  ✅ PE subnet: $SPOKE_PE_SUBNET_NAME"

# --- Private DNS zones: discover RG per zone (may differ across zones) ---
# NOTE: we avoid bash 4+ associative arrays (macOS ships bash 3.2). Instead,
# `dns_zone_rg` queries Azure on demand and caches result in a tmp dir.
DNS_ZONE_CACHE_DIR="$(mktemp -d)"
trap 'rm -rf "$DNS_ZONE_CACHE_DIR"' EXIT

dns_zone_rg() {
  local ZONE="$1"
  local CACHE_FILE="$DNS_ZONE_CACHE_DIR/${ZONE//\//_}"
  if [ -f "$CACHE_FILE" ]; then
    cat "$CACHE_FILE"
    return
  fi
  local RG
  RG=$(az network private-dns zone list --subscription "$DNS_SUBSCRIPTION" \
    --query "[?name=='$ZONE'] | [0].resourceGroup" -o tsv 2>/dev/null || true)
  printf '%s' "$RG" > "$CACHE_FILE"
  printf '%s' "$RG"
}

dns_zone_id() {
  local ZONE="$1"
  local ID_CACHE="$DNS_ZONE_CACHE_DIR/id_${ZONE//\//_}"
  if [ -f "$ID_CACHE" ]; then
    cat "$ID_CACHE"
    return
  fi
  echo "/subscriptions/$DNS_SUBSCRIPTION/resourceGroups/$(dns_zone_rg "$ZONE")/providers/Microsoft.Network/privateDnsZones/$ZONE"
}

REQUIRED_ZONES="privatelink.blob.core.windows.net privatelink.file.core.windows.net privatelink.queue.core.windows.net privatelink.table.core.windows.net privatelink.vaultcore.azure.net privatelink.search.windows.net privatelink.cognitiveservices.azure.com privatelink.openai.azure.com"
# Zones that this workload is allowed to auto-provision in SPOKE_RG if missing.
# We restrict this to Function-storage privatelink zones (queue/table) because
# those are workload-local and not commonly pre-created by network teams.
# Everything else (blob/file/vault/search/openai/cognitive) MUST already exist
# somewhere in the subscription — we do NOT create them to avoid conflicts
# with centrally-managed DNS.
AUTOCREATE_ZONES="privatelink.queue.core.windows.net privatelink.table.core.windows.net"
MISSING_ZONES=""
for ZONE in $REQUIRED_ZONES; do
  RG=$(dns_zone_rg "$ZONE")
  if [ -n "$RG" ] && [ "$RG" != "null" ]; then
    echo "  ✅ DNS zone $ZONE → sub: $DNS_SUBSCRIPTION / RG: $RG"
    continue
  fi
  # Zone not found — try to auto-create if allowed
  case " $AUTOCREATE_ZONES " in
    *" $ZONE "*)
      # Auto-create in the designated DNS zone RG (central hub RG in enterprise
      # setups, or SPOKE_RG for workload-local). Uses DNS_SUBSCRIPTION so the
      # zone lands in the central connectivity subscription when configured.
      echo "  ℹ️  DNS zone $ZONE not found — auto-creating in sub:$DNS_SUBSCRIPTION / rg:$DNS_ZONE_RG ..."
      az network private-dns zone create --subscription "$DNS_SUBSCRIPTION" \
        -g "$DNS_ZONE_RG" -n "$ZONE" -o none 2>/dev/null || true
      # Bust cache and store the new location
      CACHE_FILE="$DNS_ZONE_CACHE_DIR/${ZONE//\//_}"
      printf '%s' "$DNS_ZONE_RG" > "$CACHE_FILE"
      ZONE_ID_CACHE="$DNS_ZONE_CACHE_DIR/id_${ZONE//\//_}"
      echo "/subscriptions/$DNS_SUBSCRIPTION/resourceGroups/$DNS_ZONE_RG/providers/Microsoft.Network/privateDnsZones/$ZONE" > "$ZONE_ID_CACHE"
      echo "  ✅ DNS zone $ZONE created in $DNS_ZONE_RG"
      ;;
    *)
      MISSING_ZONES="$MISSING_ZONES $ZONE"
      echo "  ⚠️  DNS zone $ZONE NOT FOUND in subscription $DNS_SUBSCRIPTION"
      ;;
  esac
done
if [ -n "$MISSING_ZONES" ]; then
  echo ""
  echo "  ❌ Missing required private DNS zones in subscription $DNS_SUBSCRIPTION:"
  for Z in $MISSING_ZONES; do echo "     $Z"; done
  echo "  Create them, link existing ones, or set DNS_SUBSCRIPTION in sharepoint-sync.env."
  exit 1
fi

# --- Firewall policy: verify it exists (only if FW_MODE=azure) ---
if [ "$FW_MODE" = "azure" ]; then
  if ! az network firewall policy show -n "$FW_POLICY_NAME" -g "$FW_POLICY_RG" -o none 2>/dev/null; then
    echo "  ⚠️  Firewall policy '$FW_POLICY_NAME' not found in RG '$FW_POLICY_RG'."
    echo "     Set FW_POLICY_NAME and FW_POLICY_RG in sharepoint-sync.env,"
    echo "     or set FW_MODE=external if you use a 3rd-party firewall."
    exit 1
  fi
  echo "  ✅ Firewall policy: $FW_POLICY_NAME (RG: $FW_POLICY_RG)"
else
  echo "  ℹ️  FW_MODE=external — Azure Firewall rule steps will be SKIPPED."
  echo "     You must allow the required FQDNs on your 3rd-party firewall manually."
fi

echo ""
echo "  Discovery summary:"
echo "    UDR:            $UDR_NAME"
echo "    PE subnet:      $SPOKE_PE_SUBNET_NAME"
echo "    DNS zones sub:  $DNS_SUBSCRIPTION"
if [ "$FW_MODE" = "azure" ]; then
  echo "    FW mode:        azure"
  echo "    FW policy:      $FW_POLICY_NAME @ $FW_POLICY_RG"
  echo "    FW RCG:         $FW_RCG_NAME"
else
  echo "    FW mode:        external (3rd-party — skipping FW rule creation)"
fi
echo ""

# (dns_zone_rg and dns_zone_id are defined above in the DNS discovery block)

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

# Use ARM management plane API (not data plane) because enterprise policy
# enforces allowSharedKeyAccess=false and storage is private.
STORAGE_ID=$(az storage account show --name "$STORAGE_NAME" --resource-group "$SPOKE_RG" --query id -o tsv)

az rest --method PUT \
  --url "https://management.azure.com${STORAGE_ID}/blobServices/default/containers/${BLOB_CONTAINER_NAME}?api-version=2023-05-01" \
  --body '{"properties":{}}' \
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

# Elastic Premium requires a content-share connection string. Use shared key
# for the workload-local function storage (we created it, it's private).
FUNC_STG_KEY=$(az storage account keys list \
  --account-name "$FUNC_STORAGE_NAME" -g "$SPOKE_RG" \
  --query "[0].value" -o tsv)
FUNC_STG_CONN="DefaultEndpointsProtocol=https;AccountName=${FUNC_STORAGE_NAME};AccountKey=${FUNC_STG_KEY};EndpointSuffix=core.windows.net"

# Create via ARM REST API (bypasses shared key validation issues).
# Retry on transient FailedIdentityOperation / InternalServerError (Azure MSI flakiness).
CREATE_ATTEMPT=0
CREATE_MAX=5
while : ; do
  CREATE_ATTEMPT=$((CREATE_ATTEMPT+1))
  if az rest --method PUT \
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
            {\"name\": \"AzureWebJobsStorage\", \"value\": \"$FUNC_STG_CONN\"},
            {\"name\": \"WEBSITE_CONTENTAZUREFILECONNECTIONSTRING\", \"value\": \"$FUNC_STG_CONN\"},
            {\"name\": \"WEBSITE_CONTENTSHARE\", \"value\": \"$FUNC_APP_NAME\"},
            {\"name\": \"WEBSITE_CONTENTOVERVNET\", \"value\": \"1\"},
            {\"name\": \"WEBSITE_DNS_SERVER\", \"value\": \"$FW_PRIVATE_IP\"}
          ]
        }
      }
    }" \
    --output none 2>/tmp/funcapp-create.err; then
    echo "  ✅ Function App created (attempt $CREATE_ATTEMPT)"
    break
  fi
  ERR_MSG=$(cat /tmp/funcapp-create.err || true)
  if [ "$CREATE_ATTEMPT" -ge "$CREATE_MAX" ]; then
    echo "  ❌ Function App create failed after $CREATE_MAX attempts:"
    echo "$ERR_MSG"
    exit 1
  fi
  if echo "$ERR_MSG" | grep -qE "FailedIdentityOperation|InternalServerError|timed out|timeout"; then
    echo "  ⚠️  Transient error (attempt $CREATE_ATTEMPT/$CREATE_MAX), retrying in 30s..."
    echo "      $(echo "$ERR_MSG" | head -1)"
    sleep 30
    continue
  fi
  echo "  ❌ Function App create failed with non-transient error:"
  echo "$ERR_MSG"
  exit 1
done

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
  --private-dns-zone "$(dns_zone_id privatelink.blob.core.windows.net)" \
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
  --private-dns-zone "$(dns_zone_id privatelink.file.core.windows.net)" \
  --zone-name "privatelink-file-core-windows-net" \
  --output none

# Queue PE (Functions need queues for AzureWebJobs triggers)
az network private-endpoint create \
  --name "pe-${FUNC_STORAGE_NAME}-queue" \
  --resource-group "$SPOKE_RG" \
  --vnet-name "$SPOKE_VNET_NAME" \
  --subnet "$SPOKE_PE_SUBNET_NAME" \
  --private-connection-resource-id "$FUNC_STORAGE_ID" \
  --group-id queue \
  --connection-name "pe-${FUNC_STORAGE_NAME}-queue-conn" \
  --location "$LOCATION" \
  --output none

az network private-endpoint dns-zone-group create \
  --resource-group "$SPOKE_RG" \
  --endpoint-name "pe-${FUNC_STORAGE_NAME}-queue" \
  --name "default" \
  --private-dns-zone "$(dns_zone_id privatelink.queue.core.windows.net)" \
  --zone-name "privatelink-queue-core-windows-net" \
  --output none

# Table PE (Functions need tables for AzureWebJobs lease management)
az network private-endpoint create \
  --name "pe-${FUNC_STORAGE_NAME}-table" \
  --resource-group "$SPOKE_RG" \
  --vnet-name "$SPOKE_VNET_NAME" \
  --subnet "$SPOKE_PE_SUBNET_NAME" \
  --private-connection-resource-id "$FUNC_STORAGE_ID" \
  --group-id table \
  --connection-name "pe-${FUNC_STORAGE_NAME}-table-conn" \
  --location "$LOCATION" \
  --output none

az network private-endpoint dns-zone-group create \
  --resource-group "$SPOKE_RG" \
  --endpoint-name "pe-${FUNC_STORAGE_NAME}-table" \
  --name "default" \
  --private-dns-zone "$(dns_zone_id privatelink.table.core.windows.net)" \
  --zone-name "privatelink-table-core-windows-net" \
  --output none

echo "  ✅ Function Storage locked down (blob + file + queue + table PEs)"

# Link private DNS zones to the spoke VNet (required for PE name resolution).
# Zones may be spread across RGs (and possibly a central DNS subscription);
# we use the per-zone RG resolved in Step 0 and --subscription $DNS_SUBSCRIPTION.
SPOKE_VNET_ID="/subscriptions/$SUBSCRIPTION/resourceGroups/$SPOKE_RG/providers/Microsoft.Network/virtualNetworks/$SPOKE_VNET_NAME"
DNS_LINK_NAME="spoke-sync-link"
for ZONE in privatelink.blob.core.windows.net privatelink.file.core.windows.net \
            privatelink.queue.core.windows.net privatelink.table.core.windows.net \
            privatelink.vaultcore.azure.net privatelink.search.windows.net \
            privatelink.cognitiveservices.azure.com privatelink.openai.azure.com; do
  ZONE_RG=$(dns_zone_rg "$ZONE")
  # If zone was auto-created in workload subscription, use that; else DNS_SUBSCRIPTION.
  ID_CACHE="$DNS_ZONE_CACHE_DIR/id_${ZONE//\//_}"
  if [ -f "$ID_CACHE" ]; then
    ZONE_SUB="$SUBSCRIPTION"
  else
    ZONE_SUB="$DNS_SUBSCRIPTION"
  fi
  az network private-dns link vnet create \
    --subscription "$ZONE_SUB" \
    --name "$DNS_LINK_NAME" \
    --zone-name "$ZONE" \
    --resource-group "$ZONE_RG" \
    --virtual-network "$SPOKE_VNET_ID" \
    --registration-enabled false \
    -o none 2>/dev/null || true
done
echo "  ✅ Private DNS zones linked to $SPOKE_VNET_NAME"
echo ""

###############################################################################
# 6. Deploy Key Vault (private, RBAC-enabled)
###############################################################################
echo "──── Step 6: Deploying Key Vault ────"

if az keyvault show --name "$KV_NAME" --resource-group "$SPOKE_RG" -o none 2>/dev/null; then
  echo "  ℹ️  Key Vault $KV_NAME already exists — reusing"
else
  az keyvault create \
    --name "$KV_NAME" \
    --resource-group "$SPOKE_RG" \
    --location "$LOCATION" \
    --sku standard \
    --enable-rbac-authorization true \
    --output none
fi

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
  --private-dns-zone "$(dns_zone_id privatelink.vaultcore.azure.net)" \
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
# 9. Shared Private Links: AI Search → Storage + AI Services
#    Checks for existing SPLs (e.g. from Bicep spoke deployment) to avoid
#    creating duplicates. SPLs are matched by target resource + groupId.
###############################################################################
echo "──── Step 9: Shared Private Links ────"

SEARCH_MGMT_API="2025-05-01"

AI_SERVICES_NAME=$(echo "$OPENAI_RESOURCE_URI" | sed -E 's|https://([^.]+)\..*|\1|')
AI_SERVICES_ID=$(az cognitiveservices account show --name "$AI_SERVICES_NAME" \
  --resource-group "$SPOKE_RG" --query id -o tsv)

# Fetch existing SPLs once
EXISTING_SPLS=$(az rest --method GET \
  --url "https://management.azure.com/subscriptions/$SUBSCRIPTION/resourceGroups/$SPOKE_RG/providers/Microsoft.Search/searchServices/$AI_SEARCH_NAME/sharedPrivateLinkResources?api-version=${SEARCH_MGMT_API}" \
  -o json 2>/dev/null || echo '{"value":[]}')

# Helper: check if an SPL already exists for a given target resource ID + groupId
spl_exists() {
  local TARGET_ID="$1" GROUP_ID="$2"
  echo "$EXISTING_SPLS" | python3 -c "
import json,sys
data = json.load(sys.stdin)
for v in data.get('value',[]):
    p = v.get('properties',{})
    if p.get('privateLinkResourceId','').lower() == '${TARGET_ID}'.lower() and p.get('groupId') == '${GROUP_ID}':
        print(v['name'])
        sys.exit(0)
sys.exit(1)
" 2>/dev/null
}

# --- SPL: AI Search → Storage (blob) ---
EXISTING_BLOB_SPL=$(spl_exists "$STORAGE_ID" "blob" || true)
if [ -n "$EXISTING_BLOB_SPL" ]; then
  echo "  ✅ SPL for Storage/blob already exists: $EXISTING_BLOB_SPL (skipping)"
else
  az rest --method PUT \
    --url "https://management.azure.com/subscriptions/$SUBSCRIPTION/resourceGroups/$SPOKE_RG/providers/Microsoft.Search/searchServices/$AI_SEARCH_NAME/sharedPrivateLinkResources/spl-storage-blob?api-version=${SEARCH_MGMT_API}" \
    --body "{
      \"properties\": {
        \"privateLinkResourceId\": \"$STORAGE_ID\",
        \"groupId\": \"blob\",
        \"requestMessage\": \"AI Search indexer needs access to SharePoint sync blobs\"
      }
    }" \
    --output none

  echo "  ⏳ SPL spl-storage-blob created. Waiting 30s for provisioning..."
  sleep 30

  # Auto-approve the PE connection
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

# --- SPL: AI Search → AI Services (OpenAI) ---
EXISTING_OPENAI_SPL=$(spl_exists "$AI_SERVICES_ID" "openai_account" || true)
if [ -n "$EXISTING_OPENAI_SPL" ]; then
  echo "  ✅ SPL for AI Services/openai_account already exists: $EXISTING_OPENAI_SPL (skipping)"
else
  az rest --method PUT \
    --url "https://management.azure.com/subscriptions/$SUBSCRIPTION/resourceGroups/$SPOKE_RG/providers/Microsoft.Search/searchServices/$AI_SEARCH_NAME/sharedPrivateLinkResources/spl-openai?api-version=${SEARCH_MGMT_API}" \
    --body "{
      \"properties\": {
        \"privateLinkResourceId\": \"$AI_SERVICES_ID\",
        \"groupId\": \"openai_account\",
        \"requestMessage\": \"AI Search skillset needs access to OpenAI embeddings\"
      }
    }" \
    --output none
  echo "  ✅ SPL spl-openai created"
fi

# --- SPL: AI Search → AI Services (Cognitive Services) ---
EXISTING_COG_SPL=$(spl_exists "$AI_SERVICES_ID" "cognitiveservices_account" || true)
if [ -n "$EXISTING_COG_SPL" ]; then
  echo "  ✅ SPL for AI Services/cognitiveservices_account already exists: $EXISTING_COG_SPL (skipping)"
else
  az rest --method PUT \
    --url "https://management.azure.com/subscriptions/$SUBSCRIPTION/resourceGroups/$SPOKE_RG/providers/Microsoft.Search/searchServices/$AI_SEARCH_NAME/sharedPrivateLinkResources/spl-cognitive?api-version=${SEARCH_MGMT_API}" \
    --body "{
      \"properties\": {
        \"privateLinkResourceId\": \"$AI_SERVICES_ID\",
        \"groupId\": \"cognitiveservices_account\",
        \"requestMessage\": \"AI Search skillset needs access to Cognitive Services (OCR)\"
      }
    }" \
    --output none
  echo "  ✅ SPL spl-cognitive created"
fi

# Wait for any new SPLs to provision, then auto-approve pending AI Services connections
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

###############################################################################
# 10. RBAC: AI Search → AI Services (for embedding/OCR skills)
###############################################################################
echo "──── Step 10: RBAC — AI Search → AI Services ────"

SEARCH_IDENTITY=$(az search service show --name "$AI_SEARCH_NAME" --resource-group "$SPOKE_RG" \
  --query "identity.principalId" -o tsv)
# AI_SERVICES_NAME and AI_SERVICES_ID already set in Step 9

for ROLE in "Cognitive Services OpenAI User" "Cognitive Services User"; do
  az role assignment create \
    --assignee-object-id "$SEARCH_IDENTITY" \
    --assignee-principal-type ServicePrincipal \
    --role "$ROLE" \
    --scope "$AI_SERVICES_ID" \
    --output none 2>/dev/null || true
  echo "  ✅ AI Search → $ROLE"
done

# Enable trusted service bypass on AI Services so AI Search can access it
# via shared private link for skillset operations (OCR, merge, etc.)
echo "  Enabling trusted service bypass on AI Services..."
az rest --method PATCH \
  --url "https://management.azure.com${AI_SERVICES_ID}?api-version=2024-10-01" \
  --body '{"properties": {"networkAcls": {"bypass": "AzureServices"}}}' \
  --output none
echo "  ✅ AI Services: trusted service bypass enabled"
echo ""

###############################################################################
# 11. AI Search: Vector Index, Data Source, Skillset, Indexer
#     (matches original repo: Azure-Samples/sharepoint-foundryIQ-secure-sync)
###############################################################################
echo "──── Step 11: Creating AI Search Artifacts (full pipeline) ────"

SEARCH_ENDPOINT="https://${AI_SEARCH_NAME}.search.windows.net"
IDX="${INDEX_NAME:-sharepoint-index}"
DS="${DATASOURCE_NAME:-sharepoint-blob-ds}"
SS="${SKILLSET_NAME:-sharepoint-sync-skillset}"
IDXR="${INDEXER_NAME:-sharepoint-blob-indexer}"
OPENAI_URI="${OPENAI_RESOURCE_URI}"
EMB_DEPLOY="${EMBEDDING_DEPLOYMENT_ID}"
# AI Search data-plane access mode:
#   toggle-public  (default) — briefly enable public access to POST artifacts,
#                   then disable. Will FAIL in customer envs with a Deny policy
#                   on publicNetworkAccess changes.
#   private       — never touch public access. Assumes the machine running
#                   this script can resolve + reach the Search private endpoint
#                   (e.g. connected via VPN, running on a jumpbox in the spoke,
#                   self-hosted runner in the VNet). Uses admin key for auth.
SEARCH_ACCESS_MODE="${SEARCH_ACCESS_MODE:-toggle-public}"

EMB_MODEL="${EMBEDDING_MODEL_NAME}"
EMB_DIM="${EMBEDDING_DIMENSIONS}"
API_VER="2024-11-01-preview"   # needed for #Microsoft.Azure.Search.AIServicesByKey w/ subdomainUrl

if [ "$SEARCH_ACCESS_MODE" = "private" ]; then
  echo "  SEARCH_ACCESS_MODE=private — using private endpoint (public access NOT toggled)."
  # Sanity check: can we actually reach the private endpoint?
  if ! curl -sf --max-time 10 -o /dev/null \
      "${SEARCH_ENDPOINT}/servicestats?api-version=${API_VER}" \
      -H "api-key: $SEARCH_KEY"; then
    echo "  ❌ Cannot reach ${SEARCH_ENDPOINT} from this machine."
    echo "     You are in SEARCH_ACCESS_MODE=private but the Search private endpoint"
    echo "     is not reachable. Connect to the VNet (VPN / bastion / jumpbox)"
    echo "     or switch to SEARCH_ACCESS_MODE=toggle-public if your policy allows."
    exit 1
  fi
  echo "  ✅ Private endpoint reachable — proceeding."
else
  # Temporarily enable public access (required only when running outside the VNet)
  echo "  Temporarily enabling AI Search public access (SEARCH_ACCESS_MODE=toggle-public)..."
  if ! az search service update --name "$AI_SEARCH_NAME" --resource-group "$SPOKE_RG" \
      --public-access enabled --output none 2>/tmp/search-toggle.err; then
    echo "  ❌ Failed to enable public access on AI Search."
    cat /tmp/search-toggle.err
    echo ""
    echo "     This usually means an Azure Policy is denying publicNetworkAccess changes."
    echo "     Set SEARCH_ACCESS_MODE=private in sharepoint-sync.env and run this script"
    echo "     from a machine inside the spoke VNet (VPN / bastion / self-hosted runner)."
    exit 1
  fi
  sleep 15
fi

# --- Delete old artifacts if they exist (clean slate) ---
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

# Helper: PUT a Search artifact, surface HTTP errors (don't swallow them).
# Usage: search_put <url-suffix> <label> <json-body>
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
    cat "$RESP_FILE"
    echo ""
    rm -f "$RESP_FILE"
    exit 1
  fi
  rm -f "$RESP_FILE"
}

# --- Index (vector search + semantic config, from original repo) ---
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
  "similarity":{"@odata.type":"#Microsoft.Azure.Search.BM25Similarity"},
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
  },
  "vectorSearch":{
    "algorithms":[{
      "name":"'"${IDX}"'-algorithm",
      "kind":"hnsw",
      "hnswParameters":{"metric":"cosine","m":4,"efConstruction":400,"efSearch":500}
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
echo "  ✅ Index: ${IDX} (vector + semantic)"

# --- Data Source (ResourceId — managed identity, soft-delete detection) ---
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

# --- Skillset (OCR + merge + chunking + Azure OpenAI embeddings) ---
# Use CognitiveServicesByKey with trusted service bypass (enabled in Step 10).
# This allows AI Search to access AI Services through the shared private link
# for OCR/merge skills while still using key-based billing (no 20-doc/day limit).
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
      "textSplitMode": "pages",
      "maximumPageLength": 2000,
      "pageOverlapLength": 200,
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
        {"name":"original_file_name","source":"/document/metadata_storage_name"},
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
}' > /dev/null
echo "  ✅ Skillset: ${SS} (OCR → merge → chunk → embed)"

# --- Indexer (with skillset, private execution, image extraction) ---
search_put "indexers/${IDXR}" "Indexer ${IDXR}" '{
  "name": "'"${IDXR}"'",
  "dataSourceName": "'"${DS}"'",
  "skillsetName": "'"${SS}"'",
  "targetIndexName": "'"${IDX}"'",
  "parameters": {
    "maxFailedItems": -1,
    "maxFailedItemsPerBatch": -1,
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
  "schedule": {"interval": "PT1H"},
  "fieldMappings": [
    {"sourceFieldName":"metadata_storage_name","targetFieldName":"title"},
    {"sourceFieldName":"caseId","targetFieldName":"case_id"},
    {"sourceFieldName":"originalFileName","targetFieldName":"original_file_name"},
    {"sourceFieldName":"sharepoint_web_url","targetFieldName":"url"}
  ],
  "outputFieldMappings": []
}'
echo "  ✅ Indexer: ${IDXR} (skillset=${SS}, hourly, private execution)"

# Re-lock AI Search only if we toggled it open
if [ "$SEARCH_ACCESS_MODE" = "private" ]; then
  echo "  ℹ️  SEARCH_ACCESS_MODE=private — public access was never touched."
else
  az search service update --name "$AI_SEARCH_NAME" --resource-group "$SPOKE_RG" \
    --public-access disabled --output none
  echo "  ✅ AI Search locked down"
fi
echo ""

###############################################################################
# 12. Firewall Rules: Graph API + SharePoint + Entra ID
###############################################################################
# Required egress FQDNs (same list applies whether using Azure FW or a 3rd-party NVA):
SP_SYNC_FQDNS=(
  "graph.microsoft.com"
  "login.microsoftonline.com"
  "*.sharepoint.com"
)

if [ "$FW_MODE" != "azure" ]; then
  echo "──── Step 12: Firewall Rules (SKIPPED — FW_MODE=$FW_MODE) ────"
  echo "  ⚠️  Azure Firewall rule creation skipped."
  echo "  You must allow the following egress FQDNs on your 3rd-party firewall"
  echo "  (source: spoke address space ${SPOKE_ADDRESS_SPACE:-<your-spoke-cidr>}, dest: HTTPS/443):"
  for FQDN in "${SP_SYNC_FQDNS[@]}"; do
    echo "     - $FQDN"
  done
  echo ""
else
  echo "──── Step 12: Adding Firewall Rules ────"

  # Ensure rule collection group exists
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
# 13. Clone & Publish Sync Code
###############################################################################
echo "──── Step 13: Cloning & Publishing Sync Code ────"

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

  # Use zip deploy with Oryx remote build (not local func publish).
  # Local 'func publish --python' builds native packages for the host arch
  # (e.g. ARM64 on macOS) which fail on Linux x64 Function Apps.
  DEPLOY_ZIP="/tmp/func-deploy-$$.zip"
  zip -r "$DEPLOY_ZIP" . -x ".git/*" "__pycache__/*" ".env" "*.pyc" ".venv/*" > /dev/null

  # Enable Oryx remote build
  az functionapp config appsettings set \
    --name "$FUNC_APP_NAME" --resource-group "$SPOKE_RG" \
    --settings "SCM_DO_BUILD_DURING_DEPLOYMENT=true" "ENABLE_ORYX_BUILD=true" \
    --output none

  # Publish via direct Kudu REST API — bypasses az CLI's SCM validation
  # (which uses a 30s timeout that often fails on private SCM endpoints,
  # even when the endpoint is fully reachable — see #2883 in azure-cli).
  # Uses ARM token for auth + isAsync=true so we don't wait on Oryx build.
  SCM_URL="https://${FUNC_APP_NAME}.scm.azurewebsites.net"
  echo "  Requesting ARM access token..."
  ARM_TOKEN=$(az account get-access-token --resource https://management.azure.com/ --query accessToken -o tsv)
  PUBLISH_OK=0
  for ATTEMPT in 1 2 3 4 5; do
    echo "  Publish attempt $ATTEMPT/5 (Kudu zipdeploy, async)..."
    DEPLOY_RESP=$(mktemp)
    HTTP_CODE=$(curl -sS -o "$DEPLOY_RESP" -w "%{http_code}" \
      --max-time 600 \
      -X POST "${SCM_URL}/api/zipdeploy?isAsync=true" \
      -H "Authorization: Bearer $ARM_TOKEN" \
      -H "Content-Type: application/zip" \
      --data-binary "@${DEPLOY_ZIP}" 2>&1) || HTTP_CODE="000"
    if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "202" ]; then
      echo "  ✅ Kudu accepted zip (HTTP $HTTP_CODE) — build will run in background."
      rm -f "$DEPLOY_RESP"
      PUBLISH_OK=1
      break
    fi
    echo "  ⚠️  Publish attempt $ATTEMPT failed (HTTP $HTTP_CODE):"
    head -5 "$DEPLOY_RESP" 2>/dev/null
    rm -f "$DEPLOY_RESP"
    if [ "$ATTEMPT" -lt 5 ]; then
      echo "     Waiting 45s before retry..."
      sleep 45
    fi
  done
  if [ "$PUBLISH_OK" != "1" ]; then
    echo "  ❌ Function App publish failed after 5 attempts."
    echo "     SCM endpoint: https://${FUNC_APP_NAME}.scm.azurewebsites.net"
    echo "     Ensure your machine has network reachability to the Function App SCM endpoint"
    echo "     (via VPN/private DNS) and rerun the script."
    rm -f "$DEPLOY_ZIP"
    popd > /dev/null
    exit 1
  fi

  rm -f "$DEPLOY_ZIP"
  popd > /dev/null
  echo "  ✅ Sync code published (remote build)"
fi
echo ""

###############################################################################
# 14. Foundry Agent: Configure with Azure AI Search Tool
#
# Creates/updates a Foundry agent that uses the azure_ai_search tool directly
# against the sharepoint-index. This provides native url_citation annotations
# that link to actual SharePoint document URLs (from the 'url' field in the
# index), instead of the Knowledge Base MCP endpoint URL.
#
# Why azure_ai_search instead of Knowledge Base MCP?
#   - Knowledge Base MCP only returns ref_id, title, content in tool results
#   - sourceDataFields in the knowledge source config doesn't affect MCP output
#   - The Foundry citation popup always links to the MCP server_url
#   - azure_ai_search tool natively supports url_citation with document URLs
###############################################################################
echo "──── Step 14: Configuring Foundry Agent ────"

AI_SERVICES="${AI_SERVICES_NAME:-$(echo "$OPENAI_RESOURCE_URI" | sed -E 's|https://([^.]+)\..*|\1|')}"
PROJECT="${FOUNDRY_PROJECT_NAME:-}"
AGENT_NAME="${FOUNDRY_AGENT_NAME:-sharepoint-search-agent}"
AGENT_MODEL="${FOUNDRY_AGENT_MODEL:-gpt-4.1}"
AGENT_INSTRUCTIONS="${FOUNDRY_AGENT_INSTRUCTIONS:-Answer only from the knowledge-source.\nYou are not allowed to answer from the internet.\nIf you don't know the answer say I don't know.\n\nWhen citing sources, use the document URL from the search results.}"

if [ -z "$PROJECT" ]; then
  echo "  ⚠️  FOUNDRY_PROJECT_NAME not set — skipping agent configuration."
  echo "     Set it in sharepoint-sync.env and re-run, or configure the agent manually."
else
  FOUNDRY_ENDPOINT="https://${AI_SERVICES}.services.ai.azure.com/api/projects/${PROJECT}"
  AGENT_API_VER="2025-05-15-preview"

  # Get Bearer token for Foundry API
  AGENT_TOKEN=$(az account get-access-token --resource "https://ai.azure.com" --query accessToken -o tsv 2>/dev/null)

  if [ -z "$AGENT_TOKEN" ]; then
    echo "  ⚠️  Could not get Foundry API token — skipping agent configuration."
    echo "     Ensure you are logged in with: az login"
  else
    # Find the project connection to AI Search
    SEARCH_CONNECTION_NAME="${AI_SEARCH_NAME}"
    SEARCH_CONNECTION=$(curl -sf "${FOUNDRY_ENDPOINT}/connections/${SEARCH_CONNECTION_NAME}?api-version=${AGENT_API_VER}" \
      -H "Authorization: Bearer $AGENT_TOKEN" 2>/dev/null)

    SEARCH_CONNECTION_ID=$(echo "$SEARCH_CONNECTION" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)

    if [ -z "$SEARCH_CONNECTION_ID" ]; then
      echo "  ⚠️  Could not find project connection '${SEARCH_CONNECTION_NAME}'."
      echo "     Create it in the Foundry portal: Project → Operate → Admin → Add connection → Azure AI Search"
      echo "     Then re-run this script."
    else
      echo "  Using connection: $SEARCH_CONNECTION_ID"

      # Create agent version with azure_ai_search tool
      AGENT_BODY=$(python3 -c "
import json
body = {
    'definition': {
        'kind': 'prompt',
        'model': '${AGENT_MODEL}',
        'instructions': '${AGENT_INSTRUCTIONS}',
        'tools': [{
            'type': 'azure_ai_search',
            'azure_ai_search': {
                'indexes': [{
                    'project_connection_id': '${SEARCH_CONNECTION_ID}',
                    'index_name': '${IDX}',
                    'query_type': 'simple'
                }]
            }
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

      AGENT_VERSION=$(echo "$AGENT_RESPONSE" | python3 -c "import json,sys; print(json.load(sys.stdin).get('version','?'))" 2>/dev/null)

      if [ "$AGENT_VERSION" != "?" ] && [ -n "$AGENT_VERSION" ]; then
        echo "  ✅ Agent '${AGENT_NAME}' version ${AGENT_VERSION} created"
        echo "     Tool: azure_ai_search → ${IDX}"
        echo "     Model: ${AGENT_MODEL}"
        echo "     Citations: url_citation (links to SharePoint document URLs)"
      else
        echo "  ⚠️  Agent creation may have failed. Response:"
        echo "     $AGENT_RESPONSE" | head -3
        echo "     You can configure the agent manually in the Foundry portal."
      fi
    fi
  fi
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
echo "   Foundry Agent:  ${FOUNDRY_AGENT_NAME:-sharepoint-search-agent} (azure_ai_search tool)"
echo ""
echo " ⚠️  If auto-approve failed for the SPL:"
echo "   Portal → $STORAGE_NAME → Networking → Private endpoint connections → Approve"
echo ""
echo " Data flow:"
echo "   SharePoint → (Graph API via FW) → Function App (VNet) → Blob (PE)"
echo "   Blob → (Shared Private Link) → AI Search Indexer (private exec)"
echo "   Foundry Agent → Azure AI Search tool → grounded answers with SharePoint URL citations"
echo "============================================"
