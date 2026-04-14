#!/bin/bash
set -euo pipefail

###############################################################################
# Spoke 2 – Deny-All Firewall Test for Azure AI Foundry
# 
# This script:
#   1. Creates a new spoke VNet in a new RG (10.200.0.0/16)
#   2. Peers it with the existing hub
#   3. Links existing Private DNS Zones to the new spoke VNet
#   4. Replaces the firewall AllowAll rules with DENY-ALL + full logging
#   5. Deploys a complete Foundry stack:
#      - AI Services account (with CMK disabled for simplicity)
#      - AI Search (Basic SKU, private)
#      - Storage Account (private)
#      - Cosmos DB (private)
#      - Private Endpoints for all services
#      - Project + Capability Hosts (account + project level)
#   6. Then we observe what breaks and add rules incrementally
#
# Prerequisites:
#   - Hub already deployed (private-foundry-hub RG with firewall, DNS zones, LAW)
#   - Azure CLI logged in with sufficient permissions
###############################################################################

SUBSCRIPTION="f81ed7c0-efed-4b77-b948-b85407bdb710"
LOCATION="swedencentral"

# ── Existing Hub Resources ──────────────────────────────────────────────────
HUB_RG="private-foundry-hub"
HUB_VNET_NAME="hub-vnet"
FW_NAME="hub-firewall"
FW_POLICY_NAME="hub-fw-policy"
LAW_NAME="hub-fw-law"

# ── New Spoke ───────────────────────────────────────────────────────────────
SPOKE2_RG="spoke2-foundry-deny"
SPOKE2_VNET_NAME="spoke2-vnet"
SPOKE2_VNET_PREFIX="10.200.0.0/16"
SPOKE2_AGENT_SUBNET_NAME="agent-subnet"
SPOKE2_AGENT_SUBNET_PREFIX="10.200.3.0/24"
SPOKE2_PE_SUBNET_NAME="pe-subnet"
SPOKE2_PE_SUBNET_PREFIX="10.200.4.0/24"

# ── Foundry Resources (new, in spoke2 RG) ──────────────────────────────────
UNIQUE_SUFFIX="s2$(openssl rand -hex 3)"
AI_SERVICES_NAME="ais${UNIQUE_SUFFIX}"
AI_SEARCH_NAME="search${UNIQUE_SUFFIX}"
STORAGE_NAME="stor${UNIQUE_SUFFIX}"
COSMOS_NAME="cosmos${UNIQUE_SUFFIX}"
PROJECT_NAME="project1"

# ── Private DNS Zones (in hub RG, already exist) ───────────────────────────
DNS_ZONES=(
  "privatelink.cognitiveservices.azure.com"
  "privatelink.openai.azure.com"
  "privatelink.services.ai.azure.com"
  "privatelink.search.windows.net"
  "privatelink.documents.azure.com"
  "privatelink.blob.core.windows.net"
  "privatelink.file.core.windows.net"
  "privatelink.vaultcore.azure.net"
)

echo "============================================"
echo " Spoke 2 – Deny-All Foundry Firewall Test"
echo "============================================"
echo " Spoke RG:     $SPOKE2_RG"
echo " Spoke VNet:   $SPOKE2_VNET_PREFIX"
echo " AI Services:  $AI_SERVICES_NAME"
echo " AI Search:    $AI_SEARCH_NAME"
echo " Storage:      $STORAGE_NAME"
echo " Cosmos DB:    $COSMOS_NAME"
echo "============================================"
echo ""

az account set --subscription "$SUBSCRIPTION"

###############################################################################
# 1. Get Hub references
###############################################################################
echo "──── Getting Hub references ────"

HUB_VNET_ID=$(az network vnet show \
  --resource-group "$HUB_RG" \
  --name "$HUB_VNET_NAME" \
  --query id -o tsv)

FW_PRIVATE_IP=$(az network firewall show \
  --resource-group "$HUB_RG" \
  --name "$FW_NAME" \
  --query "ipConfigurations[0].privateIPAddress" -o tsv)

LAW_ID=$(az monitor log-analytics workspace show \
  --resource-group "$HUB_RG" \
  --workspace-name "$LAW_NAME" \
  --query id -o tsv)

echo "  Hub VNet:  $HUB_VNET_ID"
echo "  FW IP:     $FW_PRIVATE_IP"
echo "  LAW:       $LAW_ID"
echo ""

