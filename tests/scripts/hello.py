import sys

print("Hello from mimir run!")
if len(sys.argv) > 1:
    print(f"Args: {sys.argv[1:]}")
