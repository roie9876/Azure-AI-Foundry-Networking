using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Extensions.Logging;
using SharePointSyncFunc.Clients;
using SharePointSyncFunc.Configuration;
using SharePointSyncFunc.Models;

namespace SharePointSyncFunc.Services;

/// <summary>
/// Top-level sync orchestrator. Equivalent to Python main.py — picks delta vs.
/// full sync, applies folder/extension filters, syncs permissions and Purview
/// metadata, and aggregates stats.
/// </summary>
public sealed class SyncOrchestrator
{
    private static readonly string[] RmsErrorIndicators =
    {
        "access denied", "403", "forbidden",
        "locked", "423",
        "drm", "rights management",
        "encrypted", "protection",
        "the file is encrypted",
    };

    private readonly ILogger<SyncOrchestrator> _logger;
    private readonly ILoggerFactory _loggerFactory;

    public SyncOrchestrator(ILogger<SyncOrchestrator> logger, ILoggerFactory loggerFactory)
    {
        _logger = logger;
        _loggerFactory = loggerFactory;
    }

    public async Task<SyncStats> RunAsync(CancellationToken cancellationToken = default)
    {
        var config = SyncConfig.FromEnvironment();
        config.Validate();
        return await SyncSharePointToBlobAsync(config, cancellationToken).ConfigureAwait(false);
    }

