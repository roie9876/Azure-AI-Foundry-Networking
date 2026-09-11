@description('Azure region for all demo resources.')
param location string

@description('Globally unique lowercase suffix used by named resources.')
param suffix string

@description('API Management publisher name.')
param publisherName string

@description('API Management publisher email address.')
param publisherEmail string

param deployGatewayContainer bool
param deployDemoUi bool

@secure()
param gatewayAuthValue string

param uiImage string
param registryServer string
param registryUsername string

@secure()
param registryPassword string

@secure()
param uiApiKey string

@secure()
param easyAuthClientSecret string

@secure()
param easyAuthTokenStoreSecret string

var aiAccountName = 'aif-aigw-shgw-${suffix}'
var aiProjectName = 'proj-aigw-shgw-demo'
var apimName = 'apim-aigw-shgw-${suffix}'
var gatewayName = 'shgw-demo'
var logAnalyticsName = 'law-aigw-shgw-${suffix}'
var applicationInsightsName = 'appi-aigw-shgw-${suffix}'
var containerEnvironmentName = 'cae-aigw-shgw-${suffix}'
var containerAppName = 'ca-shgw-demo'
var registryName = 'acraigwshgw${suffix}'
var modelDeploymentName = 'gpt-4.1-mini'
var cognitiveServicesUserRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'a97b65f3-24c7-4388-baec-2e87135dc908'
)
var logAnalyticsReaderRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '73c42c96-874c-492b-b04d-ab87d138a893'
)

resource aiAccount 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' = {
  name: aiAccountName
  location: location
  kind: 'AIServices'
  sku: {
    name: 'S0'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    allowProjectManagement: true
    customSubDomainName: aiAccountName
    disableLocalAuth: false
    publicNetworkAccess: 'Enabled'
  }
}

resource modelDeployment 'Microsoft.CognitiveServices/accounts/deployments@2025-04-01-preview' = {
  parent: aiAccount
  name: modelDeploymentName
  sku: {
    name: 'GlobalStandard'
    capacity: 10
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: 'gpt-4.1-mini'
      version: '2025-04-14'
    }
  }
}

resource aiProject 'Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview' = {
  parent: aiAccount
  name: aiProjectName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    description: 'Disposable Microsoft Foundry AI Gateway self-hosted gateway demo'
    displayName: 'AI Gateway self-hosted demo'
  }
}

resource apim 'Microsoft.ApiManagement/service@2024-05-01' = {
  name: apimName
  location: location
  sku: {
    name: 'Developer'
    capacity: 1
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publisherEmail: publisherEmail
    publisherName: publisherName
    publicNetworkAccess: 'Enabled'
    #disable-next-line BCP037
    releaseChannel: 'Preview'
    virtualNetworkType: 'None'
  }
}

resource selfHostedGateway 'Microsoft.ApiManagement/service/gateways@2024-05-01' = {
  parent: apim
  name: gatewayName
  properties: {
    description: 'Self-hosted gateway running in Azure Container Apps'
    locationData: {
      name: 'Azure Container Apps - Sweden Central'
      city: 'Stockholm'
      district: 'Sweden Central'
      countryOrRegion: 'Sweden'
    }
  }
}

resource apimModelAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(aiAccount.id, apim.id, cognitiveServicesUserRoleId)
  scope: aiAccount
  properties: {
    principalId: apim.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: cognitiveServicesUserRoleId
  }
}

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsName
  location: location
  properties: {
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
    retentionInDays: 30
    sku: {
      name: 'PerGB2018'
    }
  }
}

resource applicationInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: applicationInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    DisableLocalAuth: false
    IngestionMode: 'LogAnalytics'
    RetentionInDays: 30
    SamplingPercentage: 100
    WorkspaceResourceId: logAnalytics.id
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

resource applicationInsightsConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-06-01' = {
  parent: aiProject
  name: 'appinsights-demo'
  properties: {
    #disable-next-line BCP036
    authType: 'ProjectManagedIdentity'
    category: 'AppInsights'
    isSharedToAll: true
    metadata: {
      ApplicationInsightsConnectionString: applicationInsights.properties.ConnectionString
    }
    target: applicationInsights.id
  }
}

resource projectTraceReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(logAnalytics.id, aiProject.id, logAnalyticsReaderRoleId)
  scope: logAnalytics
  properties: {
    principalId: aiProject.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: logAnalyticsReaderRoleId
  }
}

resource registry 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: registryName
  location: location
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: true
    publicNetworkAccess: 'Enabled'
  }
}

