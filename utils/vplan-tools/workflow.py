"""Raw observation collection and measurement-free fixed-model scoring."""
import argparse
import json
from pathlib import Path
from collection import collect_population, collector_identity, validate_target
from cost_model import identity, score_observation, Settings, add_arguments
from evaluation import dataset_fingerprint
import vplan_tools as vt


def main(argv=None):
    parser = vt.argument_parser('Collect passive MIR facts without reading measurements into the model.')
    parser.add_argument('--benchmark', help='exact ID for collection diagnostics')
    parser.add_argument('--output', type=vt.resolved_path, required=True)
    parser.add_argument('--cache-dir', type=vt.resolved_path, default=vt.CACHE_ROOT / 'local-observations')
    parser.add_argument('--skip-build', action='store_true')
    args = parser.parse_args(argv)
    if args.compiler_mode != 'meta': parser.error('collection requires meta mode')
    benchmarks, metadata = vt.load_database(args.db, args.benchmark)
    if not benchmarks: raise vt.ToolError('no selected benchmarks')
    validate_target(metadata)
    clang = vt.compiler_from_args(args)
    context = collector_identity(clang, args.llvm_path / 'utils/vplan-meta-compile')
    bundles, errors = collect_population(benchmarks, clang, args, context)
    vt.write_json(args.output, dict(schema='mir-local-population-v1', identity=identity(), compiler_context=context,
                  dataset_fingerprint=dataset_fingerprint(benchmarks, metadata), metadata=metadata,
                  collections={id_: dict(key=b['key'], artifacts=b['artifacts']) for id_, b in bundles.items()}, errors=errors))
    print(f'Collected {len(bundles)}/{len(benchmarks)}; {args.output}')
    return 1 if errors else 0


def score_main(argv=None):
    parser = argparse.ArgumentParser(description='Score a raw collection using the hardcoded machine model, without a measurement database.')
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--detail', action='store_true')
    add_arguments(parser)
    args = parser.parse_args(argv)
    settings = Settings.from_args(args)
    from collection import validate_bundle
    bundle = json.loads(args.bundle.read_text())
    validate_bundle(bundle, bundle['compiler_context'], bundle['key'])
    rows = []
    for row in bundle['rows']:
        try:
            if row['observation'] is None: raise vt.ToolError(row['reason'] or row['status'])
            report = score_observation(row['observation'], settings)
            vt.print_report(report, args.detail)
            rows.append(dict(candidate=row['candidate']['id'], status='scored', report=report))
        except vt.ToolError as exc:
            rows.append(dict(candidate=row['candidate']['id'], status='unsupported', reason=str(exc)))
    vt.write_json(args.output, dict(schema='mir-port-score-bundle-v1', collection_key=bundle['key'], identity=identity(settings), rows=rows))
    return 0 if any(r['status'] == 'scored' for r in rows) else 1
