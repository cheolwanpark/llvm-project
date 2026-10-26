"""Reproducible query-count and spill audit of the RVV feedback gate.

The oracle uses the same in-process provider with force-all, preserving sibling
loop context. No missing/unavailable observation is treated as spill-free.
"""
import argparse
from collections import Counter
from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib
from importlib.machinery import SourceFileLoader
import json
from pathlib import Path
import subprocess
import types

from feedback_comparison import read_feedback
from model_errors import ToolError
from observations import validate_observation
import vplan_tools as vt

TIMING_PREFIX = 'VPLAN-BACKEND-FEEDBACK-TIMING: '


def spill_counts(observation):
    validate_observation(observation)
    mapped = (not observation.get('error') and observation.get('iteration_mapping')
              and bool(observation.get('body_order')))
    # A short vector loop can disappear completely. In this narrowly identified
    # case, checking the ENTIRE straight-line function is stronger than checking
    # a loop body. Do not apply this fallback to arbitrary mapping errors/CFGs.
    blocks = observation.get('blocks', [])
    eliminated = (observation.get('error') == 'original scalar iteration mapping is unproven'
                  and not observation.get('iteration_mapping')
                  and not observation.get('body_order') and observation.get('header') == -1
                  and len(blocks) == 1 and blocks[0]['successors'] == []
                  and bool(observation.get('instructions')))
    if not mapped and not eliminated:
        raise ToolError('oracle has no mapped body or proven straight-line function')
    scope = 'body' if mapped else 'whole-function-no-loop'
    counts = Counter()
    details = []
    body = set(observation['body_order'])
    for op in observation['instructions']:
        accesses = [m for m in op['memory'] if m.get('spill_slot')]
        if not accesses:
            continue
        if not op.get('registers_complete'):
            raise ToolError('incomplete register operands on spill instruction')
        vector = any(o.get('kind') == 'register' and o.get('group8', 0) > 0
                     for o in op['operands'])
        region = 'body' if op['id'] in body else 'outside'
        kind = 'vector' if vector else 'scalar'
        for m in accesses:
            for direction in ('load', 'store'):
                if m.get(direction):
                    counts[f'{region}_{kind}_{direction}'] += 1
        details.append(dict(id=op['id'], opcode=op['opcode'], mir=op['mir'],
                            region=region, kind=kind, memory=accesses))
    return dict(counts), details, scope


def audit_pair(gated, oracle):
    def index(rows):
        result = {}
        for row in rows:
            key = row['candidate']
            if key in result:
                raise ToolError(f'duplicate candidate: {key}')
            result[key] = row
        return result
    left, right = index(gated), index(oracle)
    if left.keys() != right.keys():
        raise ToolError('gate changed the candidate population')
    counts, reasons, candidates = Counter(), Counter(), []
    for key, row in left.items():
        ref = right[key]
        gate = row['register_usage_bound']
        oracle_gate = ref['register_usage_bound']
        if gate['force_all'] or not oracle_gate['force_all']:
            raise ToolError('incorrect gate/oracle modes')
        if {k: v for k, v in gate.items() if k != 'force_all'} != {
                k: v for k, v in oracle_gate.items() if k != 'force_all'}:
            raise ToolError('gate decision changed in oracle mode')
        if ref['status'] not in ('collected', 'unavailable'):
            raise ToolError('oracle did not query a candidate')
        counts['candidates'] += 1
        counts['baseline_queries'] += 1
        counts['oracle_unavailable'] += ref['status'] == 'unavailable'
        skipped = row['status'] == 'skipped'
        if skipped != gate['would_skip']:
            raise ToolError('query decision disagrees with bound')
        counts['skipped'] += skipped
        counts['gated_queries'] += not skipped
        reasons[gate['reason'] + (':' + gate['recipe'] if 'recipe' in gate else '')] += 1
        record = dict(candidate=key, skipped=skipped, gate=gate,
                      oracle_status=ref['status'])
        candidates.append(record)
        if not skipped:
            if row['status'] != ref['status'] or row.get('observation') != ref.get('observation'):
                raise ToolError('queried candidate changed observation')
            continue
        if not gate['known'] or gate['usage_bound'] >= gate['budget'] or 'observation' in row:
            raise ToolError('invalid skipped candidate')
        if ref['status'] != 'collected':
            record['verification'] = 'unavailable'
            record['error'] = ref.get('reason', 'oracle unavailable')
            counts['skipped_unverified'] += 1
            continue
        try:
            spills, details, scope = spill_counts(ref['observation'])
        except (ToolError, ValueError, KeyError, TypeError) as exc:
            record.update(verification='unavailable', error=str(exc))
            counts['skipped_unverified'] += 1
            continue
        record.update(spills=spills, spill_instructions=details, verification_scope=scope)
        has_vector_spill = bool(spills.get('body_vector_load', 0) or
                                spills.get('body_vector_store', 0))
        if scope == 'whole-function-no-loop':
            has_vector_spill |= bool(spills.get('outside_vector_load', 0) or
                                     spills.get('outside_vector_store', 0))
            counts['skipped_eliminated_loop_verified'] += 1
        record['verification'] = 'vector-spill' if has_vector_spill else 'no-vector-spill'
        counts['skipped_with_vector_spills'] += has_vector_spill
        counts['skipped_verified'] += 1
        counts.update(spills)
    return dict(counts=dict(counts), reasons=dict(reasons), candidates=candidates)


def timings(path):
    return [json.loads(line[len(TIMING_PREFIX):])
            for line in path.read_text().splitlines() if line.startswith(TIMING_PREFIX)]


