#!/bin/bash
# PippAI2 Configuration Script
# Date: 2025-05-20
# This script updates Key Vault secrets, validates configurations, and performs housekeeping tasks

# Set error handling
set -e
echo "Starting PippAI2 configuration script at $(date)"

# Set environment variables
BASE=pippaioflondoncdx2
RG=$BASE
KV="${BASE}-kv"
echo "Base name: $BASE"
echo "Resource Group: $RG"
echo "Key Vault: $KV"

echo "----------------------------------------"
echo "1. Validating Azure resources"
echo "----------------------------------------"

# Verify resource group exists
echo "Checking resource group..."
az group show --name $RG > /dev/null
echo "✅ Resource group exists"

# Verify Key Vault exists
echo "Checking Key Vault..."
az keyvault show --name $KV --resource-group $RG > /dev/null
echo "✅ Key Vault exists"

# Verify App Service is Linux (using the correct method)
echo "Checking App Service type..."
APP_KIND=$(az webapp show --name ${BASE}-app --resource-group $RG --query kind -o tsv)
if [[ "$APP_KIND" == *"linux"* ]]; then
    echo "✅ App Service is correctly configured as Linux (kind: $APP_KIND)"
else
    echo "⚠️ App Service may not be configured as Linux (kind: $APP_KIND)"
    echo "Checking alternative method (reserved property)..."
    
    IS_LINUX=$(az webapp show --name ${BASE}-app --resource-group $RG --query reserved -o tsv)
    if [ "$IS_LINUX" == "true" ]; then
        echo "✅ App Service is confirmed as Linux via reserved property"
    else
        echo "❌ App Service is not Linux. This may cause deployment issues."
        echo "Consider recreating the App Service as Linux."
        exit 1
    fi
fi

echo "----------------------------------------"
echo "2. Setting up Key Vault secrets"
echo "----------------------------------------"

# Define all required endpoints and secrets
echo "Setting up OpenAI endpoints..."

# Primary AI endpoint for most models (including DALL-E) - all in Sweden
AI_ENDPOINT="https://pippaioflondoncdx2-foundry.cognitiveservices.azure.com"
echo "Setting OpenAIEndpoint to $AI_ENDPOINT"
az keyvault secret set --vault-name $KV -n OpenAIEndpoint --value "$AI_ENDPOINT"

# Text-to-image specific endpoint (newer version, separate from DALL-E)
TEXT_TO_IMAGE_ENDPOINT="https://anton-mawwj0d2-westus3.cognitiveservices.azure.com"
echo "Setting TextToImageEndpoint to $TEXT_TO_IMAGE_ENDPOINT"
az keyvault secret set --vault-name $KV -n TextToImageEndpoint --value "$TEXT_TO_IMAGE_ENDPOINT"

# Also set DALL-E endpoint (same as AI endpoint, since it's in Sweden)
echo "Setting DALLEEndpoint to $AI_ENDPOINT (hosted in Sweden with other AI assets)"
az keyvault secret set --vault-name $KV -n DALLEEndpoint --value "$AI_ENDPOINT"

# Get OpenAI key (for AI models including DALL-E)
echo "Getting OpenAI keys..."
OPENAI_KEY=$(az cognitiveservices account keys list -g $RG -n ${BASE}-foundry --query key1 -o tsv)
echo "Setting OpenAIKey"
az keyvault secret set --vault-name $KV -n OpenAIKey --value "$OPENAI_KEY"
echo "Setting DALLEKey (same as OpenAIKey)"
az keyvault secret set --vault-name $KV -n DALLEKey --value "$OPENAI_KEY"

