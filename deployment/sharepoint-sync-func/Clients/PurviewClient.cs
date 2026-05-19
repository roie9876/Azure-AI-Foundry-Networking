using System;
using System.Collections.Generic;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Azure.Core;
using Microsoft.Extensions.Logging;
using SharePointSyncFunc.Models;

namespace SharePointSyncFunc.Clients;

/// <summary>
/// Microsoft Purview / RMS client. Detects sensitivity labels and extracts RMS
/// protection permissions from SharePoint files via Microsoft Graph. Mirrors
/// the Python PurviewClient.
/// </summary>
public sealed class PurviewClient : IAsyncDisposable
{
    private static readonly string[] LabelEndpoints =
    {
        "https://graph.microsoft.com/v1.0/security/informationProtection/sensitivityLabels",
        "https://graph.microsoft.com/beta/security/informationProtection/sensitivityLabels",
    };

    private readonly string _driveId;
    private readonly ILogger _logger;
    private readonly TokenCredential _credential;
    private readonly HttpClient _httpClient;
    private readonly Dictionary<string, SensitivityLabelInfo> _labelCache = new();

    public PurviewClient(string driveId, ILogger logger)
    {
        _driveId = driveId;
        _logger = logger;
        _credential = CredentialFactory.GetSharePointCredential(logger);
        _httpClient = new HttpClient(new GraphTokenAuthHandler(_credential) { InnerHandler = new HttpClientHandler() })
        {
            Timeout = TimeSpan.FromSeconds(60),
        };
    }

    public async Task InitializeAsync(CancellationToken cancellationToken = default)
    {
        await LoadSensitivityLabelsAsync(cancellationToken).ConfigureAwait(false);
    }

    private async Task LoadSensitivityLabelsAsync(CancellationToken cancellationToken)
    {
        try
        {
            HttpResponseMessage? response = null;
            foreach (var url in LabelEndpoints)
            {
                response?.Dispose();
                response = await _httpClient.GetAsync(url, cancellationToken).ConfigureAwait(false);
                if ((int)response.StatusCode == 200)
                {
                    _logger.LogInformation("Loaded sensitivity labels from endpoint (url={Url})", url);
                    break;
                }
                _logger.LogDebug("Label endpoint not available, trying next (url={Url}, status={Status})",
                    url, (int)response.StatusCode);
            }

            if (response is null)
            {
                return;
            }

            if ((int)response.StatusCode == 403)
            {
                _logger.LogWarning(
                    "No permission to read sensitivity labels (InformationProtectionPolicy.Read.All required). " +
                    "Will detect labels per-file from driveItem properties.");
                response.Dispose();
                return;
            }

            if ((int)response.StatusCode != 200)
            {
                var body = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
                _logger.LogWarning("Failed to load sensitivity labels (status={Status}, body={BodyPreview})",
                    (int)response.StatusCode, body.Length > 500 ? body.Substring(0, 500) : body);
                response.Dispose();
                return;
            }

            await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
            using var doc = await JsonDocument.ParseAsync(stream, cancellationToken: cancellationToken).ConfigureAwait(false);
            response.Dispose();

            if (doc.RootElement.TryGetProperty("value", out var values) && values.ValueKind == JsonValueKind.Array)
            {
                foreach (var label in values.EnumerateArray())
                {
                    var labelId = label.TryGetProperty("id", out var idEl) ? idEl.GetString() ?? string.Empty : string.Empty;
                    var name = label.TryGetProperty("name", out var nm) ? nm.GetString() ?? string.Empty : string.Empty;
                    string? tooltip = label.TryGetProperty("tooltip", out var tt) && tt.ValueKind == JsonValueKind.String ? tt.GetString() : null;
                    string? color = label.TryGetProperty("color", out var col) && col.ValueKind == JsonValueKind.String ? col.GetString() : null;
                    string? parentName = null;
                    if (label.TryGetProperty("parent", out var parentEl) && parentEl.ValueKind == JsonValueKind.Object &&
                        parentEl.TryGetProperty("name", out var pnEl) && pnEl.ValueKind == JsonValueKind.String)
                    {
                        parentName = pnEl.GetString();
                    }

                    var info = new SensitivityLabelInfo
                    {
                        LabelId = labelId,
                        LabelName = name,
                        IsEncrypted = LabelHasEncryption(label),
                        AssignmentMethod = "standard",
                        Tooltip = tooltip,
                        Color = color,
                        ParentLabelName = parentName,
                    };
                    _labelCache[labelId] = info;
                }
            }

            var encryptedCount = 0;
            foreach (var l in _labelCache.Values)
            {
                if (l.IsEncrypted) encryptedCount++;
            }
            _logger.LogInformation("Loaded sensitivity labels (total={Total}, encrypted={Encrypted})",
                _labelCache.Count, encryptedCount);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error loading sensitivity labels");
        }
    }

