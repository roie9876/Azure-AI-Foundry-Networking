#!/bin/bash
set -euo pipefail

###############################################################################
# 3-deploy-sharepoint-sync.sh — SharePoint → Blob → AI Search Sync Pipeline
#
# Deploys on top of an existing hub-spoke + Foundry environment:
#   1. Creates func-subnet with VNet integration delegation
#   2. Creates a Blob container for SharePoint sync in existing storage
#   3. Creates Function App storage (with pre-created file share)
#   4. Private Endpoints + DNS for FA storage
#   5. Deploys Azure Function App (Flex Consumption, Python, identity storage)
#   6. Deploys Key Vault (private) with SPN secrets
#   7. Configures Function App settings (KV refs + Search + OpenAI + ext-filter)
#   8. Grants RBAC: Function App → Storage, Key Vault
#   9. Creates Shared Private Links: AI Search → Storage + AI Services
#  10. Grants RBAC: AI Search → AI Services (for embedding/OCR skills)
#  11. Creates AI Search vector index, data source, skillset, and indexer
#  11b. Patches all indexers to Private execution (incl. Foundry auto-wired ones)
#  12. Adds firewall rules: Graph + SharePoint + Entra ID + App Insights
#  13. Clones sync code, builds Linux/amd64 wheels in Docker, publishes via
#      SCM /api/publish (no Oryx, no shared-key required)
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

# Sync code source — vendored in-repo under deployment/sharepoint-sync-func/.
# See deployment/sharepoint-sync-func/UPSTREAM.md for the pinned upstream SHA
# and update instructions. No runtime git-clone: the deploy is self-contained.
SYNC_SRC_DIR="${SCRIPT_DIR}/sharepoint-sync-func"

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

# Flex Consumption uses delegation Microsoft.App/environments (set by the
# platform via a serviceAssociationLink when the FA is created). When the
# subnet already exists (re-run), don't touch the delegation — it would fail
# with "SubnetMissingRequiredDelegation" if Flex has already attached a SAL.
if az network vnet subnet show \
     --resource-group "$SPOKE_RG" \
     --vnet-name "$SPOKE_VNET_NAME" \
     --name "$FUNC_SUBNET_NAME" -o none 2>/dev/null; then
  echo "  ℹ️  Subnet $FUNC_SUBNET_NAME exists — preserving delegation, updating UDR only"
  az network vnet subnet update \
    --resource-group "$SPOKE_RG" \
    --vnet-name "$SPOKE_VNET_NAME" \
    --name "$FUNC_SUBNET_NAME" \
    --route-table "$UDR_NAME" \
    --output none
else
  # First-time create: use Microsoft.App/environments (Flex delegation)
  az network vnet subnet create \
    --resource-group "$SPOKE_RG" \
    --vnet-name "$SPOKE_VNET_NAME" \
    --name "$FUNC_SUBNET_NAME" \
    --address-prefix "$FUNC_SUBNET_PREFIX" \
    --delegations "Microsoft.App/environments" \
    --output none

  # Apply existing UDR so func traffic routes through firewall
  az network vnet subnet update \
    --resource-group "$SPOKE_RG" \
    --vnet-name "$SPOKE_VNET_NAME" \
    --name "$FUNC_SUBNET_NAME" \
    --route-table "$UDR_NAME" \
    --output none
fi

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
# 3. Create Function App Storage — PRIVATE from the start
#    Critical: storage must be locked down + PEs + DNS + share all ready
#    BEFORE the Function App is created. Otherwise the FA bootstraps
#    against the public endpoint and then can't remount when storage is
#    later locked down (classic "stuck in Application Error" symptom).
###############################################################################
echo "──── Step 3: Creating Function App Storage (private from start) ────"

if az storage account show -n "$FUNC_STORAGE_NAME" -g "$SPOKE_RG" -o none 2>/dev/null; then
  echo "  ℹ️  Storage $FUNC_STORAGE_NAME already exists — reusing"
else
  az storage account create \
    --name "$FUNC_STORAGE_NAME" \
    --resource-group "$SPOKE_RG" \
    --location "$LOCATION" \
    --sku Standard_LRS \
    --kind StorageV2 \
    --allow-blob-public-access false \
    --min-tls-version TLS1_2 \
    --public-network-access Disabled \
    --default-action Deny \
    --bypass AzureServices \
    --output none
fi