# Get Text-to-image key
echo "Getting Text-to-image key..."
TEXT_TO_IMAGE_KEY=$(az cognitiveservices account keys list -g $RG -n anton-mawwj0d2 --query key1 -o tsv 2>/dev/null || echo "MANUAL_INTERVENTION_REQUIRED")
if [ "$TEXT_TO_IMAGE_KEY" == "MANUAL_INTERVENTION_REQUIRED" ]; then
    echo "⚠️ Unable to automatically retrieve the Text-to-image key."
    echo "Please enter the Text-to-image API key manually:"
    read TEXT_TO_IMAGE_KEY
    if [ -z "$TEXT_TO_IMAGE_KEY" ]; then
        echo "No key provided, skipping TextToImageKey setup"
    else
        echo "Setting TextToImageKey with provided value"
        az keyvault secret set --vault-name $KV -n TextToImageKey --value "$TEXT_TO_IMAGE_KEY"
    fi
else
    echo "Setting TextToImageKey"
    az keyvault secret set --vault-name $KV -n TextToImageKey --value "$TEXT_TO_IMAGE_KEY"
fi

# Get Cosmos DB connection string and endpoint
echo "Getting Cosmos DB connection details..."
COSMOS_CONN=$(az cosmosdb keys list -g $RG -n ${BASE}-cosmos --type connection-strings --query connectionStrings[0].connectionString -o tsv)
COSMOS_ENDPOINT=$(az cosmosdb show -g $RG -n ${BASE}-cosmos --query documentEndpoint -o tsv)

# Store in Key Vault with correct names
echo "Setting CosmosConn"
az keyvault secret set --vault-name $KV -n CosmosConn --value "$COSMOS_CONN"
echo "Setting CosmosEndpoint"
az keyvault secret set --vault-name $KV -n CosmosEndpoint --value "$COSMOS_ENDPOINT"

# Get Storage connection string
echo "Getting Storage connection string..."
STORAGE_CONN=$(az storage account show-connection-string -g $RG -n ${BASE}store --query connectionString -o tsv)
echo "Setting StorageConn"
az keyvault secret set --vault-name $KV -n StorageConn --value "$STORAGE_CONN"

# For backward compatibility, use valid names
echo "Setting STORAGE-CONNECTION-STRING (for backward compatibility)"
az keyvault secret set --vault-name $KV -n STORAGE-CONNECTION-STRING --value "$STORAGE_CONN"
echo "Setting STORAGECONNECTIONSTRING (for backward compatibility)"
az keyvault secret set --vault-name $KV -n STORAGECONNECTIONSTRING --value "$STORAGE_CONN"

# Store model information
echo "Setting up model configuration information..."
az keyvault secret set --vault-name $KV -n ChatModelName --value "gpt-4o"
az keyvault secret set --vault-name $KV -n EmbeddingModelName --value "text-embedding-large"
az keyvault secret set --vault-name $KV -n ImageModelName --value "dalle3"
az keyvault secret set --vault-name $KV -n AudioModelName --value "whisper"
az keyvault secret set --vault-name $KV -n ApiVersion --value "2025-01-01-preview"

echo "----------------------------------------"
echo "3. Verifying and standardizing Cosmos DB configuration"
echo "----------------------------------------"

# Check which databases exist
echo "Checking Cosmos DB databases..."
CHATDB_EXISTS=$(az cosmosdb sql database show -g $RG -a ${BASE}-cosmos -n chatdb &>/dev/null && echo "true" || echo "false")
SIMPLECHAT_EXISTS=$(az cosmosdb sql database show -g $RG -a ${BASE}-cosmos -n simplechat &>/dev/null && echo "true" || echo "false")

# Report on database standardization
if [[ "$CHATDB_EXISTS" == "true" && "$SIMPLECHAT_EXISTS" == "true" ]]; then
    echo "Both 'chatdb' and 'simplechat' databases exist."
    echo "Using 'simplechat' as the standard database."
    
    # Store the standard database name in Key Vault
    az keyvault secret set --vault-name $KV -n CosmosDbName --value "simplechat"
    
    # Check containers in both databases and report
    CHATDB_CONTAINERS=$(az cosmosdb sql container list -g $RG -a ${BASE}-cosmos -d chatdb --query "[].id" -o tsv)
    SIMPLECHAT_CONTAINERS=$(az cosmosdb sql container list -g $RG -a ${BASE}-cosmos -d simplechat --query "[].id" -o tsv)
    
    echo "chatdb containers: $CHATDB_CONTAINERS"
    echo "simplechat containers: $SIMPLECHAT_CONTAINERS"
    
