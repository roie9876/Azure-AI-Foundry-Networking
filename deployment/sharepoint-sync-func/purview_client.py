"""
Microsoft Purview / Azure Information Protection (RMS) client.

This module handles:
1. Detecting if files are protected with Microsoft Purview sensitivity labels (RMS encryption)
2. Extracting the protection permissions (who can access encrypted files)
3. Merging RMS permissions with SharePoint permissions for AI Search security trimming

How RMS-encrypted files work in this pipeline:
─────────────────────────────────────────────────
When a file has a Purview sensitivity label with encryption (RMS):
  - The file content is encrypted at rest in SharePoint
  - Microsoft Graph API decrypts it server-side when downloading (if the app has Files.Read.All)
  - The encryption embeds a "publishing license" with usage rights (View, Edit, Copy, etc.)
  - These usage rights define WHO can do WHAT with the file

For AI Search knowledge integration, we need TWO permission layers:
  1. SharePoint sharing permissions  → who can access the file in SharePoint
  2. RMS protection permissions      → who the sensitivity label grants content access to

The EFFECTIVE access for security trimming = INTERSECTION of both layers.
A user must appear in BOTH permission sets to access the document in search results.

Graph API endpoints used:
  - GET /drives/{drive-id}/items/{item-id}?$select=sensitivityLabel
    → Returns the sensitivity label (labelId, displayName, etc.)
  - GET /security/informationProtection/sensitivityLabels
    → Lists all available sensitivity labels with their settings
  - POST /drives/{drive-id}/items/{item-id}/extractSensitivityLabels
    → Extracts current sensitivity labels from file content

Required Azure AD App permissions:
  - Files.Read.All (to read files and sensitivity labels on items)
  - InformationProtectionPolicy.Read.All (to read label definitions)
"""

import json
import os
from dataclasses import dataclass, field
from datetime import datetime
from typing import List, Dict, Optional, Tuple
from enum import Enum

import structlog
from azure.identity.aio import ClientSecretCredential, DefaultAzureCredential

logger = structlog.get_logger(__name__)


# ─────────────────────────────────────────────────────────────────────────────
# Data Models
# ─────────────────────────────────────────────────────────────────────────────

class ProtectionStatus(Enum):
    """Protection status of a file."""
    UNPROTECTED = "unprotected"           # No sensitivity label or label without encryption
    PROTECTED = "protected"               # Has sensitivity label with encryption (RMS)
    LABEL_ONLY = "label_only"             # Has sensitivity label but NO encryption
    UNKNOWN = "unknown"                   # Could not determine (API error, etc.)


class RMSUsageRight(Enum):
    """
    Common RMS usage rights.
    See: https://learn.microsoft.com/en-us/azure/information-protection/configure-usage-rights
    """
    VIEW = "VIEW"                     # View/Read content
    EDIT = "EDIT"                     # Edit content
    SAVE = "SAVE"                     # Save the document
    EXPORT = "EXPORT"                 # Export/Save As
    PRINT = "PRINT"                   # Print
    COPY = "COPY"                     # Copy content
    FORWARD = "FORWARD"               # Forward (email)
    REPLY = "REPLY"                   # Reply (email)
    REPLYALL = "REPLYALL"             # Reply all (email)
    EXTRACT = "EXTRACT"               # Extract/copy programmatically
    OWNER = "OWNER"                   # Full control
    DOCEDIT = "DOCEDIT"               # Edit content in Office apps
    OBJMODEL = "OBJMODEL"             # Access via object model (macros)
    VIEWRIGHTSDATA = "VIEWRIGHTSDATA" # View the usage rights


