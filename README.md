Microservices with Dapr using the CLI
=====================================

Setup base resources
--------------------

```sh
RESOURCE_GROUP="containerapps"
LOCATION="canadacentral"
CONTAINERAPPS_ENVIRONMENT="containerapps-env"
LOG_ANALYTICS_WORKSPACE="containerapps-logs"
ACR_NAME=containerappsreg
STORAGE_ACCOUNT_CONTAINER="mycontainer"
STORAGE_ACCOUNT="containerapps$(openssl rand -hex 5)"

az login

az extension add \
  --source https://workerappscliextension.blob.core.windows.net/azure-cli-extension/containerapp-0.2.0-py2.py3-none-any.whl

az provider register --namespace Microsoft.Web

az group create \
  --name $RESOURCE_GROUP \
  --location "$LOCATION"

az monitor log-analytics workspace create \
  --resource-group $RESOURCE_GROUP \
  --workspace-name $LOG_ANALYTICS_WORKSPACE

LOG_ANALYTICS_WORKSPACE_CLIENT_ID=`az monitor log-analytics workspace show --query customerId -g $RESOURCE_GROUP -n $LOG_ANALYTICS_WORKSPACE --out tsv`

LOG_ANALYTICS_WORKSPACE_CLIENT_SECRET=`az monitor log-analytics workspace get-shared-keys --query primarySharedKey -g $RESOURCE_GROUP -n $LOG_ANALYTICS_WORKSPACE --out tsv`

az containerapp env create \
  --name $CONTAINERAPPS_ENVIRONMENT \
  --resource-group $RESOURCE_GROUP \
  --logs-workspace-id $LOG_ANALYTICS_WORKSPACE_CLIENT_ID \
  --logs-workspace-key $LOG_ANALYTICS_WORKSPACE_CLIENT_SECRET \
  --location "$LOCATION"

az storage account create \
  --name $STORAGE_ACCOUNT \
  --resource-group $RESOURCE_GROUP \
  --location "$LOCATION" \
  --sku Standard_RAGRS \
  --kind StorageV2

STORAGE_ACCOUNT_KEY=`az storage account keys list --resource-group $RESOURCE_GROUP --account-name $STORAGE_ACCOUNT --query '[0].value' --out tsv`
echo $STORAGE_ACCOUNT_KEY
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
    value: $STORAGE_ACCOUNT
  - name: accountKey
    value: $STORAGE_ACCOUNT_KEY
  - name: containerName
    value: $STORAGE_ACCOUNT_CONTAINER
EOF
```

Create new node app image (for custom message)
----------------------------------------------

```sh
pushd ~

git clone https://github.com/clarenceb/quickstarts dapr-quickstarts
cd dapr-quickstarts/hello-kubernetes/node

az acr create --resource-group $RESOURCE_GROUP --name $ACR_NAME --sku Basic --admin-enabled true
ACR_USERNAME=$(az acr credential show --resource-group $RESOURCE_GROUP --name $ACR_NAME --query username -o tsv)
ACR_PASSWORD=$(az acr credential show --resource-group $RESOURCE_GROUP --name $ACR_NAME --query passwords[0].value -o tsv)

az acr build --image hello-k8s-node:v2 \
  --registry $ACR_NAME \
  --file Dockerfile .

popd
```

Deploy the service application (HTTP web server)
------------------------------------------------

```sh
az containerapp create \
  --name nodeapp \
  --resource-group $RESOURCE_GROUP \
  --environment $CONTAINERAPPS_ENVIRONMENT \
  --image $ACR_NAME.azurecr.io/hello-k8s-node:v2 \
  --registry-login-server $ACR_NAME.azurecr.io \
  --registry-username $ACR_USERNAME \
  --registry-password $ACR_PASSWORD \
  --environment-variables MESSAGE=v1 \
  --target-port 3000 \
  --ingress 'external' \
  --min-replicas 1 \
  --max-replicas 1 \
  --enable-dapr \
  --dapr-app-port 3500 \
  --dapr-app-id nodeapp \
  --dapr-components ./components.yaml

az containerapp revision list -n nodeapp -g $RESOURCE_GROUP -o table
```

Deploy the client application (headless client)
-----------------------------------------------

```sh
az containerapp create \
  --name pythonapp \
  --resource-group $RESOURCE_GROUP \
  --environment $CONTAINERAPPS_ENVIRONMENT \
  --image dapriosamples/hello-k8s-python:latest \
  --min-replicas 1 \
  --max-replicas 1 \
  --enable-dapr \
  --dapr-app-id pythonapp

az containerapp list -o table

az monitor log-analytics query \
  --workspace $LOG_ANALYTICS_WORKSPACE_CLIENT_ID \
  --analytics-query "ContainerAppConsoleLogs_CL | where ContainerAppName_s == 'nodeapp' and (Log_s contains 'persisted' or Log_s contains 'order') | project ContainerAppName_s, Log_s, TimeGenerated | order by TimeGenerated desc | take 20" \
  --out table
```

Create some orders
------------------

```sh
NODEAPP_INGRESS_URL=$(az containerapp show -n nodeapp -g $RESOURCE_GROUP --query configuration.ingress.fqdn -o tsv)
curl --request POST --data "@sample.json" --header Content-Type:application/json $NODEAPP_INGRESS_URL/neworder

curl $NODEAPP_INGRESS_URL/order

watch -n 5 az monitor log-analytics query --workspace $LOG_ANALYTICS_WORKSPACE_CLIENT_ID --analytics-query "\"ContainerAppConsoleLogs_CL | where ContainerAppName_s == 'nodeapp' and (Log_s contains 'persisted' or Log_s contains 'order') | project ContainerAppName_s, Log_s, TimeGenerated | order by TimeGenerated desc | take 20\"" --out table

i=0
while [[ $i -lt 20 ]]; do
    ordernum=$(openssl rand -hex 3)
    echo "Sending order ($i): $ordernum"
    curl -i --request POST --data "{\"data\": {\"orderId\": \"$ordernum\"}}" --header Content-Type:application/json $NODEAPP_INGRESS_URL/neworder
    let "i+=1"
done
```

Deploy v2 of nodeapp
--------------------

```sh
az containerapp update \
  --name nodeapp \
  --resource-group $RESOURCE_GROUP \
  --image $ACR_NAME.azurecr.io/hello-k8s-node:v2 \
  --registry-login-server $ACR_NAME.azurecr.io \
  --registry-username $ACR_USERNAME \
  --registry-password $ACR_PASSWORD \
  --environment-variables MESSAGE=v2 \
  --target-port 3000 \
  --ingress 'external' \
  --min-replicas 1 \
  --max-replicas 1 \
  --enable-dapr \
  --dapr-app-port 3500 \
  --dapr-app-id nodeapp \
  --dapr-components ./components.yaml
```

In the Azure Portal, split traffic 50% to v1 and v2 and send some orders.
Inspect the logs to see round-robin between the two revisions.

Cleanup
-------

```sh
az group delete \
    --resource-group $RESOURCE_GROUP
```
