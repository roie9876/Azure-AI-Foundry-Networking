import logging
import os

import azure.functions as func

from main import main as sync_main


async def main(timer: func.TimerRequest) -> None:
    """
    Daily full-sync reconcile. Forces FORCE_FULL_SYNC=true so main.py takes
    the full-list branch (which runs folder/ext filters and removes orphan
    blobs for renamed/deleted items that delta mode would miss).
    """
    if timer.past_due:
        logging.warning("Full-sync timer is running late")

    previous = os.environ.get("FORCE_FULL_SYNC")
    os.environ["FORCE_FULL_SYNC"] = "true"
    try:
        exit_code = await sync_main()
    finally:
        if previous is None:
            os.environ.pop("FORCE_FULL_SYNC", None)
        else:
            os.environ["FORCE_FULL_SYNC"] = previous

    if exit_code != 0:
        raise RuntimeError(f"SharePoint full-sync job failed with exit code {exit_code}")
