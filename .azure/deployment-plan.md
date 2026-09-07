# AI Gateway Self-Hosted Gateway Demo Deployment Plan

## Status

Deployed and verified on 2026-09-07.

## Target

- Subscription: `00000000-0000-0000-0000-000000000000`
- Purpose: Disposable demonstration of Microsoft Foundry AI Gateway backed by classic Azure API Management and an independently hosted self-hosted gateway container.
- Region: Sweden Central.
- Resource group: `rg-aigw-shgw-demo`.
- Runtime: Azure Container Apps consumption, using one fixed replica.

## Requirements

- Reuse suitable existing Foundry and APIM resources when available.
- Keep the demo isolated from the repository's existing hub-spoke deployment.
- Expose a simple HTTPS endpoint that an end user can call during a demo.
- Demonstrate Foundry-created LLM token policy enforcement at the self-hosted gateway.
- Surface native Azure Monitor metrics for successful and blocked calls.
- Avoid storing gateway tokens, model keys, or subscription keys in source control.
- Include repeatable infrastructure/configuration and cleanup instructions.

## Discovery Findings

- The subscription is accessible and already contains unrelated Foundry, APIM, and Container Apps resources. The demo will not reuse or modify them.
- Existing APIM instances use Basic v2, Standard v2, or AI Gateway tiers. Self-hosted gateways require Developer or Premium, so a new classic Developer instance is required.
- `Microsoft.ApiManagement`, `Microsoft.App`, `Microsoft.CognitiveServices`, and `Microsoft.OperationalInsights` are registered. `Microsoft.ContainerInstance` is not registered.
- Azure Container Apps is the documented Azure deployment target for the APIM self-hosted gateway and supplies managed HTTPS ingress, secrets, revisions, health checks, and Log Analytics integration.
- GPT-4.1-mini version `2025-04-14` supports Standard, Global Standard, and Data Zone Standard in Sweden Central. Available subscription quota is 5,000K TPM for both Standard and Global Standard, and 2,000K TPM for Data Zone Standard.

## Architecture

```text
Demo client
	|
	| HTTPS + APIM subscription key
	v
Azure Container Apps public ingress
	|
	| HTTP 8080 + X-Forwarded-Proto=https
	v
APIM self-hosted gateway (one replica)
	|
	| generated AI Gateway API and policies
	v
Microsoft Foundry project / GPT-4.1-mini deployment

Classic APIM Developer remains the cloud control plane. The self-hosted gateway
polls its configuration endpoint and publishes heartbeat and metrics to Azure.
```

The gateway will use the pinned Microsoft image and these runtime controls:

- External Container Apps HTTPS ingress with insecure HTTP disabled.
- Target port `8080`; TLS terminates at Container Apps ingress.
- `net.server.http.forwarded.proto.enabled=true` so APIM reconstructs the original HTTPS scheme.
- Gateway token stored as a Container Apps secret, never in source control or command output.
- Exactly one replica (`minReplicas=1`, `maxReplicas=1`). Container Apps does not support the UDP synchronization used by self-hosted gateway rate-limit counters, so scaling above one replica would make the demo limit nondeterministic.
- Lightweight consumption allocation, initially `0.25` vCPU and `0.5 GiB`, subject to image startup validation.

## Azure Resources

Names with `<suffix>` receive one generated lowercase suffix during deployment and are persisted in the local ignored environment file.

| Resource | Planned name | Notes |
| --- | --- | --- |
| Resource group | `rg-aigw-shgw-demo` | Isolated lifecycle and cleanup boundary |
| Foundry account | `aif-aigw-shgw-<suffix>` | Public network access for the portable demo |
| Foundry project | `proj-aigw-shgw-demo` | Associated with AI Gateway |
| Model deployment | `gpt-4.1-mini` | Global Standard, version `2025-04-14`, 10K TPM |
| API Management | `apim-aigw-shgw-<suffix>` | Classic Developer, system-assigned identity, AI Gateway Early channel |
| Self-hosted gateway | `shgw-demo` | Registered in APIM and assigned the generated API |
| Log Analytics workspace | `law-aigw-shgw-<suffix>` | Container stdout/stderr and operational diagnostics |
| Container registry | `acraigwshgw<suffix>` | Basic private registry for the end-user UI image |
| Container Apps environment | `cae-aigw-shgw-<suffix>` | Consumption workload profile |
| Container app | `ca-shgw-demo` | Public UI on port 3000 plus local gateway sidecar on port 8080 |