    private static bool LabelHasEncryption(JsonElement labelData)
    {
        if (labelData.TryGetProperty("hasProtection", out var hp))
        {
            return hp.ValueKind == JsonValueKind.True;
        }
        if (labelData.TryGetProperty("isEncryptingContent", out var ec) && ec.ValueKind == JsonValueKind.True)
        {
            return true;
        }
        return false;
    }

    public async Task<FileProtectionInfo> GetFileProtectionAsync(
        string fileId, string filePath, CancellationToken cancellationToken = default)
    {
        _logger.LogInformation("Checking file protection (file_path={Path}, file_id={Id})", filePath, fileId);

        try
        {
            var labelInfo = await GetItemSensitivityLabelAsync(fileId, filePath, cancellationToken).ConfigureAwait(false);

            if (labelInfo is null)
            {
                return new FileProtectionInfo
                {
                    FileId = fileId,
                    FilePath = filePath,
                    Status = ProtectionStatus.Unprotected,
                    DetectedAt = DateTimeOffset.UtcNow,
                };
            }

            if (!labelInfo.IsEncrypted)
            {
                return new FileProtectionInfo
                {
                    FileId = fileId,
                    FilePath = filePath,
                    Status = ProtectionStatus.LabelOnly,
                    SensitivityLabel = labelInfo,
                    DetectedAt = DateTimeOffset.UtcNow,
                };
            }

            var rms = await ExtractRmsPermissionsAsync(fileId, filePath, cancellationToken).ConfigureAwait(false);
            _logger.LogInformation(
                "File is RMS-protected (file_path={Path}, label={Label}, rms_perm_count={Count})",
                filePath, labelInfo.LabelName, rms.Count);

            return new FileProtectionInfo
            {
                FileId = fileId,
                FilePath = filePath,
                Status = ProtectionStatus.Protected,
                SensitivityLabel = labelInfo,
                RmsPermissions = rms,
                DetectedAt = DateTimeOffset.UtcNow,
            };
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to get file protection info (file_path={Path})", filePath);
            return new FileProtectionInfo
            {
                FileId = fileId,
                FilePath = filePath,
                Status = ProtectionStatus.Unknown,
                DetectedAt = DateTimeOffset.UtcNow,
            };
        }
    }

    private async Task<SensitivityLabelInfo?> GetItemSensitivityLabelAsync(
        string fileId, string filePath, CancellationToken cancellationToken)
    {
        try
        {
            var url = $"https://graph.microsoft.com/v1.0/drives/{_driveId}/items/{fileId}?$select=id,name,sensitivityLabel";
            using var resp = await _httpClient.GetAsync(url, cancellationToken).ConfigureAwait(false);

            if ((int)resp.StatusCode == 403)
            {
                _logger.LogWarning("No permission to read sensitivity label on item (file_path={Path})", filePath);
                return null;
            }

            if ((int)resp.StatusCode != 200)
            {
                _logger.LogWarning("Failed to get sensitivity label (file_path={Path}, status={Status})",
                    filePath, (int)resp.StatusCode);
                return null;
            }

            await using var stream = await resp.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
            using var doc = await JsonDocument.ParseAsync(stream, cancellationToken: cancellationToken).ConfigureAwait(false);

            if (!doc.RootElement.TryGetProperty("sensitivityLabel", out var labelEl) ||
                labelEl.ValueKind != JsonValueKind.Object)
            {
                return null;
            }

            var labelId = labelEl.TryGetProperty("labelId", out var lid) && lid.ValueKind == JsonValueKind.String
                ? lid.GetString() ?? string.Empty
                : string.Empty;
            var displayName = labelEl.TryGetProperty("displayName", out var dn) && dn.ValueKind == JsonValueKind.String
                ? dn.GetString() ?? string.Empty
                : string.Empty;

            if (string.IsNullOrEmpty(labelId))
            {
                _logger.LogDebug("sensitivityLabel present but labelId is empty (file_path={Path})", filePath);
                return null;
            }

            var assignmentMethod = labelEl.TryGetProperty("assignmentMethod", out var am) && am.ValueKind == JsonValueKind.String
                ? am.GetString() ?? "standard"
                : "standard";

            _labelCache.TryGetValue(labelId, out var cached);

            return new SensitivityLabelInfo
            {
                LabelId = labelId,
                LabelName = !string.IsNullOrEmpty(displayName) ? displayName : (cached?.LabelName ?? "Unknown"),
                IsEncrypted = cached?.IsEncrypted ?? false,
                AssignmentMethod = assignmentMethod,
                Tooltip = cached?.Tooltip,
                ParentLabelName = cached?.ParentLabelName,
            };
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error reading sensitivity label (file_path={Path})", filePath);
            return null;
        }
    }

