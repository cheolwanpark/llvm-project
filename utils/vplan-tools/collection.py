"""Measurement-free compiler observations, preserved MIR, and candidate coverage."""
import hashlib
import json
from pathlib import Path
import sys

from cost_model import digest_json, features_for_observation
from model_errors import ToolError
from observations import PROTOCOL_VERSION, SCHEMA, bind_observation, validate_manifest
import vplan_tools as vt

CACHE_SCHEMA = 'mir-local-collection-v1'


def digest_file(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''): h.update(block)
    return h.hexdigest()


def collector_identity(clang, meta_script):
    directory = Path(meta_script).parent / 'vplan-tools'
    return dict(schema=CACHE_SCHEMA, observation_schema=SCHEMA, protocol=PROTOCOL_VERSION,
                compiler=digest_file(clang), extractor=digest_file(Path(clang).parent / 'llvm-extract'),
                stage='post-ra-cleanup', driver=digest_file(meta_script),
                collector=digest_file(directory / 'collection.py'),
                tools=digest_file(directory / 'vplan_tools.py'),
                observations=digest_file(directory / 'observations.py'),
                headers={p.name: digest_file(p) for p in sorted((directory / 'include').iterdir()) if p.is_file()})


def validate_target(metadata):
    from hardware import REVISION
    protocol = metadata['measurement_protocol']
    if (metadata['target'] != 'xiangshan-v2/MinimalConfig@' + REVISION
            or protocol.get('rtl_revision') != REVISION
            or protocol.get('vlen_bits') != 128 or protocol.get('elen_bits') != 64):
        raise ToolError('dataset target/revision/VLEN/ELEN do not match the pinned hardware rules')


def validate_bundle(bundle, context, key):
    try:
        if bundle['schema'] != CACHE_SCHEMA or bundle['key'] != key or bundle['compiler_context'] != context:
            raise ValueError('incompatible collection identity; recollect')
        manifest = validate_manifest(bundle['manifest'], bundle['manifest']['run_id'])
        if [r['candidate']['id'] for r in bundle['rows']] != [r['id'] for r in manifest['candidates']]:
            raise ValueError('candidate population changed')
        loops = {(l['function'], l['loop']): l for l in manifest['loops']}
        for row in bundle['rows']:
            if row['observation'] is not None:
                c = row['candidate']
                bound = bind_observation(row['observation'], c, loops[c['function'], c['loop']], manifest['run_id'])
                if bound != row['observation']:
                    raise ValueError('bound middle-end context changed')
                mir = Path(row['mir'])
                raw = json.loads(mir.with_suffix('.analytics.json').read_text())
                if bind_observation(raw, c, loops[c['function'], c['loop']], manifest['run_id']) != bound:
                    raise ValueError('cached observation disagrees with the raw backend artifact')
                if not mir.is_file() or digest_file(mir) != row['mir_sha256']:
                    raise ValueError('missing or changed full MIR artifact')
    except (ValueError, KeyError, TypeError) as exc:
        raise ToolError(f'invalid raw collection: {exc}') from exc
    return bundle


def collect(benchmark, clang, args, context):
    key = digest_json(dict(compiler_context=context, source=benchmark.source, flags=benchmark.compile_args))
    root = args.cache_dir / key
    path = root / 'bundle.json'
    if path.exists():
        try: return validate_bundle(json.loads(path.read_text()), context, key)
        except (OSError, ValueError, ToolError) as exc: raise ToolError(f'invalid cache {path}: {exc}; remove the entry to recollect') from exc
    root.mkdir(parents=True, exist_ok=True)
    result = vt.compile_report(clang, benchmark, False, args.timeout,
                               meta_script=args.llvm_path / 'utils/vplan-meta-compile',
                               artifacts_dir=root, stop_after_ra=True, analytics_only=True)
    if result.returncode: raise ToolError('compiler collection failed: ' + result.stderr[-3000:])
    backend = result.artifact_root / 'backend'
    compile_identity = json.loads((backend / 'identity.json').read_text())
    if compile_identity['compiler'] != context['compiler'] or digest_file(clang) != context['compiler']:
        raise ToolError('compiler binary changed during collection; restart the run')
    manifest = result.manifest
    loops = {(l['function'], l['loop']): l for l in manifest['loops']}
    rows = []
    for index, (candidate, status) in enumerate(zip(manifest['candidates'], result.candidate_status['candidates'], strict=True)):
        a = None
        mir = backend / f'probe-{index:04d}.mir'
        if status['status'] == 'collected':
            a = bind_observation(json.loads((backend / f'probe-{index:04d}.analytics.json').read_text()), candidate,
                                 loops[candidate['function'], candidate['loop']], manifest['run_id'])
        rows.append(dict(candidate=candidate, observation=a, reason=status.get('reason'),
                         status=status['status'], mir=str(mir) if a else None,
                         mir_sha256=digest_file(mir) if a else None))
    bundle = dict(schema=CACHE_SCHEMA, key=key, compiler_context=context, manifest=manifest, rows=rows,
                  artifacts=str(result.artifact_root))
    validate_bundle(bundle, context, key)
    vt.write_json(path, bundle)
    return bundle


def prepare(benchmark, bundle):
    loops = [l for l in bundle['manifest']['loops'] if l['function'] == 'selected_kernel']
    if len(loops) != 1: raise ToolError(f'expected one selected_kernel loop, found {len(loops)}')
    candidates = [r for r in bundle['rows'] if r['candidate']['function'] == 'selected_kernel'
                  and r['candidate']['vf'].startswith('s')]
    population = {int(r['candidate']['vf'][1:]) for r in candidates}
    benchmark = vt.restrict_measurements(benchmark, population)
    if len(population) < 2: raise ToolError('fewer than two compiler scalable VFs')
    prepared, coverage, failed = {}, [], set()
    contexts = set()
    for row in candidates:
        candidate, a = row['candidate'], row['observation']
        vf = int(candidate['vf'][1:])
        try:
            if a is None: raise ToolError(row['reason'] or row['status'])
            contexts.add(tuple(a[k] for k in ('run_id', 'function', 'cpu', 'features', 'vlen', 'exact_trip_count', 'max_trip_count')))
            report = features_for_observation(a)
            prepared.setdefault(vf, []).append(report)
            coverage.append(dict(id=candidate['id'], vf=vf, status='supported', coverage=report['coverage']))
        except ToolError as exc:
            failed.add(vf)
            coverage.append(dict(id=candidate['id'], vf=vf, status='unsupported', reason=str(exc)))
    if len(contexts) > 1: raise ToolError('candidate observation contexts disagree')
    # Full candidate coverage is required: losing a plan cannot improve the
    # reported candidate ranking or change its optimization population silently.
    reason = ('unsupported candidate VF(s): ' + ','.join(map(str, sorted(failed)))) if failed else None
    if set(prepared) != population: reason = reason or 'missing supported VF'
    return dict(benchmark=benchmark, candidates=prepared, coverage=coverage, reason=reason,
                collection_key=bundle['key'], artifacts=bundle['artifacts'])


def collect_population(benchmarks, clang, args, context):
    bundles, errors = {}, {}
    for i, benchmark in enumerate(benchmarks, 1):
        print(f'[{i}/{len(benchmarks)}] collect {benchmark.id}', file=sys.stderr, flush=True)
        try: bundles[benchmark.id] = collect(benchmark, clang, args, context)
        except (ToolError, OSError) as exc:
            errors[benchmark.id] = str(exc)
            print('  ' + str(exc), file=sys.stderr, flush=True)
    return bundles, errors
