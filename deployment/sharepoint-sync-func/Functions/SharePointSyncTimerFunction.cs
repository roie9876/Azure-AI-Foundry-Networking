using System;
using System.Threading.Tasks;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;
using SharePointSyncFunc.Services;

namespace SharePointSyncFunc.Functions;

public sealed class SharePointSyncTimerFunction
{
    private readonly SyncOrchestrator _orchestrator;
    private readonly ILogger<SharePointSyncTimerFunction> _logger;

    public SharePointSyncTimerFunction(SyncOrchestrator orchestrator, ILogger<SharePointSyncTimerFunction> logger)
    {
        _orchestrator = orchestrator;
        _logger = logger;
    }

    [Function("sharepoint_sync_timer")]
    public async Task RunAsync(
        [TimerTrigger("%TIMER_SCHEDULE%")] TimerInfo timer)
    {
        if (timer.IsPastDue)
        {
            _logger.LogWarning("Timer is running late");
        }

        var stats = await _orchestrator.RunAsync().ConfigureAwait(false);
        LogStats(_logger, stats);

        if (stats.FilesFailed > 0 || stats.PermissionsFailed > 0)
        {
            throw new InvalidOperationException(
                $"SharePoint sync job failed: files_failed={stats.FilesFailed}, permissions_failed={stats.PermissionsFailed}");
        }
    }

    internal static void LogStats(ILogger logger, SyncStats stats)
    {
        logger.LogInformation(
            "Sync completed (mode={Mode}, scanned={Scanned}, added={Added}, updated={Updated}, deleted={Deleted}, " +
            "unchanged={Unchanged}, failed={Failed}, bytes={Bytes}, perm_synced={PermSynced}, perm_unchanged={PermUnchanged}, " +
            "perm_failed={PermFailed}, purview_protected={PurviewProt}, purview_label_only={PurviewLabel}, " +
            "purview_unprotected={PurviewUnprot}, purview_failed={PurviewFailed}, rms_blocked={RmsBlocked})",
            stats.SyncMode, stats.FilesScanned, stats.FilesAdded, stats.FilesUpdated, stats.FilesDeleted,
            stats.FilesUnchanged, stats.FilesFailed, stats.BytesTransferred,
            stats.PermissionsSynced, stats.PermissionsUnchanged, stats.PermissionsFailed,
            stats.PurviewProtected, stats.PurviewLabelOnly, stats.PurviewUnprotected, stats.PurviewFailed,
            stats.RmsDownloadFailed);
    }
}
