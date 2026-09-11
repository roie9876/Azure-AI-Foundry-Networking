@description('Azure region for the Prompt Shields container.')
param location string = resourceGroup().location

@description('Name of the existing Container Apps environment.')
param containerEnvironmentName string

@description('Dedicated workload profile used for the large Content Safety images.')
param workloadProfileName string = 'cs-d4'

@secure()
@description('Content Safety account key used only for connected-container metering.')
param contentSafetyKey string

@description('Content Safety account endpoint used for connected-container metering.')
param contentSafetyBillingEndpoint string

@description('Unique suffix used to force a new revision after metering-key rotation.')
param revisionSuffix string

var promptShieldsAppName = 'ca-prompt-shields'

resource containerEnvironment 'Microsoft.App/managedEnvironments@2024-03-01' existing = {
  name: containerEnvironmentName
}

resource promptShieldsContainer 'Microsoft.App/containerApps@2024-03-01' = {
  name: promptShieldsAppName
  location: location
  properties: {
    managedEnvironmentId: containerEnvironment.id
    workloadProfileName: workloadProfileName
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        allowInsecure: false
        external: false
        targetPort: 5000
        transport: 'http'
      }
      secrets: [
        {
          name: 'content-safety-key'
          value: contentSafetyKey
        }
      ]
    }
    template: {
      revisionSuffix: revisionSuffix
      containers: [
        {
          name: 'prompt-shields'
          image: 'mcr.microsoft.com/azure-cognitive-services/contentsafety/promptshields:latest'
          env: [
            {
              name: 'Eula'
              value: 'accept'
            }
            {
              name: 'Billing'
              value: contentSafetyBillingEndpoint
            }
            {
              name: 'ApiKey'
              secretRef: 'content-safety-key'
            }
            {
              name: 'CUDA_ENABLED'
              value: 'false'
            }
          ]
          resources: {
            cpu: json('4.0')
            memory: '16Gi'
          }
          probes: [
            {
              type: 'Liveness'
              httpGet: {
                path: '/status'
                port: 5000
                scheme: 'HTTP'
              }
              initialDelaySeconds: 60
              periodSeconds: 30
            }
            {
              type: 'Readiness'
              httpGet: {
                path: '/ready'
                port: 5000
                scheme: 'HTTP'
              }
              initialDelaySeconds: 60
              periodSeconds: 15
            }
          ]
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 1
      }
    }
  }
}

output promptShieldsAppName string = promptShieldsContainer.name
output promptShieldsAppFqdn string = promptShieldsContainer.properties.configuration.ingress.fqdn