# Front Door Troubleshooting Guide

Below are the step-by-step commands to fix the Azure Front Door issues identified in the verification results. The main issues are:

1. Front Door connectivity issues
2. WAF policy not assigned properly

## Step 1: Get Front Door and App Service Hostnames

```bash
export BASE=pippaioflondoncdx2
export RG=$BASE
export AFD_PROFILE="${BASE}-afd"
export AFD_ENDPOINT="chat-ep"
export WEBAPP="${BASE}-app"

# Get Front Door hostname
FD_HOSTNAME=$(az afd endpoint show -g $RG --profile-name $AFD_PROFILE -n $AFD_ENDPOINT --query hostName -o tsv)
echo "Front Door Hostname: $FD_HOSTNAME"

# Get App Service hostname
APP_HOSTNAME="${WEBAPP}.azurewebsites.net"
echo "App Service Hostname: $APP_HOSTNAME"
```

## Step 2: Fix Health Probe Path

A common issue with Front Door connectivity is that the health probe is looking for a /health endpoint that doesn't exist.

```bash
# Update health probe path to use the root path
az afd origin-group update -g $RG --profile-name $AFD_PROFILE --origin-group-name og-app --health-probe-path /
```

## Step 3: Update Origin Host Header

Make sure the origin host header matches the app service hostname:

```bash
# Update origin host header
az afd origin update -g $RG --profile-name $AFD_PROFILE --origin-group-name og-app --origin-name chat-origin --origin-host-header $APP_HOSTNAME
```

## Step 4: Fix Front Door Route

Ensure the route is correctly configured:

```bash
# Update the route
az afd route update -g $RG --profile-name $AFD_PROFILE --endpoint-name $AFD_ENDPOINT --route-name chatroute --forwarding-protocol HttpsOnly
```

## Step 5: Test Front Door and App Service Endpoints

```bash
# Test App Service endpoint (from your local machine)
curl -I https://$APP_HOSTNAME/

# Test Front Door endpoint (from your local machine)
curl -I https://$FD_HOSTNAME/
```

## Step 6: Add Diagnostic Settings

```bash
# Get Log Analytics workspace ID
LOG_ANALYTICS_ID=$(az monitor log-analytics workspace show -g $RG -n ${BASE}-logs --query id -o tsv)

# Add diagnostic settings to Front Door
az monitor diagnostic-settings create --name ${BASE}-afd-diag \
  --resource $(az afd profile show -g $RG --profile-name $AFD_PROFILE --query id -o tsv) \
  --workspace $LOG_ANALYTICS_ID \
  --logs '[{"category": "FrontDoorAccessLog", "enabled": true},{"category": "FrontDoorHealthProbeLog", "enabled": true},{"category": "FrontDoorWebApplicationFirewallLog", "enabled": true}]'
```

## Step 7: Manual WAF Setup (Required)

Azure CLI currently does not fully support WAF policy management for Azure Front Door Premium. Follow these steps in the Azure Portal:

1. Go to the Azure Portal: https://portal.azure.com
2. Search for "Front Door and CDN profiles (preview)"
3. Select your profile: `pippaioflondoncdx2-afd` in resource group `pippaioflondoncdx2`
4. In the left menu, select **Web application firewall (WAF)** > **Policies**
5. Click **+ Add** to create a new policy
   - Name: `chat-waf`
   - Policy mode: **Prevention**
   - SKU: **Premium_AzureFrontDoor**
   - Configure rules as needed (default rules are recommended)
   - Click **Review + create** and then **Create**
6. Once created, go back to your Front Door profile, select **Endpoints**
7. Click on `chat-ep`
8. Under **Web application firewall (WAF) policy**, click **Associate**
9. Select the `chat-waf` policy you created
10. Save changes

## Additional Troubleshooting Tips:

1. **Check Front Door Health Probe Logs**
   
   Look in the Log Analytics workspace for Front Door Health Probe logs to see if the health probes are failing.

2. **DNS Propagation**
   
   Sometimes, issues with Front Door connectivity can be related to DNS propagation. Wait a few minutes after making changes before testing again.

3. **Origin Health**
   
   Make sure the App Service is running and accessible.

4. **Caching Settings**

   If content appears outdated, check caching settings in your route configuration.

5. **Custom Domain Setup**

   If using a custom domain, verify that the CNAME records are correctly set up.
