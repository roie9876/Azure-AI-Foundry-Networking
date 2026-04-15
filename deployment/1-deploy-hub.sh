#!/bin/bash
set -euo pipefail

###############################################################################
# 1-deploy-hub.sh — Hub Infrastructure for Private Foundry
#
# Creates the hub side of a hub-spoke network:
#   - Resource Group
#   - Hub VNet with AzureFirewallSubnet
#   - Azure Firewall + Policy (with Foundry-specific rules)
#   - Log Analytics Workspace (firewall diagnostics)
#   - Private DNS Zones for all Foundry PaaS services
#
# Prerequisites:
#   - Azure CLI logged in (az login)
#   - Sufficient permissions (Contributor + Network Contributor)
#   - Copy hub.env.example → hub.env and fill in values
#
# Usage:
#   cp hub.env.example hub.env   # edit values
#   ./1-deploy-hub.sh
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/hub.env"

if [ ! -f "$ENV_FILE" ]; then
  echo "❌ Missing hub.env — copy hub.env.example and fill in your values"
  exit 1
fi

echo "Loading config from hub.env ..."
set -a
source "$ENV_FILE"
set +a

# Validate required variables
REQUIRED_VARS=(SUBSCRIPTION_ID LOCATION HUB_RG HUB_VNET_NAME HUB_VNET_PREFIX HUB_FW_SUBNET_PREFIX FW_NAME FW_POLICY_NAME FW_PIP_NAME LAW_NAME)
MISSING=()
for VAR in "${REQUIRED_VARS[@]}"; do
  if [ -z "${!VAR:-}" ] || [[ "${!VAR}" == "<"* ]]; then
    MISSING+=("$VAR")
  fi
