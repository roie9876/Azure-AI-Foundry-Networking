"""
SharePoint to Azure Blob Storage synchronization job.
Syncs files from a SharePoint document library to Azure Blob Storage.

Supports two modes:
1. Delta (incremental) sync — uses Microsoft Graph delta API to process only
   changed files since the last run. The delta token is persisted in blob storage.
2. Full sync — falls back to a full recursive listing when no delta token exists
   (first run) or when explicitly requested via FORCE_FULL_SYNC=true.

Permissions are synced only for files that changed (delta-aware).
"""

import asyncio
import logging
import os
import sys
from dataclasses import dataclass
from typing import AsyncIterator, Dict, Set, List
# Load environment variables from .env file for local development
from dotenv import load_dotenv
load_dotenv()
import structlog

from config import Config, PermissionsDeltaMode
from sharepoint_client import (
    SharePointClient,
    SharePointFile,
    DeltaChangeType,
    GraphDeltaFilesClient,
    DeltaTokenStorage,
    FileChangeType,
)
from blob_client import BlobStorageClient, BlobFile
from permissions_sync import (
    PermissionsClient,
    permissions_to_summary,
    should_sync_permissions,
    GraphDeltaPermissionsClient,
)
from purview_client import (
    PurviewClient,
    FileProtectionInfo,
    ProtectionStatus,
)

# Configure standard logging to output to console
logging.basicConfig(
    format="%(message)s",
    stream=sys.stdout,
    level=logging.INFO,
)

# Configure structured logging
structlog.configure(
    processors=[
        structlog.stdlib.filter_by_level,
        structlog.stdlib.add_logger_name,
        structlog.stdlib.add_log_level,
        structlog.stdlib.PositionalArgumentsFormatter(),
        structlog.processors.TimeStamper(fmt="iso"),
        structlog.processors.StackInfoRenderer(),
        structlog.processors.format_exc_info,
        structlog.processors.UnicodeDecoder(),
        structlog.stdlib.ProcessorFormatter.wrap_for_formatter,
    ],
    wrapper_class=structlog.stdlib.BoundLogger,
    context_class=dict,
    logger_factory=structlog.stdlib.LoggerFactory(),
    cache_logger_on_first_use=True,
)

# Add a handler for structlog output
formatter = structlog.stdlib.ProcessorFormatter(
    processor=structlog.dev.ConsoleRenderer()  # Use console renderer for readable output
)

handler = logging.StreamHandler()
handler.setFormatter(formatter)

root_logger = logging.getLogger()
root_logger.handlers = [handler]
root_logger.setLevel(logging.INFO)

logger = structlog.get_logger(__name__)


@dataclass
class SyncStats:
    """Statistics for the sync operation."""
    files_scanned: int = 0
    files_added: int = 0
    files_updated: int = 0
    files_deleted: int = 0
    files_unchanged: int = 0
    files_failed: int = 0
    bytes_transferred: int = 0
    permissions_synced: int = 0
    permissions_unchanged: int = 0  # Permissions skipped due to no changes (delta)
    permissions_failed: int = 0
    purview_protected: int = 0       # Files with RMS encryption (Purview)
    purview_label_only: int = 0      # Files with sensitivity label but no encryption
    purview_unprotected: int = 0     # Files with no sensitivity label
    purview_failed: int = 0          # Files where Purview detection failed
    rms_download_failed: int = 0     # Files where download was blocked by RMS encryption
    sync_mode: str = "full"  # "full" or "delta"


def _force_full_sync() -> bool:
    """Check if a full sync is explicitly requested via env var."""
    return os.environ.get("FORCE_FULL_SYNC", "false").lower() == "true"


_RMS_ERROR_INDICATORS = [
    "access denied", "403", "forbidden",
    "locked", "423",
    "drm", "rights management",
    "encrypted", "protection",
    "the file is encrypted",
]


def _ext_filter_allows(filename: str, include_exts: List[str], exclude_exts: List[str]) -> bool:
    """Return True if a filename passes the include/exclude extension filter."""
    if not filename:
        return True
    name_lower = filename.lower()
    if exclude_exts:
        for e in exclude_exts:
            if name_lower.endswith(e):
                return False
    if include_exts:
        for e in include_exts:
            if name_lower.endswith(e):
                return True
        return False
    return True


def _path_in_scope(item_path: str, folder_paths: List[str]) -> bool:
    """
    Return True if item_path is inside at least one of folder_paths.

    folder_paths is the parsed SHAREPOINT_FOLDER_PATH list (e.g. ["/IEC", "/Malan"]).
    Comparison is case-insensitive and uses path-prefix match so sub-folders
    are included. "/" or "" means "whole drive — no scope filter".
    """
    if not folder_paths:
        return True
    normalized_scopes = []
    for fp in folder_paths:
        fp = (fp or "").strip()
        if fp in ("", "/"):
            return True
        normalized_scopes.append("/" + fp.strip("/").lower())
    item = "/" + (item_path or "").lstrip("/").lower()
    for scope in normalized_scopes:
        if item == scope or item.startswith(scope + "/"):
            return True
    return False