    private async Task<List<RMSPermissionEntry>> ExtractRmsPermissionsAsync(
        string fileId, string filePath, CancellationToken cancellationToken)
    {
        var via = await TryExtractLabelsEndpointAsync(fileId, filePath, cancellationToken).ConfigureAwait(false);
        if (via.Count > 0)
        {
            return via;
        }

        return await GetPermissionsAsRmsFallbackAsync(fileId, filePath, cancellationToken).ConfigureAwait(false);
    }

    private async Task<List<RMSPermissionEntry>> TryExtractLabelsEndpointAsync(
        string fileId, string filePath, CancellationToken cancellationToken)
    {
        try
        {
            var url = $"https://graph.microsoft.com/v1.0/drives/{_driveId}/items/{fileId}/extractSensitivityLabels";
            using var content = new StringContent("{}", Encoding.UTF8, "application/json");
            using var resp = await _httpClient.PostAsync(url, content, cancellationToken).ConfigureAwait(false);

            if ((int)resp.StatusCode == 404 || (int)resp.StatusCode == 403)
            {
                _logger.LogDebug(
                    "extractSensitivityLabels not available, using fallback (file_path={Path}, status={Status})",
                    filePath, (int)resp.StatusCode);
                return new List<RMSPermissionEntry>();
            }

            if ((int)resp.StatusCode != 200)
            {
                _logger.LogDebug("extractSensitivityLabels failed (file_path={Path}, status={Status})",
                    filePath, (int)resp.StatusCode);
                return new List<RMSPermissionEntry>();
            }

            await using var stream = await resp.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
            using var doc = await JsonDocument.ParseAsync(stream, cancellationToken: cancellationToken).ConfigureAwait(false);

            var permissions = new List<RMSPermissionEntry>();
            if (!doc.RootElement.TryGetProperty("labels", out var labels) || labels.ValueKind != JsonValueKind.Array)
            {
                return permissions;
            }

            foreach (var label in labels.EnumerateArray())
            {
                if (!label.TryGetProperty("protectionSettings", out var ps) || ps.ValueKind != JsonValueKind.Object)
                {
                    continue;
                }

                var usageRights = new List<string>();
                if (ps.TryGetProperty("usageRights", out var ur) && ur.ValueKind == JsonValueKind.Array)
                {
                    foreach (var r in ur.EnumerateArray())
                    {
                        if (r.ValueKind == JsonValueKind.String)
                        {
                            usageRights.Add(r.GetString() ?? string.Empty);
                        }
                    }
                }

                if (ps.TryGetProperty("allowedUsers", out var users) && users.ValueKind == JsonValueKind.Array)
                {
                    foreach (var u in users.EnumerateArray())
                    {
                        permissions.Add(BuildEntryFromIdentity(u, "user", usageRights));
                    }
                }

                if (ps.TryGetProperty("allowedGroups", out var groups) && groups.ValueKind == JsonValueKind.Array)
                {
                    foreach (var g in groups.EnumerateArray())
                    {
                        permissions.Add(BuildEntryFromIdentity(g, "group", usageRights));
                    }
                }
            }

            return permissions;
        }
        catch (Exception ex)
        {
            _logger.LogDebug(ex, "Error with extractSensitivityLabels (file_path={Path})", filePath);
            return new List<RMSPermissionEntry>();
        }
    }

