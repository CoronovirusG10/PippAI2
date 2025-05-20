#!/bin/bash
# Script to diagnose and fix Front Door issues
# Created: May 21, 2025

# Environment variables
BASE="pippaioflondoncdx2"
RG="$BASE"
AFD_PROFILE="${BASE}-afd"
AFD_ENDPOINT="chat-ep"
WEBAPP="${BASE}-app"
WAF_POLICY="chat-waf"

# Text formatting
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== Front Door Diagnostics and Repair Script ===${NC}"
echo "This script will diagnose and attempt to fix Front Door issues"
echo "Resource Group: $RG"
echo "Front Door Profile: $AFD_PROFILE"
echo "Front Door Endpoint: $AFD_ENDPOINT"
echo "Web App: $WEBAPP"
echo ""

# Step 1: Check Front Door endpoint
echo -e "${BLUE}Step 1: Checking Front Door endpoint${NC}"
AFD_HOSTNAME=$(az afd endpoint show -g $RG --profile-name $AFD_PROFILE -n $AFD_ENDPOINT --query hostName -o tsv)
if [ -z "$AFD_HOSTNAME" ]; then
  echo -e "${RED}Error: Could not retrieve Front Door endpoint hostname${NC}"
  echo "Creating a new endpoint..."
  az afd endpoint create -g $RG --profile-name $AFD_PROFILE --endpoint-name $AFD_ENDPOINT
  AFD_HOSTNAME=$(az afd endpoint show -g $RG --profile-name $AFD_PROFILE -n $AFD_ENDPOINT --query hostName -o tsv)
  if [ -z "$AFD_HOSTNAME" ]; then
    echo -e "${RED}Failed to create Front Door endpoint${NC}"
    exit 1
  else
    echo -e "${GREEN}Created new Front Door endpoint: $AFD_HOSTNAME${NC}"
  fi
else
  echo -e "${GREEN}Front Door hostname: $AFD_HOSTNAME${NC}"
fi

# Step 2: Check Origin Group
echo -e "${BLUE}Step 2: Checking Origin Group${NC}"
ORIGIN_GROUP_EXISTS=$(az afd origin-group show -g $RG --profile-name $AFD_PROFILE --origin-group-name og-app 2>/dev/null)
if [ -z "$ORIGIN_GROUP_EXISTS" ]; then
  echo -e "${RED}Origin Group 'og-app' not found. Creating...${NC}"
  az afd origin-group create -g $RG --profile-name $AFD_PROFILE --origin-group-name og-app \
    --origin-protocol-parameter Https --session-affinity-enabled false \
    --health-probe-protocol Https --health-probe-interval 240 --health-probe-path /health \
    --health-probe-request-type GET
  echo -e "${GREEN}Origin Group created${NC}"
else
  echo -e "${GREEN}Origin Group 'og-app' exists${NC}"
fi

# Step 3: Check Origin
echo -e "${BLUE}Step 3: Checking Origin${NC}"
APP_HOSTNAME="${WEBAPP}.azurewebsites.net"
ORIGIN_EXISTS=$(az afd origin show -g $RG --profile-name $AFD_PROFILE --origin-group-name og-app --origin-name chat-origin 2>/dev/null)
if [ -z "$ORIGIN_EXISTS" ]; then
  echo -e "${RED}Origin 'chat-origin' not found. Creating...${NC}"
  az afd origin create -g $RG --profile-name $AFD_PROFILE --origin-group-name og-app \
    --origin-name chat-origin --host-name $APP_HOSTNAME --priority 1 --weight 1000 \
    --enabled-state Enabled --http-port 80 --https-port 443 --origin-host-header $APP_HOSTNAME
  echo -e "${GREEN}Origin created${NC}"
else
  echo -e "${GREEN}Origin 'chat-origin' exists${NC}"
fi

# Step 4: Check Route
echo -e "${BLUE}Step 4: Checking Route${NC}"
ROUTE_EXISTS=$(az afd route show -g $RG --profile-name $AFD_PROFILE --endpoint-name $AFD_ENDPOINT --route-name chatroute 2>/dev/null)
if [ -z "$ROUTE_EXISTS" ]; then
  echo -e "${RED}Route 'chatroute' not found. Creating...${NC}"
  az afd route create -g $RG --profile-name $AFD_PROFILE --endpoint-name $AFD_ENDPOINT \
    --route-name chatroute --origin-group og-app --origin-path "/" \
    --supported-protocols Https --patterns-to-match "/*" --forwarding-protocol HttpsOnly --custom-domains ""
  echo -e "${GREEN}Route created${NC}"
else
  echo -e "${GREEN}Route 'chatroute' exists${NC}"
fi