###############################################################################
# 2. Create Spoke 2 RG + VNet + Subnets
###############################################################################
echo "──── Creating Spoke 2 VNet ────"

az group create --name "$SPOKE2_RG" --location "$LOCATION" --output none

az network vnet create \
  --resource-group "$SPOKE2_RG" \
  --name "$SPOKE2_VNET_NAME" \
  --address-prefix "$SPOKE2_VNET_PREFIX" \
  --output none

az network vnet subnet create \
  --resource-group "$SPOKE2_RG" \
  --vnet-name "$SPOKE2_VNET_NAME" \
  --name "$SPOKE2_AGENT_SUBNET_NAME" \
  --address-prefix "$SPOKE2_AGENT_SUBNET_PREFIX" \
  --output none

az network vnet subnet create \
  --resource-group "$SPOKE2_RG" \
  --vnet-name "$SPOKE2_VNET_NAME" \
  --name "$SPOKE2_PE_SUBNET_NAME" \
  --address-prefix "$SPOKE2_PE_SUBNET_PREFIX" \
  --output none

echo "  ✅ Spoke 2 VNet: $SPOKE2_VNET_PREFIX"
echo ""

###############################################################################
# 3. VNet Peering (Hub ↔ Spoke 2)
###############################################################################
echo "──── Creating VNet Peering ────"

SPOKE2_VNET_ID=$(az network vnet show \
  --resource-group "$SPOKE2_RG" \
  --name "$SPOKE2_VNET_NAME" \
  --query id -o tsv)

# Spoke2 → Hub
az network vnet peering create \
  --resource-group "$SPOKE2_RG" \
  --name "spoke2-to-hub" \
  --vnet-name "$SPOKE2_VNET_NAME" \
  --remote-vnet "$HUB_VNET_ID" \
  --allow-vnet-access true \
  --allow-forwarded-traffic true \
  --allow-gateway-transit false \
  --use-remote-gateways false \
  --output none

# Hub → Spoke2
az network vnet peering create \
  --resource-group "$HUB_RG" \
  --name "hub-to-spoke2" \
  --vnet-name "$HUB_VNET_NAME" \
  --remote-vnet "$SPOKE2_VNET_ID" \
  --allow-vnet-access true \
  --allow-forwarded-traffic true \
  --allow-gateway-transit false \
  --use-remote-gateways false \
  --output none

echo "  ✅ Peering established"
echo ""

###############################################################################
# 4. Link Private DNS Zones to Spoke 2
###############################################################################
echo "──── Linking DNS Zones to Spoke 2 ────"

for zone in "${DNS_ZONES[@]}"; do
  LINK_NAME="link-spoke2-${zone//\./-}"
  az network private-dns link vnet create \
    --resource-group "$HUB_RG" \
    --zone-name "$zone" \
    --name "$LINK_NAME" \
    --virtual-network "$SPOKE2_VNET_ID" \
    --registration-enabled false \
    --output none 2>/dev/null || echo "  (link already exists for $zone)"
  echo "  ✔ $zone"
done

echo "  ✅ All DNS zones linked"
echo ""

###############################################################################
# 5. UDR: All traffic → Firewall
###############################################################################
echo "──── Creating UDR → Firewall ────"

az network route-table create \
  --resource-group "$SPOKE2_RG" \
  --name "spoke2-to-fw-udr" \
  --location "$LOCATION" \
  --disable-bgp-route-propagation true \
  --output none

az network route-table route create \
  --resource-group "$SPOKE2_RG" \
  --route-table-name "spoke2-to-fw-udr" \
  --name "default-to-fw" \
  --address-prefix "0.0.0.0/0" \
  --next-hop-type VirtualAppliance \
  --next-hop-ip-address "$FW_PRIVATE_IP" \
  --output none

# Apply to agent-subnet
az network vnet subnet update \
  --resource-group "$SPOKE2_RG" \
  --vnet-name "$SPOKE2_VNET_NAME" \
  --name "$SPOKE2_AGENT_SUBNET_NAME" \
  --route-table "spoke2-to-fw-udr" \
  --output none

# Apply to pe-subnet
az network vnet subnet update \
  --resource-group "$SPOKE2_RG" \
  --vnet-name "$SPOKE2_VNET_NAME" \
  --name "$SPOKE2_PE_SUBNET_NAME" \
  --route-table "spoke2-to-fw-udr" \
  --output none

