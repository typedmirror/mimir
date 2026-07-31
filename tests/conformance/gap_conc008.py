"""Concurrency: shared mutable state in gather tasks (CONC008)"""

import asyncio

results = []

def task_worker():
    results.append(42)

async def main():
    await asyncio.gather(task_worker(), task_worker())  # E[CONC008]: gather tasks mutate shared state via '.append()'

asyncio.run(main())
