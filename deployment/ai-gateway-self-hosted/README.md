# Azure-hosted APIM self-hosted gateway demo

This deployment creates an isolated Microsoft Foundry AI Gateway demonstration in Azure. A classic API Management Developer instance remains the control plane while its self-hosted gateway data plane runs as one Azure Container Apps replica behind a public HTTPS endpoint.

## Deploy

1. Create the local configuration file:

   ```bash
   cp demo.env.example demo.env
   ```

2. Validate without changing Azure:

   ```bash
   ./validate.sh preflight
   ```

3. Deploy Foundry, GPT-4.1-mini, APIM, the gateway registration, Log Analytics, the Container Apps environment, and the gateway container:

   ```bash
   ./deploy.sh all
   ```

The generated gateway bootstrap token is held in process memory only and passed as a secure Bicep parameter. It expires after seven days; a running gateway continues to operate after token expiry, but redeployment requires a newly generated token.

## End-user demo UI

After the Foundry association and API assignment are complete, deploy the browser UI:

```bash
./deploy.sh ui
```

This command creates a private Basic Azure Container Registry, builds the dependency-free Node UI image, and adds it as a sidecar to `ca-shgw-demo`. The Container Apps hostname then serves the UI at `/`, while the generated API path continues to proxy to the gateway container.

Open the UI and select **Run demo**:

```text
https://ca-shgw-demo.environment-domain.swedencentral.azurecontainerapps.io/
```

The browser calls only the same-origin `/api/run` endpoint. The Node container sends the request to `http://localhost:8080`, and the APIM project key remains in the Container Apps secret store; it is never returned to the browser.

Validate the end-user flow:

```bash
./validate.sh ui
```

## Content Safety demo

The customer-hosted path runs the Microsoft Content Safety image inside the same Container Apps environment as the self-hosted gateway. The Azure Content Safety account is used only for licensing and metering.

The management-group policy normally forces `disableLocalAuth=true`. This lab applies `SecurityControl=Ignore` only to the dedicated container billing account `csc-aigw-shgw-demo1234`, enabling the API key required by the connected container.

Do not delete `csc-aigw-shgw-demo1234` while `ca-content-safety` is running. The container must periodically reach that account for licensing and metering; deleting it causes Content Safety calls to time out and the demo to return HTTP `500`.

Deploy the local container without changing APIM routing:

```bash
bash ./deploy.sh safety-container
```

The image exceeds the Container Apps Consumption image limit of 8 GB. The deployment therefore adds a D4 profile named `cs-d4` and assigns only `ca-content-safety` to it. The gateway and UI remain on Consumption. The container uses the current `text-analyze:latest` preview image and runs with 4 vCPU, 16 GiB, `CUDA_ENABLED=false`, internal-only ingress, and one replica.

Validate the container before changing APIM:

```bash
bash ./validate.sh safety-container
```

After validation passes, deploy the local-only product policy with the internal `ca-content-safety` FQDN. The policy extracts the Responses API `input` and calls the local `/contentsafety/text:analyze` endpoint before the Foundry API policy runs.

```bash
bash ./deploy.sh safety-local
bash ./validate.sh safety
```

The policy blocks Violence severity 1 or higher for a deterministic lab demonstration. Hate, Sexual, and SelfHarm remain at threshold 4. It uses the eight-level scale from 0 through 7. The isolated request is required because this Foundry API uses the `api-key` header for its APIM subscription; forwarding that unrelated key to Content Safety overrides bearer authentication and returns `401`.

| Category | Example content blocked at threshold 4 |
| --- | --- |
| Violence | Threats, stated intent to kill, graphic violence, severe injury, or physical assault |
| Hate | Abusive or dehumanizing attacks against protected identity groups |
| Sexual | Explicit sexual content |
| SelfHarm | Instructions or encouragement for suicide or self-injury |

Run the end-to-end proof:

```bash
./validate.sh safety
```

The check sends one safe prompt and expects HTTP `200`, then sends a clearly graphic violent prompt and expects HTTP `403` with `ContentSafetyViolation`. The same blocked prompt entered at the public UI displays `Prompt blocked by Azure AI Content Safety.` Capture the applied result as `docs/images/ai-gateway-self-hosted-azure/06-content-safety-blocked.png`.

Key changes require a fresh Container Apps revision. Set `ROTATE_CONTENT_SAFETY_KEY=true` only when rotation is required; normal reruns reuse the current key. Azure's container metering backend can take several minutes to recognize a newly regenerated key.

Foundry policy changes can replace the project product policy; rerun the selected safety deployment after such a change.

## Foundry association checkpoint

After the base deployment finishes:

