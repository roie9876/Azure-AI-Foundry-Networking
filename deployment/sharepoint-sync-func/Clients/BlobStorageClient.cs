using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Azure;
using Azure.Storage.Blobs;
using Azure.Storage.Blobs.Models;
using Microsoft.Extensions.Logging;
using SharePointSyncFunc.Models;

namespace SharePointSyncFunc.Clients;

/// <summary>
/// Azure Blob Storage client mirroring the Python BlobStorageClient. Handles
/// upload/download/delete, soft-delete via metadata, metadata merge, and
/// delta-token persistence used by the drive-level delta sync.
/// </summary>
public sealed class BlobStorageClient : IAsyncDisposable
{
    public const string MetadataSpItemId = "sharepoint_item_id";
    public const string MetadataSpLastModified = "sharepoint_last_modified";
    public const string MetadataSpContentHash = "sharepoint_content_hash";
    public const string MetadataSpWebUrl = "sharepoint_web_url";
    public const string MetadataAclUserIds = "acl_user_ids";
    public const string MetadataAclGroupIds = "acl_group_ids";
    public const string MetadataPermissionsHash = "permissions_hash";
    public const string DeltaTokenBlob = ".sync-state/delta-token.json";

    private static readonly string[] DeprecatedFields =
    {
        "metadata_user_ids", "metadata_group_ids",
        "acl_user_ids_list", "acl_group_ids_list",
        "metadata_acl_user_ids", "metdata_acl_group_ids",
    };

    private readonly string _accountUrl;
    private readonly string _containerName;
    private readonly string _blobPrefix;
    private readonly ILogger _logger;
    private readonly BlobServiceClient _serviceClient;
    private readonly BlobContainerClient _containerClient;

    public BlobStorageClient(string accountUrl, string containerName, string blobPrefix, ILogger logger)
    {
        _accountUrl = accountUrl;
        _containerName = containerName;
        _blobPrefix = (blobPrefix ?? string.Empty).Trim('/');
        _logger = logger;
        var credential = CredentialFactory.GetBlobCredential(logger);
        _serviceClient = new BlobServiceClient(new Uri(accountUrl), credential);
        _containerClient = _serviceClient.GetBlobContainerClient(_containerName);
    }

    public async Task InitializeAsync(CancellationToken cancellationToken = default)
    {
        try
        {
            await _containerClient.CreateIfNotExistsAsync(cancellationToken: cancellationToken).ConfigureAwait(false);
            _logger.LogInformation("Ensured container exists (container={Container})", _containerName);
        }
        catch (RequestFailedException)
        {
            // Container probably already exists (race / RBAC scoped to data plane only).
        }
    }

    public string GetBlobName(string sharepointPath)
    {
        var clean = (sharepointPath ?? string.Empty).TrimStart('/');
        return string.IsNullOrEmpty(_blobPrefix) ? clean : $"{_blobPrefix}/{clean}";
    }

    public async IAsyncEnumerable<BlobFile> ListBlobsAsync(
        [EnumeratorCancellation] CancellationToken cancellationToken = default)
    {
        var prefix = string.IsNullOrEmpty(_blobPrefix) ? null : _blobPrefix;
        _logger.LogInformation("Listing blobs (container={Container}, prefix={Prefix})", _containerName, prefix);

        await foreach (var blob in _containerClient
            .GetBlobsAsync(BlobTraits.Metadata, BlobStates.None, prefix, cancellationToken)
            .ConfigureAwait(false))
        {
            if (blob.Name.EndsWith('/'))
            {
                continue;
            }

            // Skip directories in HNS-enabled storage: zero-byte items without a file extension.
            var lastSegment = blob.Name.Split('/').Last();
            if (blob.Properties.ContentLength is 0 && !lastSegment.Contains('.'))
            {
                continue;
            }

            yield return new BlobFile
            {
                Name = blob.Name,
                Size = blob.Properties.ContentLength ?? 0,
                LastModified = blob.Properties.LastModified ?? DateTimeOffset.UtcNow,
                ContentHash = blob.Properties.ETag?.ToString(),
                Metadata = blob.Metadata is null ? null : new Dictionary<string, string>(blob.Metadata),
            };
        }
    }

    public async Task<BlobFile?> GetBlobMetadataAsync(string blobName, CancellationToken cancellationToken = default)
    {
        try
        {
            var blobClient = _containerClient.GetBlobClient(blobName);
            var props = await blobClient.GetPropertiesAsync(cancellationToken: cancellationToken).ConfigureAwait(false);
            return new BlobFile
            {
                Name = blobName,
                Size = props.Value.ContentLength,
                LastModified = props.Value.LastModified,
                ContentHash = props.Value.ETag.ToString(),
                Metadata = props.Value.Metadata is null ? null : new Dictionary<string, string>(props.Value.Metadata),
            };
        }
        catch (RequestFailedException)
        {
            return null;
        }
    }

