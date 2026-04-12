#!/bin/bash
set -euo pipefail

###############################################################################
# Hub-and-Spoke Infrastructure for Private Foundry
# - Hub:   Azure Firewall, Log Analytics, Private DNS Zones
# - Spoke: VNet peered to hub, UDR → FW, Test VM, subnets for Foundry
###############################################################################

SUBSCRIPTION="f81ed7c0-efed-4b77-b948-b85407bdb710"
LOCATION="swedencentral"

# Resource Groups
HUB_RG="private-foundry-hub"
SPOKE_RG="private-foundry-with-fw"

# Hub networking
HUB_VNET_NAME="hub-vnet"
HUB_VNET_PREFIX="10.0.0.0/16"
HUB_FW_SUBNET_PREFIX="10.0.1.0/26"          # AzureFirewallSubnet (min /26)
HUB_FW_MGMT_SUBNET_PREFIX="10.0.2.0/26"     # AzureFirewallManagementSubnet (Basic SKU needs this)

# Spoke networking
SPOKE_VNET_NAME="spoke-foundry-vnet"
SPOKE_VNET_PREFIX="10.100.0.0/16"
SPOKE_VM_SUBNET_NAME="vm-subnet"
SPOKE_VM_SUBNET_PREFIX="10.100.1.0/24"
SPOKE_AGENT_SUBNET_NAME="agent-subnet"
SPOKE_AGENT_SUBNET_PREFIX="10.100.3.0/24"
SPOKE_PE_SUBNET_NAME="pe-subnet"
SPOKE_PE_SUBNET_PREFIX="10.100.4.0/24"
SPOKE_BASTION_SUBNET_PREFIX="10.100.5.0/26"  # AzureBastionSubnet (min /26)

# Firewall
FW_NAME="hub-firewall"
FW_POLICY_NAME="hub-fw-policy"
FW_PIP_NAME="hub-fw-pip"
FW_MGMT_PIP_NAME="hub-fw-mgmt-pip"

# Log Analytics
LAW_NAME="hub-fw-law"

# Test VM
VM_NAME="test-vm"
VM_SIZE="Standard_B2s"
VM_ADMIN_USER="azureadmin"

# Bastion
BASTION_NAME="spoke-bastion"
BASTION_PIP_NAME="spoke-bastion-pip"

# Private DNS Zones (all zones needed for Foundry private deployment)
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
echo " Setting subscription"
echo "============================================"
az account set --subscription "$SUBSCRIPTION"

echo "============================================"
echo " Creating Resource Groups"
echo "============================================"
az group create --name "$HUB_RG" --location "$LOCATION" --output none
az group create --name "$SPOKE_RG" --location "$LOCATION" --output none
echo "  ✅ Resource groups created"

###############################################################################
# HUB: VNet + Subnets
###############################################################################
echo ""
echo "============================================"
echo " [HUB] Creating VNet and Subnets"
echo "============================================"

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

az network vnet subnet create \
  --resource-group "$HUB_RG" \
  --vnet-name "$HUB_VNET_NAME" \
  --name "AzureFirewallManagementSubnet" \
  --address-prefix "$HUB_FW_MGMT_SUBNET_PREFIX" \
  --output none

echo "  ✅ Hub VNet created: $HUB_VNET_PREFIX"

###############################################################################
# HUB: Log Analytics Workspace
###############################################################################
echo ""
echo "============================================"
echo " [HUB] Creating Log Analytics Workspace"
echo "============================================"

az monitor log-analytics workspace create \
  --resource-group "$HUB_RG" \
  --workspace-name "$LAW_NAME" \
  --location "$LOCATION" \
  --retention-time 30 \
  --output none

LAW_ID=$(az monitor log-analytics workspace show \
  --resource-group "$HUB_RG" \
  --workspace-name "$LAW_NAME" \
  --query id -o tsv)

echo "  ✅ Log Analytics Workspace created"

###############################################################################
# HUB: Azure Firewall + Policy
###############################################################################
echo ""
echo "============================================"
echo " [HUB] Creating Firewall Policy"
echo "============================================"

az network firewall policy create \
  --resource-group "$HUB_RG" \
  --name "$FW_POLICY_NAME" \
  --location "$LOCATION" \
  --sku Standard \
  --output none

