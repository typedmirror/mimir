"""Concurrency: blocking calls in async functions (CONC001)"""

import asyncio
import time
import requests

async def bad_sleep():
    time.sleep(5)       # E

async def bad_open():
    f = open("data.txt")  # E

async def bad_requests():
    resp = requests.get("http://example.com")  # E

async def good_sleep():
    await asyncio.sleep(5)  # OK — async-safe

def sync_function():
    time.sleep(1)   # OK — not in async context

async def nested_sync():
    def helper():
        time.sleep(1)   # OK — inner sync function
    helper()
