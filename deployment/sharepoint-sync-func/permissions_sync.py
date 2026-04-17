"""
SharePoint to Azure Blob Storage permissions synchronization.

This module retrieves file permissions from SharePoint via Microsoft Graph API
and stores them as blob metadata in Azure Blob Storage.

Recommended approach options:
1. Blob Metadata (default): Store permissions as JSON in blob metadata
2. Azure Data Lake Storage Gen2 ACLs: Apply POSIX-like ACLs (requires HNS enabled)
3. Blob Index Tags: Store as searchable tags (limited to simple key-value pairs)

This implementation uses the Blob Metadata approach as it:
- Works with standard Blob Storage (no HNS required)
- Supports complex permission structures (users, groups, roles)
- Allows application-level permission enforcement
- Preserves the full SharePoint permission model
"""

import hashlib
import json
import os
from dataclasses import dataclass, field
from datetime import datetime
from typing import List, Dict, Optional, AsyncIterator, Tuple

import structlog
from azure.identity.aio import ClientSecretCredential, DefaultAzureCredential
from msgraph import GraphServiceClient

from purview_client import (
    PurviewClient,
    FileProtectionInfo,
    ProtectionStatus,
    merge_permissions_for_search,
    is_purview_sync_enabled,
)

logger = structlog.get_logger(__name__)

# Metadata keys for storing permissions
# Legacy: Full permissions JSON (for debugging/reference)
METADATA_PERMISSIONS = "sharepoint_permissions"
METADATA_PERMISSIONS_SYNCED_AT = "permissions_synced_at"
METADATA_PERMISSIONS_HASH = "permissions_hash"  # Hash of permissions for delta detection

# Azure AI Search ACL-compatible metadata keys for POSIX-like permissions preview feature
# When stored in blob metadata, the indexer sees them prefixed with "metadata_"
# e.g., "user_ids" in blob becomes "metadata_user_ids" in indexer
# 
# IMPORTANT: For the permissionFilter preview feature, fields MUST use these specific names:
# - "user_ids" → becomes "metadata_user_ids" → maps to index field with permissionFilter: "userIds"
# - "group_ids" → becomes "metadata_group_ids" → maps to index field with permissionFilter: "groupIds"
# See: https://learn.microsoft.com/en-us/azure/search/search-security-document-level-access-control
METADATA_ACL_USER_IDS = "user_ids"     # JSON array of user object IDs (Entra IDs)
METADATA_ACL_GROUP_IDS = "group_ids"   # JSON array of group object IDs (Entra IDs)

# Purview/RMS metadata keys (populated when SYNC_PURVIEW_PROTECTION=true)
METADATA_PURVIEW_STATUS = "purview_protection_status"     # "unprotected", "protected", "label_only"
METADATA_PURVIEW_LABEL_NAME = "purview_label_name"        # Sensitivity label display name
METADATA_PURVIEW_IS_ENCRYPTED = "purview_is_encrypted"    # "true" or "false"


@dataclass
class SharePointPermission:
    """Represents a permission entry from SharePoint."""
    id: str
    roles: List[str]  # e.g., ["read"], ["write"], ["owner"]
    identity_type: str  # "user", "group", "siteGroup"
    display_name: str
    email: Optional[str] = None
    identity_id: Optional[str] = None  # Microsoft Entra Object ID
    inherited: bool = False

    def to_dict(self) -> dict:
        """Convert to dictionary for JSON serialization."""
        return {
            "id": self.id,
            "roles": self.roles,
            "identity_type": self.identity_type,
            "display_name": self.display_name,
            "email": self.email,
            "identity_id": self.identity_id,
            "inherited": self.inherited
        }
    
    @classmethod
    def from_dict(cls, data: dict) -> "SharePointPermission":
        """Create from dictionary."""
        return cls(
            id=data.get("id", ""),
            roles=data.get("roles", []),
            identity_type=data.get("identity_type", "unknown"),
            display_name=data.get("display_name", ""),
            email=data.get("email"),
            identity_id=data.get("identity_id"),
            inherited=data.get("inherited", False)
        )


