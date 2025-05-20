#!/bin/bash

# PippAI2 - O4 Deployment Verification Script
# This script verifies all resources, variables, endpoints, secrets and configuration are correctly deployed
# Version 2.0 - With context-o4.jsonl integration and auto-fix attempts

# Set variables
BASE="pippaioflondoncdx2"
RG="$BASE"
LOC="swedencentral"
CONTEXT_LOG="documents/context-o4.jsonl"

# Text formatting
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Make sure the context log exists
if [ ! -f "$CONTEXT_LOG" ]; then
    if [ -d "documents" ]; then
        touch "$CONTEXT_LOG"
    else
        CONTEXT_LOG="context-o4.jsonl"
        touch "$CONTEXT_LOG"
    fi
fi

# Log to context-o4.jsonl function
log_to_context() {
    local task=$1
    local status=$2
    local details=$3
    
    timestamp=$(date -u +%FT%TZ)
    echo "{\"timestamp\":\"$timestamp\",\"task\":\"$task\",\"status\":\"$status\",\"details\":\"$details\"}" >> "$CONTEXT_LOG"
}

# Logging function
log_result() {
    local test_name=$1
    local result=$2
    local details=$3
    
    if [ "$result" = "PASS" ]; then
        echo -e "${GREEN}[PASS]${NC} $test_name"
    elif [ "$result" = "WARN" ]; then
        echo -e "${YELLOW}[WARN]${NC} $test_name - $details"
    else
        echo -e "${RED}[FAIL]${NC} $test_name - $details"
    fi
    
    # Log to verification results
    echo "{\"timestamp\":\"$(date -u +%FT%TZ)\",\"test\":\"$test_name\",\"result\":\"$result\",\"details\":\"$details\"}" >> verification-results.json
    
    # Only log failures and warnings to the main context log
    if [ "$result" = "FAIL" ]; then
        log_to_context "Verify_$test_name" "error" "$details"
    elif [ "$result" = "WARN" ]; then
        log_to_context "Verify_$test_name" "warning" "$details"
    fi
}

# Function to attempt fixes for common issues
attempt_fix() {
    local resource=$1
    local issue=$2
    local fix_command=$3
    
    echo -e "${YELLOW}[FIX ATTEMPT]${NC} Attempting to fix: $issue"
    log_to_context "FixAttempt_$resource" "in-progress" "Attempting to fix: $issue"
    
    if eval "$fix_command"; then
        echo -e "${GREEN}[FIX SUCCESS]${NC} Successfully fixed: $issue"
        log_to_context "FixAttempt_$resource" "success" "Successfully fixed: $issue"
        return 0
    else
        echo -e "${RED}[FIX FAILED]${NC} Could not fix: $issue"
        log_to_context "FixAttempt_$resource" "error" "Failed to fix: $issue"
        return 1
    fi
}

echo "=== PippAI2 O4 Deployment Verification ==="
echo "Starting verification at $(date)"
log_to_context "VerificationScript" "started" "Starting comprehensive verification of O4 deployment"

echo "[]" > verification-results.json

# 1. Check Azure CLI and extensions
echo -e "\n=== Checking prerequisites ==="
if ! command -v az &> /dev/null; then
    log_result "Azure CLI Check" "FAIL" "Azure CLI not installed"
    exit 1
fi

# Check for required extensions
for ext in front-door; do
    if ! az extension show -n $ext &> /dev/null; then
        log_result "Azure Extension: $ext" "FAIL" "Extension not installed"
        echo "Installing extension $ext..."
        attempt_fix "AzExtension_$ext" "Extension not installed" "az extension add -n $ext"
    else
        log_result "Azure Extension: $ext" "PASS" "Installed"
    fi
done

# 2. Check Resource Group
echo -e "\n=== Checking Resource Group ==="
if az group show -n $RG &> /dev/null; then
    log_result "Resource Group: $RG" "PASS" "Exists in $LOC"
    
    # Check RG Lock
    if az lock list -g $RG --query "[?name=='rg-delete-lock']" -o tsv | grep -q "CanNotDelete"; then
        log_result "Resource Group Lock" "PASS" "Delete lock exists"
    else
        log_result "Resource Group Lock" "FAIL" "Delete lock is missing"
        attempt_fix "RG_Lock" "Delete lock is missing" "az lock create -g $RG -n rg-delete-lock --lock-type CanNotDelete"
    fi
else
    log_result "Resource Group: $RG" "FAIL" "Does not exist"
    log_to_context "VerificationAborted" "error" "Critical failure: Resource Group $RG does not exist"
    exit 1
fi

# 3. Check Observability Resources
echo -e "\n=== Checking Observability Resources ==="

# Check Log Analytics
if az monitor log-analytics workspace show -g $RG -n "${BASE}-logs" &> /dev/null; then
    log_result "Log Analytics: ${BASE}-logs" "PASS" "Exists"
    LOG_ANALYTICS_ID=$(az monitor log-analytics workspace show -g $RG -n "${BASE}-logs" --query id -o tsv)
else
    log_result "Log Analytics: ${BASE}-logs" "FAIL" "Not found"
    attempt_fix "LogAnalytics" "Log Analytics workspace not found" "az monitor log-analytics workspace create -g $RG -n ${BASE}-logs -l $LOC"
    LOG_ANALYTICS_ID=$(az monitor log-analytics workspace show -g $RG -n "${BASE}-logs" --query id -o tsv 2>/dev/null)
fi

