using System;
using System.Collections.Generic;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using SharePointSyncFunc.Models;

namespace SharePointSyncFunc.Models;

public sealed class SharePointPermission
{
    public string Id { get; init; } = string.Empty;
    public List<string> Roles { get; init; } = new();
    public string IdentityType { get; init; } = "unknown";
    public string DisplayName { get; init; } = string.Empty;
    public string? Email { get; init; }
    public string? IdentityId { get; init; }
    public bool Inherited { get; init; }

    public Dictionary<string, object?> ToDict() => new()
    {
        ["id"] = Id,
        ["roles"] = Roles,
        ["identity_type"] = IdentityType,
        ["display_name"] = DisplayName,
        ["email"] = Email,
        ["identity_id"] = IdentityId,
        ["inherited"] = Inherited,
    };

    public static SharePointPermission FromDict(JsonElement el)
    {
        var roles = new List<string>();
        if (el.TryGetProperty("roles", out var rolesEl) && rolesEl.ValueKind == JsonValueKind.Array)
        {
            roles.AddRange(rolesEl.EnumerateArray().Select(x => x.GetString() ?? string.Empty));
        }

        return new SharePointPermission
        {
            Id = el.TryGetProperty("id", out var id) ? id.GetString() ?? string.Empty : string.Empty,
            Roles = roles,
            IdentityType = el.TryGetProperty("identity_type", out var it) ? it.GetString() ?? "unknown" : "unknown",
            DisplayName = el.TryGetProperty("display_name", out var dn) ? dn.GetString() ?? string.Empty : string.Empty,
            Email = el.TryGetProperty("email", out var em) && em.ValueKind != JsonValueKind.Null ? em.GetString() : null,
            IdentityId = el.TryGetProperty("identity_id", out var iid) && iid.ValueKind != JsonValueKind.Null ? iid.GetString() : null,
            Inherited = el.TryGetProperty("inherited", out var inh) && inh.ValueKind == JsonValueKind.True,
        };
    }
}

public sealed class FilePermissions
{
    public string FilePath { get; init; } = string.Empty;
    public string FileId { get; init; } = string.Empty;
    public List<SharePointPermission> Permissions { get; init; } = new();
    public DateTimeOffset? SyncedAt { get; init; }

    public Dictionary<string, string> ToMetadata(FileProtectionInfo? protectionInfo = null)
    {
        var permissionsJson = JsonSerializer.Serialize(Permissions.Select(p => p.ToDict()).ToList());

        var spUserIds = ExtractUserIds();
        var spGroupIds = ExtractGroupIds();

        var (effectiveUserIds, effectiveGroupIds) = PermissionMerger.MergePermissionsForSearch(
            spUserIds, spGroupIds, protectionInfo);

        var metadata = new Dictionary<string, string>
        {
            ["sharepoint_permissions"] = permissionsJson,
            ["permissions_synced_at"] = (SyncedAt ?? DateTimeOffset.UtcNow).ToString("o"),
            ["permissions_hash"] = ComputePermissionsHash(),
        };

        if (protectionInfo is not null)
        {
            foreach (var kvp in protectionInfo.ToMetadata())
            {
                metadata[kvp.Key] = kvp.Value;
            }
        }

        const string placeholderNoUsers = "00000000-0000-0000-0000-000000000000";
        const string placeholderNoGroups = "00000000-0000-0000-0000-000000000001";

        metadata["user_ids"] = effectiveUserIds.Count > 0
            ? string.Join("|", effectiveUserIds)
            : placeholderNoUsers;
        metadata["group_ids"] = effectiveGroupIds.Count > 0
            ? string.Join("|", effectiveGroupIds)
            : placeholderNoGroups;

        return metadata;
    }

