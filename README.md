Microservices with Dapr using the CLI
=====================================

Prerequisites
-------------

* [Azure Subscription](https://azure.microsoft.com/en-au/free/)
* [Azure CLI](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli)
* [k6](https://k6.io/docs/getting-started/installation/) for generating orders

Setup base resources
--------------------

```sh
RESOURCE_GROUP="containerapps"
LOCATION="canadacentral"
CONTAINERAPPS_ENVIRONMENT="containerapps"

az login

az extension add \
  --source https://workerappscliextension.blob.core.windows.net/azure-cli-extension/containerapp-0.2.3-py2.py3-none-any.whl

az provider register --namespace Microsoft.App
az provider show -n Microsoft.App --query registrationState

az group create \
  --name $RESOURCE_GROUP \
  --location "$LOCATION"

az deployment group create \
  --name env-create \
  -g $RESOURCE_GROUP \
  --template-file ./environment.bicep \
  --parameters environmentName=$CONTAINERAPPS_ENVIRONMENT

DEPLOY_OUTPUTS=$(az deployment group show --name env-create   -g $RESOURCE_GROUP --query properties.outputs)

ACR_USERNAME=$(echo $DEPLOY_OUTPUTS | jq -r .acrUserName.value)
ACR_PASSWORD=$(echo $DEPLOY_OUTPUTS | jq -r .acrPassword.value)
ACR_LOGIN_SERVER=$(echo $DEPLOY_OUTPUTS | jq -r .acrloginServer.value)
ACR_NAME=$(echo $ACR_LOGIN_SERVER | cut -f1,1 -d .)
WORKSPACE_CLIENT_ID=$(echo $DEPLOY_OUTPUTS | jq -r .workspaceId.value)
STORAGE_ACCOUNT_NAME=$(echo $DEPLOY_OUTPUTS | jq -r .storageAccountName.value)
STORAGE_ACCOUNT_KEY=$(echo $DEPLOY_OUTPUTS | jq -r .storageAccountKey.value)
STORAGE_ACCOUNT_CONTAINER="mycontainer"
```

Create new node app image (for displaying a custom message showing the app version)
-----------------------------------------------------------------------------------

```sh
pushd ~

git clone https://github.com/clarenceb/quickstarts dapr-quickstarts
cd dapr-quickstarts/hello-kubernetes/node

az acr build --image hello-k8s-node:v2 \
  --registry $ACR_NAME \
  --file Dockerfile .

cd ../python

az acr build --image hello-k8s-python:v2 \
  --registry $ACR_NAME \
  --file Dockerfile .

popd
```

Configure the state store component for Dapr
--------------------------------------------

```sh
cat << EOF > ./components.yaml
# components.yaml for Azure Blob storage component
- name: statestore
  type: state.azure.blobstorage
  version: v1
  metadata:
  # Note that in a production scenario, account keys and secrets 
  # should be securely stored. For more information, see
  # https://docs.dapr.io/operations/components/component-secrets
  - name: accountName
    value: $STORAGE_ACCOUNT_NAME
  - name: accountKey
    value: $STORAGE_ACCOUNT_KEY
  - name: containerName
    value: $STORAGE_ACCOUNT_CONTAINER
EOF
```

Deploy the service application (HTTP web server)
------------------------------------------------

```sh
# TODO: Wait for Azure CLI update to match container app ARM migration, see: aka.ms/microsoftappmigration
# See: https://github.com/microsoft/azure-container-apps/issues/109
az containerapp create \
  --name nodeapp \
  --resource-group $RESOURCE_GROUP \
  --environment $CONTAINERAPPS_ENVIRONMENT \
  --image $ACR_LOGIN_SERVER/hello-k8s-node:v2 \
  --registry-login-server $ACR_LOGIN_SERVER \
  --registry-username $ACR_USERNAME \
  --registry-password $ACR_PASSWORD \
  --environment-variables MESSAGE=v1 \
  --target-port 3000 \
  --ingress 'external' \
  --min-replicas 1 \
  --max-replicas 1 \
  --enable-dapr \
  --dapr-app-port 3000 \
  --dapr-app-id nodeapp \
  --dapr-components ./components.yaml

az containerapp list -o table
az containerapp revision list -n nodeapp -g $RESOURCE_GROUP -o table

# Alternatively, create via Bicep template
az deployment group create \
  --name nodeapp-v1 \
  -g $RESOURCE_GROUP \
  --template-file ./nodeapp-containerapp.bicep \
  --parameters environment_name=$CONTAINERAPPS_ENVIRONMENT \
    storage_account_name=$STORAGE_ACCOUNT_NAME \
    storage_account_key=$STORAGE_ACCOUNT_KEY \
    storage_container_name=$STORAGE_ACCOUNT_CONTAINER \
    custom_message="v1" \
    image_name="$ACR_LOGIN_SERVER/hello-k8s-node:v2" \
    registry_login_server=$ACR_LOGIN_SERVER \
    registry_username=$ACR_USERNAME \
    registry_password=$ACR_PASSWORD

az resource show -g $RESOURCE_GROUP --resource-type='Microsoft.App/containerApps' -n 'nodeapp' \
  | jq '. | {name: .name, resourceGroup: .resourceGroup, provisioningState: .properties.provisioningState}'
```

Deploy the client application (headless client)
-----------------------------------------------

The [Python App](https://github.com/dapr/quickstarts/tree/master/hello-kubernetes/python) will invoke the NodeApp every second via it's Dapr sidecar via the URI: `http://localhost:{DAPR_PORT}/v1.0/invoke/nodeapp/method/neworder`

```sh
# TODO: Wait for Azure CLI update to match container app ARM migration, see: aka.ms/microsoftappmigration
# See: https://github.com/microsoft/azure-container-apps/issues/109
az containerapp create \
  --name pythonapp \
  --resource-group $RESOURCE_GROUP \
  --environment $CONTAINERAPPS_ENVIRONMENT \
  --image $ACR_LOGIN_SERVER/hello-k8s-python:v2 \
  --registry-login-server $ACR_LOGIN_SERVER \
  --registry-username $ACR_USERNAME \
  --registry-password $ACR_PASSWORD \
  --min-replicas 1 \
  --max-replicas 1 \
  --enable-dapr \
  --dapr-app-id pythonapp

az containerapp list -o table
az containerapp revision list -n pythonapp -g $RESOURCE_GROUP -o table

NODEAPP_INGRESS_URL="https://$(az containerapp show -n nodeapp -g $RESOURCE_GROUP --query configuration.ingress.fqdn -o tsv)"

# Alternatively, create via Bicep template
az deployment group create \
  --name pythonapp \
  -g $RESOURCE_GROUP \
  --template-file ./pythonapp-containerapp.bicep \
  --parameters environment_name=$CONTAINERAPPS_ENVIRONMENT \
    image_name="$ACR_LOGIN_SERVER/hello-k8s-python:v2" \
    registry_login_server=$ACR_LOGIN_SERVER \
    registry_username=$ACR_USERNAME \
    registry_password=$ACR_PASSWORD

az resource show -g $RESOURCE_GROUP --resource-type='Microsoft.App/containerApps' -n 'pythonapp' \
  | jq '. | {name: .name, resourceGroup: .resourceGroup, provisioningState: .properties.provisioningState}'

NODEAPP_INGRESS_URL="https://$(az resource show -g $RESOURCE_GROUP --resource-type='Microsoft.App/containerApps' -n 'nodeapp'   | jq -r '.properties.configuration.ingress.fqdn')"
```

Create some orders
------------------

```sh
curl -i --request POST --data "@sample.json" --header Content-Type:application/json $NODEAPP_INGRESS_URL/neworder

curl -s $NODEAPP_INGRESS_URL/order | jq

az monitor log-analytics query \
  --workspace $WORKSPACE_CLIENT_ID \
  --analytics-query "ContainerAppConsoleLogs_CL | where ContainerAppName_s == 'nodeapp' and (Log_s contains 'persisted' or Log_s contains 'order') | where TimeGenerated >= ago(30m) | project ContainerAppName_s, Log_s, TimeGenerated | order by TimeGenerated desc | take 20" \
  --out table

watch -n 5 az monitor log-analytics query --workspace $WORKSPACE_CLIENT_ID --analytics-query "\"ContainerAppConsoleLogs_CL | where ContainerAppName_s == 'nodeapp' and (Log_s contains 'persisted' or Log_s contains 'order') | where TimeGenerated >= ago(30m) | project ContainerAppName_s, Log_s, TimeGenerated | order by TimeGenerated desc | take 20\"" --out table

# Note: There is some latency when streaming logs via the CLI. Use the Azure Portal if you want to query logs with less latency.

URL=$NODEAPP_INGRESS_URL/neworder k6 run k6-script.js
```

Deploy v2 of nodeapp
--------------------

```sh
# TODO: Wait for Azure CLI update to match container app ARM migration, see: aka.ms/microsoftappmigration
# See: https://github.com/microsoft/azure-container-apps/issues/109
az containerapp update \
  --name nodeapp \
  --resource-group $RESOURCE_GROUP \
  --image $ACR_LOGIN_SERVER/hello-k8s-node:v2 \
  --registry-login-server $ACR_LOGIN_SERVER \
  --registry-username $ACR_USERNAME \
  --registry-password $ACR_PASSWORD \
  --environment-variables MESSAGE=v2 \
  --target-port 3000 \
  --ingress 'external' \
  --min-replicas 1 \
  --max-replicas 1 \
  --enable-dapr \
  --dapr-app-port 3000 \
  --dapr-app-id nodeapp \
  --dapr-components ./components.yaml

az containerapp list -o table
az containerapp revision list -n nodeapp -g $RESOURCE_GROUP -o table

# Alternatively, create via Bicep template
az deployment group create \
  --name nodeapp-v2 \
  -g $RESOURCE_GROUP \
  --template-file ./nodeapp-containerapp.bicep \
  --parameters environment_name=$CONTAINERAPPS_ENVIRONMENT \
    storage_account_name=$STORAGE_ACCOUNT_NAME \
    storage_account_key=$STORAGE_ACCOUNT_KEY \
    storage_container_name=$STORAGE_ACCOUNT_CONTAINER \
    custom_message="v2" \
    image_name="$ACR_LOGIN_SERVER/hello-k8s-node:v2" \
    registry_login_server=$ACR_LOGIN_SERVER \
    registry_username=$ACR_USERNAME \
    registry_password=$ACR_PASSWORD

az resource show -g $RESOURCE_GROUP --resource-type='Microsoft.App/containerApps' -n 'nodeapp' \
  | jq '. | {name: .name, resourceGroup: .resourceGroup, provisioningState: .properties.provisioningState}'
```

In the Azure Portal, split traffic 50% to v1 and v2 and send some orders.

```sh
URL=$NODEAPP_INGRESS_URL/neworder k6 run k6-script.js
```

Inspect the logs to see round-robin between the two revisions.

```sh
watch -n 5 az monitor log-analytics query --workspace $WORKSPACE_CLIENT_ID --analytics-query "\"ContainerAppConsoleLogs_CL | where ContainerAppName_s == 'nodeapp' and (Log_s contains 'persisted' or Log_s contains 'order') | where TimeGenerated >= ago(30m) | project ContainerAppName_s, Log_s, TimeGenerated | order by TimeGenerated desc | take 20\"" --out table
```

Application Insights
--------------------

After creating some orders, check the App Insights resource.

* Application Map
* Performance

Cleanup
-------

Cleanup container apps to restart the demo (retaining enviornment and other resources):

```sh
# TODO: Wait for Azure CLI update to match container app ARM migration, see: aka.ms/microsoftappmigration
# See: https://github.com/microsoft/azure-container-apps/issues/109
az containerapp delete --name pythonapp --resource-group $RESOURCE_GROUP --yes
az containerapp delete --name nodeapp --resource-group $RESOURCE_GROUP --yes

# Alternatively, delete container app resources another way
az resource delete --name nodeapp --resource-group $RESOURCE_GROUP --resource-type='Microsoft.App/containerApps' --latest-include-preview
az resource delete --name pythonapp --resource-group $RESOURCE_GROUP --resource-type='Microsoft.App/containerApps' --latest-include-preview
```

or full cleanup:

```sh
az group delete \
    --resource-group $RESOURCE_GROUP \
    --yes
```

Resources
---------

* [Tutorial: Deploy a Dapr application to Azure Container Apps using the Azure CLI](https://docs.microsoft.com/en-us/azure/container-apps/microservices-dapr)
* [Hello Kubernetes](https://github.com/dapr/quickstarts/tree/v1.4.0/hello-kubernetes) - Dapr quickstart
* [Action Required: Namespace migration from Microsoft.Web to Microsoft.App in March 2022](https://github.com/microsoft/azure-container-apps/issues/109)
* [Container Apps Preview ARM template API specification](https://docs.microsoft.com/en-us/azure/container-apps/azure-resource-manager-api-spec)
