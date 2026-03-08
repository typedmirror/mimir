package binder

import parser "mimir:parser"
import core "mimir:core"

Import_Record :: struct {
	module_name: string,
	names:       []Import_Name,
	level:       int,
	loc:         parser.Src_Loc,
	is_star:     bool,
}

Import_Name :: struct {
	name:  string,
	alias: string,
}

record_import :: proc(b: ^Binder, stmt: ^parser.Import_Stmt) {
	for alias in stmt.names {
		local_name := alias.asname if len(alias.asname) > 0 else alias.name
		// For "import os.path", the local name is just "os" (top-level module)
		dot_idx := -1
		for i := 0; i < len(local_name); i += 1 {
			if local_name[i] == '.' {
				dot_idx = i
				break
			}
		}
		bound_name := local_name[:dot_idx] if dot_idx >= 0 else local_name
		if len(alias.asname) > 0 {
			bound_name = alias.asname
		}

		add_symbol(b, bound_name, .Import, {.Is_Imported}, stmt.loc)

		append(&b.result.imports, Import_Record{
			module_name = alias.name,
			level       = 0,
			loc         = stmt.loc,
		})
	}
}

record_import_from :: proc(b: ^Binder, stmt: ^parser.Import_From) {
	// Check for star import
	if len(stmt.names) == 1 && stmt.names[0].name == "*" {
		b.has_star_import = true
		append(&b.result.imports, Import_Record{
			module_name = stmt.module,
			level       = stmt.level,
			loc         = stmt.loc,
			is_star     = true,
		})
		append(&b.result.diagnostics, core.Diagnostic{
			severity = .Warning,
			location = core.Location{
				file   = b.file_path,
				line   = int(stmt.loc.line),
				column = int(stmt.loc.col),
			},
			what = "wildcard import",
			why  = "'from ... import *' makes it unclear which names are in scope",
			fix  = "import specific names instead",
			code = "B005",
		})
		return
	}

	names := make([]Import_Name, len(stmt.names), b.allocator)
	for alias, i in stmt.names {
		local_name := alias.asname if len(alias.asname) > 0 else alias.name
		add_symbol(b, local_name, .Import, {.Is_Imported}, stmt.loc)
		names[i] = Import_Name{
			name  = alias.name,
			alias = alias.asname,
		}
	}

	append(&b.result.imports, Import_Record{
		module_name = stmt.module,
		names       = names,
		level       = stmt.level,
		loc         = stmt.loc,
	})

	// Detect typing imports for special form dispatch
	if stmt.module == "typing" || stmt.module == "typing_extensions" {
		for alias in stmt.names {
			local_name := alias.asname if len(alias.asname) > 0 else alias.name
			b.result.typing_names[local_name] = alias.name
		}
	}
}
