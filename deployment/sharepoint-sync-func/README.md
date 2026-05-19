# SharePoint Sync Job (.NET 10 isolated worker)

.NET 10 Azure Functions job that syncs files from a SharePoint document library to
Azure Blob Storage using the Microsoft Graph delta API. Optionally exports
SharePoint permissions as blob metadata for downstream ACL filtering, and
integrates with Microsoft Purview to detect sensitivity labels and RMS
encryption for dual-layer document security.

This is a port of the original Python implementation. Behavior, configuration
surface, blob metadata keys, and deploy contracts are identical — only the
runtime is .NET. See [`UPSTREAM.md`](UPSTREAM.md) for the file mapping.

## Features

- **Delta (incremental) sync**: only downloads files changed since the last run
- **Delta token persistence**: stores the Graph delta token in blob storage
- **Delete detection**: removes blobs for files deleted in SharePoint
- **Permission sync**: exports SharePoint ACLs as blob metadata (`user_ids`, `group_ids`)
- **Purview sensitivity labels**: detects labels applied to files and extracts RMS usage rights
- **Dual-layer ACL merge**: computes effective access = SharePoint permissions ∩ RMS permissions
- **Encrypted file handling**: gracefully handles RMS-encrypted files that cannot be downloaded
- **Full sync fallback**: set `FORCE_FULL_SYNC=true` to bypass delta
- **Dry run mode**: preview changes without modifications

## How Delta Sync Works

```
First Run:
  GET /drives/{id}/root/delta -> returns ALL items + deltaLink token
  -> Upload all files, save token to .sync-state/delta-token.json

Subsequent Runs:
  GET {deltaLink} -> returns ONLY changed items since last token
  -> Process creates/updates/deletes, save new token
  -> Always re-sync permissions (delta doesn't track permission changes)
```

| Change | Delta Reports It? | Action |
|--------|-------------------|--------|
| File created/modified | Yes | Download & upload |
| File renamed/moved | Yes | Upload to new path |
| File deleted | Yes | Delete blob |
| **Permission changed** | **No** | Always fully re-synced |

## Purview Sensitivity Labels and RMS Protection

When `SYNC_PURVIEW_PROTECTION=true`, the sync pipeline adds a second security layer
by integrating with Microsoft Purview. For each file, the pipeline:

1. Reads the sensitivity label via Microsoft Graph (`sensitivityLabel` on the driveItem)
2. Detects RMS encryption and determines if the label enforces content protection
3. Extracts RMS usage rights (VIEW, EDIT, EXPORT, etc.) and the identities they apply to
4. Computes the dual-layer ACL: `effective_access = SharePoint_permissions ∩ RMS_permissions`
5. Writes Purview metadata to blob storage alongside the document

A user must appear in **both** sets to see the document in search results.

| Status | Meaning |
|--------|---------|
| `unprotected` | No sensitivity label, or label without encryption. SP permissions only. |
| `label_only` | Has a sensitivity label but no RMS encryption. SP permissions only. |
| `protected` | Has a sensitivity label with RMS encryption. Dual-layer ACL applies. |
| `unknown` | Could not determine protection status (API error). Falls back to SP permissions. |

| Metadata key | Example value |
|-------------|---------------|
| `purview_protection_status` | `protected` |
| `purview_label_id` | `a1b2c3d4-...` |
| `purview_label_name` | `Highly Confidential` |
| `purview_is_encrypted` | `true` |
| `purview_rms_permissions` | JSON array of permission entries |
| `purview_detected_at` | `2026-04-27T10:30:00Z` |

Files with RMS encryption that cannot be downloaded with the configured permissions
will receive a placeholder blob with `rms_download_blocked=true` in metadata. ACLs
and Purview metadata are still synced so AI Search trimming stays accurate.

| Permission | Type | Purpose |
|-----------|------|---------|
| `Files.Read.All` | Application | Read files and sensitivity labels on items |
| `InformationProtectionPolicy.Read.All` | Application | Read label definitions and RMS policies |

## Files

