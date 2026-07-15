# conform self-test fixture (T3a, fixture ii): code marker with the CORRECT code.
# The assignment below emits T001; its marker names T001, so this file must PASS.
# Run: ./mimir_bin conform tests/conform_selftest/pass/right_code.py
x: int = "hello"  # E[T001]