No VNet, private endpoint, Key Vault, storage account, or custom domain is required. A Basic ACR stores the private end-user UI image.

## Planned Artifacts

- `deployment/ai-gateway-self-hosted/README.md`: end-to-end runbook, portal checkpoints, evidence checklist, and cleanup.
- `deployment/ai-gateway-self-hosted/demo.env.example`: non-secret deployment settings.
- `deployment/ai-gateway-self-hosted/main.bicep`: subscription-scoped entry point that creates the resource group and deploys Foundry, project, model, APIM, Log Analytics, and Container Apps resources.
- `deployment/ai-gateway-self-hosted/main.bicepparam`: safe defaults without secrets.
- `deployment/ai-gateway-self-hosted/deploy.sh`: prerequisite checks, infrastructure deployment, gateway registration, secret injection, Container App deployment, and API assignment.
- `deployment/ai-gateway-self-hosted/validate.sh`: resource state, heartbeat, health endpoint, allowed call, blocked call, and Azure Monitor metric checks.
- `deployment/ai-gateway-self-hosted/cleanup.sh`: explicit resource-group deletion with subscription/name confirmation.

The deploy script will stop at any portal-only checkpoint. Each checkpoint must be documented in the runbook and captured as an applied-state screenshot under `docs/images/ai-gateway-self-hosted-azure/` before deployment continues:

1. APIM is enrolled in the AI Gateway Early update channel.
2. Foundry shows the classic APIM association and project enabled for AI Gateway.
3. Foundry token management shows the demo limit.

Where a stable ARM operation exists, the script will automate it, including assigning the generated API to `shgw-demo`.

## Cost Estimate

Indicative USD retail cost for a continuously available demo, before tax and agreement discounts:

- APIM Developer: `$0.0658/hour`, approximately `$48/month` at 730 hours.
- Container Apps at one `0.25` vCPU / `0.5 GiB` active replica: approximately `$14/month` after the standard monthly consumption grant, assuming continuous active billing.
- Foundry account/project: no fixed platform charge; GPT-4.1-mini is billed per token.
- Log Analytics and network egress: usage-based and expected to be small for demo traffic.
- Basic Azure Container Registry: an additional small fixed monthly charge.

Expected baseline: approximately `$62/month` plus model tokens, logs, and any network charges. Deleting `rg-aigw-shgw-demo` stops all recurring demo infrastructure charges.

## Validation

Recipe type: Bicep, subscription scope.

### All validation checks pass

- [x] Azure CLI is installed and authenticated to the approved subscription.
- [x] Bicep build and lint complete without errors or warnings.
- [x] Shell scripts pass `bash -n` and macOS Bash 3.2 compatibility review.
- [x] Required resource providers are registered.
- [x] GPT-4.1-mini Global Standard is supported and at least 10K TPM quota is available in Sweden Central.
- [x] Subscription-scope ARM validation succeeds.
- [x] Subscription-scope what-if contains only expected creates inside `rg-aigw-shgw-demo` and no deletes.
- [x] Azure Policy assignments have been reviewed for blocking effects.
- [x] Static RBAC review confirms APIM receives Cognitive Services User on only the new Foundry account.

Pre-deployment checks:

1. Validate Bicep and shell syntax.
2. Run Azure resource-name availability checks.
3. Confirm provider registration, role permissions, APIM Developer availability, and GPT-4.1-mini SKU/quota.
4. Run ARM/Bicep validation and what-if against the target resource group.
5. Confirm that no planned operation targets resources outside `rg-aigw-shgw-demo`.