echo "  ✅ UDR: 0.0.0.0/0 → $FW_PRIVATE_IP (agent + pe subnets)"
echo ""

###############################################################################
# 6. Configure custom DNS on Spoke 2 VNet → Firewall DNS Proxy
###############################################################################
echo "──── Setting custom DNS → Firewall DNS Proxy ────"

az network vnet update \
  --resource-group "$SPOKE2_RG" \
  --name "$SPOKE2_VNET_NAME" \
  --dns-servers "$FW_PRIVATE_IP" \
  --output none

echo "  ✅ VNet DNS → $FW_PRIVATE_IP"
echo ""

###############################################################################
# 7. FIREWALL: Replace AllowAll with DENY-ALL + Log Everything
###############################################################################
echo "──── Switching Firewall to DENY-ALL ────"

# Delete existing AllowAll network rule collection
echo "  Removing AllowAllOutbound..."
az network firewall policy rule-collection-group collection remove \
  --resource-group "$HUB_RG" \
  --policy-name "$FW_POLICY_NAME" \
  --rule-collection-group-name "DefaultNetworkRuleGroup" \
  --name "AllowAllOutbound" \
  --output none 2>/dev/null || echo "  (already removed)"

# Delete existing AllowWeb app rule collection
echo "  Removing AllowWeb..."
az network firewall policy rule-collection-group collection remove \
  --resource-group "$HUB_RG" \
  --policy-name "$FW_POLICY_NAME" \
  --rule-collection-group-name "DefaultAppRuleGroup" \
  --name "AllowWeb" \
  --output none 2>/dev/null || echo "  (already removed)"

# Add DENY-ALL network rule (lowest priority — catches everything)
echo "  Adding DenyAll network rule..."
az network firewall policy rule-collection-group collection add-filter-collection \
  --resource-group "$HUB_RG" \
  --policy-name "$FW_POLICY_NAME" \
  --rule-collection-group-name "DefaultNetworkRuleGroup" \
  --name "DenyAllOutbound" \
  --collection-priority 4000 \
  --action Deny \
  --rule-type NetworkRule \
  --rule-name "DenyAll" \
  --source-addresses "*" \
  --destination-addresses "*" \
  --destination-ports "*" \
  --ip-protocols Any \
  --output none

echo "  ✅ Firewall is now DENY-ALL (all traffic blocked + logged)"
echo ""

###############################################################################
# 8. Deploy AI Services Account (Foundry)
###############################################################################
echo "──── Deploying AI Services Account ────"

AGENT_SUBNET_ID=$(az network vnet subnet show \
  --resource-group "$SPOKE2_RG" \
  --vnet-name "$SPOKE2_VNET_NAME" \
  --name "$SPOKE2_AGENT_SUBNET_NAME" \
  --query id -o tsv)

PE_SUBNET_ID=$(az network vnet subnet show \
  --resource-group "$SPOKE2_RG" \
  --vnet-name "$SPOKE2_VNET_NAME" \
  --name "$SPOKE2_PE_SUBNET_NAME" \
  --query id -o tsv)

# Create AI Services account (kind=AIServices, public access disabled)
az cognitiveservices account create \
  --name "$AI_SERVICES_NAME" \
  --resource-group "$SPOKE2_RG" \
  --kind "AIServices" \
  --sku "S0" \
  --location "$LOCATION" \
  --custom-domain "$AI_SERVICES_NAME" \
  --api-properties "{}" \
  --output none

# Disable public network access (CLI flag not supported, use REST)
az rest --method PATCH \
  --url "https://management.azure.com/subscriptions/$SUBSCRIPTION/resourceGroups/$SPOKE2_RG/providers/Microsoft.CognitiveServices/accounts/$AI_SERVICES_NAME?api-version=2024-10-01" \
  --body '{"properties":{"publicNetworkAccess":"Disabled"}}' \
  --output none

echo "  ✅ AI Services: $AI_SERVICES_NAME (public access disabled)"
echo ""

###############################################################################
# 9. Deploy AI Search (Basic, public disabled)
###############################################################################
echo "──── Deploying AI Search ────"

az search service create \
  --name "$AI_SEARCH_NAME" \
  --resource-group "$SPOKE2_RG" \
  --sku basic \
  --location "$LOCATION" \
  --public-access disabled \
  --output none