# Check App Insights
if az monitor app-insights component show -g $RG --app "${BASE}-ai" &> /dev/null; then
    log_result "App Insights: ${BASE}-ai" "PASS" "Exists"
    APP_INSIGHTS_ID=$(az monitor app-insights component show -g $RG --app "${BASE}-ai" --query id -o tsv)
    
    # Check if connected to Log Analytics
    CONNECTED_WORKSPACE=$(az monitor app-insights component show -g $RG --app "${BASE}-ai" --query workspaceResourceId -o tsv)
    if [ -n "$CONNECTED_WORKSPACE" ] && [ "$CONNECTED_WORKSPACE" == "$LOG_ANALYTICS_ID" ]; then
        log_result "App Insights Workspace Connection" "PASS" "Connected to Log Analytics"
    else
        log_result "App Insights Workspace Connection" "FAIL" "Not connected to Log Analytics properly"
        if [ -n "$LOG_ANALYTICS_ID" ]; then
            attempt_fix "AppInsights_Workspace" "Not connected to Log Analytics" "az monitor app-insights component update -g $RG --app ${BASE}-ai --workspace $LOG_ANALYTICS_ID"
        fi
    fi
else
    log_result "App Insights: ${BASE}-ai" "FAIL" "Not found"
    if [ -n "$LOG_ANALYTICS_ID" ]; then
        attempt_fix "AppInsights" "App Insights not found" "az monitor app-insights component create -g $RG -a ${BASE}-ai -l $LOC --workspace $LOG_ANALYTICS_ID"
    else
        log_to_context "AppInsightsFix" "skipped" "Cannot create App Insights: Log Analytics workspace not available"
    fi
fi

# 4. Check Key Vault
echo -e "\n=== Checking Key Vault ==="
if az keyvault show -g $RG -n "${BASE}-kv" &> /dev/null; then
    log_result "Key Vault: ${BASE}-kv" "PASS" "Exists"
    
    # Check Key Vault protection settings
    KV_PROPERTIES=$(az keyvault show -g $RG -n "${BASE}-kv")
    SOFT_DELETE=$(echo $KV_PROPERTIES | jq -r .properties.enableSoftDelete)
    PURGE_PROTECTION=$(echo $KV_PROPERTIES | jq -r .properties.enablePurgeProtection)
    RBAC_AUTH=$(echo $KV_PROPERTIES | jq -r .properties.enableRbacAuthorization)
    
    if [ "$SOFT_DELETE" = "true" ]; then
        log_result "Key Vault Soft Delete" "PASS" "Enabled"
    else
        log_result "Key Vault Soft Delete" "FAIL" "Disabled"
        # Note: Cannot enable soft delete on existing vault via CLI
        log_to_context "KeyVaultSoftDelete" "manual-fix-required" "Soft delete cannot be enabled on existing Key Vault via CLI. Manual fix required in portal."
    fi
    
    if [ "$PURGE_PROTECTION" = "true" ]; then
        log_result "Key Vault Purge Protection" "PASS" "Enabled"
    else
        log_result "Key Vault Purge Protection" "FAIL" "Disabled"
        attempt_fix "KeyVaultPurgeProtection" "Purge protection disabled" "az keyvault update -g $RG -n ${BASE}-kv --enable-purge-protection true"
    fi
    
    if [ "$RBAC_AUTH" = "true" ]; then
        log_result "Key Vault RBAC Authorization" "PASS" "Enabled"
    else
        log_result "Key Vault RBAC Authorization" "FAIL" "Disabled"
        # Note: Cannot change from access policy to RBAC once vault is created
        log_to_context "KeyVaultRBAC" "manual-fix-required" "Cannot change from access policies to RBAC on existing Key Vault. Manual migration required."
    fi
    
    # Check required secrets
    for secret in CosmosConn StorageConn; do
        if az keyvault secret show --vault-name "${BASE}-kv" -n "$secret" &> /dev/null; then
            log_result "Key Vault Secret: $secret" "PASS" "Exists"
        else
            log_result "Key Vault Secret: $secret" "FAIL" "Missing"
            log_to_context "KeyVaultSecret_$secret" "manual-fix-required" "Secret $secret is missing. Must be created with correct value."
        fi
    done
else
    log_result "Key Vault: ${BASE}-kv" "FAIL" "Not found"
    attempt_fix "KeyVault" "Key Vault not found" "az keyvault create -g $RG -n ${BASE}-kv -l $LOC --enable-soft-delete true --enable-purge-protection true --enable-rbac-authorization true"
fi

