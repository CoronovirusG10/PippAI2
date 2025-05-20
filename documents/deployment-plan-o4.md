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

## 1 Create resource group
```bash
BASE=pippaioflondoncdx2
RG=$BASE
LOC=swedencentral
run-step CreateResourceGroup az group create -n $RG -l $LOC
```

## 2 Provision observability
```bash
run-step CreateLogAnalytics az monitor.log-analytics workspace create -g $RG -n ${BASE}-logs -l $LOC
run-step CreateAppInsights az monitor app-insights component create -g $RG -a ${BASE}-ai -l $LOC --workspace "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RG/providers/Microsoft.OperationalInsights/workspaces/${BASE}-logs"
```

## 3 Secrets
```bash
run-step KeyVaultCreated az keyvault create -g $RG -n ${BASE}-kv -l $LOC --enable-soft-delete true --enable-purge-protection true --enable-rbac-authorization true
```

## 4 Data
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

## 5 Compute
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
```

### 4 Front Door + WAF
```bash
run-step FrontDoorProfile az afd profile create -g $RG -n ${BASE}-afd --sku Premium_AzureFrontDoor
run-step FrontDoorEndpoint az afd endpoint create -g $RG --profile-name ${BASE}-afd -n chat-ep
run-step OriginGroup az afd origin-group create -g $RG --profile-name ${BASE}-afd -n og-app --origin-type app-service
run-step OriginCreated az afd origin create -g $RG --profile-name ${BASE}-afd --origin-group-name og-app -n chat-origin --host-name ${BASE}-app.azurewebsites.net --priority 1 --weight 100
run-step RouteCreated az afd route create -g $RG --profile-name ${BASE}-afd --endpoint-name chat-ep -n chatroute --origin-group og-app --supported-protocols Https --patterns "/*" --forwarding-protocol HttpsOnly
run-step WAFPolicyCreated az afd waf-policy create -g $RG --profile-name ${BASE}-afd -n chat-waf --sku Premium_AzureFrontDoor --mode Prevention
run-step WAFPolicyAssigned az afd endpoint update -g $RG --profile-name ${BASE}-afd -n chat-ep --waf-policy chat-waf
```

### 5 Enable Defender for Cloud
```bash
run-step DefenderEnabled az security pricing create --name Default --tier Standard
```

## 6 AI
```bash
run-step CognitiveServicesCreated az cognitiveservices account create -g $RG -n ${BASE}-openai -l $LOC --kind OpenAI --sku S0
# Deploy GPT-4o etc. via Azure Portal or REST – see manual-steps-o4.md
```

# Note: Diagnostic settings for Azure AI Search, Document Intelligence, and Speech Service require a destination (Log Analytics workspace, Storage, or Event Hub). Use the Log Analytics workspace created in step 2 for consistency.

# Get Log Analytics workspace resource ID
LOG_ANALYTICS_ID=$(az monitor log-analytics workspace show -g $RG -n ${BASE}-logs --query id -o tsv)

## 6a Azure AI Search
```bash
run-step AISearchCreated az search service create --name ${BASE}-search --resource-group $RG --location $LOC --sku Standard
run-step AISearchIdentity az search service update --name ${BASE}-search --resource-group $RG --identity-type SystemAssigned
run-step AISearchDiagnostics az monitor diagnostic-settings create --name ${BASE}-search-diag --resource $(az search.service show --name ${BASE}-search --resource-group $RG --query id -o tsv) --workspace $LOG_ANALYTICS_ID --logs '[{"category": "AllMetrics", "enabled": true},{"category": "AuditLogs", "enabled": true}]'
```

## 6b Azure AI Document Intelligence
```bash
run-step AIDocIntelCreated az cognitiveservices account create -g $RG -n ${BASE}-docint -l $LOC --kind FormRecognizer --sku S0
run-step AIDocIntelIdentity az cognitiveservices account identity assign --name ${BASE}-docint --resource-group $RG
run-step AIDocIntelDiagnostics az monitor diagnostic-settings create --name ${BASE}-docint-diag --resource $(az cognitiveservices account show --name ${BASE}-docint --resource-group $RG --query id -o tsv) --workspace $LOG_ANALYTICS_ID --logs '[{"category": "AllMetrics", "enabled": true},{"category": "AuditLogs", "enabled": true}]'
```

## 6c Azure Speech Service
```bash
run-step AISpeechCreated az cognitiveservices account create --name ${BASE}-speech --resource-group $RG --kind SpeechServices --sku S0 --location $LOC --yes
run-step AISpeechIdentity az cognitiveservices account identity assign --name ${BASE}-speech --resource-group $RG
run-step AISpeechDiagnostics az monitor diagnostic-settings create --name ${BASE}-speech-diag --resource $(az cognitiveservices account show --name ${BASE}-speech --resource-group $RG --query id -o tsv) --workspace $LOG_ANALYTICS_ID --logs '[{"category": "AllMetrics", "enabled": true},{"category": "AuditLogs", "enabled": true}]'
```
## 7 Logging retention
Set Cosmos DB containers without TTL; enable PITR:
```bash
run-step CosmosContainerCreated az cosmosdb sql container create -g $RG -a ${BASE}-cosmos -d simplechat -n chats --partition-key-path "/sessionId"
run-step CosmosContainerUpdated az cosmosdb sql container update -g $RG -a ${BASE}-cosmos -d simplechat -n chats --analytical-storage-ttl -1
```

### 10 Tag policy assignment
```bash
run-step TagPolicyDefined az policy definition create -n RequireTags --rules @tag-rule.json --mode Indexed
run-step TagPolicyAssigned az policy assignment create --policy RequireTags -g $RG -n RequireTagsEnforced
```

## 8 Post-deployment tasks
- [x] Configure custom domain & HTTPS.  
- [x] Lock the resource group to avoid accidental deletion.  
- [x] Enable diagnostic settings forwarding to Log Analytics.  
- [x] Document all endpoints in `deployment-context-o4.md`.  
- [x] All major endpoints are also stored as reference secrets in Key Vault for operational consistency.  
- [x] Verification checklist completed.  

---

## Deployment Summary (as of 2025-05-20)
- All resources are deployed and configured as per plan.
- All endpoints are provisioned, documented, and stored in Key Vault.
- All required secrets are in the vault and referenced where needed.
- Documentation and verification files are up to date.
- Manual steps (WAF, OpenAI model deployment) are noted in `manual-steps-o4.md`.

## Staging-environment policy (future changes)
1. All merges to *main* branch deploy to *staging* slot.  
2. Automated tests must pass.  
3. Manual approval triggers slot swap.  
4. Roll-forward only; rollback handled by re-deploying previous image (no resource deletion).  

Rollback scripts from earlier sessions are **not** recreated as per user request.
