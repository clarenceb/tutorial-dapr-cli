APIM import of container app
============================

```sh
SUBSCRIPTION_KEY=8e1446fdb5264720a4c5bfbc53cc995a
APIM_URL=https://colors-apim.azure-api.net/orders

# Direct to Container App Ingress URL
URL=$NODEAPP_INGRESS_URL/neworder k6 run k6-script.js

# With APIM URL and rate limit policy
SUBSCRIPTION_KEY=$SUBSCRIPTION_KEY URL=APIM_URL/neworder k6 run k6-script.js
```