@dataclass
class FilePermissions:
    """Represents all permissions for a file."""
    file_path: str
    file_id: str
    permissions: List[SharePointPermission] = field(default_factory=list)
    synced_at: Optional[datetime] = None

    def to_metadata(
        self, 
        protection_info: Optional["FileProtectionInfo"] = None
    ) -> Dict[str, str]:
        """
        Convert permissions to blob metadata format.
        
        When protection_info is provided (file is RMS-protected with Purview),
        the effective ACLs are the INTERSECTION of SharePoint permissions and
        RMS permissions. This ensures that AI Search security trimming respects
        both permission layers.
        
        Args:
            protection_info: Optional Purview/RMS protection info. When provided,
                ACL user/group IDs will be the intersection of SP and RMS permissions.
        
        Returns:
            Dictionary of metadata key-value pairs (values must be strings)
        """
        permissions_json = json.dumps([p.to_dict() for p in self.permissions])
        
        # Extract user and group IDs from SharePoint permissions
        sp_user_ids = self._extract_user_ids()
        sp_group_ids = self._extract_group_ids()
        
        # Merge with Purview/RMS permissions if available
        # This computes the intersection: user must be in BOTH SP and RMS
        effective_user_ids, effective_group_ids = merge_permissions_for_search(
            sp_user_ids, sp_group_ids, protection_info
        )
        
        metadata = {
            METADATA_PERMISSIONS: permissions_json,
            METADATA_PERMISSIONS_SYNCED_AT: self.synced_at.isoformat() if self.synced_at else datetime.utcnow().isoformat(),
            METADATA_PERMISSIONS_HASH: self.compute_permissions_hash(),
        }
        
        # Add Purview/RMS metadata if protection info is available
        if protection_info:
            metadata.update(protection_info.to_metadata())
        
        # Add ACL fields - store as pipe-delimited strings for Azure AI Search skillset compatibility
        # The indexer will read these as "metadata_user_ids" and "metadata_group_ids"
        # A SplitSkill in the skillset will convert them to Collection(Edm.String)
        #
        # We use pipe (|) as delimiter since GUIDs don't contain pipes
        # When there are no specific users/groups, we use a placeholder GUID that won't match any real ID
        PLACEHOLDER_NO_USERS = "00000000-0000-0000-0000-000000000000"
        PLACEHOLDER_NO_GROUPS = "00000000-0000-0000-0000-000000000001"
        
        if effective_user_ids:
            metadata[METADATA_ACL_USER_IDS] = "|".join(effective_user_ids)
        else:
            # No specific users - use placeholder (access controlled by groups)
            metadata[METADATA_ACL_USER_IDS] = PLACEHOLDER_NO_USERS
            
        if effective_group_ids:
            metadata[METADATA_ACL_GROUP_IDS] = "|".join(effective_group_ids)
        else:
            # No specific groups - use placeholder (access controlled by users)
            metadata[METADATA_ACL_GROUP_IDS] = PLACEHOLDER_NO_GROUPS
        
        return metadata
    
    def compute_permissions_hash(self) -> str:
        """
        Compute a stable hash of the permissions for delta detection.
        
        The hash is computed from a sorted, normalized representation of 
        permissions to ensure consistency regardless of the order permissions
        are returned from the API.
        
        Returns:
            SHA256 hash string of the permissions
        """
        if not self.permissions:
            return hashlib.sha256(b"no_permissions").hexdigest()[:16]
        
        # Create a normalized, sorted representation for consistent hashing
        # Include only fields that matter for access control
        normalized = []
        for perm in self.permissions:
            # Create a tuple of the permission-relevant fields (sorted by identity_id for consistency)
            perm_tuple = (
                perm.identity_id or "",
                perm.identity_type,
                tuple(sorted(perm.roles)),  # Sort roles for consistency
            )
            normalized.append(perm_tuple)
        
        # Sort by identity_id to ensure order doesn't affect hash
        normalized.sort(key=lambda x: (x[0], x[1]))
        
        # Convert to string and hash
        perm_string = json.dumps(normalized, sort_keys=True)
        return hashlib.sha256(perm_string.encode('utf-8')).hexdigest()[:16]
    
    def _extract_user_ids(self) -> List[str]:
        """
        Extract unique Entra user object IDs from permissions.
        
        Returns:
            List of user object IDs (GUIDs) that have access to this file
        """
        user_ids = []
        for perm in self.permissions:
            if perm.identity_type == "user" and perm.identity_id:
                # Only include Entra object IDs (GUIDs), not SharePoint-specific IDs
                if self._is_valid_guid(perm.identity_id):
                    user_ids.append(perm.identity_id)
        return list(set(user_ids))  # Remove duplicates
    
    def _extract_group_ids(self) -> List[str]:
        """
        Extract unique Entra group object IDs from permissions.
        
        Returns:
            List of group object IDs (GUIDs) that have access to this file
        """
        group_ids = []
        for perm in self.permissions:
            if perm.identity_type == "group" and perm.identity_id:
                # Only include Entra object IDs (GUIDs)
                if self._is_valid_guid(perm.identity_id):
                    group_ids.append(perm.identity_id)
        return list(set(group_ids))  # Remove duplicates
    
    @staticmethod
    def _is_valid_guid(value: str) -> bool:
        """
        Check if a string looks like a valid GUID/UUID.
        Entra Object IDs are GUIDs like: 00aa00aa-bb11-cc22-dd33-44ee44ee44ee
        """
        if not value:
            return False
        import re
        guid_pattern = r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
        return bool(re.match(guid_pattern, value))
    
    @classmethod
    def from_metadata(cls, file_path: str, file_id: str, metadata: Dict[str, str]) -> "FilePermissions":
        """Create FilePermissions from blob metadata."""
        permissions_json = metadata.get(METADATA_PERMISSIONS, "[]")
        synced_at_str = metadata.get(METADATA_PERMISSIONS_SYNCED_AT)
        
        try:
            permissions_data = json.loads(permissions_json)
            permissions = [SharePointPermission.from_dict(p) for p in permissions_data]
        except json.JSONDecodeError:
            permissions = []
        
        synced_at = None
        if synced_at_str:
            try:
                synced_at = datetime.fromisoformat(synced_at_str)
            except ValueError:
                pass
        
        return cls(
            file_path=file_path,
            file_id=file_id,
            permissions=permissions,
            synced_at=synced_at
        )


