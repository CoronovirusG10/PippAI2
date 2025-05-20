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
| App Service Plan (P1v3) | Runs production & staging slots |
| App Service *pippaioflondoncdx2-app* | Hosts the app |
| Staging slot *staging* | Future-change validation |
| Azure Cosmos DB (serverless) | Stores chats indefinitely |
| Azure OpenAI | Model hosting |
| Azure Storage (LRS) – *pippaioflondoncdx2store* | Logs & file uploads |
| Azure Key Vault | Secrets |
| Log Analytics + App Insights | Observability |

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
