package orchestrator

// Unified pass orchestration (T4, R5) — the 8 diagnostic-producing analyses
// behind one `run` entrypoint. Coverage is per-command via Pass_Set;
// resolution is per-command via Resolution_Policy. Bind always runs
// (prerequisite); Flow is derived (auto-enabled iff Check or Security is
// selected — the only passes that consume flow_result).

import core    "mimir:core"
import parser  "mimir:parser"
import binder  "mimir:binder"
import checker "mimir:checker"
import modules "mimir:modules"
import lintpkg "mimir:lint"     // aliased: frees `lint` as the pass-proc name (Odin: a proc may not shadow an import name)
import secpkg  "mimir:security" // aliased: frees `security` as the pass-proc name
import perfpkg "mimir:perf"     // aliased: frees `perf` as the pass-proc name
import safepkg "mimir:safety"   // aliased: frees `safety` as the pass-proc name
import gpupkg  "mimir:gpu"      // aliased: frees `gpu` as the pass-proc name. Legal direction:
                                 // orchestrator→gpu (DAG); the reverse (checker→gpu) is a cycle
                                 // and is banned (S wave D1 ruling) — this file never imports checker
                                 // FROM gpu, only calls gpu's existing public API one-way.

// Bind is implicit; Flow is derived from the set.
Pass :: enum { Check, Concurrency, Lint, Security, Perf, Safety, GPU }
Pass_Set :: bit_set[Pass]

// What reaches check_scope as import types (R5 policy matrix; preserving
// each command's CURRENT policy is the behavior-preserving contract —
// harmonizing policies is explicitly out of T4 scope):
//   Virtual_Only — plain single-file checker: private registry, virtual
//                  imports only, no B003. (conform, lsp)
//   Full_Single  — private registry + sibling/stdlib/cache/site-packages
//                  resolution, B003 on failures. (check single-file)
//   Full_Multi   — caller-shared registry + modules.resolve_imports output.
//                  (check multi-file; wired at step G)
Resolution_Policy :: enum { Virtual_Only, Full_Single, Full_Multi }

Run_Config :: struct {
	passes:          Pass_Set,
	resolution:      Resolution_Policy,
	bridge:          ^parser.Bridge,  // Full_Single: third-party stub parsing (tree adaptation — graph check gained this param in Phase T)
	lint_config:     lintpkg.Lint_Config,
	security_config: secpkg.Security_Config,
	perf_config:     perfpkg.Perf_Config,
	safety_config:   safepkg.Safety_Config,
	gpu_config:      gpupkg.GPU_Config,
	// Full_Multi only (step G). All five are shared, caller-owned multi-
	// module state — the graph never takes ownership. (shared_builtins,
	// virtual_registry, module_info are tree adaptations beyond R5's sketch:
	// resolve_imports/collect_exports need the per-module identity and the
	// cross-module virtual registry; the checker needs builtins with the
	// shared registry.)
	shared_registry:  ^checker.Type_Registry,
	shared_builtins:  ^checker.Builtin_Names,
	resolution_ctx:   ^modules.Resolution_Context,
	virtual_registry: ^checker.Virtual_Registry,
	module_info:      ^modules.Module_Info,
}

// Dispatch the selected passes in fixed order. Each pass records its raw
// per-pass diagnostics on the graph AND emits into the central deduped list.
run :: proc(g: ^Analysis_Graph, cfg: Run_Config) {
	cfg := cfg // local copy — Odin proc params are immutable (need &cfg.*_config below)

	bind(g)

	// Flow: auto-enabled iff a selected pass consumes flow_result.
	if .Check in cfg.passes || .Security in cfg.passes {
		flow(g)
	}

	if .Check in cfg.passes {
		switch cfg.resolution {
		case .Virtual_Only:
			check_virtual_only(g)
		case .Full_Single:
			check(g, cfg.bridge)
		case .Full_Multi:
			check_full_multi(g, &cfg)
		}
	}

	if .Concurrency in cfg.passes { concurrency(g) }
	if .Lint in cfg.passes { lint(g, &cfg.lint_config) }
	if .Security in cfg.passes { security(g, &cfg.security_config) }
	if .Perf in cfg.passes { perf(g, &cfg.perf_config) }
	if .Safety in cfg.passes { safety(g, &cfg.safety_config) }
	if .GPU in cfg.passes { gpu(g, &cfg.gpu_config) }
}

// Virtual_Only check: the plain single-file checker — private registry,
// virtual imports only, no sibling/stdlib/cache/site-packages resolution,
// no B003 emission. Byte-preserves the conform/LSP checker behavior.
check_virtual_only :: proc(g: ^Analysis_Graph) {
	if g.checked { return }
	if !g.flowed { flow(g) }

	g.check_result = checker.check(
		g.module, &g.bind_result, &g.flow_result, g.file_path, g.allocator,
	)

	// Emit flow diagnostics (after checker — checker may suppress F002)
	for d in g.flow_result.diagnostics {
		emit(g, d)
	}

	// Emit checker diagnostics
	for d in g.check_result.diagnostics {
		emit(g, d)
	}

	g.checked = true
}