    private async Task<List<RMSPermissionEntry>> GetPermissionsAsRmsFallbackAsync(
        string fileId, string filePath, CancellationToken cancellationToken)
    {
        try
        {
            var url = $"https://graph.microsoft.com/v1.0/drives/{_driveId}/items/{fileId}/permissions";
            using var resp = await _httpClient.GetAsync(url, cancellationToken).ConfigureAwait(false);

            if ((int)resp.StatusCode != 200)
            {
                _logger.LogWarning(
                    "Failed to get permissions for RMS fallback (file_path={Path}, status={Status})",
                    filePath, (int)resp.StatusCode);
                return new List<RMSPermissionEntry>();
            }

            await using var stream = await resp.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
            using var doc = await JsonDocument.ParseAsync(stream, cancellationToken: cancellationToken).ConfigureAwait(false);

            var permissions = new List<RMSPermissionEntry>();
            if (!doc.RootElement.TryGetProperty("value", out var values) || values.ValueKind != JsonValueKind.Array)
            {
                return permissions;
            }

            foreach (var perm in values.EnumerateArray())
            {
                var roles = new List<string>();
                if (perm.TryGetProperty("roles", out var rolesEl) && rolesEl.ValueKind == JsonValueKind.Array)
                {
                    foreach (var r in rolesEl.EnumerateArray())
                    {
                        if (r.ValueKind == JsonValueKind.String)
                        {
                            roles.Add(r.GetString() ?? string.Empty);
                        }
                    }
                }
                var usageRights = SpRolesToRmsRights(roles);

                JsonElement granted = default;
                if (perm.TryGetProperty("grantedToV2", out var g1) && g1.ValueKind == JsonValueKind.Object)
                {
                    granted = g1;
                }
                else if (perm.TryGetProperty("grantedTo", out var g2) && g2.ValueKind == JsonValueKind.Object)
                {
                    granted = g2;
                }

                if (granted.ValueKind != JsonValueKind.Object)
                {
                    continue;
                }

                if (granted.TryGetProperty("user", out var user) && user.ValueKind == JsonValueKind.Object)
                {
                    permissions.Add(BuildEntryFromIdentity(user, "user", usageRights));
                }
                else if (granted.TryGetProperty("group", out var group) && group.ValueKind == JsonValueKind.Object)
                {
                    permissions.Add(BuildEntryFromIdentity(group, "group", usageRights));
                }
                else if (granted.TryGetProperty("siteUser", out var siteUser) && siteUser.ValueKind == JsonValueKind.Object)
                {
                    permissions.Add(BuildEntryFromIdentity(siteUser, "user", usageRights));
                }
            }

            _logger.LogInformation("RMS permissions via fallback (file_path={Path}, count={Count})",
                filePath, permissions.Count);
            return permissions;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error getting permissions for RMS fallback (file_path={Path})", filePath);
            return new List<RMSPermissionEntry>();
        }
    }

    private static RMSPermissionEntry BuildEntryFromIdentity(JsonElement identity, string identityType, List<string> usageRights)
    {
        var email = identity.TryGetProperty("email", out var em) && em.ValueKind == JsonValueKind.String ? em.GetString() : null;
        var id = identity.TryGetProperty("id", out var idEl) && idEl.ValueKind == JsonValueKind.String ? idEl.GetString() : null;
        var displayName = identity.TryGetProperty("displayName", out var dn) && dn.ValueKind == JsonValueKind.String ? dn.GetString() : null;

        return new RMSPermissionEntry
        {
            Identity = email ?? id ?? string.Empty,
            IdentityType = identityType,
            DisplayName = displayName ?? string.Empty,
            EntraObjectId = id,
            UsageRights = usageRights,
        };
    }

    private static List<string> SpRolesToRmsRights(List<string> roles)
    {
        var rights = new HashSet<string>();
        foreach (var role in roles)
        {
            var lower = role.ToLowerInvariant();
            if (lower == "owner" || lower == "sp.full control")
            {
                rights.UnionWith(new[] { "VIEW", "EDIT", "SAVE", "PRINT", "COPY", "EXPORT", "OWNER" });
            }
            else if (lower == "write" || lower == "edit" || lower == "contribute")
            {
                rights.UnionWith(new[] { "VIEW", "EDIT", "SAVE", "PRINT", "COPY" });
            }
            else if (lower == "read")
            {
                rights.Add("VIEW");
            }
        }
        return rights.Count > 0 ? new List<string>(rights) : new List<string> { "VIEW" };
    }

    public ValueTask DisposeAsync()
    {
        _httpClient.Dispose();
        return ValueTask.CompletedTask;
    }
}
