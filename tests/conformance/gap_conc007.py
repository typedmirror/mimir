import asyncio

async def task1():
    pass

async def task2():
    pass

async def main():
    t1 = asyncio.create_task(task1())
    t2 = asyncio.create_task(task2())
    await asyncio.gather(t1, t2)  # E[CONC007]: asyncio.gather() without return_exceptions=True

asyncio.run(main())