# Force-apply private settings even if SA was reused (idempotent).
az storage account update \
  --name "$FUNC_STORAGE_NAME" \
  --resource-group "$SPOKE_RG" \
  --public-network-access Disabled \
  --default-action Deny \
  --bypass AzureServices \
  --output none

FUNC_STORAGE_ID=$(az storage account show \
  --name "$FUNC_STORAGE_NAME" \
  --resource-group "$SPOKE_RG" \
  --query id -o tsv)

# Create the file share via ARM control plane (works even when storage is locked).
az storage share-rm create \
  --storage-account "$FUNC_STORAGE_NAME" \
  --resource-group "$SPOKE_RG" \
  --name "$FUNC_APP_NAME" \
  --quota 1 \
  --output none

echo "  ✅ Function Storage: $FUNC_STORAGE_NAME (private, file share '$FUNC_APP_NAME' ready)"
echo ""

###############################################################################
# 4. Private Endpoints + DNS for Function Storage
#    MUST run before Function App creation so the FA mounts via PE from day 1.
###############################################################################
echo "──── Step 4: Creating Private Endpoints + DNS for Function Storage ────"

# Helper: create PE + DNS zone group (idempotent).
create_fnstor_pe() {
  local GROUP="$1"      # blob|file|queue|table
  local ZONE="privatelink.${GROUP}.core.windows.net"
  local PE_NAME="pe-${FUNC_STORAGE_NAME}-${GROUP}"

  if az network private-endpoint show -g "$SPOKE_RG" -n "$PE_NAME" -o none 2>/dev/null; then
    echo "  ℹ️  PE $PE_NAME exists — reusing"
  else
    az network private-endpoint create \
      --name "$PE_NAME" \
      --resource-group "$SPOKE_RG" \
      --vnet-name "$SPOKE_VNET_NAME" \
      --subnet "$SPOKE_PE_SUBNET_NAME" \
      --private-connection-resource-id "$FUNC_STORAGE_ID" \
      --group-id "$GROUP" \
      --connection-name "${PE_NAME}-conn" \
      --location "$LOCATION" \
      --output none
  fi

  # DNS zone group (upsert).
  az network private-endpoint dns-zone-group create \
    --resource-group "$SPOKE_RG" \
    --endpoint-name "$PE_NAME" \
    --name "default" \
    --private-dns-zone "$(dns_zone_id "$ZONE")" \
    --zone-name "privatelink-${GROUP}-core-windows-net" \
    --output none 2>/dev/null || true
}

create_fnstor_pe blob
create_fnstor_pe file
create_fnstor_pe queue
create_fnstor_pe table
echo "  ✅ Private Endpoints created (blob + file + queue + table)"

# Link private DNS zones to the spoke VNet (required for PE name resolution).
# Zones may be spread across RGs (and possibly a central DNS subscription).
SPOKE_VNET_ID="/subscriptions/$SUBSCRIPTION/resourceGroups/$SPOKE_RG/providers/Microsoft.Network/virtualNetworks/$SPOKE_VNET_NAME"
DNS_LINK_NAME="spoke-sync-link"
for ZONE in privatelink.blob.core.windows.net privatelink.file.core.windows.net \
            privatelink.queue.core.windows.net privatelink.table.core.windows.net \
            privatelink.vaultcore.azure.net privatelink.search.windows.net \
            privatelink.cognitiveservices.azure.com privatelink.openai.azure.com; do
  ZONE_RG=$(dns_zone_rg "$ZONE")
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

# Wait for DNS A-records to propagate (PE ↔ DNS zone group sync).
echo "  Waiting 30s for PE DNS records to propagate..."
sleep 30

# Verify the file-service FQDN resolves to a private IP (via FW or local dig).
FILE_FQDN="${FUNC_STORAGE_NAME}.file.core.windows.net"
for TRY in 1 2 3 4 5 6; do
  RESOLVED_IP=$(dig +short "$FILE_FQDN" 2>/dev/null | tail -1)
  case "$RESOLVED_IP" in
    10.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|192.168.*)
      echo "  ✅ $FILE_FQDN → $RESOLVED_IP (private) — DNS ready"
      break ;;
    *)
      echo "  ⏳ Attempt $TRY/6: $FILE_FQDN not yet resolving to private IP ($RESOLVED_IP), waiting 15s..."
      sleep 15 ;;
  esac
done
echo ""

