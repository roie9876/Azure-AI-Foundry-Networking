using System;
using System.Net;
using System.Text.Json;
using System.Threading.Tasks;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Http;
using Microsoft.Extensions.Logging;
using SharePointSyncFunc.Services;

namespace SharePointSyncFunc.Functions;

public sealed class SyncUiFunction
{
    private const string IndexHtml = """
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>SharePoint Sync Console</title>
<style>
  body { font-family: -apple-system, Segoe UI, Roboto, sans-serif; max-width: 720px; margin: 40px auto; padding: 0 20px; color: #222; }
  h1 { font-size: 22px; margin-bottom: 4px; }
  p.sub { color: #666; margin-top: 0; }
  button { font-size: 16px; padding: 14px 22px; margin: 10px 10px 10px 0; border: 0; border-radius: 8px; cursor: pointer; color: #fff; }
  .delta { background: #0366d6; }
  .full { background: #6f42c1; }
  button:disabled { opacity: .6; cursor: wait; }
  #log { margin-top: 20px; padding: 14px; background: #f6f8fa; border-radius: 8px; white-space: pre-wrap; font-family: ui-monospace, Menlo, monospace; font-size: 13px; min-height: 80px; }
  .row { display: flex; gap: 16px; flex-wrap: wrap; }
  .card { flex: 1 1 260px; padding: 14px; border: 1px solid #e1e4e8; border-radius: 8px; }
  .card h3 { margin: 0 0 6px; font-size: 15px; }
  .card p { margin: 0; font-size: 13px; color: #555; }
</style>
</head>
<body>
  <h1>SharePoint Sync Console</h1>
  <p class="sub">On-demand triggers for the SharePoint &rarr; Blob &rarr; AI Search pipeline.</p>

  <div class="row">
    <div class="card">
      <h3>Delta sync</h3>
      <p>Fast incremental. Uses Graph drive delta token. Runs on <code>TIMER_SCHEDULE</code> (default: hourly).</p>
      <button class="delta" onclick="run('delta', this)">Run delta sync now</button>
    </div>
    <div class="card">
      <h3>Full reconcile</h3>
      <p>Lists everything in scope, removes orphan blobs (renamed/deleted). Runs on <code>TIMER_SCHEDULE_FULL</code> (default: daily 03:00 UTC).</p>
      <button class="full" onclick="run('full', this)">Run full reconcile now</button>
    </div>
  </div>

  <div id="log">Ready.</div>

<script>
  async function run(mode, btn) {
    const all = document.querySelectorAll('button');
    all.forEach(b => b.disabled = true);
    const log = document.getElementById('log');
    log.textContent = `Starting ${mode} sync...\n`;
    const started = Date.now();
    try {
      const url = new URL(window.location.href);
      url.searchParams.set('mode', mode);
      const resp = await fetch(url.toString(), { method: 'POST' });
      const data = await resp.json();
      const elapsed = ((Date.now() - started) / 1000).toFixed(1);
      log.textContent += `Finished in ${elapsed}s\n\n` + JSON.stringify(data, null, 2);
    } catch (e) {
      log.textContent += 'ERROR: ' + e;
    } finally {
      all.forEach(b => b.disabled = false);
    }
  }
</script>
</body>
</html>
""";

    private readonly SyncOrchestrator _orchestrator;
    private readonly ILogger<SyncUiFunction> _logger;

    public SyncUiFunction(SyncOrchestrator orchestrator, ILogger<SyncUiFunction> logger)
    {
        _orchestrator = orchestrator;
        _logger = logger;
    }

    [Function("sync_ui")]
    public async Task<HttpResponseData> RunAsync(
        [HttpTrigger(AuthorizationLevel.Function, "get", "post", Route = "sync")] HttpRequestData req)
    {
        if (string.Equals(req.Method, "GET", StringComparison.OrdinalIgnoreCase))
        {
            var html = req.CreateResponse(HttpStatusCode.OK);
            html.Headers.Add("Content-Type", "text/html; charset=utf-8");
            await html.WriteStringAsync(IndexHtml).ConfigureAwait(false);
            return html;
        }

        var query = System.Web.HttpUtility.ParseQueryString(req.Url.Query);
        var mode = (query["mode"] ?? "delta").ToLowerInvariant();
        var forceFull = mode == "full";

        _logger.LogInformation("sync_ui POST: mode={Mode} force_full={ForceFull}", mode, forceFull);

        var previous = Environment.GetEnvironmentVariable("FORCE_FULL_SYNC");
        if (forceFull)
        {
            Environment.SetEnvironmentVariable("FORCE_FULL_SYNC", "true");
        }
        else
        {
            // Ensure a prior invocation on the same host doesn't leak full-sync state.
            Environment.SetEnvironmentVariable("FORCE_FULL_SYNC", null);
        }

        var started = DateTimeOffset.UtcNow.ToString("o");
        SyncStats? stats;
        try
        {
            stats = await _orchestrator.RunAsync().ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "sync_ui run failed");
            var failure = req.CreateResponse(HttpStatusCode.InternalServerError);
            failure.Headers.Add("Content-Type", "application/json");
            await failure.WriteStringAsync(JsonSerializer.Serialize(new
            {
                mode,
                started,
                ok = false,
                error = ex.Message,
            })).ConfigureAwait(false);
            return failure;
        }
        finally
        {
            Environment.SetEnvironmentVariable("FORCE_FULL_SYNC", previous);
        }

        var finished = DateTimeOffset.UtcNow.ToString("o");
        var ok = stats.FilesFailed == 0 && stats.PermissionsFailed == 0;
        var resp = req.CreateResponse(ok ? HttpStatusCode.OK : HttpStatusCode.InternalServerError);
        resp.Headers.Add("Content-Type", "application/json");
        await resp.WriteStringAsync(JsonSerializer.Serialize(new
        {
            mode,
            force_full = forceFull,
            started,
            finished,
            sync_mode = stats.SyncMode,
            files_scanned = stats.FilesScanned,
            files_added = stats.FilesAdded,
            files_updated = stats.FilesUpdated,
            files_deleted = stats.FilesDeleted,
            files_unchanged = stats.FilesUnchanged,
            files_failed = stats.FilesFailed,
            bytes_transferred = stats.BytesTransferred,
            permissions_synced = stats.PermissionsSynced,
            permissions_unchanged = stats.PermissionsUnchanged,
            permissions_failed = stats.PermissionsFailed,
            ok,
        })).ConfigureAwait(false);
        return resp;
    }
}
