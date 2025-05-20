# Container supply-chain security

- Always pin base images by digest, e.g.  
  `FROM mcr.microsoft.com/azure-app-service/node:20@sha256:<digest>`
- A GitHub Action (`.github/workflows/container-scan.yml`) runs Trivy on every PR and blocks merges on critical CVEs.
