"""Taint analysis: eval/exec injection (SEC010, SEC011)"""

# Direct source → sink
user_input = input("Enter code: ")
eval(user_input)        # SEC010: input() → eval()  # E[SEC006|SEC010]
exec(user_input)        # SEC011: input() → exec()  # E[SEC006|SEC011]

# Multi-step propagation
name = input("Name: ")
code = "print(" + name + ")"
eval(code)              # SEC010: input() → binop → eval()  # E[SEC006|SEC010]

# Sanitized — should NOT flag
user_num = input("Number: ")
safe_id = int(user_num)
eval(str(safe_id))      # OK — sanitized via int()  # E[SEC006]

# Literal — should NOT flag
safe = "print('hello')"
eval(safe)              # OK — literal, never tainted  # E[SEC006]
