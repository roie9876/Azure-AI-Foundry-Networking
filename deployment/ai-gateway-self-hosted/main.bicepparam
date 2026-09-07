using './main.bicep'

param location = 'swedencentral'
param resourceGroupName = 'rg-aigw-shgw-demo'
param suffix = 'demo1234'
param publisherName = 'AI Gateway Demo'
param publisherEmail = 'admin@example.com'
param deployGatewayContainer = false