# 5. Check Cosmos DB
echo -e "\n=== Checking Cosmos DB ==="
if az cosmosdb show -g $RG -n "${BASE}-cosmos" &> /dev/null; then
    log_result "Cosmos DB: ${BASE}-cosmos" "PASS" "Exists"
    
    # Check backup type
    BACKUP_TYPE=$(az cosmosdb show -g $RG -n "${BASE}-cosmos" --query "backupPolicy.type" -o tsv)
    if [ "$BACKUP_TYPE" = "Continuous" ]; then
        log_result "Cosmos DB Backup Policy" "PASS" "Continuous backup enabled"
    else
        log_result "Cosmos DB Backup Policy" "FAIL" "Continuous backup not enabled (found: $BACKUP_TYPE)"
        attempt_fix "CosmosBackup" "Continuous backup not enabled" "az cosmosdb update -g $RG -n ${BASE}-cosmos --backup-policy-type Continuous"
    fi
    
    # Check database
    if az cosmosdb sql database show -g $RG -a "${BASE}-cosmos" -n "chatdb" &> /dev/null; then
        log_result "Cosmos DB Database: chatdb" "PASS" "Exists"
        
        # Check simplechat database - some commands refer to this one
        if ! az cosmosdb sql database show -g $RG -a "${BASE}-cosmos" -n "simplechat" &> /dev/null; then
            log_result "Cosmos DB Database: simplechat" "WARN" "Not found (but chatdb exists, this might be a naming inconsistency)"
            attempt_fix "CosmosDB_simplechat" "simplechat database missing" "az cosmosdb sql database create -g $RG -a ${BASE}-cosmos -n simplechat"
        fi
        
        # Check container in chatdb
        if az cosmosdb sql container show -g $RG -a "${BASE}-cosmos" -d "chatdb" -n "chats" &> /dev/null; then
            log_result "Cosmos DB Container: chatdb.chats" "PASS" "Exists"
        else
            log_result "Cosmos DB Container: chatdb.chats" "FAIL" "Not found"
            attempt_fix "CosmosContainer_chatdb" "Container chats missing in chatdb" "az cosmosdb sql container create -g $RG -a ${BASE}-cosmos -d chatdb -n chats --partition-key-path \"/sessionId\""
        fi
        
        # Check container in simplechat if it exists
        if az cosmosdb sql database show -g $RG -a "${BASE}-cosmos" -n "simplechat" &> /dev/null; then
            if az cosmosdb sql container show -g $RG -a "${BASE}-cosmos" -d "simplechat" -n "chats" &> /dev/null; then
                log_result "Cosmos DB Container: simplechat.chats" "PASS" "Exists"
            else
                log_result "Cosmos DB Container: simplechat.chats" "FAIL" "Not found"
                attempt_fix "CosmosContainer_simplechat" "Container chats missing in simplechat" "az cosmosdb sql container create -g $RG -a ${BASE}-cosmos -d simplechat -n chats --partition-key-path \"/sessionId\""
            fi
        fi
    else
        log_result "Cosmos DB Database: chatdb" "FAIL" "Not found"
        attempt_fix "CosmosDB_chatdb" "Database chatdb missing" "az cosmosdb sql database create -g $RG -a ${BASE}-cosmos -n chatdb"
    fi
    
    # Check analytical storage capabilities - this was problematic in logs
    CAPABILITIES=$(az cosmosdb show -g $RG -n "${BASE}-cosmos" --query "capabilities[].name" -o tsv)
    if echo "$CAPABILITIES" | grep -q "EnableAnalyticalStorage"; then
        log_result "Cosmos DB Analytical Storage" "PASS" "Enabled"
    else
        log_result "Cosmos DB Analytical Storage" "WARN" "Not enabled - this was noted as an issue in logs"
        log_to_context "CosmosAnalyticalStorage" "manual-fix-required" "Analytical storage could not be enabled via CLI. Requires recreation of Cosmos account or manual configuration."
    fi
else
    log_result "Cosmos DB: ${BASE}-cosmos" "FAIL" "Not found"
    attempt_fix "Cosmos" "Cosmos DB account not found" "az cosmosdb create -g $RG -n ${BASE}-cosmos --capabilities EnableServerless"
    # If Cosmos was created, try to create the database and container
    if [ $? -eq 0 ]; then
        attempt_fix "CosmosDB_chatdb_after_create" "Creating chatdb after Cosmos creation" "az cosmosdb sql database create -g $RG -a ${BASE}-cosmos -n chatdb"
        attempt_fix "CosmosDB_simplechat_after_create" "Creating simplechat after Cosmos creation" "az cosmosdb sql database create -g $RG -a ${BASE}-cosmos -n simplechat"
        attempt_fix "CosmosContainer_chatdb_after_create" "Creating chats container after Cosmos creation" "az cosmosdb sql container create -g $RG -a ${BASE}-cosmos -d chatdb -n chats --partition-key-path \"/sessionId\""
        attempt_fix "CosmosContainer_simplechat_after_create" "Creating chats container after Cosmos creation" "az cosmosdb sql container create -g $RG -a ${BASE}-cosmos -d simplechat -n chats --partition-key-path \"/sessionId\""
        attempt_fix "CosmosBackup_after_create" "Setting continuous backup after Cosmos creation" "az cosmosdb update -g $RG -n ${BASE}-cosmos --backup-policy-type Continuous"
    fi
fi

# 6. Check Storage Account
echo -e "\n=== Checking Storage Account ==="
if az storage account show -g $RG -n "${BASE}store" &> /dev/null; then
    log_result "Storage Account: ${BASE}store" "PASS" "Exists"
    
    # Check TLS version
    TLS_VERSION=$(az storage account show -g $RG -n "${BASE}store" --query "minimumTlsVersion" -o tsv)
    if [ "$TLS_VERSION" = "TLS1_2" ]; then
        log_result "Storage Account TLS Version" "PASS" "TLS 1.2 enforced"
    else
        log_result "Storage Account TLS Version" "FAIL" "TLS 1.2 not enforced (found: $TLS_VERSION)"
        attempt_fix "StorageTLS" "TLS 1.2 not enforced" "az storage account update -g $RG -n ${BASE}store --min-tls-version TLS1_2"
    fi
    
    # Check network access
    PUBLIC_ACCESS=$(az storage account show -g $RG -n "${BASE}store" --query "publicNetworkAccess" -o tsv)
    if [ "$PUBLIC_ACCESS" = "Enabled" ]; then
        log_result "Storage Account Public Access" "PASS" "Enabled as per architecture doc"
    else
        log_result "Storage Account Public Access" "FAIL" "Not enabled (found: $PUBLIC_ACCESS)"
        attempt_fix "StoragePublicAccess" "Public network access not enabled" "az storage account update -g $RG -n ${BASE}store --public-network-access Enabled"
    fi
