using System;
using System.Threading.Tasks;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;
using SharePointSyncFunc.Services;

namespace SharePointSyncFunc.Functions;

public sealed class SharePointSyncFullTimerFunction
{
    private readonly SyncOrchestrator _orchestrator;
    private readonly ILogger<SharePointSyncFullTimerFunction> _logger;

    public SharePointSyncFullTimerFunction(SyncOrchestrator orchestrator, ILogger<SharePointSyncFullTimerFunction> logger)
    {
        _orchestrator = orchestrator;
        _logger = logger;
    }

    /// <summary>
    /// Daily full-sync reconcile. Forces FORCE_FULL_SYNC=true so the orchestrator
    /// takes the full-list branch (which runs folder/ext filters and removes
    /// orphan blobs for renamed/deleted items that delta mode would miss).
    /// </summary>
    [Function("sharepoint_sync_full_timer")]
    public async Task RunAsync(
        [TimerTrigger("%TIMER_SCHEDULE_FULL%")] TimerInfo timer)
    {
        if (timer.IsPastDue)
        {
            _logger.LogWarning("Full-sync timer is running late");
        }

        var previous = Environment.GetEnvironmentVariable("FORCE_FULL_SYNC");
        Environment.SetEnvironmentVariable("FORCE_FULL_SYNC", "true");
        try
        {
            var stats = await _orchestrator.RunAsync().ConfigureAwait(false);
            SharePointSyncTimerFunction.LogStats(_logger, stats);

            if (stats.FilesFailed > 0 || stats.PermissionsFailed > 0)
            {
                throw new InvalidOperationException(
                    $"SharePoint full-sync job failed: files_failed={stats.FilesFailed}, " +
                    $"permissions_failed={stats.PermissionsFailed}");
            }
        }
        finally
        {
            Environment.SetEnvironmentVariable("FORCE_FULL_SYNC", previous);
        }
    }
}
