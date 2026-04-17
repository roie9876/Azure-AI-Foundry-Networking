# Sync Job Deployment

Deploy `sync/main.py` as an **Azure Function** (timer trigger) or **Azure Container Apps Job** (scheduled).

## Scripts

| Script | Purpose |
|--------|---------|
| `deploy-new.sh` | Create new Function App and/or ACA Job (timestamped names for testing) |
| `deploy-existing.sh` | Deploy code + config to an existing Function App and/or ACA Job |

Both scripts use `TARGET=func|aca|both` (default: `both`).

## Quick Start

### 1) Create new test resources

```bash
# Login
az login

# Function only
TARGET=func ./deploy-new.sh

# ACA only (needs an image source)
ACR_NAME=myacr TARGET=aca ./deploy-new.sh

# Both
ACR_NAME=myacr TARGET=both ./deploy-new.sh
```

### 2) Deploy to existing resources

```bash
# Function only
FUNCTION_APP_NAME=func-sharepoint-sync TARGET=func ./deploy-existing.sh

# ACA only
ACA_JOB_NAME=acaj-sharepoint-sync ACR_NAME=myacr TARGET=aca ./deploy-existing.sh

# Both
FUNCTION_APP_NAME=func-sharepoint-sync ACA_JOB_NAME=acaj-sharepoint-sync \
  ACR_NAME=myacr TARGET=both ./deploy-existing.sh
```

### Validate without deploying

```bash
VALIDATE_ONLY=true TARGET=both ./deploy-new.sh
```

## Configuration

Set these in `.env` (root or `sync/`) or as environment variables.

### Required

| Variable | Description |
|----------|-------------|
| `SUBSCRIPTION_ID` | Azure subscription ID |
| `SHAREPOINT_SITE_URL` | SharePoint site URL |
| `AZURE_STORAGE_ACCOUNT_NAME` | Target storage account |
| `AZURE_BLOB_CONTAINER_NAME` | Target blob container |

### Optional

| Variable | Default | Description |
|----------|---------|-------------|
| `RESOURCE_GROUP` | `rg-sharepoint-sync` | Resource group |
| `LOCATION` | `francecentral` | Azure region |
| `TIMER_SCHEDULE` | `0 0 2 * * *` | Cron schedule (6-field for Function, auto-converted to 5-field for ACA) |
| `DELETE_ORPHANED_BLOBS` | `false` | Delete blobs removed from SharePoint |
| `SYNC_PERMISSIONS` | `false` | Sync ACL metadata |

### ACA-specific

| Variable | Default | Description |
|----------|---------|-------------|
| `ACR_NAME` | (required for ACA) | ACR registry name (builds image via ACR Tasks) |
| `IMAGE_NAME` | (optional) | Pre-built image (skip ACR build) |
| `ACA_JOB_TRIGGER_TYPE` | `Schedule` | `Schedule` or `Manual` |

## Post-Deployment

### Grant SharePoint access to the managed identity

The managed identity needs Microsoft Graph permissions to read SharePoint:

```bash
# Get the principal ID
PRINCIPAL_ID=$(az functionapp identity show \
  --name <app-name> --resource-group <rg> --query principalId -o tsv)

# Option A: Sites.Read.All (requires admin consent)
# Option B: Sites.Selected (granular, recommended)
```

### Verify storage RBAC

```bash
az role assignment list --assignee <principal-id> --all -o table
```

## Monitoring

```bash
# Function logs
az functionapp log tail --name <name> --resource-group <rg>

# ACA job executions
az containerapp job execution list --name <name> --resource-group <rg> -o table
```

## Cleanup

```bash
az group delete --name rg-sharepoint-sync --yes --no-wait
```