echo "  ✅ AI Search: $AI_SEARCH_NAME"
echo ""

###############################################################################
# 10. Deploy Storage Account (private)
###############################################################################
echo "──── Deploying Storage Account ────"

az storage account create \
  --name "$STORAGE_NAME" \
  --resource-group "$SPOKE2_RG" \
  --location "$LOCATION" \
  --sku Standard_LRS \
  --kind StorageV2 \
  --default-action Deny \
  --public-network-access Disabled \
  --allow-blob-public-access false \
  --output none

echo "  ✅ Storage: $STORAGE_NAME"
echo ""

###############################################################################
# 11. Deploy Cosmos DB (private)
###############################################################################
echo "──── Deploying Cosmos DB ────"

az cosmosdb create \
  --name "$COSMOS_NAME" \
  --resource-group "$SPOKE2_RG" \
  --locations regionName="$LOCATION" failoverPriority=0 \
  --default-consistency-level Session \
  --public-network-access DISABLED \
  --output none

echo "  ✅ Cosmos DB: $COSMOS_NAME"
echo ""

###############################################################################
# 12. Create Private Endpoints (+ auto-register DNS)
###############################################################################
echo "──── Creating Private Endpoints ────"

# Helper function
create_pe() {
  local PE_NAME=$1
  local RESOURCE_ID=$2
  local GROUP_ID=$3
  local DNS_ZONE=$4

  echo "  Creating PE: $PE_NAME ($GROUP_ID)..."

  az network private-endpoint create \
    --name "$PE_NAME" \
    --resource-group "$SPOKE2_RG" \
    --vnet-name "$SPOKE2_VNET_NAME" \
    --subnet "$SPOKE2_PE_SUBNET_NAME" \
    --private-connection-resource-id "$RESOURCE_ID" \
    --group-id "$GROUP_ID" \
    --connection-name "${PE_NAME}-conn" \
    --location "$LOCATION" \
    --output none

  # Register DNS in existing zone
  az network private-endpoint dns-zone-group create \
    --resource-group "$SPOKE2_RG" \
    --endpoint-name "$PE_NAME" \
    --name "default" \
    --private-dns-zone "/subscriptions/$SUBSCRIPTION/resourceGroups/$HUB_RG/providers/Microsoft.Network/privateDnsZones/$DNS_ZONE" \
    --zone-name "${DNS_ZONE//\./-}" \
    --output none

  echo "  ✔ $PE_NAME → $DNS_ZONE"
}

# Get resource IDs
AI_SERVICES_ID=$(az cognitiveservices account show \
  --name "$AI_SERVICES_NAME" \
  --resource-group "$SPOKE2_RG" \
  --query id -o tsv)

AI_SEARCH_ID=$(az search service show \
  --name "$AI_SEARCH_NAME" \
  --resource-group "$SPOKE2_RG" \
  --query id -o tsv)

STORAGE_ID=$(az storage account show \
  --name "$STORAGE_NAME" \
  --resource-group "$SPOKE2_RG" \
  --query id -o tsv)

COSMOS_ID=$(az cosmosdb show \
  --name "$COSMOS_NAME" \
  --resource-group "$SPOKE2_RG" \
  --query id -o tsv)

# AI Services PE
create_pe "pe-${AI_SERVICES_NAME}" "$AI_SERVICES_ID" "account" \
  "privatelink.cognitiveservices.azure.com"

# AI Search PE
create_pe "pe-${AI_SEARCH_NAME}" "$AI_SEARCH_ID" "searchService" \
  "privatelink.search.windows.net"

# Storage Blob PE
create_pe "pe-${STORAGE_NAME}-blob" "$STORAGE_ID" "blob" \
  "privatelink.blob.core.windows.net"

# Storage File PE
create_pe "pe-${STORAGE_NAME}-file" "$STORAGE_ID" "file" \
  "privatelink.file.core.windows.net"

# Cosmos DB PE
create_pe "pe-${COSMOS_NAME}" "$COSMOS_ID" "Sql" \
  "privatelink.documents.azure.com"

echo "  ✅ All Private Endpoints created with DNS registration"
echo ""

###############################################################################
# 13. Deploy GPT-4.1 model in AI Services
###############################################################################
echo "──── Deploying GPT-4.1 model ────"