@dataclass
class RMSPermissionEntry:
    """
    Represents a single RMS permission entry (a user/group with specific usage rights).
    """
    identity: str                     # Email or Entra Object ID
    identity_type: str                # "user" or "group"
    display_name: str
    entra_object_id: Optional[str]    # Entra (Azure AD) Object ID if resolved
    usage_rights: List[str]           # e.g., ["VIEW", "EDIT", "PRINT"]

    def has_view_access(self) -> bool:
        """Check if this entry has at least view/read access."""
        view_rights = {"VIEW", "EDIT", "OWNER", "DOCEDIT", "EXTRACT", "OBJMODEL"}
        return bool(set(self.usage_rights) & view_rights)

    def to_dict(self) -> dict:
        return {
            "identity": self.identity,
            "identity_type": self.identity_type,
            "display_name": self.display_name,
            "entra_object_id": self.entra_object_id,
            "usage_rights": self.usage_rights,
        }

    @classmethod
    def from_dict(cls, data: dict) -> "RMSPermissionEntry":
        return cls(
            identity=data.get("identity", ""),
            identity_type=data.get("identity_type", "unknown"),
            display_name=data.get("display_name", ""),
            entra_object_id=data.get("entra_object_id"),
            usage_rights=data.get("usage_rights", []),
        )


@dataclass
class SensitivityLabelInfo:
    """
    Information about a Purview sensitivity label applied to a file.
    """
    label_id: str                     # The sensitivity label GUID
    label_name: str                   # Display name (e.g., "Confidential", "Highly Confidential")
    is_encrypted: bool                # Whether the label applies RMS encryption
    assignment_method: str            # "standard", "privileged", "auto"
    tooltip: Optional[str] = None     # Label tooltip/description
    color: Optional[str] = None       # Label color in hex
    parent_label_name: Optional[str] = None  # Parent label if sublabel

    def to_dict(self) -> dict:
        return {
            "label_id": self.label_id,
            "label_name": self.label_name,
            "is_encrypted": self.is_encrypted,
            "assignment_method": self.assignment_method,
            "tooltip": self.tooltip,
            "parent_label_name": self.parent_label_name,
        }


@dataclass
class FileProtectionInfo:
    """
    Complete protection information for a file.
    Combines sensitivity label info with RMS permission entries.
    """
    file_id: str
    file_path: str
    status: ProtectionStatus
    sensitivity_label: Optional[SensitivityLabelInfo] = None
    rms_permissions: List[RMSPermissionEntry] = field(default_factory=list)
    detected_at: Optional[datetime] = None

    def get_user_ids_with_view_access(self) -> List[str]:
        """
        Get Entra Object IDs of users who have view access via RMS protection.

        Returns:
            List of user Entra Object IDs with at least view rights
        """
        user_ids = []
        for entry in self.rms_permissions:
            if entry.identity_type == "user" and entry.has_view_access():
                if entry.entra_object_id:
                    user_ids.append(entry.entra_object_id)
        return list(set(user_ids))

    def get_group_ids_with_view_access(self) -> List[str]:
        """
        Get Entra Object IDs of groups that have view access via RMS protection.

        Returns:
            List of group Entra Object IDs with at least view rights
        """
        group_ids = []
        for entry in self.rms_permissions:
            if entry.identity_type == "group" and entry.has_view_access():
                if entry.entra_object_id:
                    group_ids.append(entry.entra_object_id)
        return list(set(group_ids))

    def to_metadata(self) -> Dict[str, str]:
        """
        Convert protection info to blob metadata.

        Returns:
            Dictionary of metadata key-value pairs for blob storage
        """
        metadata = {
            "purview_protection_status": self.status.value,
        }

        if self.sensitivity_label:
            metadata["purview_label_id"] = self.sensitivity_label.label_id
            metadata["purview_label_name"] = self.sensitivity_label.label_name
            metadata["purview_is_encrypted"] = str(self.sensitivity_label.is_encrypted).lower()

        if self.rms_permissions:
            metadata["purview_rms_permissions"] = json.dumps(
                [p.to_dict() for p in self.rms_permissions]
            )

        if self.detected_at:
            metadata["purview_detected_at"] = self.detected_at.isoformat()

        return metadata

    @classmethod
    def from_metadata(cls, file_id: str, file_path: str, metadata: Dict[str, str]) -> Optional["FileProtectionInfo"]:
        """Create FileProtectionInfo from blob metadata if present."""
        status_str = metadata.get("purview_protection_status")
        if not status_str:
            return None

        try:
            status = ProtectionStatus(status_str)
        except ValueError:
            status = ProtectionStatus.UNKNOWN

        label = None
        label_id = metadata.get("purview_label_id")
        if label_id:
            label = SensitivityLabelInfo(
                label_id=label_id,
                label_name=metadata.get("purview_label_name", ""),
                is_encrypted=metadata.get("purview_is_encrypted", "false") == "true",
                assignment_method="unknown",
            )

        rms_permissions = []
        rms_json = metadata.get("purview_rms_permissions")
        if rms_json:
            try:
                rms_data = json.loads(rms_json)
                rms_permissions = [RMSPermissionEntry.from_dict(p) for p in rms_data]
            except json.JSONDecodeError:
                pass

        return cls(
            file_id=file_id,
            file_path=file_path,
            status=status,
            sensitivity_label=label,
            rms_permissions=rms_permissions,
        )


