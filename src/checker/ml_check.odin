package checker

import "core:fmt"
import "core:mem"

import parser "mimir:parser"
import binder "mimir:binder"
import core   "mimir:core"

// ==================== ML Pipeline Analysis ====================
//
// Post-inference analysis pass for sklearn pipeline anti-patterns.
// Detects data leakage (fit before split) and pipeline ordering issues.
//
// Diagnostics:
//   ML001 — Data leakage: fit/fit_transform called before train_test_split
//   ML002 — Pipeline ordering: model appears before preprocessor

// Known sklearn transformer constructor names.
KNOWN_TRANSFORMERS :: [?]string{
	"StandardScaler", "MinMaxScaler", "RobustScaler", "Normalizer",
	"MaxAbsScaler", "LabelEncoder", "OneHotEncoder", "OrdinalEncoder",
	"PolynomialFeatures", "PCA", "TfidfVectorizer", "CountVectorizer",
	"SelectKBest", "SelectFromModel",
}

// Known sklearn model constructor names.
KNOWN_MODELS :: [?]string{
	"LogisticRegression", "LinearRegression", "Ridge", "Lasso", "ElasticNet",
	"DecisionTreeClassifier", "DecisionTreeRegressor",
	"RandomForestClassifier", "RandomForestRegressor",
	"GradientBoostingClassifier", "GradientBoostingRegressor",
	"SVC", "SVR", "KNeighborsClassifier", "KNeighborsRegressor",
	"GaussianNB", "MultinomialNB",
	"MLPClassifier", "MLPRegressor",
	"AdaBoostClassifier", "AdaBoostRegressor",
	"XGBClassifier", "XGBRegressor",
	"LGBMClassifier", "LGBMRegressor",
}

ML_Check_Context :: struct {
	file_path:        string,
	diagnostics:      ^[dynamic]core.Diagnostic,
	transformer_vars: map[string]bool,              // variables holding transformers
	fitted_vars:      map[string]bool,              // transformers that had fit() called
	fitted_outputs:   map[string]parser.Src_Loc,    // variables assigned from fit_transform
	allocator:        mem.Allocator,
}

// Entry point — called from checker.odin after type checking.
analyze_ml :: proc(
	actx: ^Analysis_Pass_Context,
	diagnostics: ^[dynamic]core.Diagnostic,
) {
	// Check for sklearn imports (prefix match)
	has_sklearn := false
	for mod_name in actx.has_import {
		if len(mod_name) >= 7 && mod_name[:7] == "sklearn" { has_sklearn = true; break }
	}
	if !has_sklearn { return }

	module := actx.module
	file_path := actx.file_path
	allocator := actx.allocator

	// Analyze each function body independently
	for stmt in module.body {
		#partial switch s in stmt {
		case ^parser.Func_Def:
			analyze_ml_in_body(s.body, file_path, diagnostics, allocator)
		case ^parser.Async_Func_Def:
			analyze_ml_in_body(s.body, file_path, diagnostics, allocator)
		}
	}

	// Also analyze module-level statements (scripts)
	analyze_ml_in_body(module.body, file_path, diagnostics, allocator)
}

analyze_ml_in_body :: proc(
	stmts: []parser.Stmt,
	file_path: string,
	diagnostics: ^[dynamic]core.Diagnostic,
	allocator: mem.Allocator,
) {
	ctx := ML_Check_Context{
		file_path        = file_path,
		diagnostics      = diagnostics,
		transformer_vars = make(map[string]bool, 8, allocator),
		fitted_vars      = make(map[string]bool, 8, allocator),
		fitted_outputs   = make(map[string]parser.Src_Loc, 8, allocator),
		allocator        = allocator,
	}

	for stmt in stmts {
		check_ml_stmt(stmt, &ctx)
	}
}

check_ml_stmt :: proc(stmt: parser.Stmt, ctx: ^ML_Check_Context) {
	#partial switch s in stmt {
	case ^parser.Assign:
		// Check for: var = TransformerClass()
		if len(s.targets) == 1 {
			#partial switch t in s.targets[0] {
			case ^parser.Name_Expr:
				if is_transformer_constructor(s.value) {
					ctx.transformer_vars[t.id] = true
				}
				// Check for: var = transformer.fit_transform(X)
				if is_fit_transform_call(s.value, ctx) {
					ctx.fitted_outputs[t.id] = s.loc
				}
				// Check for: var = fitted_transformer.transform(X)
				if is_transform_of_fitted(s.value, ctx) {
					ctx.fitted_outputs[t.id] = s.loc
				}
			}
		}
		// Check for: X_train, X_test = train_test_split(...)
		if is_train_test_split(s.value) {
			check_leakage(s.value, s.loc, ctx)
		}
		// ML002: Check for Pipeline([...])
		check_pipeline_ordering(s.value, ctx)

	case ^parser.Expr_Stmt:
		// Standalone fit() call — marks the transformer as fitted
		mark_fitted_transformer(s.value, ctx)
		check_pipeline_ordering(s.value, ctx)

	case ^parser.For_Stmt:
		for body_stmt in s.body { check_ml_stmt(body_stmt, ctx) }
	case ^parser.If_Stmt:
		for body_stmt in s.body { check_ml_stmt(body_stmt, ctx) }
		for body_stmt in s.orelse { check_ml_stmt(body_stmt, ctx) }
	}
}

// ==================== ML001: Data Leakage ====================

is_transformer_constructor :: proc(expr: parser.Expr) -> bool {
	#partial switch e in expr {
	case ^parser.Call_Expr:
		#partial switch f in e.func {
		case ^parser.Name_Expr:
			for t in KNOWN_TRANSFORMERS {
				if f.id == t { return true }
			}
		}
	}
	return false
}

