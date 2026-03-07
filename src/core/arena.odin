package core

import "core:mem"
import "core:mem/virtual"

// Analysis_Arena wraps a virtual arena for per-pass allocation.
// All analysis data lives here — allocate during analysis, bulk free when done.
Analysis_Arena :: struct {
	arena:     virtual.Arena,
	allocator: mem.Allocator,
}

arena_init :: proc(a: ^Analysis_Arena) -> mem.Allocator_Error {
	err := virtual.arena_init_growing(&a.arena)
	a.allocator = virtual.arena_allocator(&a.arena)
	return err
}

arena_destroy :: proc(a: ^Analysis_Arena) {
	virtual.arena_destroy(&a.arena)
}

arena_reset :: proc(a: ^Analysis_Arena) {
	free_all(a.allocator)
}
