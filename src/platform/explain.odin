package platform

import "core:fmt"
import "core:strings"

Explanation :: struct {
	code:        string,
	name:        string,
	category:    string,
	severity:    string,
	description: string,
	example:     string,
	note:        string,
}

cmd_explain :: proc(args: []string) {
	if len(args) == 0 || args[0] == "--help" {
		fmt.println("Usage: mimir explain <code>")
		fmt.println("       mimir explain --list")
		fmt.println()
		fmt.println("Show detailed explanation for a diagnostic code (e.g., T001, SEC005).")
		return
	}

	if args[0] == "--list" {
		print_rule_list()
		return
	}

	code := strings.to_upper(args[0], context.temp_allocator)
	for &entry in ALL_EXPLANATIONS {
		if entry.code == code {
			print_explanation(&entry)
			return
		}
	}

	fmt.eprintfln("mimir explain: unknown code '%s'", args[0])
	fmt.eprintfln("Run 'mimir explain --list' to see all available codes.")
}

print_explanation :: proc(e: ^Explanation) {
	fmt.printfln("%s: %s", e.code, e.name)
	fmt.printfln("Category: %s | Severity: %s", e.category, e.severity)
	fmt.println()
	fmt.println(e.description)
	if e.example != "" {
		fmt.println()
		fmt.println("Example:")
		fmt.println(e.example)
	}
	if e.note != "" {
		fmt.println()
		fmt.println(e.note)
	}
}

print_rule_list :: proc() {
	fmt.println("mimir diagnostic codes:")
	fmt.println()
	last_cat := ""
	for &entry in ALL_EXPLANATIONS {
		if entry.category != last_cat {
			if last_cat != "" { fmt.println() }
			fmt.printfln("  %s:", entry.category)
			last_cat = entry.category
		}
		fmt.printfln("    %-8s %s", entry.code, entry.name)
	}
}

// ==================== Explanation Database ====================

