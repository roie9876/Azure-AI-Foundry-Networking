# Microsoft Foundry Networking and Security Guide

> **Updated March 2026** — This guide reflects the current Microsoft Foundry (formerly Azure AI Foundry / Azure AI Studio) networking model, including the Foundry Account + Project architecture, Agent Service setup tiers, and VNet injection for outbound network isolation.

## What is Microsoft Foundry?

Microsoft Foundry is Azure's platform for building, deploying, and managing generative AI applications. Think of it as a managed workspace where your teams build AI agents, deploy models (like GPT-4o), and connect to data — all with enterprise security built in.

The platform has two levels:

- **Foundry Account** — The top-level resource. This is where admins configure security, networking, and shared settings. Everything you set here (like "no public internet access") automatically applies to all projects underneath.
- **Projects** — Isolated workspaces under the account. Each team or application gets its own project. Data, agents, and permissions are separated between projects, but they all inherit the account's security rules.

---

## Understanding Network Isolation — The Big Picture

When you deploy Microsoft Foundry in an enterprise, you need to think about network security in **three areas**. This diagram shows all three:

![Plan for Network Isolation](images/plan-network-isolation-diagram.png)

Let's break down what each area means:

### 1. Inbound Access — Who can reach your Foundry resource?

This controls **who can connect to your Foundry account and portal**. By default, your Foundry resource is accessible from the internet. For enterprise deployments, you want to lock this down so only people inside your network can access it.

**How it works:** You set the **Public Network Access (PNA) flag** on your Foundry resource:
- **Disabled** — Nobody can reach it from the internet. Access is only possible through a **private endpoint** inside your virtual network. This is the most secure option.
- **Selected IP addresses** — Only specific IP ranges can connect (e.g., your office IPs).
- **All networks** — Open to the internet (default, fine for testing, not for production).

When you disable public access and add a private endpoint, your Foundry portal and APIs get a private IP address inside your VNet. Your data scientists connect through VPN, ExpressRoute, or a Bastion jump box — never through the public internet.

### 2. Outbound Access — How Foundry reaches other Azure services

This controls **how the Foundry resource communicates with its dependent Azure services** — things like Azure Storage, Key Vault, and Azure OpenAI. By default these communications go over the Azure backbone (encrypted, but using public endpoints).

For maximum security, you add **private endpoints** for each of these services, so all traffic stays within your private network — even traffic to Azure's own services.

### 3. Outbound Access from Agent Compute — How your agents reach data

This is the newest and most important part. When your AI agents run, they need to reach data sources, APIs, and tools. This traffic comes from the **Agent client** — the compute that actually executes your agents.

**How it works:** Microsoft Foundry uses **VNet injection** — it places the Agent client directly inside a subnet in **your own virtual network**. This means:
- Your agents run **inside your network**, not in some Microsoft-managed network you can't see
- Agents can only reach what your network allows — you have full control
- All traffic to Azure PaaS services (Storage, Cosmos DB, AI Search) goes through private endpoints
- You can add a firewall to inspect and control all outbound traffic

---

## Agent Service Setup Tiers

The level of network isolation available depends on which Agent Service tier you choose. There are three options:

| Capability | Basic | Standard | Standard + BYO VNet |
|-----------|-------|----------|---------------------|
| Get started quickly, no resource management | ✅ | | |
| Your data stays in your own Azure resources | | ✅ | ✅ |
| Customer Managed Keys (CMK) | | ✅ | ✅ |
| Full network isolation (agents in your VNet) | | | ✅ |

> **Important:** You can add a private endpoint (inbound isolation) to **any** tier. The table above is about **outbound** isolation — controlling where your agents' traffic goes.

### Basic Setup

Microsoft manages everything. Agent data (conversations, files) is stored in Microsoft's multitenant infrastructure. Good for prototyping — just create an account and project and start building agents. No networking configuration needed.

### Standard Setup

You **bring your own Azure resources** to store agent data in your tenant:

| Your Resource | What it stores |
|---------------|---------------|
| **Azure Storage** | Files uploaded by users and developers |
| **Azure AI Search** | Vector stores (embeddings for search) |
| **Azure Cosmos DB for NoSQL** | Conversations, agent metadata, message history |

