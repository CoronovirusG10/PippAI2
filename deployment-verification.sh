#!/bin/bash
# deployment-verification.sh
# Verifies all key resources and settings for the o4 deployment
# Logs results to context-o4.jsonl

BASE=pippaioflondoncdx2
RG=$BASE
LOC=swedencentral
LOG=documents/context-o4.jsonl
DATE=$(date -u +%FT%TZ)

log_result() {
  local TASK="$1"
  local STATUS="$2"
  local DETAILS="$3"
  echo "{\"timestamp\":\"$DATE\",\"task\":\"$TASK\",\"status\":\"$STATUS\",\"details\":\"$DETAILS\"}" >> "$LOG"
}

# 1. Resource Group
az group show -n "$RG" --query location -o tsv | grep -qi "$LOC" && \
  log_result "CheckResourceGroup" "success" "Resource group $RG exists in $LOC" || \
  log_result "CheckResourceGroup" "error" "Resource group $RG missing or wrong location"

# 2. Observability
az monitor log-analytics workspace show -g "$RG" -n "${BASE}-logs" &>/dev/null && \
  log_result "CheckLogAnalytics" "success" "Log Analytics workspace exists" || \
  log_result "CheckLogAnalytics" "error" "Log Analytics workspace missing"
az monitor app-insights component show -g "$RG" -a "${BASE}-ai" &>/dev/null && \
  log_result "CheckAppInsights" "success" "App Insights exists" || \
  log_result "CheckAppInsights" "error" "App Insights missing"

# 3. Key Vault
az keyvault show -g "$RG" -n "${BASE}-kv" &>/dev/null && \
  log_result "CheckKeyVault" "success" "Key Vault exists" || \
  log_result "CheckKeyVault" "error" "Key Vault missing"
# Check soft-delete and purge protection
az keyvault show -g "$RG" -n "${BASE}-kv" --query properties.enablePurgeProtection -o tsv | grep -qi true && \
  log_result "CheckKeyVaultPurgeProtection" "success" "Purge protection enabled" || \
  log_result "CheckKeyVaultPurgeProtection" "error" "Purge protection not enabled"
az keyvault show -g "$RG" -n "${BASE}-kv" --query properties.enableSoftDelete -o tsv | grep -qi true && \
  log_result "CheckKeyVaultSoftDelete" "success" "Soft delete enabled" || \
  log_result "CheckKeyVaultSoftDelete" "error" "Soft delete not enabled"

# 4. Data
az cosmosdb show -g "$RG" -n "${BASE}-cosmos" &>/dev/null && \
  log_result "CheckCosmosDB" "success" "Cosmos DB exists" || \
  log_result "CheckCosmosDB" "error" "Cosmos DB missing"
az cosmosdb sql database show -g "$RG" -a "${BASE}-cosmos" -n chatdb &>/dev/null && \
  log_result "CheckCosmosDBSqlDb" "success" "Cosmos SQL DB chatdb exists" || \
  log_result "CheckCosmosDBSqlDb" "error" "Cosmos SQL DB chatdb missing"
az cosmosdb show -g "$RG" -n "${BASE}-cosmos" --query backupPolicy.type -o tsv | grep -qi Continuous && \
  log_result "CheckCosmosBackupPolicy" "success" "Backup policy is Continuous" || \
  log_result "CheckCosmosBackupPolicy" "error" "Backup policy not Continuous"
az storage account show -g "$RG" -n "${BASE}store" &>/dev/null && \
  log_result "CheckStorageAccount" "success" "Storage account exists" || \
  log_result "CheckStorageAccount" "error" "Storage account missing"
az keyvault secret show --vault-name "${BASE}-kv" -n CosmosConn &>/dev/null && \
  log_result "CheckCosmosConnSecret" "success" "CosmosConn secret exists in Key Vault" || \
  log_result "CheckCosmosConnSecret" "error" "CosmosConn secret missing in Key Vault"
az keyvault secret show --vault-name "${BASE}-kv" -n StorageConn &>/dev/null && \
  log_result "CheckStorageConnSecret" "success" "StorageConn secret exists in Key Vault" || \
  log_result "CheckStorageConnSecret" "error" "StorageConn secret missing in Key Vault"

# 5. Compute
az appservice plan show -g "$RG" -n "${BASE}-plan" &>/dev/null && \
  log_result "CheckAppServicePlan" "success" "App Service plan exists" || \
  log_result "CheckAppServicePlan" "error" "App Service plan missing"
az webapp show -g "$RG" -n "${BASE}-app" &>/dev/null && \
  log_result "CheckWebApp" "success" "Web App exists" || \
  log_result "CheckWebApp" "error" "Web App missing"
az webapp identity show -g "$RG" -n "${BASE}-app" --query principalId -o tsv | grep -q . && \
  log_result "CheckWebAppIdentity" "success" "Managed identity assigned" || \
  log_result "CheckWebAppIdentity" "error" "Managed identity not assigned"