else
    log_result "Storage Account: ${BASE}store" "FAIL" "Not found"
    attempt_fix "Storage" "Storage account not found" "az storage account create -g $RG -n ${BASE}store -l $LOC --sku Standard_LRS --kind StorageV2 --min-tls-version TLS1_2 --public-network-access Enabled"
    
    if [ $? -eq 0 ]; then
        # If we created the storage account, try to save the connection string to Key Vault
        STORAGE_CONN=$(az storage account show-connection-string -g $RG -n ${BASE}store --query connectionString -o tsv 2>/dev/null)
        if [ -n "$STORAGE_CONN" ] && az keyvault show -g $RG -n "${BASE}-kv" &> /dev/null; then
            attempt_fix "StorageConnSecret" "Adding storage connection string to Key Vault" "az keyvault secret set --vault-name ${BASE}-kv -n StorageConn --value \"$STORAGE_CONN\""
        fi
    fi
fi

# 7. Check App Service
echo -e "\n=== Checking App Service ==="
# Check App Service Plan
if az appservice plan show -g $RG -n "${BASE}-plan" &> /dev/null; then
    log_result "App Service Plan: ${BASE}-plan" "PASS" "Exists"
    
    # Check SKU
    SKU=$(az appservice plan show -g $RG -n "${BASE}-plan" --query sku.name -o tsv)
    if [ "$SKU" = "P1v3" ]; then
        log_result "App Service Plan SKU" "PASS" "P1v3 as specified"
    else
        log_result "App Service Plan SKU" "FAIL" "Not P1v3 (found: $SKU)"
        log_to_context "AppServicePlanSKU" "manual-fix-required" "App Service Plan SKU should be P1v3, currently $SKU. Manual scaling required."
    fi
    
    # Check if Linux
    IS_LINUX=$(az appservice plan show -g $RG -n "${BASE}-plan" --query reserved -o tsv)
    if [ "$IS_LINUX" = "true" ]; then
        log_result "App Service Plan OS" "PASS" "Linux as specified"
    else
        log_result "App Service Plan OS" "FAIL" "Not Linux"
        log_to_context "AppServicePlanOS" "manual-fix-required" "App Service Plan is not Linux. Cannot change OS of existing plan, requires recreation."
    fi
else
    log_result "App Service Plan: ${BASE}-plan" "FAIL" "Not found"
    attempt_fix "AppServicePlan" "App Service Plan not found" "az appservice plan create -g $RG -n ${BASE}-plan --sku P1v3 --is-linux -l $LOC"
fi

# Check Web App
if az webapp show -g $RG -n "${BASE}-app" &> /dev/null; then
    log_result "Web App: ${BASE}-app" "PASS" "Exists"
    
    # Check identity
    IDENTITY=$(az webapp.identity show -g $RG -n "${BASE}-app" 2>/dev/null)
    if [ $? -eq 0 ] && [ -n "$IDENTITY" ]; then
        log_result "Web App Managed Identity" "PASS" "Enabled"
    else
        log_result "Web App Managed Identity" "FAIL" "Not enabled"
        attempt_fix "WebAppIdentity" "Managed identity not enabled" "az webapp identity assign -g $RG -n ${BASE}-app"
    fi
    
    # Check app settings for KeyVault references
    APP_SETTINGS=$(az webapp config appsettings list -g $RG -n "${BASE}-app")
    if echo "$APP_SETTINGS" | jq -e '.[] | select(.name=="CosmosConn" and .value | contains("@Microsoft.KeyVault"))' > /dev/null; then
        log_result "Web App KeyVault Reference" "PASS" "CosmosConn correctly references KeyVault"
    else
        log_result "Web App KeyVault Reference" "FAIL" "CosmosConn does not reference KeyVault correctly"
        attempt_fix "WebAppKeyVaultRef" "KeyVault reference missing" "az webapp config appsettings set -g $RG -n ${BASE}-app --settings CosmosConn='@Microsoft.KeyVault(VaultName=${BASE}-kv;SecretName=CosmosConn)'"
    fi
    
    # Check staging slot
    if az webapp deployment slot show -g $RG -n "${BASE}-app" -s "staging" &> /dev/null; then
        log_result "Web App Staging Slot" "PASS" "Exists"
    else
        log_result "Web App Staging Slot" "FAIL" "Not found"
        attempt_fix "WebAppStagingSlot" "Staging slot not found" "az webapp deployment slot create -g $RG -n ${BASE}-app -s staging"
    fi
else
    log_result "Web App: ${BASE}-app" "FAIL" "Not found"
    # Too complex to auto-create from scratch, need to know runtime, etc.
    log_to_context "WebApp" "manual-fix-required" "Web App ${BASE}-app not found. Required deployment from original script."
fi