This gives you full data sovereignty — all data stays in resources you own and control. You need at least **3000 RU/s** on Cosmos DB (1000 per container × 3 containers). For multiple projects, multiply accordingly.

### Standard Setup + BYO Virtual Network

Everything from Standard, **plus** your agents run inside your own virtual network. This is the full enterprise-grade setup covered in the rest of this guide.

---

## The Private Agent Network Architecture

When you deploy with the Standard + BYO VNet setup, the architecture looks like this:

![Private Network Isolation Architecture](images/private-network-isolation.png)

Here's what each component does:

**Your Virtual Network** contains two subnets:

| Subnet | Purpose | Size |
|--------|---------|------|
| **Agent Subnet** | This is where Microsoft injects the Agent client container into your network. It's delegated to `Microsoft.App/environments`. Your agents, evaluations, and prompt flows run here. | `/24` recommended (256 IPs), `/27` minimum (32 IPs) |
| **Private Endpoint Subnet** | Hosts the private endpoints — the private "doors" into each Azure service. Each private endpoint gets a private IP address in this subnet. | Sized based on number of endpoints |

**Private Endpoints** connect to:
- **Foundry Account** — so the agent client can talk to the Foundry management plane
- **Azure Storage** — so agents can read/write files
- **Azure AI Search** — so agents can use vector search
- **Azure Cosmos DB** — so agents can store conversations and metadata

**Private DNS Zones** make it all work transparently. When your agent code calls `yourstorageaccount.blob.core.windows.net`, the private DNS zone resolves it to the private endpoint IP (e.g., `192.168.1.10`) instead of a public IP. No code changes needed — the same URLs work, they just resolve privately.

**On-premises connectivity** is straightforward because agents are already in your VNet:
- **ExpressRoute** — Private dedicated connection from your data center
- **VPN Gateway** (Site-to-Site or Point-to-Site) — Encrypted tunnel over the internet
- **Azure Bastion** — Browser-based RDP/SSH jump box for developer access

Since your agents run inside your VNet, they can natively reach anything your VNet can reach — including on-premises resources through VPN or ExpressRoute. No special proxy or gateway needed.

### How the Full Network Looks End-to-End

![Agent and Evaluation Network Isolation Architecture](images/agent-eval-network-diagram.png)

This diagram shows the complete flow:
- **Left side:** Your agents and evaluations run in the delegated agent subnet
- **Center:** Private endpoints provide secure, private connections to each Azure service
- **Right side:** All your BYO resources (Storage, Cosmos DB, AI Search) have public access disabled — they only accept traffic through the private endpoints
- **Bottom:** Your on-premises network connects through ExpressRoute or VPN
- **Optional:** An Azure Firewall can sit in front to inspect and control all egress traffic

---

## Inbound Isolation — Step by Step

### Creating a Private Endpoint

