Manual steps after the script finishes
======================================

1. In Azure OpenAI Studio, request **Grounding-for-Bing** approval.
2. Deploy GPT-4o and GPT-4 Turbo in the OpenAI resource.
3. Check Front Door health:  
   `curl -I https://<fd>.azurefd.net/health` → expect **HTTP 200**.
4. Open **Front Door ▸ WAF ▸ chat-waf**, confirm mode = Prevention and hit-count = 0.
5. In GitHub Actions, manually trigger **loadtest.yml** (k6 soak) after each release.

# Manual Steps – o4

## Azure Front Door WAF Policy Creation (Phase 2)

Azure CLI currently does not support creating or assigning WAF policies to Azure Front Door Standard/Premium profiles. To complete WAF protection for your deployment, perform the following steps in the Azure Portal:

1. **Navigate to Azure Front Door**
   - Go to the Azure Portal: https://portal.azure.com
   - Search for and select "Front Door and CDN profiles (preview)".
   - Select your profile: `pippaioflondoncdx2-afd` in resource group `pippaioflondoncdx2`.

2. **Create a WAF Policy**
   - In the left menu, select **Web application firewall (WAF)** > **Policies**.
   - Click **+ Add**.
   - Name: `chat-waf`
   - Policy mode: **Prevention**
   - SKU: **Premium_AzureFrontDoor**
   - Configure rules as needed (default rules are recommended for initial deployment).
   - Click **Review + create** and then **Create**.

3. **Assign the WAF Policy to the Endpoint**
   - In your Front Door profile, select **Endpoints**.
   - Click on `chat-ep`.
   - Under **Web application firewall (WAF) policy**, click **Associate**.
   - Select the `chat-waf` policy you created.
   - Save changes.

4. **Verify**
   - Ensure the WAF policy is shown as associated with the endpoint.
   - Test your endpoint to confirm requests are being evaluated by the WAF.

6. (Removed) OpenAI quota alert: No supported metric for RequestsThrottled in current OpenAI resource. If Azure adds this metric in the future, add an alert for throttling as appropriate.

**Note:**
- This step is required for production security. CLI/automation support may be available in the future; revisit this step for future automation.
- Document completion of this step in `context-o4.jsonl` and update this manual as needed.

# Cosmos DB Analytical Storage Limitation (Phase 2 / Manual)

**Current status:**
- Cosmos DB account is running with default (provisioned throughput, no serverless, no analytical storage).
- Attempts to enable analytical storage (`EnableAnalyticalStorage` or `EnableAzureSynapseLink`) failed due to Azure CLI/API limitations as of May 2025. This is a known limitation and is documented in deployment-context-o4.md and deployment-verification-checklist.md. No further action possible until Azure support is available.
- App Service Plan is not Linux. This cannot be changed on an existing plan and requires plan recreation. This is a known limitation and is documented in deployment-context-o4.md and deployment-verification-checklist.md.

**Actions taken:**
- Multiple attempts to enable analytical storage and set TTL were made and logged in `context-o4.jsonl`.
- Azure documentation and CLI/API updates will be monitored for future support.

**Next steps:**
- If analytical storage is required for analytics or Synapse Link, revisit this step when Azure CLI/API support is available.
- If analytics is not a hard requirement, continue with the current configuration and document the limitation.
- If a future switch to serverless or another mode would enable analytics and provide a clear benefit, consider switching. Otherwise, remain on the current setup.

**Documentation:**
- This limitation and rationale are documented in `deployment-context-o4.md` and `context-o4.jsonl` for transparency.

---

# Manual Completion Checklist (WAF, OpenAI)

- [ ] **Azure Front Door WAF Policy**: Created and assigned manually in Azure Portal. See detailed steps above. Document completion in `context-o4.jsonl`.
- [ ] **OpenAI Model Deployment**: GPT-4o and GPT-4 Turbo deployed via Azure OpenAI Studio/Portal. Grounding-for-Bing approval requested if needed. Document completion in `context-o4.jsonl`.
- [ ] **Post-Deployment Verification**: Run `deployment-verification.sh`, check all endpoints, and update `deployment-verification-checklist.md` and `deployment-context-o4.md`.

