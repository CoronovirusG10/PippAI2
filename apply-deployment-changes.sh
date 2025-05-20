#!/bin/bash

# Script to apply changes from the fixed deployment-plan-o4.md
# Created: May 21, 2025

# Setup Environment
BASE=pippaioflondoncdx2
RG=$BASE
LOC=swedencentral
echo "Applying changes to resource group: $RG"

# Function to log steps
log() {
  local TASK=$1
  local STATUS=$2
  local DETAILS=$3
  echo "$(date -u +%FT%TZ): [$TASK] $STATUS - $DETAILS"
}

# Function to execute steps
run-step() {
  local TASK=$1; shift
  log "$TASK" "running" "Begin"
  if "$@"; then
    log "$TASK" "success" "OK"
    return 0
  else
    log "$TASK" "error" "Failed: $*"
    return 1
  fi
}

# 1. Get Log Analytics workspace ID
echo "Getting Log Analytics workspace ID"
LOG_ANALYTICS_ID=$(az monitor log-analytics workspace show -g $RG -n ${BASE}-logs --query id -o tsv)
if [ -z "$LOG_ANALYTICS_ID" ]; then
  log "GetLogAnalyticsID" "error" "Failed to get Log Analytics workspace ID"
  exit 1
else
  log "GetLogAnalyticsID" "success" "ID retrieved: $LOG_ANALYTICS_ID"
fi

# 2. Fix the Cosmos DB container database
echo "Updating Cosmos DB container to use chatdb"
run-step CosmosContainerUpdate "az cosmosdb sql container show -g $RG -a ${BASE}-cosmos -d chatdb -n chats 2>/dev/null || 
  az cosmosdb sql container create -g $RG -a ${BASE}-cosmos -d chatdb -n chats --partition-key-path '/sessionId'"

run-step CosmosContainerTTL "az cosmosdb sql container update -g $RG -a ${BASE}-cosmos -d chatdb -n chats --analytical-storage-ttl -1"

# 3. Deploy OpenAI models if they don't exist
echo "Deploying OpenAI models"
run-step CheckOpenAI "az cognitiveservices account show -g $RG -n ${BASE}-openai --query name || 
  echo 'OpenAI account not found, skipping model deployment'"

OPENAI_EXISTS=$(az cognitiveservices account show -g $RG -n ${BASE}-openai --query name -o tsv 2>/dev/null)
if [ ! -z "$OPENAI_EXISTS" ]; then
  # Check if GPT-4o model is already deployed
  GPT4O_EXISTS=$(az cognitiveservices account deployment show -g $RG -n ${BASE}-openai --deployment-name gpt-4o 2>/dev/null)
  if [ -z "$GPT4O_EXISTS" ]; then
    run-step GPT4oDeployment "az cognitiveservices account deployment create -g $RG -n ${BASE}-openai --deployment-name gpt-4o --model-name gpt-4o --model-format OpenAI --sku-capacity 1 --sku-name Standard"
  else
    log "GPT4oDeployment" "info" "GPT-4o model already deployed"
  fi
  
  # Check if DALLE-3 model is already deployed
  DALLE_EXISTS=$(az cognitiveservices account deployment show -g $RG -n ${BASE}-openai --deployment-name dalle3 2>/dev/null)
  if [ -z "$DALLE_EXISTS" ]; then
    run-step DalleDeployment "az cognitiveservices account deployment create -g $RG -n ${BASE}-openai --deployment-name dalle3 --model-name dalle3 --model-format OpenAI --sku-capacity 1 --sku-name Standard"
  else
    log "DalleDeployment" "info" "DALLE-3 model already deployed"
  fi
  
  # Store OpenAI key in Key Vault
  run-step StoreOpenAIKey "OPENAI_KEY=\$(az cognitiveservices account keys list -g $RG -n ${BASE}-openai --query key1 -o tsv) && 
    az keyvault secret set --vault-name ${BASE}-kv -n OpenAIKey --value \"\$OPENAI_KEY\""
fi

# 4. Store Search key in Key Vault
echo "Storing Search key in Key Vault"
run-step StoreSearchKey "SEARCH_KEY=\$(az search admin-key show --service-name ${BASE}-search --resource-group $RG --query primaryKey -o tsv) && 
  az keyvault secret set --vault-name ${BASE}-kv -n SearchKey --value \"\$SEARCH_KEY\""

# 5. Add Key Vault diagnostics if not already added
echo "Adding Key Vault diagnostic settings"
KV_DIAG_EXISTS=$(az monitor diagnostic-settings list --resource $(az keyvault show -g $RG -n ${BASE}-kv --query id -o tsv) --query "[?name=='${BASE}-kv-diag'].name" -o tsv 2>/dev/null)
if [ -z "$KV_DIAG_EXISTS" ]; then
  run-step KeyVaultDiagnostics "az monitor diagnostic-settings create --name ${BASE}-kv-diag --resource \$(az keyvault show -g $RG -n ${BASE}-kv --query id -o tsv) --workspace $LOG_ANALYTICS_ID --logs '[{\"category\": \"AuditEvent\", \"enabled\": true}]'"
else
  log "KeyVaultDiagnostics" "info" "Key Vault diagnostics already exist"
fi

# 6. Add Front Door diagnostics if not already added
echo "Adding Front Door diagnostic settings"
AFD_DIAG_EXISTS=$(az monitor diagnostic-settings list --resource $(az afd profile show -g $RG --profile-name ${BASE}-afd --query id -o tsv) --query "[?name=='${BASE}-afd-diag'].name" -o tsv 2>/dev/null)
if [ -z "$AFD_DIAG_EXISTS" ]; then
  run-step FrontDoorDiagnostics "az monitor diagnostic-settings create --name ${BASE}-afd-diag --resource \$(az afd profile show -g $RG --profile-name ${BASE}-afd --query id -o tsv) --workspace $LOG_ANALYTICS_ID --logs '[{\"category\": \"FrontDoorAccessLog\", \"enabled\": true},{\"category\": \"FrontDoorHealthProbeLog\", \"enabled\": true},{\"category\": \"FrontDoorWebApplicationFirewallLog\", \"enabled\": true}]'"
else
  log "FrontDoorDiagnostics" "info" "Front Door diagnostics already exist"
fi

# 7. Add Resource Lock if it doesn't exist
echo "Adding Resource Lock for protection"
LOCK_EXISTS=$(az lock list -g $RG --query "[?name=='${BASE}-lock'].name" -o tsv 2>/dev/null)
if [ -z "$LOCK_EXISTS" ]; then
  run-step ResourceLock "az lock create --name ${BASE}-lock --resource-group $RG --lock-type CanNotDelete --notes 'Production environment lock'"
else
  log "ResourceLock" "info" "Resource lock already exists"
fi

# 8. Verify that the changes have been applied
echo "Running verification steps"
run-step VerifyOpenAI "az cognitiveservices account deployment list -g $RG -n ${BASE}-openai --query \"[].name\" -o tsv"
run-step VerifyKeyVault "az keyvault secret list --vault-name ${BASE}-kv --query \"[].name\" -o tsv"
run-step VerifyFrontDoor "az afd endpoint show -g $RG --profile-name ${BASE}-afd -n chat-ep --query hostName -o tsv"
run-step VerifyResourceLock "az lock list -g $RG --query \"[?name=='${BASE}-lock'].name\" -o tsv"

echo "Completed applying changes to deployment"