# 8. Check Front Door
echo -e "\n=== Checking Front Door ==="
if az afd profile show -g $RG -n "${BASE}-afd" &> /dev/null; then
    log_result "Front Door Profile: ${BASE}-afd" "PASS" "Exists"
    
    # Check SKU
    AFD_SKU=$(az afd profile show -g $RG -n "${BASE}-afd" --query sku.name -o tsv)
    if [ "$AFD_SKU" = "Premium_AzureFrontDoor" ]; then
        log_result "Front Door SKU" "PASS" "Premium as specified"
    else
        log_result "Front Door SKU" "FAIL" "Not Premium (found: $AFD_SKU)"
        log_to_context "FrontDoorSKU" "manual-fix-required" "Cannot change Front Door SKU after creation. Required Premium_AzureFrontDoor."
    fi
    
    # Check endpoint
    if az afd endpoint show -g $RG --profile-name "${BASE}-afd" -n "chat-ep" &> /dev/null; then
        log_result "Front Door Endpoint: chat-ep" "PASS" "Exists"
        
        # Check WAF Policy assignment
        WAF_POLICY=$(az afd endpoint show -g $RG --profile-name "${BASE}-afd" -n "chat-ep" --query webApplicationFirewallPolicyLink.id -o tsv)
        if [ -n "$WAF_POLICY" ] && [[ "$WAF_POLICY" == */chat-waf ]]; then
            log_result "Front Door WAF Policy Assignment" "PASS" "WAF policy assigned"
        else
            log_result "Front Door WAF Policy Assignment" "WARN" "WAF policy may not be assigned correctly (was identified as an issue in logs)"
            log_to_context "WAFPolicyAssignment" "manual-fix-required" "WAF policy assignment to Front Door endpoint needs manual verification and possible fix."
        fi
    else
        log_result "Front Door Endpoint: chat-ep" "FAIL" "Not found"
        attempt_fix "FrontDoorEndpoint" "Front Door endpoint not found" "az afd endpoint create -g $RG --profile-name ${BASE}-afd -n chat-ep"
    fi
    
    # Check origin group and origin
    if az afd origin-group show -g $RG --profile-name "${BASE}-afd" -n "og-app" &> /dev/null; then
        log_result "Front Door Origin Group: og-app" "PASS" "Exists"
        
        # Check origin
        if az afd origin show -g $RG --profile-name "${BASE}-afd" --origin-group-name "og-app" -n "chat-origin" &> /dev/null; then
            log_result "Front Door Origin: chat-origin" "PASS" "Exists"
            
            # Check host name
            ORIGIN_HOST=$(az afd origin show -g $RG --profile-name "${BASE}-afd" --origin-group-name "og-app" -n "chat-origin" --query hostName -o tsv)
            EXPECTED_HOST="${BASE}-app.azurewebsites.net"
            if [ "$ORIGIN_HOST" = "$EXPECTED_HOST" ]; then
                log_result "Front Door Origin Host" "PASS" "Correctly points to App Service"
            else
                log_result "Front Door Origin Host" "FAIL" "Does not point to correct App Service (expected: $EXPECTED_HOST, found: $ORIGIN_HOST)"
                attempt_fix "FrontDoorOriginHost" "Incorrect origin host" "az afd origin update -g $RG --profile-name ${BASE}-afd --origin-group-name og-app -n chat-origin --host-name ${BASE}-app.azurewebsites.net"
            fi
        else
            log_result "Front Door Origin: chat-origin" "FAIL" "Not found"
            attempt_fix "FrontDoorOrigin" "Origin not found" "az afd origin create -g $RG --profile-name ${BASE}-afd --origin-group-name og-app -n chat-origin --host-name ${BASE}-app.azurewebsites.net --priority 1 --weight 100"
        fi
    else
        log_result "Front Door Origin Group: og-app" "FAIL" "Not found"
        attempt_fix "FrontDoorOriginGroup" "Origin group not found" "az afd origin-group create -g $RG --profile-name ${BASE}-afd -n og-app --origin-type app-service"
    fi
    
    # Check route - check both possible names based on logs
    if az afd route list -g $RG --profile-name "${BASE}-afd" --endpoint-name "chat-ep" --query "[?name=='chatroute' || name=='https-route']" -o tsv | grep -q "."; then
        log_result "Front Door Route" "PASS" "Exists (either as 'chatroute' or 'https-route')"
    else
        log_result "Front Door Route" "FAIL" "Not found (neither 'chatroute' nor 'https-route' exists)"
        attempt_fix "FrontDoorRoute" "Route not found" "az afd route create -g $RG --profile-name ${BASE}-afd --endpoint-name chat-ep -n https-route --origin-group og-app --supported-protocols Https --patterns \"/*\" --forwarding-protocol HttpsOnly"
    fi
    
    # Check WAF policy
    if az afd waf-policy show -g $RG --profile-name "${BASE}-afd" -n "chat-waf" &> /dev/null; then
        log_result "Front Door WAF Policy: chat-waf" "PASS" "Exists"
        
        # Check WAF mode
        WAF_MODE=$(az afd waf-policy show -g $RG --profile-name "${BASE}-afd" -n "chat-waf" --query "policySettings.mode" -o tsv)
        if [ "$WAF_MODE" = "Prevention" ]; then
            log_result "Front Door WAF Mode" "PASS" "Set to Prevention"
        else
            log_result "Front Door WAF Mode" "FAIL" "Not set to Prevention (found: $WAF_MODE)"
            log_to_context "WAFMode" "manual-fix-required" "Front Door WAF policy mode needs to be set to Prevention. Check manual steps."
        fi
    else
        log_result "Front Door WAF Policy: chat-waf" "WARN" "Not found - this was noted as an issue in logs, may be managed manually"
        log_to_context "WAFPolicy" "manual-fix-required" "WAF policy missing. See manual-steps-o4.md for configuration instructions."
    fi
