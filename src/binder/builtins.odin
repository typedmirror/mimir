package binder

import parser "mimir:parser"

BUILTIN_NAMES := [?]string{
	// Functions
	"abs", "aiter", "all", "anext", "any", "ascii",
	"bin", "breakpoint", "callable", "chr", "classmethod",
	"compile", "complex", "copyright", "credits",
	"delattr", "dir", "divmod",
	"enumerate", "eval", "exec", "exit",
	"filter", "format",
	"getattr", "globals",
	"hasattr", "hash", "help", "hex",
	"id", "input", "isinstance", "issubclass", "iter",
	"len", "license", "locals",
	"map", "max", "memoryview", "min",
	"next",
	"object", "oct", "open", "ord",
	"pow", "print", "property", "quit",
	"range", "repr", "reversed", "round",
	"setattr", "slice", "sorted", "staticmethod", "sum", "super",
	"vars", "zip",
	// Types
	"bool", "bytearray", "bytes",
	"dict", "float", "frozenset", "int", "list", "set", "str", "tuple", "type",
	// Constants
	"True", "False", "None", "Ellipsis", "NotImplemented", "__debug__",
	"__name__", "__doc__", "__file__", "__spec__", "__loader__",
	"__package__", "__builtins__", "__import__",
	// Exceptions
	"ArithmeticError", "AssertionError", "AttributeError",
	"BaseException", "BaseExceptionGroup", "BlockingIOError",
	"BrokenPipeError", "BufferError", "BytesWarning",
	"ChildProcessError", "ConnectionAbortedError", "ConnectionError",
	"ConnectionRefusedError", "ConnectionResetError",
	"DeprecationWarning",
	"EOFError", "EnvironmentError", "Exception", "ExceptionGroup",
	"FileExistsError", "FileNotFoundError", "FloatingPointError",
	"FutureWarning",
	"GeneratorExit",
	"IOError", "ImportError", "ImportWarning",
	"IndentationError", "IndexError", "InterruptedError",
	"IsADirectoryError",
	"KeyError", "KeyboardInterrupt",
	"LookupError",
	"MemoryError", "ModuleNotFoundError",
	"NameError", "NotADirectoryError", "NotImplementedError",
	"OSError", "OverflowError",
	"PendingDeprecationWarning", "PermissionError",
	"ProcessLookupError",
	"RecursionError", "ReferenceError", "ResourceWarning",
	"RuntimeError", "RuntimeWarning",
	"StopAsyncIteration", "StopIteration", "SyntaxError",
	"SyntaxWarning", "SystemError", "SystemExit",
	"TabError", "TimeoutError", "TypeError",
	"UnboundLocalError", "UnicodeDecodeError", "UnicodeEncodeError",
	"UnicodeError", "UnicodeTranslationError", "UnicodeWarning",
	"UserWarning",
	"ValueError",
	"Warning",
	"ZeroDivisionError",
}

init_builtins :: proc(b: ^Binder) {
	loc := parser.Src_Loc{}
	push_scope(b, .Builtin, "<builtins>", loc)
	for name in BUILTIN_NAMES {
		add_symbol(b, name, .Variable, {}, loc)
	}
}