def _is_not_found_error(e: Exception) -> bool:
    """Detect Graph API 404 / itemNotFound so we can skip missing folders."""
    err = str(e)
    status = getattr(e, "response_status_code", None) or getattr(e, "status_code", None)
    return status == 404 or "itemNotFound" in err or "could not be found" in err.lower()


async def _list_files_multi(sp_client: SharePointClient, folder_paths: List[str], include_exts: List[str] = None, exclude_exts: List[str] = None) -> AsyncIterator[SharePointFile]:
    """Yield files from multiple folder paths (supports comma-separated SHAREPOINT_FOLDER_PATH).

    If a folder no longer exists in SharePoint (deleted/renamed), log a warning
    and continue with the remaining folders instead of aborting the whole sync.
    """
    include_exts = include_exts or []
    exclude_exts = exclude_exts or []
    for folder_path in folder_paths:
        await logger.ainfo("Listing files from folder", folder_path=folder_path)
        try:
            async for sp_file in sp_client.list_files(folder_path):
                if not _ext_filter_allows(getattr(sp_file, "name", ""), include_exts, exclude_exts):
                    continue
                yield sp_file
        except Exception as e:
            if _is_not_found_error(e):
                await logger.awarning("Folder missing in SharePoint — skipping", folder_path=folder_path, error=str(e))
                continue
            raise


async def _get_changed_files_multi(delta_client: GraphDeltaFilesClient, folder_paths: List[str], include_exts: List[str] = None, exclude_exts: List[str] = None) -> AsyncIterator[SharePointFile]:
    """Yield changed files from multiple folder paths via delta API.

    Skips folders that no longer exist (same robustness as full sync).
    """
    include_exts = include_exts or []
    exclude_exts = exclude_exts or []
    for folder_path in folder_paths:
        await logger.ainfo("Getting delta changes for folder", folder_path=folder_path)
        try:
            async for sp_file in delta_client.get_changed_files(folder_path):
                if not _ext_filter_allows(getattr(sp_file, "name", ""), include_exts, exclude_exts):
                    continue
                yield sp_file
        except Exception as e:
            if _is_not_found_error(e):
                await logger.awarning("Folder missing in SharePoint (delta) — skipping", folder_path=folder_path, error=str(e))
                continue
            raise


async def _download_with_rms_fallback(
    sp_client: SharePointClient,
    file_id: str,
    file_path: str,
) -> tuple[bytes, bool]:
    """
    Download a file with graceful handling for RMS-encrypted files.

    When a file is protected with RMS encryption and the application
    does not have sufficient rights to decrypt, the Graph API returns
    an access error.  This helper catches such errors so the caller
    can still upload a placeholder blob and sync permissions/metadata.

    Returns:
        Tuple of (content, rms_blocked).  When *rms_blocked* is True
        the content is an empty ``bytes`` placeholder.
    """
    try:
        content = await sp_client.download_file(file_id)
        return content, False
    except Exception as e:
        error_str = str(e).lower()
        if any(ind in error_str for ind in _RMS_ERROR_INDICATORS):
            await logger.awarning(
                "File download blocked by RMS encryption — "
                "uploading empty placeholder with metadata",
                file_path=file_path,
                error=str(e),
            )
            return b"", True
        raise


async def _sync_permissions_for_files(
    sp_client: SharePointClient,
    blob_client: BlobStorageClient,
    drive_id: str,
    files: List[SharePointFile],
    stats: SyncStats,
    dry_run: bool,
) -> None:
    """
    Sync SharePoint permissions to blob metadata for a list of files.

    This is delta-aware: it only fetches permissions for the files that
    actually changed (instead of re-scanning the entire library).
    """
    if not files:
        return

    await logger.ainfo("Syncing permissions for changed files",
                      file_count=len(files))

    async with PermissionsClient(drive_id) as perm_client:
        for sp_file in files:
            blob_name = blob_client._get_blob_name(sp_file.path)
            try:
                file_permissions = await perm_client.get_file_permissions(
                    file_id=sp_file.id,
                    file_path=sp_file.path,
                )
                if file_permissions.permissions:
                    perm_metadata = file_permissions.to_metadata()
                    await logger.ainfo("Syncing permissions",
                        file_path=sp_file.path,
                        permission_count=len(file_permissions.permissions),
                        summary=permissions_to_summary(file_permissions.permissions),
                    )
                    await blob_client.update_blob_metadata(
                        blob_name=blob_name,
                        additional_metadata=perm_metadata,
                        dry_run=dry_run,
                    )
                    stats.permissions_synced += 1
                else:
                    await logger.adebug("No permissions to sync",
                                       file_path=sp_file.path)
            except Exception as e:
                await logger.aerror("Failed to sync permissions",
                    file_path=sp_file.path,
                    error=str(e),
                )
                stats.permissions_failed += 1