    public async Task<SyncStats> SyncSharePointToBlobAsync(SyncConfig config, CancellationToken cancellationToken)
    {
        var stats = new SyncStats();
        var forceFull = ForceFullSync();

        _logger.LogInformation(
            "Starting SharePoint to Blob sync (site={Site}, drive={Drive}, folder={Folder}, " +
            "storage={Storage}, container={Container}, dry_run={DryRun}, sync_perm={SyncPerm}, " +
            "sync_purview={SyncPurview}, perm_delta_mode={PermMode}, force_full={ForceFull})",
            config.SharePointSiteUrl, config.SharePointDriveName, config.SharePointFolderPath,
            config.StorageAccountName, config.ContainerName, config.DryRun, config.SyncPermissions,
            config.SyncPurviewProtection, config.PermissionsDeltaMode, forceFull);

        await using var spClient = new SharePointClient(
            config.SharePointSiteUrl, config.SharePointDriveName,
            _loggerFactory.CreateLogger<SharePointClient>());
        await spClient.InitializeAsync(cancellationToken).ConfigureAwait(false);
        var (siteId, driveId) = spClient.GetResolvedIds();
        _logger.LogInformation("Resolved SharePoint IDs (site_id={Site}, drive_id={Drive})", siteId, driveId);

        await using var blobClient = new BlobStorageClient(
            config.BlobAccountUrl, config.ContainerName, config.BlobPrefix,
            _loggerFactory.CreateLogger<BlobStorageClient>());
        await blobClient.InitializeAsync(cancellationToken).ConfigureAwait(false);

        string? deltaLink = null;
        if (!forceFull)
        {
            deltaLink = await blobClient.LoadDeltaTokenAsync(cancellationToken).ConfigureAwait(false);
        }

        if (!forceFull)
        {
            stats.SyncMode = deltaLink is null ? "delta-initial" : "delta-incremental";
            _logger.LogInformation("Using delta sync (mode={Mode})", stats.SyncMode);

            var deltaResult = await spClient.GetDeltaAsync(deltaLink, cancellationToken).ConfigureAwait(false);
            var changedFiles = new List<SharePointFile>();

            foreach (var change in deltaResult.Changes)
            {
                stats.FilesScanned++;

                if (!PathInScope(change.ItemPath, config.SharePointFolderPaths))
                {
                    continue;
                }

                if (change.ChangeType == DeltaChangeType.CreatedOrModified)
                {
                    var fname = change.File?.Name ?? string.Empty;
                    if (!ExtFilterAllows(fname, config.IncludeExtensions, config.ExcludeExtensions))
                    {
                        continue;
                    }
                }

                if (change.ChangeType == DeltaChangeType.Deleted)
                {
                    var blobName = blobClient.GetBlobName(change.ItemPath);
                    _logger.LogInformation("Delta: file deleted (item_id={Id}, path={Path})",
                        change.ItemId, change.ItemPath);

                    if (config.DeleteOrphanedBlobs)
                    {
                        try
                        {
                            if (config.SoftDeleteOrphanedBlobs)
                            {
                                await blobClient.SoftDeleteBlobAsync(blobName, config.DryRun, cancellationToken)
                                    .ConfigureAwait(false);
                            }
                            else
                            {
                                await blobClient.DeleteBlobAsync(blobName, config.DryRun, cancellationToken)
                                    .ConfigureAwait(false);
                            }
                            stats.FilesDeleted++;
                        }
                        catch (Exception ex)
                        {
                            _logger.LogError(ex, "Failed to delete blob (blob_name={Name})", blobName);
                            stats.FilesFailed++;
                        }
                    }
                }
                else if (change.ChangeType == DeltaChangeType.CreatedOrModified && change.File is { } spFile)
                {
                    var blobName = blobClient.GetBlobName(spFile.Path);
                    try
                    {
                        _logger.LogInformation("Delta: file created/modified (path={Path}, size={Size})",
                            spFile.Path, spFile.Size);

                        var (content, rmsBlocked) = await DownloadWithRmsFallbackAsync(
                            spClient, spFile.Id, spFile.Path, cancellationToken).ConfigureAwait(false);

                        await blobClient.UploadBlobAsync(
                            spFile.Path, content, spFile.Id, spFile.LastModified,
                            spFile.ContentHash, spFile.WebUrl, config.DryRun, cancellationToken)
                            .ConfigureAwait(false);

                        if (rmsBlocked)
                        {
                            stats.RmsDownloadFailed++;
                            await blobClient.UpdateBlobMetadataAsync(
                                blobName,
                                new Dictionary<string, string> { ["rms_download_blocked"] = "true" },
                                config.DryRun, cancellationToken).ConfigureAwait(false);
                        }
                        stats.FilesAdded++;
                        stats.BytesTransferred += content.Length;
                        changedFiles.Add(spFile);
                    }
                    catch (Exception ex)
                    {
                        _logger.LogError(ex, "Failed to process file (path={Path})", spFile.Path);
                        stats.FilesFailed++;
                    }
                }
            }

            if (!string.IsNullOrEmpty(deltaResult.DeltaToken))
            {
                await blobClient.SaveDeltaTokenAsync(deltaResult.DeltaToken, config.DryRun, cancellationToken)
                    .ConfigureAwait(false);
            }

            if (config.SyncPermissions)
            {
                var existingBlobsForPerms = new Dictionary<string, BlobFile>();
                await foreach (var blob in blobClient.ListBlobsAsync(cancellationToken).ConfigureAwait(false))
                {
                    existingBlobsForPerms[blob.Name] = blob;
                }

                if (config.PermissionsDeltaMode == PermissionsDeltaMode.Hash)
                {
                    await SyncPermissionsHashModeAsync(config, driveId, spClient, blobClient,
                        existingBlobsForPerms, stats, cancellationToken).ConfigureAwait(false);
                }
                else
                {
                    await SyncPermissionsGraphDeltaAsync(config, driveId, spClient, blobClient,
                        existingBlobsForPerms, stats, cancellationToken).ConfigureAwait(false);
                }
            }
        }
        else
        {
            stats.SyncMode = "full";
            _logger.LogInformation("Using full sync (FORCE_FULL_SYNC=true)");

            var existingBlobs = new Dictionary<string, BlobFile>();
            await foreach (var blob in blobClient.ListBlobsAsync(cancellationToken).ConfigureAwait(false))
            {
                existingBlobs[blob.Name] = blob;
            }
            _logger.LogInformation("Found existing blobs (count={Count})", existingBlobs.Count);

            var seenBlobNames = new HashSet<string>();
            var allFiles = new List<SharePointFile>();

            await foreach (var spFile in ListFilesMultiAsync(
                spClient, config.SharePointFolderPaths, config.IncludeExtensions, config.ExcludeExtensions,
                cancellationToken).ConfigureAwait(false))
            {
                stats.FilesScanned++;
                var blobName = blobClient.GetBlobName(spFile.Path);
                seenBlobNames.Add(blobName);

                try
                {
                    if (!existingBlobs.TryGetValue(blobName, out var existingBlob))
                    {
                        _logger.LogInformation("New file detected (path={Path}, size={Size})",
                            spFile.Path, spFile.Size);
                        var (content, rmsBlocked) = await DownloadWithRmsFallbackAsync(
                            spClient, spFile.Id, spFile.Path, cancellationToken).ConfigureAwait(false);
                        await blobClient.UploadBlobAsync(
                            spFile.Path, content, spFile.Id, spFile.LastModified,
                            spFile.ContentHash, spFile.WebUrl, config.DryRun, cancellationToken)
                            .ConfigureAwait(false);
                        if (rmsBlocked)
                        {
                            stats.RmsDownloadFailed++;
                            await blobClient.UpdateBlobMetadataAsync(
                                blobName,
                                new Dictionary<string, string> { ["rms_download_blocked"] = "true" },
                                config.DryRun, cancellationToken).ConfigureAwait(false);
                        }
                        stats.FilesAdded++;
                        stats.BytesTransferred += content.Length;
                        allFiles.Add(spFile);
                    }
                    else if (blobClient.ShouldUpdate(existingBlob, spFile.LastModified, spFile.ContentHash))
                    {
                        _logger.LogInformation("Modified file detected (path={Path}, size={Size})",
                            spFile.Path, spFile.Size);
                        var (content, rmsBlocked) = await DownloadWithRmsFallbackAsync(
                            spClient, spFile.Id, spFile.Path, cancellationToken).ConfigureAwait(false);
                        await blobClient.UploadBlobAsync(
                            spFile.Path, content, spFile.Id, spFile.LastModified,
                            spFile.ContentHash, spFile.WebUrl, config.DryRun, cancellationToken)
                            .ConfigureAwait(false);
                        if (rmsBlocked)
                        {
                            stats.RmsDownloadFailed++;
                            await blobClient.UpdateBlobMetadataAsync(
                                blobName,
                                new Dictionary<string, string> { ["rms_download_blocked"] = "true" },
                                config.DryRun, cancellationToken).ConfigureAwait(false);
                        }
                        stats.FilesUpdated++;
                        stats.BytesTransferred += content.Length;
                        allFiles.Add(spFile);
                    }
                    else
                    {
                        stats.FilesUnchanged++;
                        allFiles.Add(spFile);
                    }
                }
                catch (Exception ex)
                {
                    _logger.LogError(ex, "Failed to process file (path={Path})", spFile.Path);
                    stats.FilesFailed++;
                }
            }

            if (config.DeleteOrphanedBlobs)
            {
                foreach (var blobName in existingBlobs.Keys)
                {
                    if (!seenBlobNames.Contains(blobName))
                    {
                        try
                        {
                            if (config.SoftDeleteOrphanedBlobs)
                            {
                                await blobClient.SoftDeleteBlobAsync(blobName, config.DryRun, cancellationToken)
                                    .ConfigureAwait(false);
                            }
                            else
                            {
                                await blobClient.DeleteBlobAsync(blobName, config.DryRun, cancellationToken)
                                    .ConfigureAwait(false);
                            }
                            stats.FilesDeleted++;
                        }
                        catch (Exception ex)
                        {
                            _logger.LogError(ex, "Failed to delete orphaned blob (blob_name={Name})", blobName);
                            stats.FilesFailed++;
                        }
                    }
                }
            }

            if (config.SyncPermissions)
            {
                if (config.PermissionsDeltaMode == PermissionsDeltaMode.Hash)
                {
                    await SyncPermissionsHashModeAsync(config, driveId, spClient, blobClient,
                        existingBlobs, stats, cancellationToken).ConfigureAwait(false);
                }
                else
                {
                    await SyncPermissionsGraphDeltaAsync(config, driveId, spClient, blobClient,
                        existingBlobs, stats, cancellationToken).ConfigureAwait(false);
                }
            }
        }

        return stats;
    }

