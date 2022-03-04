@description('Container apps environment name')
param environment_name string

@description('Storage account name')
param storage_account_name string

@description('Storage account key')
param storage_account_key string

@description('Storage contrainer name')
param storage_container_name string

@description('Custom message for the app')
param custom_message string = 'nodeapp'

@description('Container image name (registry/image:tag)')
param image_name string

@description('Private container registry login server')
param registry_login_server string

@description('Private container registry username')
param registry_username string

@description('Private container registry password')
param registry_password string

@description('Provide a location for the Container Apps resources')
param location string = resourceGroup().location

resource nodeapp 'Microsoft.App/containerApps@2022-01-01-preview' = {
  name: 'nodeapp'
  location: location

  properties: {
    managedEnvironmentId: resourceId('Microsoft.App/managedEnvironments', environment_name)

    configuration: {
      ingress: {
        external: true
        targetPort: 3000
        allowInsecure: false
      }

      secrets: [
        {
          name: 'storage-key'
          value: storage_account_key
        }
        {
          name: 'registry-password'
          value: registry_password
        }
      ]

      registries: [
        {
          server: registry_login_server
          username: registry_username
          passwordSecretRef: 'registry-password'
        }
      ]
    }

    template: {
      containers: [
        {
          image: image_name
          name: 'nodeapp'
          env: [
            {
              name: 'MESSAGE'
              value: custom_message
            }
          ]
          resources: {
            cpu: '0.5'
            memory: '1Gi'
          }
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 1
      }
      dapr: {
        enabled: true
        appPort: 3000
        appId: 'nodeapp'
        components: [
          {
            name: 'statestore'
            type: 'state.azure.blobstorage'
            version: 'v1'
            metadata: [
                {
                    name: 'accountName'
                    value: storage_account_name
                }
                {
                    name: 'accountKey'
                    secretRef: 'storage-key'
                }
                {
                    name: 'containerName'
                    value: storage_container_name
                }
            ]
          }
        ]
      }
    }
  }
}