elif [ "$CHATDB_EXISTS" == "true" ]; then
    echo "Only 'chatdb' database exists."
    echo "Using 'chatdb' as the standard database."
    
    # Store the standard database name in Key Vault
    az keyvault secret set --vault-name $KV -n CosmosDbName --value "chatdb"
    
    # List containers
    CHATDB_CONTAINERS=$(az cosmosdb sql container list -g $RG -a ${BASE}-cosmos -d chatdb --query "[].id" -o tsv)
    echo "chatdb containers: $CHATDB_CONTAINERS"
    
elif [ "$SIMPLECHAT_EXISTS" == "true" ]; then
    echo "Only 'simplechat' database exists."
    echo "Using 'simplechat' as the standard database."
    
    # Store the standard database name in Key Vault
    az keyvault secret set --vault-name $KV -n CosmosDbName --value "simplechat"
    
    # List containers
    SIMPLECHAT_CONTAINERS=$(az cosmosdb sql container list -g $RG -a ${BASE}-cosmos -d simplechat --query "[].id" -o tsv)
    echo "simplechat containers: $SIMPLECHAT_CONTAINERS"
    
else
    echo "Neither 'chatdb' nor 'simplechat' database exists."
    echo "Creating 'simplechat' database..."
    az cosmosdb sql database create -g $RG -a ${BASE}-cosmos -n simplechat
    
    # Create chats container
    echo "Creating 'chats' container in 'simplechat' database..."
    az cosmosdb sql container create -g $RG -a ${BASE}-cosmos -d simplechat -n chats --partition-key-path "/sessionId"
    
    # Store the standard database name in Key Vault
    az keyvault secret set --vault-name $KV -n CosmosDbName --value "simplechat"
    
    echo "simplechat containers: chats"
fi

# Ensure chats container exists in the standard database
STANDARD_DB=$(az keyvault secret show --vault-name $KV -n CosmosDbName --query value -o tsv)
CHATS_EXISTS=$(az cosmosdb sql container show -g $RG -a ${BASE}-cosmos -d $STANDARD_DB -n chats &>/dev/null && echo "true" || echo "false")
if [ "$CHATS_EXISTS" == "false" ]; then
    echo "Creating 'chats' container in '$STANDARD_DB' database..."
    az cosmosdb sql container create -g $RG -a ${BASE}-cosmos -d $STANDARD_DB -n chats --partition-key-path "/sessionId"
    echo "✅ 'chats' container created"
else
    echo "✅ 'chats' container already exists in '$STANDARD_DB'"
fi

echo "----------------------------------------"
echo "4. Setting up App Service managed identity and permissions"
echo "----------------------------------------"

# Get the App Service managed identity principal ID
echo "Checking App Service managed identity..."
PRINCIPAL_ID=$(az webapp identity show -g $RG -n ${BASE}-app --query principalId -o tsv)
if [ -z "$PRINCIPAL_ID" ]; then
    echo "Assigning managed identity to App Service..."
    az webapp identity assign -g $RG -n ${BASE}-app
    PRINCIPAL_ID=$(az webapp identity show -g $RG -n ${BASE}-app --query principalId -o tsv)
fi
echo "App Service Managed Identity Principal ID: $PRINCIPAL_ID"

# Get Key Vault ID for RBAC assignment
KV_ID=$(az keyvault show -g $RG -n $KV --query id -o tsv)