// Full_Multi check: shared registry + modules.resolve_imports through the
// caller's Resolution_Context (topo order, cross-module exports). Preserves
// the pre-T4 inline multi-file semantics exactly, including one deliberate
// divergence from the single-file arms: flow diagnostics are emitted BEFORE
// the checker runs — the inline path printed them pre-checker, so F002
// Never-suppression (which mutates flow_result in place) never applied to
// multi-file output. Harmonizing that is a behavior change (post-T4).
check_full_multi :: proc(g: ^Analysis_Graph, cfg: ^Run_Config) {
	if g.checked { return }
	if !g.flowed { flow(g) }

	// Resolve imports via the shared multi-module context. Unresolved
	// imports surface as B003 warnings — never silent.
	unresolved := make([dynamic]binder.Import_Record, 0, 4, g.allocator)
	import_types := modules.resolve_imports(cfg.module_info, cfg.resolution_ctx, cfg.virtual_registry, &unresolved)
	for imp in unresolved {
		g.unresolved_import_count += 1
		emit(g, make_unresolved_import_diag(imp, g.file_path, g.allocator))
	}

	// Flow diagnostics BEFORE the checker (see header comment).
	for d in g.flow_result.diagnostics {
		emit(g, d)
	}

	r := checker.Import_Resolution{
		registry     = cfg.shared_registry,
		builtins     = cfg.shared_builtins,
		import_types = import_types,
	}
	g.check_result = checker.check(
		g.module, &g.bind_result, &g.flow_result, g.file_path,
		g.allocator, &r,
	)

	// Emit checker diagnostics
	for d in g.check_result.diagnostics {
		emit(g, d)
	}

	// Publish this module's exports for downstream modules (topo order).
	modules.collect_exports(cfg.module_info, &g.check_result, cfg.resolution_ctx)

	g.checked = true
}

// Lint pass.
lint :: proc(g: ^Analysis_Graph, config: ^lintpkg.Lint_Config) {
	if !g.bound { bind(g) }
	diags := lintpkg.lint_file(g.module, &g.bind_result, g.source, g.file_path, config, g.allocator)
	g.lint_diags = diags
	for d in diags { emit(g, d) }
}

// Security pass (bundles taint — scanner calls taint build/analyze itself).
security :: proc(g: ^Analysis_Graph, config: ^secpkg.Security_Config) {
	if !g.bound { bind(g) }
	// flow_result is optional for scan_file; run() guarantees it when this
	// pass is selected. Guard anyway so direct callers cannot hand the
	// scanner a zero-value Flow_Result.
	flow_ptr := &g.flow_result if g.flowed else nil
	diags := secpkg.scan_file(g.module, &g.bind_result, g.source, g.file_path, config, g.allocator, flow_ptr)
	g.sec_diags = diags
	for d in diags { emit(g, d) }
}

// Performance pass.
perf :: proc(g: ^Analysis_Graph, config: ^perfpkg.Perf_Config) {
	if !g.bound { bind(g) }
	diags := perfpkg.analyze_performance(g.module, &g.bind_result, g.source, g.file_path, config, g.allocator)
	g.perf_diags = diags
	for d in diags { emit(g, d) }
}

// Safety pass.
safety :: proc(g: ^Analysis_Graph, config: ^safepkg.Safety_Config) {
	if !g.bound { bind(g) }
	diags := safepkg.analyze_safety(g.module, &g.bind_result, g.file_path, config, g.allocator)
	g.safety_diags = diags
	for d in diags { emit(g, d) }
}

// GPU pass: @gpu subset validation (GPU001-010, restrictions.odin) always
// runs — find_gpu_functions is internal to validate_file and is a fast
// no-op on files with no @gpu functions. Graph-level checks (GPU011 shape
// mismatch via extract_graph; GPU012/013 multi-device via analyze_multigpu)
// are gated BY CONSTRUCTION on validate_file's own gpu_funcs result being
// non-empty: analyze_multigpu scans ALL functions, not just @gpu ones, so
// calling it unconditionally would risk new diagnostics on ordinary
// non-@gpu code. Gating at this call site keeps the regression surface on
// non-@gpu files at zero (S-wave lead ruling, checkpoint 1 amendment).
gpu :: proc(g: ^Analysis_Graph, config: ^gpupkg.GPU_Config) {
	if !g.bound { bind(g) }

	// Fresh, throwaway registry + type context per file — mirrors cmd_gpu's
	// own mini-pipeline (main.odin) exactly. Never shares the Check pass's
	// registry: GPU_Type_Context resolves Tensor[...] annotations
	// syntactically (literal identifier match against gpu_names), independent
	// of the main checker's symbol/import resolution — so this pass is
	// unaffected by whatever the Check pass does or does not resolve.
	reg := checker.init_registry(g.allocator)
	type_ctx := gpupkg.init_gpu_types(&reg, g.allocator)

	diags := make([dynamic]core.Diagnostic, 0, 8, g.allocator)

	restriction_diags, gpu_funcs := gpupkg.validate_file(
		g.module, &g.bind_result, &type_ctx, g.file_path, config, g.allocator,
	)
	for d in restriction_diags { append(&diags, d) }

	// Graph-level checks — gated on ≥1 discovered @gpu function (see header).
	if len(gpu_funcs) > 0 {
		multigpu_diags := make([dynamic]core.Diagnostic, 0, 4, g.allocator)
		gpupkg.analyze_multigpu(g.module, &g.bind_result, g.file_path, &multigpu_diags, g.allocator)
		for d in multigpu_diags { append(&diags, d) }

		for func in gpu_funcs {
			_, graph_diags := gpupkg.extract_graph(func, &g.bind_result, &type_ctx, g.file_path, g.allocator)
			for d in graph_diags { append(&diags, d) }
		}
	}

	g.gpu_diags = diags[:]
	for d in diags { emit(g, d) }
}
