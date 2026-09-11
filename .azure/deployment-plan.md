# AI Gateway Self-Hosted Gateway Demo Deployment Plan

## Status

Deployed on 2026-09-11 with Microsoft Prompt Shields and Content Safety enforced by APIM. Authenticated browser validation of the final jailbreak response remains pending.

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
- Inspect every Responses API prompt with Azure AI Content Safety before forwarding it to the model.
- Inspect every Responses API prompt with the Microsoft Prompt Shields container and block detected jailbreaks before content moderation or model invocation.
- Block prompts with medium-or-higher severity in Hate, SelfHarm, Sexual, or Violence and return a demonstrable HTTP 403 response.
- Apply the management-group policy exemption tag `SecurityControl=Ignore` to only the dedicated Content Safety account, enable local authentication, and use its key only as the connected container's metering credential.
- Run the Content Safety image as a CPU lab Container App in the existing environment, then route APIM inspection to that internal endpoint only after it is healthy.
- Use one `D4` workload profile named `cs-d4` with zero minimum and two maximum nodes because the Microsoft images exceed or can exceed the Consumption profile's 8 GB image limit. Assign only `ca-content-safety` and `ca-prompt-shields` to this profile; keep the gateway and UI on Consumption.
- Require Microsoft Entra sign-in before users can access the demo UI.
- Assign `AI.Limited` to one Entra security group and enforce Hate threshold 1 plus a per-user 1 TPM limit.
- Assign `AI.Unlimited` to a second Entra security group and enforce Hate threshold 7 with no LLM token limit.
- Create one disposable demo user in each group. Store generated one-time passwords only in the local macOS Keychain and require password change at first sign-in.
- Register the UI as an external traced application by linking workspace-based Application Insights to the Foundry project.
- Register `ai-gateway-external-agent` in Foundry with the same `gen_ai.agent.id` used by the Node OpenTelemetry spans.
- Capture each authenticated model interaction as OpenTelemetry, including the Entra object ID/name, policy tier, conversation ID, prompt, response or block reason, model, token usage, and status.

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

The Node UI exports the complete authenticated interaction as OpenTelemetry:

Node UI -> workspace-based Application Insights -> Log Analytics
											|
											v
							  Foundry project Tracing tab

The Content Safety extension adds this synchronous inbound path before the
generated AI Gateway API policy forwards an allowed request to the model:

APIM self-hosted gateway
	|
	| internal HTTPS /jailbreak:analyze
	v
Microsoft Prompt Shields container
	|
	| no attack detected
	v
Microsoft Content Safety container /text:analyze
	v
	| severity below threshold: continue; otherwise HTTP 403
	v
Generated Foundry API policy

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
| Application Insights | `appi-aigw-shgw-<suffix>` | External application OpenTelemetry and Foundry trace source |
| Container registry | `acraigwshgw<suffix>` | Basic private registry for the end-user UI image |
| Container Apps environment | `cae-aigw-shgw-<suffix>` | Consumption workload profile |
| Container app | `ca-shgw-demo` | Public UI on port 3000 plus local gateway sidecar on port 8080 |
| Content Safety billing account | `csc-aigw-shgw-<suffix>` | S0 account used only for connected-container licensing and metering |
| Prompt Shields container app | `ca-prompt-shields` | Internal-only Microsoft `promptshields` preview image on `cs-d4` |

No VNet, private endpoint, Key Vault, storage account, or custom domain is required. A Basic ACR stores the private end-user UI image.

The demo intentionally records full prompt and response text. This data can contain personal, confidential, or regulated content and is available to principals with trace/log access. Do not use this capture mode for production traffic; disable message-content attributes or add redaction and retention controls first.

The preview container requires an API key for metering, but this tenant enforces `disableLocalAuth=true`. The selected managed endpoint uses the built-in `llm-content-safety` APIM policy and keyless managed-identity authentication instead.

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

The Content Safety extension adds S0 request charges. No additional container compute is deployed.

