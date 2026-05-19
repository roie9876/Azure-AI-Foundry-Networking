using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using Microsoft.Extensions.Logging;

namespace SharePointSyncFunc.Models;

public enum ProtectionStatus
{
    Unprotected,
    Protected,
    LabelOnly,
    Unknown
}

public static class ProtectionStatusExtensions
{
    public static string ToValue(this ProtectionStatus status) => status switch
    {
        ProtectionStatus.Unprotected => "unprotected",
        ProtectionStatus.Protected => "protected",
        ProtectionStatus.LabelOnly => "label_only",
        ProtectionStatus.Unknown => "unknown",
        _ => "unknown",
    };

    public static ProtectionStatus FromValue(string value) => value switch
    {
        "unprotected" => ProtectionStatus.Unprotected,
        "protected" => ProtectionStatus.Protected,
        "label_only" => ProtectionStatus.LabelOnly,
        _ => ProtectionStatus.Unknown,
    };
}

public sealed class RMSPermissionEntry
{
    public string Identity { get; init; } = string.Empty;
    public string IdentityType { get; init; } = "unknown";
    public string DisplayName { get; init; } = string.Empty;
    public string? EntraObjectId { get; init; }
    public List<string> UsageRights { get; init; } = new();

    private static readonly HashSet<string> ViewRights = new()
    {
        "VIEW", "EDIT", "OWNER", "DOCEDIT", "EXTRACT", "OBJMODEL"
    };

    public bool HasViewAccess() => UsageRights.Any(r => ViewRights.Contains(r));

    public Dictionary<string, object?> ToDict() => new()
    {
        ["identity"] = Identity,
        ["identity_type"] = IdentityType,
        ["display_name"] = DisplayName,
        ["entra_object_id"] = EntraObjectId,
        ["usage_rights"] = UsageRights,
    };

    public static RMSPermissionEntry FromDict(JsonElement el)
    {
        var rights = new List<string>();
        if (el.TryGetProperty("usage_rights", out var ur) && ur.ValueKind == JsonValueKind.Array)
        {
            rights.AddRange(ur.EnumerateArray().Select(x => x.GetString() ?? string.Empty));
        }

        return new RMSPermissionEntry
        {
            Identity = el.TryGetProperty("identity", out var id) ? id.GetString() ?? string.Empty : string.Empty,
            IdentityType = el.TryGetProperty("identity_type", out var it) ? it.GetString() ?? "unknown" : "unknown",
            DisplayName = el.TryGetProperty("display_name", out var dn) ? dn.GetString() ?? string.Empty : string.Empty,
            EntraObjectId = el.TryGetProperty("entra_object_id", out var eo) && eo.ValueKind != JsonValueKind.Null ? eo.GetString() : null,
            UsageRights = rights,
        };
    }
}

public sealed class SensitivityLabelInfo
{
    public string LabelId { get; init; } = string.Empty;
    public string LabelName { get; init; } = string.Empty;
    public bool IsEncrypted { get; init; }
    public string AssignmentMethod { get; init; } = "standard";
    public string? Tooltip { get; init; }
    public string? Color { get; init; }
    public string? ParentLabelName { get; init; }
}

public sealed class FileProtectionInfo
{
    public string FileId { get; init; } = string.Empty;
    public string FilePath { get; init; } = string.Empty;
    public ProtectionStatus Status { get; init; } = ProtectionStatus.Unknown;
    public SensitivityLabelInfo? SensitivityLabel { get; init; }
    public List<RMSPermissionEntry> RmsPermissions { get; init; } = new();
    public DateTimeOffset? DetectedAt { get; init; }

    public List<string> GetUserIdsWithViewAccess() => RmsPermissions
        .Where(p => p.IdentityType == "user" && p.HasViewAccess() && !string.IsNullOrEmpty(p.EntraObjectId))
        .Select(p => p.EntraObjectId!)
        .Distinct()
        .ToList();

    public List<string> GetGroupIdsWithViewAccess() => RmsPermissions
        .Where(p => p.IdentityType == "group" && p.HasViewAccess() && !string.IsNullOrEmpty(p.EntraObjectId))
        .Select(p => p.EntraObjectId!)
        .Distinct()
        .ToList();

    public Dictionary<string, string> ToMetadata()
    {
        var metadata = new Dictionary<string, string>
        {
            ["purview_protection_status"] = Status.ToValue(),
        };

        if (SensitivityLabel is not null)
        {
            metadata["purview_label_id"] = SensitivityLabel.LabelId;
            metadata["purview_label_name"] = SensitivityLabel.LabelName;
            metadata["purview_is_encrypted"] = SensitivityLabel.IsEncrypted ? "true" : "false";
        }

        if (RmsPermissions.Count > 0)
        {
            metadata["purview_rms_permissions"] = JsonSerializer.Serialize(
                RmsPermissions.Select(p => p.ToDict()).ToList());
        }

        if (DetectedAt is not null)
        {
            metadata["purview_detected_at"] = DetectedAt.Value.ToString("o");
        }

        return metadata;
    }
}

public static class PermissionMerger
{
    public static (List<string> EffectiveUserIds, List<string> EffectiveGroupIds) MergePermissionsForSearch(
        List<string> spUserIds,
        List<string> spGroupIds,
        FileProtectionInfo? protectionInfo,
        ILogger? logger = null)
    {
        if (protectionInfo is null ||
            protectionInfo.Status is ProtectionStatus.Unprotected
                or ProtectionStatus.LabelOnly
                or ProtectionStatus.Unknown)
        {
            return (spUserIds, spGroupIds);
        }

        var rmsUserIds = protectionInfo.GetUserIdsWithViewAccess().ToHashSet();
        var rmsGroupIds = protectionInfo.GetGroupIdsWithViewAccess().ToHashSet();

        var spUserSet = spUserIds.ToHashSet();
        var spGroupSet = spGroupIds.ToHashSet();

        if (rmsUserIds.Count == 0 && rmsGroupIds.Count == 0)
        {
            logger?.LogWarning(
                "RMS-protected file has no extractable permissions, falling back to SharePoint permissions only (file_id={FileId}, file_path={FilePath})",
                protectionInfo.FileId, protectionInfo.FilePath);
            return (spUserIds, spGroupIds);
        }

        var effectiveUsers = rmsUserIds.Count > 0 ? spUserSet.Intersect(rmsUserIds).ToList() : spUserIds;
        var effectiveGroups = rmsGroupIds.Count > 0 ? spGroupSet.Intersect(rmsGroupIds).ToList() : spGroupIds;

        logger?.LogInformation(
            "Merged SP + RMS permissions (file={FilePath}, sp_users={SpUsers}, rms_users={RmsUsers}, effective_users={EffUsers}, sp_groups={SpGroups}, rms_groups={RmsGroups}, effective_groups={EffGroups})",
            protectionInfo.FilePath, spUserIds.Count, rmsUserIds.Count, effectiveUsers.Count,
            spGroupIds.Count, rmsGroupIds.Count, effectiveGroups.Count);

        return (effectiveUsers, effectiveGroups);
    }
}
