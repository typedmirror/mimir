#!/usr/bin/env python3
"""
Token/construct gap analysis: what Python features do failing tests use
that mimir doesn't handle?

Scrapes test Python code for constructs, compares against passing/failing
status, and outputs a ranked "missing feature" list.

Usage:
    python3 tests/scripts/gap_analysis.py [--mypy-dir PATH] [--mimir-bin PATH]
"""

import argparse
import ast
import glob
import json
import os
import re
import sys
from collections import defaultdict, Counter

sys.path.insert(0, os.path.dirname(__file__))
from mypy_test_runner import parse_test_file, evaluate_case


# ============================================================
# Feature extraction from Python AST
# ============================================================

class FeatureExtractor(ast.NodeVisitor):
    """Extract Python language constructs from an AST."""

    def __init__(self):
        self.features = set()

    def visit_FunctionDef(self, node):
        if node.returns:
            self.features.add('return_annotation')
            self._extract_annotation_features(node.returns, 'return')
        for dec in node.decorator_list:
            self._extract_decorator(dec)
        if node.args:
            self._extract_args_features(node.args)
        # Check body patterns
        if len(node.body) == 1:
            stmt = node.body[0]
            if isinstance(stmt, ast.Pass):
                self.features.add('pass_body_stub')
            elif isinstance(stmt, ast.Expr) and isinstance(stmt.value, ast.Constant) and stmt.value.value is ...:
                self.features.add('ellipsis_body_stub')
        self.generic_visit(node)

    def visit_AsyncFunctionDef(self, node):
        self.features.add('async_def')
        self.visit_FunctionDef(node)

    def visit_ClassDef(self, node):
        for base in node.bases:
            self._extract_base_class(base)
        for dec in node.decorator_list:
            self._extract_decorator(dec)
        self.generic_visit(node)

    def visit_AnnAssign(self, node):
        self.features.add('annotated_assign')
        if node.annotation:
            self._extract_annotation_features(node.annotation, 'var')
        self.generic_visit(node)

    def visit_Assert(self, node):
        self.features.add('assert')
        if isinstance(node.test, ast.Constant) and node.test.value is False:
            self.features.add('assert_false')
        if isinstance(node.test, ast.Call):
            if isinstance(node.test.func, ast.Name) and node.test.func.id == 'assert_never':
                self.features.add('assert_never')
        self.generic_visit(node)

    def visit_Match(self, node):
        self.features.add('match_stmt')
        for case in node.cases:
            self._extract_match_pattern(case.pattern)
            if case.guard:
                self.features.add('match_guard')
        self.generic_visit(node)

    def visit_Try(self, node):
        self.features.add('try_except')
        if node.finalbody:
            self.features.add('try_finally')
        self.generic_visit(node)

    def visit_With(self, node):
        self.features.add('with_stmt')
        self.generic_visit(node)

    def visit_Yield(self, node):
        self.features.add('yield')
        self.generic_visit(node)

    def visit_YieldFrom(self, node):
        self.features.add('yield_from')
        self.generic_visit(node)

    def visit_Await(self, node):
        self.features.add('await')
        self.generic_visit(node)

    def visit_Starred(self, node):
        self.features.add('star_unpack')
        self.generic_visit(node)

    def visit_Call(self, node):
        # Track specific typing/builtin calls
        if isinstance(node.func, ast.Name):
            name = node.func.id
            if name in ('reveal_type', 'assert_type'):
                self.features.add(f'call_{name}')
            elif name in ('cast', 'overload', 'type_check_only', 'no_type_check',
                          'dataclass', 'NamedTuple', 'TypedDict', 'NewType',
                          'TypeVar', 'ParamSpec', 'TypeVarTuple'):
                self.features.add(f'call_{name}')
            elif name == 'super':
                self.features.add('super_call')
            elif name == 'isinstance':
                self.features.add('isinstance_call')
            elif name == 'callable':
                self.features.add('callable_guard')
        elif isinstance(node.func, ast.Attribute):
            attr = node.func.attr
            if attr in ('__init__', '__new__', '__call__', '__enter__', '__exit__'):
                self.features.add(f'dunder_call_{attr}')

        # Star args in calls
        for arg in node.args:
            if isinstance(arg, ast.Starred):
                self.features.add('star_args_in_call')
        for kw in node.keywords:
            if kw.arg is None:
                self.features.add('kwargs_unpack_in_call')
        self.generic_visit(node)

    def visit_Subscript(self, node):
        # Track typing subscript patterns: List[X], Optional[X], etc.
        if isinstance(node.value, ast.Name):
            name = node.value.id
            if name in ('List', 'Dict', 'Set', 'Tuple', 'FrozenSet',
                        'Optional', 'Union', 'Callable', 'Type', 'ClassVar',
                        'Final', 'Literal', 'Annotated', 'TypeAlias',
                        'Required', 'NotRequired', 'Unpack', 'TypeGuard', 'TypeIs',
                        'Concatenate', 'Self', 'Never', 'NoReturn',
                        'Generic', 'Protocol', 'TypedDict', 'NamedTuple'):
                self.features.add(f'typing_{name}')
            elif name == 'type':
                self.features.add('type_subscript')
        elif isinstance(node.value, ast.Attribute):
            attr = node.value.attr
            if attr in ('Optional', 'Union', 'List', 'Dict', 'Callable', 'ClassVar', 'Final'):
                self.features.add(f'typing_{attr}')
        self.generic_visit(node)

    def visit_BinOp(self, node):
        if isinstance(node.op, ast.BitOr):
            # Could be union syntax X | Y
            self.features.add('union_or_syntax')
        self.generic_visit(node)

    def visit_NamedExpr(self, node):
        self.features.add('walrus_operator')
        self.generic_visit(node)

    def visit_AugAssign(self, node):
        self.features.add('augmented_assign')
        self.generic_visit(node)

    def visit_Global(self, node):
        self.features.add('global_stmt')
        self.generic_visit(node)

    def visit_Nonlocal(self, node):
        self.features.add('nonlocal_stmt')
        self.generic_visit(node)

    def visit_Delete(self, node):
        self.features.add('del_stmt')
        self.generic_visit(node)

    def visit_Lambda(self, node):
        self.features.add('lambda')
        self.generic_visit(node)

    # --- Helpers ---

    def _extract_decorator(self, dec):
        if isinstance(dec, ast.Name):
            name = dec.id
            self.features.add(f'decorator_{name}')
        elif isinstance(dec, ast.Attribute):
            self.features.add(f'decorator_{dec.attr}')
        elif isinstance(dec, ast.Call):
            if isinstance(dec.func, ast.Name):
                self.features.add(f'decorator_{dec.func.id}_call')
            elif isinstance(dec.func, ast.Attribute):
                self.features.add(f'decorator_{dec.func.attr}_call')
            else:
                self.features.add('decorator_complex')

    def _extract_base_class(self, base):
        if isinstance(base, ast.Name):
            name = base.id
            if name in ('Protocol', 'ABC', 'ABCMeta', 'Generic', 'TypedDict',
                        'NamedTuple', 'Enum', 'IntEnum', 'StrEnum', 'Flag', 'IntFlag'):
                self.features.add(f'base_{name}')
            else:
                self.features.add('base_class')
        elif isinstance(base, ast.Subscript):
            if isinstance(base.value, ast.Name):
                name = base.value.id
                if name == 'Generic':
                    self.features.add('base_Generic_subscript')
                elif name == 'Protocol':
                    self.features.add('base_Protocol_subscript')
                else:
                    self.features.add(f'base_{name}_subscript')
            else:
                self.features.add('base_subscript')
        elif isinstance(base, ast.Call):
            self.features.add('base_metaclass_call')

    def _extract_annotation_features(self, ann, context=''):
        if isinstance(ann, ast.Name):
            name = ann.id
            if name in ('int', 'str', 'float', 'bool', 'bytes', 'None', 'object',
                        'type', 'Any', 'Never', 'NoReturn', 'Self'):
                self.features.add(f'ann_{name}')
        elif isinstance(ann, ast.Subscript):
            if isinstance(ann.value, ast.Name):
                name = ann.value.id
                self.features.add(f'ann_{name}_subscript')
        elif isinstance(ann, ast.Constant):
            if isinstance(ann.value, str):
                self.features.add('forward_ref_annotation')
            elif ann.value is None:
                self.features.add('ann_None')
        elif isinstance(ann, ast.BinOp) and isinstance(ann.op, ast.BitOr):
            self.features.add('ann_union_or')

    def _extract_args_features(self, args):
        if args.posonlyargs:
            self.features.add('posonly_params')
        if args.kwonlyargs:
            self.features.add('kwonly_params')
        if args.vararg:
            self.features.add('vararg_param')
        if args.kwarg:
            self.features.add('kwarg_param')
        for a in (args.posonlyargs + args.args + args.kwonlyargs):
            if a.annotation:
                self.features.add('param_annotation')
                self._extract_annotation_features(a.annotation, 'param')
        if args.defaults:
            self.features.add('param_defaults')
        if args.kw_defaults and any(d is not None for d in args.kw_defaults):
            self.features.add('kwonly_defaults')

    def _extract_match_pattern(self, pattern):
        if isinstance(pattern, ast.MatchAs):
            if pattern.pattern is None:
                self.features.add('match_wildcard')
            else:
                self.features.add('match_as')
        elif isinstance(pattern, ast.MatchOr):
            self.features.add('match_or')
        elif isinstance(pattern, ast.MatchMapping):
            self.features.add('match_mapping')
        elif isinstance(pattern, ast.MatchClass):
            self.features.add('match_class')
        elif isinstance(pattern, ast.MatchSequence):
            self.features.add('match_sequence')
        elif isinstance(pattern, ast.MatchStar):
            self.features.add('match_star')
        elif isinstance(pattern, ast.MatchValue):
            self.features.add('match_value')