###############################################################################
# 5. Deploy Azure Function App — FLEX CONSUMPTION + identity-based storage
#    Flex Consumption is required in environments where the MG policy
#    'storageaccount_disablelocalauth_modify' (or similar) disables shared-key
#    auth on storage — because Flex uses identity-based AzureWebJobsStorage.
#    NOTE: Elastic Premium cannot be used here because EP requires a shared-key
#    content-share connection string, which the storage policy forbids.
###############################################################################
echo "──── Step 5: Deploying Function App (Flex Consumption) ────"

FUNC_SUBNET_ID=$(az network vnet subnet show \
  --resource-group "$SPOKE_RG" \
  --vnet-name "$SPOKE_VNET_NAME" \
  --name "$FUNC_SUBNET_NAME" \
  --query id -o tsv)

# Flex Consumption: DO NOT pre-create the plan. `az functionapp plan create`
# does not accept --sku FC1 in current CLI versions. Instead, pass
# --flexconsumption-location on `az functionapp create` and the plan is
# created implicitly. We retrieve the generated plan name from the FA after.

# Deployment storage container (required by Flex) — create in the FA storage account
FUNC_DEPLOY_CONTAINER="app-package-${FUNC_APP_NAME:0:30}"
az storage container create \
  --account-name "$FUNC_STORAGE_NAME" \
  --name "$FUNC_DEPLOY_CONTAINER" \
  --auth-mode login \
  --output none 2>/dev/null || true

FUNC_STORAGE_BLOB_URL="https://${FUNC_STORAGE_NAME}.blob.core.windows.net/${FUNC_DEPLOY_CONTAINER}"

# Create Flex Consumption function app (plan is created implicitly)
if az functionapp show -n "$FUNC_APP_NAME" -g "$SPOKE_RG" -o none 2>/dev/null; then
  echo "  ℹ️  Function App $FUNC_APP_NAME exists — reusing"
else
  CREATE_ATTEMPT=0
  CREATE_MAX=5
  while : ; do
    CREATE_ATTEMPT=$((CREATE_ATTEMPT+1))
    if az functionapp create \
      --name "$FUNC_APP_NAME" \
      --resource-group "$SPOKE_RG" \
      --flexconsumption-location "$LOCATION" \
      --runtime python \
      --runtime-version 3.11 \
      --storage-account "$FUNC_STORAGE_NAME" \
      --assign-identity "[system]" \
      --vnet "$SPOKE_VNET_NAME" \
      --subnet "$FUNC_SUBNET_NAME" \
      --deployment-storage-name "$FUNC_STORAGE_NAME" \
      --deployment-storage-container-name "$FUNC_DEPLOY_CONTAINER" \
      --deployment-storage-auth-type UserAssignedIdentity 2>/tmp/fa-create.err; then
      echo "  ✅ Function App created (attempt $CREATE_ATTEMPT)"
      break
    fi
    ERR_MSG=$(cat /tmp/fa-create.err || true)
    if [ "$CREATE_ATTEMPT" -ge "$CREATE_MAX" ]; then
      echo "  ❌ Function App create failed after $CREATE_MAX attempts:"
      echo "$ERR_MSG"
      exit 1
    fi
    echo "  ⚠️  Attempt $CREATE_ATTEMPT/$CREATE_MAX failed, retrying in 30s..."
    echo "      $(echo "$ERR_MSG" | head -2)"
    sleep 30
  done
fi

# Retrieve the implicitly-created Flex plan name (for reference / later steps)
FUNC_PLAN_NAME=$(az functionapp show -n "$FUNC_APP_NAME" -g "$SPOKE_RG" \
  --query "serverFarmId" -o tsv | awk -F/ '{print $NF}')
PLAN_ID=$(az functionapp show -n "$FUNC_APP_NAME" -g "$SPOKE_RG" \
  --query "serverFarmId" -o tsv)
echo "  ℹ️  Flex plan: $FUNC_PLAN_NAME"

# Enable VNet integration (Flex supports it, but not via --subnet in create)
az functionapp vnet-integration add \
  --name "$FUNC_APP_NAME" \
  --resource-group "$SPOKE_RG" \
  --vnet "$SPOKE_VNET_NAME" \
  --subnet "$FUNC_SUBNET_NAME" \
  --output none 2>/dev/null || true

