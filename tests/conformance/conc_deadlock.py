"""Concurrency: event loop deadlock (CONC005)"""

import asyncio

async def some_coro():
    return 42

async def bad_handler():
    loop = asyncio.get_event_loop()
    result = loop.run_until_complete(some_coro())  # CONC005: deadlock  # E

async def bad_run():
    asyncio.run(some_coro())  # CONC005: deadlock  # E

def sync_handler():
    asyncio.run(some_coro())  # OK — not inside async function
