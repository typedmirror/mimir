# conform self-test fixture (T3a): alternation code marker.
# The assignment below emits T001; the marker accepts Z999 or T001, so the
# alternation path must PASS (Z999 is a deliberately never-emitted code).
x: int = "hello"  # E[Z999|T001]
