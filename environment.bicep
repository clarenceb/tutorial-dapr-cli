@description('Provide a name for the Container Apps Environment')
param environmentName string

@description('Provide a location for the Container Apps resources')
param location string = resourceGroup().location

var suffix = '${take(uniqueString(resourceGroup().id, environmentName), 5)}'
var logAnalyticsWorkspaceName = 'logs-${environmentName}'
var appInsightsName = 'appins-${environmentName}'
var acrName = '${environmentName}${suffix}'
var storageAccountName = '${environmentName}${suffix}'
var storageContainerName = 'orders'

resource acr 'Microsoft.ContainerRegistry/registries@2021-08-01-preview' = {
  name: acrName
  location: location
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: true
  }
}

resource blobstore 'Microsoft.Storage/storageAccounts@2021-06-01' = {
  name: storageAccountName
  location: location
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
}

resource logAnalyticsWorkspace'Microsoft.OperationalInsights/workspaces@2020-03-01-preview' = {
  name: logAnalyticsWorkspaceName
  location: location
  properties: any({
    retentionInDays: 30
    features: {
      searchVersion: 1
    }
    sku: {
      name: 'PerGB2018'
    }
  })
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalyticsWorkspace.id
  }
}

resource environment 'Microsoft.App/managedEnvironments@2022-01-01-preview' = {
  name: environmentName
  location: location
  properties: {
    daprAIInstrumentationKey: reference(appInsights.id, '2020-02-02').InstrumentationKey
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: reference(logAnalyticsWorkspace.id, '2020-03-01-preview').customerId
        sharedKey: listKeys(logAnalyticsWorkspace.id, '2020-03-01-preview').primarySharedKey
      }
    }
  }
  
  resource daprComponent 'daprComponents@2022-01-01-preview' = {
    name: 'statestore'
    properties: {
      componentType: 'state.azure.blobstorage'
      version: 'v1'
      ignoreErrors: false
      initTimeout: '5s'
      secrets: [
        {
          name: 'storageaccountkey'
          value: listKeys(resourceId('Microsoft.Storage/storageAccounts/', storageAccountName), '2021-09-01').keys[0].value
        }
      ]
      metadata: [
        {
          name: 'accountName'
          value: storageAccountName
        }
        {
          name: 'containerName'
          value: storageContainerName
        }
        {
          name: 'accountKey'
          secretRef: 'storageaccountkey'
        }
      ]
      scopes: [
        'nodeapp'
      ]
    }
  }
}

@description('Container Apps Environment ID')
output environmentId string = environment.id

@description('Log Analytics workspace ID')
output workspaceId string = logAnalyticsWorkspace.properties.customerId

@description('Container Registry admin username')
output acrUserName string = acr.listCredentials().username

@description('Container Registry admin password')
output acrPassword string = acr.listCredentials().passwords[0].value

@description('Container Registry login server')
output acrloginServer string = acr.properties.loginServer