# Force identity-based AzureWebJobsStorage (required — shared key is disabled)
# and remove any shared-key/Oryx settings that break Flex.
az functionapp config appsettings set \
  --name "$FUNC_APP_NAME" -g "$SPOKE_RG" \
  --settings \
    "AzureWebJobsStorage__accountName=$FUNC_STORAGE_NAME" \
    "AzureWebJobsStorage__credential=managedidentity" \
    "WEBSITE_DNS_SERVER=$FW_PRIVATE_IP" \
    "WEBSITE_VNET_ROUTE_ALL=1" \
  --output none
# Remove anything that would conflict with Flex+identity
az functionapp config appsettings delete \
  --name "$FUNC_APP_NAME" -g "$SPOKE_RG" \
  --setting-names AzureWebJobsStorage WEBSITE_CONTENTAZUREFILECONNECTIONSTRING \
    WEBSITE_CONTENTSHARE WEBSITE_CONTENTOVERVNET \
    SCM_DO_BUILD_DURING_DEPLOYMENT ENABLE_ORYX_BUILD \
  --output none 2>/dev/null || true

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
    "TIMER_SCHEDULE=${TIMER_SCHEDULE:-0 0 * * * *}" \
    "TIMER_SCHEDULE_FULL=${TIMER_SCHEDULE_FULL:-0 0 3 * * *}" \
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
# 11b. Patch all indexers to Private execution environment
#     Foundry knowledge sources auto-wire indexers (ks-*-indexer) that default
#     to shared (public) execution. When storage has public access disabled,
#     those runs fail 403. We flip every indexer in the service to Private.
###############################################################################
echo "──── Step 11b: Ensuring all indexers use Private execution ────"
SEARCH_KEY=$(az search admin-key show --service-name "$AI_SEARCH_NAME" -g "$SPOKE_RG" --query primaryKey -o tsv)
IDX_LIST=$(curl -sS -H "api-key: $SEARCH_KEY" \
  "https://${AI_SEARCH_NAME}.search.windows.net/indexers?api-version=2024-07-01&\$select=name" \
  | python3 -c "import sys,json; print('\n'.join(i['name'] for i in json.load(sys.stdin).get('value',[])))" 2>/dev/null || true)
