# Deployment plan – o4
> NOTE: runner needs Owner (or Contributor + User Access Administrator + Security Admin) rights.  
> Make sure latest extensions are installed:  
> `az extension add --upgrade -n front-door monitor`

<!-- ...existing content... -->

## Create / configure Cosmos DB
<!-- ...existing Cosmos create commands... -->

# enable continuous backup for indefinite retention
```bash
az cosmosdb update -g $RG -n ${BASE}-cosmos --backup-policy-type Continuous
```

## Create Storage account (uploads & logs)
```bash
az storage account create -g $RG -n ${BASE}store -l swedencentral --sku Standard_LRS
echo '{"timestamp":"'$(date -u +%FT%TZ)'","task":"StorageCreated","status":"success"}' >> context-o4.jsonl
```

## Create Key Vault (hardened)
```bash
az keyvault create -g $RG -n ${BASE}-kv -l swedencentral \
  --enable-soft-delete true --enable-purge-protection true \
  --enable-rbac-authorization true
```

## Attach Web-App managed identity & wire secrets
```bash
az webapp identity assign -g $RG -n ${BASE}-app
az webapp config appsettings set -g $RG -n ${BASE}-app \
  --settings CosmosConn='@Microsoft.KeyVault(VaultName=${BASE}-kv;SecretName=CosmosConn)'
echo '{"timestamp":"'$(date -u +%FT%TZ)'","task":"IdentityAssigned","status":"success"}' >> context-o4.jsonl
```

## Deploy Azure Front Door + WAF
```bash
az afd profile create -g $RG -n ${BASE}-fd --sku Premium_AzureFrontDoor
az afd endpoint create -g $RG --profile-name ${BASE}-fd -n chat-ep

az afd origin-group create -g $RG --profile-name ${BASE}-fd -n og-app --origin-type app-service
az afd origin create -g $RG --profile-name ${BASE}-fd --origin-group-name og-app \
  -n chat-origin --host-name ${BASE}ai.azurewebsites.net --priority 1 --weight 100

az afd route create -g $RG --profile-name ${BASE}-fd --endpoint-name chat-ep \
  -n https-route --origin-group og-app --supported-protocols Https \
  --patterns "/*" --forwarding-protocol HttpsOnly

az afd waf-policy create -g $RG --profile-name ${BASE}-fd -n chat-waf \
  --sku Premium_AzureFrontDoor --mode Prevention
az afd endpoint update -g $RG --profile-name ${BASE}-fd -n chat-ep --waf-policy chat-waf
echo '{"timestamp":"'$(date -u +%FT%TZ)'","task":"FrontDoorDeployed","status":"success"}' >> context-o4.jsonl
```

## Lock resource group
```bash
az lock create -g $RG -n rg-delete-lock --lock-type CanNotDelete
echo '{"timestamp":"'$(date -u +%FT%TZ)'","task":"RGLock","status":"success"}' >> context-o4.jsonl
```

<!-- ...rest of file unchanged... -->
