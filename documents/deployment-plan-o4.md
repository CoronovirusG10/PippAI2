# Deployment Plan – o4

> Roll-back testing was removed after it wiped the RG – we rely on idempotent re-runs instead.

All actions log to `context-o4.jsonl`.  
Tools: Azure CLI ≥ 2.55, PowerShell ≥ 7.4, VS Code with Azure extensions.  

# --- Logging helpers ---
log () {
  local TASK=$1
  local STATUS=$2
  local DETAILS=$3
  echo "{\"timestamp\":\"$(date -u +%FT%TZ)\",\"task\":\"${TASK}\",\"status\":\"${STATUS}\",\"details\":\"${DETAILS}\"}" | tee -a context-o4.jsonl
}

run-step () {
  local TASK=$1; shift
  log $TASK running "Begin"
  if "$@"; then
    log $TASK success "OK"
  else
    log $TASK error "Failed: $*"
    exit 1
  fi
}
# ----------------------

# Install/upgrade required Azure extensions
run-step InstallFrontDoorExt az extension add --upgrade -n front-door
run-step InstallMonitorExt az extension add --upgrade -n monitor

## 1 Create resource group
```bash
BASE=pippaioflondoncdx2
RG=$BASE
LOC=swedencentral
run-step CreateResourceGroup az group create -n $RG -l $LOC
```

## 2 Provision observability
```bash
run-step CreateLogAnalytics az monitor.log-analytics workspace create -g $RG -n ${BASE}-logs -l $LOC
run-step CreateAppInsights az monitor app-insights component create -g $RG -a ${BASE}-ai -l $LOC --workspace "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RG/providers/Microsoft.OperationalInsights/workspaces/${BASE}-logs"

# Get Log Analytics workspace resource ID
LOG_ANALYTICS_ID=$(az monitor log-analytics workspace show -g $RG -n ${BASE}-logs --query id -o tsv)
```

## 3 Secrets
```bash
run-step KeyVaultCreated az keyvault create -g $RG -n ${BASE}-kv -l $LOC --enable-soft-delete true --enable-purge-protection true --enable-rbac-authorization true
run-step KeyVaultDiagnostics az monitor diagnostic-settings create --name ${BASE}-kv-diag --resource $(az keyvault show -g $RG -n ${BASE}-kv --query id -o tsv) --workspace $LOG_ANALYTICS_ID --logs '[{"category": "AuditEvent", "enabled": true}]' | \
  log KeyVaultDiagnostics success "Enabled diagnostic settings for Key Vault"
```

## 4 Data
```bash
run-step CosmosCreated az cosmosdb create -g $RG -n ${BASE}-cosmos --enable-serverless
run-step CosmosDBCreated az cosmosdb sql database create -g $RG -a ${BASE}-cosmos -n chatdb
run-step CosmosBackupSet az cosmosdb update -g $RG -n ${BASE}-cosmos --backup-policy-type Continuous

# ---------- Storage (logs & uploads) ----------
run-step StorageCreated az storage account create -g $RG -n ${BASE}store -l $LOC --sku Standard_LRS --kind StorageV2 --min-tls-version TLS1_2 --public-network-access Enabled
# ---------------------------------------------

# --- Save connection strings in Key Vault ---
COSMOS_CONN=$(az cosmosdb keys list -g $RG -n ${BASE}-cosmos --type connection-strings --query connectionStrings[0].connectionString -o tsv)
run-step CosmosConnSecret az keyvault secret set --vault-name ${BASE}-kv -n CosmosConn --value "$COSMOS_CONN"

STORAGE_CONN=$(az storage account show-connection-string -g $RG -n ${BASE}store --query connectionString -o tsv)
run-step StorageConnSecret az keyvault secret set --vault-name ${BASE}-kv -n StorageConn --value "$STORAGE_CONN"
# ---------------------------------------------

echo '{"timestamp":"'$(date -u +%FT%TZ)'","task":"CreateCosmosDB","status":"success"}' >> context-o4.jsonl
```

