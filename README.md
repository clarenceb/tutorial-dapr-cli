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

az extension remove -n containerapp
az extension add \
  --source https://workerappscliextension.blob.core.windows.net/azure-cli-extension/containerapp-0.2.4-py2.py3-none-any.whl

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
```

Create new contaimer images (for displaying a custom message showing the app version)
-----------------------------------------------------------------------------------

```sh
pushd ~

git clone https://github.com/clarenceb/quickstarts dapr-quickstarts
cd dapr-quickstarts/hello-kubernetes/node

az acr build --image hello-k8s-node:v4 \
  --registry $ACR_NAME \
  --file Dockerfile .

cd ../python

az acr build --image hello-k8s-python:v4 \
  --registry $ACR_NAME \
  --file Dockerfile .

popd
```

Deploy Dapr Components for the environment
------------------------------------------

```sh
az deployment group create \
  --name dapr-components \
  -g $RESOURCE_GROUP \
  --template-file ./dapr-components.bicep \
  --parameters environment_name=$CONTAINERAPPS_ENVIRONMENT
```

Deploy the service application (HTTP web server)
------------------------------------------------

```sh
az deployment group create \
  --name nodeapp-v1 \
  -g $RESOURCE_GROUP \
  --template-file ./nodeapp-containerapp.bicep \
  --parameters environment_name=$CONTAINERAPPS_ENVIRONMENT \
    custom_message="v1" \
    image_name="$ACR_LOGIN_SERVER/hello-k8s-node:v4" \
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
NODEAPP_INGRESS_URL="https://$(az resource show -g $RESOURCE_GROUP --resource-type='Microsoft.App/containerApps' -n 'nodeapp' | jq -r '.properties.configuration.ingress.fqdn')"

# Alternatively, create via Bicep template
az deployment group create \
  --name pythonapp \
  -g $RESOURCE_GROUP \
  --template-file ./pythonapp-containerapp.bicep \
  --parameters environment_name=$CONTAINERAPPS_ENVIRONMENT \
    image_name="$ACR_LOGIN_SERVER/hello-k8s-python:v4" \
    registry_login_server=$ACR_LOGIN_SERVER \
    registry_username=$ACR_USERNAME \
    registry_password=$ACR_PASSWORD \
    nodeapp_url=$NODEAPP_INGRESS_URL/neworder

az resource show -g $RESOURCE_GROUP --resource-type='Microsoft.App/containerApps' -n 'pythonapp' \
  | jq '. | {name: .name, resourceGroup: .resourceGroup, provisioningState: .properties.provisioningState}'
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

# Or in the Azure Portal, enter this KQL query:
ContainerAppConsoleLogs_CL
| where ContainerAppName_s == 'nodeapp' and (Log_s contains 'persisted' or Log_s contains 'order')
| where TimeGenerated >= ago(30m)
| project ContainerAppName_s, Log_s, TimeGenerated
| order by TimeGenerated desc
| take 20

# Note: There is some latency when streaming logs via the CLI. Use the Azure Portal if you want to query logs with less latency.

URL=$NODEAPP_INGRESS_URL/neworder k6 run k6-script.js
```

Deploy v2 of nodeapp
--------------------

```sh
az deployment group create \
  --name nodeapp-v1 \
  -g $RESOURCE_GROUP \
  --template-file ./nodeapp-containerapp.bicep \
  --parameters environment_name=$CONTAINERAPPS_ENVIRONMENT \
    custom_message="v2" \
    image_name="$ACR_LOGIN_SERVER/hello-k8s-node:v4" \
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
* [DaprComponents_CreateOrUpdate.json example for 2022-01-01-preview apiVersion](https://github.com/Azure/azure-rest-api-specs/blob/main/specification/app/resource-manager/Microsoft.App/preview/2022-01-01-preview/examples/DaprComponents_CreateOrUpdate.json)
