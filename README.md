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

az extension add --name containerapp
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

az containerapp env list -o table
az containerapp env show -n containerapps -g containerapps
az containerapp env dapr-component list -n containerapps -g containerapps -o table
az containerapp env dapr-component show -n containerapps -g containerapps --dapr-component-name statestore

DEPLOY_OUTPUTS=$(az deployment group show --name env-create -g $RESOURCE_GROUP --query properties.outputs)

ACR_USERNAME=$(echo $DEPLOY_OUTPUTS | jq -r .acrUserName.value)
ACR_PASSWORD=$(echo $DEPLOY_OUTPUTS | jq -r .acrPassword.value)
ACR_LOGIN_SERVER=$(echo $DEPLOY_OUTPUTS | jq -r .acrloginServer.value)
ACR_NAME=$(echo $ACR_LOGIN_SERVER | cut -f1,1 -d .)
WORKSPACE_CLIENT_ID=$(echo $DEPLOY_OUTPUTS | jq -r .workspaceId.value)
```

Create new contaimer images (for displaying a custom message with the the app version)
--------------------------------------------------------------------------------------

```sh
pushd ~

git clone https://github.com/clarenceb/quickstarts dapr-quickstarts
cd dapr-quickstarts/hello-kubernetes/node

az acr build --image hello-k8s-node:v1 \
  --registry $ACR_NAME \
  --file Dockerfile .

cd ../python

az acr build --image hello-k8s-python:v1 \
  --registry $ACR_NAME \
  --file Dockerfile .

popd
```

Deploy the service application (HTTP web server)
------------------------------------------------

```sh
# Deploy via Bicep template
az deployment group create \
  --name nodeapp-v1 \
  -g $RESOURCE_GROUP \
  --template-file ./nodeapp-containerapp.bicep \
  --parameters environment_name=$CONTAINERAPPS_ENVIRONMENT \
    custom_message="v1" \
    image_name="$ACR_LOGIN_SERVER/hello-k8s-node:v1" \
    registry_login_server=$ACR_LOGIN_SERVER \
    registry_username=$ACR_USERNAME \
    registry_password=$ACR_PASSWORD

# Or via CLI
az containerapp create \
  --name nodeapp \
  --container-name nodeapp \
  --revisions-mode multiple \
  --resource-group $RESOURCE_GROUP \
  --environment $CONTAINERAPPS_ENVIRONMENT \
  --image $ACR_LOGIN_SERVER/hello-k8s-node:v1 \
  --registry-server $ACR_LOGIN_SERVER \
  --registry-username $ACR_USERNAME \
  --registry-password $ACR_PASSWORD \
  --env-vars MESSAGE=v1 \
  --cpu 0.5 \
  --memory 1.0Gi \
  --target-port 3000 \
  --ingress external \
  --min-replicas 1 \
  --max-replicas 1 \
  --enable-dapr \
  --dapr-app-port 3000 \
  --dapr-app-id nodeapp \
  --dapr-app-protocol http

az containerapp list -o table
az containerapp revision list -n nodeapp -g $RESOURCE_GROUP -o table
```

Deploy the client application (headless client)
-----------------------------------------------

The [Python App](https://github.com/dapr/quickstarts/tree/master/hello-kubernetes/python) will invoke the NodeApp every second via it's Dapr sidecar via the URI: `http://localhost:{DAPR_PORT}/v1.0/invoke/nodeapp/method/neworder`

