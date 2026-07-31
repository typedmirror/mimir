"""Performance analysis: blocking calls in loops.

PROF002 — blocking call in loop

Blocking calls inside loops serialize execution and multiply latency.
These calls should be batched or moved outside the loop.
"""

import time

# --- PROF002: blocking call in loop ---

# Blocking call inside for loop
items = [1, 2, 3]
for item in items:
    time.sleep(0.1)  # E[PROF002]: blocking call in loop