Post-deployment proof:

1. Verify every resource ID, provisioning state, SKU, region, and parent relationship directly from Azure.
2. Confirm the Container App has exactly one ready replica and HTTPS-only public ingress.
3. Call the gateway health endpoint and receive HTTP 200.
4. Confirm APIM reports a current self-hosted gateway heartbeat.
5. Confirm the generated Foundry API is assigned to `shgw-demo`.
6. Send an allowed model request through the Container Apps FQDN and receive HTTP 200.
7. Send a request that exceeds the configured token limit and receive HTTP 429 from the self-hosted gateway.
8. Confirm native Azure Monitor metrics record the token-limit rejection.
9. Capture required portal screenshots and add them to the runbook.

## Section 7: Validation Proof

Validation date: 2026-09-07.

- Target confirmation: Azure CLI resolved subscription `00000000-0000-0000-0000-000000000000`; the signed-in principal has subscription Owner.
- Local build: `az bicep build --file main.bicep` passed with no Bicep warnings.
- Lint: `az bicep lint --file main.bicep` passed with no Bicep warnings.
- Script validation: `bash -n deploy.sh validate.sh cleanup.sh` passed; scripts use Bash 3.2-compatible syntax.
- Formatting: `git diff --check -- .` passed.
- Providers: API Management, Container Apps, Cognitive Services, and Operational Insights are registered.
- Model: GPT-4.1-mini `2025-04-14` supports Global Standard in Sweden Central; 5,000K TPM was available before deployment.
- ARM validation: `az deployment sub validate` passed, including APIM Developer and the Preview release channel.
- ARM what-if: 9 creates, 0 modifications, and 0 deletions. All child resources are under `rg-aigw-shgw-demo`; the only subscription-level resource is that resource group.
- Policy review: the three applicable assignments are Defender initiatives for SQL or open-source relational databases; none affects the planned resource types or public ingress.
- Static RBAC: APIM receives Cognitive Services User (`a97b65f3-24c7-4388-baec-2e87135dc908`) scoped only to the new Foundry account. No other demo component performs an external managed-identity data operation.
- Secret review: gateway and APIM subscription keys are held in process memory, are not echoed, and are not written to repository configuration.

## Deployment Proof

- Subscription deployments `aigw-shgw-demo` and `aigw-shgw-demo-container` succeeded.
- All resources were created only in `rg-aigw-shgw-demo` in Sweden Central.
- Container App revision `ca-shgw-demo--0000002` runs gateway image `2.12.1`, is healthy, and has exactly one replica.
- Public gateway status endpoint returned HTTP `200`.
- APIM-to-Foundry live RBAC is Cognitive Services User scoped to `aif-aigw-shgw-demo1234`.
- Foundry association shows `proj-aigw-shgw-demo` enabled on `apim-aigw-shgw-demo1234`.
- Generated API `aif-aigw-shgw-demo1234` is assigned to `shgw-demo`.
- Functional GPT-4.1-mini request returned HTTP `200` with `SELF_HOSTED_AZURE_OK`.
- Temporary 1 TPM validation produced HTTP `200` followed by HTTP `429`; the denied request recorded `OpenAITokenLimitExceeded` in inbound `llm-token-limit` processing without backend response fields.
- Azure Monitor Requests split by Last Error Reason showed `OpenAITokenLimitExceeded = 1`.
- The temporary limit was removed, the preview empty-variable policy was repaired, and a final request returned HTTP `200`.

## Deployment and Cleanup

Deployment was explicitly approved and completed in this order:

1. Generate the deployment artifacts.
2. Run local syntax/build validation and Azure preflight/what-if.
3. Present the what-if summary and any changed assumptions.
4. Deploy the isolated resource group.
5. Complete and capture the documented portal checkpoints.
6. Deploy the self-hosted gateway container and run the post-deployment proof.

Cleanup deletes only `rg-aigw-shgw-demo`. The script must display the target subscription, resource group, and contained resources and require an exact resource-group-name confirmation before deletion.