# Network rule collection: Allow all outbound (for testing)
az network firewall policy rule-collection-group create \
  --resource-group "$HUB_RG" \
  --policy-name "$FW_POLICY_NAME" \
  --name "DefaultNetworkRuleGroup" \
  --priority 200 \
  --output none

az network firewall policy rule-collection-group collection add-filter-collection \
  --resource-group "$HUB_RG" \
  --policy-name "$FW_POLICY_NAME" \
  --rule-collection-group-name "DefaultNetworkRuleGroup" \
  --name "AllowAllOutbound" \
  --collection-priority 100 \
  --action Allow \
  --rule-type NetworkRule \
  --rule-name "AllowAll" \
  --source-addresses "10.100.0.0/16" \
  --destination-addresses "*" \
  --destination-ports "*" \
  --ip-protocols Any \
  --output none

# Application rule collection: Allow web traffic (for testing)
az network firewall policy rule-collection-group create \
  --resource-group "$HUB_RG" \
  --policy-name "$FW_POLICY_NAME" \
  --name "DefaultAppRuleGroup" \
  --priority 300 \
  --output none

az network firewall policy rule-collection-group collection add-filter-collection \
  --resource-group "$HUB_RG" \
  --policy-name "$FW_POLICY_NAME" \
  --rule-collection-group-name "DefaultAppRuleGroup" \
  --name "AllowWeb" \
  --collection-priority 100 \
  --action Allow \
  --rule-type ApplicationRule \
  --rule-name "AllowAllHttp" \
  --source-addresses "10.100.0.0/16" \
  --protocols Https=443 Http=80 \
  --target-fqdns "*" \
  --output none

echo "  ✅ Firewall Policy created with allow-all rules (for testing)"

echo ""
echo "============================================"
echo " [HUB] Creating Azure Firewall (this takes ~5-10 min)"
echo "============================================"

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
  --tier Standard \
  --vnet-name "$HUB_VNET_NAME" \
  --firewall-policy "$FW_POLICY_NAME" \
  --output none

# Attach IP configuration separately (--public-ip in create doesn't always work)
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

echo "  ✅ Azure Firewall created — private IP: $FW_PRIVATE_IP"

###############################################################################
# HUB: Firewall Diagnostic Settings → Log Analytics
###############################################################################
echo ""
echo "============================================"
echo " [HUB] Configuring Firewall Diagnostics"
echo "============================================"

FW_ID=$(az network firewall show \
  --resource-group "$HUB_RG" \
  --name "$FW_NAME" \
  --query id -o tsv)

az monitor diagnostic-settings create \
  --name "fw-to-law" \
  --resource "$FW_ID" \
  --workspace "$LAW_ID" \
  --logs '[
    {"categoryGroup": "allLogs", "enabled": true}
  ]' \
  --metrics '[
    {"category": "AllMetrics", "enabled": true}
  ]' \
  --output none

echo "  ✅ All firewall logs → Log Analytics Workspace"

###############################################################################
# HUB: Private DNS Zones (linked to both hub and spoke VNets)
###############################################################################
echo ""
echo "============================================"
echo " [HUB] Creating Private DNS Zones"
echo "============================================"

HUB_VNET_ID=$(az network vnet show \
  --resource-group "$HUB_RG" \
  --name "$HUB_VNET_NAME" \
  --query id -o tsv)

for zone in "${DNS_ZONES[@]}"; do
  echo "  Creating zone: $zone"
  az network private-dns zone create \
    --resource-group "$HUB_RG" \
    --name "$zone" \
    --output none

  # Link to hub VNet
  LINK_NAME="link-hub-${zone//\./-}"
  az network private-dns link vnet create \
    --resource-group "$HUB_RG" \
    --zone-name "$zone" \
    --name "$LINK_NAME" \
    --virtual-network "$HUB_VNET_ID" \
    --registration-enabled false \
    --output none
done

echo "  ✅ All DNS zones created and linked to hub VNet"

###############################################################################
# SPOKE: VNet + Subnets
###############################################################################
echo ""
echo "============================================"
echo " [SPOKE] Creating VNet and Subnets"
echo "============================================"

az network vnet create \
  --resource-group "$SPOKE_RG" \
  --name "$SPOKE_VNET_NAME" \
  --address-prefix "$SPOKE_VNET_PREFIX" \
  --output none

