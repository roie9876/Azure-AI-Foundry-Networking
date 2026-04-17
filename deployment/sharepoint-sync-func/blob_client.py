"""
Azure Blob Storage client for sync operations.
Uses DefaultAzureCredential for authentication, which supports:
- Managed Identity (when running in Azure Container Apps)
- Client Credentials (when AZURE_CLIENT_ID, AZURE_CLIENT_SECRET, AZURE_TENANT_ID are set)
- Azure CLI (when logged in via 'az login')

Includes delta token persistence: the last Graph delta link is stored as a
small blob so that subsequent runs can do incremental (delta) syncs.
"""

import json
import os
from datetime import datetime, timezone
from typing import Dict, AsyncIterator, Optional
from dataclasses import dataclass

import structlog
from azure.identity.aio import DefaultAzureCredential
from azure.storage.blob.aio import BlobServiceClient, ContainerClient

logger = structlog.get_logger(__name__)


def _get_credential():
    """
    Get the appropriate Azure credential for Blob Storage access.
    
    For Blob Storage, we check if a separate storage credential is configured.
    If not, we use Azure CLI credentials directly (useful when storage is in 
    a different tenant than SharePoint).
    
    Set AZURE_STORAGE_TENANT_ID, AZURE_STORAGE_CLIENT_ID, AZURE_STORAGE_CLIENT_SECRET
    if you want to use a separate App Registration for storage.
    """
    # Check if separate storage credentials are configured
    storage_tenant_id = os.environ.get("AZURE_STORAGE_TENANT_ID")
    storage_client_id = os.environ.get("AZURE_STORAGE_CLIENT_ID")
    storage_client_secret = os.environ.get("AZURE_STORAGE_CLIENT_SECRET")
    
    if all([storage_tenant_id, storage_client_id, storage_client_secret]):
        # Use explicit credentials for storage if configured
        logger.info("Using ClientSecretCredential for Blob Storage",
                   client_id=storage_client_id, tenant_id=storage_tenant_id)
        from azure.identity.aio import ClientSecretCredential
        return ClientSecretCredential(
            tenant_id=storage_tenant_id,
            client_id=storage_client_id,
            client_secret=storage_client_secret
        )
    elif os.environ.get("IDENTITY_ENDPOINT"):
        # In Azure (Function / ACA), use ManagedIdentityCredential directly.
        # DefaultAzureCredential would try EnvironmentCredential first, which
        # picks up the SharePoint app registration (AZURE_CLIENT_ID etc.) and
        # fails because that identity lacks Storage RBAC.
        logger.info("Using Managed Identity authentication for Blob Storage")
        from azure.identity.aio import ManagedIdentityCredential
        return ManagedIdentityCredential()
    else:
        # Use Azure CLI credential directly to avoid picking up SharePoint App Registration
        # environment variables (AZURE_CLIENT_ID, etc.) which are for a different tenant
        logger.info("Using AzureCliCredential for Blob Storage")
        from azure.identity.aio import AzureCliCredential
        return AzureCliCredential()


@dataclass
class BlobFile:
    """Represents a blob in Azure Storage."""
    name: str
    size: int
    last_modified: datetime
    content_hash: str | None = None  # MD5 or ETag
    metadata: Dict[str, str] | None = None