async def sync_sharepoint_to_blob(config: Config) -> SyncStats:
    """
    Synchronize files from SharePoint to Azure Blob Storage.

    Uses delta queries when a delta token is available (incremental sync).
    Falls back to a full listing on the first run or when FORCE_FULL_SYNC=true.

    Permissions are synced only for files that were created/modified during this
    sync cycle — not the entire library.

    Args:
        config: The sync configuration

    Returns:
        SyncStats with the operation results
    """
    stats = SyncStats()
    force_full = _force_full_sync()

    await logger.ainfo("Starting SharePoint to Blob sync",
        site_url=config.sharepoint_site_url,
        drive_name=config.sharepoint_drive_name,
        folder_path=config.sharepoint_folder_path,
        storage_account=config.storage_account_name,
        container=config.container_name,
        dry_run=config.dry_run,
        sync_permissions=config.sync_permissions,
        sync_purview_protection=config.sync_purview_protection,
        permissions_delta_mode=config.permissions_delta_mode.value,
        force_full_sync=force_full,
    )

    async with SharePointClient(config.sharepoint_site_url, config.sharepoint_drive_name) as sp_client:
        site_id, drive_id = sp_client.get_resolved_ids()
        await logger.ainfo("Resolved SharePoint IDs", site_id=site_id, drive_id=drive_id)

        async with BlobStorageClient(
            config.blob_account_url,
            config.container_name,
            config.blob_prefix,
        ) as blob_client:

            # ---- Try delta (incremental) sync ---- #
            delta_link: str | None = None
            if not force_full:
                delta_link = await blob_client.load_delta_token()

            if delta_link or not force_full:
                # Use delta API (delta_link=None → initial delta crawl,
                # delta_link=<url> → incremental delta)
                stats.sync_mode = "delta-initial" if delta_link is None else "delta-incremental"
                await logger.ainfo("Using delta sync", mode=stats.sync_mode)

                delta_result = await sp_client.get_delta(delta_link=delta_link)

                # Track files that were uploaded/updated so we can sync their permissions
                changed_files: List[SharePointFile] = []

                for change in delta_result.changes:
                    stats.files_scanned += 1

                    # Apply folder-scope filter. Graph drive delta returns the
                    # WHOLE drive; SHAREPOINT_FOLDER_PATH must be honored here
                    # too (otherwise out-of-scope files get synced).
                    if not _path_in_scope(change.item_path, config.sharepoint_folder_paths):
                        continue

                    # Apply extension filter for created/modified events.
                    # Deletes are always processed so orphan blobs in scope
                    # get removed when their source is deleted upstream.
                    if change.change_type == DeltaChangeType.CREATED_OR_MODIFIED:
                        fname = getattr(change.file, "name", "") if change.file else ""
                        if not _ext_filter_allows(
                            fname,
                            config.include_extensions,
                            config.exclude_extensions,
                        ):
                            continue

                    if change.change_type == DeltaChangeType.DELETED:
                        # File deleted in SharePoint → delete blob
                        blob_name = blob_client._get_blob_name(change.item_path)
                        await logger.ainfo("Delta: file deleted",
                            item_id=change.item_id,
                            path=change.item_path,
                        )
                        if config.delete_orphaned_blobs:
                            try:
                                await blob_client.delete_blob(blob_name, dry_run=config.dry_run)
                                stats.files_deleted += 1
                            except Exception as e:
                                await logger.aerror("Failed to delete blob",
                                    blob_name=blob_name, error=str(e))
                                stats.files_failed += 1

                    elif change.change_type == DeltaChangeType.CREATED_OR_MODIFIED and change.file:
                        sp_file = change.file
                        blob_name = blob_client._get_blob_name(sp_file.path)
                        try:
                            await logger.ainfo("Delta: file created/modified",
                                path=sp_file.path,
                                size=sp_file.size,
                            )
                            content, rms_blocked = await _download_with_rms_fallback(
                                sp_client, sp_file.id, sp_file.path)
                            await blob_client.upload_blob(
                                sharepoint_path=sp_file.path,
                                content=content,
                                sharepoint_item_id=sp_file.id,
                                sharepoint_last_modified=sp_file.last_modified,
                                sharepoint_content_hash=sp_file.content_hash,
                                sharepoint_web_url=sp_file.web_url,
                                dry_run=config.dry_run,
                            )
                            if rms_blocked:
                                stats.rms_download_failed += 1
                                await blob_client.update_blob_metadata(
                                    blob_name, {"rms_download_blocked": "true"},
                                    dry_run=config.dry_run)
                            stats.files_added += 1
                            stats.bytes_transferred += len(content)
                            changed_files.append(sp_file)
                        except Exception as e:
                            await logger.aerror("Failed to process file",
                                sharepoint_path=sp_file.path,
                                error=str(e),
                            )
                            stats.files_failed += 1

                # Persist the new delta token for next run
                if delta_result.delta_token:
                    await blob_client.save_delta_token(
                        delta_result.delta_token, dry_run=config.dry_run)

                # ── Permissions + Purview metadata sync (optional) ──
                # Uses hash-based or graph-delta mode depending on config.
                # Purview labels are detected within these functions when enabled.
                if config.sync_permissions:
                    existing_blobs_for_perms: Dict[str, BlobFile] = {}
                    async for blob in blob_client.list_blobs():
                        existing_blobs_for_perms[blob.name] = blob
                    if config.permissions_delta_mode == PermissionsDeltaMode.HASH:
                        await _sync_permissions_hash_mode(
                            config, drive_id, sp_client, blob_client,
                            existing_blobs_for_perms, stats)
                    else:
                        await _sync_permissions_graph_delta(
                            config, drive_id, sp_client, blob_client,
                            existing_blobs_for_perms, stats)

            else:
                # ---- Full sync (fallback) ---- #
                stats.sync_mode = "full"
                await logger.ainfo("Using full sync (FORCE_FULL_SYNC=true)")

                existing_blobs: Dict[str, BlobFile] = {}
                async for blob in blob_client.list_blobs():
                    existing_blobs[blob.name] = blob
                await logger.ainfo("Found existing blobs", count=len(existing_blobs))

                seen_blob_names: Set[str] = set()
                all_files: List[SharePointFile] = []

                async for sp_file in _list_files_multi(sp_client, config.sharepoint_folder_paths, config.include_extensions, config.exclude_extensions):
                    stats.files_scanned += 1
                    blob_name = blob_client._get_blob_name(sp_file.path)
                    seen_blob_names.add(blob_name)

                    try:
                        existing_blob = existing_blobs.get(blob_name)
                        if existing_blob is None:
                            await logger.ainfo("New file detected",
                                sharepoint_path=sp_file.path, size=sp_file.size)
                            content, rms_blocked = await _download_with_rms_fallback(
                                sp_client, sp_file.id, sp_file.path)
                            await blob_client.upload_blob(
                                sharepoint_path=sp_file.path,
                                content=content,
                                sharepoint_item_id=sp_file.id,
                                sharepoint_last_modified=sp_file.last_modified,
                                sharepoint_content_hash=sp_file.content_hash,
                                sharepoint_web_url=sp_file.web_url,
                                dry_run=config.dry_run,
                            )
                            if rms_blocked:
                                stats.rms_download_failed += 1
                                await blob_client.update_blob_metadata(
                                    blob_client._get_blob_name(sp_file.path),
                                    {"rms_download_blocked": "true"},
                                    dry_run=config.dry_run)
                            stats.files_added += 1
                            stats.bytes_transferred += len(content)
                            all_files.append(sp_file)
                        elif blob_client.should_update(existing_blob, sp_file.last_modified, sp_file.content_hash):
                            await logger.ainfo("Modified file detected",
                                sharepoint_path=sp_file.path, size=sp_file.size)
                            content, rms_blocked = await _download_with_rms_fallback(
                                sp_client, sp_file.id, sp_file.path)
                            await blob_client.upload_blob(
                                sharepoint_path=sp_file.path,
                                content=content,
                                sharepoint_item_id=sp_file.id,
                                sharepoint_last_modified=sp_file.last_modified,
                                sharepoint_content_hash=sp_file.content_hash,
                                sharepoint_web_url=sp_file.web_url,
                                dry_run=config.dry_run,
                            )
                            if rms_blocked:
                                stats.rms_download_failed += 1
                                await blob_client.update_blob_metadata(
                                    blob_client._get_blob_name(sp_file.path),
                                    {"rms_download_blocked": "true"},
                                    dry_run=config.dry_run)
                            stats.files_updated += 1
                            stats.bytes_transferred += len(content)
                            all_files.append(sp_file)
                        else:
                            stats.files_unchanged += 1
                            all_files.append(sp_file)
                    except Exception as e:
                        await logger.aerror("Failed to process file",
                            sharepoint_path=sp_file.path, error=str(e))
                        stats.files_failed += 1

                # Orphan cleanup
                if config.delete_orphaned_blobs:
                    for blob_name in existing_blobs:
                        if blob_name not in seen_blob_names:
                            try:
                                await blob_client.delete_blob(blob_name, dry_run=config.dry_run)
                                stats.files_deleted += 1
                            except Exception as e:
                                await logger.aerror("Failed to delete orphaned blob",
                                    blob_name=blob_name, error=str(e))
                                stats.files_failed += 1

                # ── Permissions + Purview metadata sync (optional) ──
                if config.sync_permissions:
                    if config.permissions_delta_mode == PermissionsDeltaMode.HASH:
                        await _sync_permissions_hash_mode(
                            config, drive_id, sp_client, blob_client,
                            existing_blobs, stats)
                    else:
                        await _sync_permissions_graph_delta(
                            config, drive_id, sp_client, blob_client,
                            existing_blobs, stats)

    return stats