class PermissionsClient:
    """Client for fetching and syncing SharePoint permissions."""
    
    GRAPH_SCOPES = ["https://graph.microsoft.com/.default"]
    
    def __init__(self, drive_id: str):
        """
        Initialize the permissions client.
        
        Args:
            drive_id: The SharePoint drive ID
        """
        self.drive_id = drive_id
        self._credential = None
        self._client: Optional[GraphServiceClient] = None
    
    async def __aenter__(self) -> "PermissionsClient":
        """Async context manager entry."""
        self._credential = _get_sharepoint_credential()
        self._client = GraphServiceClient(
            credentials=self._credential,
            scopes=self.GRAPH_SCOPES
        )
        return self
    
    async def __aexit__(self, exc_type, exc_val, exc_tb) -> None:
        """Async context manager exit."""
        if self._credential:
            await self._credential.close()
    
    async def get_file_permissions(self, file_id: str, file_path: str) -> FilePermissions:
        """
        Get all permissions for a specific file.
        
        Args:
            file_id: The SharePoint drive item ID
            file_path: The file path (for logging/reference)
            
        Returns:
            FilePermissions object containing all permissions
        """
        if not self._client:
            raise RuntimeError("Client not initialized. Use async with context manager.")
        
        await logger.ainfo("Fetching permissions", file_path=file_path, file_id=file_id)
        
        try:
            # Get permissions from Graph API
            # GET /drives/{drive-id}/items/{item-id}/permissions
            permissions_response = await self._client.drives.by_drive_id(
                self.drive_id
            ).items.by_drive_item_id(
                file_id
            ).permissions.get()
            
            if not permissions_response or not permissions_response.value:
                await logger.ainfo("No permissions found", file_path=file_path)
                return FilePermissions(
                    file_path=file_path,
                    file_id=file_id,
                    permissions=[],
                    synced_at=datetime.utcnow()
                )
            
            permissions = []
            for perm in permissions_response.value:
                sp_perm = self._parse_permission(perm)
                if sp_perm:
                    permissions.append(sp_perm)
            
            await logger.ainfo("Fetched permissions", 
                              file_path=file_path, 
                              permission_count=len(permissions))
            
            return FilePermissions(
                file_path=file_path,
                file_id=file_id,
                permissions=permissions,
                synced_at=datetime.utcnow()
            )
            
        except Exception as e:
            await logger.aerror("Failed to fetch permissions", 
                               file_path=file_path, 
                               error=str(e))
            raise
    
    def _parse_permission(self, perm) -> Optional[SharePointPermission]:
        """
        Parse a Graph API permission object into SharePointPermission.
        
        Args:
            perm: The permission object from Graph API
            
        Returns:
            SharePointPermission or None if parsing fails
        """
        try:
            perm_id = perm.id or ""
            roles = perm.roles or []
            inherited = perm.inherited_from is not None
            
            # Determine identity type and details from grantedToV2
            identity_type = "unknown"
            display_name = ""
            email = None
            identity_id = None
            
            if perm.granted_to_v2:
                gtv2 = perm.granted_to_v2
                
                if gtv2.user:
                    identity_type = "user"
                    display_name = gtv2.user.display_name or ""
                    email = getattr(gtv2.user, 'email', None)
                    identity_id = gtv2.user.id
                    
                elif gtv2.group:
                    identity_type = "group"
                    display_name = gtv2.group.display_name or ""
                    email = getattr(gtv2.group, 'email', None)
                    identity_id = gtv2.group.id
                    
                elif gtv2.site_group:
                    identity_type = "siteGroup"
                    display_name = gtv2.site_group.display_name or ""
                    identity_id = str(gtv2.site_group.id) if gtv2.site_group.id else None
                    
                elif gtv2.site_user:
                    identity_type = "user"
                    display_name = gtv2.site_user.display_name or ""
                    email = getattr(gtv2.site_user, 'email', None)
                    identity_id = gtv2.site_user.id
            
            # Fallback to grantedTo if grantedToV2 is not available
            elif perm.granted_to and perm.granted_to.user:
                identity_type = "user"
                display_name = perm.granted_to.user.display_name or ""
                email = getattr(perm.granted_to.user, 'email', None)
                identity_id = perm.granted_to.user.id
            
            return SharePointPermission(
                id=perm_id,
                roles=roles,
                identity_type=identity_type,
                display_name=display_name,
                email=email,
                identity_id=identity_id,
                inherited=inherited
            )
            
        except Exception as e:
            logger.warning("Failed to parse permission", error=str(e))
            return None