ALL_EXPLANATIONS := [?]Explanation{

	// ── Binder ──

	{
		code = "B001", name = "Undefined name", category = "Binder", severity = "Error",
		description = "A name is used that hasn't been defined in any accessible scope. This is caught\nduring name resolution (pass 2 of binding). The binder searches LEGB scopes —\nLocal, Enclosing, Global, Builtin — and reports an error if the name is not found\nin any of them.",
		example = "    print(x)  # B001: 'x' is not defined\n\n    def f():\n        return y  # B001: 'y' is not defined",
		note = "Common causes: typos in variable names, forgetting to import a module,\nusing a variable before assignment, or referencing a name from a different scope.",
	},
	{
		code = "B002", name = "Duplicate definition", category = "Binder", severity = "Error",
		description = "The same name is defined more than once in the same scope in a way that likely\nindicates a mistake (e.g., two function definitions with the same name).",
		example = "    def process():\n        pass\n    def process():  # B002: duplicate definition\n        pass",
	},
	{
		code = "B004", name = "Import error", category = "Binder", severity = "Error",
		description = "An import statement references a module or name that cannot be resolved.\nThis can occur with 'import X' or 'from X import Y' when X or Y doesn't exist.",
		example = "    from nonexistent import thing  # B004\n    import totally_fake_module        # B004",
	},
	{
		code = "B005", name = "Import resolution failure", category = "Binder", severity = "Error",
		description = "A module was found but specific names requested via 'from X import Y' could\nnot be resolved within that module's exports.",
		example = "    from os import nonexistent_function  # B005",
	},

	// ── Flow Analysis ──

	{
		code = "F001", name = "Unreachable code", category = "Flow Analysis", severity = "Error",
		description = "Code appears after a statement that unconditionally transfers control flow\n(return, raise, break, continue). This code can never execute and is almost\ncertainly a mistake.",
		example = "    def f():\n        return 1\n        x = 2    # F001: unreachable code\n        y = 3    # F001: unreachable code",
		note = "All unreachable statements after a control flow terminator are reported,\nnot just the first one.",
	},
	{
		code = "F002", name = "Missing return statement", category = "Flow Analysis", severity = "Error",
		description = "A function declares a return type annotation but has at least one code path\nthat reaches the end of the function without returning a value.",
		example = "    def f(x: int) -> int:\n        if x > 0:\n            return x\n        # F002: missing return (falls through when x <= 0)",
		note = "Fix by adding a return statement to all code paths, or adding an else clause.",
	},

	// ── Type Checker ──

	{
		code = "T001", name = "Type mismatch in assignment", category = "Type Checker", severity = "Error",
		description = "The right-hand side of an assignment has a type that is incompatible with the\ndeclared or inferred type of the left-hand side.",
		example = "    x: int = \"hello\"  # T001: str is not assignable to int\n\n    y: int = 5\n    y = \"world\"         # T001: str is not assignable to int",
	},
	{
		code = "T002", name = "Incompatible argument type", category = "Type Checker", severity = "Error",
		description = "A function is called with an argument whose type doesn't match the parameter\ntype declared in the function signature.",
		example = "    def add(a: int, b: int) -> int:\n        return a + b\n\n    add(1, \"two\")  # T002: str is not assignable to int",
	},
	{
		code = "T003", name = "Incompatible return type", category = "Type Checker", severity = "Error",
		description = "A return statement produces a value whose type is incompatible with the\nfunction's declared return type annotation.",
		example = "    def get_name() -> str:\n        return 42  # T003: int is not assignable to str",
	},
	{
		code = "T004", name = "Argument count error", category = "Type Checker", severity = "Error",
		description = "A function is called with the wrong number of arguments, or the same parameter\nis supplied both as a positional and keyword argument.",
		example = "    def greet(name: str) -> str:\n        return \"hi \" + name\n\n    greet()                     # T004: too few arguments\n    greet(\"a\", \"b\")             # T004: too many arguments\n    greet(\"a\", name=\"b\")        # T004: duplicate argument",
		note = "Both positional and keyword arguments count toward the total.\nDuplicate detection checks if a keyword argument names a parameter\nthat was already filled by a positional argument.",
	},
	{
		code = "T005", name = "Unsupported operator", category = "Type Checker", severity = "Error",
		description = "An operator is applied to operand types that don't support it.",
		example = "    x = \"hello\" - \"world\"  # T005: str does not support '-'",
	},
	{
		code = "T006", name = "TypedDict key error", category = "Type Checker", severity = "Error",
		description = "A TypedDict is accessed with a key that isn't defined in the TypedDict,\nor is missing a required key during construction.",
		example = "    from typing import TypedDict\n    class Point(TypedDict):\n        x: int\n        y: int\n\n    p: Point = {\"x\": 1, \"z\": 3}  # T006: unknown key 'z'",
	},
	{
		code = "T007", name = "Attribute error", category = "Type Checker", severity = "Error",
		description = "An attribute is accessed on a type that doesn't define it. For user-defined\ntypes (classes, instances, modules), mimir checks against registered attributes\nand methods.",
		example = "    class Foo:\n        x: int = 0\n\n    Foo().y  # T007: 'Foo' has no attribute 'y'",
		note = "Attribute checks are scoped to user-defined types — built-in type method\ntables are intentionally incomplete to avoid false positives.",
	},
	{
		code = "T008", name = "TypedDict required key missing", category = "Type Checker", severity = "Error",
		description = "A TypedDict literal is missing one or more required keys.",
		example = "    class Config(TypedDict):\n        host: str\n        port: int\n\n    c: Config = {\"host\": \"localhost\"}  # T008: missing required key 'port'",
	},
	{
		code = "T009", name = "Revealed type", category = "Type Checker", severity = "Info",
		description = "reveal_type() displays the inferred type of an expression at check time.\nUseful for debugging type inference. The expression is evaluated normally.",
		example = "    x = [1, 2, 3]\n    reveal_type(x)  # T009: Type of expression is 'list[int]'",
		note = "This is informational — reveal_type() does not cause a check failure.\nAvailable as a builtin in Python 3.11+ or via typing.reveal_type.",
	},

	// ── Lint ──

	{
		code = "L001", name = "Unused import", category = "Lint", severity = "Warning",
		description = "A module or name is imported but never referenced anywhere in the file.",
		example = "    import os  # L001: 'os' is imported but unused",
		note = "Fix by removing the import, or use it. If the import is intentional\n(e.g., for re-export), consider using __all__.",
	},
	{
		code = "L002", name = "Unused variable", category = "Lint", severity = "Warning",
		description = "A local variable is assigned but never read.",
		example = "    def f():\n        x = compute()  # L002: 'x' is assigned but never used\n        return 0",
		note = "Prefix with underscore (_x) to indicate intentionally unused.",
	},
	{
		code = "L003", name = "Mutable default argument (lint)", category = "Lint", severity = "Warning",
		description = "A function parameter has a mutable default value. The default is created once\nand shared across all calls, which can cause surprising state mutation.",
		example = "    def append_to(item, lst=[]):  # L003\n        lst.append(item)\n        return lst",
		note = "See also SAF009 for the safety-focused version of this rule.",
	},
	{
		code = "L004", name = "F-string without placeholders", category = "Lint", severity = "Warning",
		description = "An f-string prefix is used but the string contains no {expression} placeholders,\nmaking the f-prefix unnecessary.",
		example = "    msg = f\"hello world\"  # L004: f-string has no placeholders",
	},
	{
		code = "L005", name = "Bare except", category = "Lint", severity = "Warning",
		description = "An except clause catches all exceptions without specifying a type. This catches\nKeyboardInterrupt, SystemExit, and GeneratorExit, which are rarely intentional.",
		example = "    try:\n        risky()\n    except:  # L005: bare except catches everything\n        pass",
		note = "Use 'except Exception:' to catch normal errors while allowing system exits.",
	},
	{
		code = "L006", name = "Assert on tuple", category = "Lint", severity = "Warning",
		description = "An assert statement tests a tuple literal, which is always truthy (even an\nempty tuple is a non-None object). This is almost always a mistake.",
		example = "    assert (x > 0, \"x must be positive\")  # L006: always True",
		note = "Remove the parentheses: assert x > 0, \"x must be positive\"",
	},

	// ── Convention ──

	{
		code = "C001", name = "Naming convention violation", category = "Convention", severity = "Warning",
		description = "A name doesn't follow Python naming conventions: functions and variables use\nsnake_case, classes use PascalCase, constants use UPPER_SNAKE_CASE.",
		example = "    class my_class:  # C001: class should be PascalCase\n        pass\n\n    def MyFunction():  # C001: function should be snake_case\n        pass",
	},
	{
		code = "C002", name = "Star import", category = "Convention", severity = "Warning",
		description = "A wildcard import ('from X import *') imports all public names from a module.\nThis pollutes the namespace and makes it unclear where names come from.",
		example = "    from os.path import *  # C002: star import",
		note = "Import specific names instead: from os.path import join, exists",
	},

	// ── Style ──

	{
		code = "S001", name = "Line too long", category = "Style", severity = "Warning",
		description = "A line exceeds the configured maximum length (default: 88 characters).",
		example = "    x = some_really_long_function_name(with_many_arguments, that_make_the_line, exceed_the_limit)  # S001",
		note = "Break long lines using parentheses, backslash continuation, or by\nextracting sub-expressions into variables.",
	},

	// ── Security ──

	{
		code = "SEC001", name = "Weak hash algorithm", category = "Security", severity = "Warning",
		description = "Code uses a cryptographic hash algorithm (MD5 or SHA-1) known to be vulnerable\nto collision attacks. These should not be used for security purposes.",
		example = "    import hashlib\n    h = hashlib.md5(data)    # SEC001: weak hash\n    h = hashlib.sha1(data)   # SEC001: weak hash",
		note = "Use hashlib.sha256() or hashlib.sha3_256() for security-sensitive hashing.\nMD5/SHA-1 are acceptable for non-security checksums (e.g., cache keys).",
	},
	{
		code = "SEC002", name = "Insecure random", category = "Security", severity = "Warning",
		description = "Code uses the 'random' module (which is not cryptographically secure) in a\ncontext that appears security-sensitive (e.g., generating tokens or passwords).",
		example = "    import random\n    token = random.randint(0, 999999)  # SEC002",
		note = "Use the 'secrets' module for security-sensitive randomness:\nimport secrets; token = secrets.token_hex(32)",
	},
	{
		code = "SEC003", name = "Timing attack vulnerability", category = "Security", severity = "Warning",
		description = "String comparison of secrets (passwords, tokens, API keys) using == is\nvulnerable to timing side-channel attacks.",
		example = "    if user_token == stored_token:  # SEC003: timing attack\n        grant_access()",
		note = "Use hmac.compare_digest() for constant-time comparison.",
	},
	{
		code = "SEC004", name = "Hardcoded secret", category = "Security", severity = "Warning",
		description = "A variable whose name suggests it holds a secret (password, token, api_key,\nsecret) is assigned a string literal.",
		example = "    API_KEY = \"sk-abc123def456\"  # SEC004: hardcoded secret",
		note = "Load secrets from environment variables or a secrets manager:\nimport os; API_KEY = os.environ[\"API_KEY\"]",
	},
	{
		code = "SEC005", name = "Embedded credentials", category = "Security", severity = "Warning",
		description = "A string literal contains patterns that look like embedded credentials:\nAWS access keys, JWT tokens, or other recognizable secret formats.",
		example = "    config = \"AKIAIOSFODNN7EXAMPLE\"  # SEC005: AWS access key pattern",
	},
	{
		code = "SEC006", name = "eval/exec usage", category = "Security", severity = "Warning",
		description = "Code uses eval() or exec() which execute arbitrary Python code. If the input\ncan be influenced by users, this is a code injection vulnerability.",
		example = "    result = eval(user_input)  # SEC006: eval is dangerous",
		note = "Use ast.literal_eval() for safe evaluation of literal expressions.\nFor complex cases, consider a proper parser or sandboxed execution.",
	},
	{
		code = "SEC007", name = "Unsafe deserialization", category = "Security", severity = "Warning",
		description = "Code uses pickle.loads(), yaml.load() without SafeLoader, or marshal.loads()\nwhich can execute arbitrary code during deserialization.",
		example = "    import pickle\n    data = pickle.loads(network_data)  # SEC007: unsafe deserialization",
		note = "Use json for untrusted data. For YAML, use yaml.safe_load().\npickle is only safe for fully trusted data.",
	},
	{
		code = "SEC008", name = "Shell injection risk", category = "Security", severity = "Warning",
		description = "Code uses os.system() or subprocess with shell=True, which passes commands\nthrough the system shell and is vulnerable to injection.",
		example = "    import os\n    os.system(f\"rm {user_file}\")  # SEC008: shell injection",
		note = "Use subprocess.run([\"cmd\", \"arg1\"], shell=False) with a list of arguments.",
	},
	{
		code = "SEC009", name = "Typosquat suspect", category = "Security", severity = "Warning",
		description = "An import references a package name that is suspiciously similar to a popular\npackage (edit distance of 1), which may be a typosquatting attack.",
		example = "    import reqeusts  # SEC009: did you mean 'requests'?",
	},

	// ── Taint (SEC010-014) ──

	{
		code = "SEC010", name = "Tainted eval", category = "Taint Analysis", severity = "Error",
		description = "User-controlled data flows into eval(). This is a critical code injection\nvulnerability — an attacker can execute arbitrary Python code.",
		example = "    user_input = input()\n    result = eval(user_input)  # SEC010: tainted data in eval",
	},
	{
		code = "SEC011", name = "Tainted exec", category = "Taint Analysis", severity = "Error",
		description = "User-controlled data flows into exec(). Like eval, this allows arbitrary\ncode execution.",
		example = "    code = request.form[\"code\"]\n    exec(code)  # SEC011: tainted data in exec",
	},
	{
		code = "SEC012", name = "SQL injection", category = "Taint Analysis", severity = "Error",
		description = "User-controlled data is used in a SQL query via string formatting rather than\nparameterized queries. This is a SQL injection vulnerability.",
		example = "    name = input()\n    cursor.execute(f\"SELECT * FROM users WHERE name='{name}'\")  # SEC012",
		note = "Use parameterized queries: cursor.execute(\"SELECT * FROM users WHERE name=?\", (name,))",
	},
	{
		code = "SEC013", name = "Command injection", category = "Taint Analysis", severity = "Error",
		description = "User-controlled data flows into a system command (os.system, subprocess with\nshell=True). An attacker can inject arbitrary shell commands.",
		example = "    filename = input()\n    os.system(f\"cat {filename}\")  # SEC013: command injection",
		note = "Use subprocess.run([\"cat\", filename], shell=False) with a list of arguments.",
	},
	{
		code = "SEC014", name = "Path traversal", category = "Taint Analysis", severity = "Error",
		description = "User-controlled data is used as a file path in open(). An attacker can\nread or write arbitrary files using '../' traversal.",
		example = "    path = input()\n    f = open(path)  # SEC014: tainted path",
		note = "Validate and sanitize file paths. Use os.path.realpath() and check\nthat the resolved path is within the expected directory.",
	},

	// ── Safety ──

	{
		code = "SAF001", name = "Exception silently swallowed", category = "Safety", severity = "Warning",
		description = "An except clause catches an exception but does nothing with it (only contains\npass or no statements). This hides errors and makes debugging difficult.",
		example = "    try:\n        process()\n    except ValueError:\n        pass  # SAF001: exception swallowed",
		note = "At minimum, log the error. Or re-raise if the exception shouldn't be silenced.",
	},
	{
		code = "SAF002", name = "Overly broad except", category = "Safety", severity = "Warning",
		description = "An except clause catches Exception or BaseException, which is too broad and\nwill catch unexpected errors that should propagate.",
		example = "    try:\n        process()\n    except Exception:  # SAF002: too broad\n        handle()",
		note = "Catch specific exception types that you know how to handle.",
	},
	{
		code = "SAF003", name = "Import side effect", category = "Safety", severity = "Warning",
		description = "A function call appears at module level (outside any function or class).\nModule-level code runs on import, which can cause unexpected side effects.",
		example = "    import os\n    os.chdir(\"/tmp\")  # SAF003: side effect at import time",
		note = "Move side effects into functions or guard with if __name__ == '__main__'.",
	},
	{
		code = "SAF004", name = "Monkey patching", category = "Safety", severity = "Warning",
		description = "Code modifies attributes on an imported module at runtime. This changes\nbehavior globally and makes the codebase harder to reason about.",
		example = "    import os\n    os.environ = {}  # SAF004: monkey patching",
	},
	{
		code = "SAF005", name = "Global state mutation", category = "Safety", severity = "Warning",
		description = "A function mutates a module-level mutable object (list, dict, set). Global\nmutable state creates hidden coupling between functions.",
		example = "    cache = []\n    def add(item):\n        cache.append(item)  # SAF005: global mutation",
	},
	{
		code = "SAF006", name = "Regex catastrophic backtracking", category = "Safety", severity = "Warning",
		description = "A regular expression contains patterns vulnerable to catastrophic backtracking\n(ReDoS). Nested quantifiers like (a+)+ can cause exponential time on\ncrafted inputs.",
		example = "    import re\n    re.match(r\"(a+)+b\", user_input)  # SAF006: ReDoS risk",
		note = "Simplify the regex to avoid nested quantifiers, or use re2 for\nlinear-time matching.",
	},
	{
		code = "SAF007", name = "Sensitive data in logs", category = "Safety", severity = "Warning",
		description = "A logging call includes a variable whose name suggests it contains sensitive\ndata (password, token, secret, api_key, etc.).",
		example = "    import logging\n    logging.info(f\"User token: {api_token}\")  # SAF007",
		note = "Redact sensitive values before logging, or use structured logging with\na sensitive-field filter.",
	},
	{
		code = "SAF008", name = "Expensive log formatting", category = "Safety", severity = "Warning",
		description = "A debug-level log statement uses f-string formatting with function calls.\nThe formatting is evaluated even when debug logging is disabled.",
		example = "    logging.debug(f\"Data: {expensive_serialize(obj)}\")  # SAF008",
		note = "Use lazy formatting: logging.debug(\"Data: %s\", expensive_serialize(obj))\nor guard with if logger.isEnabledFor(logging.DEBUG).",
	},
	{
		code = "SAF009", name = "Mutable default argument", category = "Safety", severity = "Warning",
		description = "A function parameter has a mutable default value (list, dict, set, or a call\nto a mutable constructor). The default object is created once at function\ndefinition time and shared across all calls. Mutating it changes the default\nfor future calls.",
		example = "    def append_to(item, target=[]):  # SAF009\n        target.append(item)\n        return target\n\n    append_to(1)  # returns [1]\n    append_to(2)  # returns [1, 2] — not [2]!",
		note = "Use None as default and create inside the function:\n    def append_to(item, target=None):\n        if target is None:\n            target = []\n        target.append(item)\n        return target",
	},

	{
		code = "SAF010", name = "Use after close", category = "Safety", severity = "Error",
		description = "A resource method (read, write, etc.) is called on a variable that was\nbound in a 'with' block after the block has exited. The resource is closed.",
		example = "    with open('f.txt') as f:\n        data = f.read()  # OK\n    f.read()  # SAF010: f is closed",
		note = "Move the operation inside the 'with' block, or re-open the resource.",
	},

	// ── Runtime Model ──

	{
		code = "RT001", name = "Reference cycle", category = "Runtime", severity = "Info",
		description = "An object is assigned to an attribute of itself, creating a reference cycle.\nCircular references prevent reference counting from freeing objects.",
		example = "    child.parent = self  # RT001: reference cycle",
		note = "Use weakref.ref() for back-references to avoid cycles.",
	},
	{
		code = "RT002", name = "Object creation hotspot", category = "Runtime", severity = "Info",
		description = "A constructor call (ClassName(...)) appears inside a loop body.\nCreating objects per iteration increases GC pressure.",
		example = "    for event in events:\n        handler = EventHandler(event)  # RT002",
		note = "Move construction outside the loop if the object can be reused,\nor use object pooling for expensive constructors.",
	},

	// ── Cross-Process ──

	{
		code = "PROC001", name = "Shared mutable state in multiprocessing", category = "Cross-Process", severity = "Error",
		description = "A function used as a multiprocessing target modifies a module-level\nmutable variable (dict, list, set). Each process gets its own copy —\nmutations are not shared between processes.",
		example = "    shared = {}\n    def worker(k, v):\n        shared[k] = v  # not actually shared!\n    pool.map(worker, data)  # PROC001",
		note = "Use multiprocessing.Manager().dict() for shared state,\nor multiprocessing.Queue for inter-process communication.",
	},

	// ── Concurrency ──

	{
		code = "CONC001", name = "Blocking call in async function", category = "Concurrency", severity = "Warning",
		description = "A blocking function (time.sleep, open, requests.get, etc.) is called inside\nan async function. This blocks the event loop and defeats the purpose of async.",
		example = "    async def fetch():\n        time.sleep(1)  # CONC001: blocks event loop",
		note = "Use asyncio.sleep() instead of time.sleep(). For I/O, use aiofiles,\naiohttp, or run_in_executor() for blocking calls.",
	},
	{
		code = "CONC002", name = "Unawaited coroutine", category = "Concurrency", severity = "Warning",
		description = "An async function is called without await, which creates a coroutine object\nthat is never executed.",
		example = "    async def fetch_data(): ...\n\n    async def main():\n        fetch_data()  # CONC002: missing await",
	},
	{
		code = "CONC003", name = "CPU-bound work in threads", category = "Concurrency", severity = "Warning",
		description = "CPU-intensive operations are dispatched to threads, but Python's GIL prevents\ntrue parallelism for CPU-bound work. Only I/O-bound work benefits from threads.",
		example = "    from concurrent.futures import ThreadPoolExecutor\n    executor.submit(heavy_computation)  # CONC003: GIL limits this",
		note = "Use ProcessPoolExecutor for CPU-bound work, or multiprocessing.",
	},
	{
		code = "CONC004", name = "Non-atomic operation on shared state", category = "Concurrency", severity = "Warning",
		description = "An augmented assignment (+=, -=, etc.) is used on a global/shared variable\nin a threaded context. These operations are not atomic in Python.",
		example = "    counter = 0\n    def increment():\n        global counter\n        counter += 1  # CONC004: not atomic",
		note = "Use threading.Lock, queue.Queue, or atomic operations from the\nconcurrent.futures module.",
	},
	{
		code = "CONC005", name = "Event loop deadlock", category = "Concurrency", severity = "Error",
		description = "asyncio.run() or loop.run_until_complete() is called inside an async function,\nwhich blocks the event loop and causes a deadlock.",
		example = "    async def main():\n        asyncio.run(other())  # CONC005: deadlock",
		note = "Use 'await other()' directly instead of asyncio.run() inside async code.",
	},
	{
		code = "CONC006", name = "Free-threaded unsafe", category = "Concurrency", severity = "Warning",
		description = "A global variable is mutated inside a function. In free-threaded Python\n(PEP 703), this is a data race without explicit synchronization.",
		example = "    counter = 0\n    def increment():\n        global counter\n        counter = counter + 1  # CONC006",
		note = "Protect with threading.Lock, use queue.Queue, or make the variable thread-local.",
	},

	// ── Performance ──

	{
		code = "PERF001", name = "String concatenation in loop", category = "Performance", severity = "Warning",
		description = "Strings are concatenated with += inside a loop. Each concatenation creates a\nnew string object, resulting in O(n²) time complexity.",
		example = "    result = \"\"\n    for line in lines:\n        result += line  # PERF001: O(n²)",
		note = "Use ''.join(lines) for O(n) concatenation, or build a list and join at the end.",
	},
	{
		code = "PERF002", name = "Unnecessary list comprehension", category = "Performance", severity = "Warning",
		description = "A list comprehension is passed directly to a function that accepts any\niterable (sum, min, max, set, frozenset, sorted, ''.join). A generator\nexpression avoids allocating the intermediate list.",
		example = "    total = sum([x*x for x in range(1000)])  # PERF002\n    # Better: sum(x*x for x in range(1000))",
	},
	{
		code = "PERF003", name = "Read entire file unnecessarily", category = "Performance", severity = "Warning",
		description = "open().read() loads an entire file into memory. For large files, this can\ncause excessive memory usage.",
		example = "    data = open(\"large.csv\").read()  # PERF003",
		note = "Process files line-by-line, or use memory-mapped files for random access.",
	},
	{
		code = "PERF004", name = "Unhashable lru_cache parameter", category = "Performance", severity = "Warning",
		description = "A function decorated with @lru_cache has a parameter with a mutable type\n(list, dict, set) that cannot be hashed, causing a TypeError at runtime.",
		example = "    @lru_cache\n    def process(data: list):  # PERF004: list is unhashable\n        ...",
		note = "Use tuple instead of list for cached function parameters.",
	},

	{
		code = "PERF005", name = "N+1 query pattern", category = "Performance", severity = "Warning",
		description = "A database query or ORM call is executed inside a loop, causing\nN+1 round-trips to the database.",
		example = "    for user in users:\n        orders = cursor.execute(\"SELECT ...\")  # PERF005",
		note = "Use a JOIN, eager loading, or collect IDs and query once outside the loop.",
	},
	{
		code = "PERF006", name = "Unbounded cache", category = "Performance", severity = "Warning",
		description = "A module-level dict is used as a cache with entries added in functions\nbut never evicted, causing unbounded memory growth.",
		example = "    _cache = {}\n    def process(key, data):\n        _cache[key] = data  # PERF006",
		note = "Use functools.lru_cache, set a maximum size, or add an eviction policy.",
	},
	{
		code = "PERF007", name = "Heavy import", category = "Performance", severity = "Info",
		description = "A large package is imported at module level, increasing startup time\nand memory usage even if only a small part is used.",
		example = "    import tensorflow  # PERF007: ~2.1GB, ~8s import",
		note = "Move the import inside the function that uses it (lazy import)\nif not needed at module level.",
	},

	{
		code = "PERF008", name = "Stale cache", category = "Performance", severity = "Warning",
		description = "A database mutation occurs in a function but a module-level cache dict\nis not updated or cleared, leaving potentially stale data.",
		example = "    _cache = {}\n    def update_user(id, data):\n        db.update(id, data)  # PERF008\n        # _cache[id] not invalidated",
		note = "Delete or update the cache entry after the mutation:\n    del _cache[id]  # or _cache[id] = new_data",
	},

	// ── Match ──

	{
		code = "MATCH002", name = "Dead match pattern", category = "Match", severity = "Warning",
		description = "A match/case pattern is unreachable because a broader pattern above\nalready matches all values of this type.",
		example = "    match value:\n        case int():  # matches all ints\n            ...\n        case 42:     # MATCH002: unreachable",
		note = "Move specific value patterns before class/type patterns.\nAlso: any case after a wildcard (case _:) is unreachable.",
	},

	// ── Migration ──

	{
		code = "MIG001", name = "Union syntax available", category = "Migration", severity = "Info",
		description = "typing.Union[X, Y] can be replaced with X | Y syntax (Python 3.10+).",
		example = "    from typing import Union\n    def f(x: Union[int, str]):  # MIG001\n        ...\n    # Modern: def f(x: int | str):",
	},
	{
		code = "MIG002", name = "Optional syntax available", category = "Migration", severity = "Info",
		description = "typing.Optional[X] can be replaced with X | None syntax (Python 3.10+).",
		example = "    from typing import Optional\n    def f(x: Optional[int]):  # MIG002\n        ...\n    # Modern: def f(x: int | None):",
	},
	{
		code = "MIG003", name = "Built-in generics available", category = "Migration", severity = "Info",
		description = "typing.List, typing.Dict, etc. can be replaced with built-in generics\n(list[int], dict[str, int]) starting from Python 3.9.",
		example = "    from typing import List\n    def f(items: List[int]):  # MIG003\n        ...\n    # Modern: def f(items: list[int]):",
	},
	{
		code = "MIG004", name = "Built-in type available", category = "Migration", severity = "Info",
		description = "typing.Text and similar aliases can be replaced with built-in types.",
		example = "    from typing import Text\n    name: Text = \"hello\"  # MIG004: use str",
	},
	{
		code = "MIG005", name = "isinstance union available", category = "Migration", severity = "Info",
		description = "isinstance() with a tuple of types can use the | syntax (Python 3.10+).",
		example = "    isinstance(x, (int, str))  # MIG005\n    # Modern: isinstance(x, int | str)",
	},
	{
		code = "MIG006", name = "OrderedDict unnecessary", category = "Migration", severity = "Info",
		description = "collections.OrderedDict is unnecessary — regular dict preserves insertion\norder since Python 3.7.",
		example = "    from collections import OrderedDict\n    d = OrderedDict()  # MIG006: use dict()",
	},
	{
		code = "MIG007", name = "collections.abc import", category = "Migration", severity = "Info",
		description = "Abstract base classes should be imported from collections.abc rather than\ncollections (deprecated since Python 3.9).",
		example = "    from collections import Mapping  # MIG007\n    # Modern: from collections.abc import Mapping",
	},
	{
		code = "MIG008", name = "Match-case candidate", category = "Migration", severity = "Info",
		description = "An if/elif chain with repeated isinstance or equality checks could be\nreplaced with a match/case statement (Python 3.10+).",
		example = "    if isinstance(x, int):    # MIG008\n        ...\n    elif isinstance(x, str):\n        ...\n    elif isinstance(x, list):\n        ...",
	},

	// ── JSON ──

	{
		code = "JSON001", name = "Non-serializable type", category = "JSON", severity = "Error",
		description = "A value passed to json.dumps(), json.dump(), mimir.json.serialize(), or\nmimir.json.write() has a type that is not JSON-serializable. JSON only\nsupports str, int, float, bool, None, list, and dict[str, ...].",
		example = "    import json\n    json.dumps({1, 2, 3})  # JSON001: set is not serializable",
		note = "Convert to a serializable type (e.g., list(my_set)) or use a custom encoder.",
	},
	{
		code = "JSON002", name = "Invalid JSON schema type", category = "JSON", severity = "Error",
		description = "The schema argument to mimir.json.parse() or mimir.json.read() is not a\nTypedDict or class. The schema must be a structured type so that fields\ncan be validated.",
		example = "    from mimir.json import parse\n    data = parse(text, int)  # JSON002: int is not a schema type",
		note = "Use a TypedDict or dataclass as the schema argument.",
	},
	{
		code = "JSON003", name = "Non-serializable schema field", category = "JSON", severity = "Error",
		description = "A TypedDict used as a JSON schema contains a field whose type is not JSON\nserializable (e.g., set, bytes, custom class).",
		example = "    class Config(TypedDict):\n        tags: set  # JSON003: set is not serializable",
		note = "Change the field type to a JSON-compatible type (e.g., list instead of set).",
	},

	// ── Data ──

	{
		code = "DATA001", name = "Column not found", category = "Data", severity = "Error",
		description = "A DataFrame is accessed with a column name that doesn't exist. Column names\nare tracked from the schema TypedDict or constructor dict literal.",
		example = "    from mimir.data import read_csv\n    class Sales(TypedDict):\n        revenue: float\n        region: str\n\n    df = read_csv(\"sales.csv\", Sales)\n    df[\"revnue\"]  # DATA001: column 'revnue' not found",
		note = "Check the column name for typos. Available columns are listed in the error.",
	},
	{
		code = "DATA002", name = "Invalid DataFrame schema type", category = "Data", severity = "Error",
		description = "The schema argument to read_csv(), read_json(), or read_parquet() is not a\nTypedDict. The schema must be a TypedDict so columns can be validated.",
		example = "    from mimir.data import read_csv\n    df = read_csv(\"data.csv\", int)  # DATA002: expected TypedDict schema",
		note = "Use a TypedDict as the schema argument.",
	},
	{
		code = "DATA003", name = "Numeric operation on non-numeric column", category = "Data", severity = "Warning",
		description = "A numeric aggregation method (mean, sum, std) is called on a Series whose\nelement type is not numeric (e.g., str).",
		example = "    df[\"name\"].mean()  # DATA003: mean() requires numeric column",
		note = "Use a numeric column, or convert the column type first.",
	},

	// ── Database ──

	{
		code = "DB001", name = "Unsafe SQL construction", category = "Database", severity = "Error",
		description = "A SQL query string is constructed dynamically using f-strings, string\nconcatenation, or .format(). This is vulnerable to SQL injection regardless\nof whether the interpolated values come from user input.",
		example = "    from mimir.db import query\n    query(db, f\"SELECT * FROM users WHERE id = {uid}\")  # DB001\n    query(db, \"SELECT * FROM users WHERE id = ?\", params=[uid])  # OK",
		note = "Always use parameterized queries with ? placeholders and pass values via params=[].",
	},
	{
		code = "DB002", name = "Invalid query result schema", category = "Database", severity = "Error",
		description = "The result= argument to query() is not a TypedDict or class. The result type\nmust be a structured type so row fields can be validated.",
		example = "    from mimir.db import query\n    query(db, sql, result=int)  # DB002: expected TypedDict or class",
		note = "Use a TypedDict as the result argument.",
	},

	// ── Cryptography ──

	{
		code = "CRYPT001", name = "Insecure encryption mode", category = "Cryptography", severity = "Error",
		description = "ECB (Electronic Codebook) mode encrypts identical plaintext blocks to identical\nciphertext blocks, leaking patterns in the data. It does not provide semantic\nsecurity and should never be used.",
		example = "    from mimir.crypt import encrypt\n    ciphertext = encrypt.aes_ecb(key, data)  # CRYPT001: ECB is insecure",
		note = "Use encrypt.aes_gcm() for authenticated encryption (recommended) or\nencrypt.aes_cbc() for compatibility. GCM also provides integrity checking.",
	},
	{
		code = "CRYPT002", name = "Weak hash for password hashing", category = "Cryptography", severity = "Warning",
		description = "MD5 and SHA-1 are fast general-purpose hash algorithms that are unsuitable for\npassword hashing. They can be brute-forced at billions of hashes per second\non modern GPUs.",
		example = "    from mimir.crypt import hash\n    hashed = hash.md5(password)   # CRYPT002: too fast for passwords\n    hashed = hash.sha1(password)  # CRYPT002: too fast for passwords",
		note = "Use hash.bcrypt() or hash.argon2() for password hashing. These are\ndeliberately slow and include salting to resist brute-force attacks.",
	},
	{
		code = "CRYPT003", name = "Insufficient key/token length", category = "Cryptography", severity = "Warning",
		description = "A cryptographic token or key is generated with fewer than 16 bytes (128 bits),\nwhich may be vulnerable to brute-force attacks.",
		example = "    from mimir.crypt import token\n    key = token.bytes(8)  # CRYPT003: only 64 bits of entropy",
		note = "Use at least 16 bytes (128 bits) for tokens. For AES keys, use 32 bytes\n(256 bits). NIST recommends 128-bit minimum for symmetric keys.",
	},

	// ── GPU ──

	{
		code = "GPU001", name = "Non-numeric type in @gpu function", category = "GPU", severity = "Error",
		description = "A @gpu function uses a type that has no GPU representation. GPU compute\nkernels only support numeric types (int, float, Tensor).",
		example = "    @gpu\n    def kernel(data: str):  # GPU001: str has no GPU type\n        ...",
	},
	{
		code = "GPU002", name = "String operation in @gpu function", category = "GPU", severity = "Error",
		description = "String operations cannot be compiled to GPU compute shaders. GPUs have no\nstring processing hardware.",
		example = "    @gpu\n    def kernel(x: int) -> int:\n        name = \"hello\"  # GPU002: no strings on GPU\n        return x",
	},
	{
		code = "GPU003", name = "Heap allocation in @gpu function", category = "GPU", severity = "Error",
		description = "Dynamic memory allocation (list, dict, set, comprehensions) is not supported\non GPUs. GPU memory must be pre-allocated.",
		example = "    @gpu\n    def kernel(n: int) -> int:\n        data = [1, 2, 3]  # GPU003: no heap allocation\n        return data[0]",
	},
	{
		code = "GPU004", name = "Exception handling in @gpu function", category = "GPU", severity = "Error",
		description = "try/except/raise/assert cannot be compiled to GPU compute shaders.\nGPU hardware has no exception mechanism.",
		example = "    @gpu\n    def kernel(x: int) -> int:\n        try:           # GPU004\n            return x\n        except:\n            return 0",
	},
	{
		code = "GPU005", name = "Recursive call in @gpu function", category = "GPU", severity = "Warning",
		description = "Recursive function calls in GPU kernels can exhaust the limited GPU stack.\nMost GPU architectures have very small call stacks.",
		example = "    @gpu\n    def factorial(n: int) -> int:\n        if n <= 1: return 1\n        return n * factorial(n - 1)  # GPU005",
	},
	{
		code = "GPU006", name = "Dynamic dispatch in @gpu function", category = "GPU", severity = "Error",
		description = "eval, exec, getattr, isinstance and similar dynamic features require the\nPython runtime, which is not available on GPUs.",
		example = "    @gpu\n    def kernel(x: int) -> int:\n        return eval(\"x + 1\")  # GPU006",
	},
	{
		code = "GPU008", name = "Unbounded while loop in @gpu function", category = "GPU", severity = "Warning",
		description = "A while loop without a clear termination condition may cause a GPU hang.\nGPU threads that don't terminate block the entire wavefront.",
		example = "    @gpu\n    def kernel(x: int) -> int:\n        while True:  # GPU008\n            x = x + 1",
	},
	{
		code = "GPU010", name = "Unsupported construct in @gpu function", category = "GPU", severity = "Error",
		description = "A Python construct (class, nested function, yield, async, global, nonlocal,\nwith, import) cannot be compiled to GPU compute shaders.",
		example = "    @gpu\n    def kernel(x: int) -> int:\n        class Foo: pass  # GPU010: unsupported\n        return x",
	},

	// ── WASM ──

	{
		code = "WASM001", name = "Untyped parameter in @wasm function", category = "WASM", severity = "Error",
		description = "All parameters in @wasm functions must have type annotations. WASM requires\nstatic types for all locals and parameters.",
		example = "    @wasm\n    def add(a, b):  # WASM001: missing type annotations\n        return a + b\n    # Fix: def add(a: int, b: int) -> int:",
	},
	{
		code = "WASM002", name = "String operation in @wasm function", category = "WASM", severity = "Error",
		description = "String operations cannot be compiled to WASM. WASM linear memory has no\nstring heap or garbage collector.",
		example = "    @wasm\n    def greet(name: str) -> str:  # WASM002\n        return \"Hello \" + name",
	},
	{
		code = "WASM003", name = "Heap allocation in @wasm function", category = "WASM", severity = "Error",
		description = "Dynamic memory allocation (list, dict, set, comprehensions) is not supported\nin WASM. Memory must be managed through linear memory.",
		example = "    @wasm\n    def make_list(n: int) -> int:\n        data = [0] * n  # WASM003\n        return len(data)",
	},
	{
		code = "WASM004", name = "Exception handling in @wasm function", category = "WASM", severity = "Error",
		description = "try/except/raise/assert cannot be compiled to WASM MVP. The WASM MVP\nspecification has no exception handling mechanism.",
		example = "    @wasm\n    def safe_div(a: int, b: int) -> int:\n        try:            # WASM004\n            return a // b\n        except:\n            return 0",
	},
	{
		code = "WASM005", name = "Recursive call in @wasm function", category = "WASM", severity = "Warning",
		description = "Recursive calls in WASM functions can exhaust the ~1MB call stack,\ncausing a trap. WASM supports recursion but the stack is limited.",
		example = "    @wasm\n    def fib(n: int) -> int:\n        if n <= 1: return n\n        return fib(n-1) + fib(n-2)  # WASM005: stack risk",
	},
	{
		code = "WASM006", name = "Dynamic dispatch in @wasm function", category = "WASM", severity = "Error",
		description = "eval, exec, getattr, isinstance and similar dynamic features require the\nPython runtime, which is not available in WASM.",
		example = "    @wasm\n    def compute(x: int) -> int:\n        return eval(\"x + 1\")  # WASM006",
	},
	{
		code = "WASM007", name = "Unsupported construct in @wasm function", category = "WASM", severity = "Error",
		description = "A Python construct (class, nested function, yield, async, global, nonlocal,\nwith, import) cannot be compiled to WebAssembly.",
		example = "    @wasm\n    def compute(x: int) -> int:\n        def helper(): pass  # WASM007\n        return x",
	},
	{
		code = "WASM008", name = "Unbounded while loop in @wasm function", category = "WASM", severity = "Warning",
		description = "A while loop without a clear termination condition may not terminate in a\nbrowser context. WASM runs on the main thread by default.",
		example = "    @wasm\n    def spin(x: int) -> int:\n        while True:  # WASM008\n            x += 1",
	},
	// ==================== Regex ====================
	{
		code = "REG001", name = "Invalid group reference", category = "Regex", severity = "Error",
		description = "A regex match .group(N) or match[N] references a group number that\nexceeds the number of capturing groups in the pattern.",
		example = "    import re\n    m = re.match(r\"(\\d+)-(\\d+)\", text)\n    m.group(3)  # REG001: pattern has 2 groups",
		note = "Group 0 is the entire match and is always valid. Group numbers\nstart at 1 for the first capturing group.",
	},
	{
		code = "REG002", name = "Invalid named group reference", category = "Regex", severity = "Error",
		description = "A regex match .group(\"name\") references a named group that does\nnot exist in the pattern.",
		example = "    import re\n    m = re.match(r\"(?P<host>[\\w.]+):(?P<port>\\d+)\", text)\n    m.group(\"prot\")  # REG002: no group \"prot\"",
		note = "Check the pattern for (?P<name>...) groups. Named groups must\nmatch exactly (case-sensitive).",
	},
	// ==================== Time & Encoding ====================
	{
		code = "TIME001", name = "Naive/aware datetime mixing", category = "Time", severity = "Warning",
		description = "Arithmetic or comparison between a naive datetime (no timezone) and an\naware datetime (has timezone) raises TypeError at runtime.",
		example = "    from datetime import datetime, timezone\n    naive = datetime.now()\n    aware = datetime.now(tz=timezone.utc)\n    diff = aware - naive  # TIME001",
		note = "datetime.now() returns naive. datetime.now(tz=timezone.utc) returns\naware. Use .replace(tzinfo=...) or .astimezone() to convert.",
	},
	{
		code = "ENC001", name = "str passed to bytes-expecting function", category = "Encoding", severity = "Error",
		description = "A function that expects bytes (e.g., hashlib, hmac) received a str\nargument. This raises TypeError at runtime.",
		example = "    import hashlib\n    password = \"secret\"\n    hashlib.sha256(password)  # ENC001: expects bytes",
		note = "Encode the string first: password.encode() or password.encode('utf-8').\nMost hashing/HMAC functions require bytes input.",
	},
	// ==================== API Contract ====================
	{
		code = "API001", name = "Response field not in spec", category = "API Contract", severity = "Error",
		description = "A route handler returns a field that is not defined in the\nOpenAPI specification's response schema.",
		example = "    @route(\"POST\", \"/users\")\n    def create_user(req):\n        return {\"id\": 1, \"username\": \"foo\"}  # API001: \"username\" not in spec",
		note = "Check the OpenAPI spec's response properties for this route.\nThe spec may use a different field name (e.g., \"name\" vs \"username\").",
	},
	{
		code = "API002", name = "Required field missing from response", category = "API Contract", severity = "Warning",
		description = "The OpenAPI specification requires a field in the response that\nthe handler does not include in its return dict.",
		example = "    @route(\"GET\", \"/users/{id}\")\n    def get_user(req, id):\n        return {\"id\": 1}  # API002: required field \"name\" missing",
		note = "Add the missing field to the response or update the spec\nto make the field optional.",
	},
	{
		code = "API003", name = "Route not in spec", category = "API Contract", severity = "Warning",
		description = "A route handler is defined in code but not found in the\nOpenAPI specification file (openapi.json).",
		example = "    @route(\"GET\", \"/health\")\n    def health(req):\n        return {\"status\": \"ok\"}  # API003: not in openapi.json",
		note = "Add the route to openapi.json or remove the handler if it\nis no longer needed.",
	},
	// ==================== Compatibility ====================
	{
		code = "COMPAT001", name = "Python version incompatibility", category = "Compatibility", severity = "Error",
		description = "Code uses syntax that requires a newer Python version than\ndeclared in mimir.toml requires-python.",
		example = "    # mimir.toml: requires-python = \">=3.8\"\n    match status:  # COMPAT001: match/case requires 3.10+\n        case \"ok\": ...",
		note = "Either update requires-python to the needed version or\navoid using this syntax for backward compatibility.",
	},
	{
		code = "DEP001", name = "Unused dependency", category = "Dependencies", severity = "Warning",
		description = "A dependency is declared in mimir.toml [dependencies] but\nnever imported in the checked file.",
		example = "    # mimir.toml: [dependencies] redis = \"*\"\n    # No 'import redis' found → DEP001",
		note = "Remove unused dependencies to reduce install time and\nattack surface. Note: single-file check may miss imports\nfrom other project files.",
	},
	{
		code = "DEP002", name = "Missing dependency", category = "Dependencies", severity = "Warning",
		description = "A module is imported but not declared in mimir.toml\n[dependencies]. Standard library modules are excluded.",
		example = "    import httpx  # DEP002: not in [dependencies]\n    # Fix: mimir add httpx",
		note = "Undeclared dependencies may not be installed in deployment.\nRun 'mimir add <package>' to declare them.",
	},
	// ==================== Serialization ====================
	{
		code = "SER001", name = "Tainted deserialization", category = "Serialization", severity = "Error",
		description = "pickle.loads() or marshal.loads() is called with data from a\npotentially untrusted source (request body, user input, etc.).",
		example = "    import pickle\n    data = pickle.loads(request.body)  # SER001: untrusted data",
		note = "Deserializing untrusted data can execute arbitrary code.\nUse json.loads() for untrusted data, or validate the source.",
	},
	{
		code = "SER002", name = "Shelve uses pickle", category = "Serialization", severity = "Warning",
		description = "shelve.open() uses pickle internally for serialization.\nOpening a shelve file from an untrusted source is unsafe.",
		example = "    import shelve\n    db = shelve.open(\"data.db\")  # SER002: uses pickle",
		note = "Shelve files can execute arbitrary code when opened.\nUse sqlite3 or json-based storage for untrusted data.",
	},
	{
		code = "SER003", name = "__dict__ serialization", category = "Serialization", severity = "Warning",
		description = "json.dumps() on obj.__dict__ may include non-serializable\ntypes (datetime, set, bytes, custom objects).",
		example = "    import json\n    json.dumps(user.__dict__)  # SER003: may fail at runtime",
		note = "Use dataclasses.asdict() or explicitly select fields.\n__dict__ includes all instance attributes without filtering.",
	},

	// ==================== ML Pipeline ====================
	{
		code = "ML001", name = "Data leakage", category = "ML Pipeline", severity = "Error",
		description = "A transformer (StandardScaler, etc.) was fit on data that is then\npassed to train_test_split. This leaks test set statistics into training.",
		example = "    scaler = StandardScaler()\n    X_scaled = scaler.fit_transform(X)\n    X_train, X_test = train_test_split(X_scaled)  # ML001",
		note = "Split data first, then fit_transform on the training set only:\n    X_train, X_test = train_test_split(X)\n    X_train = scaler.fit_transform(X_train)\n    X_test = scaler.transform(X_test)",
	},
	{
		code = "ML002", name = "Pipeline ordering", category = "ML Pipeline", severity = "Warning",
		description = "A preprocessor (scaler, encoder) appears after a model in a\nsklearn Pipeline. Features will not be transformed before model training.",
		example = "    Pipeline([\n        (\"model\", LogisticRegression()),\n        (\"scaler\", StandardScaler()),\n    ])  # ML002",
		note = "Reorder pipeline steps: preprocessors first, then models.\nPipeline executes steps in list order — transform → predict.",
	},
}
