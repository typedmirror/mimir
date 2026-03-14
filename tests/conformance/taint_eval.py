"""Taint analysis: eval/exec injection (SEC010, SEC011)"""

# Direct source → sink
user_input = input("Enter code: ")
eval(user_input)        # SEC010: input() → eval()  # E
exec(user_input)        # SEC011: input() → exec()  # E

# Multi-step propagation
name = input("Name: ")
code = "print(" + name + ")"
eval(code)              # SEC010: input() → binop → eval()  # E

# Sanitized — should NOT flag
user_num = input("Number: ")
safe_id = int(user_num)
eval(str(safe_id))      # OK — sanitized via int()  # E

# Literal — should NOT flag
safe = "print('hello')"
eval(safe)              # OK — literal, never tainted  # E