async def _sync_files_full_scan(
    config: Config,
    sp_client: SharePointClient,
    blob_client: BlobStorageClient,
    existing_blobs: Dict[str, BlobFile],
    seen_blob_names: Set[str],
    stats: SyncStats
) -> None:
    """
    Sync files using traditional full-scan mode.
    
    Scans all files in SharePoint and compares with existing blobs to detect
    new, modified, and unchanged files. This is the default mode.
    """
    await logger.ainfo(
        "Syncing SharePoint files using FULL SCAN mode",
        mode="full_scan"
    )
    
    async for sp_file in _list_files_multi(sp_client, config.sharepoint_folder_paths, config.include_extensions, config.exclude_extensions):
        stats.files_scanned += 1
        
        blob_name = blob_client._get_blob_name(sp_file.path)
        seen_blob_names.add(blob_name)
        
        try:
            existing_blob = existing_blobs.get(blob_name)
            
            if existing_blob is None:
                # New file - upload it
                await logger.ainfo("New file detected", 
                    sharepoint_path=sp_file.path,
                    size=sp_file.size
                )
                
                content, rms_blocked = await _download_with_rms_fallback(
                    sp_client, sp_file.id, sp_file.path)
                await blob_client.upload_blob(
                    sharepoint_path=sp_file.path,
                    content=content,
                    sharepoint_item_id=sp_file.id,
                    sharepoint_last_modified=sp_file.last_modified,
                    sharepoint_content_hash=sp_file.content_hash,
                    sharepoint_web_url=sp_file.web_url,
                    dry_run=config.dry_run
                )
                if rms_blocked:
                    stats.rms_download_failed += 1
                    await blob_client.update_blob_metadata(
                        blob_name, {"rms_download_blocked": "true"},
                        dry_run=config.dry_run)
                
                stats.files_added += 1
                stats.bytes_transferred += len(content)
            
            elif blob_client.should_update(existing_blob, sp_file.last_modified, sp_file.content_hash):
                # File has been modified - update it
                await logger.ainfo("Modified file detected",
                    sharepoint_path=sp_file.path,
                    size=sp_file.size,
                    sp_modified=sp_file.last_modified.isoformat() if sp_file.last_modified else None
                )
                
                content, rms_blocked = await _download_with_rms_fallback(
                    sp_client, sp_file.id, sp_file.path)
                await blob_client.upload_blob(
                    sharepoint_path=sp_file.path,
                    content=content,
                    sharepoint_item_id=sp_file.id,
                    sharepoint_last_modified=sp_file.last_modified,
                    sharepoint_content_hash=sp_file.content_hash,
                    sharepoint_web_url=sp_file.web_url,
                    dry_run=config.dry_run
                )
                if rms_blocked:
                    stats.rms_download_failed += 1
                    await blob_client.update_blob_metadata(
                        blob_name, {"rms_download_blocked": "true"},
                        dry_run=config.dry_run)
                
                stats.files_updated += 1
                stats.bytes_transferred += len(content)
            
            else:
                # File unchanged
                await logger.adebug("File unchanged", sharepoint_path=sp_file.path)
                stats.files_unchanged += 1
        
        except Exception as e:
            await logger.aerror("Failed to process file",
                sharepoint_path=sp_file.path,
                error=str(e)
            )
            stats.files_failed += 1


