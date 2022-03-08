@description('Provide a name for the Container Apps Environment')
param environmentName string

@description('Provide a location for the Container Apps resources')
param location string = resourceGroup().location

var suffix = '${take(uniqueString(resourceGroup().id, environmentName), 5)}'
var storageAccountName = '${environmentName}${suffix}'

resource blobstore 'Microsoft.Storage/storageAccounts@2021-06-01' = {
  name: storageAccountName
  location: location
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
}

resource environment 'Microsoft.App/managedEnvironments@2022-01-01-preview' existing = {
  name: environmentName
}

resource statestore 'Microsoft.App/managedEnvironments/daprComponents@2022-01-01-preview' = {
  name: 'statestore'
  parent: environment
  
  properties: {
    type: 'state.azure.blobstorage'
    version: 'v1'

    secrets: [
      {
        name: 'storage-key'
        value: blobstore.listKeys().keys[0].value
      }
    ]

    metadata: [
        {
            name: 'accountName'
            value: blobstore.name
        }
        {
            name: 'accountKey'
            secretRef: 'storage-key'
        }
        {
            name: 'containerName'
            value: storageAccountName
        }
    ]

    scopes: [
      'nodeapp'
    ]
  }
}

@description('Blob storage account name')
output storageAccountName string = blobstore.name

@description('Blob storage account key')
output storageAccountKey string = blobstore.listKeys().keys[0].value