    private static bool ForceFullSync()
    {
        var raw = Environment.GetEnvironmentVariable("FORCE_FULL_SYNC");
        return !string.IsNullOrEmpty(raw) && raw.Trim().Equals("true", StringComparison.OrdinalIgnoreCase);
    }

    private static bool ExtFilterAllows(string filename, List<string> includeExts, List<string> excludeExts)
    {
        if (string.IsNullOrEmpty(filename))
        {
            return true;
        }
        var lower = filename.ToLowerInvariant();
        if (excludeExts.Count > 0)
        {
            foreach (var e in excludeExts)
            {
                if (lower.EndsWith(e, StringComparison.Ordinal))
                {
                    return false;
                }
            }
        }
        if (includeExts.Count > 0)
        {
            foreach (var e in includeExts)
            {
                if (lower.EndsWith(e, StringComparison.Ordinal))
                {
                    return true;
                }
            }
            return false;
        }
        return true;
    }

    private static bool PathInScope(string itemPath, List<string> folderPaths)
    {
        if (folderPaths.Count == 0)
        {
            return true;
        }

        var normalized = new List<string>();
        foreach (var fp in folderPaths)
        {
            var trimmed = (fp ?? string.Empty).Trim();
            if (trimmed == string.Empty || trimmed == "/")
            {
                return true;
            }
            normalized.Add("/" + trimmed.Trim('/').ToLowerInvariant());
        }

        var item = "/" + (itemPath ?? string.Empty).TrimStart('/').ToLowerInvariant();
        foreach (var scope in normalized)
        {
            if (item == scope || item.StartsWith(scope + "/", StringComparison.Ordinal))
            {
                return true;
            }
        }
        return false;
    }

