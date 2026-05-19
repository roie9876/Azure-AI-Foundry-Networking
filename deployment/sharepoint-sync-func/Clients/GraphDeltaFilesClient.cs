using System;
using System.Collections.Generic;
using System.IO;
using System.Net.Http;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using System.Web;
using Azure.Core;
using Microsoft.Extensions.Logging;
using Microsoft.Graph;
using SharePointSyncFunc.Models;

namespace SharePointSyncFunc.Clients;

/// <summary>
/// Detects file changes using Microsoft Graph's drive-level delta API. Equivalent
/// to the Python GraphDeltaFilesClient — keeps a token file per drive so that the
/// next call returns only changed/deleted items.
/// </summary>
public sealed class GraphDeltaFilesClient : IAsyncDisposable
{
    private static readonly string[] GraphScopes = { "https://graph.microsoft.com/.default" };

    private readonly string _driveId;
    private readonly DeltaTokenStorage _tokenStorage;
    private readonly ILogger _logger;
    private readonly TokenCredential _credential;
    private readonly HttpClient _httpClient;
    private readonly GraphServiceClient _graph;

    public GraphDeltaFilesClient(string driveId, DeltaTokenStorage tokenStorage, ILogger logger)
    {
        _driveId = driveId;
        _tokenStorage = tokenStorage;
        _logger = logger;
        _credential = CredentialFactory.GetSharePointCredential(logger);
        _httpClient = new HttpClient(new GraphTokenAuthHandler(_credential) { InnerHandler = new HttpClientHandler() })
        {
            Timeout = TimeSpan.FromSeconds(60),
        };
        _graph = new GraphServiceClient(_credential, GraphScopes);
    }

