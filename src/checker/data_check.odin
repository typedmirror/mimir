package checker

import "core:fmt"

import parser "mimir:parser"
import core   "mimir:core"

// ==================== DataFrame Column Analysis ====================
//
// Helpers for DataFrame/Series type inference during the main
// type checking pass. Column access validation, method resolution,
// and constructor column inference.
//
// Diagnostics:
//   DATA001 — Column not found in DataFrame
//   DATA002 — Invalid schema type for read_csv/read_json
//   DATA003 — Numeric operation on non-numeric column

// Resolve DataFrame subscript: df["col"] → Series, df[["a","b"]] → DataFrame
resolve_dataframe_subscript :: proc(ctx: ^Infer_Context, df: ^DataFrame_Type, e: ^parser.Subscript_Expr) -> Type_ID {
	// Single string key → Series with column type
	#partial switch key_expr in e.slice {
	case ^parser.Constant_Expr:
		if key_str, ok := key_expr.value.(string); ok {
			if col_type, found := df.columns[key_str]; found {
				return make_series_type(ctx.reg, col_type, key_str)
			}
			if len(df.columns) > 0 {
				// DATA001: column not found
				avail := available_columns(df, ctx.reg.allocator)
				emit_diagnostic(ctx, e.loc, "DATA001", .Error,
					"Column not found",
					fmt.aprintf("DataFrame has no column '%s'. Available: %s",
						key_str, avail,
						allocator = ctx.reg.allocator),
					"Check the column name for typos")
				return TYPE_UNKNOWN
			}
			// Unknown columns — permissive
			return make_series_type(ctx.reg, TYPE_UNKNOWN, key_str)
		}
	case ^parser.List_Expr:
		// Multi-column select: df[["a", "b"]] → sub-DataFrame
		sub_cols := make(map[string]Type_ID, len(key_expr.elts), ctx.reg.allocator)
		all_valid := true
		for elt in key_expr.elts {
			if c, ok := elt.(^parser.Constant_Expr); ok {
				if col_str, ok2 := c.value.(string); ok2 {
					if col_type, found := df.columns[col_str]; found {
						sub_cols[col_str] = col_type
					} else if len(df.columns) > 0 {
						avail := available_columns(df, ctx.reg.allocator)
						emit_diagnostic(ctx, e.loc, "DATA001", .Error,
							"Column not found",
							fmt.aprintf("DataFrame has no column '%s'. Available: %s",
								col_str, avail,
								allocator = ctx.reg.allocator),
							"Check the column name for typos")
						all_valid = false
					}
				}
			}
		}
		if !all_valid { return TYPE_UNKNOWN }
		if len(sub_cols) > 0 {
			return make_dataframe_type(ctx.reg, sub_cols)
		}
		// Unknown columns or non-literal list
		return make_dataframe_type(ctx.reg, {})
	}

	// Non-literal key or slice — return generic Series
	if _, is_slice := e.slice.(^parser.Slice_Expr); is_slice {
		return make_dataframe_type(ctx.reg, df.columns)
	}
	return make_series_type(ctx.reg, TYPE_UNKNOWN, "")
}

// Resolve DataFrame attribute access — methods that return known types.
resolve_dataframe_attr :: proc(reg: ^Type_Registry, df: ^DataFrame_Type, attr: string) -> Type_ID {
	no_params := make([]Param_Type, 0, reg.allocator)
	df_type := make_dataframe_type(reg, df.columns)

	switch attr {
	// Methods returning same DataFrame type (columns preserved)
	case "sort_values":
		return make_callable_type(reg,
			{Param_Type{name = "by", type_id = TYPE_STR}, Param_Type{name = "ascending", type_id = TYPE_BOOL, has_default = true}},
			df_type)
	case "head", "tail":
		return make_callable_type(reg,
			{Param_Type{name = "n", type_id = TYPE_INT, has_default = true}},
			df_type)
	case "drop_duplicates":
		return make_callable_type(reg, no_params, df_type)
	case "fillna":
		return make_callable_type(reg,
			{Param_Type{name = "value", type_id = TYPE_ANY}},
			df_type)
	case "dropna":
		return make_callable_type(reg, no_params, df_type)
	case "copy":
		return make_callable_type(reg, no_params, df_type)
	case "reset_index":
		return make_callable_type(reg,
			{Param_Type{name = "drop", type_id = TYPE_BOOL, has_default = true}},
			df_type)
	case "rename":
		return make_callable_type(reg,
			{Param_Type{name = "columns", type_id = TYPE_ANY, has_default = true}},
			make_dataframe_type(reg, {})) // columns unknown after rename

	// Aggregation methods returning Series
	case "mean", "sum", "min", "max", "std":
		return make_callable_type(reg, no_params, make_series_type(reg, TYPE_FLOAT))
	case "count":
		return make_callable_type(reg, no_params, make_series_type(reg, TYPE_INT))

	// Properties
	case "shape":
		return make_tuple_type(reg, {TYPE_INT, TYPE_INT}, false)
	case "columns":
		return make_list_type(reg, TYPE_STR)
	case "dtypes":
		return make_dict_type(reg, TYPE_STR, TYPE_STR)
	case "values":
		return make_list_type(reg, make_list_type(reg, TYPE_ANY))
	case "index":
		return make_list_type(reg, TYPE_INT)
	case "T":
		return df_type

	// groupby — returns opaque callable (full tracking deferred)
	case "groupby":
		return make_callable_type(reg,
			{Param_Type{name = "by", type_id = TYPE_STR}},
			TYPE_ANY)

	// merge/join
	case "merge":
		return make_callable_type(reg,
			{
				Param_Type{name = "right", type_id = TYPE_ANY},
				Param_Type{name = "on", type_id = TYPE_STR, has_default = true},
				Param_Type{name = "how", type_id = TYPE_STR, has_default = true},
			},
			make_dataframe_type(reg, {})) // columns unknown after merge

	// I/O
	case "to_csv":
		return make_callable_type(reg,
			{Param_Type{name = "path", type_id = TYPE_STR}},
			TYPE_NONE)
	case "to_json":
		return make_callable_type(reg,
			{Param_Type{name = "path", type_id = TYPE_STR}},
			TYPE_NONE)
	}

	return TYPE_UNKNOWN
}

