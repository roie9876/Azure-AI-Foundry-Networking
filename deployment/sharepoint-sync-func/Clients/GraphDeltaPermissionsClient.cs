using System;
using System.Collections.Generic;
using System.Net.Http;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using System.Web;
using Azure.Core;
using Microsoft.Extensions.Logging;
using SharePointSyncFunc.Models;

namespace SharePointSyncFunc.Clients;

/// <summary>
/// Detects permission changes via Microsoft Graph delta API. The "Prefer:
/// deltashowsharingchanges, hierarchicalsharing, ..." headers ask Graph to
/// surface @microsoft.graph.sharedChanged annotations on items whose sharing
/// has changed since the last delta token. Mirrors the Python
/// GraphDeltaPermissionsClient.
/// </summary>
public sealed class GraphDeltaPermissionsClient : IAsyncDisposable
{
    private const string DeltaPreferHeader =
        "deltashowremovedasdeleted, deltatraversepermissiongaps, deltashowsharingchanges, hierarchicalsharing";

    private readonly string _driveId;
    private readonly DeltaTokenStorage _tokenStorage;
    private readonly ILogger _logger;
    private readonly TokenCredential _credential;
    private readonly HttpClient _httpClient;

    public GraphDeltaPermissionsClient(string driveId, DeltaTokenStorage tokenStorage, ILogger logger)
    {
        _driveId = driveId;
        _tokenStorage = tokenStorage;
        _logger = logger;
        _credential = CredentialFactory.GetSharePointCredential(logger);
        _httpClient = new HttpClient(new GraphTokenAuthHandler(_credential) { InnerHandler = new HttpClientHandler() })
        {
            Timeout = TimeSpan.FromSeconds(60),
        };
        _httpClient.DefaultRequestHeaders.Add("Prefer", DeltaPreferHeader);
    }

    public async IAsyncEnumerable<PermissionChangedItem> GetItemsWithPermissionChangesAsync(
        [EnumeratorCancellation] CancellationToken cancellationToken = default)
    {
        var existingToken = _tokenStorage.GetToken(_driveId, "permissions");

        _logger.LogInformation(
            "Starting Graph delta query for permission changes (drive_id={DriveId}, has_token={HasToken})",
            _driveId, existingToken is not null);

        var deltaUrl = !string.IsNullOrEmpty(existingToken?.Token)
            ? $"https://graph.microsoft.com/v1.0/drives/{_driveId}/root/delta?token={existingToken!.Token}"
            : $"https://graph.microsoft.com/v1.0/drives/{_driveId}/root/delta";

        string? newDeltaLink = null;
        var itemsProcessed = 0;
        var itemsWithSharingChanges = 0;

        while (!string.IsNullOrEmpty(deltaUrl))
        {
            using var resp = await _httpClient.GetAsync(deltaUrl, cancellationToken).ConfigureAwait(false);

            if ((int)resp.StatusCode == 410)
            {
                _logger.LogWarning("Delta token expired, starting fresh enumeration");
                _tokenStorage.DeleteToken(_driveId, "permissions");
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

                    var sharingChanged =
                        item.TryGetProperty("@microsoft.graph.sharedChanged", out var scEl) &&
                        scEl.ValueKind == JsonValueKind.String &&
                        string.Equals(scEl.GetString(), "True", StringComparison.OrdinalIgnoreCase);

                    if (item.TryGetProperty("folder", out _) && !sharingChanged)
                    {
                        continue;
                    }

                    if (item.TryGetProperty("deleted", out _))
                    {
                        continue;
                    }

                    if (existingToken is not null && !sharingChanged)
                    {
                        continue;
                    }

                    if (sharingChanged)
                    {
                        itemsWithSharingChanges++;
                        _logger.LogInformation(
                            "Item with permission change detected (item_id={ItemId}, name={Name}, sharing_changed=true)",
                            item.TryGetProperty("id", out var idEl) ? idEl.GetString() : "",
                            item.TryGetProperty("name", out var nameEl) ? nameEl.GetString() : "");
                    }

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

                    var name = item.TryGetProperty("name", out var nameEl2) && nameEl2.ValueKind == JsonValueKind.String
                        ? nameEl2.GetString() ?? string.Empty
                        : string.Empty;

                    var itemPath = string.IsNullOrEmpty(parentPath)
                        ? $"/{name}"
                        : $"/{parentPath}/{name}";
                    itemPath = itemPath.Replace("//", "/");

                    yield return new PermissionChangedItem
                    {
                        ItemId = item.TryGetProperty("id", out var idEl2) ? idEl2.GetString() ?? string.Empty : string.Empty,
                        Name = name,
                        Path = itemPath,
                        SharingChanged = sharingChanged,
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
            "Graph delta query completed (items_processed={Items}, sharing_changes={SharingChanges}, is_initial={Initial})",
            itemsProcessed, itemsWithSharingChanges, existingToken is null);

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
                    TokenType = "permissions",
                });
            }
        }
    }

    public ValueTask DisposeAsync()
    {
        _httpClient.Dispose();
        return ValueTask.CompletedTask;
    }
}