```sh
NODEAPP_INGRESS_URL="https://$(az containerapp show -n nodeapp -g $RESOURCE_GROUP --query properties.configuration.ingress.fqdn -o tsv)"

# Deploy via Bicep template
az deployment group create \
  --name pythonapp \
  -g $RESOURCE_GROUP \
  --template-file ./pythonapp-containerapp.bicep \
  --parameters environment_name=$CONTAINERAPPS_ENVIRONMENT \
    image_name="$ACR_LOGIN_SERVER/hello-k8s-python:v1" \
    registry_login_server=$ACR_LOGIN_SERVER \
    registry_username=$ACR_USERNAME \
    registry_password=$ACR_PASSWORD

# Or via CLI
az containerapp create \
  --name pythonapp \
  --container-name pythonapp \
  --resource-group $RESOURCE_GROUP \
  --environment $CONTAINERAPPS_ENVIRONMENT \
  --image $ACR_LOGIN_SERVER/hello-k8s-node:v1 \
  --registry-server $ACR_LOGIN_SERVER \
  --registry-username $ACR_USERNAME \
  --registry-password $ACR_PASSWORD \
  --cpu 0.5 \
  --memory 1.0Gi \
  --min-replicas 1 \
  --max-replicas 1 \
  --enable-dapr \
  --dapr-app-id pythonapp \
  --dapr-app-protocol http

# Append paraemter `nodeapp_url` if not using Dapr for service discovery
# nodeapp_url=$NODEAPP_INGRESS_URL/neworder

az containerapp list -o table
az containerapp revision list -n pythonapp -g $RESOURCE_GROUP -o table
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
# Deploy via Bicep template
az deployment group create \
  --name nodeapp-v1 \
  -g $RESOURCE_GROUP \
  --template-file ./nodeapp-containerapp.bicep \
  --parameters environment_name=$CONTAINERAPPS_ENVIRONMENT \
    custom_message="v2" \
    image_name="$ACR_LOGIN_SERVER/hello-k8s-node:v1" \
    registry_login_server=$ACR_LOGIN_SERVER \
    registry_username=$ACR_USERNAME \
    registry_password=$ACR_PASSWORD

# Or via CLI
az containerapp update \
  --name nodeapp \
  --container-name nodeapp \
  --resource-group $RESOURCE_GROUP \
  --image $ACR_LOGIN_SERVER/hello-k8s-node:v1 \
  --replace-env-vars MESSAGE=v2 \
  --min-replicas 1 \
  --max-replicas 1

az containerapp list -o table
az containerapp revision list -n nodeapp -g $RESOURCE_GROUP -o table
```

In the Azure Portal, split traffic 50% to v1 and v2 and send some orders.

```sh
URL=$NODEAPP_INGRESS_URL/neworder k6 run k6-script.js
```

Inspect the logs via CLI or in the Azure Portal to see round-robin between the two revisions.

```sh
watch -n 5 az monitor log-analytics query --workspace $WORKSPACE_CLIENT_ID --analytics-query "\"ContainerAppConsoleLogs_CL | where ContainerAppName_s == 'nodeapp' and (Log_s contains 'persisted' or Log_s contains 'order') | where TimeGenerated >= ago(30m) | project ContainerAppName_s, Log_s, TimeGenerated | order by TimeGenerated desc | take 20\"" --out table

# Or in the Azure Portal, enter this KQL query:
ContainerAppConsoleLogs_CL
| where ContainerAppName_s == 'nodeapp' and (Log_s contains 'persisted' or Log_s contains 'order')
| where TimeGenerated >= ago(30m)
| project ContainerAppName_s, Log_s, TimeGenerated
| order by TimeGenerated desc
| take 20
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
az deployment group delete --name nodeapp-v1 -g $RESOURCE_GROUP
az deployment group delete --name pythonapp -g $RESOURCE_GROUP

az containerapp delete --name nodeapp --resource-group $RESOURCE_GROUP --yes
az containerapp delete --name pythonapp --resource-group $RESOURCE_GROUP --yes
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
* [Container Apps Preview ARM template API specification](https://docs.microsoft.com/en-us/azure/container-apps/azure-resource-manager-api-spec)
* [Container apps Bicep specifications for 2022-01-01-preview apiVersion](https://github.com/Azure/azure-rest-api-specs/tree/main/specification/app/resource-manager/Microsoft.App/preview/2022-01-01-preview)
* [Container apps Bicep specifications for 2022-03-01 apiVersion](https://github.com/Azure/azure-rest-api-specs/tree/main/specification/app/resource-manager/Microsoft.App/stable/2022-03-01)