else
    log_result "Front Door Profile: ${BASE}-afd" "FAIL" "Not found"
    attempt_fix "FrontDoor" "Front Door profile not found" "az afd profile create -g $RG -n ${BASE}-afd --sku Premium_AzureFrontDoor"
    # If Front Door creation succeeded, try to create the endpoint
    if [ $? -eq 0 ]; then
        attempt_fix "FrontDoorEndpoint_after_create" "Creating endpoint after profile creation" "az afd endpoint create -g $RG --profile-name ${BASE}-afd -n chat-ep"
    fi
    log_to_context "FrontDoor" "manual-fix-required" "Multiple Front Door components need to be created and configured."
fi

# 9. Check AI Services
echo -e "\n=== Checking AI Services ==="

# Check OpenAI
if az cognitiveservices account show -g $RG -n "${BASE}-openai" &> /dev/null; then
    log_result "OpenAI: ${BASE}-openai" "PASS" "Exists"
    
    # Check kind
    AI_KIND=$(az cognitiveservices account show -g $RG -n "${BASE}-openai" --query kind -o tsv)
    if [ "$AI_KIND" = "OpenAI" ]; then
        log_result "OpenAI Kind" "PASS" "Correct kind"
    else
        log_result "OpenAI Kind" "FAIL" "Incorrect kind (found: $AI_KIND)"
        log_to_context "OpenAIKind" "manual-fix-required" "OpenAI resource has incorrect kind. Cannot be changed after creation."
    fi
    
    # Models cannot be checked through CLI easily, note as manual check
    log_result "OpenAI Models (GPT-4o, GPT-4 Turbo)" "WARN" "Requires manual verification in Azure Portal"
    log_to_context "OpenAIModels" "manual-verification-required" "Verify GPT-4o and GPT-4 Turbo models are deployed as specified in manual-steps-o4.md"
else
    log_result "OpenAI: ${BASE}-openai" "FAIL" "Not found"
    attempt_fix "OpenAI" "OpenAI resource not found" "az cognitiveservices account create -g $RG -n ${BASE}-openai -l $LOC --kind OpenAI --sku S0"
    log_to_context "OpenAIModels" "manual-step-required" "OpenAI models need to be deployed per manual-steps-o4.md"
fi

# Check Document Intelligence
if az cognitiveservices account show -g $RG -n "${BASE}-docint" &> /dev/null; then
    log_result "Document Intelligence: ${BASE}-docint" "PASS" "Exists"
    
    # Check kind
    DOCINT_KIND=$(az cognitiveservices account show -g $RG -n "${BASE}-docint" --query kind -o tsv)
    if [ "$DOCINT_KIND" = "FormRecognizer" ]; then
        log_result "Document Intelligence Kind" "PASS" "Correct kind (FormRecognizer)"
    else
        log_result "Document Intelligence Kind" "FAIL" "Incorrect kind (found: $DOCINT_KIND)"
        log_to_context "DocIntKind" "manual-fix-required" "Document Intelligence resource has incorrect kind. Cannot be changed after creation."
    fi
else
    log_result "Document Intelligence: ${BASE}-docint" "FAIL" "Not found"
    attempt_fix "DocInt" "Document Intelligence not found" "az cognitiveservices account create -g $RG -n ${BASE}-docint -l $LOC --kind FormRecognizer --sku S0"
    
    # If created, assign managed identity
    if [ $? -eq 0 ]; then
        attempt_fix "DocIntIdentity" "Assign managed identity to Document Intelligence" "az cognitiveservices account identity assign --name ${BASE}-docint --resource-group $RG"
        
        # Set up diagnostics if Log Analytics exists
        if [ -n "$LOG_ANALYTICS_ID" ]; then
            attempt_fix "DocIntDiagnostics" "Setting up diagnostics" "az monitor diagnostic-settings create --name ${BASE}-docint-diag --resource $(az cognitiveservices account show --name ${BASE}-docint --resource-group $RG --query id -o tsv) --workspace $LOG_ANALYTICS_ID --logs \"*\" --metrics \"*\""
        fi
    fi
fi

# Check Speech Service
if az cognitiveservices account show -g $RG -n "${BASE}-speech" &> /dev/null; then
    log_result "Speech Service: ${BASE}-speech" "PASS" "Exists"
    
    # Check kind
    SPEECH_KIND=$(az cognitiveservices account show -g $RG -n "${BASE}-speech" --query kind -o tsv)
    if [ "$SPEECH_KIND" = "SpeechServices" ]; then
        log_result "Speech Service Kind" "PASS" "Correct kind"
    else
        log_result "Speech Service Kind" "FAIL" "Incorrect kind (found: $SPEECH_KIND)"
        log_to_context "SpeechKind" "manual-fix-required" "Speech Service resource has incorrect kind. Cannot be changed after creation."
    fi
else
    log_result "Speech Service: ${BASE}-speech" "FAIL" "Not found"
    attempt_fix "Speech" "Speech Service not found" "az cognitiveservices account create --name ${BASE}-speech --resource-group $RG --kind SpeechServices --sku S0 --location $LOC --yes"
    
    # If created, assign managed identity
    if [ $? -eq 0 ]; then
        attempt_fix "SpeechIdentity" "Assign managed identity to Speech Service" "az cognitiveservices account identity assign --name ${BASE}-speech --resource-group $RG"
        
        # Set up diagnostics if Log Analytics exists
        if [ -n "$LOG_ANALYTICS_ID" ]; then
            attempt_fix "SpeechDiagnostics" "Setting up diagnostics" "az monitor diagnostic-settings create --name ${BASE}-speech-diag --resource $(az cognitiveservices account show --name ${BASE}-speech --resource-group $RG --query id -o tsv) --workspace $LOG_ANALYTICS_ID --logs \"*\" --metrics \"*\""
        fi
    fi