The two customer-hosted safety containers can allocate up to two D4 nodes. Each app has `minReplicas=1`, so both nodes can remain allocated until the apps are stopped or removed.

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
- [x] Content Safety S0 is available in Sweden Central and the pinned `text-analyze:1.0.0-amd64-preview` image manifest is available from MCR.
- [x] The isolated Content Safety Bicep module builds and lints without warnings.
- [x] Resource-group ARM validation succeeds against the existing APIM product and Container Apps environment.
- [x] Resource-group what-if contains two creates and one product-policy deployment, with no deletes or changes to the existing gateway or Foundry resources.
- [x] The custom policy is inherited at product scope and leaves the Foundry-generated API routing policy unchanged.
- [x] The effective `CognitiveServices_LocalAuth_Modify` policy was inspected and confirms `SecurityControl=Ignore` bypasses the local-auth modification at resource or resource-group scope.
- [x] The account-only Bicep module builds and lints cleanly with the exemption tag and `disableLocalAuth=false`.
- [x] ARM validation passes and what-if shows one in-place local-auth modification, zero creates, and zero deletes.
- [x] The Microsoft `promptshields:latest` image manifest is available from MCR.
- [x] `prompt-shields-container.bicep` builds and lints without errors or warnings.
- [x] Resource-group ARM validation and what-if show only the new internal `ca-prompt-shields` app and the expected APIM product-policy modification, with no deletes.
- [x] The D4 workload profile is configured for up to two nodes while the gateway and UI remain on Consumption.
- [x] Direct container validation detects a known jailbreak prompt and allows a benign prompt.
- [ ] End-to-end APIM validation returns HTTP `403` with `PromptAttackDetected` for a jailbreak while preserving the existing safe and harmful-content behavior.

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
10. Confirm the `AppInsights` project connection targets the new component, generate one authenticated request, and locate its conversation ID and end-user identity in Foundry **Tracing**.

## Section 7: Validation Proof

Prompt Shields extension predeployment validation date: 2026-09-11.

- Microsoft documentation confirms `mcr.microsoft.com/azure-cognitive-services/contentsafety/promptshields:latest` is the official preview container for user-prompt jailbreak and document prompt-injection detection.
- `docker manifest inspect` confirmed the current `promptshields:latest` image manifest is available from MCR.
- `prompt-shields-container.bicep`, `content-safety.bicep`, and `resources.bicep` build and lint successfully; `deploy.sh` and `validate.sh` pass `bash -n`; `git diff --check` passes.
- Resource-group ARM validation passed for `prompt-shields-container.bicep`; what-if shows exactly one create (`ca-prompt-shields`), zero modifications, and zero deletions.
- The APIM product-policy ARM validation passed; what-if shows only the expected policy deployment and no resource deletion.
- Static RBAC review confirms no new role assignment is required. Prompt Shields uses the existing dedicated Content Safety account key solely for connected-container metering.
- The deployment raises only the `cs-d4` profile maximum from one to two nodes; `ca-shgw-demo` remains on Consumption.
- Runtime readiness and direct jailbreak classification are complete; authenticated browser validation remains pending.
- Live deployment created internal-only `ca-prompt-shields` on `cs-d4`; revision `ca-prompt-shields--20260911043818` is Healthy and Running with one replica.
- Direct runtime calls returned class `0` for a benign prompt and class `1` for a known jailbreak, with jailbreak score approximately `0.998`.
- The live APIM product policy contains `/contentsafety/jailbreak:analyze`, `PromptAttackDetected`, `/contentsafety/text:analyze`, and `ContentSafetyViolation`.
- The public command-line test is intentionally blocked by Easy Auth without a fresh role-bearing ID token. Final browser validation remains pending and must use one of the documented demo users.

Entra role-policy validation date: 2026-09-10.

- The authenticated Node proxy passes syntax validation and forwards only the Easy Auth-provided ID token to APIM; the APIM subscription key remains server-side.
- The role-aware APIM policy compiles locally and passes ARM validation against the existing product with Entra authentication enabled.
- Container Apps Easy Auth is configured only after the authenticated UI revision is deployed; the APIM role policy is enabled last to avoid partial lockout.
- Entra app roles are assigned to groups rather than embedding tenant-specific group IDs in the APIM policy.
- The local Docker build reached Docker Hub unsuccessfully due to a network timeout; the existing Azure Container Registry build remains the deployment validation path.

Content Safety extension validation date: 2026-09-09.

Container retry validation date: 2026-09-09.