// Resolve Series attribute access.
resolve_series_attr :: proc(reg: ^Type_Registry, series: ^Series_Type, attr: string) -> Type_ID {
	no_params := make([]Param_Type, 0, reg.allocator)

	elem_numeric := is_numeric(reg, series.element) || series.element == TYPE_UNKNOWN || series.element == TYPE_ANY

	switch attr {
	// Aggregation → element type or float (only for numeric columns)
	case "mean", "std":
		if !elem_numeric { return TYPE_UNKNOWN }
		return make_callable_type(reg, no_params, TYPE_FLOAT)
	case "sum":
		if !elem_numeric { return TYPE_UNKNOWN }
		return make_callable_type(reg, no_params, series.element)
	case "min", "max":
		if !elem_numeric { return TYPE_UNKNOWN }
		return make_callable_type(reg, no_params, series.element)
	case "count":
		return make_callable_type(reg, no_params, TYPE_INT)

	// Transformations → same Series
	case "sort_values":
		return make_callable_type(reg,
			{Param_Type{name = "ascending", type_id = TYPE_BOOL, has_default = true}},
			make_series_type(reg, series.element, series.name))
	case "fillna":
		return make_callable_type(reg,
			{Param_Type{name = "value", type_id = series.element}},
			make_series_type(reg, series.element, series.name))
	case "dropna":
		return make_callable_type(reg, no_params, make_series_type(reg, series.element, series.name))
	case "unique":
		return make_callable_type(reg, no_params, make_list_type(reg, series.element))
	case "head", "tail":
		return make_callable_type(reg,
			{Param_Type{name = "n", type_id = TYPE_INT, has_default = true}},
			make_series_type(reg, series.element, series.name))

	// Properties
	case "name":
		return TYPE_STR
	case "values":
		return make_list_type(reg, series.element)
	case "dtype":
		return TYPE_STR
	case "shape":
		return make_tuple_type(reg, {TYPE_INT}, false)
	}

	return TYPE_UNKNOWN
}

// Infer DataFrame columns from dict literal constructor: DataFrame({"a": [1,2], "b": ["x","y"]})
infer_dataframe_from_dict :: proc(ctx: ^Infer_Context, dict_lit: ^parser.Dict_Expr) -> Type_ID {
	if len(dict_lit.keys) == 0 {
		return make_dataframe_type(ctx.reg, {})
	}

	cols := make(map[string]Type_ID, len(dict_lit.keys), ctx.reg.allocator)
	for key, i in dict_lit.keys {
		if key == nil { continue }
		// Key must be a string literal
		if c, ok := key.(^parser.Constant_Expr); ok {
			if col_name, ok2 := c.value.(string); ok2 {
				// Infer value type — extract list element type
				val_type := infer_expr(dict_lit.values[i], ctx)
				elem_type := get_list_element(ctx.reg, val_type)
				if elem_type == TYPE_UNKNOWN {
					elem_type = val_type
				}
				cols[col_name] = elem_type
			}
		}
	}

	if len(cols) > 0 {
		return make_dataframe_type(ctx.reg, cols)
	}
	return make_dataframe_type(ctx.reg, {})
}

// Build "available columns" string for DATA001 error messages.
available_columns :: proc(df: ^DataFrame_Type, allocator := context.allocator) -> string {
	buf := make([dynamic]u8, 0, 64, allocator)
	i := 0
	for col_name in df.columns {
		if i > 0 { for c in ", " { append(&buf, u8(c)) } }
		if i >= 8 { for c in "..." { append(&buf, u8(c)) }; break }
		append(&buf, '\'')
		for c in col_name { append(&buf, u8(c)) }
		append(&buf, '\'')
		i += 1
	}
	return string(buf[:])
}