    public async IAsyncEnumerable<SharePointFile> GetChangedFilesAsync(
        string folderPath = "/",
        [EnumeratorCancellation] CancellationToken cancellationToken = default)
    {
        var existingToken = _tokenStorage.GetToken(_driveId, "files");

        _logger.LogInformation(
            "Starting Graph delta query for file changes (drive_id={DriveId}, has_token={HasToken}, folder={Folder})",
            _driveId, existingToken is not null, folderPath);

        var folderFilter = (folderPath != null && folderPath != "/")
            ? folderPath.Trim('/').ToLowerInvariant()
            : string.Empty;

        var deltaUrl = !string.IsNullOrEmpty(existingToken?.Token)
            ? $"https://graph.microsoft.com/v1.0/drives/{_driveId}/root/delta?token={existingToken!.Token}"
            : $"https://graph.microsoft.com/v1.0/drives/{_driveId}/root/delta";

        string? newDeltaLink = null;
        var itemsProcessed = 0;
        var filesChanged = 0;
        var filesDeleted = 0;

        while (!string.IsNullOrEmpty(deltaUrl))
        {
            using var resp = await _httpClient.GetAsync(deltaUrl, cancellationToken).ConfigureAwait(false);

            if ((int)resp.StatusCode == 410)
            {
                _logger.LogWarning("Delta token expired, starting fresh enumeration");
                _tokenStorage.DeleteToken(_driveId, "files");
                deltaUrl = $"https://graph.microsoft.com/v1.0/drives/{_driveId}/root/delta";
                existingToken = null;
                continue;
            }

            resp.EnsureSuccessStatusCode();
            await using var contentStream = await resp.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
            using var doc = await JsonDocument.ParseAsync(contentStream, cancellationToken: cancellationToken).ConfigureAwait(false);
            var root = doc.RootElement;

            if (root.TryGetProperty("value", out var valueArr) && valueArr.ValueKind == JsonValueKind.Array)
            {
                foreach (var item in valueArr.EnumerateArray())
                {
                    itemsProcessed++;

                    var parentPath = string.Empty;
                    if (item.TryGetProperty("parentReference", out var parentEl) &&
                        parentEl.ValueKind == JsonValueKind.Object &&
                        parentEl.TryGetProperty("path", out var pathEl) &&
                        pathEl.ValueKind == JsonValueKind.String)
                    {
                        var raw = pathEl.GetString() ?? string.Empty;
                        var idx = raw.IndexOf(":/", StringComparison.Ordinal);
                        if (idx >= 0)
                        {
                            parentPath = raw.Substring(idx + 2);
                        }
                        else if (!string.IsNullOrEmpty(raw))
                        {
                            parentPath = raw.TrimStart('/');
                        }
                    }

                    var itemName = item.TryGetProperty("name", out var nameEl) && nameEl.ValueKind == JsonValueKind.String
                        ? nameEl.GetString() ?? string.Empty
                        : string.Empty;

                    var itemPath = string.IsNullOrEmpty(parentPath)
                        ? $"/{itemName}"
                        : $"/{parentPath}/{itemName}";
                    itemPath = itemPath.Replace("//", "/");

                    if (!string.IsNullOrEmpty(folderFilter))
                    {
                        var lowered = itemPath.TrimStart('/').ToLowerInvariant();
                        if (!lowered.StartsWith(folderFilter, StringComparison.Ordinal))
                        {
                            continue;
                        }
                    }

                    if (item.TryGetProperty("folder", out _))
                    {
                        continue;
                    }

                    var itemId = item.TryGetProperty("id", out var idEl) && idEl.ValueKind == JsonValueKind.String
                        ? idEl.GetString() ?? string.Empty
                        : string.Empty;

                    if (item.TryGetProperty("deleted", out _))
                    {
                        filesDeleted++;
                        yield return new SharePointFile
                        {
                            Id = itemId,
                            Name = itemName,
                            Path = itemPath,
                            Size = 0,
                            LastModified = DateTimeOffset.UtcNow,
                            ChangeType = FileChangeType.Deleted,
                        };
                        continue;
                    }

                    if (!item.TryGetProperty("file", out _))
                    {
                        continue;
                    }

                    filesChanged++;
                    var changeType = existingToken is not null ? FileChangeType.Modified : FileChangeType.Added;

                    DateTimeOffset? lastModified = null;
                    if (item.TryGetProperty("lastModifiedDateTime", out var lmEl) &&
                        lmEl.ValueKind == JsonValueKind.String &&
                        DateTimeOffset.TryParse(lmEl.GetString(), out var parsedLm))
                    {
                        lastModified = parsedLm;
                    }

                    long size = 0;
                    if (item.TryGetProperty("size", out var sizeEl) && sizeEl.ValueKind == JsonValueKind.Number)
                    {
                        size = sizeEl.GetInt64();
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

                    yield return new SharePointFile
                    {
                        Id = itemId,
                        Name = itemName,
                        Path = itemPath,
                        Size = size,
                        LastModified = lastModified,
                        ContentHash = contentHash,
                        ChangeType = changeType,
                        WebUrl = webUrl,
                    };
                }
            }

            deltaUrl = root.TryGetProperty("@odata.nextLink", out var nl) && nl.ValueKind == JsonValueKind.String
                ? nl.GetString()
                : null;

            if (string.IsNullOrEmpty(deltaUrl) &&
                root.TryGetProperty("@odata.deltaLink", out var dl) &&
                dl.ValueKind == JsonValueKind.String)
            {
                newDeltaLink = dl.GetString();
            }
        }

        _logger.LogInformation(
            "Graph delta query completed (items_processed={Items}, files_changed={Changed}, files_deleted={Deleted}, is_initial={Initial})",
            itemsProcessed, filesChanged, filesDeleted, existingToken is null);

        if (!string.IsNullOrEmpty(newDeltaLink))
        {
            var query = HttpUtility.ParseQueryString(new Uri(newDeltaLink).Query);
            var tokenValue = query.Get("token");
            if (!string.IsNullOrEmpty(tokenValue))
            {
                _tokenStorage.SaveToken(new DeltaToken
                {
                    DriveId = _driveId,
                    Token = tokenValue,
                    LastUpdated = DateTimeOffset.UtcNow,
                    TokenType = "files",
                });
            }
        }
    }

    public async Task<byte[]> DownloadFileAsync(string itemId, CancellationToken cancellationToken = default)
    {
        await using var stream = await _graph.Drives[_driveId].Items[itemId].Content
            .GetAsync(cancellationToken: cancellationToken).ConfigureAwait(false);
        if (stream is null)
        {
            return Array.Empty<byte>();
        }
        using var ms = new MemoryStream();
        await stream.CopyToAsync(ms, cancellationToken).ConfigureAwait(false);
        return ms.ToArray();
    }

    public ValueTask DisposeAsync()
    {
        _httpClient.Dispose();
        return ValueTask.CompletedTask;
    }
}
