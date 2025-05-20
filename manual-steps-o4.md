<!-- ...existing intro... -->
1. After deployment finishes, run  
   `curl -I https://<your-frontdoor>.azurefd.net` and confirm an HTTP 200.
2. Open **Front Door ▸ WAF ▸ chat-waf** and verify default rules are in *Prevention* mode.
3. From GitHub **Actions ▸ Load Test** trigger the *Load Test* workflow manually and review results in the run summary.
