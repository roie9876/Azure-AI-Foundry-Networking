namespace SharePointSyncFunc.Services;

public sealed class SyncStats
{
    public int FilesScanned { get; set; }
    public int FilesAdded { get; set; }
    public int FilesUpdated { get; set; }
    public int FilesDeleted { get; set; }
    public int FilesUnchanged { get; set; }
    public int FilesFailed { get; set; }
    public long BytesTransferred { get; set; }
    public int PermissionsSynced { get; set; }
    public int PermissionsUnchanged { get; set; }
    public int PermissionsFailed { get; set; }
    public int PurviewProtected { get; set; }
    public int PurviewLabelOnly { get; set; }
    public int PurviewUnprotected { get; set; }
    public int PurviewFailed { get; set; }
    public int RmsDownloadFailed { get; set; }
    public string SyncMode { get; set; } = "full";
}