def extract_features(code: str) -> set:
    """Extract language features from Python source code."""
    try:
        tree = ast.parse(code)
    except SyntaxError:
        return {'PARSE_ERROR'}

    extractor = FeatureExtractor()
    extractor.visit(tree)

    # Also scan for comment-based features
    for line in code.split('\n'):
        stripped = line.strip()
        if '# type:' in stripped:
            if 'ignore' in stripped.split('# type:')[1]:
                extractor.features.add('type_ignore_comment')
            else:
                extractor.features.add('type_comment')
        if '# type: ignore' in stripped:
            extractor.features.add('type_ignore_comment')

    return extractor.features


# ============================================================
# Gap analysis
# ============================================================

def run_gap_analysis(mypy_dir: str, mimir_bin: str):
    test_dir = os.path.join(mypy_dir, 'test-data', 'unit')
    pattern = os.path.join(test_dir, 'check-*.test')
    test_files = sorted(glob.glob(pattern))

    # Feature → {passing: count, failing: count, d1fp: count, d1fn: count}
    feature_stats = defaultdict(lambda: {'pass': 0, 'fail': 0, 'd1fp': 0, 'd1fn': 0})
    # Feature combinations in d1-FP tests
    d1fp_features = []
    d1fn_features = []

    total_run = 0
    total_pass = 0

    for filepath in test_files:
        cases = parse_test_file(filepath)
        for case in cases:
            if case.skip:
                continue
            total_run += 1
            result = evaluate_case(case, mimir_bin)
            features = extract_features(case.code)

            if result.passed:
                total_pass += 1
                for f in features:
                    feature_stats[f]['pass'] += 1
            else:
                for f in features:
                    feature_stats[f]['fail'] += 1

                # d1-FP
                if len(result.false_negatives) == 0 and len(result.false_positives) == 1:
                    for f in features:
                        feature_stats[f]['d1fp'] += 1
                    d1fp_features.append(features)

                # d1-FN
                if len(result.false_negatives) == 1 and len(result.false_positives) == 0:
                    for f in features:
                        feature_stats[f]['d1fn'] += 1
                    d1fn_features.append(features)

    # Compute "gap score" — features that appear much more in failing than passing
    # gap_score = fail_rate - pass_rate (normalized)
    gap_features = []
    for feat, stats in feature_stats.items():
        total = stats['pass'] + stats['fail']
        if total < 5:
            continue  # skip rare features
        fail_rate = stats['fail'] / total
        pass_rate = stats['pass'] / total
        gap_score = fail_rate - pass_rate  # positive = more in failing
        gap_features.append({
            'feature': feat,
            'pass': stats['pass'],
            'fail': stats['fail'],
            'total': total,
            'fail_rate': fail_rate,
            'd1fp': stats['d1fp'],
            'd1fn': stats['d1fn'],
            'gap_score': gap_score,
        })

    # Sort by gap_score (features most associated with failure)
    gap_features.sort(key=lambda x: -x['gap_score'])

    # Output
    print("=" * 80)
    print(f"FEATURE GAP ANALYSIS — {total_pass}/{total_run} passed ({total_pass/total_run*100:.1f}%)")
    print("=" * 80)

    print(f"\n--- TOP FEATURES ASSOCIATED WITH FAILURE (gap_score = fail_rate - pass_rate) ---")
    print(f"{'Feature':<45} {'Pass':>5} {'Fail':>5} {'Total':>5} {'Fail%':>6} {'d1-FP':>5} {'d1-FN':>5} {'Gap':>6}")
    print("-" * 80)
    for f in gap_features[:40]:
        print(f"{f['feature']:<45} {f['pass']:>5} {f['fail']:>5} {f['total']:>5} "
              f"{f['fail_rate']*100:>5.1f}% {f['d1fp']:>5} {f['d1fn']:>5} {f['gap_score']:>+.3f}")

    # d1-FP exclusive features (features that appear in d1-FP but rarely in passing)
    print(f"\n--- FEATURES CONCENTRATED IN d1-FP TESTS ---")
    d1fp_ranked = sorted(gap_features, key=lambda x: -x['d1fp'])
    print(f"{'Feature':<45} {'d1-FP':>5} {'d1-FN':>5} {'Pass':>5} {'Fail':>5}")
    print("-" * 80)
    for f in d1fp_ranked[:25]:
        if f['d1fp'] > 0:
            print(f"{f['feature']:<45} {f['d1fp']:>5} {f['d1fn']:>5} {f['pass']:>5} {f['fail']:>5}")

    # d1-FN exclusive features
    print(f"\n--- FEATURES CONCENTRATED IN d1-FN TESTS ---")
    d1fn_ranked = sorted(gap_features, key=lambda x: -x['d1fn'])
    print(f"{'Feature':<45} {'d1-FN':>5} {'d1-FP':>5} {'Pass':>5} {'Fail':>5}")
    print("-" * 80)
    for f in d1fn_ranked[:25]:
        if f['d1fn'] > 0:
            print(f"{f['feature']:<45} {f['d1fn']:>5} {f['d1fp']:>5} {f['pass']:>5} {f['fail']:>5}")

    # Save full data
    out_path = os.path.join(os.path.dirname(__file__), 'gap_analysis.json')
    with open(out_path, 'w') as f:
        json.dump({
            'total_run': total_run,
            'total_pass': total_pass,
            'features': gap_features,
        }, f, indent=2)
    print(f"\nFull data saved to {out_path}")


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Feature gap analysis')
    parser.add_argument('--mypy-dir', default='/Users/ivermektin/Desktop/mypy')
    parser.add_argument('--mimir-bin', default='./mimir_bin')
    args = parser.parse_args()

    if not os.path.isdir(args.mypy_dir):
        print(f"Error: mypy directory not found at {args.mypy_dir}")
        sys.exit(1)

    run_gap_analysis(args.mypy_dir, args.mimir_bin)