**For a new Foundry resource:**
1. In the [Azure portal](https://portal.azure.com/), search for **Foundry** and select **Create a resource**.
2. On the **Networking** tab, set public access to **Disabled**.
3. Select **+ Add private endpoint** — choose the same region as your VNet, select your VNet and subnet.
4. Complete the wizard and create the resource.

**For an existing project:**
1. Go to your project in the Azure portal.
2. Navigate to **Resource Management → Networking → Private endpoint connections**.
3. Select **+ Private endpoint** and configure with your VNet and subnet.

### DNS — How Private Endpoints Resolve

When you create a private endpoint, Azure automatically:
1. Creates a `privatelink` DNS alias for your resource
2. Sets up a Private DNS Zone with an A record pointing to the private IP

**The result:**
- From **inside** your VNet: `yourfoundry.cognitiveservices.azure.com` resolves to `192.168.1.5` (private)
- From **outside** your VNet: the same URL resolves to the public IP (blocked if public access is disabled)

If you use a **custom DNS server** (e.g., on-premises Active Directory DNS), configure it to forward `privatelink.*` queries to Azure DNS at `168.63.129.16`.

### Validating Your Setup

1. Confirm private endpoint status is **Approved** in the portal under Networking.
2. From a VM inside the VNet, run:
   ```
   nslookup <your-foundry-endpoint-hostname>
   ```
   Verify it returns a private IP (10.x, 172.16-31.x, or 192.168.x).
3. Test connectivity:
   ```powershell
   Test-NetConnection <private-endpoint-ip-address> -Port 443
   ```

### Trusted Azure Services

Even with public access disabled, you can allow specific Azure services to reach Foundry using their managed identities:

| Service | Resource Provider |
|---------|------------------|
| Foundry Tools | `Microsoft.CognitiveServices` |
| Azure AI Search | `Microsoft.Search` |
| Azure Machine Learning | `Microsoft.MachineLearningServices` |

![Foundry Portal Firewall Settings](images/foundry-portal-firewall.png)

### How to Connect — VPN, ExpressRoute, or Bastion

Once public access is disabled, your team needs a way in:

| Method | Best for |
|--------|----------|
| **[Azure VPN Gateway](https://learn.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-about-vpngateways)** (Point-to-Site) | Individual developers connecting from laptops |
| **[Azure VPN Gateway](https://learn.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-about-vpngateways)** (Site-to-Site) | Connecting your entire office network |
| **[ExpressRoute](https://learn.microsoft.com/en-us/azure/expressroute/)** | High-bandwidth, low-latency private connection from your data center |
| **[Azure Bastion](https://learn.microsoft.com/en-us/azure/bastion/bastion-overview)** | Quick access via a jump box VM — connect through your browser |

---

## Outbound Isolation — VNet Injection

### Setting Up VNet Injection

1. In the Azure portal, create a Foundry resource.
2. On the **Storage** tab, select **Select resources** under Agent service — choose or create your Storage, AI Search, and Cosmos DB.
3. On the **Network** tab, set public access to **Disabled** and add your private endpoint.
4. Under **Virtual network injection**, select your VNet and the subnet delegated to `Microsoft.App/environments`.
5. Complete the wizard.

> **Note:** For production deployments, use the **Bicep or Terraform templates** — they handle all the networking, private endpoints, DNS zones, and RBAC automatically:
> - **Bicep:** [15-private-network-standard-agent-setup](https://github.com/microsoft-foundry/foundry-samples/tree/main/infrastructure/infrastructure-setup-bicep/15-private-network-standard-agent-setup)
> - **Terraform:** [15b-private-network-standard-agent-setup-byovnet](https://github.com/microsoft-foundry/foundry-samples/tree/main/infrastructure/infrastructure-setup-terraform/15b-private-network-standard-agent-setup-byovnet)
> - **Hybrid/on-prem:** [19-hybrid-private-resources-agent-setup](https://github.com/microsoft-foundry/foundry-samples/tree/main/infrastructure/infrastructure-setup-bicep/19-hybrid-private-resources-agent-setup)

### DNS Zones You Need

Each Azure service needs its own Private DNS Zone. Here's the complete list:

| Resource | Private DNS Zone | Public DNS Zone |
|----------|-----------------|-----------------|
| Foundry Account | `privatelink.cognitiveservices.azure.com` | `cognitiveservices.azure.com` |
| Foundry Account | `privatelink.openai.azure.com` | `openai.azure.com` |
| Foundry Account | `privatelink.services.ai.azure.com` | `services.ai.azure.com` |
| Azure AI Search | `privatelink.search.windows.net` | `search.windows.net` |
| Azure Cosmos DB | `privatelink.documents.azure.com` | `documents.azure.com` |
| Azure Storage | `privatelink.blob.core.windows.net` | `blob.core.windows.net` |

To create a conditional forwarder in your DNS Server to Azure DNS, use the Azure DNS Virtual Server IP: `168.63.129.16`.

### Verifying the Deployment

1. **Subnet delegation:** In the portal, go to VNet → Subnets — the agent subnet should show delegation to `Microsoft.App/environments`.
2. **Public access disabled:** Check each resource (Foundry, AI Search, Storage, Cosmos DB) — public network access should be **Disabled**.
3. **DNS resolution:** From inside the VNet, run `nslookup` on each endpoint — all should resolve to private IPs.
4. **Agent test:** Open your Foundry project from within the VNet and create a test agent.

---

## Hub-and-Spoke with Firewall

For enterprises that need to inspect and control all outbound traffic, use a **hub-and-spoke** topology:

![Hub-and-Spoke Firewall Configuration](images/network-hub-spoke-diagram.png)

- **Hub VNet** — Contains a shared Azure Firewall (or third-party NVA) that inspects all traffic
- **Spoke VNet** — Contains your Foundry resources, agent subnet, and private endpoints
- The two VNets are **peered**, and a route table on the spoke forces all traffic through the firewall

When using Azure Firewall with VNet-injected agents, allowlist the FQDNs from the [Integrate with Azure Firewall](https://learn.microsoft.com/en-us/azure/container-apps/use-azure-firewall#application-rules) article (under Managed Identity), or add the Service Tag `AzureActiveDirectory`.

---

## Agent Tools — What Works Behind a VNet?

Not all agent tools support network isolation yet. Here's the current status:

| Tool | Works in VNet? | How traffic flows |
|------|---------------|-------------------|
| MCP Tool (Private MCP) | ✅ Yes | Through your VNet subnet |
| Azure AI Search | ✅ Yes | Through private endpoint |
| Code Interpreter | ✅ Yes | Microsoft backbone (no config needed) |
| Function Calling | ✅ Yes | Microsoft backbone (no config needed) |
| Bing Grounding | ✅ Yes | Public internet* |
| Websearch | ✅ Yes | Public internet* |
| SharePoint Grounding | ✅ Yes | Public internet* |
| Foundry IQ (preview) | ✅ Yes | Via MCP |
| Fabric Data Agent | ❌ No | — |
| Logic Apps | ❌ No | — |
| File Search | ❌ No | Under development |
| OpenAPI tool | ❌ No | Under development |
| Azure Functions | ❌ No | Under investigation |
| Browser Automation | ❌ No | Under investigation |
| Computer Use | ❌ No | Under investigation |
| Image Generation | ❌ No | Under investigation |
| Agent-to-Agent (A2A) | ❌ No | Under development |

> *Bing, Websearch, and SharePoint tools work but use the **public internet**. If your compliance requires all traffic to stay private, these tools won't meet that requirement. You can block them via Azure Policy.

---

## Foundry Features — Network Isolation Support

Some Foundry features don't yet support full network isolation:

| Feature | Status | What to know |
|---------|--------|-------------|
| Hosted Agents | ❌ Not supported | No VNet support yet |
| Publish to Teams/M365 | ❌ Not supported | Requires public endpoints |
| Synthetic Data for Evaluations | ❌ Not supported | Bring your own data instead |
| Traces | ❌ Not supported | No private Application Insights support yet |
| Workflow Agents | ⚠️ Partial | Inbound works (UI, SDK, CLI). Outbound VNet injection not supported yet |
| AI Gateway | ⚠️ Partial | Gateway is auto-public. Needs its own network isolation config for data plane |
| Agent Tools | ⚠️ Partial | See the tool-by-tool table above |

---

## Known Limitations

- **RFC1918 only:** Subnets must use private IP ranges: `10.0.0.0/8`, `172.16.0.0/12`, or `192.168.0.0/16`
- **One subnet per Foundry resource:** Each Foundry resource needs its own dedicated agent subnet
- **Subnet size:** Minimum `/27` (32 IPs), recommended `/24` (256 IPs)
- **Same region:** All resources (Cosmos DB, Storage, AI Search, Foundry, VNet) must be in the same Azure region
- **Same subscription:** Private endpoints must be in the same subscription as the VNet
- **Avoid 172.17.0.0/16:** Reserved by Docker
- **Capability hosts are immutable:** Once set, you can't update them — delete and recreate the project
- **No TLS inspection:** Firewall TLS inspection can break agent traffic by injecting self-signed certs
- **File Search + Blob Storage:** Not supported in network-isolated environments

---

## Required RBAC Roles

| Who | Needs this role | On what scope |
|-----|----------------|---------------|
| Admin creating the account | Azure AI Account Owner | Subscription |
| Admin assigning resource permissions (Standard) | Role Based Access Administrator | Resource group |
| Developers creating/editing agents | Azure AI User | Project |

**The project's managed identity needs these roles on BYO resources:**

| Resource | Role |
|----------|------|
| Cosmos DB account | Cosmos DB Operator |
| Storage account | Storage Account Contributor |
| Azure AI Search | Search Index Data Contributor + Search Service Contributor |
| Blob container `<workspaceId>-azureml-blobstore` | Storage Blob Data Contributor |
| Blob container `<workspaceId>-agents-blobstore` | Storage Blob Data Owner |
| Cosmos DB database `enterprise_memory` | Cosmos DB Built-in Data Contributor |

---

## Required Resource Provider Registrations

Register these before deploying:

```bash
az provider register --namespace 'Microsoft.KeyVault'
az provider register --namespace 'Microsoft.CognitiveServices'
az provider register --namespace 'Microsoft.Storage'
az provider register --namespace 'Microsoft.MachineLearningServices'
az provider register --namespace 'Microsoft.Search'
az provider register --namespace 'Microsoft.Network'
az provider register --namespace 'Microsoft.App'
az provider register --namespace 'Microsoft.ContainerService'
# Only if using Bing Search tool:
az provider register --namespace 'Microsoft.Bing'
```

---

## Troubleshooting

### Deployment Errors

| Error message | What's wrong | Fix |
|--------------|-------------|-----|
| `CapabilityHost supports a single, non empty value for storageConnections...` | Missing BYO resource connections | You must provide all three: Storage, Cosmos DB, and AI Search |
| `Provided subnet must be of the proper address space` | Wrong IP range | Use RFC1918 ranges only (`10.x`, `172.16-31.x`, `192.168.x`) |
| `Subscription is not registered with required resource providers` | Missing providers | Run the `az provider register` commands above |
| `Failed async operation` / `Capability host operation failed` | Various | Create a support ticket. Check capability host details in portal |
| `Subnet requires delegation to Microsoft.App/environments` | Stale resources | In portal: Foundry resource → **Manage deleted resources** → purge. Or run `deleteCaphost.sh` |
| `Timeout of 60000ms` on Agent pages | Can't reach Cosmos DB | Check Cosmos DB private endpoint and DNS. If using firewall, allow required FQDNs |

### DNS Problems

| Symptom | Fix |
|---------|-----|
| `nslookup` returns a public IP | Private DNS zone not linked to VNet. Check zone → Virtual network links |
| Custom DNS server can't resolve | Add conditional forwarder for `privatelink.*` domains to `168.63.129.16` |
| Intermittent DNS failures | Check DNS server reachability from all subnets |

### Connectivity Problems

| Symptom | Fix |
|---------|-----|
| Connection timeout on port 443 | Check NSG rules allow traffic to private endpoint IPs on 443 |
| Can't reach Foundry from on-prem | Verify VPN/ExpressRoute is up. Check route tables include VNet address space |
| 403 Forbidden | Usually RBAC, not networking. Verify role assignments on the project |

### Agent Problems

| Symptom | Fix |
|---------|-----|
| Agent won't start | Verify you're using Standard setup (not Basic). Check subnet has available IPs |
| Agent can't access MCP tools | Check private endpoints exist for all services. Verify managed identity RBAC |
| Evaluation runs fail | Verify all DNS zones are configured and linked |
| Agent timeout on external APIs | Firewall may block outbound HTTPS. Allow the destination or add a NAT gateway |

---

## References

- [Configure network isolation for Microsoft Foundry](https://learn.microsoft.com/en-us/azure/foundry/how-to/configure-private-link?view=foundry)
- [Set up your environment for Foundry Agent Service](https://learn.microsoft.com/en-us/azure/foundry/agents/environment-setup)
- [Set up standard agent resources](https://learn.microsoft.com/en-us/azure/foundry/agents/concepts/standard-agent-setup)
- [Set up private networking for Foundry Agent Service](https://learn.microsoft.com/en-us/azure/foundry/agents/how-to/virtual-networks)
- [Foundry Samples on GitHub](https://github.com/microsoft-foundry/foundry-samples)
- [Azure AI Agent Service FAQ — Virtual Networking](https://learn.microsoft.com/en-us/azure/foundry/agents/faq#virtual-networking)

## License

This project is licensed under the terms specified in the LICENSE file.
