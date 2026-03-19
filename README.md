# Microsoft Foundry Networking

> **Updated March 2026** — Reflects the current Microsoft Foundry (formerly Azure AI Foundry) networking and security model.

This repository contains resources and documentation for Microsoft Foundry networking and security at enterprise scale, covering the full network isolation model for Foundry Account, Projects, and Agent Service.

## What's Covered

- **Foundry Account & Projects** — The new resource hierarchy (replacing Hub + Projects)
- **Agent Service Setup Tiers** — Basic, Standard, and Standard + BYO VNet configurations
- **Inbound Network Isolation** — Private endpoints, PNA flag, DNS configuration
- **Outbound Network Isolation** — VNet injection model with delegated agent subnets
- **Agent Tool Network Support** — Which tools work behind a VNet and their traffic paths
- **Hub-and-Spoke / Firewall** — Egress control with Azure Firewall
- **Hybrid Connectivity** — On-premises access via VPN, ExpressRoute, or Bastion
- **RBAC, DNS Zones, Troubleshooting** — Complete reference for enterprise deployments

## Architecture Overview

![Plan for Network Isolation](images/plan-network-isolation-diagram.png)

![VNet Injection Architecture](images/private-network-isolation.png)

For the full guide, see [azure-ai-foundry-networking.md](azure-ai-foundry-networking.md).

## Key References

- [Configure network isolation for Microsoft Foundry](https://learn.microsoft.com/en-us/azure/foundry/how-to/configure-private-link?view=foundry)
- [Set up your environment for Foundry Agent Service](https://learn.microsoft.com/en-us/azure/foundry/agents/environment-setup)
- [Set up standard agent resources](https://learn.microsoft.com/en-us/azure/foundry/agents/concepts/standard-agent-setup)
- [Set up private networking for Foundry Agent Service](https://learn.microsoft.com/en-us/azure/foundry/agents/how-to/virtual-networks)
- [Foundry Samples on GitHub](https://github.com/microsoft-foundry/foundry-samples)

## How to Contribute

1. Fork the repository.
2. Create a new branch for your feature or fix.
3. Make your changes and commit them with clear messages.
4. Push your changes to your forked repository.
5. Submit a pull request detailing your changes.

## License

This project is licensed under the terms specified in the LICENSE file.