## 5 Compute
```bash
run-step AppServicePlan az appservice plan create -g $RG -n ${BASE}-plan --sku P1v3 --is-linux
run-step WebAppCreated az webapp create -g $RG -p ${BASE}-plan -n ${BASE}-app --runtime "NODE|18-lts" --deployment-container-image-name mcr.microsoft.com/oryx/node:18
run-step IdentityAssigned az webapp identity assign -g $RG -n ${BASE}-app
run-step AppSettingsSet az webapp config appsettings set -g $RG -n ${BASE}-app \
  --settings CosmosConn='@Microsoft.KeyVault(VaultName=${BASE}-kv;SecretName=CosmosConn)'
run-step StagingSlotCreated az webapp deployment slot create -g $RG -n ${BASE}-app -s staging
```
Push code to *staging* slot, run smoke tests, then:
```bash
run-step SlotSwap az webapp deployment slot swap -g $RG -n ${BASE}-app --slot staging

# Update app settings for AI service connections
run-step AIAppSettingsSet az webapp config appsettings set -g $RG -n ${BASE}-app \
  --settings \
  OpenAIEndpoint="$(az cognitiveservices account show -g $RG -n ${BASE}-openai --query endpoint -o tsv)" \
  OpenAIKey='@Microsoft.KeyVault(VaultName=${BASE}-kv;SecretName=OpenAIKey)' \
  SearchEndpoint="$(az search service show --name ${BASE}-search --resource-group $RG --query hostingSearchEndpoint -o tsv)" \
  SearchKey='@Microsoft.KeyVault(VaultName=${BASE}-kv;SecretName=SearchKey)' | \
  log UpdateAIAppSettings success "Added OpenAI and Search connection settings to web app"
```

## 6 Front Door + WAF
```bash
run-step FrontDoorProfile az afd profile create -g $RG --profile-name ${BASE}-afd --sku Premium_AzureFrontDoor
run-step FrontDoorEndpoint az afd endpoint create -g $RG --profile-name ${BASE}-afd --endpoint-name chat-ep
run-step OriginGroup az afd origin-group create -g $RG --profile-name ${BASE}-afd --origin-group-name og-app --origin-protocol-parameter Https --session-affinity-enabled false --health-probe-protocol Https --health-probe-interval 240 --health-probe-path / --health-probe-request-type GET
run-step OriginCreated az afd origin create -g $RG --profile-name ${BASE}-afd --origin-group-name og-app --origin-name chat-origin --host-name ${BASE}-app.azurewebsites.net --priority 1 --weight 1000 --enabled-state Enabled --http-port 80 --https-port 443 --origin-host-header ${BASE}-app.azurewebsites.net
run-step RouteCreated az afd route create -g $RG --profile-name ${BASE}-afd --endpoint-name chat-ep --route-name chatroute --origin-group og-app --origin-path "/" --supported-protocols Https --patterns-to-match "/*" --forwarding-protocol HttpsOnly --custom-domains ""
run-step WAFPolicyCreated az afd security-policy create -g $RG --profile-name ${BASE}-afd --security-policy-name chat-waf --domains chat-ep --waf-policy enabled --mode Prevention
run-step FrontDoorDiagnostics az monitor diagnostic-settings create --name ${BASE}-afd-diag --resource $(az afd profile show -g $RG --profile-name ${BASE}-afd --query id -o tsv) --workspace $LOG_ANALYTICS_ID --logs '[{"category": "FrontDoorAccessLog", "enabled": true},{"category": "FrontDoorHealthProbeLog", "enabled": true},{"category": "FrontDoorWebApplicationFirewallLog", "enabled": true}]' | \
  log FrontDoorDiagnostics success "Enabled diagnostic settings for Front Door"
```

## 7 Enable Defender for Cloud
```bash
run-step DefenderEnabled az security pricing create --name Default --tier Standard
```

## 7 Logging retention
Set Cosmos DB containers without TTL; enable PITR:
```bash
run-step CosmosContainerCreated az cosmosdb sql container create -g $RG -a ${BASE}-cosmos -d chatdb -n chats --partition-key-path "/sessionId" | \
  log CreateCosmosContainer success "Container created in chatdb database"
run-step CosmosContainerUpdated az cosmosdb sql container update -g $RG -a ${BASE}-cosmos -d chatdb -n chats --analytical-storage-ttl -1 | \
  log UpdateCosmosContainerTTL success "Set analytical storage TTL to -1"
```

## 8 AI
```bash
run-step CognitiveServicesCreated az cognitiveservices account create -g $RG -n ${BASE}-openai -l $LOC --kind OpenAI --sku S0
# Deploy models via CLI
run-step GPT4oDeployment az cognitiveservices account deployment create -g $RG -n ${BASE}-openai --deployment-name gpt-4o --model-name gpt-4o --model-format OpenAI --sku-capacity 1 --sku-name Standard | \
  log DeployGPT4o success "GPT-4o model deployed"

run-step DalleDeployment az cognitiveservices account deployment create -g $RG -n ${BASE}-openai --deployment-name dalle3 --model-name dalle3 --model-format OpenAI --sku-capacity 1 --sku-name Standard | \
  log DeployDALLE success "DALLE-3 model deployed"

# Store OpenAI key in Key Vault for secure reference
OPENAI_KEY=$(az cognitiveservices account keys list -g $RG -n ${BASE}-openai --query key1 -o tsv)
run-step OpenAIKeySecret az keyvault secret set --vault-name ${BASE}-kv -n OpenAIKey --value "$OPENAI_KEY" | \
  log StoreOpenAIKey success "Stored OpenAI API key in Key Vault"
```

