# Deployment Plan – o4

> Roll-back testing was removed after it wiped the RG – we rely on idempotent re-runs instead.

All actions log to `context-o4.jsonl`.  
Tools: Azure CLI ≥ 2.55, PowerShell ≥ 7.4, VS Code with Azure extensions.  
# Install/upgrade required Azure extensions
az extension add --upgrade -n front-door monitor

## 1 Create resource group
```bash
BASE=pippaioflondoncdx2
RG=$BASE
az group create -n $RG -l swedencentral
echo '{"timestamp":"'$(date -u +%FT%TZ)'","task":"CreateResourceGroup","status":"success"}' >> context-o4.jsonl
```

## 2 Provision observability
```bash
az monitor log-analytics workspace create     -g $RG -n ${BASE}-logs -l swedencentral
az monitor app-insights component create      -g $RG -a ${BASE}-ai  -l swedencentral --workspace "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RG/providers/Microsoft.OperationalInsights/workspaces/${BASE}-logs"
echo '{"timestamp":"'$(date -u +%FT%TZ)'","task":"ProvisionObservability","status":"success"}' >> context-o4.jsonl
```

## 3 Secrets
```bash
az keyvault create -g $RG -n ${BASE}-kv -l swedencentral \
  --enable-soft-delete true --enable-purge-protection true \
  --enable-rbac-authorization true
echo '{"timestamp":"'$(date -u +%FT%TZ)'","task":"KeyVaultCreated","status":"success"}' >> context-o4.jsonl
```

## 4 Data
```bash
az cosmosdb create -g $RG -n ${BASE}-cosmos --enable-serverless
az cosmosdb sql database create -g $RG -a ${BASE}-cosmos -n chatdb
# Continuous backup so chats are never lost
az cosmosdb update -g $RG -n ${BASE}-cosmos --backup-policy-type Continuous
echo '{"timestamp":"'$(date -u +%FT%TZ)'","task":"CosmosContinuousBackup","status":"success"}' >> context-o4.jsonl

# ---------- Storage (logs & uploads) ----------
az storage account create -g $RG -n ${BASE}store -l swedencentral \
  --sku Standard_LRS --kind StorageV2 \
  --min-tls-version TLS1_2 --public-network-access Enabled
echo '{"timestamp":"'$(date -u +%FT%TZ)'","task":"StorageCreated","status":"success"}' >> context-o4.jsonl
# ---------------------------------------------

# --- Save connection strings in Key Vault ---
COSMOS_CONN=$(az cosmosdb keys list -g $RG -n ${BASE}-cosmos --type connection-strings \
              --query connectionStrings[0].connectionString -o tsv)
az keyvault secret set --vault-name ${BASE}-kv -n CosmosConn --value "$COSMOS_CONN"

STORAGE_CONN=$(az storage account show-connection-string -g $RG -n ${BASE}store \
               --query connectionString -o tsv)
az keyvault secret set --vault-name ${BASE}-kv -n StorageConn --value "$STORAGE_CONN"

echo '{"timestamp":"'$(date -u +%FT%TZ)'","task":"SecretsStored","status":"success"}' >> context-o4.jsonl
# ---------------------------------------------

echo '{"timestamp":"'$(date -u +%FT%TZ)'","task":"CreateCosmosDB","status":"success"}' >> context-o4.jsonl
```

## 5 Compute
```bash
az appservice plan create  -g $RG -n ${BASE}-plan --sku P1v3 --is-linux
az webapp create -g $RG -p ${BASE}-plan -n ${BASE}-app --runtime "NODE|18-lts" --deployment-container-image-name mcr.microsoft.com/oryx/node:18
# Add managed identity & KV-backed settings
az webapp identity assign -g $RG -n ${BASE}-app
az webapp config appsettings set -g $RG -n ${BASE}-app \
  --settings CosmosConn='@Microsoft.KeyVault(VaultName=${BASE}-kv;SecretName=CosmosConn)'
echo '{"timestamp":"'$(date -u +%FT%TZ)'","task":"IdentityAssigned","status":"success"}' >> context-o4.jsonl

az webapp deployment slot create -g $RG -n ${BASE}-app -s staging
echo '{"timestamp":"'$(date -u +%FT%TZ)'","task":"CreateWebApp","status":"success","details":"${BASE}-app"}' >> context-o4.jsonl
```
Push code to *staging* slot, run smoke tests, then:
```bash
az webapp deployment slot swap -g $RG -n ${BASE}-app --slot staging
echo '{"timestamp":"'$(date -u +%FT%TZ)'","task":"SlotSwap","status":"success"}' >> context-o4.jsonl
```