resource containerEnvironment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: containerEnvironmentName
  location: location
  properties: {
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
      {
        name: 'cs-d4'
        workloadProfileType: 'D4'
        minimumCount: 0
        maximumCount: 2
      }
    ]
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalytics.properties.customerId
        sharedKey: logAnalytics.listKeys().primarySharedKey
      }
    }
  }
}

resource gatewayContainer 'Microsoft.App/containerApps@2024-03-01' = if (deployGatewayContainer) {
  name: containerAppName
  location: location
  properties: {
    managedEnvironmentId: containerEnvironment.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        allowInsecure: false
        external: true
        targetPort: deployDemoUi ? 3000 : 8080
        transport: 'auto'
      }
      registries: deployDemoUi ? [
        {
          server: registryServer
          username: registryUsername
          passwordSecretRef: 'registry-password'
        }
      ] : null
      secrets: concat([
        {
          name: 'gateway-auth'
          value: gatewayAuthValue
        }
      ], deployDemoUi ? [
        {
          name: 'ui-api-key'
          value: uiApiKey
        }
        {
          name: 'registry-password'
          value: registryPassword
        }
        {
          name: 'app-insights-connection-string'
          value: applicationInsights.properties.ConnectionString
        }
        {
          name: 'microsoft-provider-authentication-secret'
          value: easyAuthClientSecret
        }
        {
          name: 'blob-storage-token-store-sasurl-secret'
          value: easyAuthTokenStoreSecret
        }
      ] : [])
    }
    template: {
      containers: concat([
        {
          name: 'gateway'
          image: 'mcr.microsoft.com/azure-api-management/gateway:2.12.1'
          env: [
            {
              name: 'config.service.endpoint'
              value: 'https://${apim.name}.configuration.azure-api.net'
            }
            {
              name: 'config.service.auth'
              secretRef: 'gateway-auth'
            }
            {
              name: 'net.server.http.forwarded.proto.enabled'
              value: 'true'
            }
            {
              name: 'telemetry.logs.std'
              value: 'json'
            }
            {
              name: 'telemetry.metrics.cloud'
              value: 'true'
            }
          ]
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
          probes: [
            {
              type: 'Liveness'
              httpGet: {
                path: '/status-0123456789abcdef'
                port: 8080
                scheme: 'HTTP'
              }
              initialDelaySeconds: 30
              periodSeconds: 30
            }
            {
              type: 'Readiness'
              httpGet: {
                path: '/status-0123456789abcdef'
                port: 8080
                scheme: 'HTTP'
              }
              initialDelaySeconds: 10
              periodSeconds: 10
            }
          ]
        }
      ], deployDemoUi ? [
        {
          name: 'demo-ui'
          image: uiImage
          env: [
            {
              name: 'GATEWAY_URL'
              value: 'http://localhost:8080'
            }
            {
              name: 'GATEWAY_HOST'
              value: '${apim.name}.azure-api.net'
            }
            {
              name: 'API_PATH'
              value: aiAccount.name
            }
            {
              name: 'MODEL'
              value: modelDeployment.name
            }
            {
              name: 'API_KEY'
              secretRef: 'ui-api-key'
            }
            {
              name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
              secretRef: 'app-insights-connection-string'
            }
            {
              name: 'OTEL_SERVICE_NAME'
              value: 'ai-gateway-external-app'
            }
            {
              name: 'OTEL_AGENT_ID'
              value: 'ai-gateway-external-agent'
            }
          ]
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
          probes: [
            {
              type: 'Liveness'
              httpGet: {
                path: '/healthz'
                port: 3000
                scheme: 'HTTP'
              }
              initialDelaySeconds: 5
              periodSeconds: 30
            }
            {
              type: 'Readiness'
              httpGet: {
                path: '/healthz'
                port: 3000
                scheme: 'HTTP'
              }
              initialDelaySeconds: 2
              periodSeconds: 10
            }
          ]
        }
      ] : [])
      scale: {
        minReplicas: 1
        maxReplicas: 1
      }
    }
  }
}

output aiAccountName string = aiAccount.name
output aiProjectName string = aiProject.name
output apimName string = apim.name
output gatewayName string = selfHostedGateway.name
output registryName string = registry.name
output containerAppName string = containerAppName
output containerAppFqdn string = gatewayContainer.?properties.configuration.ingress.fqdn ?? ''
output modelDeploymentName string = modelDeployment.name
output applicationInsightsName string = applicationInsights.name