az network vnet subnet create \
  --resource-group "$SPOKE_RG" \
  --vnet-name "$SPOKE_VNET_NAME" \
  --name "$SPOKE_VM_SUBNET_NAME" \
  --address-prefix "$SPOKE_VM_SUBNET_PREFIX" \
  --output none

az network vnet subnet create \
  --resource-group "$SPOKE_RG" \
  --vnet-name "$SPOKE_VNET_NAME" \
  --name "$SPOKE_AGENT_SUBNET_NAME" \
  --address-prefix "$SPOKE_AGENT_SUBNET_PREFIX" \
  --output none

az network vnet subnet create \
  --resource-group "$SPOKE_RG" \
  --vnet-name "$SPOKE_VNET_NAME" \
  --name "$SPOKE_PE_SUBNET_NAME" \
  --address-prefix "$SPOKE_PE_SUBNET_PREFIX" \
  --output none

az network vnet subnet create \
  --resource-group "$SPOKE_RG" \
  --vnet-name "$SPOKE_VNET_NAME" \
  --name "AzureBastionSubnet" \
  --address-prefix "$SPOKE_BASTION_SUBNET_PREFIX" \
  --output none

echo "  ✅ Spoke VNet created with subnets: vm, agent, pe, bastion"

###############################################################################
# SPOKE: Link DNS Zones to Spoke VNet
###############################################################################
echo ""
echo "============================================"
echo " [SPOKE] Linking DNS Zones to Spoke VNet"
echo "============================================"

SPOKE_VNET_ID=$(az network vnet show \
  --resource-group "$SPOKE_RG" \
  --name "$SPOKE_VNET_NAME" \
  --query id -o tsv)

for zone in "${DNS_ZONES[@]}"; do
  LINK_NAME="link-spoke-${zone//\./-}"
  az network private-dns link vnet create \
    --resource-group "$HUB_RG" \
    --zone-name "$zone" \
    --name "$LINK_NAME" \
    --virtual-network "$SPOKE_VNET_ID" \
    --registration-enabled false \
    --output none
done

echo "  ✅ All DNS zones linked to spoke VNet"

###############################################################################
# SPOKE: UDR → Azure Firewall
###############################################################################
echo ""
echo "============================================"
echo " [SPOKE] Creating UDR (all traffic → Firewall)"
echo "============================================"

az network route-table create \
  --resource-group "$SPOKE_RG" \
  --name "spoke-to-fw-udr" \
  --location "$LOCATION" \
  --disable-bgp-route-propagation true \
  --output none

az network route-table route create \
  --resource-group "$SPOKE_RG" \
  --route-table-name "spoke-to-fw-udr" \
  --name "default-to-fw" \
  --address-prefix "0.0.0.0/0" \
  --next-hop-type VirtualAppliance \
  --next-hop-ip-address "$FW_PRIVATE_IP" \
  --output none

# Associate UDR to vm-subnet
az network vnet subnet update \
  --resource-group "$SPOKE_RG" \
  --vnet-name "$SPOKE_VNET_NAME" \
  --name "$SPOKE_VM_SUBNET_NAME" \
  --route-table "spoke-to-fw-udr" \
  --output none

# Associate UDR to agent-subnet
az network vnet subnet update \
  --resource-group "$SPOKE_RG" \
  --vnet-name "$SPOKE_VNET_NAME" \
  --name "$SPOKE_AGENT_SUBNET_NAME" \
  --route-table "spoke-to-fw-udr" \
  --output none

# Associate UDR to pe-subnet
az network vnet subnet update \
  --resource-group "$SPOKE_RG" \
  --vnet-name "$SPOKE_VNET_NAME" \
  --name "$SPOKE_PE_SUBNET_NAME" \
  --route-table "spoke-to-fw-udr" \
  --output none

echo "  ✅ UDR created: 0.0.0.0/0 → $FW_PRIVATE_IP (applied to vm, agent, pe subnets)"

###############################################################################
# SPOKE ↔ HUB: VNet Peering
###############################################################################
echo ""
echo "============================================"
echo " [PEERING] Hub ↔ Spoke VNet Peering"
echo "============================================"

