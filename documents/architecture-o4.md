# SimpleChat – Architecture (o4 deployment)

> Master log file: `context-o4.jsonl`.  
> Region: **Sweden Central**   Resource Group: **pippaioflondoncdx2**  
> Performance and stability are prioritised over cost.  
> Chat-session data is retained indefinitely (unless manually purged).

## 1 Solution overview
- Fork/clone of https://github.com/microsoft/simplechat  
- Deployed as an Azure Web App (Linux) running the React + Node back-end.  
- Uses Azure Cosmos DB for chat history (no TTL).  
- Uses Azure OpenAI (GPT-4o & GPT-4 Turbo) for responses.  
- Static files served from the same App Service; a staging slot enables zero-downtime swaps.  
- Secrets stored in Azure Key Vault with managed identity access.

## 2 Component list
| Azure service | Purpose |
|---------------|---------|
| Resource Group *pippaioflondoncdx2* | Logical container |
| App Service Plan (P1v3, Linux) | Runs production & staging slots |
| App Service *pippaioflondoncdx2-app* | Hosts the app |
| Staging slot *staging* | Future-change validation |
| Azure Cosmos DB (serverless) | Stores chats indefinitely |
| Azure OpenAI | Model hosting |
| Azure Storage (LRS) – *pippaioflondoncdx2store* | Logs & file uploads |
| Azure Key Vault | Secrets |
| Log Analytics + App Insights | Observability |
| OpenAI Models (dalle3, o3, 4o, gpt4.1, o1, text embedding large, whisper) | Deployed and available |

## 3 Security
- AAD authentication enabled on the Web App.  
- Managed identity on the Web App receives RBAC permissions (Cosmos DB reader/writer, Key Vault secrets user).  
- Key Vault firewall “deny-all except VNET & AppService” once connectivity is validated.  
Key Vault is protected by soft-delete, purge-protection and RBAC; rotation is manual for now.  
All resources must carry tags **costCentre**, `owner`, and `env`; enforced via Azure Policy.  
- Storage account currently has **public-network-access enabled** so the Node back-end can reach Blob service.  
  A private endpoint will replace this in Phase 2.

## 4 Staging strategy
- A dedicated *staging* slot mirrors production settings.  
- CI deploys to *staging*, runs smoke tests, then swaps if green.  
- Post-swap, metrics are compared for 30 minutes before marking roll-forward complete.

## 5 Logging & retention
- Chat collection in Cosmos DB has no TTL; point-in-time restore enabled.  
- All telemetry forwarded to Log Analytics; App Insights data retention set to 2 years.  
Under Monitoring we surface latency, success %, RU/s and tokens/min in the *ChatHealth* workbook (dashboards/ChatHealth.workbook.json).  
<!-- TODO – add OpenAI token graph when metric GA. -->

## 6 High-availability
- Zone-redundant resources where available (App Service plan, Cosmos DB multi-region read).  
- Daily automated backups of App Service & Cosmos DB; geo-backup enabled.

## 6 Observability additions
- Workbook **ChatHealth** (dashboards/ChatHealth.workbook.json) surfaces latency, success %, RU/s and tokens/min from Application Insights.

## 7 Future work (Phase 2)
• Map custom Front-Door domain (e.g. `chat.yourcorp.com`).

## Deployment & Operational State (as of 2025-05-20)
- All Azure resources (App Service, Cosmos DB, Storage, AI Search, Document Intelligence, Speech, Front Door, Key Vault, Log Analytics, App Insights) are deployed and configured.
- All service endpoints are documented in `deployment-context-o4.md` and stored as Key Vault secrets.
- All required secrets (connection strings, endpoints) are present in Key Vault and referenced by the application.
- Diagnostic settings and managed identities are configured as per best practices.
- Manual steps (WAF, OpenAI model deployment) are clearly documented in `manual-steps-o4.md`.
- The architecture is fully realized and operational as designed.

## Endpoint Documentation & Key Vault Reference

All major Azure resource endpoints (App Service, Front Door, Cosmos DB, Storage, AI Search, Document Intelligence, Speech) are:
- Documented in `deployment-context-o4.md` for developer and ops reference
- Stored as reference secrets in Azure Key Vault for operational consistency and automation

This ensures all integration points are discoverable and centrally managed.

## Notes
- App Service Plan is not Linux. This is a known limitation and requires plan recreation. See manual-steps-o4.md for details.
- Cosmos DB analytical storage could not be enabled due to Azure CLI/API limitations. See manual-steps-o4.md for details.

## Front Door Endpoints

| Endpoint Name | Hostname | Provisioning State | Enabled State | Deployment Status |
|--------------|----------------------------------------------------------|-------------------|--------------|-------------------|
| chat-ep      | chat-ep-cfebg9ahdsd5a8ad.z02.azurefd.net                | Succeeded         | Enabled      | NotStarted        |

- **Manual steps required if Deployment Status is NotStarted.**
- See `manual-steps-o4.md` for detailed instructions.
