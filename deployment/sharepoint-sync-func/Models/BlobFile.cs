using System;
using System.Collections.Generic;

namespace SharePointSyncFunc.Models;

public sealed class BlobFile
{
    public string Name { get; init; } = string.Empty;
    public long Size { get; init; }
    public DateTimeOffset LastModified { get; init; }
    public string? ContentHash { get; init; }
    public IDictionary<string, string>? Metadata { get; init; }
}
