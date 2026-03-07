package mimir

import "core:fmt"
import "core:os"
import "core:strings"

main :: proc() {
	args := os.args
	if len(args) < 2 {
		print_usage()
		os.exit(1)
	}

	command := args[1]

	switch command {
	case "check":
		cmd_check(args[2:])
	case "version":
		cmd_version()
	case "help":
		print_usage()
	case:
		fmt.eprintfln("mimir: unknown command '%s'", command)
		fmt.eprintfln("Run 'mimir help' for usage.")
		os.exit(1)
	}
}

cmd_version :: proc() {
	fmt.println("mimir 0.0.1-dev")
}

cmd_check :: proc(args: []string) {
	if len(args) == 0 {
		fmt.eprintln("mimir check: no input path specified")
		fmt.eprintln("Usage: mimir check <path>")
		os.exit(1)
	}

	target := args[0]
	fmt.printfln("mimir: checking '%s'...", target)
	fmt.println("mimir: no analysis passes implemented yet")
}

print_usage :: proc() {
	fmt.println("mimir — Python development platform")
	fmt.println()
	fmt.println("Usage: mimir <command> [options]")
	fmt.println()
	fmt.println("Commands:")
	fmt.println("  check <path>    Analyze Python source files")
	fmt.println("  version         Print version")
	fmt.println("  help            Show this message")
}