1. Open the new APIM service and verify **Deployment + infrastructure → Service updates (preview)** shows update group **Early**. Capture the applied state as `docs/images/ai-gateway-self-hosted-azure/01-apim-ai-gateway-early.png`.
2. In Microsoft Foundry, open `proj-aigw-shgw-demo`, then **Manage → AI Gateway → Add AI Gateway**.
3. Select the new Foundry resource, choose **Use existing**, select `apim-aigw-shgw-demo1234`, and add `proj-aigw-shgw-demo`.
4. Capture the associated gateway and enabled project as `docs/images/ai-gateway-self-hosted-azure/02-foundry-gateway-associated.png`.
5. List the generated APIs:

   ```bash
   az apim api list \
     --service-name apim-aigw-shgw-demo1234 \
     --resource-group rg-aigw-shgw-demo \
     --query '[].{id:name,displayName:displayName,path:path}' \
     --output table
   ```

6. Add the generated API ID and path to `demo.env`, then assign it to the self-hosted gateway:

   ```bash
   ./deploy.sh assign
   ```

7. Find the project subscription and add its identifier to `demo.env`:

   ```bash
   az apim subscription list \
     --service-name apim-aigw-shgw-demo1234 \
     --resource-group rg-aigw-shgw-demo \
     --query '[].{id:name,displayName:displayName,scope:scope,state:state}' \
     --output table
   ```

Do not store the returned subscription key in `demo.env`; the validation script retrieves it only for the duration of the request.

## Validate the demo

Validate deployed state and the gateway health endpoint:

```bash
./validate.sh deployed
```

After association and API assignment, run an end-to-end model request:

```bash
./validate.sh functional
```

To prove local token enforcement:

1. In Foundry, open the associated gateway and select **Token management → Limits**.
2. Set the GPT-4.1-mini project limit to `1` token per minute.
3. Capture the applied setting as `docs/images/ai-gateway-self-hosted-azure/03-token-limit-1-tpm.png`.
4. Repeat the functional request. Expect HTTP `429` with `OpenAITokenLimitExceeded` before a backend call.
5. In APIM, open **Self-hosted gateways → shgw-demo → Metrics**. Chart **Requests**, filter to the gateway location, and split by **Last Error Reason**. Capture the result as `docs/images/ai-gateway-self-hosted-azure/04-token-limit-metrics.png`.
6. Remove the test limit and confirm a final functional request returns HTTP `200`. If the preview UI leaves an empty token-limit variable, restore the project product policy to its base policy before retesting.

Container stdout is available in the Container App logs. Self-hosted request diagnostics are not uploaded to `ApiManagementGatewayLogs`; use APIM native metrics for the enforcement proof.

## Validated deployment

Validated on 2026-09-07 in subscription `00000000-0000-0000-0000-000000000000`:

- Resource group: `rg-aigw-shgw-demo`
- Foundry account/project: `aif-aigw-shgw-demo1234` / `proj-aigw-shgw-demo`
- APIM/gateway: `apim-aigw-shgw-demo1234` / `shgw-demo`
- Generated API and path: `aif-aigw-shgw-demo1234`
- Container Apps endpoint: `https://ca-shgw-demo.environment-domain.swedencentral.azurecontainerapps.io`
- Runtime image: `mcr.microsoft.com/azure-api-management/gateway:2.12.1`
- UI image: private `acraigwshgwdemo1234.azurecr.io/aigw-demo-ui:<timestamp>`

The initial `2.9.2` image could not compile Foundry's generated API policy because it did not expose `context.Request.Foundry.Deployment`. Version `2.12.1` compiled the policy and completed an end-to-end GPT-4.1-mini request.

Validation results:

| Check | Result |
| --- | --- |
| Status endpoint | HTTP `200` |
| Foundry API assignment to `shgw-demo` | Verified |
| Baseline model request | HTTP `200`, `SELF_HOSTED_AZURE_OK` |
| First request after setting 1 TPM | HTTP `200` |
| Second request | HTTP `429`, `OpenAITokenLimitExceeded` |
| Rejected request backend fields | Absent; policy stopped it in inbound processing |
| Azure Monitor Requests split | `OpenAITokenLimitExceeded = 1` |
| Final request after cleanup | HTTP `200` |
| End-user UI model request | HTTP `200`, `UI_DEMO_OK` |
| Content Safety safe prompt | HTTP `200`, model called |
| Content Safety violent prompt | HTTP `403`, `ContentSafetyViolation`, model not called |
| End-user UI violent prompt | HTTP `403`, `Prompt blocked by Azure AI Content Safety.` |
| Local container readiness | HTTP `200`, valid metering key |
| Local Hebrew classification | Violence severity `5` |
| Live APIM safety endpoint | Internal `ca-content-safety` FQDN |

Removing the test limit reproduced the preview empty-variable issue. The project product policy was restored to a base-only policy and verified to contain no `tokenlimit-*` variable before the final request.

Evidence:

- `docs/images/ai-gateway-self-hosted-azure/01-apim-ai-gateway-early.png`
- `docs/images/ai-gateway-self-hosted-azure/02-foundry-gateway-associated.png`
- `docs/images/ai-gateway-self-hosted-azure/03-token-limit-1-tpm.png`
- `docs/images/ai-gateway-self-hosted-azure/04-token-limit-metrics.png`

## Cleanup

```bash
./cleanup.sh
```

The script lists the resources and requires the exact resource-group name before starting deletion.