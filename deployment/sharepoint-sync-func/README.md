# SharePoint Sync Job

Python job that syncs files from a SharePoint document library to Azure Blob Storage using the Microsoft Graph delta API. Optionally exports SharePoint permissions as blob metadata for downstream ACL filtering, and integrates with Microsoft Purview to detect sensitivity labels and RMS encryption for dual-layer document security.

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
  GET /drives/{id}/root/delta → returns ALL items + deltaLink token
  → Upload all files, save token to .sync-state/delta-token.json

Subsequent Runs:
  GET {deltaLink} → returns ONLY changed items since last token
  → Process creates/updates/deletes, save new token
  → Always re-sync permissions (delta doesn't track permission changes)
```

| Change | Delta Reports It? | Action |
|--------|-------------------|--------|
| File created/modified | Yes | Download & upload |
| File renamed/moved | Yes | Upload to new path |
| File deleted | Yes | Delete blob |
| **Permission changed** | **No** ¹ | Always fully re-synced |

> ¹ Permissions are always fully re-synced on every run. See [Why permissions are fully re-synced](#why-permissions-are-fully-re-synced) below for details.

## Purview Sensitivity Labels and RMS Protection

When `SYNC_PURVIEW_PROTECTION=true`, the sync pipeline adds a second security layer by integrating with Microsoft Purview. This is the feature that distinguishes this solution from native SharePoint indexing.

### What it does

For each file, the pipeline:

1. **Reads the sensitivity label** via Microsoft Graph (`sensitivityLabel` on the driveItem)
2. **Detects RMS encryption** and determines if the label enforces content protection
3. **Extracts RMS usage rights** (VIEW, EDIT, EXPORT, etc.) and the identities they apply to
4. **Computes the dual-layer ACL**: `effective_access = SharePoint_permissions ∩ RMS_permissions`
5. **Writes Purview metadata** to blob storage alongside the document

### How the dual-layer merge works

```
SharePoint permissions           RMS protection permissions
(who can access the folder)      (who the label grants content access to)
       |                                    |
       v                                    v
  SP user IDs: [Alice, Bob, Charlie]   RMS VIEW rights: [Alice, Bob]
       |                                    |
       +-------- INTERSECTION -------------+
                      |
                      v
            Effective ACL: [Alice, Bob]
            (written to blob metadata → propagated to AI Search)
```

A user must appear in **both** sets to see the document in search results. If a user has SharePoint access but is not listed in the RMS policy, their ID is **not** written to the blob metadata, and AI Search will never return that document for them. The same applies in reverse: RMS access alone without SharePoint access is also excluded.

### File protection statuses

| Status | Meaning |
|--------|---------|
| `unprotected` | No sensitivity label, or label without encryption. SP permissions only. |
| `label_only` | Has a sensitivity label but no RMS encryption. SP permissions only. |
| `protected` | Has a sensitivity label with RMS encryption. Dual-layer ACL applies. |
| `unknown` | Could not determine protection status (API error). Falls back to SP permissions. |

### Blob metadata written

| Metadata key | Example value |
|-------------|---------------|
| `purview_protection_status` | `protected` |
| `purview_label_id` | `a1b2c3d4-...` |
| `purview_label_name` | `Highly Confidential` |
| `purview_is_encrypted` | `true` |
| `purview_rms_permissions` | JSON array of permission entries |
| `purview_detected_at` | `2026-04-07T10:30:00Z` |

### Handling encrypted files

Files with RMS encryption may not be downloadable with `Sites.Read.All` or `Sites.Selected` permissions. When a download fails due to RMS restrictions, the pipeline:

1. Uploads a **placeholder blob** (empty content) so the file still exists in the index
2. Sets `rms_download_blocked=true` in blob metadata
3. **Still syncs all permissions and Purview metadata** so the ACLs are correct
4. Logs the file to `SyncStats.rms_download_failed` for operational tracking
5. Continues processing remaining files without interruption

To download encrypted files, add the RMS Super User role to your app registration. See [docs/purview-rms-explained.md](../../docs/purview-rms-explained.md) for details.

### Required app permissions for Purview

| Permission | Type | Purpose |
|-----------|------|---------|
| `Files.Read.All` | Application | Read files and sensitivity labels on items |
| `InformationProtectionPolicy.Read.All` | Application | Read label definitions and RMS policies |

These are in addition to the base `Sites.Read.All` or `Sites.Selected` permission needed for file and permission sync.

## Why Permissions Are Fully Re-synced

The Microsoft Graph **driveItem: delta** API _can_ detect permission changes, but
only when **all** of the following conditions are met:

1. The request includes the `Prefer` header:
   ```
   Prefer: deltashowremovedasdeleted, deltatraversepermissiongaps, deltashowsharingchanges
   ```
   Items whose permissions changed are then annotated with
   `"@microsoft.graph.sharedChanged": "True"` in the delta response.

2. The `Prefer: hierarchicalsharing` header is also added to get sharing info
   only for items with explicit sharing changes (not inherited).

3. The app registration holds **`Sites.FullControl.All`** application permission
   the docs state: _"In order to process permissions correctly your application
   will need to request Sites.FullControl.All permissions."_

**Our app uses `Sites.Read.All` (or the scoped `Sites.Selected` with read
role).** This is intentional: we follow the principle of least privilege and only
need read access to enumerate files and their permissions. Because we do not (and
should not) request `Sites.FullControl.All`, the delta-based permission change
tracking is **not available** to us.

### Current approach: full permission re-scan

On every sync run the job:
1. Uses the delta API to efficiently detect **file** content changes (adds, edits, deletes).
2. Lists **all** files in the library and re-fetches their permissions via
   `GET /drives/{driveId}/items/{itemId}/permissions`. This endpoint only
   requires `Files.Read.All` / `Sites.Read.All`.
3. Writes the permissions as blob metadata (`user_ids`, `group_ids`) so that
   downstream AI Search can apply ACL filters.

This is the **recommended approach** when you want to stay on `Sites.Read.All`:
- It is simple and correct: no permission change is ever missed.
- The per-file `/permissions` call is lightweight (small JSON, no file download).
- For libraries with a few hundred files the overhead is minimal (a few seconds).

### Alternative: delta-aware permission sync

If your library has **thousands of files** and permission changes are frequent,
you could switch to the delta-aware approach by:

1. Adding `Sites.FullControl.All` to the app registration.
2. Sending the three `Prefer` headers with the delta query.
3. Checking for `@microsoft.graph.sharedChanged` on each item and only
   re-fetching permissions for those items.

This trades a broader permission scope for reduced API calls.

### References

- [driveItem: delta - Scanning permissions hierarchies](https://learn.microsoft.com/en-us/graph/api/driveitem-delta?view=graph-rest-1.0#scanning-permissions-hierarchies)
- [Best practices for discovering files and detecting changes at scale](https://learn.microsoft.com/en-us/onedrive/developer/rest-api/concepts/scan-guidance)
- [List driveItem permissions](https://learn.microsoft.com/en-us/graph/api/driveitem-list-permissions?view=graph-rest-1.0)

## Files

| File | Description |
|------|-------------|
| `main.py` | Entry point, orchestrates the sync |
| `config.py` | Configuration from environment variables |
| `sharepoint_client.py` | Microsoft Graph API client |
| `blob_client.py` | Azure Blob Storage client |
| `permissions_sync.py` | SharePoint permission export + ACL merge |
| `purview_client.py` | Purview sensitivity labels + RMS rights extraction |
| `Dockerfile` | Container build file |
| `requirements.txt` | Python dependencies |
| `deploy/` | Azure Function + ACA Job deployment scripts ([README](deploy/README.md)) |
| `host.json` | Azure Functions host configuration |
| `sharepoint_sync_timer/` | Timer-trigger wrapper that executes `main.py` |

## Usage

```bash
# Install dependencies
pip install -r requirements.txt

# Run
python main.py
```

## Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `SHAREPOINT_SITE_URL` | Yes | (required) | e.g. `https://contoso.sharepoint.com/sites/MySite` |
| `SHAREPOINT_DRIVE_NAME` | No | `Documents` | Document library name |
| `SHAREPOINT_FOLDER_PATH` | No | `/` | Folder path to sync |
| `AZURE_STORAGE_ACCOUNT_NAME` | Yes | (required) | Storage account name |
| `AZURE_BLOB_CONTAINER_NAME` | No | `sharepoint-sync` | Container name |
| `AZURE_BLOB_PREFIX` | No | (empty) | Prefix for all blobs |
| `DELETE_ORPHANED_BLOBS` | No | `false` | Delete blobs removed from SharePoint |
| `DRY_RUN` | No | `false` | Preview without changes |
| `SYNC_PERMISSIONS` | No | `false` | Export SharePoint permissions to blob metadata |
| `SYNC_PURVIEW_PROTECTION` | No | `false` | Enable Purview sensitivity label and RMS protection sync |
| `FORCE_FULL_SYNC` | No | `false` | Skip delta, do full re-scan |

## Authentication

Credentials are resolved per service:

- **SharePoint (Graph API)**: Uses `ClientSecretCredential` when `AZURE_CLIENT_ID` / `AZURE_CLIENT_SECRET` / `AZURE_TENANT_ID` are set (app registration with `Sites.Selected` or `Sites.Read.All`), otherwise `DefaultAzureCredential`.
- **Blob Storage**: Uses `ManagedIdentityCredential` when running in Azure (Function / ACA, detected via `IDENTITY_ENDPOINT`), `AzureCliCredential` locally, or explicit storage credentials via `AZURE_STORAGE_CLIENT_ID` / `AZURE_STORAGE_CLIENT_SECRET` / `AZURE_STORAGE_TENANT_ID`.

This separation ensures the SharePoint app registration credentials (env vars) don't interfere with storage RBAC, which is assigned to the workload's managed identity.

### SharePoint Permissions (Sites.Selected)

```bash
# Grant Sites.Selected to your app registration
az rest --method POST \
  --url "https://graph.microsoft.com/v1.0/sites/<site-id>/permissions" \
  --body '{"roles":["read"],"grantedToIdentities":[{"application":{"id":"<app-id>"}}]}'
```

### Storage Permissions

```bash
az role assignment create \
  --assignee <identity-id> \
  --role "Storage Blob Data Contributor" \
  --scope /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Storage/storageAccounts/<account>
```

## Docker

```bash
docker build -t sharepoint-sync:latest .
docker run --env-file .env sharepoint-sync:latest
```

## Run as Cloud Job

The same `main.py` runs in two schedulers:

- **Azure Function** (timer trigger): see [deploy/README.md](deploy/README.md)
- **Azure Container Apps Job** (scheduled/manual)

Deploy scripts:

| Script | Purpose |
|--------|---------|
| `deploy/deploy-new.sh` | Create new test resources |
| `deploy/deploy-existing.sh` | Deploy code to existing resources |

## Delta Token

Stored at `.sync-state/delta-token.json` in the blob container. Delete it or set `FORCE_FULL_SYNC=true` to force a full re-crawl.