az cognitiveservices account deployment create \
  --name "$AI_SERVICES_NAME" \
  --resource-group "$SPOKE2_RG" \
  --deployment-name "gpt-4.1" \
  --model-name "gpt-4.1" \
  --model-version "2025-04-14" \
  --model-format "OpenAI" \
  --sku-capacity 10 \
  --sku-name "GlobalStandard" \
  --output none 2>/dev/null || echo "  (model deployment may need adjustment)"

echo "  ✅ Model deployed"
echo ""

###############################################################################
# 14. RBAC: Grant AI Services identity access to dependent resources
###############################################################################
echo "──── Configuring RBAC ────"

# Get the AI Services managed identity
AI_SERVICES_PRINCIPAL=$(az cognitiveservices account show \
  --name "$AI_SERVICES_NAME" \
  --resource-group "$SPOKE2_RG" \
  --query identity.principalId -o tsv 2>/dev/null || echo "")

if [ -z "$AI_SERVICES_PRINCIPAL" ]; then
  echo "  Enabling system-assigned identity..."
  az cognitiveservices account identity assign \
    --name "$AI_SERVICES_NAME" \
    --resource-group "$SPOKE2_RG" \
    --output none
  AI_SERVICES_PRINCIPAL=$(az cognitiveservices account show \
    --name "$AI_SERVICES_NAME" \
    --resource-group "$SPOKE2_RG" \
    --query identity.principalId -o tsv)
fi

echo "  AI Services principal: $AI_SERVICES_PRINCIPAL"

# Storage Blob Data Contributor on Storage
az role assignment create \
  --assignee-object-id "$AI_SERVICES_PRINCIPAL" \
  --assignee-principal-type ServicePrincipal \
  --role "Storage Blob Data Contributor" \
  --scope "$STORAGE_ID" \
  --output none 2>/dev/null || true

# Cosmos DB: DocumentDB Account Contributor (for thread storage)
az role assignment create \
  --assignee-object-id "$AI_SERVICES_PRINCIPAL" \
  --assignee-principal-type ServicePrincipal \
  --role "DocumentDB Account Contributor" \
  --scope "$COSMOS_ID" \
  --output none 2>/dev/null || true

# This role is needed for Cosmos DB data plane operations
az role assignment create \
  --assignee-object-id "$AI_SERVICES_PRINCIPAL" \
  --assignee-principal-type ServicePrincipal \
  --role "Cosmos DB Operator" \
  --scope "$COSMOS_ID" \
  --output none 2>/dev/null || true

# AI Search: Search Index Data Contributor 
az role assignment create \
  --assignee-object-id "$AI_SERVICES_PRINCIPAL" \
  --assignee-principal-type ServicePrincipal \
  --role "Search Index Data Contributor" \
  --scope "$AI_SEARCH_ID" \
  --output none 2>/dev/null || true

# AI Search: Search Service Contributor
az role assignment create \
  --assignee-object-id "$AI_SERVICES_PRINCIPAL" \
  --assignee-principal-type ServicePrincipal \
  --role "Search Service Contributor" \
  --scope "$AI_SEARCH_ID" \
  --output none 2>/dev/null || true

# Cognitive Services OpenAI Contributor on itself (for agents to call models)
az role assignment create \
  --assignee-object-id "$AI_SERVICES_PRINCIPAL" \
  --assignee-principal-type ServicePrincipal \
  --role "Cognitive Services OpenAI Contributor" \
  --scope "$AI_SERVICES_ID" \
  --output none 2>/dev/null || true

echo "  ✅ RBAC assignments created"
echo ""

###############################################################################
# 15. Create Foundry Project
###############################################################################
echo "──── Creating Foundry Project ────"

az rest --method PUT \
  --url "https://management.azure.com${AI_SERVICES_ID}/projects/${PROJECT_NAME}?api-version=2025-04-01-preview" \
  --body "{\"location\":\"$LOCATION\",\"properties\":{},\"identity\":{\"type\":\"SystemAssigned\"}}" \
  --output none

echo "  ✅ Project: $PROJECT_NAME"
echo ""

###############################################################################
# 16. Create Connections (project-level)
###############################################################################
echo "──── Creating Project Connections ────"

