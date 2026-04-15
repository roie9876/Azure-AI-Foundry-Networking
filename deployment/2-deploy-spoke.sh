#!/bin/bash
set -euo pipefail

###############################################################################
# 2-deploy-spoke.sh — Spoke Network for Private Foundry
#
# Creates the spoke side peered to the hub:
#   - Resource Group
#   - Spoke VNet with subnets (VM, Agent, PE, Bastion)
#   - VNet Peering (hub ↔ spoke)
#   - DNS Zone links to spoke VNet
#   - UDR: 0.0.0.0/0 → Azure Firewall
#   - Azure Bastion + Test VM (optional)
#
# After this script, deploy Foundry via the Bicep template (Deploy to Azure).
#
# Prerequisites:
#   - Hub deployed (1-deploy-hub.sh)
#   - Copy spoke.env.example → spoke.env and fill in values
#
# Usage:
#   cp spoke.env.example spoke.env   # edit values
#   ./2-deploy-spoke.sh
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/spoke.env"

if [ ! -f "$ENV_FILE" ]; then
  echo "❌ Missing spoke.env — copy spoke.env.example and fill in your values"
  exit 1
fi

echo "Loading config from spoke.env ..."
set -a
source "$ENV_FILE"
set +a

# Validate required variables
REQUIRED_VARS=(SUBSCRIPTION_ID LOCATION HUB_RG HUB_VNET_NAME SPOKE_RG SPOKE_VNET_NAME SPOKE_VNET_PREFIX SPOKE_AGENT_SUBNET_PREFIX SPOKE_PE_SUBNET_PREFIX)
MISSING=()
for VAR in "${REQUIRED_VARS[@]}"; do
  if [ -z "${!VAR:-}" ] || [[ "${!VAR}" == "<"* ]]; then
    MISSING+=("$VAR")
  fi