# ─────────────────────────────────────────────────────────────────────────────
# Purview Client
# ─────────────────────────────────────────────────────────────────────────────

def _get_purview_credential():
    """Get credential for Purview/Graph API access."""
    client_id = os.environ.get("AZURE_CLIENT_ID")
    client_secret = os.environ.get("AZURE_CLIENT_SECRET")
    tenant_id = os.environ.get("AZURE_TENANT_ID")

    if all([client_id, client_secret, tenant_id]):
        return ClientSecretCredential(
            tenant_id=tenant_id,
            client_id=client_id,
            client_secret=client_secret,
        )
    else:
        return DefaultAzureCredential()


class PurviewClient:
    """
    Client for detecting and extracting Microsoft Purview sensitivity labels
    and RMS protection permissions from SharePoint files.

    This client uses Microsoft Graph API to:
    1. Check if a file has a sensitivity label
    2. Determine if the label includes RMS encryption
    3. Extract the protection permissions (users/groups with usage rights)

    The extracted permissions are used alongside SharePoint permissions
    for security-trimmed search in Azure AI Search.
    """

    GRAPH_SCOPES = ["https://graph.microsoft.com/.default"]

    def __init__(self, drive_id: str):
        """
        Initialize the Purview client.

        Args:
            drive_id: The SharePoint drive ID
        """
        self.drive_id = drive_id
        self._credential = None
        self._http_client = None
        self._label_cache: Dict[str, SensitivityLabelInfo] = {}  # label_id → info

    async def __aenter__(self) -> "PurviewClient":
        """Async context manager entry."""
        import httpx
        self._credential = _get_purview_credential()
        self._http_client = httpx.AsyncClient(timeout=60.0)
        # Pre-fetch available sensitivity labels for the tenant
        await self._load_sensitivity_labels()
        return self

    async def __aexit__(self, exc_type, exc_val, exc_tb) -> None:
        """Async context manager exit."""
        if self._http_client:
            await self._http_client.aclose()
        if self._credential:
            await self._credential.close()

    async def _get_auth_headers(self) -> Dict[str, str]:
        """Get authorization headers for Graph API calls."""
        token = await self._credential.get_token("https://graph.microsoft.com/.default")
        return {"Authorization": f"Bearer {token.token}"}

    async def _load_sensitivity_labels(self) -> None:
        """
        Pre-fetch all sensitivity labels from the tenant.
        This allows us to determine if a label includes encryption
        without making per-file API calls.

        Uses: GET /security/informationProtection/sensitivityLabels
        Requires: InformationProtectionPolicy.Read.All permission
        """
        try:
            headers = await self._get_auth_headers()

            # Try v1.0 first, fall back to beta if not available
            # Some tenants (e.g., M365 developer tenants) only expose
            # the informationProtection segment on the beta endpoint.
            urls_to_try = [
                "https://graph.microsoft.com/v1.0/security/informationProtection/sensitivityLabels",
                "https://graph.microsoft.com/beta/security/informationProtection/sensitivityLabels",
            ]

            response = None
            for url in urls_to_try:
                response = await self._http_client.get(url, headers=headers)
                if response.status_code == 200:
                    await logger.ainfo("Loaded sensitivity labels from endpoint", url=url)
                    break
                await logger.adebug(
                    "Label endpoint not available, trying next",
                    url=url,
                    status_code=response.status_code,
                )

            if response.status_code == 403:
                await logger.awarning(
                    "No permission to read sensitivity labels "
                    "(InformationProtectionPolicy.Read.All required). "
                    "Will detect labels per-file from driveItem properties."
                )
                return

            if response.status_code != 200:
                await logger.awarning(
                    "Failed to load sensitivity labels from all endpoints",
                    status_code=response.status_code,
                    body=response.text[:500],
                )
                return

            data = response.json()
            labels = data.get("value", [])

            for label in labels:
                label_id = label.get("id", "")
                # Determine if the label has encryption from its contentFormats
                # and isActive / parent info
                is_encrypted = self._label_has_encryption(label)

                parent_info = label.get("parent", {})
                parent_name = parent_info.get("name") if parent_info else None

                info = SensitivityLabelInfo(
                    label_id=label_id,
                    label_name=label.get("name", ""),
                    is_encrypted=is_encrypted,
                    assignment_method="standard",
                    tooltip=label.get("tooltip"),
                    color=label.get("color"),
                    parent_label_name=parent_name,
                )
                self._label_cache[label_id] = info

            await logger.ainfo(
                "Loaded sensitivity labels",
                total=len(self._label_cache),
                encrypted_count=sum(1 for l in self._label_cache.values() if l.is_encrypted),
            )

        except Exception as e:
            await logger.aerror("Error loading sensitivity labels", error=str(e))

    @staticmethod
    def _label_has_encryption(label_data: dict) -> bool:
        """
        Determine if a sensitivity label definition includes encryption.

        Uses the explicit ``hasProtection`` field returned by the Graph API
        (available on both v1.0 and beta endpoints).  Falls back to the
        ``isEncryptingContent`` field when ``hasProtection`` is absent.

        Previous versions used name-based heuristics (e.g. matching
        "confidential") which produced false positives — labels whose name
        matched but had no encryption configured.  This has been removed
        in favour of the authoritative API fields.
        """
        # Primary: explicit hasProtection field from Graph API
        if "hasProtection" in label_data:
            return bool(label_data["hasProtection"])

        # Fallback: isEncryptingContent (older API versions)
        if label_data.get("isEncryptingContent"):
            return True

        return False

    async def get_file_protection(self, file_id: str, file_path: str) -> FileProtectionInfo:
        """
        Get the complete protection information for a file.

        This method:
        1. Checks the driveItem for a sensitivity label
        2. Looks up the label in our cache to determine if it has encryption
        3. If encrypted, extracts the protection permissions

        Args:
            file_id: The SharePoint drive item ID
            file_path: The file path (for logging)

        Returns:
            FileProtectionInfo with protection status and permissions
        """
        await logger.ainfo("Checking file protection", file_path=file_path, file_id=file_id)

        try:
            # Step 1: Get the sensitivity label from the driveItem
            label_info = await self._get_item_sensitivity_label(file_id, file_path)

            if not label_info:
                return FileProtectionInfo(
                    file_id=file_id,
                    file_path=file_path,
                    status=ProtectionStatus.UNPROTECTED,
                    detected_at=datetime.utcnow(),
                )

            # Step 2: Determine if the label includes encryption
            if not label_info.is_encrypted:
                return FileProtectionInfo(
                    file_id=file_id,
                    file_path=file_path,
                    status=ProtectionStatus.LABEL_ONLY,
                    sensitivity_label=label_info,
                    detected_at=datetime.utcnow(),
                )

            # Step 3: Extract RMS protection permissions
            rms_permissions = await self._extract_rms_permissions(file_id, file_path)

            await logger.ainfo(
                "File is RMS-protected",
                file_path=file_path,
                label_name=label_info.label_name,
                rms_permission_count=len(rms_permissions),
            )

            return FileProtectionInfo(
                file_id=file_id,
                file_path=file_path,
                status=ProtectionStatus.PROTECTED,
                sensitivity_label=label_info,
                rms_permissions=rms_permissions,
                detected_at=datetime.utcnow(),
            )

        except Exception as e:
            await logger.aerror(
                "Failed to get file protection info",
                file_path=file_path,
                error=str(e),
            )
            return FileProtectionInfo(
                file_id=file_id,
                file_path=file_path,
                status=ProtectionStatus.UNKNOWN,
                detected_at=datetime.utcnow(),
            )

    async def _get_item_sensitivity_label(
        self, file_id: str, file_path: str
    ) -> Optional[SensitivityLabelInfo]:
        """
        Get the sensitivity label applied to a driveItem.

        Uses: GET /drives/{drive-id}/items/{item-id}?$select=id,name,sensitivityLabel
        Note: The sensitivityLabel property is available on driveItem in Graph v1.0

        Args:
            file_id: The drive item ID
            file_path: File path for logging

        Returns:
            SensitivityLabelInfo if a label is applied, None otherwise
        """
        try:
            headers = await self._get_auth_headers()
            url = (
                f"https://graph.microsoft.com/v1.0/drives/{self.drive_id}"
                f"/items/{file_id}?$select=id,name,sensitivityLabel"
            )

            response = await self._http_client.get(url, headers=headers)

            if response.status_code == 403:
                await logger.awarning(
                    "No permission to read sensitivity label on item",
                    file_path=file_path,
                )
                return None

            if response.status_code != 200:
                await logger.awarning(
                    "Failed to get sensitivity label",
                    file_path=file_path,
                    status_code=response.status_code,
                )
                return None

            data = response.json()
            label_data = data.get("sensitivityLabel")

            # sensitivityLabel can be null, empty object, or have empty fields
            if not label_data:
                return None

            label_id = label_data.get("labelId") or ""
            display_name = label_data.get("displayName") or ""

            # If labelId is empty, no label is actually applied
            if not label_id:
                await logger.adebug(
                    "sensitivityLabel present but labelId is empty — no label applied",
                    file_path=file_path,
                )
                return None

            assignment_method = label_data.get("assignmentMethod", "standard")

            # Look up in cache to get encryption info
            cached = self._label_cache.get(label_id)
            is_encrypted = cached.is_encrypted if cached else False

            return SensitivityLabelInfo(
                label_id=label_id,
                label_name=display_name or (cached.label_name if cached else "Unknown"),
                is_encrypted=is_encrypted,
                assignment_method=assignment_method,
                tooltip=cached.tooltip if cached else None,
                parent_label_name=cached.parent_label_name if cached else None,
            )

        except Exception as e:
            await logger.aerror(
                "Error reading sensitivity label",
                file_path=file_path,
                error=str(e),
            )
            return None

    async def _extract_rms_permissions(
        self, file_id: str, file_path: str
    ) -> List[RMSPermissionEntry]:
        """
        Extract RMS protection permissions from an encrypted file.

        For RMS-encrypted files, the protection permissions define who can
        access the decrypted content and what they can do with it.

        Strategy:
        1. Try POST /drives/{drive-id}/items/{item-id}/extractSensitivityLabels
           to get detailed protection data
        2. Fall back to checking the item's sharing permissions filtered by
           the protection policy
        3. If both fail, use the label definition's default protection settings

        Args:
            file_id: The drive item ID
            file_path: File path for logging

        Returns:
            List of RMSPermissionEntry with users/groups and their usage rights
        """
        rms_permissions = []

        # Approach 1: Try extractSensitivityLabels endpoint
        rms_permissions = await self._try_extract_labels_endpoint(file_id, file_path)
        if rms_permissions:
            return rms_permissions

        # Approach 2: Read the item's permissions and infer RMS access
        # When a file is RMS-protected, the Graph API still returns sharing permissions.
        # Users who have sharing access AND are in the RMS policy can decrypt and view.
        # We get the permissions and mark them as RMS-derived.
        rms_permissions = await self._get_permissions_as_rms_fallback(file_id, file_path)

        return rms_permissions

    async def _try_extract_labels_endpoint(
        self, file_id: str, file_path: str
    ) -> List[RMSPermissionEntry]:
        """
        Try using the extractSensitivityLabels endpoint for detailed protection data.

        POST /drives/{drive-id}/items/{item-id}/extractSensitivityLabels

        This endpoint reads the publishing license embedded in the file to
        extract the actual RMS protection recipients and their rights.

        Note: This endpoint may not be available in all tenants or may require
        specific licensing (Microsoft 365 E5 or equivalent).
        """
        try:
            headers = await self._get_auth_headers()
            headers["Content-Type"] = "application/json"
            url = (
                f"https://graph.microsoft.com/v1.0/drives/{self.drive_id}"
                f"/items/{file_id}/extractSensitivityLabels"
            )

            response = await self._http_client.post(url, headers=headers, content="{}")

            if response.status_code == 404 or response.status_code == 403:
                await logger.adebug(
                    "extractSensitivityLabels not available, using fallback",
                    file_path=file_path,
                    status_code=response.status_code,
                )
                return []

            if response.status_code != 200:
                await logger.adebug(
                    "extractSensitivityLabels failed",
                    file_path=file_path,
                    status_code=response.status_code,
                )
                return []

            data = response.json()
            labels = data.get("labels", [])

            permissions = []
            for label in labels:
                # Extract protection entries from the label's protection settings
                protection = label.get("protectionSettings", {})
                allowed_users = protection.get("allowedUsers", [])
                allowed_groups = protection.get("allowedGroups", [])
                usage_rights = protection.get("usageRights", [])

                for user in allowed_users:
                    permissions.append(RMSPermissionEntry(
                        identity=user.get("email", user.get("id", "")),
                        identity_type="user",
                        display_name=user.get("displayName", ""),
                        entra_object_id=user.get("id"),
                        usage_rights=usage_rights,
                    ))

                for group in allowed_groups:
                    permissions.append(RMSPermissionEntry(
                        identity=group.get("email", group.get("id", "")),
                        identity_type="group",
                        display_name=group.get("displayName", ""),
                        entra_object_id=group.get("id"),
                        usage_rights=usage_rights,
                    ))

            return permissions

        except Exception as e:
            await logger.adebug(
                "Error with extractSensitivityLabels",
                file_path=file_path,
                error=str(e),
            )
            return []

    async def _get_permissions_as_rms_fallback(
        self, file_id: str, file_path: str
    ) -> List[RMSPermissionEntry]:
        """
        Fallback: Get the file's Graph API permissions and treat them as RMS access.

        When the extractSensitivityLabels endpoint is not available, we use
        the standard permissions endpoint. The rationale:

        - If a file is RMS-encrypted AND shared in SharePoint, the effective
          access is the intersection of both
        - The Graph API permissions already reflect who has access in SharePoint
        - For RMS-encrypted files, SharePoint enforces that only users in the
          RMS policy can actually open/decrypt the file
        - So the Graph permissions on an encrypted file are a reasonable
          approximation of the effective RMS access

        This is a pragmatic fallback for security trimming in AI Search.
        """
        try:
            headers = await self._get_auth_headers()
            url = (
                f"https://graph.microsoft.com/v1.0/drives/{self.drive_id}"
                f"/items/{file_id}/permissions"
            )

            response = await self._http_client.get(url, headers=headers)

            if response.status_code != 200:
                await logger.awarning(
                    "Failed to get permissions for RMS fallback",
                    file_path=file_path,
                    status_code=response.status_code,
                )
                return []

            data = response.json()
            permissions = []

            for perm in data.get("value", []):
                roles = perm.get("roles", [])

                # Map SharePoint roles to RMS-like usage rights
                usage_rights = self._sp_roles_to_rms_rights(roles)

                # Extract identity from grantedToV2
                granted = perm.get("grantedToV2") or perm.get("grantedTo") or {}

                user = granted.get("user")
                group = granted.get("group")
                site_user = granted.get("siteUser")

                if user:
                    permissions.append(RMSPermissionEntry(
                        identity=user.get("email", user.get("id", "")),
                        identity_type="user",
                        display_name=user.get("displayName", ""),
                        entra_object_id=user.get("id"),
                        usage_rights=usage_rights,
                    ))
                elif group:
                    permissions.append(RMSPermissionEntry(
                        identity=group.get("email", group.get("id", "")),
                        identity_type="group",
                        display_name=group.get("displayName", ""),
                        entra_object_id=group.get("id"),
                        usage_rights=usage_rights,
                    ))
                elif site_user:
                    permissions.append(RMSPermissionEntry(
                        identity=site_user.get("email", site_user.get("id", "")),
                        identity_type="user",
                        display_name=site_user.get("displayName", ""),
                        entra_object_id=site_user.get("id"),
                        usage_rights=usage_rights,
                    ))

            await logger.ainfo(
                "RMS permissions via fallback",
                file_path=file_path,
                permission_count=len(permissions),
            )

            return permissions

        except Exception as e:
            await logger.aerror(
                "Error getting permissions for RMS fallback",
                file_path=file_path,
                error=str(e),
            )
            return []

    @staticmethod
    def _sp_roles_to_rms_rights(roles: List[str]) -> List[str]:
        """
        Map SharePoint permission roles to equivalent RMS usage rights.

        SharePoint roles: "read", "write", "owner", "sp.full control", etc.
        """
        rights = set()
        for role in roles:
            role_lower = role.lower()
            if role_lower in ("owner", "sp.full control"):
                rights.update(["VIEW", "EDIT", "SAVE", "PRINT", "COPY", "EXPORT", "OWNER"])
            elif role_lower in ("write", "edit", "contribute"):
                rights.update(["VIEW", "EDIT", "SAVE", "PRINT", "COPY"])
            elif role_lower in ("read",):
                rights.update(["VIEW"])
        return list(rights) if rights else ["VIEW"]


