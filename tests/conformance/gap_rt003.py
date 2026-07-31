def process_stream():
    """Unbounded growth in infinite loop."""
    items: list[int] = []

    while True:
        items.append(1)
