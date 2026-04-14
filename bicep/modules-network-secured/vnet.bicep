/*
Virtual Network Module (MODIFIED: UDR + Private Subnet)
-----------------------------------------------------------
This module deploys the core network infrastructure with DENY-ALL security controls:

MODIFICATIONS from Microsoft original:
  1. Creates a Route Table (UDR) that forces 0.0.0.0/0 → firewall
  2. Attaches the UDR to the agent subnet
  3. Sets defaultOutboundAccess: false on both subnets (private subnets)

This is used to test whether Container Apps delegation can be forced through
a firewall, or whether the platform bypasses customer UDR entirely.
*/

@description('Azure region for the deployment')
param location string

@description('The name of the virtual network')
param vnetName string = 'agents-vnet-test'

@description('The name of Agents Subnet')
param agentSubnetName string = 'agent-subnet'

@description('The name of Hub subnet')
param peSubnetName string = 'pe-subnet'

@description('Address space for the VNet')
param vnetAddressPrefix string = ''

@description('Address prefix for the agent subnet')
param agentSubnetPrefix string = ''

@description('Address prefix for the private endpoint subnet')
param peSubnetPrefix string = ''

// ===== NEW: Firewall / UDR parameters =====
@description('Private IP of the Azure Firewall to route all traffic through. Leave empty to skip UDR creation.')
param firewallPrivateIp string = ''

// Defaults
var defaultVnetAddressPrefix = '192.168.0.0/16'
var vnetAddress = empty(vnetAddressPrefix) ? defaultVnetAddressPrefix : vnetAddressPrefix
var agentSubnet = empty(agentSubnetPrefix) ? cidrSubnet(vnetAddress, 24, 0) : agentSubnetPrefix
var peSubnet = empty(peSubnetPrefix) ? cidrSubnet(vnetAddress, 24, 1) : peSubnetPrefix

// ===== NEW: Route Table forcing all traffic to firewall =====
resource routeTable 'Microsoft.Network/routeTables@2024-05-01' = if (!empty(firewallPrivateIp)) {
  name: '${vnetName}-agent-udr'
  location: location
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

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddress
      ]
    }
    subnets: [
      {
        name: agentSubnetName
        properties: {
          addressPrefix: agentSubnet
          // MODIFIED: disable default outbound access (private subnet)
          defaultOutboundAccess: false
          // MODIFIED: attach UDR to force traffic through firewall
          routeTable: !empty(firewallPrivateIp) ? { id: routeTable.id } : null
          delegations: [
            {
              name: 'Microsoft.app/environments'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
        }
      }
      {
        name: peSubnetName
        properties: {
          addressPrefix: peSubnet
          // MODIFIED: disable default outbound access (private subnet)
          defaultOutboundAccess: false
        }
      }
    ]
  }
}

// Output variables
output peSubnetName string = peSubnetName
output agentSubnetName string = agentSubnetName
output agentSubnetId string = '${virtualNetwork.id}/subnets/${agentSubnetName}'
output peSubnetId string = '${virtualNetwork.id}/subnets/${peSubnetName}'
output virtualNetworkName string = virtualNetwork.name
output virtualNetworkId string = virtualNetwork.id
output virtualNetworkResourceGroup string = resourceGroup().name
output virtualNetworkSubscriptionId string = subscription().subscriptionId