# Check if Key Vault is using RBAC 
KV_RBAC=$(az keyvault show -g $RG -n $KV --query properties.enableRbacAuthorization -o tsv)
if [ "$KV_RBAC" == "true" ]; then
    echo "Key Vault is using RBAC for authorization"
    
    # Check if role assignment already exists
    ROLE_EXISTS=$(az role assignment list --assignee $PRINCIPAL_ID --scope $KV_ID --query "[?roleDefinitionName=='Key Vault Secrets User']" -o tsv)
    
    if [ -z "$ROLE_EXISTS" ]; then
        echo "Assigning Key Vault Secrets User role to App Service managed identity..."
        az role assignment create --assignee $PRINCIPAL_ID --role "Key Vault Secrets User" --scope $KV_ID
        echo "✅ Role assigned successfully"
    else
        echo "✅ App Service already has Key Vault Secrets User role"
    fi
else
    echo "Key Vault is using Access Policies for authorization"
    echo "Setting Key Vault access policy for App Service managed identity..."
    az keyvault set-policy --name $KV --resource-group $RG --object-id $PRINCIPAL_ID --secret-permissions get list
    echo "✅ Access policy set successfully"
fi

# Verify role assignments
echo "Verifying role assignments for App Service managed identity..."
az role assignment list --assignee $PRINCIPAL_ID --scope $KV_ID --query "[].{RoleName:roleDefinitionName, Scope:scope}" -o table

echo "----------------------------------------"
echo "5. Verifying and updating App Service configuration"
echo "----------------------------------------"

# Ensure App Service has the correct environment variables
echo "Setting up App Service environment variables..."
az webapp config appsettings set -g $RG -n ${BASE}-app --settings \
    "COSMOS_DATABASE_NAME=@Microsoft.KeyVault(SecretUri=https://$KV.vault.azure.net/secrets/CosmosDbName)" \
    "COSMOS_ENDPOINT=@Microsoft.KeyVault(SecretUri=https://$KV.vault.azure.net/secrets/CosmosEndpoint)" \
    "COSMOS_KEY=@Microsoft.KeyVault(SecretUri=https://$KV.vault.azure.net/secrets/CosmosConn)" \
    "OPENAI_ENDPOINT=@Microsoft.KeyVault(SecretUri=https://$KV.vault.azure.net/secrets/OpenAIEndpoint)" \
    "OPENAI_API_KEY=@Microsoft.KeyVault(SecretUri=https://$KV.vault.azure.net/secrets/OpenAIKey)" \
    "TEXT_TO_IMAGE_ENDPOINT=@Microsoft.KeyVault(SecretUri=https://$KV.vault.azure.net/secrets/TextToImageEndpoint)" \
    "TEXT_TO_IMAGE_API_KEY=@Microsoft.KeyVault(SecretUri=https://$KV.vault.azure.net/secrets/TextToImageKey)" \
    "DALLE_ENDPOINT=@Microsoft.KeyVault(SecretUri=https://$KV.vault.azure.net/secrets/DALLEEndpoint)" \
    "DALLE_API_KEY=@Microsoft.KeyVault(SecretUri=https://$KV.vault.azure.net/secrets/DALLEKey)" \
    "STORAGE_CONNECTION_STRING=@Microsoft.KeyVault(SecretUri=https://$KV.vault.azure.net/secrets/StorageConn)" \
    "CHAT_MODEL_NAME=@Microsoft.KeyVault(SecretUri=https://$KV.vault.azure.net/secrets/ChatModelName)" \
    "EMBEDDING_MODEL_NAME=@Microsoft.KeyVault(SecretUri=https://$KV.vault.azure.net/secrets/EmbeddingModelName)" \
    "IMAGE_MODEL_NAME=@Microsoft.KeyVault(SecretUri=https://$KV.vault.azure.net/secrets/ImageModelName)" \
    "AUDIO_MODEL_NAME=@Microsoft.KeyVault(SecretUri=https://$KV.vault.azure.net/secrets/AudioModelName)" \
    "API_VERSION=@Microsoft.KeyVault(SecretUri=https://$KV.vault.azure.net/secrets/ApiVersion)" \
    > /dev/null