done
if [ ${#MISSING[@]} -gt 0 ]; then
  echo "❌ Missing or placeholder values in spoke.env:"
  printf '   %s\n' "${MISSING[@]}"
  exit 1
fi

# Private DNS Zones (must match what hub deployed)
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

# Subnet names (fixed naming convention)
SPOKE_VM_SUBNET_NAME="vm-subnet"
SPOKE_AGENT_SUBNET_NAME="agent-subnet"
SPOKE_PE_SUBNET_NAME="pe-subnet"

echo "============================================"
echo " Spoke Network Deployment"
echo "============================================"
echo " Spoke RG:       $SPOKE_RG"
echo " Spoke VNet:     $SPOKE_VNET_PREFIX"
echo " Agent Subnet:   $SPOKE_AGENT_SUBNET_PREFIX"
echo " PE Subnet:      $SPOKE_PE_SUBNET_PREFIX"
echo " Hub:            $HUB_RG / $HUB_VNET_NAME"
echo " Bastion+VM:     ${DEPLOY_BASTION:-true}"
echo "============================================"
echo ""

az account set --subscription "$SUBSCRIPTION_ID"

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
  --name "${FW_NAME:-hub-firewall}" \
  --query "ipConfigurations[0].privateIPAddress" -o tsv)

echo "  Hub VNet: $HUB_VNET_ID"
echo "  FW IP:    $FW_PRIVATE_IP"
echo ""

###############################################################################
# 2. Resource Group
###############################################################################
echo "──── Creating Resource Group ────"
az group create --name "$SPOKE_RG" --location "$LOCATION" --output none
echo "  ✅ $SPOKE_RG"
echo ""

###############################################################################
# 3. Spoke VNet + Subnets
###############################################################################
echo "──── Creating Spoke VNet ────"

az network vnet create \
  --resource-group "$SPOKE_RG" \
  --name "$SPOKE_VNET_NAME" \
  --address-prefix "$SPOKE_VNET_PREFIX" \
  --output none

# VM subnet (for test VM access via Bastion)
if [ -n "${SPOKE_VM_SUBNET_PREFIX:-}" ]; then
  az network vnet subnet create \
    --resource-group "$SPOKE_RG" \
    --vnet-name "$SPOKE_VNET_NAME" \
    --name "$SPOKE_VM_SUBNET_NAME" \
    --address-prefix "$SPOKE_VM_SUBNET_PREFIX" \
    --output none
fi

# Agent subnet (Foundry Agent Service containers run here)
az network vnet subnet create \
  --resource-group "$SPOKE_RG" \
  --vnet-name "$SPOKE_VNET_NAME" \
  --name "$SPOKE_AGENT_SUBNET_NAME" \
  --address-prefix "$SPOKE_AGENT_SUBNET_PREFIX" \
  --output none

# Private endpoint subnet
az network vnet subnet create \
  --resource-group "$SPOKE_RG" \
  --vnet-name "$SPOKE_VNET_NAME" \
  --name "$SPOKE_PE_SUBNET_NAME" \
  --address-prefix "$SPOKE_PE_SUBNET_PREFIX" \
  --output none

# Bastion subnet
if [[ "${DEPLOY_BASTION:-true}" == "true" ]] && [ -n "${SPOKE_BASTION_SUBNET_PREFIX:-}" ]; then
  az network vnet subnet create \
    --resource-group "$SPOKE_RG" \
    --vnet-name "$SPOKE_VNET_NAME" \
    --name "AzureBastionSubnet" \
    --address-prefix "$SPOKE_BASTION_SUBNET_PREFIX" \
    --output none
fi

echo "  ✅ Spoke VNet + subnets created"
echo ""

###############################################################################
# 4. Link DNS Zones to Spoke VNet
###############################################################################
echo "──── Linking DNS Zones to Spoke VNet ────"

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
    --output none 2>/dev/null || true
  echo "  ✔ $zone"
done

echo "  ✅ DNS zones linked"
echo ""

###############################################################################
# 5. UDR: All traffic → Azure Firewall
###############################################################################
echo "──── Creating UDR → Firewall ────"

UDR_NAME="spoke-to-fw-udr"

az network route-table create \
  --resource-group "$SPOKE_RG" \
  --name "$UDR_NAME" \
  --location "$LOCATION" \
  --disable-bgp-route-propagation true \
  --output none

az network route-table route create \
  --resource-group "$SPOKE_RG" \
  --route-table-name "$UDR_NAME" \
  --name "default-to-fw" \
  --address-prefix "0.0.0.0/0" \
  --next-hop-type VirtualAppliance \
  --next-hop-ip-address "$FW_PRIVATE_IP" \
  --output none

# Apply UDR to subnets
for SUBNET in "$SPOKE_AGENT_SUBNET_NAME" "$SPOKE_PE_SUBNET_NAME"; do
  az network vnet subnet update \
    --resource-group "$SPOKE_RG" \
    --vnet-name "$SPOKE_VNET_NAME" \
    --name "$SUBNET" \
    --route-table "$UDR_NAME" \
    --output none
done

if [ -n "${SPOKE_VM_SUBNET_PREFIX:-}" ]; then
  az network vnet subnet update \
    --resource-group "$SPOKE_RG" \
    --vnet-name "$SPOKE_VNET_NAME" \
    --name "$SPOKE_VM_SUBNET_NAME" \
    --route-table "$UDR_NAME" \
    --output none
fi

echo "  ✅ UDR: 0.0.0.0/0 → $FW_PRIVATE_IP"
echo ""

###############################################################################
# 6. VNet Peering (Hub ↔ Spoke)
###############################################################################
echo "──── Creating VNet Peering ────"

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
echo ""

###############################################################################
# 7. Azure Bastion + Test VM (optional)
###############################################################################
if [[ "${DEPLOY_BASTION:-true}" == "true" ]]; then
  echo "──── Creating Azure Bastion (~5 min) ────"

  BASTION_PIP_NAME="${BASTION_NAME:-spoke-bastion}-pip"

  az network public-ip create \
    --resource-group "$SPOKE_RG" \
    --name "$BASTION_PIP_NAME" \
    --sku Standard \
    --allocation-method Static \
    --output none

  az network bastion create \
    --resource-group "$SPOKE_RG" \
    --name "${BASTION_NAME:-spoke-bastion}" \
    --public-ip-address "$BASTION_PIP_NAME" \
    --vnet-name "$SPOKE_VNET_NAME" \
    --location "$LOCATION" \
    --sku Basic \
    --output none

  echo "  ✅ Bastion: ${BASTION_NAME:-spoke-bastion}"
  echo ""

  echo "──── Creating Test VM ────"

  az vm create \
    --resource-group "$SPOKE_RG" \
    --name "${VM_NAME:-test-vm}" \
    --image Ubuntu2404 \
    --size "${VM_SIZE:-Standard_B2s}" \
    --admin-username "${VM_ADMIN_USER:-azureadmin}" \
    --generate-ssh-keys \
    --vnet-name "$SPOKE_VNET_NAME" \
    --subnet "$SPOKE_VM_SUBNET_NAME" \
    --public-ip-address "" \
    --nsg "" \
    --output none

  echo "  ✅ Test VM: ${VM_NAME:-test-vm} (access via Bastion)"
  echo ""
fi

###############################################################################
# Summary
###############################################################################
echo ""
echo "============================================"
echo " ✅ SPOKE DEPLOYMENT COMPLETE"
echo "============================================"
echo ""
echo " Spoke RG:       $SPOKE_RG"
echo " Spoke VNet:     $SPOKE_VNET_PREFIX"
echo " Firewall IP:    $FW_PRIVATE_IP"
echo " UDR:            0.0.0.0/0 → $FW_PRIVATE_IP"
echo ""
echo " Subnets ready for Foundry deployment:"
echo "   • agent-subnet  ($SPOKE_AGENT_SUBNET_PREFIX)"
echo "   • pe-subnet     ($SPOKE_PE_SUBNET_PREFIX)"
echo ""
echo " Spoke VNet ID (needed for Bicep deployment):"
echo "   $SPOKE_VNET_ID"
echo ""
echo " ➡️  Next: Deploy Foundry via Bicep template"
echo "    Option A: Click 'Deploy to Azure' button in README"
echo "    Option B: az deployment group create \\"
echo "      --resource-group $SPOKE_RG \\"
echo "      --template-file ../bicep/main.bicep \\"
echo "      --parameters ../bicep/main.bicepparam \\"
echo "      --parameters existingVnetResourceId=$SPOKE_VNET_ID \\"
echo "                   firewallPrivateIp=$FW_PRIVATE_IP"
echo ""