# ─────────────────────────────────────────────────────────────────────────────
# Permission Merging Logic
# ─────────────────────────────────────────────────────────────────────────────

def merge_permissions_for_search(
    sp_user_ids: List[str],
    sp_group_ids: List[str],
    protection_info: Optional[FileProtectionInfo],
) -> Tuple[List[str], List[str]]:
    """
    Merge SharePoint permissions with Purview/RMS permissions for AI Search.

    The effective access for security trimming is the INTERSECTION:
    - A user must have BOTH SharePoint access AND RMS access
    - If the file is NOT RMS-protected, only SharePoint permissions apply
    - If the file IS RMS-protected, take the intersection of both sets

    Args:
        sp_user_ids: User Entra Object IDs from SharePoint permissions
        sp_group_ids: Group Entra Object IDs from SharePoint permissions
        protection_info: FileProtectionInfo from Purview client (may be None)

    Returns:
        Tuple of (effective_user_ids, effective_group_ids) for AI Search ACLs
    """
    # No protection info or unprotected → SharePoint permissions only
    if not protection_info or protection_info.status in (
        ProtectionStatus.UNPROTECTED,
        ProtectionStatus.LABEL_ONLY,
        ProtectionStatus.UNKNOWN,
    ):
        return sp_user_ids, sp_group_ids

    # File is RMS-protected → intersect with RMS permissions
    rms_user_ids = set(protection_info.get_user_ids_with_view_access())
    rms_group_ids = set(protection_info.get_group_ids_with_view_access())

    sp_user_set = set(sp_user_ids)
    sp_group_set = set(sp_group_ids)

    # If RMS has no specific users/groups, it might mean "all authenticated users"
    # or the extraction failed. In that case, fall back to SP permissions only.
    if not rms_user_ids and not rms_group_ids:
        logger.warning(
            "RMS-protected file has no extractable permissions, "
            "falling back to SharePoint permissions only",
            file_id=protection_info.file_id,
            file_path=protection_info.file_path,
        )
        return sp_user_ids, sp_group_ids

    # Intersection: user must be in BOTH SharePoint AND RMS
    effective_users = list(sp_user_set & rms_user_ids) if rms_user_ids else sp_user_ids
    effective_groups = list(sp_group_set & rms_group_ids) if rms_group_ids else sp_group_ids

    logger.info(
        "Merged SP + RMS permissions",
        file_path=protection_info.file_path,
        sp_users=len(sp_user_ids),
        rms_users=len(rms_user_ids),
        effective_users=len(effective_users),
        sp_groups=len(sp_group_ids),
        rms_groups=len(rms_group_ids),
        effective_groups=len(effective_groups),
    )

    return effective_users, effective_groups


def is_purview_sync_enabled() -> bool:
    """Check if Purview/RMS protection sync is enabled via environment variable."""
    return os.environ.get("SYNC_PURVIEW_PROTECTION", "false").lower() == "true"
