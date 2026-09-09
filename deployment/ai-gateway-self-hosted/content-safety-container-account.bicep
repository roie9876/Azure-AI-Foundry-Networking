@description('Azure region for the container-only Content Safety metering resource.')
param location string = resourceGroup().location

@description('Suffix used by the existing AI Gateway demo resources.')
param suffix string

var contentSafetyContainerAccountName = 'csc-aigw-shgw-${suffix}'

resource contentSafetyContainerAccount 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: contentSafetyContainerAccountName
  location: location
  kind: 'ContentSafety'
  tags: {
    SecurityControl: 'Ignore'
  }
  sku: {
    name: 'S0'
  }
  properties: {
    customSubDomainName: contentSafetyContainerAccountName
    disableLocalAuth: false
    publicNetworkAccess: 'Enabled'
  }
}

output contentSafetyContainerAccountName string = contentSafetyContainerAccount.name
output contentSafetyContainerEndpoint string = contentSafetyContainerAccount.properties.endpoint