# Spoke → Hub
az network vnet peering create \
  --resource-group "$SPOKE_RG" \
  --name "spoke-to-hub" \
  --vnet-name "$SPOKE_VNET_NAME" \
  --remote-vnet "$HUB_VNET_ID" \
  --allow-vnet-access true \
  --allow-forwarded-traffic true \
  --allow-gateway-transit false \
  --use-remote-gateways false \
  --output none

# Hub → Spoke
az network vnet peering create \
  --resource-group "$HUB_RG" \
  --name "hub-to-spoke" \
  --vnet-name "$HUB_VNET_NAME" \
  --remote-vnet "$SPOKE_VNET_ID" \
  --allow-vnet-access true \
  --allow-forwarded-traffic true \
  --allow-gateway-transit false \
  --use-remote-gateways false \
  --output none

echo "  ✅ VNet peering established (bidirectional)"

###############################################################################
# SPOKE: Azure Bastion (to access the test VM)
###############################################################################
echo ""
echo "============================================"
echo " [SPOKE] Creating Azure Bastion (~5 min)"
echo "============================================"

az network public-ip create \
  --resource-group "$SPOKE_RG" \
  --name "$BASTION_PIP_NAME" \
  --sku Standard \
  --allocation-method Static \
  --output none

az network bastion create \
  --resource-group "$SPOKE_RG" \
  --name "$BASTION_NAME" \
  --public-ip-address "$BASTION_PIP_NAME" \
  --vnet-name "$SPOKE_VNET_NAME" \
  --location "$LOCATION" \
  --sku Basic \
  --output none

echo "  ✅ Azure Bastion created"

###############################################################################
# SPOKE: Test VM (no public IP)
###############################################################################
echo ""
echo "============================================"
echo " [SPOKE] Creating Test VM"
echo "============================================"

az vm create \
  --resource-group "$SPOKE_RG" \
  --name "$VM_NAME" \
  --image Ubuntu2404 \
  --size "$VM_SIZE" \
  --admin-username "$VM_ADMIN_USER" \
  --generate-ssh-keys \
  --vnet-name "$SPOKE_VNET_NAME" \
  --subnet "$SPOKE_VM_SUBNET_NAME" \
  --public-ip-address "" \
  --nsg "" \
  --output none

echo "  ✅ Test VM created (no public IP, access via Bastion)"

###############################################################################
# Summary
###############################################################################
echo ""
echo "============================================"
echo " ✅ DEPLOYMENT COMPLETE"
echo "============================================"
echo ""
echo " Hub RG:   $HUB_RG"
echo " Spoke RG: $SPOKE_RG"
echo ""
echo " Hub VNet:        $HUB_VNET_PREFIX"
echo " Spoke VNet:      $SPOKE_VNET_PREFIX"
echo " Firewall IP:     $FW_PRIVATE_IP"
echo " Peering:         ✅ bidirectional"
echo " UDR:             0.0.0.0/0 → $FW_PRIVATE_IP"
echo ""
echo " Test VM:         $VM_NAME (access via Bastion)"
echo " Bastion:         $BASTION_NAME"
echo ""
echo " DNS Zones (in $HUB_RG):"
for zone in "${DNS_ZONES[@]}"; do
  echo "   • $zone"
done
echo ""
echo " Subnets ready for Foundry Bicep deployment:"
echo "   • $SPOKE_AGENT_SUBNET_NAME ($SPOKE_AGENT_SUBNET_PREFIX)"
echo "   • $SPOKE_PE_SUBNET_NAME ($SPOKE_PE_SUBNET_PREFIX)"
echo ""
echo " 🔥 Firewall Logs → Log Analytics: $LAW_NAME"
echo ""
echo " To verify VM traffic goes through firewall:"
echo "   1. Connect to $VM_NAME via Bastion"
echo "   2. Run: curl -s ifconfig.me  (should show FW public IP)"
echo "   3. Check FW logs in Log Analytics:"
echo "      AZFWNetworkRule | where SourceIp startswith '10.100.1'"
echo "      AZFWApplicationRule | where SourceIp startswith '10.100.1'"
echo ""
echo " For Foundry Bicep deployment, use:"
echo "   VNet Resource ID: $SPOKE_VNET_ID"
echo "   Agent Subnet:     $SPOKE_AGENT_SUBNET_NAME"
echo "   PE Subnet:        $SPOKE_PE_SUBNET_NAME"
echo "   DNS Zones RG:     $HUB_RG"
echo ""