async def _sync_files_graph_delta(
    config: Config,
    drive_id: str,
    sp_client: SharePointClient,
    blob_client: BlobStorageClient,
    existing_blobs: Dict[str, BlobFile],
    seen_blob_names: Set[str],
    stats: SyncStats
) -> None:
    """
    Sync files using Microsoft Graph delta API.
    
    Uses the Graph delta API to detect changed files:
    - First run (no token): Returns all files, establishes baseline
    - Subsequent runs (with token): Returns only changed/deleted files
    
    This approach is more efficient for large document libraries as it only
    processes files that have changed since the last sync.
    
    Note: Blob metadata format remains the same as full-scan mode for compatibility.
    """
    await logger.ainfo(
        "Syncing SharePoint files using GRAPH DELTA API",
        mode="graph_delta",
        token_storage_path=config.delta_token_storage_path
    )
    
    token_storage = DeltaTokenStorage(config.delta_token_storage_path)
    
    async with GraphDeltaFilesClient(drive_id, token_storage) as delta_client:
        async for sp_file in _get_changed_files_multi(delta_client, config.sharepoint_folder_paths, config.include_extensions, config.exclude_extensions):
            stats.files_scanned += 1
            
            blob_name = blob_client._get_blob_name(sp_file.path)
            seen_blob_names.add(blob_name)
            
            try:
                if sp_file.change_type == FileChangeType.DELETED:
                    # File was deleted in SharePoint
                    if config.delete_orphaned_blobs:
                        existing_blob = existing_blobs.get(blob_name)
                        if existing_blob:
                            await logger.ainfo("Deleted file detected via delta",
                                sharepoint_path=sp_file.path,
                                blob_name=blob_name
                            )
                            await blob_client.delete_blob(blob_name, dry_run=config.dry_run)
                            stats.files_deleted += 1
                    continue
                
                elif sp_file.change_type == FileChangeType.ADDED:
                    # New file
                    await logger.ainfo("New file detected via delta",
                        sharepoint_path=sp_file.path,
                        size=sp_file.size
                    )
                    
                    content, rms_blocked = await _download_with_rms_fallback(
                        delta_client, sp_file.id, sp_file.path)
                    await blob_client.upload_blob(
                        sharepoint_path=sp_file.path,
                        content=content,
                        sharepoint_item_id=sp_file.id,
                        sharepoint_last_modified=sp_file.last_modified,
                        sharepoint_content_hash=sp_file.content_hash,
                        sharepoint_web_url=sp_file.web_url,
                        dry_run=config.dry_run
                    )
                    if rms_blocked:
                        stats.rms_download_failed += 1
                        await blob_client.update_blob_metadata(
                            blob_name, {"rms_download_blocked": "true"},
                            dry_run=config.dry_run)
                    
                    stats.files_added += 1
                    stats.bytes_transferred += len(content)
                
                elif sp_file.change_type == FileChangeType.MODIFIED:
                    # Modified file
                    await logger.ainfo("Modified file detected via delta",
                        sharepoint_path=sp_file.path,
                        size=sp_file.size
                    )
                    
                    content, rms_blocked = await _download_with_rms_fallback(
                        delta_client, sp_file.id, sp_file.path)
                    await blob_client.upload_blob(
                        sharepoint_path=sp_file.path,
                        content=content,
                        sharepoint_item_id=sp_file.id,
                        sharepoint_last_modified=sp_file.last_modified,
                        sharepoint_content_hash=sp_file.content_hash,
                        sharepoint_web_url=sp_file.web_url,
                        dry_run=config.dry_run
                    )
                    if rms_blocked:
                        stats.rms_download_failed += 1
                        await blob_client.update_blob_metadata(
                            blob_name, {"rms_download_blocked": "true"},
                            dry_run=config.dry_run)
                    
                    stats.files_updated += 1
                    stats.bytes_transferred += len(content)
            
            except Exception as e:
                await logger.aerror("Failed to process file",
                    sharepoint_path=sp_file.path,
                    error=str(e)
                )
                stats.files_failed += 1


