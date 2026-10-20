"""Score LLVM's ordinary vectorizer choices, including final emission checks."""
from types import SimpleNamespace
import os
import re
import subprocess
import sys
import time

import vplan_tools as vt
from selection_evaluation import summarize_rows


def report_sections(text):
    from vplan_report import parse_reports
    return [r for r in parse_reports(text)['reports']
            if r['header']['function'] == 'selected_kernel']


def selection_row(benchmark, result):
    row = dict(id=benchmark.id, split=benchmark.kind, eligible=False,
               compile_failed=bool(result.returncode), status='compile-failed',
               reason=None, actual_selection=None, selected_vf=None,
               measured_cycles={str(v): c for v, c in benchmark.measured.items()},
               ignored_measured_cycles={}, evaluated_vfs=[],
               top1_correct=None, top1_regret=None)
    if result.returncode:
        row['reason'] = result.stderr[-3000:]
        return row
    try:
        sections = report_sections(result.stderr)
        if len(sections) != 1:
            row.update(status='ambiguous-loops' if sections else 'no-report',
                       reason=f'expected one selected_kernel report, found {len(sections)}')
            return row
        report = sections[0]
        header = report['header']
        singletons = report['singletons']
        choice = singletons['selected-for-main']['fields']
        epilogue = singletons['selected-for-epilogue']['fields']
        outcome = singletons['outcome']['fields']['outcome']
        vf = choice.get('vf')
        ic = singletons['selected_interleave_count']['fields']['selected_interleave_count']
        if vf != 'not-evaluated' and not re.fullmatch(r'[fs][1-9][0-9]*', vf or ''):
            raise vt.ReportError('invalid selected VF')
        if outcome not in ('vectorization-emitted', 'vectorization-rejected', 'no-plan'):
            raise vt.ReportError('unknown transformation outcome')
        candidates = {int(n['fields']['vf'][1:]) for n in report['candidates']
                      if n['fields']['phase'] == 'main' and n['fields']['vf'].startswith('s')}
        if vf and vf.startswith('s'):
            candidates.add(int(vf[1:]))
        row['evaluated_vfs'] = sorted(candidates)
        row['actual_selection'] = dict(function=header['function'], loop=int(header['loop']),
            main_vf=vf, plan=choice.get('plan'), ic=int(ic) if ic.isdigit() else None,
            epilogue_vf=epilogue.get('vf'), outcome=outcome,
            emitted=outcome == 'vectorization-emitted')
        try:
            benchmark = vt.restrict_measurements(benchmark, candidates)
        except vt.ToolError as exc:
            row.update(status='missing-measurements', reason=str(exc))
            return row
        row['measured_cycles'] = {str(v): c for v, c in benchmark.measured.items()}
        row['ignored_measured_cycles'] = {str(v): c for v, c in benchmark.ignored_measured.items()}
        if outcome != 'vectorization-emitted':
            row.update(status='not-vectorized', reason=outcome)
        elif vf == 'f1':
            row.update(status='scalar-selection', reason='selected scalar f1')
        elif vf is None or vf == 'not-evaluated':
            raise vt.ReportError('emitted transformation has no selected VF')
        elif vf.startswith('f'):
            row.update(status='unmeasured-vf', reason=f'no measurement for {vf}')
        elif ic != '1' or epilogue.get('vf') not in ('not-evaluated', 'f0'):
            row.update(status='measurement-context-mismatch', reason='measurements require IC=1 and no vector epilogue')
        elif len(benchmark.measured) < 2:
            row.update(status='insufficient-measurements', reason='fewer than two compiler scalable VFs')
        else:
            selected = int(vf[1:])
            winner = min(benchmark.measured, key=lambda v: (benchmark.measured[v], v))
            row.update(status='scored', eligible=True, selected_vf=selected,
                       top1_correct=selected == winner,
                       top1_regret=benchmark.measured[selected] / benchmark.measured[winner] - 1)
    except (vt.ToolError, KeyError, ValueError) as exc:
        row.update(status='invalid-report', compile_failed=True, failure_kind='report-parse', reason=str(exc))
    return row


