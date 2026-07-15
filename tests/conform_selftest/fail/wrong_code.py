# conform self-test fixture (T3a, fixture i): code marker with the WRONG code.
# The assignment below emits T001, but its marker demands SEC001.
# This file MUST FAIL (missed errors on the marker line). The failure is the
# instrument working: a wrong code must never silently pass. Note the T001
# that does fire is absorbed by the marked line (line-level parity, see
# runner.odin), so the only failure is the false negative.
x: int = "hello"  # E[SEC001]
