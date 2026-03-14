"""Security: dangerous call rules (SEC006-SEC008)"""

import pickle
import subprocess
import yaml

# SEC006 — eval/exec
eval("2 + 2")              # SEC006  # E
exec("print('hi')")        # SEC006  # E

# SEC007 — unsafe deserialization
data = pickle.loads(b"x")              # SEC007  # E
config = yaml.load("x: 1")            # SEC007  # E
safe_config = yaml.safe_load("x: 1")  # OK

# SEC008 — shell injection
subprocess.run("ls -la", shell=True)   # SEC008  # E
subprocess.run(["ls", "-la"])          # OK — list args

import os
os.system("rm -rf /")                 # SEC008  # E
