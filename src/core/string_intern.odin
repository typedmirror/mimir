package core

import "core:mem"

// String_Intern deduplicates strings during parsing/binding.
// All interned strings share ownership with the analysis arena.
String_Intern :: struct {
	entries:   map[string]string,
	allocator: mem.Allocator,
}

string_intern_init :: proc(si: ^String_Intern, allocator: mem.Allocator) {
	si.allocator = allocator
	si.entries = make(map[string]string, 256, allocator)
}

string_intern :: proc(si: ^String_Intern, s: string) -> string {
	if existing, ok := si.entries[s]; ok {
		return existing
	}
	owned := strings_clone(s, si.allocator)
	si.entries[owned] = owned
	return owned
}

// Clone a string into the given allocator.
strings_clone :: proc(s: string, allocator: mem.Allocator) -> string {
	buf := make([]byte, len(s), allocator)
	copy(buf, s)
	return string(buf)
}