is_fit_transform_call :: proc(expr: parser.Expr, ctx: ^ML_Check_Context) -> bool {
	#partial switch e in expr {
	case ^parser.Call_Expr:
		#partial switch f in e.func {
		case ^parser.Attribute_Expr:
			if f.attr == "fit_transform" {
				#partial switch v in f.value {
				case ^parser.Name_Expr:
					if v.id in ctx.transformer_vars { return true }
				}
			}
		}
	}
	return false
}

is_fit_call :: proc(expr: parser.Expr, ctx: ^ML_Check_Context) -> bool {
	#partial switch e in expr {
	case ^parser.Call_Expr:
		#partial switch f in e.func {
		case ^parser.Attribute_Expr:
			if f.attr == "fit" {
				#partial switch v in f.value {
				case ^parser.Name_Expr:
					if v.id in ctx.transformer_vars { return true }
				}
			}
		}
	}
	return false
}

mark_fitted_transformer :: proc(expr: parser.Expr, ctx: ^ML_Check_Context) {
	#partial switch e in expr {
	case ^parser.Call_Expr:
		#partial switch f in e.func {
		case ^parser.Attribute_Expr:
			if f.attr == "fit" {
				#partial switch v in f.value {
				case ^parser.Name_Expr:
					if v.id in ctx.transformer_vars {
						ctx.fitted_vars[v.id] = true
					}
				}
			}
		}
	}
}

is_transform_of_fitted :: proc(expr: parser.Expr, ctx: ^ML_Check_Context) -> bool {
	#partial switch e in expr {
	case ^parser.Call_Expr:
		#partial switch f in e.func {
		case ^parser.Attribute_Expr:
			if f.attr == "transform" {
				#partial switch v in f.value {
				case ^parser.Name_Expr:
					if v.id in ctx.fitted_vars { return true }
				}
			}
		}
	}
	return false
}

is_train_test_split :: proc(expr: parser.Expr) -> bool {
	#partial switch e in expr {
	case ^parser.Call_Expr:
		#partial switch f in e.func {
		case ^parser.Name_Expr:
			return f.id == "train_test_split"
		}
	}
	return false
}

check_leakage :: proc(call_expr: parser.Expr, loc: parser.Src_Loc, ctx: ^ML_Check_Context) {
	// Check if any arg to train_test_split is a fitted output variable
	#partial switch e in call_expr {
	case ^parser.Call_Expr:
		for arg in e.args {
			#partial switch a in arg {
			case ^parser.Name_Expr:
				if fit_loc, ok := ctx.fitted_outputs[a.id]; ok {
					append(ctx.diagnostics, core.Diagnostic{
						severity = .Error,
						location = core.Location{
							file   = ctx.file_path,
							line   = int(loc.line),
							column = int(loc.col),
						},
						code = "ML001",
						what = fmt.tprintf("data leakage: '%s' was produced by fit_transform before train_test_split", a.id),
						why  = "fitting a transformer on all data before splitting leaks test set statistics into the model",
						fix  = "call train_test_split first, then fit_transform on the training set only",
					})
				}
			}
		}
	}
}

// ==================== ML002: Pipeline Ordering ====================

Step_Kind :: enum { Unknown, Preprocessor, Model }

check_pipeline_ordering :: proc(expr: parser.Expr, ctx: ^ML_Check_Context) {
	#partial switch e in expr {
	case ^parser.Call_Expr:
		// Look for Pipeline([...])
		#partial switch f in e.func {
		case ^parser.Name_Expr:
			if f.id != "Pipeline" { return }
		case: return
		}
		if len(e.args) < 1 { return }

		// First arg should be a list of tuples
		#partial switch list in e.args[0] {
		case ^parser.List_Expr:
			last_model_idx := -1
			last_model_name := ""
			for elt, idx in list.elts {
				kind, name := classify_pipeline_step(elt)
				if kind == .Model {
					last_model_idx = idx
					last_model_name = name
				} else if kind == .Preprocessor && last_model_idx >= 0 {
					// Preprocessor after model
					append(ctx.diagnostics, core.Diagnostic{
						severity = .Error,
						location = core.Location{
							file   = ctx.file_path,
							line   = int(e.loc.line),
							column = int(e.loc.col),
						},
						code = "ML002",
						what = fmt.tprintf("pipeline ordering: '%s' (preprocessor) appears after '%s' (model)", name, last_model_name),
						why  = "preprocessors should run before models so features are properly transformed",
						fix  = "reorder pipeline steps: preprocessors first, then models",
					})
					return // one diagnostic per pipeline
				}
			}
		}
	}
}

classify_pipeline_step :: proc(expr: parser.Expr) -> (Step_Kind, string) {
	// Expect a tuple: ("name", EstimatorClass(...))
	#partial switch t in expr {
	case ^parser.Tuple_Expr:
		if len(t.elts) >= 2 {
			return classify_estimator(t.elts[1])
		}
	}
	return .Unknown, ""
}

classify_estimator :: proc(expr: parser.Expr) -> (Step_Kind, string) {
	#partial switch e in expr {
	case ^parser.Call_Expr:
		#partial switch f in e.func {
		case ^parser.Name_Expr:
			for p in KNOWN_TRANSFORMERS {
				if f.id == p { return .Preprocessor, f.id }
			}
			for m in KNOWN_MODELS {
				if f.id == m { return .Model, f.id }
			}
			return .Unknown, f.id
		}
	}
	return .Unknown, ""
}
