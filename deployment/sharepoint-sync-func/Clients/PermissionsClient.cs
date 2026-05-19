using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using Azure.Core;
using Microsoft.Extensions.Logging;
using Microsoft.Graph;
using Microsoft.Graph.Models;
using SharePointSyncFunc.Models;

namespace SharePointSyncFunc.Clients;

/// <summary>
/// Fetches SharePoint file permissions via Microsoft Graph and parses them into
/// the FilePermissions data model. Mirrors the Python PermissionsClient.
/// </summary>
public sealed class PermissionsClient : IAsyncDisposable
{
    private static readonly string[] GraphScopes = { "https://graph.microsoft.com/.default" };

    private readonly string _driveId;
    private readonly ILogger _logger;
    private readonly TokenCredential _credential;
    private readonly GraphServiceClient _graph;

    public PermissionsClient(string driveId, ILogger logger)
    {
        _driveId = driveId;
        _logger = logger;
        _credential = CredentialFactory.GetSharePointCredential(logger);
        _graph = new GraphServiceClient(_credential, GraphScopes);
    }

    public async Task<FilePermissions> GetFilePermissionsAsync(
        string fileId, string filePath, CancellationToken cancellationToken = default)
    {
        _logger.LogInformation("Fetching permissions (file_path={FilePath}, file_id={FileId})", filePath, fileId);

        try
        {
            var resp = await _graph.Drives[_driveId].Items[fileId].Permissions
                .GetAsync(cancellationToken: cancellationToken).ConfigureAwait(false);

            if (resp?.Value is null || resp.Value.Count == 0)
            {
                _logger.LogInformation("No permissions found (file_path={FilePath})", filePath);
                return new FilePermissions
                {
                    FilePath = filePath,
                    FileId = fileId,
                    Permissions = new List<SharePointPermission>(),
                    SyncedAt = DateTimeOffset.UtcNow,
                };
            }

            var permissions = new List<SharePointPermission>(resp.Value.Count);
            foreach (var p in resp.Value)
            {
                var parsed = ParsePermission(p);
                if (parsed is not null)
                {
                    permissions.Add(parsed);
                }
            }

            _logger.LogInformation("Fetched permissions (file_path={FilePath}, count={Count})", filePath, permissions.Count);

            return new FilePermissions
            {
                FilePath = filePath,
                FileId = fileId,
                Permissions = permissions,
                SyncedAt = DateTimeOffset.UtcNow,
            };
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to fetch permissions (file_path={FilePath})", filePath);
            throw;
        }
    }

    private SharePointPermission? ParsePermission(Permission perm)
    {
        try
        {
            var permId = perm.Id ?? string.Empty;
            var roles = perm.Roles is null ? new List<string>() : new List<string>(perm.Roles);
            var inherited = perm.InheritedFrom is not null;

            var identityType = "unknown";
            var displayName = string.Empty;
            string? email = null;
            string? identityId = null;

            if (perm.GrantedToV2 is { } gtv2)
            {
                if (gtv2.User is { } user)
                {
                    identityType = "user";
                    displayName = user.DisplayName ?? string.Empty;
                    identityId = user.Id;
                    if (user.AdditionalData?.TryGetValue("email", out var emObj) == true && emObj is string emStr)
                    {
                        email = emStr;
                    }
                }
                else if (gtv2.Group is { } group)
                {
                    identityType = "group";
                    displayName = group.DisplayName ?? string.Empty;
                    identityId = group.Id;
                    if (group.AdditionalData?.TryGetValue("email", out var grEmObj) == true && grEmObj is string grEm)
                    {
                        email = grEm;
                    }
                }
                else if (gtv2.SiteGroup is { } siteGroup)
                {
                    identityType = "siteGroup";
                    displayName = siteGroup.DisplayName ?? string.Empty;
                    identityId = siteGroup.Id;
                }
                else if (gtv2.SiteUser is { } siteUser)
                {
                    identityType = "user";
                    displayName = siteUser.DisplayName ?? string.Empty;
                    identityId = siteUser.Id;
                    if (siteUser.AdditionalData?.TryGetValue("email", out var suEmObj) == true && suEmObj is string suEm)
                    {
                        email = suEm;
                    }
                }
            }
            else if (perm.GrantedTo?.User is { } legacyUser)
            {
                identityType = "user";
                displayName = legacyUser.DisplayName ?? string.Empty;
                identityId = legacyUser.Id;
                if (legacyUser.AdditionalData?.TryGetValue("email", out var legEmObj) == true && legEmObj is string legEm)
                {
                    email = legEm;
                }
            }

            return new SharePointPermission
            {
                Id = permId,
                Roles = roles,
                IdentityType = identityType,
                DisplayName = displayName,
                Email = email,
                IdentityId = identityId,
                Inherited = inherited,
            };
        }
        catch (Exception ex)
        {
            _logger.LogWarning("Failed to parse permission (error={Error})", ex.Message);
            return null;
        }
    }

    public ValueTask DisposeAsync() => ValueTask.CompletedTask;
}