    public string ComputePermissionsHash()
    {
        if (Permissions.Count == 0)
        {
            return Sha256("no_permissions").Substring(0, 16);
        }

        var normalized = Permissions
            .Select(p => new
            {
                identity_id = p.IdentityId ?? string.Empty,
                identity_type = p.IdentityType,
                roles = p.Roles.OrderBy(r => r, StringComparer.Ordinal).ToList(),
            })
            .OrderBy(x => x.identity_id, StringComparer.Ordinal)
            .ThenBy(x => x.identity_type, StringComparer.Ordinal)
            .Select(x => new object[] { x.identity_id, x.identity_type, x.roles })
            .ToList();

        var permString = JsonSerializer.Serialize(normalized);
        return Sha256(permString).Substring(0, 16);
    }

    private List<string> ExtractUserIds() => Permissions
        .Where(p => p.IdentityType == "user" && !string.IsNullOrEmpty(p.IdentityId) && IsValidGuid(p.IdentityId!))
        .Select(p => p.IdentityId!)
        .Distinct()
        .ToList();

    private List<string> ExtractGroupIds() => Permissions
        .Where(p => p.IdentityType == "group" && !string.IsNullOrEmpty(p.IdentityId) && IsValidGuid(p.IdentityId!))
        .Select(p => p.IdentityId!)
        .Distinct()
        .ToList();

    private static readonly Regex GuidRegex = new(
        @"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$",
        RegexOptions.Compiled);

    private static bool IsValidGuid(string value) =>
        !string.IsNullOrEmpty(value) && GuidRegex.IsMatch(value);

    private static string Sha256(string input)
    {
        var bytes = SHA256.HashData(Encoding.UTF8.GetBytes(input));
        var sb = new StringBuilder(bytes.Length * 2);
        foreach (var b in bytes)
        {
            sb.Append(b.ToString("x2"));
        }
        return sb.ToString();
    }

    public static FilePermissions FromMetadata(string filePath, string fileId, IDictionary<string, string> metadata)
    {
        var permissionsJson = metadata.TryGetValue("sharepoint_permissions", out var pj) ? pj : "[]";
        var syncedAtStr = metadata.TryGetValue("permissions_synced_at", out var sa) ? sa : null;

        var permissions = new List<SharePointPermission>();
        try
        {
            using var doc = JsonDocument.Parse(permissionsJson);
            if (doc.RootElement.ValueKind == JsonValueKind.Array)
            {
                foreach (var el in doc.RootElement.EnumerateArray())
                {
                    permissions.Add(SharePointPermission.FromDict(el));
                }
            }
        }
        catch (JsonException)
        {
            // ignore malformed metadata
        }

        DateTimeOffset? syncedAt = null;
        if (!string.IsNullOrEmpty(syncedAtStr) &&
            DateTimeOffset.TryParse(syncedAtStr, out var parsed))
        {
            syncedAt = parsed;
        }

        return new FilePermissions
        {
            FilePath = filePath,
            FileId = fileId,
            Permissions = permissions,
            SyncedAt = syncedAt,
        };
    }
}

public static class PermissionsHelpers
{
    public static string PermissionsToSummary(List<SharePointPermission> permissions)
    {
        if (permissions.Count == 0)
        {
            return "No permissions";
        }

        var parts = new List<string>();
        foreach (var p in permissions)
        {
            var rolesStr = string.Join(",", p.Roles);
            parts.Add(string.IsNullOrEmpty(p.Email)
                ? $"{p.DisplayName}:{rolesStr}"
                : $"{p.DisplayName}<{p.Email}>:{rolesStr}");
        }
        return string.Join("; ", parts);
    }

    public static bool ShouldSyncPermissions(FilePermissions filePermissions, IDictionary<string, string>? existingMetadata)
    {
        if (existingMetadata is null)
        {
            return true;
        }

        if (!existingMetadata.TryGetValue("permissions_hash", out var storedHash) || string.IsNullOrEmpty(storedHash))
        {
            return true;
        }

        var currentHash = filePermissions.ComputePermissionsHash();
        return storedHash != currentHash;
    }
}
