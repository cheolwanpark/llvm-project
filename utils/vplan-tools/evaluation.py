"""Benchmark population, rankings, selection regret and comparable cohorts."""
from collections import Counter
import statistics
import vplan_tools as vt
from cost_model import score_value, Settings


def excluded(benchmark, reason, status='unsupported', coverage=None):
    return dict(id=benchmark.id, source_split=benchmark.kind, eligible=False, status=status, reason=reason,
                compile_failed=status == 'compile-failed', evaluated_vfs=[], selected_vf=None,
                scores={}, measured_cycles={str(v): c for v, c in benchmark.measured.items()},
                ignored_measured_cycles={}, top1_correct=None, top1_regret=None,
                spearman=None, top2_overlap=None, replay_verified=False, candidate_coverage=coverage or [])


def evaluate(example, settings=Settings()):
    benchmark = example['benchmark']
    if example['reason']: return excluded(benchmark, example['reason'], coverage=example['coverage'])
    scores = {vf: min(score_value(r['features'], settings) for r in reports) for vf, reports in example['candidates'].items()}
    selected = min(scores, key=lambda vf: (scores[vf], vf))
    measured = benchmark.measured
    oracle = min(measured, key=lambda vf: (measured[vf], vf))
    vfs = sorted(scores)
    pred_top = sorted(vfs, key=lambda v: (scores[v], v))[:2]
    true_top = sorted(vfs, key=lambda v: (measured[v], v))[:2]
    return dict(id=benchmark.id, source_split=benchmark.kind, eligible=True, status='scored', reason=None,
                compile_failed=False, evaluated_vfs=vfs, selected_vf=selected,
                scores={str(v): float(c) for v, c in scores.items()},
                exact_scores={str(v): str(c) for v, c in scores.items()},
                measured_cycles={str(v): c for v, c in measured.items()},
                ignored_measured_cycles={str(v): c for v, c in benchmark.ignored_measured.items()},
                top1_correct=selected == oracle, top1_regret=measured[selected] / measured[oracle] - 1,
                spearman=vt.spearman([scores[v] for v in vfs], [measured[v] for v in vfs]),
                top2_overlap=len(set(pred_top) & set(true_top)) / 2, replay_verified=False,
                candidate_coverage=example['coverage'])


def summarize_rows(rows):
    eligible = [r for r in rows if r['eligible']]
    regrets = [r['top1_regret'] for r in eligible]
    spearman = [r['spearman'] for r in eligible if r.get('spearman') is not None]
    return dict(total=len(rows), scored=len(eligible), excluded=len(rows) - len(eligible),
                coverage=len(eligible) / len(rows) if rows else 0.,
                compile_failed=sum(r.get('compile_failed', False) for r in rows),
                statuses=dict(Counter(r['status'] for r in rows)),
                top1=dict(exact=statistics.mean(r['top1_correct'] for r in eligible) if eligible else None,
                          correct=sum(r['top1_correct'] for r in eligible), total=len(eligible)),
                top1_regret=dict(mean=statistics.mean(regrets) if regrets else None,
                                 median=statistics.median(regrets) if regrets else None,
                                 p95=vt.percentile(regrets, .95) if regrets else None,
                                 worst=max(regrets) if regrets else None),
                spearman=dict(n=len(spearman), mean=statistics.mean(spearman) if spearman else None),
                replay_verified=sum(r.get('replay_verified', False) for r in rows),
                worst_cases=[dict(id=r['id'], selected_vf=r['selected_vf'],
                                  oracle_vf=min((int(v) for v in r['measured_cycles']),
                                                key=lambda v: (r['measured_cycles'][str(v)], v)),
                                  regret=r['top1_regret'])
                             for r in sorted(eligible, key=lambda r: (-r['top1_regret'], r['id']))[:10]])


def compare(model_rows, baseline_rows):
    if {r['id'] for r in model_rows} != {r['id'] for r in baseline_rows}:
        raise vt.ToolError('model and LLVM baseline attempted populations differ')
    baseline = {r['id']: r for r in baseline_rows}
    same = [r['id'] for r in model_rows if r['eligible'] and baseline[r['id']]['eligible']
            and r['evaluated_vfs'] == baseline[r['id']]['evaluated_vfs']]
    model = {r['id']: r for r in model_rows}
    return dict(attempted=len(model), matched_population=same,
                model=summarize_rows([model[id_] for id_ in same]),
                baseline=summarize_rows([baseline[id_] for id_ in same]),
                unmatched=[r['id'] for r in model_rows if r['id'] not in same],
                mean_regret_difference=statistics.mean(model[id_]['top1_regret'] - baseline[id_]['top1_regret'] for id_ in same) if same else None)


def dataset_fingerprint(benchmarks, metadata):
    from cost_model import digest_json
    return digest_json(dict(metadata=metadata, benchmarks=[dict(id=b.id, source=b.source, flags=b.compile_args,
                         workload=b.workload, measurements=b.measured) for b in sorted(benchmarks, key=lambda b: b.id)]))


def replay(benchmark, example, row, clang, args, directory, settings=Settings()):
    result = vt.compile_report(clang, benchmark, False, args.timeout,
                               meta_script=args.llvm_path / 'utils/vplan-meta-compile', artifacts_dir=directory, settings=settings)
    if result.returncode: raise vt.ToolError(result.stderr[-3000:])
    selections = [s for s in result.final_manifest['selections'] if s['function'] == 'selected_kernel']
    if len(selections) != 1 or selections[0]['scalar']:
        raise vt.ToolError('replay did not emit the selected scalable candidate')
    expected = min(example['candidates'][row['selected_vf']],
                   key=lambda r: (score_value(r['features'], settings), r['candidate']))['candidate']
    if selections[0]['id'] != expected:
        raise vt.ToolError('final replay selection differs from the ranked choice')
    from cost_model import identity
    if result.candidate_status['policy'] != identity(settings):
        raise vt.ToolError('model changed between ranking and replay')
    row.update(replay_verified=True, final_selection=selections[0], replay_artifacts=str(result.artifact_root))


