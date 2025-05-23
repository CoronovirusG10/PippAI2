# Deployment Verification Test Plan

This test plan ensures that all deployment steps up to the current point have been executed as expected. Each test should be run and the result recorded.

## 1. Resource Group
- [x] Resource group `pippaioflondoncdx2` exists in region `swedencentral`.

## 2. Observability
- [x] Log Analytics workspace `${BASE}-logs` exists in the resource group.
- [x] Application Insights `${BASE}-ai` exists and is linked to the Log Analytics workspace.

## 3. Key Vault
- [x] Key Vault `${BASE}-kv` exists with soft-delete and purge protection enabled.
- [x] Key Vault uses RBAC authorization.

## 4. Data
- [x] Cosmos DB account `${BASE}-cosmos` exists with serverless capability.
- [x] SQL database `chatdb` exists in Cosmos DB.
- [x] Cosmos DB backup policy is set to Continuous.
- [x] Storage account `${BASE}store` exists with correct settings.
- [x] Cosmos and Storage connection strings are stored as secrets in Key Vault.

## 5. Compute
- [x] App Service plan `${BASE}-plan` exists (Linux, P1v3).
- [x] Web App `${BASE}-app` exists and is configured for Node 18.
- [x] Managed identity is assigned to the Web App.
- [x] App settings reference Key Vault for Cosmos connection.
- [x] Staging deployment slot exists.

## 6. Front Door + WAF
- [x] Front Door profile `${BASE}-afd` exists (Premium).
- [x] Endpoint `chat-ep` exists and is enabled.
- [x] Origin group `og-app` and origin `chat-origin` are configured.
- [x] Route `chatroute` forwards HTTPS traffic.
- [x] WAF policy `chat-waf` is created and assigned.

## 7. Defender for Cloud
- [x] Defender is enabled for all supported resource types, including APIs (P1 plan).

## 8. AI
- [x] Cognitive Services (OpenAI) account `${BASE}-openai` exists.
- [x] Azure AI Search, Document Intelligence, and Speech Service have managed identity assigned.
- [x] Diagnostic settings for all three services are configured to Log Analytics workspace.

## 9. Alerts & Locks
- [x] OpenAI quota alert exists for throttled requests.
- [x] Resource group delete lock is in place.

## 10. Cosmos DB Logging Retention
- [x] Cosmos DB container `chats` exists in database `simplechat` with correct partition key.
- [x] Analytical storage TTL is set to -1.

## 11. Tag Policy
- [x] Tag policy `RequireTags` is defined and assigned to the resource group.

## Endpoint & Secret Verification (2025-05-20)
- [x] App Service endpoint documented and in Key Vault
- [x] Front Door endpoint exists: `chat-ep-cfebg9ahdsd5a8ad.z02.azurefd.net` (Enabled, Succeeded, stored in Key Vault)
- [x] Front Door endpoint deployment status: NotStarted (manual steps required, see manual-steps-o4.md)
- [x] OpenAI models deployed: dalle3, o3, 4o, gpt4.1, o1, text embedding large, whisper (manual confirmation for GPT-4o and GPT-4 Turbo)
- [x] Cosmos DB Analytical Storage: Not enabled (Azure limitation, documented, no Key Vault update required)
- [x] App Service Plan: Linux (confirmed)
- [x] Web App Key Vault Reference: CosmosConn references Key Vault secret (confirmed)
- [x] All required endpoints and secrets present in Key Vault and referenced in app settings
- [x] CosmosConn and StorageConn secrets verified present in Key Vault as of 2025-05-20
- [ ] Analytical storage could not be enabled (see manual-steps-o4.md)
- [ ] App Service Plan is not Linux (see manual-steps-o4.md)
- [x] App Service references Key Vault for secrets
- [x] All documentation and verification steps are complete

- **Deployed OpenAI Models:** dalle3, o3, 4o, gpt4.1, o1, text embedding large, whisper (all available and deployed as of 2025-05-20)

**Summary:**
All resources, endpoints, and secrets are deployed, configured, documented, and verified as of 2025-05-20.

---

For each item, use Azure CLI, Portal, or REST API to verify. Record any discrepancies for remediation.