### 4 Front Door + WAF
```bash
az afd profile create -g $RG -n ${BASE}-afd --sku Premium_AzureFrontDoor
az afd endpoint create -g $RG --profile-name ${BASE}-afd -n chat-ep

az afd origin-group create -g $RG --profile-name ${BASE}-afd -n og-app --origin-type app-service

az afd origin create -g $RG --profile-name ${BASE}-afd --origin-group-name og-app \
  -n chat-origin --host-name ${BASE}-app.azurewebsites.net --priority 1 --weight 100

az afd route create -g $RG --profile-name ${BASE}-afd --endpoint-name chat-ep \
  -n chatroute --origin-group og-app --supported-protocols Https \
  --patterns "/*" --forwarding-protocol HttpsOnly

az afd waf-policy create -g $RG --profile-name ${BASE}-afd -n chat-waf --sku Premium_AzureFrontDoor --mode Prevention
az afd endpoint update -g $RG --profile-name ${BASE}-afd -n chat-ep --waf-policy chat-waf
echo '{"timestamp":"'$(date -u +%FT%TZ)'","task":"FrontDoorConfigured","status":"success"}' >> context-o4.jsonl
```

### 5 Enable Defender for Cloud
```bash
az security pricing create --name Default --tier Standard
echo '{"timestamp":"'$(date -u +%FT%TZ)'","task":"DefenderEnabled","status":"success"}' >> context-o4.jsonl
```

## 6 AI
```bash
az cognitiveservices account create -g $RG -n ${BASE}-openai -l swedencentral --kind OpenAI --sku S0
# Deploy GPT-4o etc. via Azure Portal or REST – see manual-steps-o4.md
echo '{"timestamp":"'$(date -u +%FT%TZ)'","task":"CreateCognitiveServices","status":"success"}' >> context-o4.jsonl
```

### 7 OpenAI quota alert
```bash
az monitor metrics alert create -g $RG -n OpenAIQuotaAlert \
  --scopes $(az cognitiveservices account show -g $RG -n ${BASE}-openai --query id -o tsv) \
  --condition "avg RequestsThrottled > 0" --window-size 5m
echo '{"timestamp":"'$(date -u +%FT%TZ)'","task":"OpenAIAlertCreated","status":"success"}' >> context-o4.jsonl
```

# -------- Resource-group delete-lock --------
```bash
az lock create -g $RG -n rg-delete-lock --lock-type CanNotDelete
echo '{"timestamp":"'$(date -u +%FT%TZ)'","task":"RGLock","status":"success"}' >> context-o4.jsonl
```
# -------------------------------------------

## 7 Logging retention
Set Cosmos DB containers without TTL; enable PITR:
```bash
az cosmosdb sql container create -g $RG -a ${BASE}-cosmos -d simplechat -n chats --partition-key-path "/sessionId"
az cosmosdb sql container update -g $RG -a ${BASE}-cosmos -d simplechat -n chats --analytical-storage-ttl -1
echo '{"timestamp":"'$(date -u +%FT%TZ)'","task":"ConfigureCosmosDB","status":"success"}' >> context-o4.jsonl
```

### 10 Tag policy assignment
```bash
az policy definition create -n RequireTags --rules @tag-rule.json --mode Indexed
az policy assignment create --policy RequireTags -g $RG -n RequireTagsEnforced
echo '{"timestamp":"'$(date -u +%FT%TZ)'","task":"TagPolicyAssigned","status":"success"}' >> context-o4.jsonl
```

## 8 Post-deployment tasks
- Configure custom domain & HTTPS.  
- Lock the resource group to avoid accidental deletion.  
- Enable diagnostic settings forwarding to Log Analytics.  
- Document all endpoints in `deployment-context-o4.md`.

---

## Staging-environment policy (future changes)
1. All merges to *main* branch deploy to *staging* slot.  
2. Automated tests must pass.  
3. Manual approval triggers slot swap.  
4. Roll-forward only; rollback handled by re-deploying previous image (no resource deletion).  

Rollback scripts from earlier sessions are **not** recreated as per user request.
`````