async def _sync_permissions_hash_mode(
    config: Config,
    drive_id: str,
    sp_client: SharePointClient,
    blob_client: BlobStorageClient,
    existing_blobs: Dict[str, BlobFile],
    stats: SyncStats
) -> None:
    """
    Sync permissions using hash-based delta detection.
    
    Computes a hash of permissions and only syncs if the hash has changed.
    This is the default mode and works well for most scenarios.
    
    When SYNC_PURVIEW_PROTECTION=true, also detects Purview sensitivity labels
    and RMS encryption, merging those permissions with SharePoint permissions
    for security-trimmed AI Search indexing.
    """
    sync_purview = config.sync_purview_protection
    
    await logger.ainfo(
        "Syncing SharePoint permissions using HASH-based delta detection",
        mode="hash",
        sync_purview=sync_purview,
    )
    
    # Optionally create Purview client for RMS protection detection
    purview_client = None
    if sync_purview:
        purview_client = PurviewClient(drive_id)
        await purview_client.__aenter__()
    
    try:
        async with PermissionsClient(drive_id) as perm_client:
            # Re-scan files to get their permissions
            async for sp_file in _list_files_multi(sp_client, config.sharepoint_folder_paths, config.include_extensions, config.exclude_extensions):
                blob_name = blob_client._get_blob_name(sp_file.path)
                
                try:
                    # Get permissions from SharePoint
                    file_permissions = await perm_client.get_file_permissions(
                        file_id=sp_file.id,
                        file_path=sp_file.path
                    )
                    
                    # Get Purview/RMS protection info if enabled
                    protection_info = None
                    if purview_client:
                        try:
                            protection_info = await purview_client.get_file_protection(
                                file_id=sp_file.id,
                                file_path=sp_file.path,
                            )
                            # Track Purview stats
                            if protection_info.status == ProtectionStatus.PROTECTED:
                                stats.purview_protected += 1
                            elif protection_info.status == ProtectionStatus.LABEL_ONLY:
                                stats.purview_label_only += 1
                            elif protection_info.status == ProtectionStatus.UNPROTECTED:
                                stats.purview_unprotected += 1
                        except Exception as e:
                            await logger.aerror("Purview detection failed",
                                file_path=sp_file.path, error=str(e))
                            stats.purview_failed += 1
                    
                    if file_permissions.permissions:
                        # Get existing blob metadata to check for permission changes
                        existing_blob = existing_blobs.get(blob_name)
                        existing_metadata = existing_blob.metadata if existing_blob else None
                        
                        # Check if permissions have actually changed (delta detection)
                        if should_sync_permissions(file_permissions, existing_metadata):
                            # Convert to metadata with Purview/RMS merge
                            perm_metadata = file_permissions.to_metadata(
                                protection_info=protection_info
                            )
                            
                            await logger.ainfo("Syncing permissions (changed)",
                                file_path=sp_file.path,
                                permission_count=len(file_permissions.permissions),
                                summary=permissions_to_summary(file_permissions.permissions),
                                purview_status=protection_info.status.value if protection_info else "not_checked",
                            )
                            
                            await blob_client.update_blob_metadata(
                                blob_name=blob_name,
                                additional_metadata=perm_metadata,
                                dry_run=config.dry_run
                            )
                            
                            stats.permissions_synced += 1
                        else:
                            # Permissions unchanged, skip update
                            await logger.adebug("Permissions unchanged (skipped)", file_path=sp_file.path)
                            stats.permissions_unchanged += 1
                    else:
                        await logger.adebug("No permissions to sync", file_path=sp_file.path)
                        
                except Exception as e:
                    await logger.aerror("Failed to sync permissions",
                        file_path=sp_file.path,
                        error=str(e)
                    )
                    stats.permissions_failed += 1
    finally:
        if purview_client:
            await purview_client.__aexit__(None, None, None)