def _get_sharepoint_credential():
    """
    Get the appropriate Azure credential for SharePoint/Graph API access.
    Uses explicit ClientSecretCredential when App Registration environment 
    variables are set.
    """
    client_id = os.environ.get("AZURE_CLIENT_ID")
    client_secret = os.environ.get("AZURE_CLIENT_SECRET")
    tenant_id = os.environ.get("AZURE_TENANT_ID")
    
    if all([client_id, client_secret, tenant_id]):
        logger.info("Using ClientSecretCredential for permissions sync",
                   client_id=client_id, tenant_id=tenant_id)
        return ClientSecretCredential(
            tenant_id=tenant_id,
            client_id=client_id,
            client_secret=client_secret
        )
    elif os.environ.get("IDENTITY_ENDPOINT"):
        logger.info("Using Managed Identity for permissions sync")
        return DefaultAzureCredential()
    else:
        logger.info("Using DefaultAzureCredential for permissions sync")
        return DefaultAzureCredential()


def is_permissions_sync_enabled() -> bool:
    """Check if permissions sync is enabled via environment variable."""
    return os.environ.get("SYNC_PERMISSIONS", "false").lower() == "true"


def get_permissions_from_metadata(metadata: Dict[str, str]) -> Optional[FilePermissions]:
    """
    Extract permissions from blob metadata.
    
    Args:
        metadata: The blob metadata dictionary
        
    Returns:
        FilePermissions if present, None otherwise
    """
    if METADATA_PERMISSIONS not in metadata:
        return None
    
    return FilePermissions.from_metadata(
        file_path="",
        file_id="",
        metadata=metadata
    )


def permissions_to_summary(permissions: List[SharePointPermission]) -> str:
    """
    Create a human-readable summary of permissions.
    
    Args:
        permissions: List of SharePointPermission objects
        
    Returns:
        Summary string for logging
    """
    if not permissions:
        return "No permissions"
    
    summary_parts = []
    for perm in permissions:
        roles_str = ",".join(perm.roles)
        if perm.email:
            summary_parts.append(f"{perm.display_name}<{perm.email}>:{roles_str}")
        else:
            summary_parts.append(f"{perm.display_name}:{roles_str}")
    
    return "; ".join(summary_parts)


