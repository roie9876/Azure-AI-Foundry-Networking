# Upstream source

This folder originated from a vendored copy of the Microsoft sample repo and
has since been **rewritten in .NET 10 (Azure Functions isolated worker)**. The
behavior, configuration surface, and external contracts (env vars, blob
metadata keys, host.json schedules, deploy scripts) are kept identical to the
upstream Python version.

- **Original source:** https://github.com/Azure-Samples/sharepoint-foundryIQ-secure-sync
- **Path in upstream:** `src/sync/`
- **Originally vendored at commit:** `2afa0beed107671e1fc4c39afb4ccfda5ae8c1dd`
- **Upstream commit date:** 2026-04-07 16:11:40 +0200
- **Originally vendored on:** 2026-04-17T12:44:20Z
- **Ported to .NET on:** 2026-04-27

## Why vendored?

- Deploy must not depend on upstream being available (repo deletion, privacy change, network outage).
- Local patches (extra triggers, filter fixes) and the .NET port live alongside the original logic.

## Mapping Python -> .NET

| Python file | .NET equivalent |
|-------------|-----------------|
| `config.py` | `Configuration/SyncConfig.cs` |
| `sharepoint_client.py` | `Clients/SharePointClient.cs`, `Clients/GraphDeltaFilesClient.cs`, `Clients/DeltaTokenStorage.cs` |
| `blob_client.py` | `Clients/BlobStorageClient.cs` |
| `permissions_sync.py` | `Clients/PermissionsClient.cs`, `Clients/GraphDeltaPermissionsClient.cs`, `Models/PermissionsModels.cs` |
| `purview_client.py` | `Clients/PurviewClient.cs`, `Models/PurviewModels.cs` |
| `main.py` | `Services/SyncOrchestrator.cs` |
| `sharepoint_sync_timer/` | `Functions/SharePointSyncTimerFunction.cs` |
| `sharepoint_sync_full_timer/` | `Functions/SharePointSyncFullTimerFunction.cs` |
| `sync_ui/` | `Functions/SyncUiFunction.cs` |

## Local modifications vs. upstream

Tracked in git history. To see diffs:

```bash
git log --follow deployment/sharepoint-sync-func/
```