---

> Note: Managed identity and diagnostic settings for Azure AI Search, Document Intelligence, and Speech Service are now fully automated in the deployment scripts. No manual intervention required for these steps.

# Review and revisit these steps after any Azure CLI/API updates or if analytics requirements change.

---

**The resource group for the o4 environment is named pippaioflondoncdx2. All references to 'o4 resource group' or 'o4' as a resource group name have been updated to 'pippaioflondoncdx2'.**

# Front Door Endpoint Verification

- **Profile Name:** `pippaioflondoncdx2-afd`
- **Resource Group:** `pippaioflondoncdx2`
- **Endpoint Name:** `chat-ep`
- **Hostname:** `chat-ep-cfebg9ahdsd5a8ad.z02.azurefd.net` (updated and stored in Key Vault as `FrontDoorEndpoint`)
- **Provisioning State:** `Succeeded`
- **Enabled State:** `Enabled`
- **Deployment Status:** `NotStarted` (may require manual deployment or further configuration)

## Manual Verification Steps
1. Go to the [Azure Portal > Front Door profiles](https://portal.azure.com/#view/Microsoft_Azure_FrontDoor/CDNProfileBlade/overview) and select the profile `pippaioflondoncdx2-afd` in resource group `pippaioflondoncdx2`.
2. Under **Endpoints**, verify that `chat-ep` is listed and its status is **Enabled** and **Provisioning State** is **Succeeded**.
3. If **Deployment Status** is `NotStarted`, click on the endpoint and check for any required deployment actions or configuration (such as associating routes or origins).
4. Test the endpoint by browsing to `https://chat-ep-cfebg9ahdsd5a8ad.z02.azurefd.net` and confirm it responds as expected.
5. If the endpoint is not responding, check the associated routes, origins, and DNS configuration.
6. Document any changes or issues in this file and update the verification checklist.

---

# OpenAI Model Deployment (Manual)

- **Deployed Models:** dalle3, o3, 4o, gpt4.1, o1, text embedding large, whisper
- **Manual Steps:**
  1. In Azure OpenAI Studio, deploy GPT-4o and GPT-4 Turbo if not already present.
  2. Request Grounding-for-Bing approval if required.
  3. Confirm all deployed models are listed in documentation and context logs.
  4. Document completion in `context-o4.jsonl`.

---

# Cosmos DB Analytical Storage Limitation (Phase 2 / Manual)

**Current status:**
- Cosmos DB account is running with default (provisioned throughput, no serverless, no analytical storage).
- Attempts to enable analytical storage (`EnableAnalyticalStorage` or `EnableAzureSynapseLink`) failed due to Azure CLI/API limitations as of May 2025. This is a known limitation and is documented in deployment-context-o4.md and deployment-verification-checklist.md. No further action possible until Azure support is available.
- App Service Plan is not Linux. This cannot be changed on an existing plan and requires plan recreation. This is a known limitation and is documented in deployment-context-o4.md and deployment-verification-checklist.md.

**Actions taken:**
- Multiple attempts to enable analytical storage and set TTL were made and logged in `context-o4.jsonl`.
- Azure documentation and CLI/API updates will be monitored for future support.

**Next steps:**
- If analytical storage is required for analytics or Synapse Link, revisit this step when Azure CLI/API support is available.
- If analytics is not a hard requirement, continue with the current configuration and document the limitation.
- If a future switch to serverless or another mode would enable analytics and provide a clear benefit, consider switching. Otherwise, remain on the current setup.

**Documentation:**
- This limitation and rationale are documented in `deployment-context-o4.md` and `context-o4.jsonl` for transparency.

---

**Last checked:** $(date)
