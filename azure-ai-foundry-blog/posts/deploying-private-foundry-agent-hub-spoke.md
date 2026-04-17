# Deploying a Private AI Foundry Agent in a Hub-Spoke Network

> A step-by-step walkthrough of deploying Azure AI Foundry Agent Service with full network isolation in an existing hub-spoke topology with Azure Firewall.

---

## Why This Guide?

Microsoft provides a [Bicep template for private network agent setup](https://github.com/microsoft-foundry/foundry-samples/tree/main/infrastructure/infrastructure-setup-bicep/15-private-network-standard-agent-setup) — but the docs assume you're starting from scratch. In reality, most enterprises already have a **hub-spoke network** with Azure Firewall, DNS infrastructure, and routing in place.

This guide shows how to deploy the Foundry private agent into that **existing** topology — bringing your own VNet, subnets, DNS zones, and firewall routing.

### Which Bicep Template Are We Using?

The [foundry-samples](https://github.com/microsoft-foundry/foundry-samples) repo contains **15+ infrastructure templates** under `infrastructure/infrastructure-setup-bicep/`. Here's what makes template **#15** special:

| Template | Use Case |
|----------|----------|
| `01-basic-setup` | Simplest — public network, no isolation |
| `05-managed-network-*` | Microsoft-managed VNet (you don't control the network) |
| `10-serverless-*` | Serverless compute, less control |
| **`15-private-network-standard-agent-setup`** | **Full BYO VNet with subnet delegation, private endpoints, RBAC — the enterprise choice** |

**Template 15** is the right choice when you need:
- Full control over networking (BYO VNet)
- Private endpoints for all PaaS services
- Subnet delegation for Agent compute (Microsoft.App/environments)
- Integration with existing hub-spoke + Azure Firewall
- All public endpoints disabled

---

## Architecture Overview

![Hub-Spoke Architecture](../images/hub-spoke-foundry-private.drawio)

### Network Topology

```
┌─────────────────────────┐         VNet Peering         ┌──────────────────────────────────────┐
│   Hub VNet              │◄────────────────────────────►│   Spoke VNet (foundry-vnet)           │
│   10.0.0.0/16           │                              │   10.100.0.0/16                       │
│                         │                              │                                        │
│  ┌───────────────────┐  │                              │  ┌──────────────┐ ┌──────────────────┐│
│  │ AzureFirewallSubnet│  │                              │  │ Bastion      │ │ test-vm subnet   ││
│  │ Azure Firewall     │  │                              │  │ 10.100.1.0/26│ │ 10.100.2.0/24    ││
│  │ 10.0.0.4          │  │                              │  │ (Azure       │ │ (foundry-vm)     ││
│  └───────────────────┘  │                              │  │  Bastion)    │ │                  ││
│                         │                              │  └──────────────┘ └──────────────────┘│
│  UDR: 0.0.0.0/0 →      │                              │                                        │
│        10.0.0.4         │                              │  ┌──────────────────────────────────┐  │
└─────────────────────────┘                              │  │ agent-subnet  10.100.3.0/24      │  │
                                                         │  │ (delegated: Microsoft.App/envs)  │  │
                 ┌─────┐                                 │  │ AI Agent Service compute         │  │
                 │ ☁️  │                                 │  └──────────────────────────────────┘  │
                 │ Net │                                 │                                        │
                 └─────┘                                 │  ┌──────────────────────────────────┐  │
                                                         │  │ pe-subnet  10.100.4.0/24         │  │
                                                         │  │ Private Endpoints:               │  │
                                                         │  │  • AI Foundry  • AI Search       │  │
                                                         │  │  • Storage     • Cosmos DB       │  │
                                                         │  │  • Blob        • File            │  │
                                                         │  └──────────────────────────────────┘  │
                                                         └──────────────────────────────────────┘
```

### What Gets Deployed

The Bicep template creates these resources (all with **public access disabled**):

| Resource | Purpose | Private Endpoint Zone |
|----------|---------|----------------------|
| **AI Foundry** (Cognitive Services) | Central orchestration, model hosting | `privatelink.cognitiveservices.azure.com`, `privatelink.openai.azure.com`, `privatelink.services.ai.azure.com` |
| **Azure AI Search** | Vector store for agent knowledge | `privatelink.search.windows.net` |
| **Azure Storage** | File storage (agent configs, uploads) | `privatelink.blob.core.windows.net`, `privatelink.file.core.windows.net` |
| **Azure Cosmos DB** | Thread/conversation storage | `privatelink.documents.azure.com` |
| **GPT-4.1 Model** | GlobalStandard deployment, capacity 30 | (via AI Foundry endpoint) |

---

## Prerequisites

Before deploying, you need:

1. **Hub-spoke network** already deployed with:
   - Hub VNet with Azure Firewall
   - Spoke VNet peered to hub
   - UDR routing `0.0.0.0/0` → Azure Firewall
   - Azure Bastion + test VM for private access

2. **Resource providers registered**:
   ```bash
   az provider register --namespace Microsoft.App
   az provider register --namespace Microsoft.ContainerService
   az provider register --namespace Microsoft.CognitiveServices
   az provider register --namespace Microsoft.Search
   az provider register --namespace Microsoft.Storage
   ```

3. **Two available subnets** in the spoke VNet (the template can create them):
   - `agent-subnet` (`10.100.3.0/24`) — will be delegated to `Microsoft.App/environments`
   - `pe-subnet` (`10.100.4.0/24`) — hosts private endpoints

4. **Seven private DNS zones** created and linked to the spoke VNet:
   - `privatelink.cognitiveservices.azure.com`
   - `privatelink.openai.azure.com`
   - `privatelink.services.ai.azure.com`
   - `privatelink.search.windows.net`
   - `privatelink.documents.azure.com`
   - `privatelink.blob.core.windows.net`
   - `privatelink.file.core.windows.net`

---

## Step-by-Step Deployment

### Step 1: Create DNS Zones

If your hub-spoke doesn't already have the required private DNS zones, create them:

```bash
RG="foundry-private"
VNET_ID="/subscriptions/<sub-id>/resourceGroups/$RG/providers/Microsoft.Network/virtualNetworks/foundry-vnet"

ZONES=(
  "privatelink.cognitiveservices.azure.com"
  "privatelink.openai.azure.com"
  "privatelink.services.ai.azure.com"
  "privatelink.search.windows.net"
  "privatelink.documents.azure.com"
  "privatelink.blob.core.windows.net"
  "privatelink.file.core.windows.net"
)

for zone in "${ZONES[@]}"; do
  az network private-dns zone create -g $RG -n "$zone"
  az network private-dns link vnet create -g $RG -n "${zone}-link" \
    --zone-name "$zone" --virtual-network "$VNET_ID" --registration-enabled false
done
```

### Step 2: Deploy via Azure Portal

Click the **"Deploy to Azure"** button from the [template README](https://github.com/microsoft-foundry/foundry-samples/tree/main/infrastructure/infrastructure-setup-bicep/15-private-network-standard-agent-setup).

Fill in the parameters:

![Bicep Deployment Parameters](../bicp-scresnshots.jpeg)

| Parameter | Value |
|-----------|-------|
| **First Project Name** | `project` |
| **Display Name** | `network secured agent project` |
| **Vnet Name** | `foundry-vnet` |
| **Agent Subnet Name** | `agent-subnet` |
| **Pe Subnet Name** | `pe-subnet` |
| **Existing Vnet Resource Id** | `/subscriptions/<sub-id>/resourceGroups/foundry-private/providers/Microsoft.Network/virtualNetworks/foundry-vnet` |
| **Vnet Address Prefix** | `10.100.0.0/16` |
| **Agent Subnet Prefix** | `10.100.3.0/24` |
| **Pe Subnet Prefix** | `10.100.4.0/24` |
| **Ai Search / Storage / Cosmos** | _(leave empty — template creates new ones)_ |
| **Dns Zones Subscription Id** | Your subscription ID |
| **Existing Dns Zones** | JSON with zone names → **resource group name** (see below) |
| **Project Cap Host** | `caphostproj` |

**Existing DNS Zones value** (JSON — map zone names to the **resource group name** where each zone lives, NOT full resource IDs):
```json
{
  "privatelink.services.ai.azure.com": "foundry-private",
  "privatelink.openai.azure.com": "foundry-private",
  "privatelink.cognitiveservices.azure.com": "foundry-private",
  "privatelink.search.windows.net": "foundry-private",
  "privatelink.documents.azure.com": "foundry-private",
  "privatelink.blob.core.windows.net": "foundry-private",
  "privatelink.file.core.windows.net": "foundry-private"
}
```

> Leave a zone value empty (`""`) to let the template create a new zone for that service.

### Step 3: Troubleshooting Common Deployment Errors

#### Error: "Subscription not registered with Microsoft.App / Microsoft.ContainerService"

The agent subnet delegation requires these providers. Register them:

```bash
az provider register --namespace Microsoft.App
az provider register --namespace Microsoft.ContainerService
```

Wait until both show `Registered`:

```bash
az provider show -n Microsoft.App --query registrationState -o tsv
az provider show -n Microsoft.ContainerService --query registrationState -o tsv
```

#### Error: "AccountIsNotSucceeded — Current state: Failed"

If a previous deployment attempt left the AI Services account in a `Failed` state, ARM can't update it. Delete and purge:

```bash
az cognitiveservices account delete \
  --name <account-name> \
  --resource-group foundry-private

az cognitiveservices account purge \
  --name <account-name> \
  --resource-group foundry-private \
  --location swedencentral
```

Then redeploy.

### Step 4: Attach UDR to New Subnets

After deployment succeeds, the new subnets (`agent-subnet`, `pe-subnet`) don't have the UDR attached. Without this, traffic from these subnets bypasses Azure Firewall:

```bash
az network vnet subnet update \
  --resource-group foundry-private \
  --vnet-name foundry-vnet \
  --name agent-subnet \
  --route-table udr-foundry-private

az network vnet subnet update \
  --resource-group foundry-private \
  --vnet-name foundry-vnet \
  --name pe-subnet \
  --route-table udr-foundry-private
```

### Step 5: Verify Connectivity

Connect to `foundry-vm` via Azure Bastion, then verify DNS resolution for the private endpoints:

```bash
# From the test VM
nslookup <ai-services-name>.cognitiveservices.azure.com
# Should resolve to a 10.100.4.x address (pe-subnet)

nslookup <storage-name>.blob.core.windows.net
# Should resolve to a 10.100.4.x address

nslookup <cosmos-name>.documents.azure.com
# Should resolve to a 10.100.4.x address
```

If DNS resolves to private IPs, your private endpoints are working correctly.

---

## How It All Fits Together

1. **User** connects to `foundry-vm` via **Azure Bastion** (no public IP on the VM)
2. From the VM, the user accesses the **AI Foundry portal** — DNS resolves via **private DNS zones** to **private endpoints** in `pe-subnet`
3. The **AI Agent Service** runs in `agent-subnet` (delegated to Microsoft.App) — it communicates with Storage, Cosmos DB, and AI Search through **private endpoints**
4. **All outbound traffic** from the spoke VNet is routed through **Azure Firewall** in the hub via the **UDR**
5. **No public endpoints** are exposed — all PaaS services have public access disabled

---

## Key Takeaways

- **Template 15** is the enterprise-grade option for Foundry agent isolation
- **BYO VNet** means you keep full control of networking, routing, and DNS
- **Subnet delegation** (`Microsoft.App/environments`) is how the agent compute gets injected into your VNet
- **Private DNS zones must exist before deployment** and be linked to your VNet
- **Register Microsoft.App and Microsoft.ContainerService** providers before deploying
- **Attach UDR** to new subnets post-deployment to ensure traffic flows through your firewall

---

## Part 2: SharePoint Sync Pipeline & Agent with Citations

After the base hub-spoke + Foundry deployment, you can add a **SharePoint → AI Search → Foundry Agent** pipeline that:
1. Syncs SharePoint documents to Azure Blob Storage (via an Azure Function)
2. Indexes blobs into AI Search with vector embeddings, OCR, and chunking
3. Configures a Foundry agent with the **Azure AI Search tool** for grounded answers with **clickable SharePoint citations**

### Architecture

```
SharePoint Online
      │
      ▼ (Graph API via Azure Firewall)
Azure Function App (VNet-integrated, Elastic Premium)
      │
      ▼ (Private Endpoint)
Azure Blob Storage (sharepoint-sync container)
      │
      ▼ (Shared Private Link)
Azure AI Search Indexer (private execution)
  • OCR → merge → chunk → embed (Azure OpenAI)
  • Field: 'url' mapped from blob metadata 'sharepoint_web_url'
      │
      ▼
Foundry Agent (azure_ai_search tool)
  • Queries sharepoint-index directly
  • Returns answers with url_citation annotations → SharePoint URLs
```

### Why Azure AI Search Tool Instead of Knowledge Base MCP?

The Foundry Knowledge Base (Foundry IQ) exposes an MCP endpoint that agents can query. However, there's a key limitation for citation URLs:

| Aspect | Knowledge Base MCP | Azure AI Search Tool |
|--------|-------------------|---------------------|
| **Tool results** | Only `ref_id`, `title`, `content` | All retrievable index fields including `url` |
| **sourceDataFields config** | Accepted but doesn't affect MCP output | N/A — reads directly from index |
| **Citation links** | Always point to the MCP endpoint URL | Native `url_citation` with document-level URLs |
| **Setup** | Knowledge base + knowledge source + MCP tool | Project connection + tool config |

The `azure_ai_search` tool reads directly from your search index, so the `url` field (populated with SharePoint document URLs during sync) is available to the LLM and used in citation annotations.

### Deploying the Pipeline

```bash
# 1. Copy and configure the env file
cp deployment/sharepoint-sync.env.example deployment/sharepoint-sync.env
# Edit: subscription, SPN credentials, SharePoint site, Foundry project name

# 2. Run the deployment
./deployment/3-deploy-sharepoint-sync.sh
```

The script handles 14 steps end-to-end:

| Step | What It Does |
|------|-------------|
| 1 | Creates `func-subnet` with VNet integration delegation |
| 2 | Creates blob container for SharePoint sync |
| 3 | Creates Function App storage |
| 4 | Deploys Function App (Elastic Premium, Python, VNet-integrated) |
| 5 | Locks down Function App storage (private endpoints) |
| 6 | Deploys Key Vault (private) with SPN secrets |
| 7 | Configures Function App settings |
| 8 | RBAC: Function App → Storage |
| 9 | Shared Private Links: AI Search → Storage + AI Services |
| 10 | RBAC: AI Search → AI Services |
| 11 | Creates AI Search index, data source, skillset, indexer |
| 12 | Firewall rules for Graph API + SharePoint |
| 13 | Clones sync code and publishes to Function App |
| **14** | **Creates Foundry agent with `azure_ai_search` tool** |

### Step 14: Foundry Agent Configuration

Step 14 uses the Foundry Agents API (`2025-05-15-preview`) to create an agent version with the `azure_ai_search` tool:

```json
{
  "definition": {
    "kind": "prompt",
    "model": "gpt-4.1",
    "instructions": "Answer only from the knowledge-source...",
    "tools": [{
      "type": "azure_ai_search",
      "azure_ai_search": {
        "indexes": [{
          "project_connection_id": "/subscriptions/.../connections/aiservicesrzgnsearch",
          "index_name": "sharepoint-index",
          "query_type": "simple"
        }]
      }
    }]
  }
}
```

**Prerequisites for Step 14:**
- A **project connection** to your AI Search service must exist. The script looks for a connection named after your search service. If it doesn't exist, create it in the Foundry portal: **Project → Operate → Admin → Add connection → Azure AI Search**
- For private VNet setups, the connection **must use Microsoft Entra (keyless) authentication** — key-based auth is not supported with private networking

### How SharePoint URLs Flow Through the Pipeline

```
SharePoint file.pdf
    → web_url: https://contoso.sharepoint.com/sites/MySite/Shared Documents/file.pdf
    → Sync Function stores as blob metadata: sharepoint_web_url=<web_url>
    → AI Search indexer field mapping: sharepoint_web_url → url
    → Agent queries index, LLM sees url field in results
    → Response includes url_citation annotation with SharePoint URL
    → User clicks citation → opens SharePoint document
```

### Configuration Reference

Add these to `sharepoint-sync.env` for Step 14:

```bash
# Foundry Agent Configuration
AI_SERVICES_NAME=<your-ai-services-name>
FOUNDRY_PROJECT_NAME=<your-foundry-project-name>
FOUNDRY_AGENT_NAME=sharepoint-search-agent
FOUNDRY_AGENT_MODEL=gpt-4.1
```