async def _sync_permissions_graph_delta(
    config: Config,
    drive_id: str,
    sp_client: SharePointClient,
    blob_client: BlobStorageClient,
    existing_blobs: Dict[str, BlobFile],
    stats: SyncStats
) -> None:
    """
    Sync permissions using Microsoft Graph delta API.
    
    Uses the Graph delta API with special headers to detect permission changes:
    - Prefer: deltashowsharingchanges - Annotates items with @microsoft.graph.sharedChanged
    - Prefer: hierarchicalsharing - Efficient permission hierarchy tracking
    
    This approach is more efficient for large document libraries as it only
    queries items that have changed since the last sync.
    
    Note: Requires Sites.FullControl.All permission for proper operation.
    
    When SYNC_PURVIEW_PROTECTION=true, also detects Purview sensitivity labels
    and RMS encryption, merging those permissions with SharePoint permissions.
    """
    sync_purview = config.sync_purview_protection
    
    await logger.ainfo(
        "Syncing SharePoint permissions using GRAPH DELTA API",
        mode="graph_delta",
        token_storage_path=config.delta_token_storage_path,
        sync_purview=sync_purview,
    )
    
    # Initialize delta token storage and client
    token_storage = DeltaTokenStorage(config.delta_token_storage_path)
    
    # Build a map of item_id to SharePoint file info (we need this to map delta items back to files)
    file_id_to_info: Dict[str, SharePointFile] = {}
    await logger.ainfo("Building file ID index for delta mapping...")
    async for sp_file in _list_files_multi(sp_client, config.sharepoint_folder_paths, config.include_extensions, config.exclude_extensions):
        file_id_to_info[sp_file.id] = sp_file
    await logger.ainfo("File ID index built", file_count=len(file_id_to_info))

    # Optionally create Purview client for RMS protection detection
    purview_client = None
    if sync_purview:
        purview_client = PurviewClient(drive_id)
        await purview_client.__aenter__()

    try:
        async with GraphDeltaPermissionsClient(drive_id, token_storage) as delta_client:
            async with PermissionsClient(drive_id) as perm_client:
                items_to_sync = []
                
                # Collect items with permission changes from delta API
                async for changed_item in delta_client.get_items_with_permission_changes():
                    items_to_sync.append(changed_item)
                
                await logger.ainfo(
                    "Delta query completed",
                    items_to_sync=len(items_to_sync)
                )
                
                # Process each item that has permission changes
                for changed_item in items_to_sync:
                    # Look up the file info
                    sp_file = file_id_to_info.get(changed_item.item_id)
                    
                    if not sp_file:
                        # Item might be in a subfolder we haven't indexed, skip it
                        await logger.adebug(
                            "Skipping item not in file index",
                            item_id=changed_item.item_id,
                            path=changed_item.path
                        )
                        continue
                    
                    blob_name = blob_client._get_blob_name(sp_file.path)
                    
                    try:
                        # Get current permissions from SharePoint
                        file_permissions = await perm_client.get_file_permissions(
                            file_id=sp_file.id,
                            file_path=sp_file.path
                        )
                        
                        # Get Purview/RMS protection info if enabled
                        protection_info = None
                        if purview_client:
                            try:
                                protection_info = await purview_client.get_file_protection(
                                    file_id=sp_file.id,
                                    file_path=sp_file.path,
                                )
                                if protection_info.status == ProtectionStatus.PROTECTED:
                                    stats.purview_protected += 1
                                elif protection_info.status == ProtectionStatus.LABEL_ONLY:
                                    stats.purview_label_only += 1
                                elif protection_info.status == ProtectionStatus.UNPROTECTED:
                                    stats.purview_unprotected += 1
                            except Exception as e:
                                await logger.aerror("Purview detection failed",
                                    file_path=sp_file.path, error=str(e))
                                stats.purview_failed += 1
                        
                        if file_permissions.permissions:
                            # Convert to metadata with Purview/RMS merge
                            perm_metadata = file_permissions.to_metadata(
                                protection_info=protection_info
                            )
                            
                            await logger.ainfo("Syncing permissions (delta changed)",
                                file_path=sp_file.path,
                                permission_count=len(file_permissions.permissions),
                                summary=permissions_to_summary(file_permissions.permissions),
                                sharing_changed=changed_item.sharing_changed,
                                purview_status=protection_info.status.value if protection_info else "not_checked",
                            )
                            
                            await blob_client.update_blob_metadata(
                                blob_name=blob_name,
                                additional_metadata=perm_metadata,
                                dry_run=config.dry_run
                            )
                            
                            stats.permissions_synced += 1
                        else:
                            await logger.adebug("No permissions to sync", file_path=sp_file.path)
                            
                    except Exception as e:
                        await logger.aerror("Failed to sync permissions",
                            file_path=sp_file.path,
                            error=str(e)
                        )
                        stats.permissions_failed += 1
                
                # Calculate unchanged (items not in delta = unchanged)
                stats.permissions_unchanged = len(file_id_to_info) - len(items_to_sync)
    finally:
        if purview_client:
            await purview_client.__aexit__(None, None, None)


