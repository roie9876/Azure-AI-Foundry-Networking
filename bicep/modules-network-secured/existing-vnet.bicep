/*
Existing Virtual Network Module (MODIFIED: UDR + Private Subnet)
-----------------------------------------------------------
This module works with existing virtual networks and adds UDR + private subnet
support to the agent subnet for deny-all testing.

MODIFICATIONS from Microsoft original:
  1. Creates a Route Table (UDR) that forces 0.0.0.0/0 → firewall
  2. Passes routeTableId to subnet.bicep for agent subnet
  3. Sets defaultOutboundAccess: false on both subnets
*/

@description('The name of the existing virtual network')
param vnetName string

@description('Subscription ID of virtual network')
param vnetSubscriptionId string = subscription().subscriptionId

@description('Resource Group name of the existing VNet')
param vnetResourceGroupName string = resourceGroup().name

@description('The name of Agents Subnet')
param agentSubnetName string = 'agent-subnet'

@description('The name of Private Endpoint subnet')
param peSubnetName string = 'pe-subnet'

@description('Address prefix for the agent subnet')
param agentSubnetPrefix string = ''

@description('Address prefix for the private endpoint subnet')
param peSubnetPrefix string = ''

// ===== NEW: Firewall / UDR parameters =====
@description('Private IP of the Azure Firewall to route all traffic through. Leave empty to skip UDR creation.')
param firewallPrivateIp string = ''

// Get the address space
var vnetAddressSpace = existingVNet.properties.addressSpace.addressPrefixes[0]

var agentSubnetSpaces = empty(agentSubnetPrefix) ? cidrSubnet(vnetAddressSpace, 24, 0) : agentSubnetPrefix
var peSubnetSpaces = empty(peSubnetPrefix) ? cidrSubnet(vnetAddressSpace, 24, 1) : peSubnetPrefix

// Reference the existing virtual network
resource existingVNet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: vnetName
  scope: resourceGroup(vnetResourceGroupName)
}

// ===== NEW: Route Table forcing all traffic to firewall =====
resource routeTable 'Microsoft.Network/routeTables@2024-05-01' = if (!empty(firewallPrivateIp)) {
  name: '${vnetName}-agent-udr'
  location: resourceGroup().location
  properties: {
    disableBgpRoutePropagation: false
    routes: [
      {
        name: 'default-to-firewall'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: firewallPrivateIp
        }
      }
    ]
  }
}

// Create the agent subnet with UDR + private subnet
module agentSubnet 'subnet.bicep' = {
  name: 'agent-subnet-${uniqueString(deployment().name, agentSubnetName)}'
  scope: resourceGroup(vnetResourceGroupName)
  params: {
    vnetName: vnetName
    subnetName: agentSubnetName
    addressPrefix: agentSubnetSpaces
    defaultOutboundAccess: false
    routeTableId: !empty(firewallPrivateIp) ? routeTable.id : ''
    delegations: [
      {
        name: 'Microsoft.App/environments'
        properties: {
          serviceName: 'Microsoft.App/environments'
        }
      }
    ]
  }
}

// Create the private endpoint subnet (private, no UDR needed)
module peSubnet 'subnet.bicep' = {
  name: 'pe-subnet-${uniqueString(deployment().name, peSubnetName)}'
  scope: resourceGroup(vnetResourceGroupName)
  params: {
    vnetName: vnetName
    subnetName: peSubnetName
    addressPrefix: peSubnetSpaces
    defaultOutboundAccess: false
    delegations: []
  }
}

// Output variables
output peSubnetName string = peSubnetName
output agentSubnetName string = agentSubnetName
output agentSubnetId string = '${existingVNet.id}/subnets/${agentSubnetName}'
output peSubnetId string = '${existingVNet.id}/subnets/${peSubnetName}'
output virtualNetworkName string = existingVNet.name
output virtualNetworkId string = existingVNet.id
output virtualNetworkResourceGroup string = vnetResourceGroupName
output virtualNetworkSubscriptionId string = vnetSubscriptionId