az webapp config appsettings list -g "$RG" -n "${BASE}-app" | grep -q 'CosmosConn.*@Microsoft.KeyVault' && \
  log_result "CheckWebAppAppSettings" "success" "App settings reference Key Vault" || \
  log_result "CheckWebAppAppSettings" "error" "App settings do not reference Key Vault"
az webapp deployment slot list -g "$RG" -n "${BASE}-app" | grep -q 'staging' && \
  log_result "CheckWebAppStagingSlot" "success" "Staging slot exists" || \
  log_result "CheckWebAppStagingSlot" "error" "Staging slot missing"

# 6. Front Door + WAF
az afd profile show -g "$RG" -n "${BASE}-afd" &>/dev/null && \
  log_result "CheckFrontDoorProfile" "success" "Front Door profile exists" || \
  log_result "CheckFrontDoorProfile" "error" "Front Door profile missing"
az afd endpoint show -g "$RG" --profile-name "${BASE}-afd" -n chat-ep &>/dev/null && \
  log_result "CheckFrontDoorEndpoint" "success" "Front Door endpoint exists" || \
  log_result "CheckFrontDoorEndpoint" "error" "Front Door endpoint missing"
az afd origin-group show -g "$RG" --profile-name "${BASE}-afd" -n og-app &>/dev/null && \
  log_result "CheckOriginGroup" "success" "Origin group exists" || \
  log_result "CheckOriginGroup" "error" "Origin group missing"
az afd origin show -g "$RG" --profile-name "${BASE}-afd" --origin-group-name og-app -n chat-origin &>/dev/null && \
  log_result "CheckOrigin" "success" "Origin exists" || \
  log_result "CheckOrigin" "error" "Origin missing"
az afd route show -g "$RG" --profile-name "${BASE}-afd" --endpoint-name chat-ep -n chatroute &>/dev/null && \
  log_result "CheckRoute" "success" "Route exists" || \
  log_result "CheckRoute" "error" "Route missing"
az afd waf-policy show -g "$RG" --profile-name "${BASE}-afd" -n chat-waf &>/dev/null && \
  log_result "CheckWAFPolicy" "success" "WAF policy exists" || \
  log_result "CheckWAFPolicy" "error" "WAF policy missing"

# 7. Defender for Cloud
az security pricing list --query "[?pricingTier=='Standard']" -o tsv | grep -q . && \
  log_result "CheckDefender" "success" "Defender for Cloud enabled for at least one resource type" || \
  log_result "CheckDefender" "error" "Defender for Cloud not enabled"
az security pricing show -n Api --query subPlan -o tsv | grep -q P1 && \
  log_result "CheckDefenderAPI" "success" "Defender for APIs enabled with P1 plan" || \
  log_result "CheckDefenderAPI" "error" "Defender for APIs not enabled with P1 plan"

# 8. AI
az cognitiveservices account show -g "$RG" -n "${BASE}-openai" &>/dev/null && \
  log_result "CheckCognitiveServices" "success" "Cognitive Services (OpenAI) exists" || \
  log_result "CheckCognitiveServices" "error" "Cognitive Services (OpenAI) missing"

# 9. Alerts & Locks
az monitor metrics alert show -g "$RG" -n OpenAIQuotaAlert &>/dev/null && \
  log_result "CheckOpenAIQuotaAlert" "success" "OpenAI quota alert exists" || \
  log_result "CheckOpenAIQuotaAlert" "error" "OpenAI quota alert missing"
az lock show -g "$RG" | grep -q 'CanNotDelete' && \
  log_result "CheckResourceGroupLock" "success" "Resource group delete lock exists" || \
  log_result "CheckResourceGroupLock" "error" "Resource group delete lock missing"

# 10. Cosmos DB Logging Retention
az cosmosdb sql container show -g "$RG" -a "${BASE}-cosmos" -d simplechat -n chats &>/dev/null && \
  log_result "CheckCosmosContainer" "success" "Cosmos DB container exists" || \
  log_result "CheckCosmosContainer" "error" "Cosmos DB container missing"
az cosmosdb sql container show -g "$RG" -a "${BASE}-cosmos" -d simplechat -n chats --query analyticalStorageTtl -o tsv | grep -q -- '-1' && \
  log_result "CheckCosmosContainerTTL" "success" "Analytical storage TTL is -1" || \
  log_result "CheckCosmosContainerTTL" "error" "Analytical storage TTL is not -1"

# 11. Tag Policy
az policy definition show -n RequireTags &>/dev/null && \
  log_result "CheckTagPolicyDefinition" "success" "Tag policy definition exists" || \
  log_result "CheckTagPolicyDefinition" "error" "Tag policy definition missing"
az policy assignment show -g "$RG" -n RequireTagsEnforced &>/dev/null && \
  log_result "CheckTagPolicyAssignment" "success" "Tag policy assignment exists" || \
  log_result "CheckTagPolicyAssignment" "error" "Tag policy assignment missing"

exit 0
