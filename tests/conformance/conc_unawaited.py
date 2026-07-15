"""Concurrency: unawaited coroutine (CONC002)"""

import asyncio

async def fetch_data():
    return {"result": 42}

async def process():
    return "done"

async def main():
    fetch_data()                         # E[CONC002]
    process()                            # E[CONC002]
    result = await fetch_data()          # OK — awaited
    task = asyncio.create_task(fetch_data())  # OK — wrapped in task