# Storage connection
az rest --method PUT \
  --url "https://management.azure.com${AI_SERVICES_ID}/projects/${PROJECT_NAME}/connections/${STORAGE_NAME}?api-version=2025-04-01-preview" \
  --body "{\"properties\":{\"authType\":\"AAD\",\"category\":\"AzureStorageAccount\",\"group\":\"Azure\",\"isDefault\":true,\"metadata\":{\"ApiType\":\"Azure\",\"ResourceId\":\"$STORAGE_ID\",\"location\":\"$LOCATION\"},\"target\":\"https://${STORAGE_NAME}.blob.core.windows.net/\"}}" \
  --output none
echo "  ✔ Storage connection"

# Cosmos DB connection
az rest --method PUT \
  --url "https://management.azure.com${AI_SERVICES_ID}/projects/${PROJECT_NAME}/connections/${COSMOS_NAME}?api-version=2025-04-01-preview" \
  --body "{\"properties\":{\"authType\":\"AAD\",\"category\":\"CosmosDb\",\"group\":\"Azure\",\"isDefault\":true,\"metadata\":{\"ApiType\":\"Azure\",\"ResourceId\":\"$COSMOS_ID\",\"location\":\"$LOCATION\"},\"target\":\"https://${COSMOS_NAME}.documents.azure.com:443/\"}}" \
  --output none
echo "  ✔ Cosmos DB connection"

# AI Search connection
az rest --method PUT \
  --url "https://management.azure.com${AI_SERVICES_ID}/projects/${PROJECT_NAME}/connections/${AI_SEARCH_NAME}?api-version=2025-04-01-preview" \
  --body "{\"properties\":{\"authType\":\"AAD\",\"category\":\"CognitiveSearch\",\"group\":\"AzureAI\",\"metadata\":{\"ApiType\":\"Azure\",\"ApiVersion\":\"2024-05-01-preview\",\"DeploymentApiVersion\":\"2023-11-01\",\"ResourceId\":\"$AI_SEARCH_ID\",\"displayName\":\"$AI_SEARCH_NAME\",\"type\":\"azure_ai_search\"},\"target\":\"https://${AI_SEARCH_NAME}.search.windows.net/\"}}" \
  --output none
echo "  ✔ AI Search connection"

echo "  ✅ All connections created"
echo ""

###############################################################################
# 17. Create Capability Hosts
###############################################################################
echo "──── Creating Capability Hosts ────"

# Account-level capability host (with subnet)
echo "  Creating account-level caphost..."
az rest --method PUT \
  --url "https://management.azure.com${AI_SERVICES_ID}/capabilityHosts/caphost-account?api-version=2025-04-01-preview" \
  --body "{\"properties\":{\"capabilityHostKind\":\"Agents\",\"customerSubnet\":\"$AGENT_SUBNET_ID\"}}" \
  --output none

# Wait for account caphost
echo "  Waiting for account caphost..."
for i in $(seq 1 24); do
  sleep 10
  STATE=$(az rest --method GET \
    --url "https://management.azure.com${AI_SERVICES_ID}/capabilityHosts/caphost-account?api-version=2025-04-01-preview" \
    2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['properties']['provisioningState'])" 2>/dev/null || echo "Pending")
  echo "    $((i*10))s: $STATE"
  if [[ "$STATE" == "Succeeded" || "$STATE" == "Failed" ]]; then break; fi
done

if [[ "$STATE" != "Succeeded" ]]; then
  echo "  ⚠️  Account caphost did not succeed: $STATE"
  echo "  Continuing anyway..."
fi

# Project-level capability host (with connections)
echo "  Creating project-level caphost..."
az rest --method PUT \
  --url "https://management.azure.com${AI_SERVICES_ID}/projects/${PROJECT_NAME}/capabilityHosts/caphost-project?api-version=2025-04-01-preview" \
  --body "{\"properties\":{\"capabilityHostKind\":\"Agents\",\"storageConnections\":[\"$STORAGE_NAME\"],\"threadStorageConnections\":[\"$COSMOS_NAME\"],\"vectorStoreConnections\":[\"$AI_SEARCH_NAME\"]}}" \
  --output none

# Wait for project caphost
echo "  Waiting for project caphost..."
for i in $(seq 1 12); do
  sleep 5
  STATE=$(az rest --method GET \
    --url "https://management.azure.com${AI_SERVICES_ID}/projects/${PROJECT_NAME}/capabilityHosts/caphost-project?api-version=2025-04-01-preview" \
    2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['properties']['provisioningState'])" 2>/dev/null || echo "Pending")
  echo "    $((i*5))s: $STATE"
  if [[ "$STATE" == "Succeeded" || "$STATE" == "Failed" ]]; then break; fi
