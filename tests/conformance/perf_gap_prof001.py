# PROF001: quadratic-nested-loop
# Trigger: nested for loops over same iterable

def inefficient_search(items: list[int]) -> bool:
    # O(n²) algorithm due to nested loops on same collection
    for x in items:
        for y in items:  # E[PROF001]: O(n²) nested loop — both loops iterate over 'items'
            if x == y:
                return True
    return False