async def main() -> int:
    """Main entry point for the sync job."""
    try:
        # Load and validate configuration
        config = Config.from_environment()
        config.validate()
        
        # Run the sync
        stats = await sync_sharepoint_to_blob(config)
        
        # Log final statistics
        await logger.ainfo("Sync completed",
            sync_mode=stats.sync_mode,
            files_scanned=stats.files_scanned,
            files_added=stats.files_added,
            files_updated=stats.files_updated,
            files_deleted=stats.files_deleted,
            files_unchanged=stats.files_unchanged,
            files_failed=stats.files_failed,
            bytes_transferred=stats.bytes_transferred,
            permissions_synced=stats.permissions_synced,
            permissions_unchanged=stats.permissions_unchanged,
            permissions_failed=stats.permissions_failed,
            purview_protected=stats.purview_protected,
            purview_label_only=stats.purview_label_only,
            purview_unprotected=stats.purview_unprotected,
            purview_failed=stats.purview_failed,
            rms_download_failed=stats.rms_download_failed,
        )
        
        # Return non-zero exit code if there were failures
        if stats.files_failed > 0 or stats.permissions_failed > 0:
            await logger.awarning("Sync completed with failures", 
                                 files_failed=stats.files_failed,
                                 permissions_failed=stats.permissions_failed)
            return 1
        
        return 0
    
    except ValueError as e:
        await logger.aerror("Configuration error", error=str(e))
        return 2
    
    except Exception as e:
        await logger.aerror("Unexpected error during sync", error=str(e), exc_info=True)
        return 1


if __name__ == "__main__":
    exit_code = asyncio.run(main())
    sys.exit(exit_code)