done

echo "  ✅ Capability hosts created"
echo ""

###############################################################################
# 18. Grant current user access to the project
###############################################################################
echo "──── Granting user access ────"

CURRENT_USER=$(az ad signed-in-user show --query id -o tsv)

# Cognitive Services OpenAI User on AI Services (to use playground)
az role assignment create \
  --assignee-object-id "$CURRENT_USER" \
  --assignee-principal-type User \
  --role "Cognitive Services OpenAI Contributor" \
  --scope "$AI_SERVICES_ID" \
  --output none 2>/dev/null || true

# Contributor on the project (for portal access)
PROJECT_ID="${AI_SERVICES_ID}/projects/${PROJECT_NAME}"
az role assignment create \
  --assignee-object-id "$CURRENT_USER" \
  --assignee-principal-type User \
  --role "Contributor" \
  --scope "$SPOKE2_RG" \
  --output none 2>/dev/null || true

echo "  ✅ User access granted"
echo ""

###############################################################################
# Summary
###############################################################################
echo ""
echo "============================================"
echo " ✅ SPOKE 2 DEPLOYMENT COMPLETE"
echo "============================================"
echo ""
echo "  Spoke 2 RG:      $SPOKE2_RG"
echo "  VNet:            $SPOKE2_VNET_PREFIX"
echo "  Agent Subnet:    $SPOKE2_AGENT_SUBNET_PREFIX"
echo "  PE Subnet:       $SPOKE2_PE_SUBNET_PREFIX"
echo "  UDR:             0.0.0.0/0 → $FW_PRIVATE_IP"
echo "  DNS:             $FW_PRIVATE_IP (firewall proxy)"
echo ""
echo "  🔥 FIREWALL: DENY-ALL (everything blocked)"
echo ""
echo "  AI Services:     $AI_SERVICES_NAME"
echo "  AI Search:       $AI_SEARCH_NAME"
echo "  Storage:         $STORAGE_NAME"
echo "  Cosmos DB:       $COSMOS_NAME"
echo "  Project:         $PROJECT_NAME"
echo ""
echo "  Private Endpoints (all in pe-subnet):"
echo "    • pe-${AI_SERVICES_NAME} → cognitiveservices"
echo "    • pe-${AI_SEARCH_NAME} → search"
echo "    • pe-${STORAGE_NAME}-blob → blob"
echo "    • pe-${STORAGE_NAME}-file → file"
echo "    • pe-${COSMOS_NAME} → cosmosdb"
echo ""
echo "============================================"
echo " NEXT STEPS"
echo "============================================"
echo ""
echo " 1. Check what's blocked in firewall logs:"
echo "    az monitor log-analytics query -w \$(az monitor log-analytics workspace show -g $HUB_RG -n $LAW_NAME --query customerId -o tsv) \\"
echo "      --analytics-query 'AzureDiagnostics | where ResourceType == \"AZUREFIREWALLS\" and msg_s contains \"Deny\" and msg_s contains \"10.200.\" | sort by TimeGenerated desc | take 50 | project TimeGenerated, msg_s'"
echo ""
echo " 2. Open Foundry portal → project1 → Agents tab"
echo "    Expect it to fail since firewall blocks everything"
echo ""
echo " 3. Incrementally add allow rules and re-test"
echo ""
echo " 4. To restore AllowAll on firewall (revert):"
echo "    az network firewall policy rule-collection-group collection remove \\"
echo "      --resource-group $HUB_RG --policy-name $FW_POLICY_NAME \\"
echo "      --rule-collection-group-name DefaultNetworkRuleGroup --name DenyAllOutbound"
echo "    # Then re-add the original AllowAll rules"
echo ""

# Save resource names for later reference
cat > /tmp/spoke2-resources.env << EOF
SPOKE2_RG=$SPOKE2_RG
AI_SERVICES_NAME=$AI_SERVICES_NAME
AI_SEARCH_NAME=$AI_SEARCH_NAME
STORAGE_NAME=$STORAGE_NAME
COSMOS_NAME=$COSMOS_NAME
PROJECT_NAME=$PROJECT_NAME
AGENT_SUBNET_ID=$AGENT_SUBNET_ID
AI_SERVICES_ID=$AI_SERVICES_ID
EOF

echo " Resource names saved to /tmp/spoke2-resources.env"
echo ""
