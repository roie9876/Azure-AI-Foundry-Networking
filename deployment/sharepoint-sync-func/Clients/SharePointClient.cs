using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using System.Web;
using Azure.Core;
using Microsoft.Extensions.Logging;
using Microsoft.Graph;
using Microsoft.Graph.Models;
using SharePointSyncFunc.Models;

namespace SharePointSyncFunc.Clients;

/// <summary>
/// SharePoint client using Microsoft Graph API. Mirrors the Python SharePointClient.
/// Resolves site/drive IDs from a SharePoint URL, lists files recursively, downloads
/// content, and exposes the drive-level delta API.
/// </summary>
public sealed class SharePointClient : IAsyncDisposable
{
    private static readonly string[] GraphScopes = { "https://graph.microsoft.com/.default" };

    private readonly string _siteUrl;
    private readonly string _driveName;
    private readonly ILogger<SharePointClient> _logger;
    private readonly TokenCredential _credential;
    private readonly GraphServiceClient _graph;
    private readonly HttpClient _httpClient;

    public string? SiteId { get; private set; }
    public string? DriveId { get; private set; }
    public string? DriveWebUrl { get; private set; }

    public SharePointClient(string siteUrl, string driveName, ILogger<SharePointClient> logger)
    {
        _siteUrl = siteUrl;
        _driveName = driveName;
        _logger = logger;
        _credential = CredentialFactory.GetSharePointCredential(logger);
        _graph = new GraphServiceClient(_credential, GraphScopes);
        _httpClient = new HttpClient(new GraphTokenAuthHandler(_credential) { InnerHandler = new HttpClientHandler() })
        {
            Timeout = TimeSpan.FromSeconds(120),
        };
    }

    public async Task InitializeAsync(CancellationToken cancellationToken = default)
    {
        var uri = new Uri(_siteUrl);
        var hostname = uri.Host;
        var sitePath = uri.AbsolutePath;

        _logger.LogInformation("Resolving SharePoint site (hostname={Hostname}, path={SitePath})", hostname, sitePath);

        var site = await _graph.Sites[$"{hostname}:{sitePath}"]
            .GetAsync(cancellationToken: cancellationToken).ConfigureAwait(false);

        if (site is null || string.IsNullOrEmpty(site.Id))
        {
            throw new InvalidOperationException($"Could not resolve SharePoint site: {_siteUrl}");
        }

        SiteId = site.Id;
        _logger.LogInformation("Resolved site ID (site_id={SiteId}, name={Name})", SiteId, site.DisplayName);

        var drives = await _graph.Sites[SiteId].Drives
            .GetAsync(cancellationToken: cancellationToken).ConfigureAwait(false);

        if (drives?.Value is null || drives.Value.Count == 0)
        {
            throw new InvalidOperationException($"No document libraries found in site: {_siteUrl}");
        }

        foreach (var drive in drives.Value)
        {
            if (!string.IsNullOrEmpty(drive.Name) &&
                string.Equals(drive.Name, _driveName, StringComparison.OrdinalIgnoreCase))
            {
                DriveId = drive.Id;
                DriveWebUrl = drive.WebUrl;
                _logger.LogInformation("Resolved drive (drive_id={DriveId}, name={Name}, web_url={WebUrl})",
                    DriveId, drive.Name, DriveWebUrl);
                break;
            }
        }

        if (string.IsNullOrEmpty(DriveId))
        {
            var available = string.Join(", ", System.Linq.Enumerable.Select(drives.Value, d => d.Name ?? "<unnamed>"));
            throw new InvalidOperationException(
                $"Document library '{_driveName}' not found in site. Available libraries: {available}");
        }
    }

    public (string SiteId, string DriveId) GetResolvedIds()
    {
        if (string.IsNullOrEmpty(SiteId) || string.IsNullOrEmpty(DriveId))
        {
            throw new InvalidOperationException("IDs not resolved. Call InitializeAsync first.");
        }
        return (SiteId, DriveId);
    }

    public async IAsyncEnumerable<SharePointFile> ListFilesAsync(
        string folderPath = "/",
        [EnumeratorCancellation] CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrEmpty(DriveId))
        {
            throw new InvalidOperationException("Client not initialized. Call InitializeAsync first.");
        }

        _logger.LogInformation("Listing SharePoint files (folder_path={FolderPath})", folderPath);