def print_metrics(label, metrics):
    percentage = lambda value: f'{value:.3%}' if value is not None else 'N/A'
    print(f"{label}: {metrics['scored']}/{metrics['total']} scored; "
          f"mean regret {percentage(metrics['top1_regret']['mean'])}; "
          f"accuracy {percentage(metrics['top1']['exact'])} "
          f"({metrics['top1']['correct']}/{metrics['top1']['total']}); "
          f"worst regret {percentage(metrics['top1_regret']['worst'])}")
    if metrics['worst_cases']:
        worst = metrics['worst_cases'][0]
        print(f"  Worst: {worst['id']}, selected s{worst['selected_vf']}, best s{worst['oracle_vf']}")


def main(argv=None):
    import sys
    import time
    from collection import collect_population, collector_identity, prepare, validate_target
    from cost_model import identity
    parser = vt.argument_parser('Evaluate the port-demand model and verify selection replay.')
    parser.add_argument('--benchmark', help='evaluate one exact benchmark ID')
    parser.add_argument('--output-dir', type=vt.resolved_path, required=True)
    parser.add_argument('--cache-dir', type=vt.resolved_path, default=vt.TOOLS / '.cache/local-observations')
    parser.add_argument('--skip-build', action='store_true')
    parser.add_argument('--ranking-only', action='store_true', help='diagnostic without final selection replay')
    parser.add_argument('--no-baseline', action='store_true', help='diagnostic without ordinary LLVM comparison')
    args = parser.parse_args(argv)
    if args.compiler_mode != 'meta': parser.error('evaluation requires meta mode')
    settings = Settings.from_args(args)
    benchmarks, metadata = vt.load_database(args.db, args.benchmark)
    if not benchmarks: raise vt.ToolError('no selected benchmarks')
    validate_target(metadata)
    if args.output_dir.exists() and any(args.output_dir.iterdir()):
        raise vt.ToolError('output directory must be new or empty')
    args.output_dir.mkdir(parents=True, exist_ok=True)
    clang = vt.compiler_from_args(args)
    context = collector_identity(clang, args.llvm_path / 'utils/vplan-meta-compile')
    started = time.monotonic()
    fixed_identity = identity(settings)
    fingerprint = dataset_fingerprint(benchmarks, metadata)
    bundles, errors = collect_population(benchmarks, clang, args, context)
    rows = []
    for index, benchmark in enumerate(benchmarks, 1):
        print(f'[{index}/{len(benchmarks)}] port model {benchmark.id}', file=sys.stderr, flush=True)
        if benchmark.id in errors:
            row = excluded(benchmark, errors[benchmark.id], 'compile-failed')
        else:
            try:
                example = prepare(benchmark, bundles[benchmark.id], settings)
                row = evaluate(example, settings)
                if row['eligible']:
                    reports = [r for group in example['candidates'].values() for r in group]
                    vt.write_json(args.output_dir / 'reports' / (vt.report_name(benchmark.id) + '.json'), reports)
                    if not args.ranking_only:
                        try: replay(benchmark, example, row, clang, args, args.output_dir / 'replay' / vt.report_name(benchmark.id), settings)
                        except (vt.ToolError, OSError) as exc:
                            row.update(eligible=False, status='replay-failed', reason=str(exc), top1_correct=None, top1_regret=None)
            except vt.ToolError as exc:
                row = excluded(benchmark, str(exc))
        rows.append(row)
        vt.write_json(args.output_dir / 'summary.json', dict(schema='mir-port-aware-evaluation-v1', complete=False,
                      identity=fixed_identity, rows=rows, metrics=summarize_rows(rows)))
    baseline_rows = []
    if not args.no_baseline:
        from llvm_baseline import evaluate_population
        baseline_rows = evaluate_population(benchmarks, clang, args)
        vt.write_json(args.output_dir / 'baseline.json', dict(rows=baseline_rows, metrics=summarize_rows(baseline_rows), compiler_context=context))
    if identity(settings) != fixed_identity: raise vt.ToolError('model changed during evaluation')
    summary = dict(schema='mir-port-aware-evaluation-v1', complete=len(rows) == len(benchmarks),
                   successful=any(r['eligible'] for r in rows) and not any(r['status'] in ('compile-failed', 'replay-failed') for r in rows)
                   and (args.no_baseline or (any(r['eligible'] for r in baseline_rows) and not any(r.get('compile_failed') for r in baseline_rows))),
                   identity=fixed_identity, compiler_context=context, dataset_fingerprint=fingerprint, metadata=metadata,
                   rows=rows, metrics=summarize_rows(rows), elapsed_seconds=time.monotonic() - started,
                   replay_required=not args.ranking_only, baseline_required=not args.no_baseline)
    if baseline_rows: summary['comparison'] = compare(rows, baseline_rows)
    vt.write_json(args.output_dir / 'summary.json', summary)
    print_metrics('Port-demand model', summary['metrics'])
    if baseline_rows:
        print_metrics('Port model (matched population)', summary['comparison']['model'])
        print_metrics('LLVM (matched population)', summary['comparison']['baseline'])
    print(f"Results: {args.output_dir / 'summary.json'}")
    return 0 if summary['successful'] else 1