echo "✅ App Service environment variables updated"

# Also update staging slot if it exists
STAGING_EXISTS=$(az webapp deployment slot list -g $RG -n ${BASE}-app --query "[?name=='staging']" -o tsv)
if [ -n "$STAGING_EXISTS" ]; then
    echo "Updating staging slot configuration..."
    az webapp config appsettings set -g $RG -n ${BASE}-app --slot staging --settings \
        "COSMOS_DATABASE_NAME=@Microsoft.KeyVault(SecretUri=https://$KV.vault.azure.net/secrets/CosmosDbName)" \
        "COSMOS_ENDPOINT=@Microsoft.KeyVault(SecretUri=https://$KV.vault.azure.net/secrets/CosmosEndpoint)" \
        "COSMOS_KEY=@Microsoft.KeyVault(SecretUri=https://$KV.vault.azure.net/secrets/CosmosConn)" \
        "OPENAI_ENDPOINT=@Microsoft.KeyVault(SecretUri=https://$KV.vault.azure.net/secrets/OpenAIEndpoint)" \
        "OPENAI_API_KEY=@Microsoft.KeyVault(SecretUri=https://$KV.vault.azure.net/secrets/OpenAIKey)" \
        "TEXT_TO_IMAGE_ENDPOINT=@Microsoft.KeyVault(SecretUri=https://$KV.vault.azure.net/secrets/TextToImageEndpoint)" \
        "TEXT_TO_IMAGE_API_KEY=@Microsoft.KeyVault(SecretUri=https://$KV.vault.azure.net/secrets/TextToImageKey)" \
        "DALLE_ENDPOINT=@Microsoft.KeyVault(SecretUri=https://$KV.vault.azure.net/secrets/DALLEEndpoint)" \
        "DALLE_API_KEY=@Microsoft.KeyVault(SecretUri=https://$KV.vault.azure.net/secrets/DALLEKey)" \
        "STORAGE_CONNECTION_STRING=@Microsoft.KeyVault(SecretUri=https://$KV.vault.azure.net/secrets/StorageConn)" \
        "CHAT_MODEL_NAME=@Microsoft.KeyVault(SecretUri=https://$KV.vault.azure.net/secrets/ChatModelName)" \
        "EMBEDDING_MODEL_NAME=@Microsoft.KeyVault(SecretUri=https://$KV.vault.azure.net/secrets/EmbeddingModelName)" \
        "IMAGE_MODEL_NAME=@Microsoft.KeyVault(SecretUri=https://$KV.vault.azure.net/secrets/ImageModelName)" \
        "AUDIO_MODEL_NAME=@Microsoft.KeyVault(SecretUri=https://$KV.vault.azure.net/secrets/AudioModelName)" \
        "API_VERSION=@Microsoft.KeyVault(SecretUri=https://$KV.vault.azure.net/secrets/ApiVersion)" \
        > /dev/null
    echo "✅ Staging slot environment variables updated"
fi

echo "----------------------------------------"
echo "7. Running environment verification"
echo "----------------------------------------"

# List all Key Vault secrets (names only)
echo "Key Vault secrets:"
az keyvault secret list --vault-name $KV --query "[].name" -o table

# Verify OpenAI models
echo "OpenAI models in primary endpoint:"
az cognitiveservices account deployment list -g $RG -n ${BASE}-foundry -o table

# Verify storage account
echo "Storage account information:"
az storage account show -g $RG -n ${BASE}store --query "{name:name,location:location,httpsOnly:enableHttpsTrafficOnly,encryption:encryption.services}" -o table

