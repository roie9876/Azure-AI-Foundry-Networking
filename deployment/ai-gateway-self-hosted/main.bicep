targetScope = 'subscription'

@description('Azure region for the demo resources.')
param location string = 'swedencentral'

@description('Resource group that contains the disposable demo.')
param resourceGroupName string = 'rg-aigw-shgw-demo'

@description('Globally unique lowercase suffix used by named resources.')
@minLength(4)
@maxLength(8)
param suffix string

@description('API Management publisher name.')
param publisherName string

@description('API Management publisher email address.')
param publisherEmail string

@description('Deploy the gateway container after a gateway token has been generated.')
param deployGatewayContainer bool = false

@description('Expose the end-user UI after Foundry has generated the project subscription.')
param deployDemoUi bool = false

@secure()
@description('Complete APIM gateway authentication value: GatewayKey followed by the generated token.')
param gatewayAuthValue string = ''

@description('Full container image name for the end-user demo UI.')
param uiImage string = ''

@description('Azure Container Registry login server for the UI image.')
param registryServer string = ''

@description('Azure Container Registry username for the UI image.')
param registryUsername string = ''

@secure()
@description('Azure Container Registry password for the UI image.')
param registryPassword string = ''

@secure()
@description('APIM project subscription key used only by the server-side UI container.')
param uiApiKey string = ''

@secure()
@description('Existing Container Apps Easy Auth client secret, preserved during UI redeployment.')
param easyAuthClientSecret string = ''

@secure()
@description('Existing Container Apps Easy Auth Blob token-store SAS URL, preserved during UI redeployment.')
param easyAuthTokenStoreSecret string = ''

resource resourceGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: {
    workload: 'ai-gateway-self-hosted-demo'
    environment: 'demo'
  }
}

module demoResources 'resources.bicep' = {
  name: 'ai-gateway-self-hosted-resources'
  scope: resourceGroup
  params: {
    location: location
    suffix: suffix
    publisherName: publisherName
    publisherEmail: publisherEmail
    deployGatewayContainer: deployGatewayContainer
    deployDemoUi: deployDemoUi
    gatewayAuthValue: gatewayAuthValue
    uiImage: uiImage
    registryServer: registryServer
    registryUsername: registryUsername
    registryPassword: registryPassword
    uiApiKey: uiApiKey
    easyAuthClientSecret: easyAuthClientSecret
    easyAuthTokenStoreSecret: easyAuthTokenStoreSecret
  }
}

output resourceGroupName string = resourceGroup.name
output aiAccountName string = demoResources.outputs.aiAccountName
output aiProjectName string = demoResources.outputs.aiProjectName
output apimName string = demoResources.outputs.apimName
output gatewayName string = demoResources.outputs.gatewayName
output registryName string = demoResources.outputs.registryName
output containerAppName string = demoResources.outputs.containerAppName
output containerAppFqdn string = demoResources.outputs.containerAppFqdn
output modelDeploymentName string = demoResources.outputs.modelDeploymentName