- Policy rule: management-group definition `CognitiveServices_LocalAuth_Modify` excludes resources when `tags['SecurityControl'] == 'Ignore'`; defaults resolve to the exact requested name and value.
- Final account IaC: `content-safety-container-account.bicep` sets `SecurityControl: Ignore` and `disableLocalAuth: false` only on `csc-aigw-shgw-demo1234`.
- Local validation: Bicep build and lint passed with no template warnings; `git diff --check` passed.
- ARM validation: resource-group validation passed.
- ARM what-if: one in-place modification (`disableLocalAuth: true => false`), zero creates, zero deletes, and all unrelated resources ignored.
- Staged cutover: the verified managed Content Safety policy remains active until key listing, container readiness, direct container classification, and public `200/403` behavior pass.
- Container module: `content-safety-container.bicep` builds and lints cleanly with the key modeled as a secure parameter and internal-only ingress.
- Container preflight initially rejected a 120-second liveness delay; it was corrected to the platform maximum of 60 seconds and revalidated.
- Container ARM validation passed. Final what-if shows one create (`ca-content-safety`), zero modifications, zero deletes, and eight existing resources ignored.
- First Consumption deployment proved the image exceeds the 8 GB per-replica image limit (`ImagePullFailure: no space left on device`). Sweden Central supports D4, and the existing environment supports adding dedicated profiles. The corrected app targets `cs-d4` with 4 vCPU and 16 GiB.
- D4 remediation validation: `az containerapp env workload-profile list-supported --location swedencentral` confirmed D4 with 4 vCPU/16 GiB; Bicep build/lint and whitespace checks passed. The change adds one profile and moves only the failed `ca-content-safety` revision; existing gateway/UI traffic remains on Consumption.
- Container runtime proof: image size 8,995,255,477 bytes pulled successfully on D4; billing returned HTTP 200; model decrypted and initialized on CPU; revision became healthy and listened on port 5000.
- Internal API proof: `/ready` returned HTTP 200; `/contentsafety/text:analyze` returned HTTP 200 for safe and Hebrew violence prompts, with violence severity 5 for the demo prompt.
- APIM cutover validation: parameterized policy compiles and passes ARM validation with the internal FQDN, no managed-identity header, and `FourSeverityLevels`. Empty endpoint/default authentication parameters restore the managed Azure endpoint.
- Container billing isolation: the original account was created while local auth was policy-disabled; although regenerated Key1 works for inference, connected-container metering returns 403. A new `csc-aigw-shgw-demo1234` account will be created with `SecurityControl=Ignore` and local auth enabled from initial creation.
- Container billing account validation: Bicep build/lint and ARM validation passed; what-if shows one create (`csc-aigw-shgw-demo1234`), zero modifications, zero deletes, and nine existing resources ignored.

- Authentication: Azure CLI resolved subscription `00000000-0000-0000-0000-000000000000`, tenant `00000000-0000-0000-0000-000000000000`, and user `admin@example.com`.
- Image: `docker manifest inspect mcr.microsoft.com/azure-cognitive-services/contentsafety/text-analyze:1.0.0-amd64-preview` passed.
- SKU: `az cognitiveservices account list-skus --kind ContentSafety --location swedencentral` returned S0 Standard.
- Local build: `az bicep build` and `az bicep lint` passed for `content-safety.bicep` and the original `main.bicep`, with no template warnings.
- Script validation: `bash -n deploy.sh validate.sh` passed.
- ARM validation: `az deployment group validate` passed against `rg-aigw-shgw-demo` with the existing APIM product and Container Apps environment.
- Initial ARM what-if covered the proposed container path. Deployment discovery showed the tenant enforces `disableLocalAuth=true`, while the preview container requires an API key for metering. The user selected the managed endpoint fallback.
- Final managed deployment created `cs-aigw-shgw-demo1234`, assigned least-privilege data-plane roles, and deployed the generated product policy with no resource deletion.
- Static RBAC: no new role assignment is required. The Content Safety key is scoped to the dedicated metering account and injected into the internal Container App secret store.
- Post-deployment checks are defined in `validate.sh safety`: internal-only ingress, policy presence, safe HTTP 200, violent HTTP 403, blocking header, and `ContentSafetyViolation` response.

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

- Recovery proof: accidental deletion of `csc-aigw-shgw-demo1234` caused billing DNS failures and APIM `send-request` timeouts. The soft-deleted account was recovered with its tag, local-auth setting, endpoint, and keys intact; internal validation passed, then public requests returned HTTP 200/403 as expected.
- Container-only Content Safety account `csc-aigw-shgw-demo1234` was created with `SecurityControl=Ignore` and local authentication enabled from inception; its initial key passed direct API validation and connected-container metering returned HTTP 200.
- Container App `ca-content-safety` runs `text-analyze:latest` on dedicated profile `cs-d4` with 4 vCPU, 16 GiB, CPU inference, internal-only ingress, and a healthy ready revision.
- Internal `/ready` returned HTTP 200. Direct container analysis scored the Hebrew demo prompt as violence severity 5.
- Live APIM product policy targets the internal Container App FQDN, uses `FourSeverityLevels`, and sends no cloud authentication header.
- Public gateway and browser UI validation returned HTTP 200 for safe prompts and HTTP 403 for the Hebrew violence prompt.
- Container logs recorded the final APIM/UI analysis calls locally with approximately 265–317 ms model time.
- The temporary managed fallback account `cs-aigw-shgw-demo1234` was deleted after local-container validation completed.
- APIM and the Azure-hosted self-hosted gateway runtime identities have `Cognitive Services User` scoped only to the Content Safety account.
- The generated product policy sends an isolated managed-identity request to Content Safety, preventing the Foundry `api-key` subscription header from overriding bearer authentication.
- Direct public gateway validation returned HTTP `200` for a safe prompt and HTTP `403` with `ContentSafetyViolation` for a violent prompt.
- Public UI validation returned HTTP `200` with `UI_CONTENT_SAFETY_SAFE_OK` for a safe prompt and HTTP `403` with `Prompt blocked by Azure AI Content Safety.` for a violent prompt.

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