using System;
using System.Collections.Generic;

namespace SharePointSyncFunc.Models;

public enum FileChangeType
{
    Added,
    Modified,
    Deleted
}

public sealed class SharePointFile
{
    public string Id { get; init; } = string.Empty;
    public string Name { get; init; } = string.Empty;
    public string Path { get; init; } = string.Empty;
    public long Size { get; init; }
    public DateTimeOffset? LastModified { get; init; }
    public string? DownloadUrl { get; init; }
    public string? ContentHash { get; init; }
    public FileChangeType? ChangeType { get; init; }
    public string? WebUrl { get; init; }
}

public enum DeltaChangeType
{
    CreatedOrModified,
    Deleted
}

public sealed class DeltaChange
{
    public DeltaChangeType ChangeType { get; init; }
    public SharePointFile? File { get; init; }
    public string ItemId { get; init; } = string.Empty;
    public string ItemName { get; init; } = string.Empty;
    public string ItemPath { get; init; } = string.Empty;
    public bool IsFolder { get; init; }
}

public sealed class DeltaResult
{
    public List<DeltaChange> Changes { get; init; } = new();
    public string DeltaToken { get; init; } = string.Empty;
    public bool IsInitialSync { get; init; }
}

public sealed class DeltaToken
{
    public string DriveId { get; init; } = string.Empty;
    public string Token { get; init; } = string.Empty;
    public DateTimeOffset LastUpdated { get; init; }
    public string TokenType { get; init; } = "files";
}

public sealed class PermissionChangedItem
{
    public string ItemId { get; init; } = string.Empty;
    public string Name { get; init; } = string.Empty;
    public string Path { get; init; } = string.Empty;
    public bool SharingChanged { get; init; }
}
