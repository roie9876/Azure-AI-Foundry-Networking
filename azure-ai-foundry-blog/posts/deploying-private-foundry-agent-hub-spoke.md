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
| **Existing Dns Zones** | JSON with zone names → resource IDs (see below) |
| **Project Cap Host** | `caphostproj` |

**Existing DNS Zones value** (JSON — map zone names to full resource IDs):
```json
{
  "privatelink.services.ai.azure.com": "/subscriptions/<sub-id>/resourceGroups/foundry-private/providers/Microsoft.Network/privateDnsZones/privatelink.services.ai.azure.com",
  "privatelink.openai.azure.com": "/subscriptions/<sub-id>/resourceGroups/foundry-private/providers/Microsoft.Network/privateDnsZones/privatelink.openai.azure.com",
  "privatelink.cognitiveservices.azure.com": "/subscriptions/<sub-id>/resourceGroups/foundry-private/providers/Microsoft.Network/privateDnsZones/privatelink.cognitiveservices.azure.com",
  "privatelink.search.windows.net": "/subscriptions/<sub-id>/resourceGroups/foundry-private/providers/Microsoft.Network/privateDnsZones/privatelink.search.windows.net",
  "privatelink.documents.azure.com": "/subscriptions/<sub-id>/resourceGroups/foundry-private/providers/Microsoft.Network/privateDnsZones/privatelink.documents.azure.com",
  "privatelink.blob.core.windows.net": "/subscriptions/<sub-id>/resourceGroups/foundry-private/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net",
  "privatelink.file.core.windows.net": "/subscriptions/<sub-id>/resourceGroups/foundry-private/providers/Microsoft.Network/privateDnsZones/privatelink.file.core.windows.net"
}
```

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
