import asyncio
import json
import logging
import os
from datetime import datetime, timezone

import azure.functions as func

from main import main as sync_main


_INDEX_HTML = """<!doctype html>
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
"""


async def main(req: func.HttpRequest) -> func.HttpResponse:
    if req.method == "GET":
        return func.HttpResponse(_INDEX_HTML, mimetype="text/html", status_code=200)

    mode = (req.params.get("mode") or "delta").lower()
    force_full = mode == "full"

    logging.info("sync_ui POST: mode=%s force_full=%s", mode, force_full)

    previous = os.environ.get("FORCE_FULL_SYNC")
    if force_full:
        os.environ["FORCE_FULL_SYNC"] = "true"
    else:
        # Ensure a prior invocation on the same host doesn't leak full-sync state.
        os.environ.pop("FORCE_FULL_SYNC", None)

    started = datetime.now(timezone.utc).isoformat()
    try:
        exit_code = await sync_main()
    except Exception as exc:  # noqa: BLE001
        logging.exception("sync_ui run failed")
        return func.HttpResponse(
            json.dumps({"mode": mode, "started": started, "ok": False, "error": str(exc)}),
            mimetype="application/json",
            status_code=500,
        )
    finally:
        if previous is None:
            os.environ.pop("FORCE_FULL_SYNC", None)
        else:
            os.environ["FORCE_FULL_SYNC"] = previous

    finished = datetime.now(timezone.utc).isoformat()
    return func.HttpResponse(
        json.dumps({
            "mode": mode,
            "force_full": force_full,
            "started": started,
            "finished": finished,
            "exit_code": exit_code,
            "ok": exit_code == 0,
        }),
        mimetype="application/json",
        status_code=200 if exit_code == 0 else 500,
    )
