import azure.functions as func
import logging

from main import main as sync_main


async def main(timer: func.TimerRequest) -> None:
    if timer.past_due:
        logging.warning("Timer is running late")

    exit_code = await sync_main()
    if exit_code != 0:
        raise RuntimeError(f"SharePoint sync job failed with exit code {exit_code}")