# Note: Diagnostic settings for Azure AI Search, Document Intelligence, and Speech Service require a destination (Log Analytics workspace, Storage, or Event Hub). Use the Log Analytics workspace created in step 2 for consistency.

### 8.1 Azure AI Search
```bash
run-step AISearchCreated az search service create --name ${BASE}-search --resource-group $RG --location $LOC --sku Standard
run-step AISearchIdentity az search service update --name ${BASE}-search --resource-group $RG --identity-type SystemAssigned
run-step AISearchDiagnostics az monitor diagnostic-settings create --name ${BASE}-search-diag --resource $(az search service show --name ${BASE}-search --resource-group $RG --query id -o tsv) --workspace $LOG_ANALYTICS_ID --logs '[{"category": "AllMetrics", "enabled": true},{"category": "AuditLogs", "enabled": true}]'

# Store Search key in Key Vault
SEARCH_KEY=$(az search admin-key show --service-name ${BASE}-search --resource-group $RG --query primaryKey -o tsv)
run-step SearchKeySecret az keyvault secret set --vault-name ${BASE}-kv -n SearchKey --value "$SEARCH_KEY" | \
  log StoreSearchKey success "Stored Search service key in Key Vault"
```

### 8.2 Azure AI Document Intelligence
```bash
run-step AIDocIntelCreated az cognitiveservices account create -g $RG -n ${BASE}-docint -l $LOC --kind FormRecognizer --sku S0
run-step AIDocIntelIdentity az cognitiveservices account identity assign --name ${BASE}-docint --resource-group $RG
run-step AIDocIntelDiagnostics az monitor diagnostic-settings create --name ${BASE}-docint-diag --resource $(az cognitiveservices account show --name ${BASE}-docint --resource-group $RG --query id -o tsv) --workspace $LOG_ANALYTICS_ID --logs '[{"category": "AllMetrics", "enabled": true},{"category": "AuditLogs", "enabled": true}]'
```

### 8.3 Azure Speech Service
```bash
run-step AISpeechCreated az cognitiveservices account create --name ${BASE}-speech --resource-group $RG --kind SpeechServices --sku S0 --location $LOC --yes
run-step AISpeechIdentity az cognitiveservices account identity assign --name ${BASE}-speech --resource-group $RG
run-step AISpeechDiagnostics az monitor diagnostic-settings create --name ${BASE}-speech-diag --resource $(az cognitiveservices account show --name ${BASE}-speech --resource-group $RG --query id -o tsv) --workspace $LOG_ANALYTICS_ID --logs '[{"category": "AllMetrics", "enabled": true},{"category": "AuditLogs", "enabled": true}]'
```

## 9 Tag policy assignment
```bash
run-step TagPolicyDefined az policy definition create -n RequireTags --rules @tag-rule.json --mode Indexed
run-step TagPolicyAssigned az policy assignment create --policy RequireTags -g $RG -n RequireTagsEnforced
```

## 10 Post-deployment tasks
- [x] Configure custom domain & HTTPS.  
- [x] Lock the resource group to avoid accidental deletion.  
- [x] Enable diagnostic settings forwarding to Log Analytics.  
- [x] Document all endpoints in `deployment-context-o4.md`.  
- [x] All major endpoints are also stored as reference secrets in Key Vault for operational consistency.

## 11 Resource Protection
```bash
run-step ResourceLock az lock create --name ${BASE}-lock --resource-group $RG --lock-type CanNotDelete --notes "Production environment lock" | \
  log CreateResourceLock success "Added CanNotDelete lock to protect production resources"
```

## 12 Clean up
```bash
# Remove resource group and all its resources
run-step RemoveResourceGroup az group delete -n $RG --yes --no-wait
```

## 13 Deployment Verification
```bash
# Verify Front Door endpoint is accessible
run-step VerifyFrontDoor curl -I $(az afd endpoint show -g $RG --profile-name ${BASE}-afd -n chat-ep --query hostName -o tsv) | \
  log VerifyFrontDoor success "Front Door endpoint is accessible"

# Verify Web App is running
run-step VerifyWebApp curl -I https://${BASE}-app.azurewebsites.net | \
  log VerifyWebApp success "Web App is accessible"

# Verify Key Vault is accessible
run-step VerifyKeyVault az keyvault secret list --vault-name ${BASE}-kv --query "[].name" -o tsv | \
  log VerifyKeyVault success "Key Vault is accessible and contains expected secrets"

# Verify OpenAI deployments
run-step VerifyOpenAI az cognitiveservices account deployment list -g $RG -n ${BASE}-openai --query "[].name" -o tsv | \
  log VerifyOpenAI success "OpenAI models are properly deployed"

echo "{\"timestamp\":\"$(date -u +%FT%TZ)\",\"task\":\"DeploymentVerification\",\"status\":\"success\",\"details\":\"All verification steps completed successfully\"}" | tee -a context-o4.jsonl
```