    private async Task<(byte[] Content, bool RmsBlocked)> DownloadWithRmsFallbackAsync(
        SharePointClient spClient, string fileId, string filePath, CancellationToken cancellationToken)
    {
        try
        {
            var content = await spClient.DownloadFileAsync(fileId, cancellationToken).ConfigureAwait(false);
            return (content, false);
        }
        catch (Exception ex)
        {
            var msg = (ex.Message ?? string.Empty).ToLowerInvariant();
            foreach (var ind in RmsErrorIndicators)
            {
                if (msg.Contains(ind, StringComparison.Ordinal))
                {
                    _logger.LogWarning(
                        "File download blocked by RMS encryption — uploading empty placeholder " +
                        "(file_path={Path}, error={Error})", filePath, ex.Message);
                    return (Array.Empty<byte>(), true);
                }
            }
            throw;
        }
    }

    private async IAsyncEnumerable<SharePointFile> ListFilesMultiAsync(
        SharePointClient spClient,
        List<string> folderPaths,
        List<string> includeExts,
        List<string> excludeExts,
        [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        foreach (var folderPath in folderPaths)
        {
            _logger.LogInformation("Listing files from folder (folder_path={Path})", folderPath);
            await foreach (var spFile in spClient.ListFilesAsync(folderPath, cancellationToken).ConfigureAwait(false))
            {
                if (!ExtFilterAllows(spFile.Name ?? string.Empty, includeExts, excludeExts))
                {
                    continue;
                }
                yield return spFile;
            }
        }
    }

    private async Task SyncPermissionsHashModeAsync(
        SyncConfig config, string driveId,
        SharePointClient spClient, BlobStorageClient blobClient,
        Dictionary<string, BlobFile> existingBlobs, SyncStats stats,
        CancellationToken cancellationToken)
    {
        var syncPurview = config.SyncPurviewProtection;
        _logger.LogInformation(
            "Syncing SharePoint permissions using HASH-based delta detection (sync_purview={SyncPurview})",
            syncPurview);

        PurviewClient? purview = null;
        if (syncPurview)
        {
            purview = new PurviewClient(driveId, _loggerFactory.CreateLogger<PurviewClient>());
            await purview.InitializeAsync(cancellationToken).ConfigureAwait(false);
        }

        try
        {
            await using var permClient = new PermissionsClient(driveId, _loggerFactory.CreateLogger<PermissionsClient>());

            await foreach (var spFile in ListFilesMultiAsync(
                spClient, config.SharePointFolderPaths, config.IncludeExtensions, config.ExcludeExtensions,
                cancellationToken).ConfigureAwait(false))
            {
                var blobName = blobClient.GetBlobName(spFile.Path);
                try
                {
                    var filePermissions = await permClient.GetFilePermissionsAsync(
                        spFile.Id, spFile.Path, cancellationToken).ConfigureAwait(false);

                    FileProtectionInfo? protectionInfo = null;
                    if (purview is not null)
                    {
                        try
                        {
                            protectionInfo = await purview.GetFileProtectionAsync(
                                spFile.Id, spFile.Path, cancellationToken).ConfigureAwait(false);
                            switch (protectionInfo.Status)
                            {
                                case ProtectionStatus.Protected: stats.PurviewProtected++; break;
                                case ProtectionStatus.LabelOnly: stats.PurviewLabelOnly++; break;
                                case ProtectionStatus.Unprotected: stats.PurviewUnprotected++; break;
                            }
                        }
                        catch (Exception ex)
                        {
                            _logger.LogError(ex, "Purview detection failed (file_path={Path})", spFile.Path);
                            stats.PurviewFailed++;
                        }
                    }

                    if (filePermissions.Permissions.Count > 0)
                    {
                        existingBlobs.TryGetValue(blobName, out var existingBlob);
                        var existingMetadata = existingBlob?.Metadata;

                        if (PermissionsHelpers.ShouldSyncPermissions(filePermissions, existingMetadata))
                        {
                            var permMetadata = filePermissions.ToMetadata(protectionInfo);
                            _logger.LogInformation(
                                "Syncing permissions (changed) (file_path={Path}, count={Count}, summary={Summary}, purview={Purview})",
                                spFile.Path, filePermissions.Permissions.Count,
                                PermissionsHelpers.PermissionsToSummary(filePermissions.Permissions),
                                protectionInfo?.Status.ToValue() ?? "not_checked");

                            await blobClient.UpdateBlobMetadataAsync(blobName, permMetadata, config.DryRun, cancellationToken)
                                .ConfigureAwait(false);
                            stats.PermissionsSynced++;
                        }
                        else
                        {
                            _logger.LogDebug("Permissions unchanged (skipped) (file_path={Path})", spFile.Path);
                            stats.PermissionsUnchanged++;
                        }
                    }
                    else
                    {
                        _logger.LogDebug("No permissions to sync (file_path={Path})", spFile.Path);
                    }
                }
                catch (Exception ex)
                {
                    _logger.LogError(ex, "Failed to sync permissions (file_path={Path})", spFile.Path);
                    stats.PermissionsFailed++;
                }
            }
        }
        finally
        {
            if (purview is not null)
            {
                await purview.DisposeAsync().ConfigureAwait(false);
            }
        }
    }

    private async Task SyncPermissionsGraphDeltaAsync(
        SyncConfig config, string driveId,
        SharePointClient spClient, BlobStorageClient blobClient,
        Dictionary<string, BlobFile> existingBlobs, SyncStats stats,
        CancellationToken cancellationToken)
    {
        var syncPurview = config.SyncPurviewProtection;
        _logger.LogInformation(
            "Syncing SharePoint permissions using GRAPH DELTA API (storage_path={Path}, sync_purview={SyncPurview})",
            config.DeltaTokenStoragePath, syncPurview);

        var tokenStorage = new DeltaTokenStorage(config.DeltaTokenStoragePath, _logger);

        var fileIdToInfo = new Dictionary<string, SharePointFile>();
        _logger.LogInformation("Building file ID index for delta mapping...");
        await foreach (var spFile in ListFilesMultiAsync(
            spClient, config.SharePointFolderPaths, config.IncludeExtensions, config.ExcludeExtensions,
            cancellationToken).ConfigureAwait(false))
        {
            fileIdToInfo[spFile.Id] = spFile;
        }
        _logger.LogInformation("File ID index built (file_count={Count})", fileIdToInfo.Count);

        PurviewClient? purview = null;
        if (syncPurview)
        {
            purview = new PurviewClient(driveId, _loggerFactory.CreateLogger<PurviewClient>());
            await purview.InitializeAsync(cancellationToken).ConfigureAwait(false);
        }

        try
        {
            await using var deltaClient = new GraphDeltaPermissionsClient(
                driveId, tokenStorage, _loggerFactory.CreateLogger<GraphDeltaPermissionsClient>());
            await using var permClient = new PermissionsClient(
                driveId, _loggerFactory.CreateLogger<PermissionsClient>());

            var itemsToSync = new List<PermissionChangedItem>();
            await foreach (var changed in deltaClient.GetItemsWithPermissionChangesAsync(cancellationToken)
                .ConfigureAwait(false))
            {
                itemsToSync.Add(changed);
            }
            _logger.LogInformation("Delta query completed (items_to_sync={Count})", itemsToSync.Count);

            foreach (var changedItem in itemsToSync)
            {
                if (!fileIdToInfo.TryGetValue(changedItem.ItemId, out var spFile))
                {
                    _logger.LogDebug("Skipping item not in file index (item_id={Id}, path={Path})",
                        changedItem.ItemId, changedItem.Path);
                    continue;
                }

                var blobName = blobClient.GetBlobName(spFile.Path);
                try
                {
                    var filePermissions = await permClient.GetFilePermissionsAsync(
                        spFile.Id, spFile.Path, cancellationToken).ConfigureAwait(false);

                    FileProtectionInfo? protectionInfo = null;
                    if (purview is not null)
                    {
                        try
                        {
                            protectionInfo = await purview.GetFileProtectionAsync(
                                spFile.Id, spFile.Path, cancellationToken).ConfigureAwait(false);
                            switch (protectionInfo.Status)
                            {
                                case ProtectionStatus.Protected: stats.PurviewProtected++; break;
                                case ProtectionStatus.LabelOnly: stats.PurviewLabelOnly++; break;
                                case ProtectionStatus.Unprotected: stats.PurviewUnprotected++; break;
                            }
                        }
                        catch (Exception ex)
                        {
                            _logger.LogError(ex, "Purview detection failed (file_path={Path})", spFile.Path);
                            stats.PurviewFailed++;
                        }
                    }

                    if (filePermissions.Permissions.Count > 0)
                    {
                        var permMetadata = filePermissions.ToMetadata(protectionInfo);
                        _logger.LogInformation(
                            "Syncing permissions (delta changed) (file_path={Path}, count={Count}, summary={Summary}, " +
                            "sharing_changed={Changed}, purview={Purview})",
                            spFile.Path, filePermissions.Permissions.Count,
                            PermissionsHelpers.PermissionsToSummary(filePermissions.Permissions),
                            changedItem.SharingChanged,
                            protectionInfo?.Status.ToValue() ?? "not_checked");
                        await blobClient.UpdateBlobMetadataAsync(blobName, permMetadata, config.DryRun, cancellationToken)
                            .ConfigureAwait(false);
                        stats.PermissionsSynced++;
                    }
                    else
                    {
                        _logger.LogDebug("No permissions to sync (file_path={Path})", spFile.Path);
                    }
                }
                catch (Exception ex)
                {
                    _logger.LogError(ex, "Failed to sync permissions (file_path={Path})", spFile.Path);
                    stats.PermissionsFailed++;
                }
            }

            stats.PermissionsUnchanged = fileIdToInfo.Count - itemsToSync.Count;
        }
        finally
        {
            if (purview is not null)
            {
                await purview.DisposeAsync().ConfigureAwait(false);
            }
        }
    }
}