def should_sync_permissions(
    file_permissions: "FilePermissions", 
    existing_metadata: Optional[Dict[str, str]]
) -> bool:
    """
    Determine if permissions should be synced based on hash comparison.
    
    This enables delta detection for permission changes by comparing the 
    computed permissions hash with the stored hash in blob metadata.
    
    Args:
        file_permissions: The current permissions from SharePoint
        existing_metadata: The existing blob metadata (may be None)
        
    Returns:
        True if permissions have changed and should be synced
    """
    if not existing_metadata:
        # No existing metadata, always sync
        return True
    
    stored_hash = existing_metadata.get(METADATA_PERMISSIONS_HASH)
    if not stored_hash:
        # No stored hash, need to sync to establish baseline
        return True
    
    # Compute current permissions hash
    current_hash = file_permissions.compute_permissions_hash()
    
    # Only sync if hash has changed
    return stored_hash != current_hash


# =============================================================================
# Graph Delta API Implementation for Permission Change Detection
# =============================================================================

# Import shared delta token classes from sharepoint_client
from sharepoint_client import DeltaToken, DeltaTokenStorage


@dataclass
class PermissionChangedItem:
    """Represents an item whose permissions have changed (from Graph delta API)."""
    item_id: str
    name: str
    path: str
    sharing_changed: bool  # True if @microsoft.graph.sharedChanged annotation is present


