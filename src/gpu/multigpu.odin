package gpu

import "core:fmt"
import "core:mem"
import "core:strings"

import parser "mimir:parser"
import binder "mimir:binder"
import core   "mimir:core"

// Multi-GPU Analysis (§6/§7)
//
// Diagnostics:
//   GPU012 — Unbalanced multi-device: tensors used across different device
//            contexts without explicit .to(device) migration
//   GPU013 — Missing synchronization: cross-device data transfer without
//            synchronize() barrier

// Known device allocation patterns (PyTorch, JAX, TensorFlow)
DEVICE_CONSTRUCTORS :: [?]string{
	"cuda", "to", "device",
}

DEVICE_STRINGS :: [?]string{
	"cuda:0", "cuda:1", "cuda:2", "cuda:3",
	"gpu:0", "gpu:1", "gpu:2", "gpu:3",
}

SYNC_METHODS :: [?]string{
	"synchronize", "sync", "wait", "barrier",
}

TRANSFER_METHODS :: [?]string{
	"to", "cuda", "cpu", "copy_", "clone",
}

// Device_Ref tracks which variables are bound to which device.
Device_Ref :: struct {
	var_name:    string,
	device_str:  string,
	loc:         parser.Src_Loc,
}

// Analyze a module for multi-GPU issues.
analyze_multigpu :: proc(
	module: ^parser.Module,
	bind_result: ^binder.Bind_Result,
	file_path: string,
	diagnostics: ^[dynamic]core.Diagnostic,
	allocator: mem.Allocator,
) {
	// Scan all functions (not just @gpu — multi-GPU issues occur in host code)
	_scan_body_multigpu(module.body, file_path, diagnostics, allocator)

	for stmt in module.body {
		#partial switch s in stmt {
		case ^parser.Func_Def:
			_scan_body_multigpu(s.body, file_path, diagnostics, allocator)
		case ^parser.Async_Func_Def:
			_scan_body_multigpu(s.body, file_path, diagnostics, allocator)
		case ^parser.Class_Def:
			for body_stmt in s.body {
				#partial switch ms in body_stmt {
				case ^parser.Func_Def:
					_scan_body_multigpu(ms.body, file_path, diagnostics, allocator)
				case ^parser.Async_Func_Def:
					_scan_body_multigpu(ms.body, file_path, diagnostics, allocator)
				}
			}
		}
	}
}

// Scan a function body for multi-GPU patterns.
@(private = "file")
_scan_body_multigpu :: proc(
	stmts: []parser.Stmt,
	file_path: string,
	diagnostics: ^[dynamic]core.Diagnostic,
	allocator: mem.Allocator,
) {
	// Phase 1: Collect device references (variable → device string)
	device_refs := make([dynamic]Device_Ref, 0, 8, allocator)
	has_sync := false
	has_transfer := false
	transfer_locs := make([dynamic]parser.Src_Loc, 0, 8, allocator)

	_collect_device_info(stmts, &device_refs, &has_sync, &has_transfer, &transfer_locs)

	// Phase 2: Check for multi-device usage without proper handling
	if len(device_refs) < 2 { return } // Single device — nothing to check

	// GPU012: Check if multiple distinct devices are referenced
	devices_seen := make(map[string]parser.Src_Loc, 4, allocator)
	for ref in device_refs {
		devices_seen[ref.device_str] = ref.loc
	}

	if len(devices_seen) >= 2 {
		// Multiple devices detected — check for unbalanced usage
		// Find variables that are created on one device but used in context of another
		device_list := make([dynamic]string, 0, len(devices_seen), allocator)
		for dev, _ in devices_seen {
			append(&device_list, dev)
		}

		if !has_transfer {
			// Multiple devices referenced but no .to() / .cuda() transfers
			first_loc: parser.Src_Loc
			for _, loc in devices_seen {
				first_loc = loc
				break
			}
			append(diagnostics, core.Diagnostic{
				severity = .Warning,
				location = core.Location{
					file   = file_path,
					line   = int(first_loc.line),
					column = int(first_loc.col),
				},
				code = "GPU012",
				what = fmt.tprintf("multiple GPU devices referenced (%s) without explicit tensor migration",
					strings.join(device_list[:], ", ", allocator)),
				why  = "tensors on different devices cannot be used together — operations will fail with device mismatch errors",
				fix  = "use .to(device) to explicitly migrate tensors to the target device before operations",
			})
		}

		// GPU013: Cross-device transfer without synchronization
		if has_transfer && !has_sync {
			for loc in transfer_locs {
				append(diagnostics, core.Diagnostic{
					severity = .Warning,
					location = core.Location{
						file   = file_path,
						line   = int(loc.line),
						column = int(loc.col),
					},
					code = "GPU013",
					what = "cross-device transfer without synchronization barrier",
					why  = "GPU operations are asynchronous — reading transferred data before sync can produce stale or undefined values",
					fix  = "call torch.cuda.synchronize() or device.synchronize() after cross-device transfers",
				})
			}
		}
	}
}

