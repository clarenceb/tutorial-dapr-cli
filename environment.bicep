@description('Provide a name for the Container Apps Environment')
param environmentName string

@description('Provide a location for the Container Apps resources')
param location string = resourceGroup().location

var suffix = '${take(uniqueString(resourceGroup().id, environmentName), 5)}'
var logAnalyticsWorkspaceName = 'logs-${environmentName}'
var appInsightsName = 'appins-${environmentName}'
var storageAccountName = '${environmentName}${suffix}'
var acrName = '${environmentName}${suffix}'

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2020-08-01' = {
  name: logAnalyticsWorkspaceName
  location: location
  properties: any({
    retentionInDays: 30
    features: {
      searchVersion: 1
      legacy: 0
      enableLogAccessUsingOnlyResourcePermissions: true
    }
    sku: {
      name: 'PerGB2018'
    }
  })
}

resource appInsights 'Microsoft.Insights/components@2020-02-02-preview' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: { 
    ApplicationId: appInsightsName
    Application_Type: 'web'
    Flow_Type: 'Redfield'
    Request_Source: 'CustomDeployment'
  }
}

resource environment 'Microsoft.App/managedEnvironments@2022-01-01-preview' = {
  name: environmentName
  location: location
  properties: {
    type: 'managed'
    internalLoadBalancerEnabled: false
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalyticsWorkspace.properties.customerId
        sharedKey: logAnalyticsWorkspace.listKeys().primarySharedKey
      }
    }
    containerAppsConfiguration: {
      daprAIInstrumentationKey: appInsights.properties.InstrumentationKey
    }
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

@description('Container Apps Environment ID')
output environmentId string = environment.id

@description('Blob storage account name')
output storageAccountName string = blobstore.name

@description('Blob storage account key')
output storageAccountKey string = blobstore.listKeys().keys[0].value

@description('Log Analytics workspace ID')
output workspaceId string = logAnalyticsWorkspace.properties.customerId

@description('Container Registry admin username')
output acrUserName string = acr.listCredentials().username

@description('Container Registry admin password')
output acrPassword string = acr.listCredentials().passwords[0].value

@description('Container Registry login server')
output acrloginServer string = acr.properties.loginServer