| File | Description |
|------|-------------|
| `Program.cs` | DI bootstrap for the isolated worker |
| `host.json` | Azure Functions host configuration |
| `Configuration/SyncConfig.cs` | Configuration loaded from environment variables |
| `Models/` | DTOs (SharePoint files, blobs, permissions, Purview) |
| `Clients/SharePointClient.cs` | Microsoft Graph client (sites, drives, delta) |
| `Clients/GraphDeltaFilesClient.cs` | File-change delta client |
| `Clients/GraphDeltaPermissionsClient.cs` | Permission-change delta client |
| `Clients/BlobStorageClient.cs` | Azure Blob Storage client |
| `Clients/PermissionsClient.cs` | SharePoint permission export |
| `Clients/PurviewClient.cs` | Purview sensitivity labels + RMS rights extraction |
| `Clients/CredentialFactory.cs` | Builds the right Azure credential per service |
| `Services/SyncOrchestrator.cs` | Top-level orchestrator (delta/full + permissions/Purview) |
| `Functions/SharePointSyncTimerFunction.cs` | Hourly delta-sync timer trigger |
| `Functions/SharePointSyncFullTimerFunction.cs` | Daily full-reconcile timer trigger |
| `Functions/SyncUiFunction.cs` | HTTP UI / on-demand trigger |
| `Dockerfile` | Container build file |
| `SharePointSyncFunc.csproj` | .NET project file |
| `deploy/` | Azure Function + ACA Job deployment scripts ([README](deploy/README.md)) |

## Local development

```bash
# Restore + build
dotnet build

# Copy the example settings file and edit values
cp local.settings.json.example local.settings.json

# Run the Functions host
func start
```

## Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `SHAREPOINT_SITE_URL` | Yes | (required) | e.g. `https://contoso.sharepoint.com/sites/MySite` |
| `SHAREPOINT_DRIVE_NAME` | No | `Documents` | Document library name |
| `SHAREPOINT_FOLDER_PATH` | No | `/` | Folder path(s), comma-separated |
| `SHAREPOINT_INCLUDE_EXTENSIONS` | No | (empty) | Only sync these extensions |
| `SHAREPOINT_EXCLUDE_EXTENSIONS` | No | (empty) | Skip these extensions |
| `AZURE_STORAGE_ACCOUNT_NAME` | Yes | (required) | Storage account name |
| `AZURE_BLOB_CONTAINER_NAME` | No | `sharepoint-sync` | Container name |
| `AZURE_BLOB_PREFIX` | No | (empty) | Prefix for all blobs |
| `DELETE_ORPHANED_BLOBS` | No | `false` | Delete blobs removed from SharePoint |
| `SOFT_DELETE_ORPHANED_BLOBS` | No | `true` | Soft-delete via metadata instead of hard-delete |
| `DRY_RUN` | No | `false` | Preview without changes |
| `SYNC_PERMISSIONS` | No | `false` | Export SharePoint permissions to blob metadata |
| `SYNC_PURVIEW_PROTECTION` | No | `false` | Enable Purview sensitivity label and RMS protection sync |
| `PERMISSIONS_DELTA_MODE` | No | `hash` | `hash` or `graph_delta` |
| `DELTA_TOKEN_STORAGE_PATH` | No | `.delta_tokens` | Delta token directory (graph_delta mode) |
| `FORCE_FULL_SYNC` | No | `false` | Skip delta, do full re-scan |
| `TIMER_SCHEDULE` | No | host.json | Cron for hourly delta timer |
| `TIMER_SCHEDULE_FULL` | No | host.json | Cron for daily full-sync timer |

## Authentication

Credentials are resolved per service:

- **SharePoint (Graph API)**: Uses `ClientSecretCredential` when `AZURE_CLIENT_ID` / `AZURE_CLIENT_SECRET` / `AZURE_TENANT_ID` are set, otherwise `DefaultAzureCredential`.
- **Blob Storage**: Uses `ManagedIdentityCredential` when running in Azure (detected via `IDENTITY_ENDPOINT`), `AzureCliCredential` locally, or explicit storage credentials via `AZURE_STORAGE_CLIENT_ID` / `AZURE_STORAGE_CLIENT_SECRET` / `AZURE_STORAGE_TENANT_ID`.

This separation ensures the SharePoint app registration credentials don't interfere with storage RBAC.

## Docker

```bash
docker build -t sharepoint-sync:latest .
docker run --env-file .env sharepoint-sync:latest
```

## Run as Cloud Job

The same code runs as:

- **Azure Function** (timer trigger): see [deploy/README.md](deploy/README.md)
- **Azure Container Apps Job** (scheduled/manual)

Deploy scripts:

| Script | Purpose |
|--------|---------|
| `deploy/deploy-new.sh` | Create new test resources |
| `deploy/deploy-existing.sh` | Deploy code to existing resources |

## Delta Token

Stored at `.sync-state/delta-token.json` in the blob container. Delete it or set `FORCE_FULL_SYNC=true` to force a full re-crawl.