class BlobStorageClient:
    """Client for Azure Blob Storage operations."""
    
    # Metadata key for storing SharePoint file info
    METADATA_SP_ITEM_ID = "sharepoint_item_id"
    METADATA_SP_LAST_MODIFIED = "sharepoint_last_modified"
    METADATA_SP_CONTENT_HASH = "sharepoint_content_hash"
    METADATA_SP_WEB_URL = "sharepoint_web_url"
    
    # Azure AI Search ACL-compatible metadata keys
    # These are populated by permissions_sync.py and read by the indexer
    # See: https://learn.microsoft.com/en-us/azure/search/search-index-access-control-lists-and-rbac-push-api
    METADATA_ACL_USER_IDS = "acl_user_ids"    # JSON array of user Entra Object IDs
    METADATA_ACL_GROUP_IDS = "acl_group_ids"  # JSON array of group Entra Object IDs

    # Blob name used to persist the Graph API delta token between runs
    DELTA_TOKEN_BLOB = ".sync-state/delta-token.json"
    
    # Permissions hash for delta detection - set by permissions_sync.py
    METADATA_PERMISSIONS_HASH = "permissions_hash"
    
    def __init__(self, account_url: str, container_name: str, blob_prefix: str = ""):
        """
        Initialize the Blob Storage client.
        
        Args:
            account_url: The blob storage account URL
            container_name: The container name
            blob_prefix: Optional prefix for all blobs
        """
        self.account_url = account_url
        self.container_name = container_name
        self.blob_prefix = blob_prefix.strip("/")
        self._credential: DefaultAzureCredential | None = None
        self._service_client: BlobServiceClient | None = None
        self._container_client: ContainerClient | None = None
    
    async def __aenter__(self) -> "BlobStorageClient":
        """Async context manager entry."""
        self._credential = _get_credential()
        self._service_client = BlobServiceClient(
            account_url=self.account_url,
            credential=self._credential
        )
        self._container_client = self._service_client.get_container_client(self.container_name)
        
        # Ensure container exists
        try:
            await self._container_client.create_container()
            await logger.ainfo("Created container", container=self.container_name)
        except Exception:
            # Container likely already exists
            pass
        
        return self
    
    async def __aexit__(self, exc_type, exc_val, exc_tb) -> None:
        """Async context manager exit."""
        if self._service_client:
            await self._service_client.close()
        if self._credential:
            await self._credential.close()
    
    def _get_blob_name(self, sharepoint_path: str) -> str:
        """
        Convert a SharePoint path to a blob name.
        
        Args:
            sharepoint_path: The SharePoint file path
            
        Returns:
            The blob name with optional prefix
        """
        # Remove leading slash and clean up the path
        clean_path = sharepoint_path.lstrip("/")
        
        if self.blob_prefix:
            return f"{self.blob_prefix}/{clean_path}"
        return clean_path
    
    async def list_blobs(self) -> AsyncIterator[BlobFile]:
        """
        List all blobs in the container with the configured prefix.
        
        Yields:
            BlobFile objects for each blob (excludes directories in HNS-enabled storage)
        """
        if not self._container_client:
            raise RuntimeError("Client not initialized. Use async with context manager.")
        
        prefix = self.blob_prefix if self.blob_prefix else None
        
        await logger.ainfo("Listing blobs", container=self.container_name, prefix=prefix)
        
        async for blob in self._container_client.list_blobs(name_starts_with=prefix, include=['metadata']):
            # Skip directories in HNS-enabled storage (they have size 0 and are marked as directories)
            # Directories end with "/" or have is_directory=True in metadata
            if blob.name.endswith('/'):
                continue
            # Also skip items with size 0 that look like directories (no file extension in last segment)
            if blob.size == 0 and '.' not in blob.name.split('/')[-1]:
                continue
            yield BlobFile(
                name=blob.name,
                size=blob.size,
                last_modified=blob.last_modified,
                content_hash=blob.etag,
                metadata=blob.metadata
            )
    
    async def get_blob_metadata(self, blob_name: str) -> BlobFile | None:
        """
        Get metadata for a specific blob.
        
        Args:
            blob_name: The blob name
            
        Returns:
            BlobFile if exists, None otherwise
        """
        if not self._container_client:
            raise RuntimeError("Client not initialized. Use async with context manager.")
        
        try:
            blob_client = self._container_client.get_blob_client(blob_name)
            properties = await blob_client.get_blob_properties()
            
            return BlobFile(
                name=blob_name,
                size=properties.size,
                last_modified=properties.last_modified,
                content_hash=properties.etag,
                metadata=properties.metadata
            )
        except Exception:
            return None
    
    async def upload_blob(
        self,
        sharepoint_path: str,
        content: bytes,
        sharepoint_item_id: str,
        sharepoint_last_modified: datetime,
        sharepoint_content_hash: str | None = None,
        sharepoint_web_url: str | None = None,
        dry_run: bool = False
    ) -> str:
        """
        Upload content to a blob.
        
        Args:
            sharepoint_path: The SharePoint file path (used to derive blob name)
            content: The file content
            sharepoint_item_id: The SharePoint item ID (stored in metadata)
            sharepoint_last_modified: The SharePoint last modified date
            sharepoint_content_hash: Optional content hash from SharePoint
            dry_run: If True, only log without making changes
            
        Returns:
            The blob name
        """
        if not self._container_client:
            raise RuntimeError("Client not initialized. Use async with context manager.")
        
        blob_name = self._get_blob_name(sharepoint_path)
        
        metadata = {
            self.METADATA_SP_ITEM_ID: sharepoint_item_id,
            self.METADATA_SP_LAST_MODIFIED: sharepoint_last_modified.isoformat(),
        }
        if sharepoint_content_hash:
            metadata[self.METADATA_SP_CONTENT_HASH] = sharepoint_content_hash
        if sharepoint_web_url:
            metadata[self.METADATA_SP_WEB_URL] = sharepoint_web_url
        
        if dry_run:
            await logger.ainfo("[DRY RUN] Would upload blob", 
                blob_name=blob_name, 
                size=len(content),
                sharepoint_path=sharepoint_path
            )
        else:
            blob_client = self._container_client.get_blob_client(blob_name)
            await blob_client.upload_blob(content, overwrite=True, metadata=metadata)
            await logger.ainfo("Uploaded blob", 
                blob_name=blob_name, 
                size=len(content),
                sharepoint_path=sharepoint_path
            )
        
        return blob_name
    
    async def delete_blob(self, blob_name: str, dry_run: bool = False) -> None:
        """
        Delete a blob or directory.
        
        For hierarchical namespace (HNS) enabled storage accounts, directories
        must be deleted recursively. This method handles both regular blobs
        and HNS directories.
        
        Args:
            blob_name: The blob name to delete
            dry_run: If True, only log without making changes
        """
        if not self._container_client:
            raise RuntimeError("Client not initialized. Use async with context manager.")
        
        if dry_run:
            await logger.ainfo("[DRY RUN] Would delete blob", blob_name=blob_name)
        else:
            blob_client = self._container_client.get_blob_client(blob_name)
            try:
                await blob_client.delete_blob()
                await logger.ainfo("Deleted blob", blob_name=blob_name)
            except Exception as e:
                # Check if this is a directory that needs recursive deletion
                # This happens with HNS-enabled storage (Data Lake Storage Gen2)
                if "DirectoryIsNotEmpty" in str(e):
                    await logger.ainfo("Deleting directory recursively", blob_name=blob_name)
                    await self._delete_directory_recursive(blob_name)
                else:
                    raise

    async def _delete_directory_recursive(self, directory_path: str) -> None:
        """
        Recursively delete a directory and all its contents (for HNS-enabled storage).
        
        Args:
            directory_path: The directory path to delete
        """
        if not self._container_client:
            raise RuntimeError("Client not initialized. Use async with context manager.")
        
        # First, delete all blobs/files within the directory
        prefix = directory_path.rstrip("/") + "/"
        blobs_deleted = 0
        
        async for blob in self._container_client.list_blobs(name_starts_with=prefix):
            try:
                blob_client = self._container_client.get_blob_client(blob.name)
                await blob_client.delete_blob()
                blobs_deleted += 1
            except Exception as e:
                await logger.awarning("Failed to delete blob in directory", 
                                     blob_name=blob.name, error=str(e))
        
        # Now try to delete the directory itself
        try:
            blob_client = self._container_client.get_blob_client(directory_path)
            await blob_client.delete_blob()
        except Exception:
            # Directory might not exist as a separate blob (flat namespace behavior)
            pass
        
        await logger.ainfo("Deleted directory", 
                          directory_path=directory_path, 
                          blobs_deleted=blobs_deleted)
    
    def should_update(self, blob: BlobFile, sp_last_modified: datetime, sp_content_hash: str | None) -> bool:
        """
        Determine if a blob should be updated based on SharePoint file changes.
        
        Args:
            blob: The existing blob
            sp_last_modified: SharePoint file last modified date
            sp_content_hash: SharePoint content hash
            
        Returns:
            True if the blob should be updated
        """
        if not blob.metadata:
            return True
        
        # Check content hash first (most reliable)
        stored_hash = blob.metadata.get(self.METADATA_SP_CONTENT_HASH)
        if stored_hash and sp_content_hash and stored_hash != sp_content_hash:
            return True
        
        # Fall back to date comparison
        stored_date_str = blob.metadata.get(self.METADATA_SP_LAST_MODIFIED)
        if stored_date_str:
            try:
                stored_date = datetime.fromisoformat(stored_date_str.replace('Z', '+00:00'))
                # Ensure both dates are timezone-aware for comparison
                if sp_last_modified.tzinfo is None:
                    sp_last_modified = sp_last_modified.replace(tzinfo=timezone.utc)
                if stored_date.tzinfo is None:
                    stored_date = stored_date.replace(tzinfo=timezone.utc)
                
                return sp_last_modified > stored_date
            except (ValueError, TypeError):
                return True
        
        return True

    async def update_blob_metadata(
        self,
        blob_name: str,
        additional_metadata: Dict[str, str],
        dry_run: bool = False
    ) -> None:
        """
        Update metadata on an existing blob (merges with existing metadata).
        
        Removes deprecated metadata fields and keeps only essential ones.
        
        Args:
            blob_name: The blob name
            additional_metadata: New metadata to add/update
            dry_run: If True, only log without making changes
        """
        if not self._container_client:
            raise RuntimeError("Client not initialized. Use async with context manager.")
        
        blob_client = self._container_client.get_blob_client(blob_name)
        
        if dry_run:
            await logger.ainfo("[DRY RUN] Would update blob metadata", 
                blob_name=blob_name,
                metadata_keys=list(additional_metadata.keys())
            )
        else:
            # Get existing metadata
            try:
                properties = await blob_client.get_blob_properties()
                existing_metadata = properties.metadata or {}
            except Exception:
                existing_metadata = {}
            
            # Remove deprecated metadata fields
            deprecated_fields = [
                "metadata_user_ids", "metadata_group_ids",
                "acl_user_ids_list", "acl_group_ids_list",
                "metadata_acl_user_ids", "metdata_acl_group_ids"
            ]
            for field in deprecated_fields:
                existing_metadata.pop(field, None)
            
            # Merge metadata
            merged_metadata = {**existing_metadata, **additional_metadata}
            
            await blob_client.set_blob_metadata(merged_metadata)
            await logger.ainfo("Updated blob metadata", 
                blob_name=blob_name,
                metadata_keys=list(additional_metadata.keys())
            )

    # ------------------------------------------------------------------ #
    #  Delta token persistence
    # ------------------------------------------------------------------ #

    async def load_delta_token(self) -> Optional[str]:
        """
        Load the saved Graph delta link from blob storage.

        Returns:
            The deltaLink URL string, or None if no token has been saved yet
            (i.e. first run).
        """
        if not self._container_client:
            raise RuntimeError("Client not initialized. Use async with context manager.")

        try:
            blob_client = self._container_client.get_blob_client(self.DELTA_TOKEN_BLOB)
            download = await blob_client.download_blob()
            raw = await download.readall()
            data = json.loads(raw)
            delta_link = data.get("delta_link")
            saved_at = data.get("saved_at", "unknown")
            await logger.ainfo("Loaded delta token from blob storage",
                              saved_at=saved_at,
                              delta_link_preview=delta_link[:100] if delta_link else None)
            return delta_link
        except Exception:
            await logger.ainfo("No existing delta token found — will do full initial sync")
            return None

    async def save_delta_token(self, delta_link: str, dry_run: bool = False) -> None:
        """
        Persist the Graph delta link to blob storage for the next run.

        Args:
            delta_link: The @odata.deltaLink URL to save.
            dry_run: If True, skip the actual write.
        """
        if not self._container_client:
            raise RuntimeError("Client not initialized. Use async with context manager.")

        payload = json.dumps({
            "delta_link": delta_link,
            "saved_at": datetime.now(timezone.utc).isoformat(),
        })

        if dry_run:
            await logger.ainfo("[DRY RUN] Would save delta token")
        else:
            blob_client = self._container_client.get_blob_client(self.DELTA_TOKEN_BLOB)
            await blob_client.upload_blob(payload.encode(), overwrite=True)
            await logger.ainfo("Saved delta token to blob storage")

    async def clear_delta_token(self) -> None:
        """Delete the persisted delta token, forcing a full re-sync on next run."""
        if not self._container_client:
            raise RuntimeError("Client not initialized. Use async with context manager.")

        try:
            blob_client = self._container_client.get_blob_client(self.DELTA_TOKEN_BLOB)
            await blob_client.delete_blob()
            await logger.ainfo("Cleared delta token — next run will be a full sync")
        except Exception:
            pass  # Token didn't exist