def print_summary(rows, elapsed):
    summary = summarize_rows(rows)
    percentage = lambda value: f'{value:.2%}' if value is not None else 'N/A'
    print('\nLLVM baseline')
    print(f"  total={summary['total']} scored={summary['scored']} excluded={summary['excluded']} "
          f"compile_failed={summary['compile_failed']}")
    print(f"  Coverage              {percentage(summary['coverage'])}")
    correct = sum(bool(r['top1_correct']) for r in rows)
    print(f"  Top-1 exact           {percentage(summary['top1']['exact'])} ({correct}/{summary['scored']})")
    for label in ('mean', 'median', 'p95'):
        print(f"  Top-1 regret {label:<8} {percentage(summary['top1_regret'][label])}")
    for status, count in sorted(summary['statuses'].items()):
        if status != 'scored':
            print(f'  Excluded: {status}: {count}')
    print(f'  Evaluation time       {elapsed:.2f}s (existing compiler; excludes build)')
    print('Highest selection regrets:')
    for row in sorted((r for r in rows if r['eligible']),
                      key=lambda r: (-r['top1_regret'], r['id']))[:10]:
        print(f"  {row['id']}: s{row['selected_vf']} {row['top1_regret']:.3%}")
    return summary


def main(argv=None):
    parser = vt.argument_parser('Evaluate actual LLVM middle-end VF selections on all benchmark IDs, including TSVC.')
    parser.set_defaults(compiler_mode='direct')
    parser.add_argument('--benchmark', help='diagnose one exact ID instead of the full CV population')
    parser.add_argument('--skip-build', action='store_true', help='use existing compiler binaries without running CMake/Ninja')
    args = parser.parse_args(argv)
    if args.compiler_mode != 'direct':
        parser.error('LLVM baseline requires --compiler-mode direct')
    benchmarks, metadata = vt.load_database(args.db, benchmark_id=args.benchmark)
    if not benchmarks:
        raise vt.ToolError(f'unknown benchmark: {args.benchmark}' if args.benchmark else 'database contains no benchmarks')
    if args.skip_build:
        clang = (args.build_dir or args.llvm_path / 'build-vplan-tools') / 'bin/clang'
        if not all(p.is_file() and os.access(p, os.X_OK) for p in (clang, clang.parent / 'llvm-extract')):
            raise vt.ToolError('existing clang/llvm-extract binaries are missing or not executable')
    else:
        clang = vt.ensure_compiler(args.llvm_path, args.build_dir, args.jobs)
    version = subprocess.run([str(clang), '--version'], capture_output=True, text=True, check=True).stdout
    print(f'Database: {args.db}')
    print(f'Compiler: {clang}')
    print(version.splitlines()[0])
    print(f"Measured target: {metadata['target']}")
    print('Actual LLVM selections; compiler scalable VF set; extra DB VFs ignored.', flush=True)
    started = time.perf_counter()
    rows = []
    for index, benchmark in enumerate(benchmarks, 1):
        print(f'[{index}/{len(benchmarks)}] {benchmark.id}', file=sys.stderr, flush=True)
        try:
            result = vt.compile_report(clang, benchmark, False, args.timeout, compiler_mode='direct',
                meta_script=args.llvm_path / 'utils/vplan-meta-compile')
        except (vt.ToolError, OSError) as exc:
            result = SimpleNamespace(returncode=1, stderr=str(exc))
        row = selection_row(benchmark, result)
        rows.append(row)
        if not row['eligible']:
            print(f"  {row['status']}: {row['reason']}", file=sys.stderr, flush=True)
    summary = print_summary(rows, time.perf_counter() - started)
    return 0 if summary['scored'] and not summary['compile_failed'] else 1