fi

# Check AI Search
if az search service show -g $RG -n "${BASE}-search" &> /dev/null; then
    log_result "AI Search: ${BASE}-search" "PASS" "Exists"
    
    # Check SKU
    SEARCH_SKU=$(az search service show -g $RG -n "${BASE}-search" --query sku.name -o tsv)
    if [ "$SEARCH_SKU" = "standard" ]; then
        log_result "AI Search SKU" "PASS" "Standard as specified"
    else
        log_result "AI Search SKU" "FAIL" "Not Standard (found: $SEARCH_SKU)"
        log_to_context "SearchSKU" "manual-fix-required" "AI Search SKU is not Standard. Cannot be changed after creation."
    fi
    
    # Check managed identity
    SEARCH_IDENTITY=$(az search service show -g $RG -n "${BASE}-search" --query identity.type -o tsv 2>/dev/null)
    if [ "$SEARCH_IDENTITY" = "SystemAssigned" ]; then
        log_result "AI Search Managed Identity" "PASS" "System-assigned identity enabled"
    else
        log_result "AI Search Managed Identity" "FAIL" "System-assigned identity not enabled"
        attempt_fix "SearchIdentity" "System-assigned identity not enabled" "az search service update --name ${BASE}-search --resource-group $RG --identity-type SystemAssigned"
    fi
else
    log_result "AI Search: ${BASE}-search" "FAIL" "Not found"
    attempt_fix "AISearch" "AI Search not found" "az search service create --name ${BASE}-search --resource-group $RG --location $LOC --sku Standard"
    
    # If created, assign managed identity
    if [ $? -eq 0 ]; then
        attempt_fix "SearchIdentity_after_create" "Assign managed identity to AI Search" "az search service update --name ${BASE}-search --resource-group $RG --identity-type SystemAssigned"
        
        # Set up diagnostics if Log Analytics exists
        if [ -n "$LOG_ANALYTICS_ID" ]; then
            attempt_fix "SearchDiagnostics" "Setting up diagnostics" "az monitor diagnostic-settings create --name ${BASE}-search-diag --resource $(az search service show --name ${BASE}-search --resource-group $RG --query id -o tsv) --workspace $LOG_ANALYTICS_ID --logs \"*\" --metrics \"*\""
        fi
    fi
fi

# 10. Check Defender for Cloud
echo -e "\n=== Checking Defender for Cloud ==="
DEFENDER_STATUS=$(az security pricing show -n "AppServices" --query "pricingTier" -o tsv 2>/dev/null)
if [ "$DEFENDER_STATUS" = "Standard" ]; then
    log_result "Defender for AppServices" "PASS" "Standard tier enabled"
else
    log_result "Defender for AppServices" "WARN" "Standard tier may not be enabled"
    log_to_context "DefenderAppServices" "manual-verification-required" "Verify Defender for AppServices is enabled with Standard tier"
    attempt_fix "DefenderAppServices" "Standard tier not enabled" "az security pricing create --name AppServices --tier Standard"
fi

# Check required Defender services
for svc in CosmosDbs StorageAccounts ContainerRegistry; do
    DEFENDER_SVC_STATUS=$(az security pricing show -n "$svc" --query "pricingTier" -o tsv 2>/dev/null)
    if [ "$DEFENDER_SVC_STATUS" = "Standard" ]; then
        log_result "Defender for $svc" "PASS" "Standard tier enabled"
    else
        log_result "Defender for $svc" "WARN" "Standard tier may not be enabled"
        attempt_fix "Defender$svc" "Standard tier not enabled" "az security pricing create --name $svc --tier Standard"
    fi
done

# 11. Check Tag Policy
echo -e "\n=== Checking Tag Policy ==="
if az policy assignment show -g $RG -n "RequireTagsEnforced" &> /dev/null; then
    log_result "Tag Policy Assignment" "PASS" "RequireTagsEnforced policy is assigned to resource group"
else
    log_result "Tag Policy Assignment" "FAIL" "RequireTagsEnforced policy is not assigned to resource group"
    # Check if policy definition exists
    if az policy definition show -n RequireTags &> /dev/null; then
        attempt_fix "TagPolicyAssignment" "Policy exists but not assigned" "az policy assignment create --policy RequireTags -g $RG -n RequireTagsEnforced"
    else
        log_to_context "TagPolicyDefinition" "manual-fix-required" "RequireTags policy definition is missing. Needs to be created from tag-rule.json file."
    fi
fi

# 12. Perform connectivity tests
echo -e "\n=== Performing Connectivity Tests ==="

# Front Door endpoint connectivity
FD_ENDPOINT=$(az afd endpoint show -g $RG --profile-name "${BASE}-afd" -n "chat-ep" --query hostName -o tsv 2>/dev/null)
if [ -n "$FD_ENDPOINT" ]; then
    echo "Testing Front Door endpoint: $FD_ENDPOINT"
    if curl -s -o /dev/null -w "%{http_code}" "https://$FD_ENDPOINT" | grep -q -E "^[2-3][0-9][0-9]$"; then
        log_result "Front Door Connectivity" "PASS" "Successfully connected to endpoint"
    else
        log_result "Front Door Connectivity" "WARN" "Could not connect to endpoint or received non-2xx/3xx response"
        log_to_context "FrontDoorConnectivity" "manual-verification-required" "Front Door endpoint connectivity check failed. Verify routing and origin health."
    fi