done
if [ ${#MISSING[@]} -gt 0 ]; then
  echo "❌ Missing or placeholder values in hub.env:"
  printf '   %s\n' "${MISSING[@]}"
  exit 1
fi

# Private DNS Zones needed for Foundry private deployment
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
echo " Hub Infrastructure Deployment"
echo "============================================"
echo " RG:          $HUB_RG"
echo " VNet:        $HUB_VNET_PREFIX"
echo " Firewall:    $FW_NAME (${FW_SKU:-Standard})"
echo " DNS Zones:   ${#DNS_ZONES[@]} zones"
echo " Location:    $LOCATION"
echo "============================================"
echo ""

az account set --subscription "$SUBSCRIPTION_ID"

###############################################################################
# 1. Resource Group
###############################################################################
echo "──── Creating Resource Group ────"
az group create --name "$HUB_RG" --location "$LOCATION" --output none
echo "  ✅ $HUB_RG"
echo ""

###############################################################################
# 2. Hub VNet + Firewall Subnet
###############################################################################
echo "──── Creating Hub VNet ────"

az network vnet create \
  --resource-group "$HUB_RG" \
  --name "$HUB_VNET_NAME" \
  --address-prefix "$HUB_VNET_PREFIX" \
  --output none

az network vnet subnet create \
  --resource-group "$HUB_RG" \
  --vnet-name "$HUB_VNET_NAME" \
  --name "AzureFirewallSubnet" \
  --address-prefix "$HUB_FW_SUBNET_PREFIX" \
  --output none

echo "  ✅ Hub VNet: $HUB_VNET_PREFIX"
echo ""

###############################################################################
# 3. Log Analytics Workspace
###############################################################################
echo "──── Creating Log Analytics Workspace ────"

az monitor log-analytics workspace create \
  --resource-group "$HUB_RG" \
  --workspace-name "$LAW_NAME" \
  --location "$LOCATION" \
  --retention-time "${LAW_RETENTION_DAYS:-30}" \
  --output none

LAW_ID=$(az monitor log-analytics workspace show \
  --resource-group "$HUB_RG" \
  --workspace-name "$LAW_NAME" \
  --query id -o tsv)

echo "  ✅ Log Analytics: $LAW_NAME"
echo ""

###############################################################################
# 4. Azure Firewall + Policy
###############################################################################
echo "──── Creating Firewall Policy ────"

az network firewall policy create \
  --resource-group "$HUB_RG" \
  --name "$FW_POLICY_NAME" \
  --location "$LOCATION" \
  --sku "${FW_SKU:-Standard}" \
  --output none

# ── Network Rule Group: Allow Azure management + DNS ────────────────────────
az network firewall policy rule-collection-group create \
  --resource-group "$HUB_RG" \
  --policy-name "$FW_POLICY_NAME" \
  --name "FoundryNetworkRules" \
  --priority 200 \
  --output none

# Allow DNS (required for all private endpoint resolution)
az network firewall policy rule-collection-group collection add-filter-collection \
  --resource-group "$HUB_RG" \
  --policy-name "$FW_POLICY_NAME" \
  --rule-collection-group-name "FoundryNetworkRules" \
  --name "AllowDNS" \
  --collection-priority 100 \
  --action Allow \
  --rule-type NetworkRule \
  --rule-name "DNS-UDP" \
  --source-addresses "10.0.0.0/8" \
  --destination-addresses "*" \
  --destination-ports "53" \
  --ip-protocols UDP \
  --output none

# ── Application Rule Group: Allow required FQDNs ───────────────────────────
az network firewall policy rule-collection-group create \
  --resource-group "$HUB_RG" \
  --policy-name "$FW_POLICY_NAME" \
  --name "FoundryAppRules" \
  --priority 300 \
  --output none

# Agent Service infrastructure (minimum for Container Apps to start)
# Ref: https://learn.microsoft.com/en-us/azure/container-apps/use-azure-firewall#application-rules
az network firewall policy rule-collection-group collection add-filter-collection \
  --resource-group "$HUB_RG" \
  --policy-name "$FW_POLICY_NAME" \
  --rule-collection-group-name "FoundryAppRules" \
  --name "AllowAgentServiceInfra" \
  --collection-priority 100 \
  --action Allow \
  --rule-type ApplicationRule \
  --rule-name "AgentService" \
  --source-addresses "10.0.0.0/8" \
  --protocols Https=443 \
  --target-fqdns \
    "mcr.microsoft.com" \
    "*.data.mcr.microsoft.com" \
    "*.login.microsoft.com" \
    "*.identity.azure.net" \
    "login.microsoftonline.com" \
    "*.login.microsoftonline.com" \
  --output none

# Foundry evaluation (required for eval jobs to succeed)
az network firewall policy rule-collection-group collection add-filter-collection \
  --resource-group "$HUB_RG" \
  --policy-name "$FW_POLICY_NAME" \
  --rule-collection-group-name "FoundryAppRules" \
  --name "AllowFoundryEvaluation" \
  --collection-priority 200 \
  --action Allow \
  --rule-type ApplicationRule \
  --rule-name "EvaluationEndpoints" \
  --source-addresses "10.0.0.0/8" \
  --protocols Https=443 \
  --target-fqdns \
    "*.azureml.ms" \
    "*.blob.core.windows.net" \
    "raw.githubusercontent.com" \
  --output none

# Optional: Application Insights (uncomment if you want agent telemetry)
# az network firewall policy rule-collection-group collection add-filter-collection \
#   --resource-group "$HUB_RG" \
#   --policy-name "$FW_POLICY_NAME" \
#   --rule-collection-group-name "FoundryAppRules" \
#   --name "AllowAppInsights" \
#   --collection-priority 300 \
#   --action Allow \
#   --rule-type ApplicationRule \
#   --rule-name "AppInsightsSDK" \
#   --source-addresses "10.0.0.0/8" \
#   --protocols Https=443 \
#   --target-fqdns \
#     "settings.sdk.monitor.azure.com" \
#   --output none

echo "  ✅ Firewall Policy with Foundry rules"

echo ""
echo "──── Creating Azure Firewall (~5-10 min) ────"

az network public-ip create \
  --resource-group "$HUB_RG" \
  --name "$FW_PIP_NAME" \
  --sku Standard \
  --allocation-method Static \
  --output none

az network firewall create \
  --resource-group "$HUB_RG" \
  --name "$FW_NAME" \
  --location "$LOCATION" \
  --sku AZFW_VNet \
  --tier "${FW_SKU:-Standard}" \
  --vnet-name "$HUB_VNET_NAME" \
  --firewall-policy "$FW_POLICY_NAME" \
  --output none

az network firewall ip-config create \
  --resource-group "$HUB_RG" \
  --firewall-name "$FW_NAME" \
  --name "fw-ipconfig" \
  --public-ip-address "$FW_PIP_NAME" \
  --vnet-name "$HUB_VNET_NAME" \
  --output none

FW_PRIVATE_IP=$(az network firewall show \
  --resource-group "$HUB_RG" \
  --name "$FW_NAME" \
  --query "ipConfigurations[0].privateIPAddress" -o tsv)

echo "  ✅ Azure Firewall: $FW_NAME (private IP: $FW_PRIVATE_IP)"

# Enable DNS proxy on firewall (required for spoke DNS forwarding)
az network firewall policy update \
  --resource-group "$HUB_RG" \
  --name "$FW_POLICY_NAME" \
  --dns-proxy true \
  --output none 2>/dev/null || echo "  (DNS proxy may already be enabled)"

echo ""

###############################################################################
# 5. Firewall Diagnostics → Log Analytics
###############################################################################
echo "──── Configuring Firewall Diagnostics ────"

FW_ID=$(az network firewall show \
  --resource-group "$HUB_RG" \
  --name "$FW_NAME" \
  --query id -o tsv)

az monitor diagnostic-settings create \
  --name "fw-to-law" \
  --resource "$FW_ID" \
  --workspace "$LAW_ID" \
  --logs '[{"categoryGroup": "allLogs", "enabled": true}]' \
  --metrics '[{"category": "AllMetrics", "enabled": true}]' \
  --output none

echo "  ✅ All firewall logs → $LAW_NAME"
echo ""

###############################################################################
# 6. Private DNS Zones
###############################################################################
echo "──── Creating Private DNS Zones ────"

HUB_VNET_ID=$(az network vnet show \
  --resource-group "$HUB_RG" \
  --name "$HUB_VNET_NAME" \
  --query id -o tsv)

for zone in "${DNS_ZONES[@]}"; do
  echo "  Creating: $zone"
  az network private-dns zone create \
    --resource-group "$HUB_RG" \
    --name "$zone" \
    --output none 2>/dev/null || true

  LINK_NAME="link-hub-${zone//\./-}"
  az network private-dns link vnet create \
    --resource-group "$HUB_RG" \
    --zone-name "$zone" \
    --name "$LINK_NAME" \
    --virtual-network "$HUB_VNET_ID" \
    --registration-enabled false \
    --output none 2>/dev/null || true
done

echo "  ✅ ${#DNS_ZONES[@]} DNS zones created and linked to hub"
echo ""

###############################################################################
# Summary
###############################################################################
echo ""
echo "============================================"
echo " ✅ HUB DEPLOYMENT COMPLETE"
echo "============================================"
echo ""
echo " Resource Group:   $HUB_RG"
echo " Hub VNet:         $HUB_VNET_PREFIX"
echo " Firewall:         $FW_NAME"
echo " Firewall IP:      $FW_PRIVATE_IP"
echo " Log Analytics:    $LAW_NAME"
echo ""
echo " DNS Zones (in $HUB_RG):"
for zone in "${DNS_ZONES[@]}"; do
  echo "   • $zone"
done
echo ""
echo " Firewall Rules (see README for details):"
echo "   • AllowDNS                — UDP/53 to any"
echo "   • AllowAgentServiceInfra  — MCR + Entra ID + Managed Identity"
echo "   • AllowFoundryEvaluation  — AzureML + Blob + GitHub templates"
echo "   • (Optional: AllowAppInsights — uncomment in script if needed)"
echo ""
echo " 🔥 Firewall logs → Log Analytics: $LAW_NAME"
echo "    Query blocked traffic:"
echo "    AZFWApplicationRule | where Action == 'Deny'"
echo "    AZFWNetworkRule | where Action == 'Deny'"
echo ""
echo " ➡️  Next: Run 2-deploy-spoke.sh"
echo ""
