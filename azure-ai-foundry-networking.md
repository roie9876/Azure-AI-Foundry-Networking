# Microsoft Foundry Networking and Security at Enterprise Scale

> **Updated March 2026** — This document reflects the current Microsoft Foundry (formerly Azure AI Foundry / Azure AI Studio) networking model, including the new Foundry Account + Project architecture, Agent Service setup tiers, and VNet injection for outbound network isolation.

## Overview

Microsoft Foundry is a unified, enterprise-ready platform for building, testing, deploying, and managing generative AI applications at scale. It provides a web portal ([Foundry portal](https://ai.azure.com)) and integrated toolset that let AI developers and data scientists collaborate on AI solutions with enterprise-grade governance and security in place. By consolidating Azure's AI services (like Azure OpenAI, Cognitive Services, and Search) with compute infrastructure and tools, Foundry accelerates AI development while ensuring compliance, security, and scalability for production use.

At a high level, Microsoft Foundry offers a top-level **Foundry Account** (resource) to define shared configurations and resources, and multiple **Projects** under each account to isolate workloads. This structure allows IT teams to set up a preconfigured AI environment (the account) that developers can use to spin up projects quickly without waiting on bespoke infrastructure setups. In practice, this means organizations can prototype and implement AI solutions faster, with the account enforcing central policies (networking, identity, encryption, etc.) across all projects automatically.

## Foundry Account and Projects

### Microsoft Foundry Account

The Foundry Account is the top-level resource container (resource type `Microsoft.CognitiveServices/accounts`). It acts as a central management plane for a team or department's AI environment. The account defines common settings and shared assets, including: network and security configurations, allocated compute capacity and quotas, connections to external data or AI services, and model deployments. An account can host multiple projects, and any security or networking setting on the account is inherited by its projects (enforcing uniform guardrails). The account also manages shared resources like foundational AI model endpoints (Azure OpenAI, etc.) that can be accessed across projects via **Connections** (authenticated links to external resources). In essence, the account is where IT admins or platform engineers configure the "environment" — virtual network, identity integration, keys, policies, and so on — and manage high-level resources and user access.

A key new concept is the **Capability Host** — a sub-resource that exists on both the account and the project. The account-level capability host enables Agent Service for the account (with `capabilityHostKind="Agents"`), while the project-level capability host specifies the data resources (Cosmos DB, Storage, AI Search) used by agents within that project. Capability hosts cannot be updated after creation.

### Microsoft Foundry Project

A project is an isolated workspace within a Foundry Account, intended for an individual team, application, or AI workload. Each project serves as a sandbox for developers or data scientists to build and deploy AI solutions without affecting other projects. Projects isolate assets like data, models, and experiments. Project members can create agents, fine-tune or import models, and deploy endpoints, all within the resource and policy boundaries defined by the account. Projects can also have project-scoped connections to data sources or services that shouldn't be shared with other projects. While projects inherit the account's configurations, they allow further role-based access control at the project level (so a user could be an Azure AI User in one project but have no access to another project in the same account).

#### Project-Level Data Isolation

Standard setup enforces project-level data isolation by default. Two blob storage containers are automatically provisioned in your storage account: one for files and one for intermediate system data (chunks, embeddings). Three containers are provisioned in your Cosmos DB account: one for user threads, one for system messages, and one for agent configuration data such as instructions, tools, and names.

## Agent Service Setup Tiers

Before diving into networking, it's important to understand the three Agent Service environment configurations, since the networking model is tightly coupled to which tier you choose.

### Compare Setup Options

| Capability | Basic Setup | Standard Setup | Standard + BYO VNet |
|-----------|-------------|----------------|---------------------|
| Get started quickly without managing resources | ✅ | | |
| All conversation history, files, and vector stores in your own resources | | ✅ | ✅ |
| Support for Customer Managed Keys (CMK) | | ✅ | ✅ |
| Private Network Isolation (Bring your own virtual network) | | | ✅ |

> **Note:** Inbound secured communication (private endpoint + disabled public access) can be applied to **all** setups. The "Private Network Isolation" row above refers specifically to *outbound* agent traffic isolation.

### Basic Setup

The basic setup uses Microsoft-managed multitenant storage for agent state. It is compatible with the OpenAI Assistants API and includes built-in tools plus support for non-OpenAI models. This is ideal for prototyping and quick development. No BYO resources are needed — just a Foundry Account and Project.

### Standard Setup

Standard setup requires you to **Bring Your Own (BYO) resources** so that all agent data stays in your Azure tenant:

| Resource | Purpose |
|----------|---------|
| **Azure Storage** (BYO File Storage) | Files uploaded by developers and end-users |
| **Azure AI Search** (BYO Search) | Vector stores created by the agent |
| **Azure Cosmos DB for NoSQL** (BYO Thread Storage) | Messages, conversation history, and agent metadata |

All data processed by Foundry Agent Service is automatically stored at rest in these resources, helping you meet compliance requirements and enterprise security standards.

#### Cosmos DB Throughput Requirements

Your Azure Cosmos DB for NoSQL account must have a total throughput limit of at least **3000 RU/s**. Both Provisioned Throughput and Serverless modes are supported. Standard setup provisions three containers in your Cosmos DB account, each requiring 1000 RU/s:

| Container | Data |
|-----------|------|
| `thread-message-store` | End-user conversations |
| `system-thread-message-store` | Internal system messages |
| `agent-entity-store` | Agent metadata (instructions, tools, name) |

For multiple projects under the same Foundry account, multiply by the number of projects. For example, two projects require at least 6000 RU/s (3 containers × 1000 RU/s × 2 projects).

### Standard Setup with BYO Virtual Network

Includes everything in the Standard Setup, with the added ability to operate entirely within your own virtual network. This setup supports **VNet injection**, allowing for strict control over data movement and helping prevent data exfiltration by keeping traffic confined to your network environment. This is the focus of the networking sections below.

## Microsoft Foundry Networking

Networking is a critical aspect of Microsoft Foundry's security model. Consider network isolation in **three areas**:

1. **Inbound access** to the Microsoft Foundry resource — e.g., for your data scientists to securely access the resource.
2. **Outbound access** from the Microsoft Foundry resource — e.g., to access other Azure services.
3. **Outbound access from the Agent client** to reach required dependencies — such as private data sources, Azure PaaS services, or approved internet endpoints — while keeping all traffic within customer-defined network boundaries through virtual network injection.

![Plan for Network Isolation](images/plan-network-isolation-diagram.png)

### Inbound Network Isolation (Private Link)

Set inbound access to a secured Microsoft Foundry project by using the **public network access (PNA) flag**. The PNA flag setting determines whether your project requires a private endpoint for access. There are three settings:

- **Disabled** — only accessible via private endpoint (most secure)
- **Enabled from selected IP addresses** — allows access from specific IP ranges
- **All networks** — public access enabled

For stricter security, disable public network access and use [Azure Private Link](https://learn.microsoft.com/en-us/azure/foundry/how-to/configure-private-link?view=foundry) to expose the Foundry account and its portal only within your private network. A private endpoint is a NIC with a private IP in your VNet linked to the Foundry resource. When set up, all traffic to the account's API and UI is forced through your VNet — no traffic uses a public IP.

#### Creating a Private Endpoint

**For a new resource:**
1. From the [Azure portal](https://portal.azure.com/), search for Foundry and select **Create a resource**.
2. After configuring the Basics tab, select the **Networking** tab and choose **Disabled** for public access.
3. From the Private endpoint section, select **+ Add private endpoint**.
4. Select the same **Region** as your virtual network, and select your VNet and subnet.
5. Continue through the forms and create the project.

**For an existing project:**
1. Select your project in the Azure portal.
2. Go to **Resource Management → Networking → Private endpoint connections**.
3. Select **+ Private endpoint** and configure it with your VNet and subnet.

#### DNS Configuration

Clients on a virtual network that use the private endpoint use the same connection string as clients connecting to the public endpoint. DNS resolution automatically routes connections from the virtual network to the Foundry resource over a private link.

When you create a private endpoint, Azure updates the DNS CNAME resource record to an alias in a subdomain with the prefix `privatelink`. By default, Azure also creates a private DNS zone with DNS A resource records for the private endpoints.

- From **outside** the VNet: the endpoint URL resolves to the public endpoint.
- From **inside** the VNet hosting the private endpoint: it resolves to the private IP address.

If you use a custom DNS server, configure it to delegate the `privatelink` subdomain to the private DNS zone for the virtual network, or configure conditional forwarders to the Azure DNS Virtual Server at `168.63.129.16`.

#### Validating the Configuration

1. In the Azure portal, go to your project resource. Under **Networking → Private endpoint connections**, confirm the connection status is **Approved**.
2. From a VM connected to the VNet, resolve your Foundry endpoint:
   ```
   nslookup <your-foundry-endpoint-hostname>
   ```
3. Test connectivity on port 443:
   ```powershell
   Test-NetConnection <private-endpoint-ip-address> -Port 443
   ```

#### Grant Access to Trusted Azure Services

If your Foundry project restricts network access, you can grant a subset of trusted Azure services access using managed identity. The following services can access Foundry if their managed identity has appropriate role assignments:

| Service | Resource Provider |
|---------|------------------|
| Foundry Tools | `Microsoft.CognitiveServices` |
| Azure AI Search | `Microsoft.Search` |
| Azure Machine Learning | `Microsoft.MachineLearningServices` |

![Foundry Portal Firewall Settings](images/foundry-portal-firewall.png)

#### Secure Connection Methods

To access a Foundry resource with public access disabled, use one of these methods:

- **[Azure VPN Gateway](https://learn.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-about-vpngateways)** — Point-to-site or Site-to-site VPN
- **[ExpressRoute](https://learn.microsoft.com/en-us/azure/expressroute/)** — Private connection through a connectivity provider
- **[Azure Bastion VM](https://learn.microsoft.com/en-us/azure/bastion/bastion-overview)** — Jump box in the VNet, accessed via RDP/SSH through browser

### Outbound Network Isolation (VNet Injection)

Microsoft Foundry's outbound network isolation uses **virtual network (VNet) injection** of the Agent client. The Agent client is injected into a customer-managed virtual network subnet, allowing outbound communication to Azure PaaS resources over private endpoints and Private Link while keeping all traffic within customer-defined network boundaries.

> **Key change from older versions:** The previous "Managed Virtual Network" model with three outbound modes (Allow Internet Outbound / Allow Only Approved Outbound / Disabled) has been superseded by the VNet injection model for Agent Service. In the current architecture, customers don't manage separate "compute" resources in Foundry. Instead, the Agent client operates within a delegated Agent subnet and the platform provides container injection to integrate with your VNet.

![Agent and Evaluation Network Isolation Architecture](images/agent-eval-network-diagram.png)

#### VNet Injection Architecture

The VNet injection model deploys into a customer-owned virtual network with two subnets:

![Private Network Isolation Architecture](images/private-network-isolation.png)

**Network Infrastructure:**
- A virtual network (e.g., `192.168.0.0/16`)
- **Agent Subnet** (e.g., `192.168.0.0/24`): Hosts the Agent client, delegated to `Microsoft.App/environments`. Minimum size is `/27` (32 addresses), recommended `/24` (256 addresses).
- **Private Endpoint Subnet** (e.g., `192.168.1.0/24`): Hosts private endpoints for all PaaS resources.

**Private DNS Zones configured:**
- `privatelink.blob.core.windows.net`
- `privatelink.cognitiveservices.azure.com`
- `privatelink.documents.azure.com`
- `privatelink.file.core.windows.net`
- `privatelink.openai.azure.com`
- `privatelink.search.windows.net`
- `privatelink.services.ai.azure.com`

**DNS Zone Configurations Summary:**

| Resource | Group ID | Private DNS Zone | Public DNS Zone |
|----------|----------|-----------------|-----------------|
| Foundry | account | `privatelink.cognitiveservices.azure.com` `privatelink.openai.azure.com` `privatelink.services.ai.azure.com` | `cognitiveservices.azure.com` `openai.azure.com` `services.ai.azure.com` |
| Azure AI Search | searchService | `privatelink.search.windows.net` | `search.windows.net` |
| Azure Cosmos DB | Sql | `privatelink.documents.azure.com` | `documents.azure.com` |
| Azure Storage | blob | `privatelink.blob.core.windows.net` | `blob.core.windows.net` |

#### Creating a Resource with VNet Injection

1. From the [Azure portal](https://portal.azure.com/), search for Foundry and select **Create a resource**.
2. After configuring the Basics tab, select the **Storage** tab and select **Select resources** under Agent service.
   - Select or create new Storage account, AI Search resource, and Azure Cosmos DB.
3. Select the **Network** tab and choose **Disabled** for public access. Add your private endpoint.
4. A new dropdown appears for **Virtual network injection**. Select your VNet and the subnet delegated to `Microsoft.App/environments` (minimum `/27`).
5. Continue through the forms to create the project.

> **Note:** Programmatic deployment (Bicep or Terraform) is required for full network-secured setup. Portal-based creation has limitations. See templates at [microsoft-foundry/foundry-samples](https://github.com/microsoft-foundry/foundry-samples).

#### Deployment Templates

- **Bicep:** [15-private-network-standard-agent-setup](https://github.com/microsoft-foundry/foundry-samples/tree/main/infrastructure/infrastructure-setup-bicep/15-private-network-standard-agent-setup)
- **Terraform:** [15b-private-network-standard-agent-setup-byovnet](https://github.com/microsoft-foundry/foundry-samples/tree/main/infrastructure/infrastructure-setup-terraform/15b-private-network-standard-agent-setup-byovnet)
- **Hybrid/on-prem resources:** [19-hybrid-private-resources-agent-setup](https://github.com/microsoft-foundry/foundry-samples/tree/main/infrastructure/infrastructure-setup-bicep/19-hybrid-private-resources-agent-setup)

#### Verifying the Deployment

1. **Confirm subnet delegation:** Navigate to your VNet → Subnets and verify the agent subnet shows delegation to `Microsoft.App/environments`.
2. **Check public network access:** Open each resource (Foundry, Azure AI Search, Azure Storage, Azure Cosmos DB) and confirm Public network access is set to **Disabled**.
3. **Validate private endpoint DNS resolution:** From a machine connected to the VNet, run `nslookup` against each endpoint and verify each name resolves to a private IP address.
4. **Test agent connectivity:** Access your Foundry project from within the VNet and confirm you can create and run an agent.

### Agent Tools and Network Isolation

Certain Agent tools are supported when Foundry is network isolated, while others are not. The following table shows support status and traffic flow for agent tools in network-isolated environments (covers tool support for the Responses API Agents created through SDK/CLI or in the Foundry portal):

| Tool | Supported? | Traffic Path |
|------|-----------|-------------|
| MCP Tool (Private MCP) | ✅ Supported | Through your VNet subnet |
| Azure AI Search | ✅ Supported | Through private endpoint |
| Code Interpreter | ✅ Supported | Microsoft backbone network |
| Function Calling | ✅ Supported | Microsoft backbone network |
| Bing Grounding | ✅ Supported | Public endpoint |
| Websearch | ✅ Supported | Public endpoint |
| SharePoint Grounding | ✅ Supported | Public endpoint |
| Foundry IQ (preview) | ✅ Supported | Via MCP |
| Fabric Data Agent | ❌ Not supported | |
| Logic Apps | ❌ Not supported | |
| File Search | ❌ Not supported | Under development |
| OpenAPI tool | ❌ Not supported | Under development |
| Azure Functions | ❌ Not supported | Under investigation |
| Browser Automation | ❌ Not supported | Under investigation |
| Computer Use | ❌ Not supported | Under investigation |
| Image Generation | ❌ Not supported | Under investigation |
| Agent-to-Agent (A2A) | ❌ Not supported | Under development |

> **Note:** Public endpoint tools (Bing Grounding, Websearch, SharePoint Grounding) work in network-isolated environments but communicate over the public internet. If your organization requires that all traffic remain within a private network, these tools may not meet your compliance requirements. You can block them using Azure Policy.

**Configuration requirements by traffic pattern:**

- **Tools using your VNet subnet** (MCP Tool, Azure AI Search): Require private endpoints for the Azure services the MCP tools access. Verify managed identity has appropriate RBAC roles and firewall rules permit agent→service traffic.
- **Tools using Microsoft backbone** (Code Interpreter, Function Calling): No private endpoints or additional networking configuration required. Traffic stays within Microsoft's backbone network infrastructure.
- **Tools using public endpoints** (Bing, Websearch, SharePoint): No private endpoints required. Traffic goes over the public internet.

### Hub-and-Spoke and Firewall Configuration

To secure egress (outbound) traffic through network injection, configure an Azure Firewall or another firewall solution. This configuration helps inspect and control outbound traffic before it leaves your virtual network.

You can use a **hub-and-spoke networking architecture** where a virtual network is created for a shared firewall (the hub) and a separate virtual network for Foundry networking (a spoke). These virtual networks are then peered together.

![Hub-and-Spoke Firewall Configuration](images/network-hub-spoke-diagram.png)

When integrating Azure Firewall with a private-network-secured standard agent, allowlist the FQDNs listed under Managed Identity in the [Integrate with Azure Firewall](https://learn.microsoft.com/en-us/azure/container-apps/use-azure-firewall#application-rules) article, or add the Service Tag `AzureActiveDirectory`.

### Hybrid Connectivity to On-Premises Resources

With the VNet injection model, agents run **inside your virtual network**, which simplifies hybrid connectivity significantly compared to previous architectures. Since the Agent client is injected into your subnet, it can natively reach anything accessible from your VNet.

**Connection methods:**

- **VPN Gateway (Point-to-Site or Site-to-Site):** Connects on-premises networks to the virtual network over the public internet using encrypted tunnels.
- **ExpressRoute:** Connects on-premises networks into Azure over a private connection through a connectivity provider.
- **Azure Bastion:** Create a jump box VM inside the virtual network and connect via browser-based RDP/SSH.

For hybrid scenarios with private MCP servers or on-premises data sources, see the [19-hybrid-private-resources-agent-setup](https://github.com/microsoft-foundry/foundry-samples/tree/main/infrastructure/infrastructure-setup-bicep/19-hybrid-private-resources-agent-setup) Bicep template.

## Foundry Feature Limitations with Network Isolation

The following features in Foundry don't yet fully support network isolation:

| Feature | Status | Notes |
|---------|--------|-------|
| Hosted Agents | Not supported | No virtual network support yet |
| Publish Agent to Teams/M365 | Not supported | Requires public endpoints for Teams/M365 integration |
| Synthetic Data Gen for Evaluations | Not supported | Bring your own data to run evaluations |
| Traces | Not supported | No virtual network support with a private Application Insights yet |
| Workflow Agents | Partially supported | Inbound access works in UI, SDK, and CLI. Outbound via VNet injection is not currently supported |
| AI Gateway | Partially supported | Can create a new AI Gateway with private Foundry resource, but gateway is automatically public. Data plane actions require AI Gateway network isolation too |
| Certain Agent Tools | Partially supported | See the Agent Tools table above for tool-by-tool status |

## Known Limitations

- **Subnet IP address limitation:** Both subnets must have IP ranges within valid RFC1918 private IPv4 ranges: `10.0.0.0/8`, `172.16.0.0/12`, or `192.168.0.0/16`. Public IP ranges are not supported.
- **Agent subnet exclusivity:** The agent subnet cannot be shared by multiple Foundry resources. Each Foundry resource must use a dedicated agent subnet.
- **Agent subnet size:** The recommended size of the delegated Agent subnet is `/24` (256 addresses) due to the delegation to `Microsoft.App/environments`. Minimum is `/27`.
- **Agent subnet egress firewall:** If integrating Azure Firewall, allowlist the FQDNs listed under Managed Identity in the [Integrate with Azure Firewall](https://learn.microsoft.com/en-us/azure/container-apps/use-azure-firewall#application-rules) article, or add the Service Tag `AzureActiveDirectory`. Verify that no TLS inspection adds a self-signed certificate.
- **Same region requirement:** All Foundry workspace resources must be deployed in the same region as the VNet. This includes Cosmos DB, Storage Account, Azure AI Search, Foundry Account, Project, Managed Identity, and Azure OpenAI.
- **Private endpoint region/subscription:** The private endpoint must be in the same region and subscription as the virtual network.
- **Don't use 172.17.0.0/16:** This range is reserved by Docker bridge networking.
- **Capability host immutability:** You cannot update the capability host after it is set for a project or account. Delete and recreate the project if changes are needed.
- **Azure Blob Storage:** Using Azure Blob Storage files with the File Search tool is not supported.

## Required RBAC Roles

| Task | Required Role |
|------|---------------|
| Create an account and project | Azure AI Account Owner |
| Assign RBAC for BYO resources (Standard setup) | Role Based Access Administrator |
| Create and edit agents | Azure AI User |

**Project managed identity role assignments (Standard setup):**

| Resource | Role |
|----------|------|
| Cosmos DB | Cosmos DB Operator (account level) |
| Storage Account | Storage Account Contributor (account level) |
| Azure AI Search | Search Index Data Contributor + Search Service Contributor |
| Blob Storage Container (`<workspaceId>-azureml-blobstore`) | Storage Blob Data Contributor |
| Blob Storage Container (`<workspaceId>-agents-blobstore`) | Storage Blob Data Owner |
| Cosmos DB Database (`enterprise_memory`) | Cosmos DB Built-in Data Contributor |

## Required Resource Provider Registrations

```bash
az provider register --namespace 'Microsoft.KeyVault'
az provider register --namespace 'Microsoft.CognitiveServices'
az provider register --namespace 'Microsoft.Storage'
az provider register --namespace 'Microsoft.MachineLearningServices'
az provider register --namespace 'Microsoft.Search'
az provider register --namespace 'Microsoft.Network'
az provider register --namespace 'Microsoft.App'
az provider register --namespace 'Microsoft.ContainerService'
# Only to use Grounding with Bing Search tool:
az provider register --namespace 'Microsoft.Bing'
```

## Troubleshooting

### Template Deployment Errors

| Error | Solution |
|-------|----------|
| `CreateCapabilityHostRequestDto is invalid: Agents CapabilityHost supports a single, non empty value for vectorStoreConnections / storageConnections / threadStorageConnections property.` | All BYO resource connections must be provided. You cannot create a secured standard agent without all three resources (Storage, Cosmos DB, AI Search). |
| `Provided subnet must be of the proper address space.` | Use a valid private IP range (`10.0.0.0/8`, `172.16.0.0/12`, or `192.168.0.0/16`). |
| `Subscription is not registered with the required resource providers.` | Register all required resource providers (see section above). |
| `Failed async operation` or `Capability host operation failed.` | Catch-all error. Create a support ticket. Check the capability host for details. |
| `Subnet requires delegation to Microsoft.App/environments` | Navigate to your Foundry resource in the Azure portal and select **Manage deleted resources**. Purge the resource associated with the VNet, or run the `deleteCaphost.sh` script. |
| `Timeout of 60000ms exceeded` when loading Agent pages | Verify connectivity to Azure Cosmos DB (Private Endpoint and DNS). When using a firewall, ensure it allows access to required FQDNs. |

### DNS Resolution Problems

- **DNS resolution returns public IP:** Confirm a private DNS zone exists for the `privatelink` subdomain and is linked to your VNet. Run `nslookup` from inside the VNet.
- **Custom DNS server not resolving:** Ensure it forwards queries for `privatelink` subdomain to Azure DNS (`168.63.129.16`).
- **Private endpoint DNS fails:** Verify each private DNS zone is linked to your VNet. Confirm conditional forwarders point to `168.63.129.16`.

### Connectivity Issues

- **Connection times out on port 443:** Check NSG rules allow outbound traffic to the private endpoint IP on port 443. Verify no firewall is blocking.
- **Can't reach Foundry from on-premises:** Verify VPN or ExpressRoute is active and routing tables include the VNet address space.
- **403 Forbidden errors:** Usually authentication, not networking. Verify RBAC roles on the Foundry project.

### Agent-Specific Issues

- **Agent fails to start:** Verify you are using Standard Agent deployment (not Basic). Check VNet injection configuration and subnet IP availability.
- **Agent cannot access MCP tools:** Ensure private endpoints exist for all required Azure services. Verify managed identity RBAC roles.
- **Evaluation runs fail with network errors:** Confirm all required DNS zones are configured.
- **Agent timeouts on external API calls:** If agents call external APIs, ensure your firewall allows outbound HTTPS, or deploy a NAT gateway.

## References

- [Configure network isolation for Microsoft Foundry](https://learn.microsoft.com/en-us/azure/foundry/how-to/configure-private-link?view=foundry)
- [Set up your environment for Foundry Agent Service](https://learn.microsoft.com/en-us/azure/foundry/agents/environment-setup)
- [Set up standard agent resources](https://learn.microsoft.com/en-us/azure/foundry/agents/concepts/standard-agent-setup)
- [Set up private networking for Foundry Agent Service](https://learn.microsoft.com/en-us/azure/foundry/agents/how-to/virtual-networks)
- [Foundry Samples on GitHub](https://github.com/microsoft-foundry/foundry-samples)
- [Azure AI Agent Service FAQ - Virtual Networking](https://learn.microsoft.com/en-us/azure/foundry/agents/faq#virtual-networking)