    public async Task<string> UploadBlobAsync(
        string sharepointPath,
        byte[] content,
        string sharepointItemId,
        DateTimeOffset? sharepointLastModified,
        string? sharepointContentHash = null,
        string? sharepointWebUrl = null,
        bool dryRun = false,
        CancellationToken cancellationToken = default)
    {
        var blobName = GetBlobName(sharepointPath);

        var metadata = new Dictionary<string, string>
        {
            [MetadataSpItemId] = sharepointItemId,
            [MetadataSpLastModified] = (sharepointLastModified ?? DateTimeOffset.UtcNow).ToString("o"),
        };
        if (!string.IsNullOrEmpty(sharepointContentHash))
        {
            metadata[MetadataSpContentHash] = sharepointContentHash;
        }
        if (!string.IsNullOrEmpty(sharepointWebUrl))
        {
            metadata[MetadataSpWebUrl] = sharepointWebUrl;
        }

        if (dryRun)
        {
            _logger.LogInformation(
                "[DRY RUN] Would upload blob (blob_name={BlobName}, size={Size}, sharepoint_path={Path})",
                blobName, content.Length, sharepointPath);
            return blobName;
        }

        var blobClient = _containerClient.GetBlobClient(blobName);
        using var stream = new MemoryStream(content);
        await blobClient.UploadAsync(stream, new BlobUploadOptions { Metadata = metadata }, cancellationToken)
            .ConfigureAwait(false);
        _logger.LogInformation("Uploaded blob (blob_name={BlobName}, size={Size}, sharepoint_path={Path})",
            blobName, content.Length, sharepointPath);
        return blobName;
    }

    public async Task DeleteBlobAsync(string blobName, bool dryRun = false, CancellationToken cancellationToken = default)
    {
        if (dryRun)
        {
            _logger.LogInformation("[DRY RUN] Would delete blob (blob_name={BlobName})", blobName);
            return;
        }

        var blobClient = _containerClient.GetBlobClient(blobName);
        try
        {
            await blobClient.DeleteAsync(cancellationToken: cancellationToken).ConfigureAwait(false);
            _logger.LogInformation("Deleted blob (blob_name={BlobName})", blobName);
        }
        catch (RequestFailedException ex) when (ex.ErrorCode == "DirectoryIsNotEmpty" ||
                                                ex.Message.Contains("DirectoryIsNotEmpty", StringComparison.Ordinal))
        {
            _logger.LogInformation("Deleting directory recursively (blob_name={BlobName})", blobName);
            await DeleteDirectoryRecursiveAsync(blobName, cancellationToken).ConfigureAwait(false);
        }
    }

    public async Task SoftDeleteBlobAsync(string blobName, bool dryRun = false, CancellationToken cancellationToken = default)
    {
        if (dryRun)
        {
            _logger.LogInformation("[DRY RUN] Would soft-delete blob (IsDeleted=true) (blob_name={BlobName})", blobName);
            return;
        }

        var blobClient = _containerClient.GetBlobClient(blobName);
        BlobProperties props;
        try
        {
            props = await blobClient.GetPropertiesAsync(cancellationToken: cancellationToken).ConfigureAwait(false);
        }
        catch (RequestFailedException ex)
        {
            _logger.LogWarning("Soft-delete skipped (blob not found) (blob_name={BlobName}, error={Error})",
                blobName, ex.Message);
            return;
        }

        var existing = props.Metadata is null
            ? new Dictionary<string, string>()
            : new Dictionary<string, string>(props.Metadata);

        if (existing.TryGetValue("IsDeleted", out var isDel) && isDel == "true")
        {
            _logger.LogInformation("Blob already soft-deleted (blob_name={BlobName})", blobName);
            return;
        }

        existing["IsDeleted"] = "true";
        existing["deleted_at"] = DateTimeOffset.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ");
        await blobClient.SetMetadataAsync(existing, cancellationToken: cancellationToken).ConfigureAwait(false);
        _logger.LogInformation("Soft-deleted blob (IsDeleted=true) (blob_name={BlobName})", blobName);
    }

    private async Task DeleteDirectoryRecursiveAsync(string directoryPath, CancellationToken cancellationToken)
    {
        var prefix = directoryPath.TrimEnd('/') + "/";
        var blobsDeleted = 0;
        await foreach (var blob in _containerClient
            .GetBlobsAsync(BlobTraits.None, BlobStates.None, prefix, cancellationToken)
            .ConfigureAwait(false))
        {
            try
            {
                await _containerClient.GetBlobClient(blob.Name)
                    .DeleteAsync(cancellationToken: cancellationToken).ConfigureAwait(false);
                blobsDeleted++;
            }
            catch (RequestFailedException ex)
            {
                _logger.LogWarning(
                    "Failed to delete blob in directory (blob_name={BlobName}, error={Error})",
                    blob.Name, ex.Message);
            }
        }

        try
        {
            await _containerClient.GetBlobClient(directoryPath)
                .DeleteAsync(cancellationToken: cancellationToken).ConfigureAwait(false);
        }
        catch (RequestFailedException)
        {
            // ignore — flat namespace
        }

        _logger.LogInformation("Deleted directory (directory_path={Path}, blobs_deleted={Count})",
            directoryPath, blobsDeleted);
    }

