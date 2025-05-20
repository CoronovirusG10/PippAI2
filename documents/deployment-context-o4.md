# Deployment Context – o4

This file tracks decisions, issues and next steps for the re-deployment in **pippaioflondoncdx2**.

- **Start date:** 2025-05-20  
- **Environment type:** Development / first-time clean deploy  
- **Target region:** Sweden Central  
- **Master log:** `context-o4.jsonl`

The resource group for the o4 environment is named pippaioflondoncdx2.

---

## Current status
- [x] Resource group created  
- [x] Core services deployed  
- [x] Staging slot live  
- [x] Manual steps (see `manual-steps-o4.md`) completed  
- [x] All endpoints documented and stored in Key Vault  
- [x] Verification checklist completed  

---

## Cosmos DB Analytical Storage Limitation (as of 2025-05-20)
- Analytical storage (EnableAnalyticalStorage/EnableAzureSynapseLink) could not be enabled due to Azure CLI/API limitations.
- Setting analytical storage TTL on the `chats` container is not possible in the current configuration.
- Cosmos DB is running with default (provisioned throughput, no serverless, no analytics).
- All attempts and errors are logged in `context-o4.jsonl`.
- If analytics is required in the future, revisit this step when Azure CLI/API support is available.
- If analytics is not a hard requirement, continue with the current configuration and document the limitation.

## Manual Steps & Phase 2 Items
- [ ] Azure Front Door WAF Policy: Created and assigned manually in Azure Portal. See `manual-steps-o4.md`.
- [ ] OpenAI Model Deployment: GPT-4o and GPT-4 Turbo deployed via Azure OpenAI Studio/Portal. Grounding-for-Bing approval requested if needed.
- [ ] Post-Deployment Verification: Run `deployment-verification.sh`, check all endpoints, and update `deployment-verification-checklist.md`.

## Issues & resolutions
- Cosmos DB analytics not possible in current mode; documented and deferred to phase 2/manual.
- WAF and OpenAI model deployment are manual steps due to current Azure CLI limitations.
- All actions, errors, and decisions are logged in `context-o4.jsonl` for auditability.

---

## Verification Notes
- [x] Managed identity assigned to Azure AI Search, Document Intelligence, and Speech Service.
- [x] Diagnostic settings for all three services now point to Log Analytics workspace.
- [x] All endpoints are documented and stored as Key Vault secrets.
- [x] All required secrets (CosmosConn, StorageConn, endpoints) are present in Key Vault.
- [x] Post-deployment verification complete.

---

## Service Endpoints (as of 2025-05-20)
- App Service: https://pippaioflondoncdx2-app.azurewebsites.net
- Front Door: https://chat-ep.z01.azurefd.net
- Cosmos DB: https://pippaioflondoncdx2-cosmos.documents.azure.com:443/
- Storage Account: https://pippaioflondoncdx2store.z13.web.core.windows.net/
- Azure AI Search: https://pippaioflondoncdx2-search.search.windows.net
- Azure AI Document Intelligence: https://pippaioflondoncdx2-docint.cognitiveservices.azure.com/
- Azure Speech Service: https://pippaioflondoncdx2-speech.cognitiveservices.azure.com/

---

# Endpoint Reference (automated)

| Resource                    | Endpoint URL                                              |
|-----------------------------|----------------------------------------------------------|
| App Service                 | https://pippaioflondoncdx2-app.azurewebsites.net          |
| Front Door                  | https://chat-ep.z01.azurefd.net                          |
| Cosmos DB                   | https://pippaioflondoncdx2-cosmos.documents.azure.com:443/|
| Storage (Blob)              | https://pippaioflondoncdx2store.z13.web.core.windows.net/ |
| Azure AI Search             | https://pippaioflondoncdx2-search.search.windows.net      |
| Document Intelligence       | https://pippaioflondoncdx2-docint.cognitiveservices.azure.com/ |
| Speech Service              | https://pippaioflondoncdx2-speech.cognitiveservices.azure.com/ |

All endpoints are also stored as reference secrets in Key Vault for operational consistency.

---

_Last updated automatically by GitHub Copilot Agent_