# Step 5: Check app health
echo -e "${BLUE}Step 5: Checking App Service health${NC}"
APP_HEALTH=$(curl -s -o /dev/null -w "%{http_code}" https://$APP_HOSTNAME/health || echo "Connection failed")
if [ "$APP_HEALTH" = "200" ]; then
  echo -e "${GREEN}App Service is healthy (HTTP 200)${NC}"
elif [ "$APP_HEALTH" = "404" ]; then
  echo -e "${YELLOW}Warning: App Service returned 404 for /health endpoint. This may be normal if no health endpoint is configured.${NC}"
  echo "Checking if app is running at all..."
  APP_ROOT=$(curl -s -o /dev/null -w "%{http_code}" https://$APP_HOSTNAME/ || echo "Connection failed")
  if [ "$APP_ROOT" != "Connection failed" ] && [ "$APP_ROOT" -lt 500 ]; then
    echo -e "${GREEN}App Service is accessible at root path (HTTP $APP_ROOT)${NC}"
  else
    echo -e "${RED}App Service is not responding or returned error: $APP_ROOT${NC}"
  fi
else
  echo -e "${RED}App Service health check failed with status: $APP_HEALTH${NC}"
fi

# Step 6: Update health probe path if needed
echo -e "${BLUE}Step 6: Updating health probe path${NC}"
echo "Setting health probe path to '/' instead of '/health' to match app configuration"
az afd origin-group update -g $RG --profile-name $AFD_PROFILE --origin-group-name og-app \
  --health-probe-path / || echo -e "${RED}Failed to update health probe path${NC}"

# Step 7: Check Front Door diagnostic settings
echo -e "${BLUE}Step 7: Checking Front Door diagnostic settings${NC}"
LOG_ANALYTICS_ID=$(az monitor log-analytics workspace show -g $RG -n ${BASE}-logs --query id -o tsv)
if [ -z "$LOG_ANALYTICS_ID" ]; then
  echo -e "${RED}Could not retrieve Log Analytics ID${NC}"
else
  echo "Adding diagnostic settings to Front Door..."
  az monitor diagnostic-settings create --name ${BASE}-afd-diag \
    --resource $(az afd profile show -g $RG --profile-name $AFD_PROFILE --query id -o tsv) \
    --workspace $LOG_ANALYTICS_ID \
    --logs '[{"category": "FrontDoorAccessLog", "enabled": true},{"category": "FrontDoorHealthProbeLog", "enabled": true},{"category": "FrontDoorWebApplicationFirewallLog", "enabled": true}]' || \
    echo -e "${RED}Failed to create diagnostic settings${NC}"
  echo -e "${GREEN}Diagnostic settings added or already exist${NC}"
fi

# Step 8: Check Front Door connectivity
echo -e "${BLUE}Step 8: Testing Front Door connectivity${NC}"
FD_HOSTNAME=$(az afd endpoint show -g $RG --profile-name $AFD_PROFILE -n $AFD_ENDPOINT --query hostName -o tsv)
FD_HEALTH=$(curl -s -I -o /dev/null -w "%{http_code}" https://$FD_HOSTNAME/ || echo "Connection failed")
if [ "$FD_HEALTH" = "Connection failed" ]; then
  echo -e "${RED}Could not connect to Front Door endpoint.${NC}"
  echo "This could be due to DNS propagation delay. Try again in a few minutes."
elif [ "$FD_HEALTH" -ge 200 ] && [ "$FD_HEALTH" -lt 400 ]; then
  echo -e "${GREEN}Front Door endpoint is responding successfully with status: $FD_HEALTH${NC}"
else
  echo -e "${RED}Front Door endpoint responded with error status: $FD_HEALTH${NC}"
  echo "Check the route configuration and origin health."
fi

# Step 9: Check WAF policy (can only print instructions for manual correction)
echo -e "${BLUE}Step 9: WAF Policy Instructions${NC}"
echo -e "${YELLOW}The WAF policy must be created and assigned manually in the Azure Portal.${NC}"
echo -e "${YELLOW}Please follow these steps:${NC}"
echo "1. Go to the Azure Portal: https://portal.azure.com"
echo "2. Search for and select 'Front Door and CDN profiles (preview)'"
echo "3. Select your profile: $AFD_PROFILE in resource group $RG"
echo "4. In the left menu, select 'Web application firewall (WAF)' > 'Policies'"
echo "5. Click '+ Add' and create a WAF policy named '$WAF_POLICY' with mode 'Prevention'"
echo "6. Once created, go back to your Front Door profile, select 'Endpoints', click on '$AFD_ENDPOINT'"
echo "7. Under 'Web application firewall (WAF) policy', click 'Associate' and select the WAF policy you created"
echo "8. Save changes and verify that requests are being evaluated by the WAF"

echo ""
echo -e "${BLUE}=== Diagnostics and repair completed ===${NC}"
echo "Front Door hostname: $FD_HOSTNAME"
echo "App Service hostname: $APP_HOSTNAME"
