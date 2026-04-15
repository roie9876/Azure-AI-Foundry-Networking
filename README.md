# Microsoft Foundry Networking — The Complete Guide

> **Updated April 2026** — Covers all networking options for Microsoft Foundry (formerly Azure AI Foundry), including Private Link, Managed VNet, BYO VNet injection, and Network Security Perimeter.

[![Deploy To Azure](https://raw.githubusercontent.com/Azure/azure-quickstart-templates/master/1-CONTRIBUTION-GUIDE/images/deploytoazure.svg?sanitize=true)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Froie9876%2FAzure-AI-Foundry-Networking%2Frefs%2Fheads%2Fmain%2Fbicep%2Fazuredeploy.json)

> **Modified Template 15** — This repo includes a copy of the [official Microsoft Foundry Template 15](https://github.com/microsoft-foundry/foundry-samples/tree/main/infrastructure/infrastructure-setup-bicep/15-private-network-standard-agent-setup) with added support for **UDR (route all traffic through Azure Firewall)** and **private subnets** (`defaultOutboundAccess: false`). Set the `firewallPrivateIp` parameter to your firewall's private IP to enable deny-all egress control.

---

## Table of Contents

- [Why Is This So Confusing?](#why-is-this-so-confusing)
- [Part 1: The Components — What Needs Network Protection?](#part-1-the-components--what-needs-network-protection)
- [Part 2: The Three Network Directions](#part-2-the-three-network-directions)
  - [Direction 1: Inbound](#direction-1-inbound--who-can-reach-your-foundry-resource)
  - [Direction 2: Outbound from Foundry](#direction-2-outbound-from-foundry--how-it-reaches-azure-services)
  - [Direction 3: Outbound from Agent compute](#direction-3-outbound-from-agent-compute--how-your-agents-reach-data)
- [Part 3: The Four Network Options](#part-3-the-four-network-options-and-when-to-use-each)
  - [Option A: Private Link (Inbound)](#option-a-private-link-inbound-isolation--ga)
  - [Option B: BYO VNet Injection (Outbound)](#option-b-byo-vnet-injection-outbound-isolation--ga)
  - [Option C: Managed VNet (Outbound)](#option-c-managed-vnet-outbound-isolation--preview)
  - [Option D: Network Security Perimeter](#option-d-network-security-perimeter-nsp--preview)
- [Part 4: Decision Guide](#part-4-how-it-all-fits-together--decision-guide)
- [Part 5: Agent Setup Tiers](#part-5-agent-setup-tiers--when-do-you-provide-resources)
- [Part 5b: How Dependent Resources Connect — AI Search Networking Deep Dive](#part-5b-how-dependent-resources-connect--ai-search-networking-deep-dive)
  - [Mechanism 1: Trusted Services Exception (Inbound to AI Search)](#mechanism-1-trusted-services-exception-inbound-to-ai-search)
  - [Mechanism 2: Shared Private Access (Outbound from AI Search)](#mechanism-2-shared-private-access-outbound-from-ai-search)
  - [Comparison: Trusted Services vs Shared Private Access](#comparison-trusted-services-vs-shared-private-access)
  - [What Your Private Deployment Should Use](#what-your-private-deployment-should-use)
  - [Does Foundry Have SPLs Too?](#does-foundry-have-spls-too)
- [Part 6: Agent Tools — Network Support Matrix](#part-6-agent-tools--network-support-matrix)
- [Part 7: Feature Limitations with Network Isolation](#part-7-feature-limitations-with-network-isolation)
- [Part 8: Known Limitations](#part-8-known-limitations)
- [Part 9: RBAC Roles Required](#part-9-rbac-roles-required)
- [Part 10: Resource Provider Registrations](#part-10-resource-provider-registrations)
- [Part 11: Troubleshooting](#part-11-troubleshooting)
- [Part 12: Which Bicep Template Should I Use?](#part-12-which-bicep-template-should-i-use)
- [References — The Microsoft Docs Map](#references--the-microsoft-docs-map)
- [Part 13: Hands-On — Deploying Template 15 in a Hub-Spoke Network](#part-13-hands-on--deploying-template-15-in-a-hub-spoke-network)
  - [Firewall Rules Reference](#firewall-rules-reference)
- [Part 14: SharePoint Online Integration — Secure Sync with Foundry IQ](#part-14-sharepoint-online-integration--secure-sync-with-foundry-iq)

---

## Why Is This So Confusing?

If you've been reading Microsoft's docs and feeling lost — you're not alone. Microsoft has **5 separate documentation pages** about Foundry networking, and it's unclear how they relate to each other. Here's the problem: **Foundry is not one thing — it's made up of several components, and each component has its own networking story.**

This guide puts it all in one place.

---

## Part 1: The Components — What Needs Network Protection?

Before talking about network options, you need to understand that Microsoft Foundry has **four different components**, and each one has separate networking considerations:

```
┌─────────────────────────────────────────────────────────────────┐
│                    Microsoft Foundry                            │
│                                                                 │
│  ┌──────────────┐  ┌──────────────┐  ┌────────────────────────┐│
│  │ 1. Foundry   │  │ 2. Foundry   │  │ 3. Agent Service       ││
│  │    Portal    │  │    Resource  │  │    (compute that runs  ││
│  │    (UI)      │  │    (APIs)    │  │     your agents)       ││
│  └──────────────┘  └──────────────┘  └────────────────────────┘│
│                                                                 │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │ 4. Dependent Azure Resources                               ││
│  │    (Storage, Cosmos DB, AI Search, Key Vault, OpenAI, etc.)││
│  └─────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────┘
```

| Component | What it is | Network question it raises |
|-----------|-----------|---------------------------|
| **Foundry Portal** | The web UI at ai.azure.com where you manage projects | How do your users access the portal? |
| **Foundry Resource** (Account + Project) | The Azure resource with APIs and settings | Can it be reached from the internet? Who can call its APIs? |
| **Agent Service compute** | The container that runs your AI agents, evaluations, prompt flows | Where does agent code execute? What can it reach? |
| **Dependent resources** | Azure Storage, Cosmos DB, AI Search, Azure OpenAI, Key Vault | Are these resources accessible from the internet or only privately? |

**Each of these components has its own network surface**, and you need to secure all of them. That's why there are so many docs — each one focuses on a different piece.

---

## Part 2: The Three Network Directions

Now that you know the components, there are **three directions** of network traffic to secure:

![Plan for Network Isolation](docs/images/plan-network-isolation-diagram.png)

### Direction 1: Inbound — Who can reach your Foundry resource?

**This is about your users and client applications connecting to Foundry.**

By default, your Foundry resource is accessible from the public internet. Anyone with the right credentials can call the APIs or open the portal. For enterprise deployments, you want to restrict this.

**How you lock it down:** You set the **Public Network Access (PNA) flag** on your Foundry resource:

| PNA Setting | What it means |
|-------------|--------------|
| **All networks** | Anyone on the internet can connect (default — fine for testing) |
| **Selected IPs** | Only specific IP ranges can connect (e.g., your office IP) |
| **Disabled** | No public access at all — only reachable through a **private endpoint** in your VNet |

When you disable public access and add a private endpoint, your Foundry resource gets a private IP address inside your virtual network. Your team connects through VPN, ExpressRoute, or a Bastion jump box — never over the public internet.

> **This applies to ALL setup tiers** (Basic, Standard, Standard+VNet). You can always add a private endpoint, regardless of which agent tier you chose.

### Direction 2: Outbound from Foundry — How it reaches Azure services

**This is about how the Foundry resource talks to its dependent Azure services** (Storage, Key Vault, Azure OpenAI, etc.).

By default, these communications go over the Azure backbone network using public endpoints — encrypted, but technically "public." For maximum security, you create **private endpoints** for each dependent service, so all traffic stays fully private.

### Direction 3: Outbound from Agent compute — How your agents reach data

**This is the big one.** When your AI agents run, they need to reach data sources, APIs, and tools. This traffic comes from the **Agent Service compute** — the container that executes your agent code.

**This is where it gets complicated**, because Microsoft offers **three different options** for securing this traffic. That's the next section.

---

## Part 3: The Four Network Options (And When To Use Each)

Here's where people get confused. Microsoft offers **four different networking approaches**, and they're documented in four separate pages. Here's how they map:

```
                        ┌──────────────────────────────────────┐
                        │     INBOUND (to Foundry)             │
                        │                                      │
                        │  Option A: Private Link              │
                        │  Option D: Network Security          │
                        │            Perimeter (NSP)           │
                        └──────────────────────────────────────┘

                        ┌──────────────────────────────────────┐
                        │     OUTBOUND (from Agent compute)    │
                        │                                      │
                        │  Option B: BYO VNet Injection (GA)   │
                        │  Option C: Managed VNet (Preview)    │
                        └──────────────────────────────────────┘
```

### Quick Comparison

| | **Option A: Private Link** | **Option B: BYO VNet Injection** | **Option C: Managed VNet** | **Option D: NSP** |
|---|---|---|---|---|
| **What it secures** | Inbound access to Foundry | Outbound from Agent compute | Outbound from Agent compute | Inbound + Outbound (data-plane) |
| **Status** | GA | GA | **Preview** | **Preview** |
| **Complexity** | Low | Medium-High | Low-Medium | Medium |
| **Who manages the network** | You create PE in your VNet | You provide VNet + subnets | Microsoft manages the VNet | Microsoft manages the perimeter |
| **Agent runs in** | N/A (inbound only) | Your VNet subnet | Microsoft-managed VNet | N/A (policy layer) |
| **Can reach on-prem** | N/A | Yes (agents are in your VNet) | Via Application Gateway only | N/A |
| **Your own firewall** | N/A | Yes | No (Microsoft-managed FW) | N/A |
| **Use it when** | You need private access to the portal/APIs | Full network control, compliance, on-prem access | Simpler setup, no own VNet needed | You want a policy-based perimeter across multiple Azure services |
| **Docs** | [Private Link](https://learn.microsoft.com/en-us/azure/foundry/how-to/configure-private-link?view=foundry) | [VNet for Agents](https://learn.microsoft.com/en-us/azure/foundry/agents/how-to/virtual-networks) | [Managed VNet](https://learn.microsoft.com/en-us/azure/foundry/how-to/managed-virtual-network?view=foundry) | [NSP](https://learn.microsoft.com/en-us/azure/foundry/how-to/add-foundry-to-network-security-perimeter?view=foundry) |

> **Important:** These are NOT mutually exclusive. You typically **combine** Option A (Private Link for inbound) with either Option B or C (for outbound). Option D (NSP) is a complementary policy layer on top.

Now let's explain each one.

---

### Option A: Private Link (Inbound Isolation) — GA

**What it does:** Creates a private endpoint in your VNet that gives your Foundry resource a private IP address. Your team accesses the Foundry portal and APIs through this private IP instead of the public internet.

**Think of it like:** A private door into Foundry that only exists inside your building (VNet). The public door gets locked.

**How to set it up:**

1. In the [Azure portal](https://portal.azure.com/), go to your Foundry resource → **Networking**.
2. Set Public network access to **Disabled**.
3. Select **+ Private endpoint** → choose your VNet and subnet.
4. Azure creates a private IP and updates DNS automatically.

**DNS is the key:** When your team types `yourfoundry.cognitiveservices.azure.com`, the Private DNS Zone resolves it to the private IP (e.g., `10.0.1.5`) instead of a public IP. Same URL, private path. No code changes needed.

**Your team connects via:**

| Method | Best for |
|--------|----------|
| **[VPN Gateway](https://learn.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-about-vpngateways)** (Point-to-Site) | Individual developers on laptops |
| **[VPN Gateway](https://learn.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-about-vpngateways)** (Site-to-Site) | Connecting an entire office |
| **[ExpressRoute](https://learn.microsoft.com/en-us/azure/expressroute/)** | Dedicated private connection from data center |
| **[Azure Bastion](https://learn.microsoft.com/en-us/azure/bastion/bastion-overview)** | Quick access via a jump box VM in the browser |

**Trusted Azure services** can bypass the firewall if you enable it — they authenticate via managed identity:

| Service | Resource Provider |
|---------|------------------|
| Foundry Tools | `Microsoft.CognitiveServices` |
| Azure AI Search | `Microsoft.Search` |
| Azure Machine Learning | `Microsoft.MachineLearningServices` |

![Foundry Portal Firewall Settings](docs/images/foundry-portal-firewall.png)

---

### Option B: BYO VNet Injection (Outbound Isolation) — GA

**What it does:** Places the Agent Service compute (the container running your agents) directly inside **your own virtual network**. You provide the VNet and subnets. Microsoft injects the agent container into your subnet.

**Think of it like:** Instead of your agents running on some Microsoft server you can't see, they run *inside your own network*. You control what they can reach.

**This is the full enterprise solution.** It's GA (production-ready) and gives you maximum control.

![Private Network Isolation Architecture](docs/images/private-network-isolation.png)

**What gets deployed in your VNet:**

| Subnet | What's in it | Size |
|--------|-------------|------|
| **Agent Subnet** | Your agents run here. Delegated to `Microsoft.App/environments`. Microsoft injects the agent container. | `/24` recommended (256 IPs), `/27` minimum |
| **Private Endpoint Subnet** | Private endpoints for Storage, Cosmos DB, AI Search, Foundry Account. Each gets a private IP. | Sized per number of endpoints |

**How traffic flows:**
- Agent code runs in the agent subnet → calls Azure Storage → goes through the private endpoint in the PE subnet → reaches Storage over private IP. Never touches the public internet.
- Agent calls Azure OpenAI → goes through the Foundry private endpoint → private IP. Same story.
- Agent calls an on-premises API → goes through your VPN/ExpressRoute → reaches your data center. Works natively because the agent is already in your VNet.

**Required Private DNS Zones** (so URLs resolve to private IPs):

| For | Private DNS Zone |
|-----|-----------------|
| Foundry Account | `privatelink.cognitiveservices.azure.com` |
| Foundry Account | `privatelink.openai.azure.com` |
| Foundry Account | `privatelink.services.ai.azure.com` |
| Azure AI Search | `privatelink.search.windows.net` |
| Azure Cosmos DB | `privatelink.documents.azure.com` |
| Azure Storage | `privatelink.blob.core.windows.net` |
| Azure Storage | `privatelink.file.core.windows.net` |

**Deployment:** Use the Bicep or Terraform templates — they create everything:
- **Bicep:** [15-private-network-standard-agent-setup](https://github.com/microsoft-foundry/foundry-samples/tree/main/infrastructure/infrastructure-setup-bicep/15-private-network-standard-agent-setup)
- **Terraform:** [15b-private-network-standard-agent-setup-byovnet](https://github.com/microsoft-foundry/foundry-samples/tree/main/infrastructure/infrastructure-setup-terraform/15b-private-network-standard-agent-setup-byovnet)
- **Hybrid/on-prem:** [19-hybrid-private-resources-agent-setup](https://github.com/microsoft-foundry/foundry-samples/tree/main/infrastructure/infrastructure-setup-bicep/19-hybrid-private-resources-agent-setup)

**Add a firewall** with hub-and-spoke if you need egress control:

![Hub-and-Spoke Firewall Configuration](docs/images/network-hub-spoke-diagram.png)

---

### Option C: Managed VNet (Outbound Isolation) — Preview

**What it does:** Microsoft creates and manages a virtual network **for you**. Your agents run in this Microsoft-managed VNet. You don't provide a VNet or subnets — Microsoft handles it all.

**Think of it like:** Option B is "bring your own house, we'll move in." Option C is "we'll build the house for you, you just tell us the rules."

> ⚠️ **This is currently in Preview** — not recommended for production. If your enterprise doesn't allow preview features, use Option B instead.

![Managed VNet Overview](docs/images/diagram-managed-network.png)

**Two isolation modes for the managed VNet:**

**Allow Internet Outbound** — Agents can reach any internet destination. Useful for development where agents need to download packages or call external APIs. Azure still manages the VNet and can add private endpoints for Azure services.

![Allow Internet Outbound](docs/images/diagram-allow-internet-outbound.png)

**Allow Only Approved Outbound** — Agents can ONLY reach destinations you explicitly approve. Everything else is blocked. You define allowed targets using service tags, FQDNs, or private endpoints. Microsoft creates a managed Azure Firewall automatically.

![Allow Only Approved Outbound](docs/images/diagram-allow-only-approved-outbound.png)

**Managed VNet vs BYO VNet Injection — side by side:**

| | Managed VNet (Option C) | BYO VNet Injection (Option B) |
|---|---|---|
| Who creates the VNet | Microsoft | You |
| Your firewall | No — managed firewall auto-created | Yes — bring your own |
| On-premises access | Via Application Gateway only | Native (agents are in your VNet) |
| Evaluation compute security | Not supported | Supported |
| MCP tools with network isolation | Not supported (public MCP only) | Supported (private MCP) |
| Logging outbound traffic | Not supported | Supported (your firewall) |
| Status | **Preview** | **GA** |
| Deploy via | Bicep template only | Portal, Bicep, or Terraform |

**Managed VNet limitations:**
- Bicep-only deployment ([18-managed-virtual-network-preview](https://github.com/microsoft-foundry/foundry-samples/tree/main/infrastructure/infrastructure-setup-bicep/18-managed-virtual-network-preview))
- Can't bring your own firewall
- Can't switch back to no isolation once enabled
- FQDN rules only support ports 80 and 443
- Private endpoints to Cosmos DB and AI Search must be created manually via CLI
- Each Foundry account gets its own managed firewall (can't share)
- Preview regions only
- Requires feature flag registration: `az feature register --namespace Microsoft.CognitiveServices --name AI.ManagedVnetPreview`

---

### Option D: Network Security Perimeter (NSP) — Preview

**What it does:** NSP is a **policy-based security boundary** around multiple Azure PaaS resources. Instead of managing private endpoints one by one, you group resources into a perimeter and define inbound/outbound rules centrally.

**Think of it like:** Options A/B/C are about building walls and doors. Option D is about drawing a circle around a group of resources and saying "nothing crosses this circle unless it's on the list."

> ⚠️ **This is also in Preview.**

![Network Security Perimeter](docs/images/network-security-perimeter-diagram.png)

**How it works:**
1. Create a Network Security Perimeter in Azure
2. Associate your Foundry resource (and other Azure resources like Storage, AI Search) with the perimeter
3. Start in **Learning mode** — logs what would be blocked without actually blocking
4. Define **inbound rules** (who can reach your resources — by IP range or subscription)
5. Define **outbound rules** (what your resources can reach — by FQDN)
6. Switch to **Enforced mode** — now the rules are active

**Key concept:** Resources inside the same NSP **trust each other automatically** (when using managed identity). You only need rules for traffic crossing the perimeter boundary.

**NSP vs Private Link:**

| | Private Link (Option A) | NSP (Option D) |
|---|---|---|
| Approach | Network-level (private endpoints, private IPs) | Policy-level (rules, allow-lists) |
| Controls | Inbound only | Inbound + Outbound (data-plane) |
| Scope | One resource at a time | Multiple resources grouped together |
| Private IPs | Yes — resources get private IPs in your VNet | No — works at the policy layer |
| Status | **GA** | **Preview** |

**NSP doesn't replace Private Link** — it's complementary. You might use Private Link for the network-level isolation and NSP for the policy-level governance on top.

---

## Part 4: How It All Fits Together — Decision Guide

Here's the practical guide: **which options do you combine for your scenario?**

### Scenario 1a: "Just getting started, minimal security"
- **Agent tier:** Basic
- **Inbound:** Public access (default)
- **Outbound:** N/A (Microsoft-managed compute)
- **Options used:** None — just create an account and project
- **Template:** [40-basic-agent-setup](https://github.com/microsoft-foundry/foundry-samples/tree/main/infrastructure/infrastructure-setup-bicep/40-basic-agent-setup)

### Scenario 1b: "Basic agents, but private portal access"
- **Agent tier:** Basic
- **Inbound:** Option A (Private Link) — disable public access, add private endpoint
- **Outbound:** N/A (Microsoft-managed compute, Azure backbone)
- **Options used:** A
- **Template:** [10-private-network-basic](https://github.com/microsoft-foundry/foundry-samples/tree/main/infrastructure/infrastructure-setup-bicep/10-private-network-basic)

> ℹ️ **Basic ≠ public only.** You can add a private endpoint to a Basic setup. The "Basic" label refers to data storage (Microsoft-managed multitenant) — not the network access level. What you CAN'T do with Basic is BYO resources, VNet injection, or CMK.

### Scenario 2: "Production, data in my tenant, but no VNet needed"
- **Agent tier:** Standard (BYO Storage, Cosmos DB, AI Search)
- **Inbound:** Option A (Private Link) — disable public access, add private endpoint
- **Outbound:** Default (Azure backbone)
- **Options used:** A
- **Template:** [41-standard-agent-setup](https://github.com/microsoft-foundry/foundry-samples/tree/main/infrastructure/infrastructure-setup-bicep/41-standard-agent-setup) + manually add PE, or [10-private-network-basic](https://github.com/microsoft-foundry/foundry-samples/tree/main/infrastructure/infrastructure-setup-bicep/10-private-network-basic)

> ⚠️ **What's NOT private here:** The Foundry portal/API gets a private IP (your users connect privately), but the **Agent Service compute still runs on Microsoft's infrastructure**. It talks to your BYO resources (Storage, Cosmos DB, AI Search) over the **Azure backbone using their public endpoints** — encrypted, but not over private IPs. Your BYO resources still have public endpoints unless you manually lock them down. If you need the agent compute itself to be in your VNet with private IPs to all resources, go to **Scenario 3**.

### Scenario 3: "Full enterprise lockdown"
- **Agent tier:** Standard + BYO VNet
- **Inbound:** Option A (Private Link) — disable public access
- **Outbound:** Option B (BYO VNet Injection) — agents in your VNet, all private endpoints, all resources have public access disabled
- **Firewall:** Hub-and-spoke with Azure Firewall for egress control
- **Options used:** A + B
- **Template:** [15-private-network-standard-agent-setup](https://github.com/microsoft-foundry/foundry-samples/tree/main/infrastructure/infrastructure-setup-bicep/15-private-network-standard-agent-setup)

> ✅ **Everything is private here:** Foundry portal (private endpoint), Agent compute (injected into your VNet subnet), and ALL BYO resources (private endpoints, public access disabled). This is the only scenario where the agent compute itself has a private IP in your network.

### Scenario 4: "Enterprise lockdown, but don't want to manage a VNet"
- **Agent tier:** Standard
- **Inbound:** Option A (Private Link)
- **Outbound:** Option C (Managed VNet) — Microsoft manages the VNet
- **Options used:** A + C *(Preview)*
- **Template:** [18-managed-virtual-network-preview](https://github.com/microsoft-foundry/foundry-samples/tree/main/infrastructure/infrastructure-setup-bicep/18-managed-virtual-network-preview)

> ⚠️ **Preview.** Agent compute runs in a Microsoft-managed VNet (not your VNet). You don't see or manage the network — Microsoft handles it. Some limitations: no private MCP, no evaluation compute isolation, no custom firewall.

### Scenario 5: "Full lockdown + private MCP servers or on-prem data"
- **Agent tier:** Standard + BYO VNet
- **Inbound:** Option A (Private Link)
- **Outbound:** Option B (BYO VNet Injection) + MCP subnet
- **Options used:** A + B
- **Template:** [19-hybrid-private-resources-agent-setup](https://github.com/microsoft-foundry/foundry-samples/tree/main/infrastructure/infrastructure-setup-bicep/19-hybrid-private-resources-agent-setup)

> Uses 3 subnets: agent subnet, PE subnet, and an MCP subnet for hosting private MCP servers accessible by the agent.

---

## Part 5: Agent Setup Tiers — When Do You Provide Resources?

This is a critical question: **when do YOU need to create and manage Azure resources for the Agent Service, and when does Microsoft handle it?**

| | Basic | Standard | Standard + BYO VNet |
|---|---|---|---|
| **Cosmos DB** | ❌ Microsoft manages it | ✅ **You provide it** | ✅ **You provide it** |
| **Azure Storage** | ❌ Microsoft manages it | ✅ **You provide it** | ✅ **You provide it** |
| **Azure AI Search** | ❌ Microsoft manages it | ✅ **You provide it** | ✅ **You provide it** |
| **Virtual Network** | ❌ Not needed | ❌ Not needed | ✅ **You provide it** |
| **Where is agent data stored?** | Microsoft's multitenant storage (you can't see it) | In YOUR Azure resources (your tenant) | In YOUR Azure resources (your tenant) |
| **Who pays for data resources?** | Included | You pay for Cosmos DB, Storage, AI Search | You pay for Cosmos DB, Storage, AI Search |

**In plain terms:**
- **Basic** = You bring NOTHING. Microsoft stores your agent conversations, files, and search indexes in their own infrastructure. Fast to start, but you don't control where data lives.
- **Standard** = You bring **3 resources**: Azure Storage + Azure Cosmos DB + Azure AI Search. All agent data is stored in YOUR Azure subscription. You control it, you see it, you pay for it.
- **Standard + BYO VNet** = Same as Standard, PLUS you also bring a **Virtual Network** with subnets. The agent compute runs inside your network.

### Quick Reference

| Capability | Basic | Standard | Standard + BYO VNet |
|-----------|-------|----------|---------------------|
| Quick start, no resource management | ✅ | | |
| Data in your own Azure resources | | ✅ | ✅ |
| Customer Managed Keys (CMK) | | ✅ | ✅ |
| Full network isolation (agents in your VNet) | | | ✅ |

**Standard setup BYO resources:**

| Your Resource | What it stores | Minimum requirements |
|---------------|---------------|---------------------|
| Azure Storage | Files uploaded by users/devs | Standard account |
| Azure AI Search | Vector stores (embeddings) | Any tier |
| Azure Cosmos DB for NoSQL | Conversations, agent metadata | 3000 RU/s minimum (1000 × 3 containers) |

**Cosmos DB containers created automatically:**

| Container | Data |
|-----------|------|
| `thread-message-store` | User conversations |
| `system-thread-message-store` | Internal system messages |
| `agent-entity-store` | Agent metadata (instructions, tools, name) |

For N projects under one account, you need N × 3000 RU/s.

### Behind the Scenes: What is a Capability Host?

If you dig into the Azure portal or use the REST API, you will encounter an object called a **[Capability Host](https://learn.microsoft.com/en-us/azure/foundry/agents/concepts/capability-hosts?view=foundry-classic)**. 

* **What is it?** The Capability Host is the underlying infrastructure engine that actually runs your AI agents. It acts as the bridge that binds your agent code to your BYO data resources (Cosmos DB, Storage, AI Search) and the LLM models. 
* **Why it matters for networking:** When you use **Option B (BYO VNet Injection)**, the Capability Host is the actual physical resource component that gets injected into your delegated `Agent Subnet`.

> **💡 Pro Tip: Stuck Deletions & Cleanups** 
> Capability hosts are **immutable**. If you change your network setup, you must delete the capability host and recreate it. Occasionally, a capability host can get "stuck" in a deleting or failed state, making it impossible to delete from the UI (which can prevent you from dropping or changing your subnets). 
> 
> If you get stuck with a locked capability host, there is a manual cleanup procedure. You can use the `deleteCaphost.sh` script or direct Azure CLI REST API calls to force-delete the "zombie" capability host object so you can start fresh. (Check the official GitHub/Microsoft troubleshooting guides for the exact cleanup script).

---

## Part 5b: How Dependent Resources Connect — AI Search Networking Deep Dive

When you deploy a fully private Foundry setup (Scenario 3 / Template 15), all your BYO resources — AI Search, Storage, Cosmos DB, AI Services — have **public access disabled**. But these resources need to talk to *each other*, not just to Foundry and your agents.

This section explains the two networking mechanisms that control **how Azure AI Search connects to and from other services** in a private deployment. These are often confused because they appear on the same Networking page in the portal — but they solve completely different problems.

```
                          ┌──────────────────────┐
      Foundry/OpenAI ───► │   Azure AI Search    │ ───► Azure Storage
       (INBOUND)          │   (your resource)    │       (OUTBOUND)
                          └──────────────────────┘
                          
      Controlled by:          Controlled by:
      "Trusted Services"      "Shared Private Access"
      checkbox                (shared private links)
```

### Mechanism 1: Trusted Services Exception (Inbound to AI Search)

**Direction: INBOUND** — Other Azure services reaching *into* AI Search.

On the AI Search Networking page → **Firewalls and virtual networks** tab, there is a checkbox under **Exceptions**:

> ☑ Allow Azure services on the trusted services list to access this search service.

![AI Search Trusted Services Exception](docs/images/ai-search-trusted-services.jpeg)

**What this does:** When public access is **Disabled**, nobody can reach AI Search — not even other Azure services. Checking this box creates an exception for specific Azure services that Microsoft considers "trusted." These services can bypass the IP firewall using their **managed identity** instead of a network path.

**The trusted services list for AI Search includes:**

| Trusted Service | Resource Provider | Why it needs access |
|---|---|---|
| **Microsoft Foundry / Azure OpenAI** | `Microsoft.CognitiveServices` | RAG patterns — Foundry queries AI Search to retrieve relevant documents for "Azure OpenAI On Your Data" |
| **Azure Machine Learning** | `Microsoft.MachineLearningServices` | ML pipelines that query search indexes |

**How it works under the hood:**
1. The trusted service (e.g., Foundry) has a **system-assigned managed identity**
2. That identity has a **role assignment** on the AI Search service (e.g., `Search Index Data Reader` or `Search Index Data Contributor`)
3. The service authenticates via Microsoft Entra ID — no API keys, no public IP needed
4. AI Search validates the Entra token and checks the caller is on the trusted list
5. The request is allowed through even though public access is disabled

**Key characteristics:**
- **Free** — no additional cost
- **Identity-based** — relies on Entra ID + RBAC, not network paths
- **Limited scope** — only the services on Microsoft's trusted list can use this; you can't add arbitrary services
- Works even when public network access is **Disabled** (that's the whole point)

> **Ref:** [Configure network access and firewall rules for Azure AI Search](https://learn.microsoft.com/en-us/azure/search/service-configure-firewall#grant-access-to-trusted-azure-services)

### Mechanism 2: Shared Private Access (Outbound from AI Search)

**Direction: OUTBOUND** — AI Search reaching *out* to other Azure resources.

On the AI Search Networking page → **Shared private access** tab, you can create **Shared Private Links (SPLs)** that let AI Search connect to other resources through managed private endpoints.

![AI Search Shared Private Access](docs/images/ai-search-shared-private-access.jpeg)

#### What is a Shared Private Link (SPL)?

A Shared Private Link is a **private endpoint that a PaaS service creates inside Microsoft's own managed infrastructure** — not in your VNet. It solves a specific problem: how does a fully managed service (like AI Search) reach another locked-down resource when it doesn't live in your virtual network?

**The key difference from a regular Private Endpoint:**

| | Private Endpoint (PE) | Shared Private Link (SPL) |
|---|---|---|
| **Created by** | You, in your VNet | The Azure service (e.g., AI Search), in Microsoft's infrastructure |
| **Lives in** | Your subnet (`pe-subnet`) | Microsoft-managed network — invisible to you |
| **Shows up in your VNet?** | Yes — you see the NIC, the IP | No — it's entirely hidden |
| **Traffic path** | Your VNet → PE → target resource | Azure service → Azure backbone → target resource |
| **Visible in your firewall logs?** | Yes (if routed through firewall) | No — never touches your VNet |
| **You manage it?** | Fully | You create/delete the link; Microsoft manages the endpoint |
| **Approval required?** | You approve on the target resource | Same — target resource owner must approve |
| **Use case** | Your apps/VMs/agents reaching a resource | An Azure PaaS service reaching another resource on your behalf |

**Think of it this way:** You have Private Endpoints in your VNet so *your* agents can reach AI Search, Storage, etc. But AI Search itself also needs to reach Storage and AI Services — and AI Search doesn't live in your VNet. SPLs give AI Search its *own* private connection to those resources, running entirely on the Azure backbone.

```
YOUR VNET                                    MICROSOFT-MANAGED
┌─────────────────────┐                      ┌─────────────────────┐
│ pe-subnet           │                      │ (invisible to you)  │
│  PE ─────────────────────► AI Search ─────── SPL ──► Storage     │
│  PE ─────────────────────► Storage         │ SPL ──► AI Services │
│  PE ─────────────────────► AI Services     │ SPL ──► AI Services │
│  PE ─────────────────────► CosmosDB        │ SPL ──► AI Services │
└─────────────────────┘                      └─────────────────────┘
  You created these                           AI Search created these
  They live in YOUR subnet                    They live in MICROSOFT's infra
```

> **Note:** SPLs are not unique to AI Search. Other Azure PaaS services also support them — see [Does Foundry Have SPLs Too?](#does-foundry-have-spls-too) below.

#### What this does

AI Search indexers and vectorizers need to read data from Storage, call embedding models on AI Services, write to knowledge stores, etc. When those target resources have public access disabled, AI Search can't reach them — unless it has a private connection. Shared Private Access creates a **private endpoint managed by Microsoft** (inside Microsoft's infrastructure, not your VNet) that connects AI Search to a specific target resource.

**In a typical private Foundry deployment, you need these SPLs:**

| # | Name | Target Resource | Sub-resource | Purpose |
|---|------|----------------|-------------|---------|
| 1 | `shared-to-blob` | Azure Storage | `blob` | Indexer reads blob data; enrichment cache; debug sessions; knowledge store |
| 2 | `foundry_account` | AI Services | `foundry_account` | Billing and skills processing |
| 3 | `openai_account` | AI Services | `openai_account` | Calls embedding model (e.g., `text-embedding-3-small`) during indexing for integrated vectorization |
| 4 | `cognitive_account` | AI Services | `cognitiveservices_account` | Built-in cognitive skills (OCR, entity recognition, etc.) |

**How it works under the hood:**
1. You create the shared private link on AI Search (portal → Shared private access → Add)
2. Microsoft deploys a private endpoint inside its managed infrastructure — AI Search gets a private IP for talking to the target resource
3. The target resource owner must **approve** the connection (it shows as "Pending" until approved)
4. Once approved, AI Search always uses this private path for that resource — it's enforced, not optional
5. **Indexers must run in the private execution environment** — set `"executionEnvironment": "Private"` on each indexer (see [Section 7.4](#74-set-indexer-execution-environment-to-private))

**Key characteristics:**
- **Billed** — based on [Azure Private Link pricing](https://azure.microsoft.com/pricing/details/private-link/)
- **Network-based** — creates an actual private endpoint with a private IP
- **Requires approval** — the target resource owner must approve each connection
- **Forces private execution** — indexers using SPLs cannot run in the multitenant environment
- **Per-resource** — one SPL per resource + sub-resource combination

> **Important:** Once an SPL is created for a resource, AI Search **always** uses it for connections to that resource. You can't bypass the private connection for a public one. This is enforced internally.

> **Ref:** [Make outbound connections through a shared private link](https://learn.microsoft.com/en-us/azure/search/search-indexer-howto-access-private)

### Comparison: Trusted Services vs Shared Private Access

| | Trusted Services Exception | Shared Private Access (SPLs) |
|---|---|---|
| **Traffic direction** | **Inbound** to AI Search | **Outbound** from AI Search |
| **What it controls** | Who can call/query AI Search | What AI Search indexers/vectorizers can reach |
| **Mechanism** | Firewall bypass via managed identity + RBAC | Private endpoint created by AI Search in Microsoft-managed infrastructure |
| **Cost** | **Free** | **Billed** (Azure Private Link pricing) |
| **Setup complexity** | Low — checkbox + role assignments | Medium — create link, approve on target, configure indexer execution |
| **Security model** | Identity-based (Entra ID + RBAC) | Network-based (private endpoint, no public internet) |
| **Alternative** | Private endpoint from your VNet to AI Search (which Template 15 already creates) | IP firewall rules on target resource (weaker, doesn't work for same-region storage) |
| **One or the other?** | No — **they can coexist.** One is inbound, the other is outbound. | |

### What Your Private Deployment Should Use

In a full enterprise lockdown (Template 15 / hub-spoke), here's the recommendation:

| Feature | Recommendation | Reason |
|---|---|---|
| **Trusted services checkbox** | **Leave unchecked** (most restrictive) | You already have a private endpoint for AI Search in your `pe-subnet`. Foundry reaches AI Search through that PE. The checkbox is redundant and slightly widens the attack surface. |
| **Shared private access** | **Required — create 2-4 SPLs** | Without these, AI Search indexers can't reach your locked-down Storage and AI Services. Knowledge source creation will fail. |

**If you enable the trusted services checkbox anyway:**
- It's a **belt-and-suspenders** approach — Foundry can reach AI Search via PE *or* via the trusted exception
- There's no conflict, but it's less restrictive than PE-only
- Some organizations enable it during troubleshooting and forget to disable it — not ideal for zero-trust posture

**If you skip the shared private access:**
- AI Search indexers **will fail** with `transientFailure` errors
- Knowledge source creation in the Foundry portal will fail with: *"Failed to create knowledge source"*
- The indexer literally cannot reach the blob storage or embedding model endpoint

> **Note:** Azure AI Search is *also* on the trusted services list of **other** Azure resources. For example, you can use the trusted service exception to let [AI Search connect to Azure Storage as a trusted service](https://learn.microsoft.com/en-us/azure/search/search-indexer-howto-access-trusted-service-exception). However, this only works for **blob and ADLS Gen2** on Azure Storage, and only with a **system-assigned managed identity**. In a fully private deployment with SPLs, you don't need this — the SPL already provides the private connection.

### Does Foundry Have SPLs Too?

**Yes — but only when using Managed VNet (Option C), and they're called "outbound rules" or "managed private endpoints" instead of SPLs.**

The concept is identical: Foundry (like AI Search) is a managed PaaS service that needs to reach your locked-down resources. Depending on which networking option you chose, the mechanism differs:

| Networking Option | How Foundry reaches your resources | SPL-like mechanism? |
|---|---|---|
| **Option B: BYO VNet Injection** | Agents run **in your subnet** — they use your VNet's Private Endpoints directly | **No SPLs needed.** Agents are already in your network. |
| **Option C: Managed VNet** | Agents run in a **Microsoft-managed VNet** — Foundry creates managed private endpoints to reach your resources | **Yes — these are Foundry's equivalent of SPLs.** You configure them as "outbound rules" on the Managed VNet. |

**In a BYO VNet deployment (Option B / Template 15):**
- Your agents run in the `agent-subnet` of your spoke VNet
- They reach Storage, AI Search, CosmosDB, AI Services via the Private Endpoints in your `pe-subnet`
- No SPLs needed on Foundry — the agents *are* in your network

**In a Managed VNet deployment (Option C):**
- Your agents run in a Microsoft-managed VNet (invisible to you)
- Foundry creates **managed private endpoints** (outbound rules) from its managed VNet to your resources
- These are functionally the same as AI Search's SPLs — a private endpoint inside Microsoft's infrastructure, approved by the target resource owner
- You configure them in Portal → Foundry account → Networking → Managed VNet → Outbound rules

**Summary:** SPL is a general Azure pattern — any PaaS service that runs in Microsoft-managed infrastructure and needs to reach your locked-down resources will use some form of managed private endpoint. AI Search calls them "Shared Private Links." Foundry's Managed VNet calls them "outbound rules." The mechanism is the same.

---

## Part 6: Agent Tools — Network Support Matrix

Not all agent tools work behind a VNet. Here's the current status:

| Tool | Works in VNet? | Traffic path |
|------|---------------|-------------|
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

*Bing, Websearch, and SharePoint use the public internet even in VNet-isolated setups. Block via Azure Policy if needed.

> **SharePoint & AI Search connectivity in hub-spoke:** If you use an AI Search **SharePoint Online indexer**, the traffic from AI Search to SharePoint goes via the **Microsoft Graph API on the Microsoft backbone network**. It does **not** flow through your VNet, UDR, or Azure Firewall. This means SharePoint indexers work regardless of your network topology — no firewall rules, no private endpoints, no SPL needed for SharePoint.

---

## Part 7: Feature Limitations with Network Isolation

| Feature | Status | Notes |
|---------|--------|-------|
| Hosted Agents | ❌ Not supported | No VNet support |
| Publish to Teams/M365 | ❌ Not supported | Requires public endpoints |
| Synthetic Data for Evaluations | ❌ Not supported | Bring your own data |
| Traces | ❌ Not supported | No private Application Insights support |
| Workflow Agents | ⚠️ Partial | Inbound works. Outbound VNet injection not supported |
| AI Gateway | ⚠️ Partial | Auto-public. Needs its own network isolation |
| MCP tools + Managed VNet | ❌ Not supported | Use BYO VNet (Option B) for private MCP |
| Evaluation compute + Managed VNet | ❌ Not supported | Use BYO VNet (Option B) |

---

## Part 8: Known Limitations

- **RFC1918 only:** Subnets must use `10.0.0.0/8`, `172.16.0.0/12`, or `192.168.0.0/16`
- **Avoid 172.17.0.0/16:** Reserved by Docker
- **One agent subnet per Foundry resource** — can't share subnets
- **Subnet size:** Minimum `/27` (32 IPs), recommended `/24` (256 IPs)
- **Same subscription:** Private endpoints must match the VNet subscription
- **Capability hosts are immutable:** Can't update after creation — delete and recreate
- **Managed VNet is one-way:** Once enabled, can't disable or switch modes
- **File Search + Blob Storage:** Not supported behind VNet

---

## Part 9: RBAC Roles Required

| Who | Needs this role | Scope |
|-----|----------------|-------|
| Admin creating the account | Azure AI Account Owner | Subscription |
| Admin assigning BYO resource permissions | Role Based Access Administrator | Resource group |
| Developers creating/editing agents | Azure AI User | Project |

### Project managed identity roles (Standard setup)

| Resource | Role |
|----------|------|
| Cosmos DB account | Cosmos DB Operator |
| Storage account | Storage Account Contributor |
| Azure AI Search | Search Index Data Contributor + Search Service Contributor |
| Blob container `<workspaceId>-azureml-blobstore` | Storage Blob Data Contributor |
| Blob container `<workspaceId>-agents-blobstore` | Storage Blob Data Owner |
| Cosmos DB database `enterprise_memory` | Cosmos DB Built-in Data Contributor |

### Custom RBAC for Cosmos DB Data Plan (Private Networks)

When your Cosmos DB operates within a private network setup, built-in roles might lack exact data-plane query access. You may need to create and assign a strictly-scoped **Custom Role** to your project's managed identity so it can read/query items over the private network. 

Run this PowerShell script (replace the variables with your own environments data):

```powershell
$resourceGroupName = "<your-resource-group>"
$accountName = "<your-cosmos-db-account-name>"

# 1. Create a custom Data-Plane Role
New-AzCosmosDBSqlRoleDefinition -AccountName $accountName `
  -ResourceGroupName $resourceGroupName `
  -Type CustomRole `
  -RoleName CosmosDBDataPlanRole `
  -DataAction @( `
    'Microsoft.DocumentDB/databaseAccounts/readMetadata', `
    'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/items/read', `
    'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/executeQuery', `
    'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/readChangeFeed' `
  ) `
  -AssignableScope "/"

# 2. Get the new Role's ID (You can pull the ID from the output of the command above)
$customRoleDefinitionId = "/subscriptions/<your-subscription-id>/resourceGroups/$resourceGroupName/providers/Microsoft.DocumentDB/databaseAccounts/$accountName/sqlRoleDefinitions/<new-role-guid>"

# 3. Assign the new role to the Foundry Project Managed Identity 
# (You can find the Principal ID under Identity in your AI Project)
$principalId = "<your-ai-project-managed-identity-object-id>"

New-AzCosmosDBSqlRoleAssignment -AccountName $accountName `
   -ResourceGroupName $resourceGroupName `
   -RoleDefinitionId $customRoleDefinitionId `
   -Scope "/" `
   -PrincipalId $principalId
```

---

## Part 10: Resource Provider Registrations

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

For Managed VNet (Preview), also register the feature flag:
```bash
az feature register --namespace Microsoft.CognitiveServices --name AI.ManagedVnetPreview
```

---

## Part 11: Troubleshooting

### Deployment Errors

| Error | Cause | Fix |
|-------|-------|-----|
| `CapabilityHost supports a single, non empty value for storageConnections...` | Missing BYO resource | Provide all three: Storage, Cosmos DB, AI Search |
| `Provided subnet must be of the proper address space` | Wrong IP range | Use RFC1918 only |
| `Subscription is not registered with required resource providers` | Missing registrations | Run `az provider register` commands above |
| `Failed async operation` / `Capability host operation failed` | Various | Create support ticket. Check capability host |
| `Subnet requires delegation to Microsoft.App/environments` | Stale resource | Purge via portal or run `deleteCaphost.sh` |
| `Timeout of 60000ms` on Agent pages | Can't reach Cosmos DB | Check private endpoint + DNS for Cosmos DB |
| `Failed to create knowledge source` | Multiple possible causes | See Knowledge Source section below |

### Knowledge Source Creation Failures

Creating a knowledge source (blob → AI Search → Foundry) in the portal is the most error-prone step in a private deployment. Here's a systematic checklist:

| # | Check | How to verify | Fix |
|---|-------|--------------|-----|
| 1 | **API key auth enabled on AI Services** | `az cognitiveservices account show --name <name> -g <rg> --query properties.disableLocalAuth` → should be `false` | See Part 13 Step 4.5 |
| 2 | **AI Services has RBAC on Storage** | Check AI Services MI has `Storage Blob Data Contributor` on storage account | See Part 13 Step 4.2 |
| 3 | **AI Services has RBAC on AI Search** | Check AI Services MI has `Search Index Data Contributor` + `Search Service Contributor` on AI Search | See Part 13 Step 4.2 |
| 4 | **SPL: AI Search → Blob Storage** | `az search shared-private-link-resource list` — should show `blob` with `Approved` status | See Part 13 Step 4.3 |
| 5 | **SPL: AI Search → Foundry Account** | Same command — should show `foundry_account` with `Approved` status | See Part 13 Step 4.3 |
| 6 | **SPL: AI Search → OpenAI Account** | Same command — should show `openai_account` with `Approved` status | See Part 13 Step 4.3 |
| 7 | **SPL: AI Search → Cognitive Account** | Same command — should show `cognitiveservices_account` with `Approved` status | See Part 13 Step 4.3 |
| 8 | **Indexer execution environment** | Check indexer JSON has `"executionEnvironment": "Private"` | See Part 13 Step 4.4 |
| 9 | **Semantic search enabled** | `az search service show --query properties.semanticSearch` — should be `free` or `standard` | See Part 13 Step 4.6 |
| 8 | **AI Search bypass** | `az search service show --query networkRuleSet.bypass` — consider `"AzurePortal"` for portal operations | Set bypass via REST API |

> **Tip:** Check the Azure Activity Log for the actual error details — the portal's generic "Failed to create knowledge source" message hides the real cause:
> ```bash
> az monitor activity-log list --resource-group <rg> \
>   --start-time $(date -u -v-30M '+%Y-%m-%dT%H:%M:%SZ') \
>   --status Failed \
>   --query "[].{time:eventTimestamp, operation:operationName.localizedValue, message:properties.statusMessage}" \
>   -o json
> ```

### DNS Issues

| Symptom | Fix |
|---------|-----|
| `nslookup` returns public IP | Link private DNS zone to your VNet |
| Custom DNS can't resolve | Forward `privatelink.*` to Azure DNS (`168.63.129.16`) |
| Intermittent resolution failures | Check DNS server reachability from all subnets |

### Connectivity Issues

| Symptom | Fix |
|---------|-----|
| Timeout on port 443 | Check NSG allows traffic to PE IP on 443 |
| Can't reach from on-prem | Check VPN/ER is up + route tables include VNet range |
| 403 Forbidden | Usually RBAC, not networking. Check role assignments |

### Agent Issues

| Symptom | Fix |
|---------|-----|
| Agent won't start | Use Standard setup (not Basic). Check subnet IPs available |
| Agent can't access MCP tools | Check private endpoints + managed identity RBAC |
| Evaluation fails with network errors | Check all DNS zones configured |
| Agent timeout on external calls | Firewall may block HTTPS. Allow destination or add NAT gateway |

---

## Part 12: Which Bicep Template Should I Use?

Microsoft provides **many** Bicep templates in [foundry-samples](https://github.com/microsoft-foundry/foundry-samples/tree/main/infrastructure/infrastructure-setup-bicep) and it's hard to know which one fits your scenario. Here's the complete guide:

### Template Decision Flowchart

```
Do you need network isolation?
│
├── No ──► Do you need your own data resources?
│          │
│          ├── No  ──► 40-basic-agent-setup
│          │           (Fastest start. Microsoft-managed storage.)
│          │
│          └── Yes ──► 41-standard-agent-setup
│                      (BYO Cosmos DB, Storage, AI Search. No VNet.)
│
└── Yes ──► Do you need ONLY inbound isolation (private portal access)?
           │
           ├── Yes ──► 10-private-network-basic
           │           (Private endpoint for Foundry. No agent VNet.)
           │
           └── No ──► You need full outbound isolation too.
                      │
                      ├── Want Microsoft to manage the VNet?
                      │   └── 18-managed-virtual-network-preview ⚠️ PREVIEW
                      │
                      ├── Want to manage your own VNet?
                      │   │
                      │   ├── System Managed Identity (default)
                      │   │   └── 15-private-network-standard-agent-setup ✅ MOST COMMON
                      │   │
                      │   ├── User Assigned Identity
                      │   │   └── 17-private-network-standard-user-assigned-identity-agent-setup
                      │   │
                      │   ├── Need API Management integration?
                      │   │   └── 16-private-network-standard-agent-apim-setup-preview ⚠️ PREVIEW
                      │   │
                      │   └── Need MCP servers or on-prem data in the VNet?
                      │       └── 19-hybrid-private-resources-agent-setup
                      │
                      └── (See also 30/31/32 templates if you need Customer Managed Keys)
```

### All Templates — Side by Side

| # | Template | Agent Tier | Identity | Network | Special Feature | Status |
|---|----------|-----------|----------|---------|----------------|--------|
| **40** | [basic-agent-setup](https://github.com/microsoft-foundry/foundry-samples/tree/main/infrastructure/infrastructure-setup-bicep/40-basic-agent-setup) | Basic | SMI | Public | Fastest start | GA |
| **42** | [basic-agent-setup-with-customization](https://github.com/microsoft-foundry/foundry-samples/tree/main/infrastructure/infrastructure-setup-bicep/42-basic-agent-setup-with-customization) | Basic | SMI | Public | BYO OpenAI + App Insights | GA |
| **45** | [basic-agent-bing](https://github.com/microsoft-foundry/foundry-samples/tree/main/infrastructure/infrastructure-setup-bicep/45-basic-agent-bing) | Basic | SMI | Public | Bing grounding pre-configured | GA |
| **41** | [standard-agent-setup](https://github.com/microsoft-foundry/foundry-samples/tree/main/infrastructure/infrastructure-setup-bicep/41-standard-agent-setup) | Standard | SMI | Public | BYO resources (Cosmos, Storage, Search) | GA |
| **43** | [standard-agent-setup-with-customization](https://github.com/microsoft-foundry/foundry-samples/tree/main/infrastructure/infrastructure-setup-bicep/43-standard-agent-setup-with-customization) | Standard | SMI | Public | BYO resources + BYO OpenAI | GA |
| **10** | [private-network-basic](https://github.com/microsoft-foundry/foundry-samples/tree/main/infrastructure/infrastructure-setup-bicep/10-private-network-basic) | — | SMI | **Private inbound** | PE for Foundry only (no agent VNet) | GA |
| **15** | [private-network-standard-agent-setup](https://github.com/microsoft-foundry/foundry-samples/tree/main/infrastructure/infrastructure-setup-bicep/15-private-network-standard-agent-setup) | Standard | SMI | **Full E2E** | BYO VNet + all private endpoints | **GA** |
| **16** | [private-network-standard-agent-apim-setup](https://github.com/microsoft-foundry/foundry-samples/tree/main/infrastructure/infrastructure-setup-bicep/16-private-network-standard-agent-apim-setup-preview) | Standard | SMI | **Full E2E** | + Azure API Management integration | **Preview** |
| **17** | [private-network-standard-UAI-agent-setup](https://github.com/microsoft-foundry/foundry-samples/tree/main/infrastructure/infrastructure-setup-bicep/17-private-network-standard-user-assigned-identity-agent-setup) | Standard | **UAI** | **Full E2E** | User Assigned Identity instead of SMI | GA |
| **18** | [managed-virtual-network-preview](https://github.com/microsoft-foundry/foundry-samples/tree/main/infrastructure/infrastructure-setup-bicep/18-managed-virtual-network-preview) | Standard | SMI | **Managed VNet** | Microsoft manages the VNet for you | **Preview** |
| **19** | [hybrid-private-resources-agent-setup](https://github.com/microsoft-foundry/foundry-samples/tree/main/infrastructure/infrastructure-setup-bicep/19-hybrid-private-resources-agent-setup) | Standard | SMI | **Full E2E** | + MCP servers + on-prem data + 3 subnets | GA |
| **30** | [customer-managed-keys](https://github.com/microsoft-foundry/foundry-samples/tree/main/infrastructure/infrastructure-setup-bicep/30-customer-managed-keys) | — | SMI | — | CMK encryption | GA |
| **31** | [CMK-standard-agent](https://github.com/microsoft-foundry/foundry-samples/tree/main/infrastructure/infrastructure-setup-bicep/31-customer-managed-keys-standard-agent) | Standard | SMI | — | CMK + Standard agent | GA |
| **32** | [CMK-UAI](https://github.com/microsoft-foundry/foundry-samples/tree/main/infrastructure/infrastructure-setup-bicep/32-customer-managed-keys-user-assigned-identity) | — | UAI | — | CMK + User Assigned Identity | GA |

**Legend:** SMI = System Managed Identity, UAI = User Assigned Identity, PE = Private Endpoint, E2E = End-to-end network isolation

### What's the Difference Between 15, 16, 17, and 19?

These four templates are all "full E2E network isolation" but with different extras:

| Template | Base | + What's Added |
|----------|------|---------------|
| **15** | Standard + BYO VNet + all PEs | **The baseline.** Start here if you just need full network isolation. |
| **16** | Same as 15 | + **Azure API Management** private endpoint. Use when agents need to call APIs through APIM. Preview. |
| **17** | Same as 15 | + **User Assigned Identity** instead of System Managed Identity. Use when you need to pre-create and share the identity across resources, or when your org requires UAI. |
| **19** | Same as 15 | + **Third subnet for MCP servers** + on-prem data access. Use when agents need to reach private MCP tools or hybrid data sources. Also supports toggling public/private access. |

### My Recommendation

For most enterprise deployments:

1. **Starting out?** Use **40** (basic) or **41** (standard) — no networking complexity
2. **Need private portal access only?** Use **10** — adds a private endpoint, nothing else
3. **Full enterprise lockdown?** Use **15** — this is the "production standard" template
4. **Need private MCP or on-prem data?** Use **19** — extends 15 with hybrid connectivity
5. **Don't want to manage a VNet?** Use **18** — but it's Preview, with limitations

---

## References — The Microsoft Docs Map

Here's where each doc fits (so you don't get lost again):

| Doc | Covers | Options |
|-----|--------|---------|
| [Configure Private Link](https://learn.microsoft.com/en-us/azure/foundry/how-to/configure-private-link?view=foundry) | **Inbound** access + overall network planning | Option A |
| [Virtual Networks for Agents](https://learn.microsoft.com/en-us/azure/foundry/agents/how-to/virtual-networks) | **Outbound** — BYO VNet injection for Agent Service | Option B |
| [Managed Virtual Network](https://learn.microsoft.com/en-us/azure/foundry/how-to/managed-virtual-network?view=foundry) | **Outbound** — Microsoft-managed VNet (Preview) | Option C |
| [Network Security Perimeter](https://learn.microsoft.com/en-us/azure/foundry/how-to/add-foundry-to-network-security-perimeter?view=foundry) | **Policy-based** inbound + outbound (Preview) | Option D |
| [Environment Setup](https://learn.microsoft.com/en-us/azure/foundry/agents/environment-setup) | Agent setup tiers (Basic / Standard / Standard+VNet) | Tier choice |
| [Standard Agent Setup](https://learn.microsoft.com/en-us/azure/foundry/agents/concepts/standard-agent-setup) | BYO resources (Cosmos DB, Storage, AI Search) details | Standard tier |
| [Capability Hosts](https://learn.microsoft.com/en-us/azure/foundry/agents/concepts/capability-hosts?view=foundry-classic) | The underlying compute infrastructure that runs your AI Agent | Architecture |
| [Foundry Samples](https://github.com/microsoft-foundry/foundry-samples) | Bicep + Terraform templates for all scenarios | All |

---

## Part 13: Hands-On — Deploying Template 15 in a Hub-Spoke Network

This section walks through a complete, production-ready deployment of **Template 15** (private network standard agent setup) into a hub-spoke topology with Azure Firewall. All egress traffic is forced through the firewall for inspection and control.

### Repository Structure

This repo is organized for a **modular, step-by-step deployment**:

```
deployment/
  1-deploy-hub.sh                 # Step 1: Hub infrastructure
  2-deploy-spoke.sh               # Step 2: Spoke networking
  3-deploy-sharepoint-sync.sh     # Step 4: SharePoint sync layer (Part 14)
  hub.env.example                 # Hub configuration template
  spoke.env.example               # Spoke configuration template
  sharepoint-sync.env.example     # SharePoint sync configuration template

bicep/                            # Step 3: Modified Template 15
  main.bicep                      #   Added: UDR support + private subnets
  main.bicepparam                 #   Parameter file
  azuredeploy.json                #   Compiled ARM template
  modules-network-secured/        #   Bicep modules
```

**Deployment order:**

```
1-deploy-hub.sh → 2-deploy-spoke.sh → Bicep (Template 15) → 3-deploy-sharepoint-sync.sh
     Hub              Spoke             Foundry               SharePoint (Part 14)
```

### The Scenario

You want a fully private AI Foundry agent deployment with enterprise-grade network controls:

- **Hub VNet** (`10.0.0.0/16`) — Azure Firewall, Private DNS Zones, Log Analytics
- **Spoke VNet** (`10.100.0.0/16`) — peered to hub, UDR routing `0.0.0.0/0` → Firewall
- **All PaaS endpoints private** — Foundry, AI Search, Storage, Cosmos DB behind private endpoints
- **Firewall controls all egress** — only whitelisted FQDNs allowed out
- (Optional) **SharePoint Online sync** — enterprise documents indexed for RAG via Foundry IQ

### Architecture Diagram

![Hub-Spoke Foundry Private Network](docs/hub-spoke-foundry-private.drawio.png)

```
┌──────────────────────────┐     VNet Peering     ┌──────────────────────────────────────┐
│  Hub VNet (10.0.0.0/16)  │◄───────────────────►│  Spoke VNet (10.100.0.0/16)           │
│                          │                      │                                        │
│  ┌────────────────────┐  │                      │  ┌─────────────────────────────────┐  │
│  │ Azure Firewall     │  │                      │  │ agent-subnet    10.100.3.0/24   │  │
│  │ 10.0.1.4           │  │                      │  │ delegated: Microsoft.App/envs   │  │
│  │ DNS Proxy enabled  │  │                      │  │ (Foundry Agent compute)         │  │
│  └────────────────────┘  │                      │  └─────────────────────────────────┘  │
│                          │                      │                                        │
│  ┌────────────────────┐  │                      │  ┌─────────────────────────────────┐  │
│  │ Log Analytics      │  │                      │  │ pe-subnet       10.100.4.0/24   │  │
│  │ (firewall logs)    │  │                      │  │ PEs: Foundry, Search, Storage,  │  │
│  └────────────────────┘  │                      │  │      Cosmos DB, Blob, File      │  │
│                          │                      │  └─────────────────────────────────┘  │
│  Private DNS Zones:      │                      │                                        │
│  • cognitiveservices     │   UDR: 0/0 → FW     │  ┌─────────────────────────────────┐  │
│  • openai                │◄─────────────────────│  │ func-subnet     10.100.6.0/24   │  │
│  • search                │                      │  │ (SharePoint sync Function App)  │  │
│  • documents             │                      │  └─────────────────────────────────┘  │
│  • blob / file / vault   │                      │                                        │
└──────────────────────────┘                      │  ┌─────────────────────────────────┐  │
                                                  │  │ vm-subnet / Bastion (testing)   │  │
                                                  │  └─────────────────────────────────┘  │
                                                  └──────────────────────────────────────┘
```

### Step 1: Deploy Hub Infrastructure

The hub contains the shared network services: Azure Firewall, Private DNS Zones, and Log Analytics.

```bash
cd deployment
cp hub.env.example hub.env      # Edit: set SUBSCRIPTION_ID, LOCATION
./1-deploy-hub.sh
```

**What it creates:**

| Resource | Purpose |
|----------|---------|
| Hub VNet (`10.0.0.0/16`) | Central network hub |
| Azure Firewall + Policy | Egress control with Foundry-specific FQDN rules |
| Log Analytics Workspace | Firewall diagnostic logs |
| 8 Private DNS Zones | DNS resolution for all private endpoints |

### Step 2: Deploy Spoke Network

The spoke creates the VNet infrastructure that will host Foundry and its dependent services.

```bash
cp spoke.env.example spoke.env  # Edit: set SUBSCRIPTION_ID, SPOKE_RG, etc.
./2-deploy-spoke.sh
```

**What it creates:**

| Resource | Purpose |
|----------|---------|
| Spoke VNet (`10.100.0.0/16`) | Hosts all Foundry resources |
| `agent-subnet` (`10.100.3.0/24`) | Foundry Agent Service (delegated to `Microsoft.App/environments`) |
| `pe-subnet` (`10.100.4.0/24`) | Private endpoints for all PaaS services |
| `vm-subnet` + Bastion | Test VM for verifying DNS and connectivity |
| VNet Peering | Bidirectional hub ↔ spoke |
| UDR | `0.0.0.0/0` → Firewall (applied to all subnets) |
| DNS Zone Links | All 8 zones linked to spoke VNet |

### Step 3: Deploy Foundry (Modified Template 15)

This repo includes a **modified copy** of the [official Microsoft Template 15](https://github.com/microsoft-foundry/foundry-samples/tree/main/infrastructure/infrastructure-setup-bicep/15-private-network-standard-agent-setup) in the `bicep/` directory.

#### Why We Modified Template 15

The original Template 15 creates a VNet with subnets but doesn't address hub-spoke scenarios. Our modifications add:

1. **`firewallPrivateIp` parameter** — When set, creates a UDR that routes `0.0.0.0/0` to your firewall and attaches it to the agent subnet
2. **`defaultOutboundAccess: false`** on subnets — Ensures no implicit outbound internet access even without the UDR
3. **Existing VNet support** — Uses `existingVnetResourceId` to deploy into the spoke VNet created in Step 2

#### Deploy via Azure Portal (Recommended)

Click the button below to deploy directly:

[![Deploy To Azure](https://raw.githubusercontent.com/Azure/azure-quickstart-templates/master/1-CONTRIBUTION-GUIDE/images/deploytoazure.svg?sanitize=true)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Froie9876%2FAzure-AI-Foundry-Networking%2Frefs%2Fheads%2Fmain%2Fbicep%2Fazuredeploy.json)

Fill in these key parameters:

| Parameter | Value |
|-----------|-------|
| **Location** | Same as your spoke (e.g., `swedencentral`) |
| **Vnet Name** | `spoke-vnet` |
| **Agent Subnet Name / Prefix** | `agent-subnet` / `10.100.3.0/24` |
| **Pe Subnet Name / Prefix** | `pe-subnet` / `10.100.4.0/24` |
| **Existing Vnet Resource Id** | Full resource ID of your spoke VNet |
| **Firewall Private Ip** | Your firewall's private IP (e.g., `10.0.1.4`) |
| **Dns Zones Subscription Id** | Your subscription ID |
| **Existing Dns Zones** | JSON mapping zone names → hub resource group name |

**`existingDnsZones` example:**
```json
{
  "privatelink.services.ai.azure.com": "foundry-hub-rg",
  "privatelink.openai.azure.com": "foundry-hub-rg",
  "privatelink.cognitiveservices.azure.com": "foundry-hub-rg",
  "privatelink.search.windows.net": "foundry-hub-rg",
  "privatelink.documents.azure.com": "foundry-hub-rg",
  "privatelink.blob.core.windows.net": "foundry-hub-rg",
  "privatelink.file.core.windows.net": "foundry-hub-rg"
}
```

#### Deploy via CLI (Alternative)

```bash
SPOKE_VNET_ID=$(az network vnet show -g foundry-spoke-rg -n spoke-vnet --query id -o tsv)

az deployment group create \
  --resource-group foundry-spoke-rg \
  --template-file ../bicep/main.bicep \
  --parameters ../bicep/main.bicepparam \
  --parameters \
    existingVnetResourceId="$SPOKE_VNET_ID" \
    firewallPrivateIp="10.0.1.4"
```

### Step 4: Post-Deployment Configuration

After Foundry deploys, complete these manual steps:

1. **Register resource providers** — `Microsoft.App`, `Microsoft.ContainerService` (see [Part 10](#part-10-resource-provider-registrations))

2. **Assign RBAC roles** (see [Part 9](#part-9-rbac-roles-required) for the full list)  
   Key assignments: AI Services MI + Project MI → `Storage Blob Data Contributor` on Storage, `Search Index Data Contributor` + `Search Service Contributor` on AI Search. AI Search MI → `Storage Blob Data Reader` on Storage, `Cognitive Services OpenAI Contributor` on AI Services.

3. **Create Shared Private Links** — AI Search needs 4 SPLs (see [Part 5](#part-5-shared-private-links-spls) for details):
   - `blob` → Storage Account (indexer reads blobs)
   - `foundry_account` → AI Services (Foundry control plane)
   - `openai_account` → AI Services (embedding models)
   - `cognitiveservices_account` → AI Services (cognitive skills)
   
   After creating, approve each pending PE connection on the target resource.

4. **Set indexer execution to Private** — required when using SPLs:
   ```bash
   SEARCH_KEY=$(az search admin-key show --service-name <name> -g <rg> --query primaryKey -o tsv)
   curl -X PUT "https://<name>.search.windows.net/indexers/<indexer>?api-version=2024-07-01" \
     -H "Content-Type: application/json" -H "api-key: $SEARCH_KEY" \
     -d '{"name":"<indexer>","dataSourceName":"<ds>","targetIndexName":"<idx>","parameters":{"configuration":{"executionEnvironment":"Private"}}}'
   ```

5. **Enable API key auth** on AI Services (portal limitation for knowledge source creation):
   ```bash
   az rest --method PATCH \
     --url "https://management.azure.com/<ai-services-resource-id>?api-version=2024-10-01" \
     --body '{"properties":{"disableLocalAuth":false}}'
   ```

6. **Enable semantic search** on AI Search:
   ```bash
   az rest --method PATCH \
     --url "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Search/searchServices/<name>?api-version=2024-06-01-preview" \
     --body '{"properties":{"semanticSearch":"free"}}'
   ```

### Step 5: Verify from Test VM

Connect to the test VM via Bastion and verify DNS resolves to private IPs:

```bash
nslookup <ai-services-name>.cognitiveservices.azure.com
# Should resolve to 10.100.4.x (pe-subnet)

nslookup <storage-name>.blob.core.windows.net
# Should resolve to 10.100.4.x

nslookup <cosmos-name>.documents.azure.com
# Should resolve to 10.100.4.x
```

Verify traffic routes through the firewall:
```bash
curl -s ifconfig.me
# Should return the firewall's public IP
```

### Firewall Rules Reference

We tested Foundry behind a **deny-all** firewall and discovered the minimum FQDNs that must be allowed. These rules are split by purpose — start with the required ones and add optional rules as needed.

> **Official reference:** For the full Container Apps firewall requirements, see [Integrate Azure Container Apps with Azure Firewall — Application Rules](https://learn.microsoft.com/en-us/azure/container-apps/use-azure-firewall#application-rules)

#### Required: Agent Service Infrastructure

These FQDNs are the **minimum** needed for the Foundry Agent Service (Container Apps) to start and run:

| Protocol | FQDNs | Purpose |
|----------|-------|---------|
| UDP/53 | `*` | DNS resolution (required for all private endpoint lookups) |
| HTTPS/443 | `mcr.microsoft.com`, `*.data.mcr.microsoft.com` | Microsoft Container Registry — agent runtime image pulls |
| HTTPS/443 | `*.login.microsoft.com`, `login.microsoftonline.com`, `*.login.microsoftonline.com` | Entra ID authentication |
| HTTPS/443 | `*.identity.azure.net` | Managed identity token acquisition |

#### Required: Foundry Evaluation

Without these, Foundry evaluation jobs will fail:

| Protocol | FQDNs | Purpose |
|----------|-------|---------|
| HTTPS/443 | `*.azureml.ms` | Azure ML evaluation backend |
| HTTPS/443 | `*.blob.core.windows.net` | Evaluation data storage |
| HTTPS/443 | `raw.githubusercontent.com` | Evaluation prompt templates |

#### Optional: Application Insights

Only needed if you want Application Insights telemetry from your agents:

| Protocol | FQDNs | Purpose |
|----------|-------|---------|
| HTTPS/443 | `settings.sdk.monitor.azure.com` | App Insights SDK configuration |

#### Additional for SharePoint Sync (Part 14)

| Protocol | FQDNs | Purpose |
|----------|-------|---------|
| HTTPS/443 | `graph.microsoft.com`, `login.microsoftonline.com`, `*.sharepoint.com` | Graph API for file sync + SharePoint REST |

> **Tip:** If you see blocked traffic in the firewall logs, query Log Analytics:
> ```kql
> AZFWApplicationRule | where Action == "Deny" | project TimeGenerated, Fqdn, SourceIp
> AZFWNetworkRule | where Action == "Deny" | project TimeGenerated, DestinationIp, DestinationPort
> ```

### What Template 15 Creates

| Resource | Purpose | Public Access |
|----------|---------|---------------|
| AI Foundry (Cognitive Services) | Orchestration + model hosting (GPT-4.1) | **Disabled** |
| Azure AI Search | Vector store for agent knowledge | **Disabled** |
| Azure Storage (Blob + Files) | File storage for agent configs/uploads | **Disabled** |
| Azure Cosmos DB (NoSQL) | Thread/conversation storage | **Disabled** |
| Private Endpoints (6) | Secure connectivity to all PaaS services | N/A |
| Subnet delegation | `agent-subnet` delegated to `Microsoft.App/environments` | N/A |

### What You Get After Steps 1–5

At this point you have a **fully private Foundry agent** that can:
- Deploy and run agents (GPT-4.1) in a private VNet
- Use RAG on files uploaded to the private Blob storage
- All traffic inspected by Azure Firewall
- Zero public internet exposure on any PaaS service

---

## Part 14: SharePoint Online Integration — Secure Sync with Foundry IQ

> **Credit:** The SharePoint sync solution is based on [sharepoint-foundryIQ-secure-sync](https://github.com/Azure-Samples/sharepoint-foundryIQ-secure-sync) by **[Sidali Kadouche](https://github.com/sidkadouc)** ([@sidkadouc](https://github.com/sidkadouc)). We adapted it to run within our hub-spoke private network.

### Why Add SharePoint?

After completing Part 13, your Foundry agent can do RAG on files you manually upload to Blob storage. But in most enterprises, the documents live in **SharePoint Online** — not in Azure Blob.

The SharePoint sync pipeline bridges this gap:

```
SharePoint Online                     Hub-Spoke Network
┌──────────────┐    Graph API    ┌──────────────────────────────────────────────┐
│              │    (via FW)     │  Spoke VNet                                  │
│  Documents   │ ──────────────►│  ┌──────────────┐    ┌──────────────────┐    │
│  Permissions │                │  │ Azure Func   │───►│ Blob Storage     │    │
│  Labels      │                │  │ (func-subnet)│    │ (PE, existing)   │    │
│              │                │  └──────────────┘    └────────┬─────────┘    │
└──────────────┘                │                               │              │
                                │                        Shared Private Link   │
                                │                               │              │
                                │                     ┌─────────▼──────────┐   │
                                │                     │ AI Search          │   │
                                │                     │ (indexer, private)  │   │
                                │                     └─────────┬──────────┘   │
                                │                               │              │
                                │                     ┌─────────▼──────────┐   │
                                │                     │ Foundry Agent      │   │
                                │                     │ (grounded answers) │   │
                                │                     └────────────────────┘   │
                                └──────────────────────────────────────────────┘
```

### What the Pipeline Does

1. **Syncs files** from SharePoint to Azure Blob Storage (with metadata and permissions)
2. **Extracts SharePoint ACLs** — per-document access control lists
3. **Indexes content** in Azure AI Search with OCR, chunking, and optional vector embeddings
4. **Enables secure RAG** — Foundry agents search SharePoint content with permission enforcement
5. (Optional) **Purview integration** — dual-layer ACLs: SharePoint permissions ∩ Purview RMS

### Prerequisites

Before deploying, you need:

1. **Hub + Spoke + Foundry deployed** (Steps 1–3 from Part 13)
2. **App Registration (SPN)** in Entra ID with:
   - `Sites.Read.All` or `Sites.Selected` (Graph API application permission)
   - `Files.Read.All` (Graph API application permission)
   - A client secret generated
3. **Azure Functions Core Tools** installed: `npm i -g azure-functions-core-tools@4`

### Deploy the SharePoint Sync Layer

```bash
cd deployment
cp sharepoint-sync.env.example sharepoint-sync.env   # Fill in your values
./3-deploy-sharepoint-sync.sh
```

### What It Deploys

| Resource | Purpose | Network |
|----------|---------|---------|
| `func-subnet` (`10.100.6.0/24`) | Function App VNet integration | UDR → Firewall |
| Azure Function App (Elastic Premium, Python) | Runs the sync code on a schedule | VNet-integrated, managed identity |
| Function Storage Account | Function App internal storage | Private (blob + file PEs) |
| Key Vault | Stores SPN secrets + AI Search key | Private (PE), RBAC-enabled |
| Blob Container (`sharepoint-sync`) | Synced SharePoint files with metadata | In existing Foundry storage |
| AI Search Index | `sharepoint-index` with permission fields | Existing AI Search service |
| AI Search Indexer | Hourly, private execution environment | Via Shared Private Link |
| Shared Private Link | AI Search → Storage (blob) | Managed PE from Search |
| Firewall Rule | `AllowSharePointSync` | `*.sharepoint.com`, `graph.microsoft.com` |

### How Secrets Are Handled

The deployment uses **Key Vault references** — secrets are never stored as plain text in Function App settings:

```
Function App Setting                 → Key Vault Secret
─────────────────────────────────────────────────────────
AZURE_TENANT_ID                      → @Microsoft.KeyVault(SecretUri=.../sp-tenant-id)
AZURE_CLIENT_ID                      → @Microsoft.KeyVault(SecretUri=.../sp-client-id)
AZURE_CLIENT_SECRET                  → @Microsoft.KeyVault(SecretUri=.../sp-client-secret)
SEARCH_API_KEY                       → @Microsoft.KeyVault(SecretUri=.../search-api-key)
```

The Function App's managed identity has `Key Vault Secrets User` role — it can read secrets but not modify them.

### Data Flow

```
1. Timer trigger (hourly) or manual invoke
2. Function App → Graph API (via firewall: *.sharepoint.com, graph.microsoft.com)
3. Downloads files + extracts permissions + sensitivity labels
4. Writes to Blob Storage (via private endpoint)
5. AI Search indexer (hourly, private execution) picks up new/changed blobs
6. Foundry Agent queries AI Search → returns answers grounded in SharePoint docs
```

### Post-Deployment Steps

1. **Approve the Shared Private Link** (if auto-approve failed):
   Portal → Storage Account → Networking → Private endpoint connections → Approve

2. **Trigger initial sync** — run the Function manually from the Azure Portal

3. **Verify the indexer** runs successfully:
   ```bash
   # Temporarily enable AI Search public access to check
   az search service update --name <search-name> -g <rg> --public-access enabled
   SEARCH_KEY=$(az search admin-key show --service-name <search-name> -g <rg> --query primaryKey -o tsv)
   curl -s "https://<search-name>.search.windows.net/indexers/<indexer-name>/status?api-version=2024-07-01" \
     -H "api-key: $SEARCH_KEY" | python3 -m json.tool
   # Lock down again
   az search service update --name <search-name> -g <rg> --public-access disabled
   ```

4. **Create a Knowledge Source in Foundry** — connect the `sharepoint-index` to your agent for grounded answers

### Troubleshooting

| Issue | Cause | Fix |
|-------|-------|-----|
| Function App can't reach Graph API | Firewall blocking | Check `AllowSharePointSync` rule exists, source IP range matches spoke VNet |
| Indexer fails: "Unable to retrieve blob container" | SPL not approved or MI missing RBAC | Approve SPL on Storage → Networking. Grant AI Search MI `Storage Blob Data Reader` on Storage |
| Key Vault secret resolution fails (Function 500s) | KV PE not registered in DNS, or RBAC delay | Check DNS zone link. Wait 5 min for RBAC propagation |
| Indexer status shows `transientFailure` | Not using private execution environment | Set `"executionEnvironment": "private"` on the indexer |

---

## License

This project is licensed under the terms specified in the LICENSE file.
