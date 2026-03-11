"""Concurrency: unawaited coroutine (CONC002)"""

import asyncio

async def fetch_data():
    return {"result": 42}

async def process():
    return "done"

async def main():
    fetch_data()                         # CONC002: coroutine never awaited
    process()                            # CONC002: coroutine never awaited
    result = await fetch_data()          # OK — awaited
    task = asyncio.create_task(fetch_data())  # OK — wrapped in task
