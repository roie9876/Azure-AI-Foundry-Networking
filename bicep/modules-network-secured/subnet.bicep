@description('Name of the virtual network')
param vnetName string

@description('Name of the subnet')
param subnetName string

@description('Address prefix for the subnet')
param addressPrefix string

@description('Array of subnet delegations')
param delegations array = []

@description('Optional: Route Table resource ID to attach to the subnet')
param routeTableId string = ''

@description('Disable default outbound access for the subnet (private subnet)')
param defaultOutboundAccess bool = true

resource subnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = {
  name: '${vnetName}/${subnetName}'
  properties: {
    addressPrefix: addressPrefix
    delegations: delegations
    defaultOutboundAccess: defaultOutboundAccess
    routeTable: !empty(routeTableId) ? { id: routeTableId } : null
  }
}

output subnetId string = subnet.id
output subnetName string = subnetName