    public bool ShouldUpdate(BlobFile blob, DateTimeOffset? spLastModified, string? spContentHash)
    {
        if (blob.Metadata is null)
        {
            return true;
        }

        if (blob.Metadata.TryGetValue(MetadataSpContentHash, out var storedHash) &&
            !string.IsNullOrEmpty(storedHash) &&
            !string.IsNullOrEmpty(spContentHash) &&
            storedHash != spContentHash)
        {
            return true;
        }

        if (blob.Metadata.TryGetValue(MetadataSpLastModified, out var storedDateStr) &&
            !string.IsNullOrEmpty(storedDateStr) &&
            DateTimeOffset.TryParse(storedDateStr, out var storedDate))
        {
            var sp = spLastModified ?? DateTimeOffset.UtcNow;
            return sp > storedDate;
        }

        return true;
    }

    public async Task UpdateBlobMetadataAsync(
        string blobName,
        IDictionary<string, string> additionalMetadata,
        bool dryRun = false,
        CancellationToken cancellationToken = default)
    {
        if (dryRun)
        {
            _logger.LogInformation(
                "[DRY RUN] Would update blob metadata (blob_name={BlobName}, keys={Keys})",
                blobName, string.Join(",", additionalMetadata.Keys));
            return;
        }

        var blobClient = _containerClient.GetBlobClient(blobName);
        Dictionary<string, string> existing;
        try
        {
            var props = await blobClient.GetPropertiesAsync(cancellationToken: cancellationToken).ConfigureAwait(false);
            existing = props.Value.Metadata is null
                ? new Dictionary<string, string>()
                : new Dictionary<string, string>(props.Value.Metadata);
        }
        catch (RequestFailedException)
        {
            existing = new Dictionary<string, string>();
        }

        foreach (var deprecated in DeprecatedFields)
        {
            existing.Remove(deprecated);
        }

        foreach (var kvp in additionalMetadata)
        {
            existing[kvp.Key] = kvp.Value;
        }

        await blobClient.SetMetadataAsync(existing, cancellationToken: cancellationToken).ConfigureAwait(false);
        _logger.LogInformation("Updated blob metadata (blob_name={BlobName}, keys={Keys})",
            blobName, string.Join(",", additionalMetadata.Keys));
    }

    public async Task<string?> LoadDeltaTokenAsync(CancellationToken cancellationToken = default)
    {
        try
        {
            var blobClient = _containerClient.GetBlobClient(DeltaTokenBlob);
            var resp = await blobClient.DownloadContentAsync(cancellationToken).ConfigureAwait(false);
            var raw = resp.Value.Content.ToString();
            using var doc = JsonDocument.Parse(raw);
            var root = doc.RootElement;
            var deltaLink = root.TryGetProperty("delta_link", out var dl) && dl.ValueKind == JsonValueKind.String
                ? dl.GetString()
                : null;
            var savedAt = root.TryGetProperty("saved_at", out var sa) && sa.ValueKind == JsonValueKind.String
                ? sa.GetString()
                : "unknown";
            _logger.LogInformation(
                "Loaded delta token from blob storage (saved_at={SavedAt}, preview={Preview})",
                savedAt,
                string.IsNullOrEmpty(deltaLink) ? null : (deltaLink!.Length > 100 ? deltaLink.Substring(0, 100) : deltaLink));
            return deltaLink;
        }
        catch (RequestFailedException)
        {
            _logger.LogInformation("No existing delta token found — will do full initial sync");
            return null;
        }
        catch (JsonException)
        {
            _logger.LogInformation("Existing delta token unparseable — will do full initial sync");
            return null;
        }
    }

    public async Task SaveDeltaTokenAsync(string deltaLink, bool dryRun = false, CancellationToken cancellationToken = default)
    {
        if (dryRun)
        {
            _logger.LogInformation("[DRY RUN] Would save delta token");
            return;
        }

        var payload = JsonSerializer.Serialize(new
        {
            delta_link = deltaLink,
            saved_at = DateTimeOffset.UtcNow.ToString("o"),
        });

        var blobClient = _containerClient.GetBlobClient(DeltaTokenBlob);
        using var ms = new MemoryStream(Encoding.UTF8.GetBytes(payload));
        await blobClient.UploadAsync(ms, overwrite: true, cancellationToken: cancellationToken).ConfigureAwait(false);
        _logger.LogInformation("Saved delta token to blob storage");
    }

    public async Task ClearDeltaTokenAsync(CancellationToken cancellationToken = default)
    {
        try
        {
            await _containerClient.GetBlobClient(DeltaTokenBlob)
                .DeleteAsync(cancellationToken: cancellationToken).ConfigureAwait(false);
            _logger.LogInformation("Cleared delta token — next run will be a full sync");
        }
        catch (RequestFailedException)
        {
            // No-op when the token didn't exist.
        }
    }

    public ValueTask DisposeAsync() => ValueTask.CompletedTask;
}
