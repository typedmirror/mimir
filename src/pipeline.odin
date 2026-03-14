package mimir

// Shared analysis pipeline infrastructure.
// Eliminates boilerplate across cmd_lint, cmd_audit, cmd_check, etc.
//
// IMPORTANT: Pipeline contains a virtual.Arena which cannot be copied by value
// (the allocator holds internal pointers). pipeline_start takes a ^Pipeline
// to initialize in-place at the caller's address.

import "core:fmt"
import "core:os"

import "core"
import "parser"

Pipeline :: struct {
	files:   []string,
	bridge:  parser.Bridge,
	arena:   core.Analysis_Arena,
}

// Start the shared pipeline: find files, start bridge, init arena.
// Initializes p in-place (arena cannot be safely copied by value).
// Prints errors and calls os.exit(1) on infrastructure failure.
// Returns ok=false only if no files found (caller should return, not exit).
pipeline_start :: proc(command_name: string, target: string, p: ^Pipeline) -> bool {
	files, find_err := core.find_python_files(target)
	if find_err != nil {
		fmt.eprintfln("mimir %s: error reading '%s': %v", command_name, target, find_err)
		os.exit(1)
	}
	if len(files) == 0 {
		fmt.eprintfln("mimir %s: no Python files found in '%s'", command_name, target)
		return false
	}
	p.files = files

	bridge, bridge_err := parser.bridge_start()
	if bridge_err != nil {
		#partial switch e in bridge_err {
		case parser.Bridge_Error:
			fmt.eprintfln("mimir: %s", e.msg)
		case parser.Syntax_Error:
			fmt.eprintfln("mimir: %s", e.msg)
		}
		os.exit(1)
	}
	p.bridge = bridge

	arena_err := core.arena_init(&p.arena)
	if arena_err != nil {
		fmt.eprintln("mimir: failed to initialize analysis arena")
		os.exit(1)
	}

	return true
}

// Stop the pipeline: stop bridge, destroy arena.
pipeline_stop :: proc(p: ^Pipeline) {
	parser.bridge_stop(&p.bridge)
	core.arena_destroy(&p.arena)
}

// Parse a single file through the bridge. Returns nil on error (error already printed).
pipeline_parse_file :: proc(p: ^Pipeline, command_name: string, file: string) -> ^parser.Module {
	module, parse_err := parser.bridge_parse(&p.bridge, file, p.arena.allocator)
	if parse_err != nil {
		#partial switch e in parse_err {
		case parser.Syntax_Error:
			fmt.eprintfln("%s:%d:%d: error: %s", e.file, e.line, e.col, e.msg)
		case parser.Bridge_Error:
			fmt.eprintfln("mimir %s: %s: %s", command_name, file, e.msg)
		}
		return nil
	}
	return module
}