def validate_benchmark(benchmark, args, resume_flags):
    root = args.output_dir / vt.report_name(benchmark.id)
    root.mkdir()
    commands = []

    def run(name, command):
        commands.append(dict(name=name, command=command))
        vt.write_json(root / 'commands.json', commands)
        with (root / (name + '.stdout')).open('w') as out, \
                (root / (name + '.stderr')).open('w') as err:
            result = subprocess.run(command, stdout=out, stderr=err, timeout=args.timeout)
        if result.returncode:
            raise ToolError(f'{benchmark.id}: {name} failed ({result.returncode}); see {root}')

    source = root / vt.source_name(benchmark)
    source.write_text(benchmark.source)
    flags = vt.benchmark_flags(benchmark)
    checkpoint = root / 'checkpoint.bc'
    run('prepare', [str(args.clang), *flags, '-mllvm', '-vplan-pipeline=prepare',
                    '-emit-llvm', '-c', str(source), '-o', str(root / 'module.bc')])
    run('extract', [str(args.clang.parent / 'llvm-extract'), str(root / 'module.bc'),
                    '--func', 'selected_kernel', '--recursive', '--keep-const-init',
                    '-o', str(checkpoint)])
    common = [str(args.clang), *resume_flags(flags), '-x', 'ir', str(checkpoint),
              '-mllvm', '-vplan-pipeline=resume', '-S']
    run('off', [*common, '-o', str(root / 'off.s')])
    output = dict(benchmark=benchmark.id, modes={})
    modes = (False, True) if args.late_cleanup == 'both' else (args.late_cleanup == 'on',)
    for late in modes:
        late_name = 'late-on' if late else 'late-off'
        for force in (True, False):
            name = late_name + ('-oracle' if force else '-gate')
            run(name, [*common, '-mllvm', '-enable-vplan-backend-feedback',
                       '-mllvm', '-time-vplan-backend-feedback',
                       '-mllvm', f'-vplan-backend-feedback-force-all={str(force).lower()}',
                       '-mllvm', f'-vplan-backend-feedback-late-cleanup={str(late).lower()}',
                       '-mllvm', '-vplan-backend-feedback-output=' + str(root / (name + '.jsonl')),
                       '-o', str(root / (name + '.s'))])
            if (root / (name + '.s')).read_bytes() != (root / 'off.s').read_bytes():
                raise ToolError(f'{benchmark.id}: {name} changed assembly')
        rows = {}
        for name in ('gate', 'oracle'):
            file = root / (late_name + '-' + name + '.jsonl')
            rows[name] = read_feedback(file, allow_empty=True) if file.exists() else []
            called = timings(root / (late_name + '-' + name + '.stderr'))
            expected = {r['candidate'] for r in rows[name] if r['status'] != 'skipped'}
            if len(called) != len(expected) or {t['candidate'] for t in called} != expected:
                raise ToolError('provider call timings do not match query decisions')
        output['modes'][late_name] = audit_pair(rows['gate'], rows['oracle'])
    vt.write_json(root / 'audit.json', output)
    return output


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--clang', type=Path, required=True)
    p.add_argument('--db', type=Path, required=True)
    p.add_argument('--output-dir', type=Path, required=True)
    p.add_argument('--benchmark')
    p.add_argument('--jobs', type=int, default=4)
    p.add_argument('--timeout', type=int, default=180)
    p.add_argument('--late-cleanup', choices=('off', 'on', 'both'), default='both')
    args = p.parse_args()
    args.clang = args.clang.resolve()
    args.db = args.db.resolve()
    args.output_dir = args.output_dir.resolve()
    args.output_dir.mkdir(parents=True, exist_ok=False)
    benchmarks, _ = vt.load_database(args.db, args.benchmark)
    if not benchmarks:
        raise ToolError('empty benchmark population')
    path = vt.DEFAULT_LLVM / 'utils/vplan-meta-compile'
    driver = types.ModuleType('vplan_gate_driver')
    driver.__file__ = str(path)
    SourceFileLoader(driver.__name__, str(path)).exec_module(driver)
    report = dict(db=str(args.db), db_sha256=hashlib.sha256(args.db.read_bytes()).hexdigest(),
                  compiler=str(args.clang), compiler_sha256=hashlib.sha256(args.clang.read_bytes()).hexdigest(),
                  benchmarks=len(benchmarks), completed=0, errors=[], modes={})
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        work = {pool.submit(validate_benchmark, b, args, driver.resume_flags): b.id for b in benchmarks}
        for task in as_completed(work):
            try:
                result = task.result()
                for mode, audit in result['modes'].items():
                    total = report['modes'].setdefault(mode, dict(counts={}, reasons={}))
                    for section in ('counts', 'reasons'):
                        c = Counter(total[section])
                        c.update(audit[section])
                        total[section] = dict(c)
                report['completed'] += 1
            except Exception as exc:
                report['errors'].append(dict(benchmark=work[task], error=str(exc)))
            vt.write_json(args.output_dir / 'summary.json', report)
            print(f"{report['completed']}/{len(benchmarks)} completed; errors={len(report['errors'])}", flush=True)
    for mode in report['modes'].values():
        c = mode['counts']
        mode['query_reduction_percent'] = 100 * c.get('skipped', 0) / max(1, c.get('baseline_queries', 0))
    report['passed'] = (not report['errors'] and bool(report['modes']) and
                        all(m['counts'].get('skipped_verified', 0) > 0 and
                            not m['counts'].get('skipped_with_vector_spills', 0) and
                            not m['counts'].get('skipped_unverified', 0)
                            for m in report['modes'].values()))
    vt.write_json(args.output_dir / 'summary.json', report)
    print(json.dumps(report, indent=2))
    return 0 if report['passed'] else 1