for IDXR_NAME in $IDX_LIST; do
  [ -z "$IDXR_NAME" ] && continue
  IDXR_JSON=$(curl -sS -H "api-key: $SEARCH_KEY" \
    "https://${AI_SEARCH_NAME}.search.windows.net/indexers/${IDXR_NAME}?api-version=2024-07-01")
  NEW_JSON=$(echo "$IDXR_JSON" | python3 -c "
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
# 12. Firewall Rules: Graph API + SharePoint + Entra ID
###############################################################################
# Required egress FQDNs (same list applies whether using Azure FW or a 3rd-party NVA):
SP_SYNC_FQDNS=(
  "graph.microsoft.com"
  "login.microsoftonline.com"
  "*.sharepoint.com"
  # Application Insights telemetry (required for Function App logs + ingestion)
  "*.applicationinsights.azure.com"
  "*.in.applicationinsights.azure.com"
  "*.livediagnostics.monitor.azure.com"
  "dc.services.visualstudio.com"
  "*.services.visualstudio.com"
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
# 13. Publish Sync Code (Flex Consumption — identity-auth, no Oryx)
#     Flex Consumption rejects Oryx build settings and requires pre-built
#     wheels. We build dependencies in a Linux/amd64 container so the wheels
#     match the FA runtime (critical when deploying from macOS ARM).
#
#     Source is vendored in deployment/sharepoint-sync-func/ — no git-clone
#     at deploy time. See sharepoint-sync-func/UPSTREAM.md for provenance.
###############################################################################
echo "──── Step 13: Publishing Sync Code ────"

if [ ! -f "$SYNC_SRC_DIR/host.json" ]; then
  echo "  ❌ Vendored sync source not found at $SYNC_SRC_DIR"
  echo "     Expected deployment/sharepoint-sync-func/host.json"
  exit 1
fi

FUNC_SRC_DIR="$SYNC_SRC_DIR"
echo "  Source: $FUNC_SRC_DIR (vendored)"

# Remove any Oryx settings that would break Flex deploy
az functionapp config appsettings delete \
  --name "$FUNC_APP_NAME" -g "$SPOKE_RG" \
  --setting-names SCM_DO_BUILD_DURING_DEPLOYMENT ENABLE_ORYX_BUILD \
  --output none 2>/dev/null || true

# Stage a deploy package with pre-built Linux/amd64 wheels
PKG_DIR=$(mktemp -d -t sp-sync-pkg-XXXX)
cp -R "$FUNC_SRC_DIR"/. "$PKG_DIR"/
rm -rf "$PKG_DIR/.venv" "$PKG_DIR/__pycache__" 2>/dev/null || true
find "$PKG_DIR" -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
find "$PKG_DIR" -name "*.pyc" -delete 2>/dev/null || true

if [ -f "$PKG_DIR/requirements.txt" ]; then
  echo "  Building Python wheels in Linux/amd64 container..."
  if ! command -v docker >/dev/null 2>&1; then
    echo "  ❌ Docker is required to build Linux/amd64 wheels on macOS/Windows."
    echo "     Install Docker Desktop or use a Linux build host."
    exit 1
  fi
  docker run --rm --platform linux/amd64 \
    -v "$PKG_DIR":/work -w /work \
    mcr.microsoft.com/azure-functions/python:4-python3.11 \
    bash -lc "pip install --upgrade pip >/dev/null && pip install --target=.python_packages/lib/site-packages -r requirements.txt"
  echo "  ✅ Wheels staged in .python_packages/lib/site-packages"
fi

DEPLOY_ZIP="/tmp/sp-sync-deploy-$$.zip"
(cd "$PKG_DIR" && zip -rq "$DEPLOY_ZIP" . -x "*.pyc" "*/__pycache__/*" ".git/*" ".env" ".venv/*")
echo "  Zip size: $(du -h "$DEPLOY_ZIP" | cut -f1)"

# Deploy via SCM /api/publish — ARM /extensions/publish has a ~30MB limit,
# SCM direct accepts large payloads. RemoteBuild=false because wheels
# are already staged. Deployer=az_cli flags it in deployment history.
SCM_HOST="${FUNC_APP_NAME}.scm.azurewebsites.net"
ARM_TOKEN=$(az account get-access-token --resource https://management.azure.com/ --query accessToken -o tsv)

PUBLISH_OK=0
for ATTEMPT in 1 2 3 4 5; do
  echo "  Publish attempt $ATTEMPT/5 (SCM /api/publish)..."
  HTTP=$(curl -sS -o /tmp/pub-resp.json -w "%{http_code}" \
    --max-time 900 \
    -X POST "https://${SCM_HOST}/api/publish?RemoteBuild=false&Deployer=az_cli" \
    -H "Authorization: Bearer $ARM_TOKEN" \
    -H "Content-Type: application/zip" \
    --data-binary "@${DEPLOY_ZIP}" 2>&1) || HTTP="000"
  if [ "$HTTP" = "200" ] || [ "$HTTP" = "202" ]; then
    echo "  ✅ Accepted (HTTP $HTTP): $(head -c 200 /tmp/pub-resp.json)"
    PUBLISH_OK=1
    break
  fi
  echo "  ⚠️  HTTP $HTTP — $(head -c 300 /tmp/pub-resp.json)"
  [ "$ATTEMPT" -lt 5 ] && sleep 30
done

rm -rf "$PKG_DIR" "$DEPLOY_ZIP" /tmp/pub-resp.json

if [ "$PUBLISH_OK" != "1" ]; then
  echo "  ❌ Function App publish failed after 5 attempts."
  echo "     Check your machine can reach https://${SCM_HOST} (VPN/private DNS)."
  exit 1
fi

echo "  Restarting Function App..."
az functionapp restart -g "$SPOKE_RG" -n "$FUNC_APP_NAME" --output none
echo "  ✅ Sync code deployed (Flex Consumption, pre-built wheels)"
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
      # Pass instructions via env var to avoid shell/Python quoting issues
      # (instructions may contain single quotes like "don't")
      AGENT_BODY=$(AGENT_INSTRUCTIONS_ENV="$AGENT_INSTRUCTIONS" \
        AGENT_MODEL_ENV="$AGENT_MODEL" \
        SEARCH_CONNECTION_ID_ENV="$SEARCH_CONNECTION_ID" \
        INDEX_NAME_ENV="$IDX" \
        python3 -c "
import json, os
body = {
    'definition': {
        'kind': 'prompt',
        'model': os.environ['AGENT_MODEL_ENV'],
        'instructions': os.environ['AGENT_INSTRUCTIONS_ENV'],
        'tools': [{
            'type': 'azure_ai_search',
            'azure_ai_search': {
                'indexes': [{
                    'project_connection_id': os.environ['SEARCH_CONNECTION_ID_ENV'],
                    'index_name': os.environ['INDEX_NAME_ENV'],
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
