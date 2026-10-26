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


def audit_pair(gated, oracle, *, fallback_loops=None):
    def index(rows):
        result = {}
        for row in rows:
            key = row['candidate']
            if key in result:
                raise ToolError(f'duplicate candidate: {key}')
            result[key] = row
        return result
    left, right = index(gated), index(oracle)
    missing = left.keys() ^ right.keys()
    if missing and (fallback_loops is None or any(
            ((left.get(k) or right[k])['function'], (left.get(k) or right[k])['loop'])
            not in fallback_loops for k in missing)):
        raise ToolError('gate changed the candidate population')
    counts, reasons, candidates = Counter(), Counter(), []
    for key in sorted(missing):
        row = left.get(key) or right[key]
        counts['not_evaluated_after_loop_fallback'] += 1
        candidates.append(dict(candidate=key, verification='loop-fallback-not-evaluated',
                               missing='oracle' if key in left else 'gate'))
    for key, row in left.items():
        if key not in right:
            continue
        ref = right[key]
        gate = row['register_usage_bound']
        oracle_gate = ref['register_usage_bound']
        if gate['force_all'] or not oracle_gate['force_all']:
            raise ToolError('incorrect gate/oracle modes')
        if {k: v for k, v in gate.items() if k not in ('force_all', 'queried')} != {
                k: v for k, v in oracle_gate.items() if k not in ('force_all', 'queried')}:
            raise ToolError('gate decision changed in oracle mode')
        if ref['status'] not in ('collected', 'unavailable'):
            raise ToolError('oracle did not query a candidate')
        counts['candidates'] += 1
        counts['baseline_queries'] += 1
        counts['oracle_unavailable'] += ref['status'] == 'unavailable'
        counts['cost_failures'] += bool(row.get('cost_failure') or ref.get('cost_failure'))
        skipped = row['status'] == 'skipped'
        if skipped != gate['would_skip']:
            raise ToolError('query decision disagrees with bound')
        counts['skipped'] += skipped
        counts['gated_queries'] += not skipped
        reasons[gate['reason'] + (':' + gate['recipe'] if 'recipe' in gate else '')] += 1
        if 'body_quarters_numerator' in row and 'body_quarters_numerator' in ref:
            from fractions import Fraction
            if Fraction(row['body_quarters_numerator'], row['body_quarters_denominator']) != Fraction(ref['body_quarters_numerator'], ref['body_quarters_denominator']):
                raise ToolError('gate changed the exact candidate cost')
            counts['costs_equal'] += 1
        if 'usage_before_ic' in gate and gate['usage_bound'] != gate['usage_before_ic'] * row['ic']:
            raise ToolError('gate does not include candidate IC')
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
              '-mllvm', '-vplan-pipeline=resume', '-mllvm', '-print-vplans', '-S']
    run('off', [*common, '-o', str(root / 'off.s')])
    output = dict(benchmark=benchmark.id, modes={})
    modes = (False, True) if args.late_cleanup == 'both' else (args.late_cleanup == 'on',)
    for late in modes:
        late_name = 'late-on' if late else 'late-off'
        for force in (True, False):
            name = late_name + ('-oracle' if force else '-gate')
            run(name, [*common, '-mllvm', '-enable-vplan-backend-cost-model',
                       '-mllvm', '-time-vplan-backend-feedback',
                       '-mllvm', f'-vplan-backend-feedback-force-all={str(force).lower()}',
                       '-mllvm', f'-vplan-backend-feedback-late-cleanup={str(late).lower()}',
                       '-mllvm', '-vplan-backend-feedback-output=' + str(root / (name + '.jsonl')),
                       '-o', str(root / (name + '.s'))])

        rows = {}
        for name in ('gate', 'oracle'):
            file = root / (late_name + '-' + name + '.jsonl')
            rows[name] = read_feedback(file, allow_empty=True) if file.exists() else []
            called = timings(root / (late_name + '-' + name + '.stderr'))
            expected = {r['candidate'] for r in rows[name] if r['status'] != 'skipped'}
            if len(called) != len(expected) or {t['candidate'] for t in called} != expected:
                raise ToolError('provider call timings do not match query decisions')
        decisions = {}
        for mode in ('gate', 'oracle'):
            path = root / (late_name + '-' + mode + '.jsonl')
            records = [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
            decisions[mode] = [r for r in records if r.get('status') in ('selected', 'native-fallback')]
        fallback_loops = {(r['function'], r['loop']) for ds in decisions.values() for r in ds
                          if r['status'] == 'native-fallback'}
        audit = audit_pair(rows['gate'], rows['oracle'], fallback_loops=fallback_loops)
        audit['native_assembly_changed'] = (root / (late_name + '-gate.s')).read_bytes() != (root / 'off.s').read_bytes()
        audit['gate_oracle_assembly_equal'] = (root / (late_name + '-gate.s')).read_bytes() == (root / (late_name + '-oracle.s')).read_bytes()
        audit['decisions'] = decisions
        # Preserve the selected final IR as well as its assembled object. Use a
        # separate diagnostics stream so verification cannot append candidates
        # to the measured compilation's population.
        ir_name = late_name + '-gate-ir'
        ir_command = next(c['command'] for c in commands if c['name'] == late_name + '-gate').copy()
        ir_command[ir_command.index('-o') + 1] = str(root / (ir_name + '.ll'))
        ir_command = [('-vplan-backend-feedback-output=' + str(root / (ir_name + '.jsonl')))
                      if a.startswith('-vplan-backend-feedback-output=') else a for a in ir_command]
        run(ir_name, [*ir_command, '-emit-llvm'])
        run(ir_name + '-verify', [str(args.clang.parent / 'opt'), '-passes=verify',
                                  '-disable-output', str(root / (ir_name + '.ll'))])
        from llvm_baseline import report_sections
        audit['final_vf_ic'] = {}
        for mode in ('off', 'gate', 'oracle', 'ir'):
            name = 'off' if mode == 'off' else ir_name if mode == 'ir' else late_name + '-' + mode
            final = []
            for header, lines in report_sections((root / (name + '.stderr')).read_text()):
                main = next((vt.fields(line) for line in lines if line.startswith('  selected-for-main ')), {})
                # Clone materialization bypasses selection. Its remarks and
                # reports must not be counted as original output decisions.
                if main.get('vf') in (None, 'not-evaluated'):
                    continue
                epi = next(vt.fields(line) for line in lines if line.startswith('  selected-for-epilogue '))
                ic = next(vt.fields(line)['selected_interleave_count'] for line in lines if line.startswith('  selected_interleave_count='))
                outcome = next(vt.fields(line)['outcome'] for line in lines if line.startswith('  outcome='))
                final.append(dict(loop=int(header['loop']), vf=main['vf'], ic=ic,
                                  epilogue=epi['vf'], outcome=outcome))
            audit['final_vf_ic'][mode] = final
        audit['gate_oracle_selection_equal'] = audit['final_vf_ic']['gate'] == audit['final_vf_ic']['oracle']
        audit['native_selection_changed'] = audit['final_vf_ic']['gate'] != audit['final_vf_ic']['off']
        run(late_name + '-object', [str(args.clang), *resume_flags(flags), '-x', 'assembler',
            '-c', str(root / (late_name + '-gate.s')), '-o', str(root / (late_name + '-gate.o'))])
        counts = audit['counts']
        counts['native_vf_ic_changes'] = int(audit['native_selection_changed'])
        counts['gate_oracle_selection_mismatches'] = int(not audit['gate_oracle_selection_equal'])
        counts['gate_oracle_assembly_mismatches'] = int(not audit['gate_oracle_assembly_equal'])
        counts['objects_generated'] = 1
        counts['final_ir_verified'] = 1
        counts['ir_assembly_selection_mismatches'] = int(audit['final_vf_ic']['gate'] != audit['final_vf_ic']['ir'])
        for mode in ('gate', 'oracle'):
            counts[mode + '_candidates'] = len(rows[mode])
            counts[mode + '_provider_calls'] = sum(r['status'] != 'skipped' for r in rows[mode])
            counts[mode + '_cost_successes'] = sum('body_quarters_numerator' in r for r in rows[mode])
            counts[mode + '_applied_loops'] = sum(r['status'] == 'selected' for r in decisions[mode])
            counts[mode + '_fallback_loops'] = sum(r['status'] == 'native-fallback' for r in decisions[mode])
            for r in decisions[mode]:
                if r['status'] == 'native-fallback':
                    key = mode + ':fallback:' + r['reason']
                    audit['reasons'][key] = audit['reasons'].get(key, 0) + 1
        output['modes'][late_name] = audit
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
        mode['query_reduction_percent'] = 100 * (1 - c.get('gate_provider_calls', 0) / max(1, c.get('oracle_provider_calls', 0)))
    report['passed'] = (not report['errors'] and bool(report['modes']) and
                        all(m['counts'].get('skipped_verified', 0) > 0 and
                            not m['counts'].get('skipped_with_vector_spills', 0) and
                            not m['counts'].get('skipped_unverified', 0) and
                            not m['counts'].get('gate_oracle_selection_mismatches', 0) and
                            not m['counts'].get('gate_oracle_assembly_mismatches', 0) and
                            not m['counts'].get('ir_assembly_selection_mismatches', 0)
                            for m in report['modes'].values()))
    vt.write_json(args.output_dir / 'summary.json', report)
    print(json.dumps(report, indent=2))
    return 0 if report['passed'] else 1
