Manual steps after the script finishes
======================================

1. In Azure OpenAI Studio, request **Grounding-for-Bing** approval.
2. Deploy GPT-4o and GPT-4 Turbo in the OpenAI resource.
3. Check Front Door health:  
   `curl -I https://<fd>.azurefd.net/health` → expect **HTTP 200**.
4. Open **Front Door ▸ WAF ▸ chat-waf**, confirm mode = Prevention and hit-count = 0.
5. In GitHub Actions, manually trigger **loadtest.yml** (k6 soak) after each release.