# Verify Cosmos DB analytical storage
echo "Checking Cosmos DB analytical storage..."
ANALYTICAL_STORAGE=$(az cosmosdb show -g $RG -n ${BASE}-cosmos --query "analyticalStorageConfiguration.schemaType" -o tsv)
if [ -z "$ANALYTICAL_STORAGE" ] || [ "$ANALYTICAL_STORAGE" == "None" ]; then
    echo "⚠️ Analytical storage is not enabled for Cosmos DB"
    echo "You should enable this manually through the Azure Portal:"
    echo "1. Navigate to your Cosmos DB account (${BASE}-cosmos)"
    echo "2. Go to 'Features' in the left menu"
    echo "3. Click 'Synapse Link'"
    echo "4. Enable 'Azure Synapse Link for Azure Cosmos DB'"
    echo "5. For each database and container, set the analytical TTL to -1 (infinite)"
else
    echo "✅ Cosmos DB analytical storage is enabled"
fi

echo "----------------------------------------"
echo "8. Fixing .env file for local development"
echo "----------------------------------------"

# Check if 1.env exists and rename it to .env
if [ -f "1.env" ]; then
    echo "Renaming 1.env to .env..."
    mv 1.env .env
    echo "✅ Renamed 1.env to .env"
elif [ ! -f ".env" ]; then
    echo "Creating .env file for local development..."
    # Create a basic .env file for local development
    cat > .env << EOF
# Local development environment variables for PippAI2
# Created by setup script on $(date)
# This file should not be committed to source control

# Cosmos DB Configuration
COSMOS_DATABASE_NAME=simplechat
COSMOS_ENDPOINT=$COSMOS_ENDPOINT
COSMOS_KEY=$COSMOS_CONN

# OpenAI Configuration
OPENAI_ENDPOINT=$AI_ENDPOINT
OPENAI_API_KEY=$OPENAI_KEY

# DALL-E 3 Configuration (hosted in Sweden with other AI assets)
DALLE_ENDPOINT=$AI_ENDPOINT
DALLE_API_KEY=$OPENAI_KEY

# Text-to-Image Configuration (newer version, separate service)
TEXT_TO_IMAGE_ENDPOINT=$TEXT_TO_IMAGE_ENDPOINT
# Text-to-image key must be manually added

# Storage Configuration
STORAGE_CONNECTION_STRING=$STORAGE_CONN

# Model Names
CHAT_MODEL_NAME=gpt-4o
EMBEDDING_MODEL_NAME=text-embedding-large
IMAGE_MODEL_NAME=dalle3
AUDIO_MODEL_NAME=whisper
API_VERSION=2025-01-01-preview
EOF
    echo "✅ Created .env file"
else
    echo "✅ .env file already exists"
fi

echo "----------------------------------------"
echo "9. Summary and next steps"
echo "----------------------------------------"

echo "✅ Configuration script completed successfully at $(date)"
echo ""
echo "Key Information:"
echo "----------------"
echo "Resource Group: $RG"
echo "Key Vault: $KV"
echo "Key Vault Authorization: $(if [ "$KV_RBAC" == "true" ]; then echo "RBAC"; else echo "Access Policies"; fi)"
echo "App Service: ${BASE}-app (Kind: $APP_KIND)"
echo "App Service Identity: $PRINCIPAL_ID"
echo "Database: $(az keyvault secret show --vault-name $KV -n CosmosDbName --query value -o tsv)"
echo "OpenAI Endpoint: $AI_ENDPOINT"
echo "Text-to-Image Endpoint: $TEXT_TO_IMAGE_ENDPOINT"
echo ""
echo "Next Steps:"
echo "-----------"
echo "1. If needed, manually enable Cosmos DB analytical storage through the Azure Portal"
echo "2. Verify application functionality in the staging environment before promoting to production"
echo "3. Check application logs for any errors after deployment"
echo ""
echo "To deploy your application to staging, run:"
echo "  az webapp deployment source config-zip -g $RG -n ${BASE}-app -s staging --src deployment.zip"
echo ""
echo "To swap staging to production after verification:"
echo "  az webapp deployment slot swap -g $RG -n ${BASE}-app --slot staging --target-slot production"