class GraphDeltaPermissionsClient:
    """
    Client that uses Microsoft Graph delta API to detect permission changes.
    
    This approach uses the following Graph API features:
    - Delta query: GET /drives/{drive-id}/root/delta
    - Prefer: deltashowsharingchanges header to identify items with permission changes
    - Prefer: hierarchicalsharing for efficient permission hierarchy tracking
    
    See: https://learn.microsoft.com/en-us/graph/api/driveitem-delta
    """
    
    GRAPH_SCOPES = ["https://graph.microsoft.com/.default"]
    
    # Required headers for permission change detection
    # See: https://learn.microsoft.com/en-us/graph/api/driveitem-delta#scanning-permissions-hierarchies
    DELTA_HEADERS = {
        "Prefer": "deltashowremovedasdeleted, deltatraversepermissiongaps, deltashowsharingchanges, hierarchicalsharing"
    }
    
    def __init__(self, drive_id: str, token_storage: DeltaTokenStorage):
        """
        Initialize the Graph delta permissions client.
        
        Args:
            drive_id: The SharePoint drive ID
            token_storage: Storage for delta tokens
        """
        self.drive_id = drive_id
        self.token_storage = token_storage
        self._credential = None
        self._client: Optional[GraphServiceClient] = None
    
    async def __aenter__(self) -> "GraphDeltaPermissionsClient":
        """Async context manager entry."""
        self._credential = _get_sharepoint_credential()
        self._client = GraphServiceClient(
            credentials=self._credential,
            scopes=self.GRAPH_SCOPES
        )
        return self
    
    async def __aexit__(self, exc_type, exc_val, exc_tb) -> None:
        """Async context manager exit."""
        if self._credential:
            await self._credential.close()
    
    async def get_items_with_permission_changes(self) -> AsyncIterator[PermissionChangedItem]:
        """
        Query Graph API delta to find items with permission changes.
        
        Uses the delta API with special headers to detect permission changes:
        - First call (no token): Returns all items, establishes baseline
        - Subsequent calls (with token): Returns only changed items
        - Items with permission changes have @microsoft.graph.sharedChanged annotation
        
        Yields:
            PermissionChangedItem for each item that has permission changes
        """
        if not self._client:
            raise RuntimeError("Client not initialized. Use async with context manager.")
        
        # Get existing token or None for initial sync
        existing_token = self.token_storage.get_token(self.drive_id, "permissions")
        
        await logger.ainfo(
            "Starting Graph delta query for permission changes",
            drive_id=self.drive_id,
            has_existing_token=existing_token is not None
        )
        
        try:
            # Build the delta request with permission tracking headers
            import httpx
            
            # Use direct HTTP call since msgraph SDK doesn't easily support custom headers for delta
            async with httpx.AsyncClient() as http_client:
                # Get access token
                token = await self._credential.get_token("https://graph.microsoft.com/.default")
                
                # Build delta URL
                if existing_token:
                    # Use stored delta link/token
                    delta_url = f"https://graph.microsoft.com/v1.0/drives/{self.drive_id}/root/delta?token={existing_token.token}"
                else:
                    # Initial enumeration
                    delta_url = f"https://graph.microsoft.com/v1.0/drives/{self.drive_id}/root/delta"
                
                headers = {
                    "Authorization": f"Bearer {token.token}",
                    **self.DELTA_HEADERS
                }
                
                new_delta_link = None
                items_processed = 0
                items_with_sharing_changes = 0
                
                # Page through results
                while delta_url:
                    response = await http_client.get(delta_url, headers=headers, timeout=60.0)
                    
                    if response.status_code == 410:
                        # Token expired, need to start fresh
                        await logger.awarning("Delta token expired, starting fresh enumeration")
                        self.token_storage.delete_token(self.drive_id, "permissions")
                        delta_url = f"https://graph.microsoft.com/v1.0/drives/{self.drive_id}/root/delta"
                        existing_token = None
                        continue
                    
                    response.raise_for_status()
                    data = response.json()
                    
                    # Process items
                    for item in data.get("value", []):
                        items_processed += 1
                        
                        # Check for permission change annotation
                        sharing_changed = item.get("@microsoft.graph.sharedChanged") == "True"
                        
                        # Skip folders unless they have sharing changes
                        if "folder" in item and not sharing_changed:
                            continue
                        
                        # Skip deleted items for permission sync (they'll be handled by file sync)
                        if "deleted" in item:
                            continue
                        
                        # Only yield if this is initial sync (no token) or item has sharing changes
                        if not existing_token or sharing_changed:
                            if sharing_changed:
                                items_with_sharing_changes += 1
                                await logger.ainfo(
                                    "Item with permission change detected",
                                    item_id=item.get("id"),
                                    name=item.get("name"),
                                    sharing_changed=True
                                )
                            
                            # Build path from parentReference
                            parent_ref = item.get("parentReference", {})
                            parent_path = parent_ref.get("path", "")
                            # Remove the /drives/{id}/root: prefix
                            if ":/" in parent_path:
                                parent_path = parent_path.split(":/", 1)[1]
                            elif parent_path:
                                parent_path = parent_path.lstrip("/")
                            
                            item_path = f"/{parent_path}/{item.get('name', '')}" if parent_path else f"/{item.get('name', '')}"
                            item_path = item_path.replace("//", "/")
                            
                            yield PermissionChangedItem(
                                item_id=item.get("id", ""),
                                name=item.get("name", ""),
                                path=item_path,
                                sharing_changed=sharing_changed
                            )
                    
                    # Get next page or delta link
                    delta_url = data.get("@odata.nextLink")
                    if not delta_url:
                        # No more pages, save the delta link for next time
                        new_delta_link = data.get("@odata.deltaLink")
                
                await logger.ainfo(
                    "Graph delta query completed",
                    items_processed=items_processed,
                    items_with_sharing_changes=items_with_sharing_changes,
                    is_initial_sync=existing_token is None
                )
                
                # Save the new delta link for next run
                if new_delta_link:
                    # Extract token from delta link
                    from urllib.parse import urlparse, parse_qs
                    parsed = urlparse(new_delta_link)
                    query_params = parse_qs(parsed.query)
                    token_value = query_params.get("token", [None])[0]
                    
                    if token_value:
                        new_token = DeltaToken(
                            drive_id=self.drive_id,
                            token=token_value,
                            last_updated=datetime.utcnow(),
                            token_type="permissions"
                        )
                        self.token_storage.save_token(new_token)
        
        except Exception as e:
            await logger.aerror("Error during Graph delta query", error=str(e))
            raise


def get_permissions_delta_mode() -> str:
    """
    Get the configured permissions delta detection mode.
    
    Returns:
        "hash" or "graph_delta"
    """
    return os.environ.get("PERMISSIONS_DELTA_MODE", "hash").lower()