else
    log_result "Front Door Connectivity" "WARN" "Could not retrieve Front Door endpoint hostname"
    log_to_context "FrontDoorHostname" "manual-verification-required" "Could not determine Front Door endpoint hostname for connectivity check"
fi

# App Service connectivity
APP_ENDPOINT="${BASE}-app.azurewebsites.net"
echo "Testing App Service endpoint: $APP_ENDPOINT"
if curl -s -o /dev/null -w "%{http_code}" "https://$APP_ENDPOINT" | grep -q -E "^[2-3][0-9][0-9]$"; then
    log_result "App Service Connectivity" "PASS" "Successfully connected to endpoint"
else
    log_result "App Service Connectivity" "WARN" "Could not connect to endpoint or received non-2xx/3xx response"
    log_to_context "AppServiceConnectivity" "manual-verification-required" "App Service endpoint connectivity check failed. Verify app is deployed and running."
fi

# 13. Key Vault References Check
echo -e "\n=== Checking Key Vault References in App Settings ==="

# Get the App Service's current settings
if az webapp show -g $RG -n "${BASE}-app" &> /dev/null; then
    APP_SETTINGS=$(az webapp config appsettings list -g $RG -n "${BASE}-app" -o json)
    
    # Check for common settings that should reference Key Vault
    for setting in "CosmosConn" "StorageConn" "OpenAIKey" "SearchKey" "DocIntKey" "SpeechKey"; do
        if echo "$APP_SETTINGS" | jq -e ".[] | select(.name==\"$setting\" and .value | contains(\"@Microsoft.KeyVault\"))" > /dev/null; then
            log_result "Key Vault Reference: $setting" "PASS" "App setting correctly references Key Vault"
        elif echo "$APP_SETTINGS" | jq -e ".[] | select(.name==\"$setting\")" > /dev/null; then
            # Setting exists but not as Key Vault reference
            log_result "Key Vault Reference: $setting" "WARN" "App setting exists but does not reference Key Vault"
            log_to_context "AppSettingKeyVault_$setting" "manual-fix-recommended" "App setting $setting should reference Key Vault for security"
        fi
    done
fi

# 14. Summary
echo -e "\n=== Verification Summary ==="
PASS_COUNT=$(grep -c '"result":"PASS"' verification-results.json)
FAIL_COUNT=$(grep -c '"result":"FAIL"' verification-results.json)
WARN_COUNT=$(grep -c '"result":"WARN"' verification-results.json)
TOTAL_COUNT=$((PASS_COUNT + FAIL_COUNT + WARN_COUNT))

echo -e "${GREEN}PASS: $PASS_COUNT${NC}"
echo -e "${RED}FAIL: $FAIL_COUNT${NC}"
echo -e "${YELLOW}WARN: $WARN_COUNT${NC}"
echo "TOTAL: $TOTAL_COUNT"

log_to_context "VerificationSummary" "completed" "Verification completed with $PASS_COUNT passed, $FAIL_COUNT failed, and $WARN_COUNT warnings"

if [ $FAIL_COUNT -eq 0 ]; then
    echo -e "\n${GREEN}Verification completed successfully!${NC}"
    echo "Review any WARN items as they may require manual checks or are known limitations."
    log_to_context "VerificationResult" "success" "Verification completed successfully. Review any warnings for manual steps."
else
    echo -e "\n${RED}Verification completed with errors.${NC}"
    echo "Please address the FAIL items before proceeding with deployment."
    log_to_context "VerificationResult" "error" "$FAIL_COUNT failures detected. Address these issues before proceeding with deployment."
fi

echo "Full results are available in verification-results.json"
echo "Issues have been logged to $CONTEXT_LOG"

# Generate a list of required manual actions
echo -e "\n=== Required Manual Actions ==="
echo "{\"timestamp\":\"$(date -u +%FT%TZ)\",\"manual_actions\":["  > manual-actions-required.json
grep "manual-fix\|manual-verification" "$CONTEXT_LOG" | tail -10 | jq -r '.task + ": " + .details' | while read line; do
    echo "- $line"
    echo "\"$line\"," >> manual-actions-required.json
done
sed -i '$ s/,$//' manual-actions-required.json
echo "]}" >> manual-actions-required.json

# Create Azure Portal deep links for manual fixes
echo -e "\n=== Azure Portal Deep Links ==="
echo "Key Vault: https://portal.azure.com/#@/resource/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RG/providers/Microsoft.KeyVault/vaults/${BASE}-kv"
echo "App Service: https://portal.azure.com/#@/resource/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RG/providers/Microsoft.Web/sites/${BASE}-app"
echo "Front Door: https://portal.azure.com/#@/resource/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RG/providers/Microsoft.Cdn/profiles/${BASE}-afd"
echo "OpenAI Service: https://portal.azure.com/#@/resource/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RG/providers/Microsoft.CognitiveServices/accounts/${BASE}-openai"
echo "Cosmos DB: https://portal.azure.com/#@/resource/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RG/providers/Microsoft.DocumentDB/databaseAccounts/${BASE}-cosmos"