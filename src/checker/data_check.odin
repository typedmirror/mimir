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
				emit_data001(ctx, e.loc, key_str, df)
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
						emit_data001(ctx, e.loc, col_str, df)
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

	// Non-literal key or slice — check for boolean filter or slice
	if _, is_slice := e.slice.(^parser.Slice_Expr); is_slice {
		return make_dataframe_type(ctx.reg, df.columns)
	}
	// Boolean filter: df[df["x"] > 0] or df[mask] → same columns preserved
	// Always infer the slice to ensure sub-expressions are type-checked
	slice_type := infer_expr(e.slice, ctx)
	is_bool_filter := false
	#partial switch _ in e.slice {
	case ^parser.Compare_Expr: is_bool_filter = true
	case ^parser.Bool_Op_Expr: is_bool_filter = true
	case ^parser.Unary_Op_Expr: is_bool_filter = true
	case:
		// Check if the subscript expression inferred to a Series or bool type
		if slice_type == TYPE_BOOL {
			is_bool_filter = true
		} else {
			st := get_type(ctx.reg, slice_type)
			if st != nil {
				#partial switch _ in st.info {
				case Series_Type: is_bool_filter = true
				}
			}
		}
	}
	if is_bool_filter {
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

	// groupby — returns callable that produces GroupBy instance
	case "groupby":
		groupby_ret := TYPE_ANY
		if reg.data_groupby_class != 0 {
			groupby_ret = make_instance_type(reg, reg.data_groupby_class)
		}
		return make_callable_type(reg,
			{Param_Type{name = "by", type_id = TYPE_STR}},
			groupby_ret)

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

// Find closest column name for "did you mean?" suggestions.
// Returns empty string if no close match found (edit distance > 2).
find_closest_column :: proc(target: string, df: ^DataFrame_Type) -> string {
	best_name := ""
	best_dist := 3 // threshold: suggest only if distance ≤ 2
	for col_name in df.columns {
		d := _edit_distance(target, col_name)
		if d < best_dist {
			best_dist = d
			best_name = col_name
		}
	}
	return best_name
}

// Simple Levenshtein edit distance (bounded at max 3 for early exit).
_edit_distance :: proc(a, b: string) -> int {
	la := len(a)
	lb := len(b)
	if la == 0 { return lb }
	if lb == 0 { return la }
	if la - lb > 3 || lb - la > 3 { return 4 } // fast reject

	// Use two rows for space efficiency
	prev := make([]int, lb + 1, context.temp_allocator)
	curr := make([]int, lb + 1, context.temp_allocator)
	for j in 0..=lb { prev[j] = j }

	for i in 1..=la {
		curr[0] = i
		for j in 1..=lb {
			cost := 0 if a[i-1] == b[j-1] else 1
			del := prev[j] + 1
			ins := curr[j-1] + 1
			sub := prev[j-1] + cost
			curr[j] = min(del, min(ins, sub))
		}
		prev, curr = curr, prev
	}
	return prev[lb]
}

// Build DATA001 diagnostic message with optional "did you mean?" suggestion.
emit_data001 :: proc(ctx: ^Infer_Context, loc: parser.Src_Loc, col_name: string, df: ^DataFrame_Type) {
	avail := available_columns(df, ctx.reg.allocator)
	suggestion := find_closest_column(col_name, df)
	hint := "Check the column name for typos"
	if len(suggestion) > 0 {
		hint = fmt.aprintf("Did you mean '%s'?", suggestion, allocator = ctx.reg.allocator)
	}
	emit_diagnostic(ctx, loc, "DATA001", .Error,
		"Column not found",
		fmt.aprintf("DataFrame has no column '%s'. Available: %s",
			col_name, avail,
			allocator = ctx.reg.allocator),
		hint)
}

// ==================== GroupBy Column Computation ====================

GroupBy_Info :: struct {
	df_type:   Type_ID,  // source DataFrame type
	group_key: string,   // column name used for grouping
}

// Compute result DataFrame columns for a groupby aggregation.
// Group key column is preserved. For sum/mean/std/min/max: only numeric columns.
// For count: all columns become int.
compute_groupby_result :: proc(reg: ^Type_Registry, info: ^GroupBy_Info, agg_name: string) -> Type_ID {
	src := get_type(reg, info.df_type)
	if src == nil { return make_dataframe_type(reg, {}) }
	#partial switch df_info in src.info {
	case DataFrame_Type:
		result_cols := make(map[string]Type_ID, len(df_info.columns), reg.allocator)
		// Always include group key
		if key_type, found := df_info.columns[info.group_key]; found {
			result_cols[info.group_key] = key_type
		}
		numeric_only := agg_name == "sum" || agg_name == "mean" || agg_name == "std" ||
		                agg_name == "min" || agg_name == "max"
		for col_name, col_type in df_info.columns {
			if col_name == info.group_key { continue }
			if numeric_only {
				if is_numeric(reg, col_type) || col_type == TYPE_UNKNOWN || col_type == TYPE_ANY {
					if agg_name == "mean" || agg_name == "std" {
						result_cols[col_name] = TYPE_FLOAT
					} else {
						result_cols[col_name] = col_type
					}
				}
				// Non-numeric columns silently dropped (pandas behavior)
			} else {
				// count: all columns → int
				result_cols[col_name] = TYPE_INT
			}
		}
		return make_dataframe_type(reg, result_cols)
	}
	return make_dataframe_type(reg, {})
}

// Compute merged DataFrame columns from left and right DataFrames.
compute_merge_result :: proc(reg: ^Type_Registry, left_type: Type_ID, right_type: Type_ID, join_key: string) -> Type_ID {
	left_t := get_type(reg, left_type)
	right_t := get_type(reg, right_type)
	if left_t == nil || right_t == nil { return make_dataframe_type(reg, {}) }

	left_df: ^DataFrame_Type
	right_df: ^DataFrame_Type
	#partial switch &info in left_t.info {
	case DataFrame_Type: left_df = &info
	}
	#partial switch &info in right_t.info {
	case DataFrame_Type: right_df = &info
	}
	if left_df == nil || right_df == nil { return make_dataframe_type(reg, {}) }

	result_cols := make(map[string]Type_ID, len(left_df.columns) + len(right_df.columns), reg.allocator)
	// All left columns
	for col_name, col_type in left_df.columns {
		result_cols[col_name] = col_type
	}
	// Right columns except join key (already from left)
	for col_name, col_type in right_df.columns {
		if col_name == join_key { continue }
		result_cols[col_name] = col_type
	}
	return make_dataframe_type(reg, result_cols)
}

// Compute renamed DataFrame columns from a rename mapping.
compute_rename_result :: proc(reg: ^Type_Registry, df_type: Type_ID, rename_map: map[string]string) -> Type_ID {
	t := get_type(reg, df_type)
	if t == nil { return make_dataframe_type(reg, {}) }
	#partial switch df_info in t.info {
	case DataFrame_Type:
		result_cols := make(map[string]Type_ID, len(df_info.columns), reg.allocator)
		for col_name, col_type in df_info.columns {
			if new_name, found := rename_map[col_name]; found {
				result_cols[new_name] = col_type
			} else {
				result_cols[col_name] = col_type
			}
		}
		return make_dataframe_type(reg, result_cols)
	}
	return make_dataframe_type(reg, {})
}
