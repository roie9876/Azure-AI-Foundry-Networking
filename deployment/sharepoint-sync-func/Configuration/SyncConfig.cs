using System;
using System.Collections.Generic;
using System.Linq;

namespace SharePointSyncFunc.Configuration;

public enum PermissionsDeltaMode
{
    Hash,
    GraphDelta
}

public sealed class SyncConfig
{
    public string SharePointSiteUrl { get; init; } = string.Empty;
    public string SharePointDriveName { get; init; } = "Documents";
    public string SharePointFolderPath { get; init; } = "/";
    public List<string> SharePointFolderPaths { get; init; } = new() { "/" };
    public List<string> IncludeExtensions { get; init; } = new();
    public List<string> ExcludeExtensions { get; init; } = new();

    public string StorageAccountName { get; init; } = string.Empty;
    public string ContainerName { get; init; } = "sharepoint-sync";
    public string BlobPrefix { get; init; } = string.Empty;

    public bool DeleteOrphanedBlobs { get; init; }
    public bool SoftDeleteOrphanedBlobs { get; init; } = true;
    public bool DryRun { get; init; }

    public PermissionsDeltaMode PermissionsDeltaMode { get; init; } = PermissionsDeltaMode.Hash;
    public string DeltaTokenStoragePath { get; init; } = ".delta_tokens";

    public bool SyncPermissions { get; init; }
    public bool SyncPurviewProtection { get; init; }

    public string SharePointSiteId { get; set; } = string.Empty;
    public string SharePointDriveId { get; set; } = string.Empty;

    public string BlobAccountUrl => $"https://{StorageAccountName}.blob.core.windows.net";

    public (string Host, string Path) SharePointHostAndPath
    {
        get
        {
            var uri = new Uri(SharePointSiteUrl);
            return (uri.Host, uri.AbsolutePath);
        }
    }

    public static SyncConfig FromEnvironment()
    {
        var deltaModeStr = (Environment.GetEnvironmentVariable("PERMISSIONS_DELTA_MODE") ?? "hash").ToLowerInvariant();
        var deltaMode = deltaModeStr switch
        {
            "graph_delta" => PermissionsDeltaMode.GraphDelta,
            _ => PermissionsDeltaMode.Hash,
        };

        var rawFolderPath = Environment.GetEnvironmentVariable("SHAREPOINT_FOLDER_PATH") ?? "/";
        var folderPaths = rawFolderPath
            .Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries)
            .ToList();
        if (folderPaths.Count == 0)
        {
            folderPaths.Add("/");
        }

        return new SyncConfig
        {
            SharePointSiteUrl = Environment.GetEnvironmentVariable("SHAREPOINT_SITE_URL") ?? string.Empty,
            SharePointDriveName = Environment.GetEnvironmentVariable("SHAREPOINT_DRIVE_NAME") ?? "Documents",
            SharePointFolderPath = rawFolderPath,
            SharePointFolderPaths = folderPaths,
            IncludeExtensions = ParseExtensions(Environment.GetEnvironmentVariable("SHAREPOINT_INCLUDE_EXTENSIONS")),
            ExcludeExtensions = ParseExtensions(Environment.GetEnvironmentVariable("SHAREPOINT_EXCLUDE_EXTENSIONS")),

            StorageAccountName = Environment.GetEnvironmentVariable("AZURE_STORAGE_ACCOUNT_NAME") ?? string.Empty,
            ContainerName = Environment.GetEnvironmentVariable("AZURE_BLOB_CONTAINER_NAME") ?? "sharepoint-sync",
            BlobPrefix = Environment.GetEnvironmentVariable("AZURE_BLOB_PREFIX") ?? string.Empty,

            DeleteOrphanedBlobs = ParseBool("DELETE_ORPHANED_BLOBS", false),
            SoftDeleteOrphanedBlobs = ParseBool("SOFT_DELETE_ORPHANED_BLOBS", true),
            DryRun = ParseBool("DRY_RUN", false),

            PermissionsDeltaMode = deltaMode,
            DeltaTokenStoragePath = Environment.GetEnvironmentVariable("DELTA_TOKEN_STORAGE_PATH") ?? ".delta_tokens",

            SyncPermissions = ParseBool("SYNC_PERMISSIONS", false),
            SyncPurviewProtection = ParseBool("SYNC_PURVIEW_PROTECTION", false),
        };
    }

    public void Validate()
    {
        var errors = new List<string>();

        if (string.IsNullOrWhiteSpace(SharePointSiteUrl))
        {
            errors.Add("SHAREPOINT_SITE_URL is required (e.g., https://contoso.sharepoint.com/sites/MySite)");
        }
        if (string.IsNullOrWhiteSpace(StorageAccountName))
        {
            errors.Add("AZURE_STORAGE_ACCOUNT_NAME is required");
        }
        if (string.IsNullOrWhiteSpace(ContainerName))
        {
            errors.Add("AZURE_BLOB_CONTAINER_NAME is required");
        }

        if (errors.Count > 0)
        {
            throw new InvalidOperationException($"Configuration errors: {string.Join(", ", errors)}");
        }
    }

    private static List<string> ParseExtensions(string? raw)
    {
        var result = new List<string>();
        if (string.IsNullOrWhiteSpace(raw))
        {
            return result;
        }

        foreach (var token in raw.Split(','))
        {
            var t = token.Trim().ToLowerInvariant().TrimStart('*');
            if (string.IsNullOrEmpty(t))
            {
                continue;
            }

            if (!t.StartsWith('.'))
            {
                t = "." + t;
            }
            result.Add(t);
        }

        return result;
    }

    private static bool ParseBool(string envName, bool defaultValue)
    {
        var raw = Environment.GetEnvironmentVariable(envName);
        if (string.IsNullOrWhiteSpace(raw))
        {
            return defaultValue;
        }

        return raw.Trim().Equals("true", StringComparison.OrdinalIgnoreCase);
    }
}
