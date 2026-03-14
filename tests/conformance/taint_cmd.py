"""Taint analysis: command injection (SEC013)"""
import os
import subprocess

# os.system with tainted input
cmd = input("Command: ")
os.system(cmd)                          # SEC013: input() → os.system()  # E

# subprocess with shell=True
user_arg = input("Arg: ")
subprocess.run(user_arg, shell=True)    # SEC013: input() → subprocess.run(shell=True)  # E

# subprocess without shell=True — should NOT flag
subprocess.run(["ls", user_arg])        # OK — no shell=True

# Literal — should NOT flag
os.system("ls -la")                     # OK — literal  # E