// Collect device reference information from statements.
@(private = "file")
_collect_device_info :: proc(
	stmts: []parser.Stmt,
	device_refs: ^[dynamic]Device_Ref,
	has_sync: ^bool,
	has_transfer: ^bool,
	transfer_locs: ^[dynamic]parser.Src_Loc,
) {
	for stmt in stmts {
		#partial switch s in stmt {
		case ^parser.Assign:
			// x = torch.device("cuda:0"), x = tensor.to("cuda:1")
			_check_expr_for_device(s.value, s.loc, device_refs, has_sync, has_transfer, transfer_locs)
		case ^parser.Expr_Stmt:
			_check_expr_for_device(s.value, s.loc, device_refs, has_sync, has_transfer, transfer_locs)
		case ^parser.If_Stmt:
			_collect_device_info(s.body, device_refs, has_sync, has_transfer, transfer_locs)
			_collect_device_info(s.orelse, device_refs, has_sync, has_transfer, transfer_locs)
		case ^parser.For_Stmt:
			_collect_device_info(s.body, device_refs, has_sync, has_transfer, transfer_locs)
		case ^parser.While_Stmt:
			_collect_device_info(s.body, device_refs, has_sync, has_transfer, transfer_locs)
		}
	}
}

@(private = "file")
_check_expr_for_device :: proc(
	expr: parser.Expr,
	loc: parser.Src_Loc,
	device_refs: ^[dynamic]Device_Ref,
	has_sync: ^bool,
	has_transfer: ^bool,
	transfer_locs: ^[dynamic]parser.Src_Loc,
) {
	if expr == nil { return }

	#partial switch e in expr {
	case ^parser.Call_Expr:
		// Check for device() constructor or .to() method
		#partial switch f in e.func {
		case ^parser.Name_Expr:
			// torch.device("cuda:0") called as device("cuda:0")
			if f.id == "device" && len(e.args) > 0 {
				if dev_str := _extract_device_string(e.args[0]); len(dev_str) > 0 {
					append(device_refs, Device_Ref{device_str = dev_str, loc = loc})
				}
			}
		case ^parser.Attribute_Expr:
			// x.to("cuda:1"), x.cuda(), torch.cuda.synchronize()
			if f.attr == "to" && len(e.args) > 0 {
				if dev_str := _extract_device_string(e.args[0]); len(dev_str) > 0 {
					append(device_refs, Device_Ref{device_str = dev_str, loc = loc})
					has_transfer^ = true
					append(transfer_locs, loc)
				}
			} else if f.attr == "cuda" {
				// .cuda() defaults to cuda:0; .cuda(device_id) specifies device
				dev_str := "cuda:0"
				if len(e.args) > 0 {
					if c, ok := e.args[0].(^parser.Constant_Expr); ok {
						if v, vok := c.value.(i64); vok {
							dev_str = fmt.tprintf("cuda:%d", v)
						}
					}
				}
				append(device_refs, Device_Ref{device_str = dev_str, loc = loc})
				has_transfer^ = true
				append(transfer_locs, loc)
			}
			// Check for synchronize
			for m in SYNC_METHODS {
				if f.attr == m {
					has_sync^ = true
				}
			}
		}
	}
}

@(private = "file")
_extract_device_string :: proc(expr: parser.Expr) -> string {
	if expr == nil { return "" }
	#partial switch e in expr {
	case ^parser.Constant_Expr:
		if s, ok := e.value.(string); ok {
			// Check if it matches a known device string pattern
			for ds in DEVICE_STRINGS {
				if s == ds { return s }
			}
			// Also match bare "cuda" or "cpu"
			if s == "cuda" { return "cuda:0" }
			if s == "cpu" { return "cpu" }
		}
	}
	return ""
}