        IAsyncEnumerable<SharePointFile> source;
        try
        {
            source = ListFilesInternalAsync(folderPath, cancellationToken);
        }
        catch (Exception ex) when (IsNotFoundError(ex))
        {
            _logger.LogWarning("SharePoint folder not found — skipping (folder_path={FolderPath}, error={Error})",
                folderPath, ex.Message);
            yield break;
        }

        await foreach (var file in source.WithCancellation(cancellationToken).ConfigureAwait(false))
        {
            yield return file;
        }
    }

    private async IAsyncEnumerable<SharePointFile> ListFilesInternalAsync(
        string folderPath,
        [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        if (string.IsNullOrEmpty(folderPath) || folderPath == "/")
        {
            DriveItemCollectionResponse? rootChildren = null;
            try
            {
                var root = await _graph.Drives[DriveId].Root
                    .GetAsync(req => req.QueryParameters.Expand = new[] { "children" },
                        cancellationToken: cancellationToken).ConfigureAwait(false);
                if (root?.Children is { Count: > 0 })
                {
                    foreach (var item in root.Children)
                    {
                        await foreach (var f in ProcessItemAsync(item, "/", cancellationToken)
                            .ConfigureAwait(false))
                        {
                            yield return f;
                        }
                    }
                }
            }
            finally
            {
                _ = rootChildren;
            }
        }
        else
        {
            var cleanPath = folderPath.Trim('/');
            // Path-based driveItem addressing (root:/path:) requires the literal `:` and `/` chars.
            // Kiota's level-1 URI template substitution percent-encodes them, so we override the
            // URL with WithUrl() to preserve them. Per-segment Uri.EscapeDataString handles names
            // with spaces, '#', etc. while keeping the segment separators intact.
            var encodedPath = string.Join("/",
                cleanPath.Split('/', StringSplitOptions.RemoveEmptyEntries)
                    .Select(Uri.EscapeDataString));
            var folderUrl =
                $"https://graph.microsoft.com/v1.0/drives/{DriveId}/root:/{encodedPath}:";

            var folderItem = await _graph.Drives[DriveId].Items["root"]
                .WithUrl(folderUrl)
                .GetAsync(cancellationToken: cancellationToken).ConfigureAwait(false);

            if (folderItem?.Id is null)
            {
                yield break;
            }

            var children = await _graph.Drives[DriveId].Items[folderItem.Id].Children
                .GetAsync(cancellationToken: cancellationToken).ConfigureAwait(false);

            if (children?.Value is { Count: > 0 })
            {
                foreach (var item in children.Value)
                {
                    await foreach (var f in ProcessItemAsync(item, folderPath, cancellationToken)
                        .ConfigureAwait(false))
                    {
                        yield return f;
                    }
                }
            }
        }
    }

    private async IAsyncEnumerable<SharePointFile> ProcessItemAsync(
        DriveItem item,
        string parentPath,
        [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        if (string.IsNullOrEmpty(item.Id))
        {
            yield break;
        }

        var currentPath = parentPath == "/" || string.IsNullOrEmpty(parentPath)
            ? $"/{item.Name}"
            : $"{parentPath.TrimEnd('/')}/{item.Name}";

        if (item.Folder is not null)
        {
            _logger.LogDebug("Processing folder (path={Path})", currentPath);

            var children = await _graph.Drives[DriveId].Items[item.Id].Children
                .GetAsync(cancellationToken: cancellationToken).ConfigureAwait(false);

            if (children?.Value is { Count: > 0 })
            {
                foreach (var child in children.Value)
                {
                    await foreach (var f in ProcessItemAsync(child, currentPath, cancellationToken)
                        .ConfigureAwait(false))
                    {
                        yield return f;
                    }
                }
            }
        }
        else if (item.File is not null)
        {
            string? downloadUrl = null;
            if (item.AdditionalData.TryGetValue("@microsoft.graph.downloadUrl", out var dlObj) && dlObj is not null)
            {
                downloadUrl = dlObj.ToString();
            }

            var webUrl = item.WebUrl;
            if (string.IsNullOrEmpty(webUrl) && !string.IsNullOrEmpty(DriveWebUrl))
            {
                webUrl = DriveWebUrl.TrimEnd('/') + EscapeUrlPath(currentPath);
            }

            yield return new SharePointFile
            {
                Id = item.Id,
                Name = item.Name ?? string.Empty,
                Path = currentPath,
                Size = item.Size ?? 0,
                LastModified = item.LastModifiedDateTime,
                DownloadUrl = downloadUrl,
                ContentHash = item.CTag ?? item.ETag,
                WebUrl = webUrl,
            };
        }
    }

    public async Task<byte[]> DownloadFileAsync(string itemId, CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrEmpty(DriveId))
        {
            throw new InvalidOperationException("Client not initialized. Call InitializeAsync first.");
        }

        await using var stream = await _graph.Drives[DriveId].Items[itemId].Content
            .GetAsync(cancellationToken: cancellationToken).ConfigureAwait(false);
        if (stream is null)
        {
            return Array.Empty<byte>();
        }

        using var ms = new MemoryStream();
        await stream.CopyToAsync(ms, cancellationToken).ConfigureAwait(false);
        return ms.ToArray();
    }

    public async Task<DeltaResult> GetDeltaAsync(string? deltaLink = null, CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrEmpty(DriveId))
        {
            throw new InvalidOperationException("Client not initialized. Call InitializeAsync first.");
        }

        var isInitial = string.IsNullOrEmpty(deltaLink);
        var url = string.IsNullOrEmpty(deltaLink)
            ? $"https://graph.microsoft.com/v1.0/drives/{DriveId}/root/delta"
            : deltaLink!;

        _logger.LogInformation("Starting delta query (is_initial={IsInitial}, url={UrlPreview})",
            isInitial, url.Length > 120 ? url.Substring(0, 120) : url);

        var changes = new List<DeltaChange>();
        var newDeltaLink = string.Empty;
        string? nextUrl = url;
        var page = 0;

        while (!string.IsNullOrEmpty(nextUrl))
        {
            page++;
            using var resp = await _httpClient.GetAsync(nextUrl, cancellationToken).ConfigureAwait(false);
            resp.EnsureSuccessStatusCode();

            await using var contentStream = await resp.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
            using var doc = await JsonDocument.ParseAsync(contentStream, cancellationToken: cancellationToken).ConfigureAwait(false);
            var root = doc.RootElement;

            var items = root.TryGetProperty("value", out var v) && v.ValueKind == JsonValueKind.Array
                ? v
                : default;

            var pageCount = items.ValueKind == JsonValueKind.Array ? items.GetArrayLength() : 0;
            _logger.LogInformation("Delta page received (page={Page}, items={Items})", page, pageCount);

            if (items.ValueKind == JsonValueKind.Array)
            {
                foreach (var item in items.EnumerateArray())
                {
                    var change = ParseDeltaItem(item);
                    if (change is not null)
                    {
                        changes.Add(change);
                    }
                }
            }

            nextUrl = root.TryGetProperty("@odata.nextLink", out var nl) && nl.ValueKind == JsonValueKind.String
                ? nl.GetString()
                : null;

            if (string.IsNullOrEmpty(nextUrl) &&
                root.TryGetProperty("@odata.deltaLink", out var dl) &&
                dl.ValueKind == JsonValueKind.String)
            {
                newDeltaLink = dl.GetString() ?? string.Empty;
            }
        }

        var fileChanges = new List<DeltaChange>();
        foreach (var c in changes)
        {
            if (!c.IsFolder)
            {
                fileChanges.Add(c);
            }
        }

        _logger.LogInformation(
            "Delta query complete (total={Total}, files={Files}, deletions={Del}, is_initial={IsInitial})",
            changes.Count, fileChanges.Count,
            System.Linq.Enumerable.Count(changes, c => c.ChangeType == DeltaChangeType.Deleted),
            isInitial);

        return new DeltaResult
        {
            Changes = fileChanges,
            DeltaToken = newDeltaLink,
            IsInitialSync = isInitial,
        };
    }

    private static DeltaChange? ParseDeltaItem(JsonElement item)
    {
        var itemId = item.TryGetProperty("id", out var idEl) && idEl.ValueKind == JsonValueKind.String
            ? idEl.GetString() ?? string.Empty
            : string.Empty;
        var itemName = item.TryGetProperty("name", out var nameEl) && nameEl.ValueKind == JsonValueKind.String
            ? nameEl.GetString() ?? string.Empty
            : string.Empty;

        var parentPath = string.Empty;
        if (item.TryGetProperty("parentReference", out var parentEl) &&
            parentEl.ValueKind == JsonValueKind.Object &&
            parentEl.TryGetProperty("path", out var pathEl) &&
            pathEl.ValueKind == JsonValueKind.String)
        {
            var raw = pathEl.GetString() ?? string.Empty;
            var idx = raw.IndexOf(':');
            parentPath = idx >= 0 ? raw.Substring(idx + 1) : string.Empty;
        }

        string itemPath;
        if (!string.IsNullOrEmpty(parentPath))
        {
            itemPath = $"{parentPath.TrimEnd('/')}/{itemName}";
        }
        else
        {
            itemPath = string.IsNullOrEmpty(itemName) ? string.Empty : $"/{itemName}";
        }

        var isFolder = item.TryGetProperty("folder", out _);

        if (item.TryGetProperty("deleted", out _))
        {
            return new DeltaChange
            {
                ChangeType = DeltaChangeType.Deleted,
                ItemId = itemId,
                ItemName = itemName,
                ItemPath = itemPath,
                IsFolder = isFolder,
            };
        }

        if (isFolder)
        {
            return new DeltaChange
            {
                ChangeType = DeltaChangeType.CreatedOrModified,
                ItemId = itemId,
                ItemName = itemName,
                ItemPath = itemPath,
                IsFolder = true,
            };
        }

        if (item.TryGetProperty("file", out _))
        {
            DateTimeOffset? lastModified = null;
            if (item.TryGetProperty("lastModifiedDateTime", out var lmEl) &&
                lmEl.ValueKind == JsonValueKind.String &&
                DateTimeOffset.TryParse(lmEl.GetString(), out var parsedLm))
            {
                lastModified = parsedLm;
            }

            string? downloadUrl = null;
            if (item.TryGetProperty("@microsoft.graph.downloadUrl", out var duEl) &&
                duEl.ValueKind == JsonValueKind.String)
            {
                downloadUrl = duEl.GetString();
            }

            string? contentHash = null;
            if (item.TryGetProperty("cTag", out var cTagEl) && cTagEl.ValueKind == JsonValueKind.String)
            {
                contentHash = cTagEl.GetString();
            }
            else if (item.TryGetProperty("eTag", out var eTagEl) && eTagEl.ValueKind == JsonValueKind.String)
            {
                contentHash = eTagEl.GetString();
            }

            string? webUrl = null;
            if (item.TryGetProperty("webUrl", out var wuEl) && wuEl.ValueKind == JsonValueKind.String)
            {
                webUrl = wuEl.GetString();
            }

            long size = 0;
            if (item.TryGetProperty("size", out var sizeEl) && sizeEl.ValueKind == JsonValueKind.Number)
            {
                size = sizeEl.GetInt64();
            }

            var spFile = new SharePointFile
            {
                Id = itemId,
                Name = itemName,
                Path = itemPath,
                Size = size,
                LastModified = lastModified,
                DownloadUrl = downloadUrl,
                ContentHash = contentHash,
                WebUrl = webUrl,
            };

            return new DeltaChange
            {
                ChangeType = DeltaChangeType.CreatedOrModified,
                File = spFile,
                ItemId = itemId,
                ItemName = itemName,
                ItemPath = itemPath,
                IsFolder = false,
            };
        }

        return null;
    }

    private static string EscapeUrlPath(string path)
    {
        if (string.IsNullOrEmpty(path)) return string.Empty;
        var segments = path.Split('/');
        for (var i = 0; i < segments.Length; i++)
        {
            segments[i] = Uri.EscapeDataString(segments[i]);
        }
        return string.Join("/", segments);
    }

    public static bool IsNotFoundError(Exception ex)
    {
        var msg = ex.Message ?? string.Empty;
        if (msg.Contains("itemNotFound", StringComparison.OrdinalIgnoreCase) ||
            msg.Contains("could not be found", StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }

        if (ex is Microsoft.Graph.Models.ODataErrors.ODataError odataError)
        {
            return odataError.ResponseStatusCode == 404 ||
                   string.Equals(odataError.Error?.Code, "itemNotFound", StringComparison.OrdinalIgnoreCase);
        }

        return false;
    }

    public ValueTask DisposeAsync()
    {
        _httpClient.Dispose();
        return ValueTask.CompletedTask;
    }
}
