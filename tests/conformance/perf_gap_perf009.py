# PERF009: redundant-sorted
# Trigger: double sort() call

def process_data(items: list[int]) -> list[int]:
    # This double sort is wasteful — inner sorted() already produces sorted output
    result = sorted(sorted(items))  # E[PERF009]: redundant double sort: sorted(sorted(x))
    return result
