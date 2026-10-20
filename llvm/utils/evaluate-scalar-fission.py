#!/usr/bin/env python3
# Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
# See https://llvm.org/LICENSE.txt for license information.
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
"""Compare independent original-LV, Early and Late runs on a pinned corpus.

Requires PyYAML. Reads search-fission-benchmarks' targets.json without modifying
sources or historical evidence. Exact function/file/line/column attribution is
required for target selection; inner-loop and helper records remain separate.
"""
import argparse
from collections import Counter
from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib
import json
from pathlib import Path
import subprocess
import shutil
import sys
import time
import yaml

class Loader(yaml.SafeLoader):
    pass
Loader.add_multi_constructor('!', lambda loader, tag, node: loader.construct_mapping(node))


def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def run(argv, directory, tag):
    argv = list(map(str, argv))
    (directory / (tag + '.command.json')).write_text(json.dumps(argv) + '\n')
    start = time.perf_counter()
    # Measure each process, not the cumulative maximum of previous children.
    measured = argv
    rss = directory / (tag + '.resources')
    if sys.platform == 'darwin':
        measured = ['/usr/bin/time', '-l', '-o', str(rss), *argv]
    result = subprocess.run(measured, capture_output=True, text=True, timeout=180)
    elapsed = time.perf_counter() - start
    (directory / (tag + '.stderr')).write_text(result.stderr)
    peak = None
    if rss.exists():
        for line in rss.read_text().splitlines():
            if 'maximum resident set size' in line: peak = int(line.split()[0])
    return dict(exit_code=result.returncode, seconds=elapsed, peak_rss_bytes=peak)


def records(path, entry):
    all_records = list(yaml.load_all(path.read_text() if path.exists() else '', Loader=Loader))
    target, other = [], []
    for r in all_records:
        if not isinstance(r, dict) or r.get('Pass') not in ['scalar-fission', 'vplan-reduction-fission', 'loop-vectorize']:
            continue
        loc, expected = r.get('DebugLoc', {}), entry['location']
        exact = (expected['status'] == 'exact' and r.get('Function') == entry['function']
                 and Path(loc.get('File', '')).name == Path(entry['source']).name
                 and loc.get('Line') == expected['target']['line']
                 and (not loc.get('Column') or loc['Column'] == expected['target']['column']))
        (target if exact else other).append(r)
    selections = [r for r in target if r['Pass'] in ['scalar-fission', 'vplan-reduction-fission'] and r.get('Name') == 'Selected']
    rejections = [r for r in target if r['Pass'] in ['scalar-fission', 'vplan-reduction-fission'] and r.get('Name') == 'Rejected']
    return dict(fission='selected' if selections else 'rejected' if rejections else 'no_decision',
                target_records=target, other_records=other)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--build-dir', type=Path, required=True)
    p.add_argument('--corpus', type=Path, required=True)
    p.add_argument('--sysroot', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--frontend-input-dir', type=Path,
                   help='reuse a completed corpus run’s verified frontend IR for an identical-input comparison')
    args = p.parse_args()
    build, corpus, output = args.build_dir.resolve(), args.corpus.resolve(), args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    manifest = corpus / 'benchmark-search/targets.json'
    entries = json.loads(manifest.read_text())['benchmarks']
    frontend_dir = args.frontend_input_dir.resolve() if args.frontend_input_dir else None
    if frontend_dir:
        previous = json.loads((frontend_dir / 'result.json').read_text())
        assert previous['manifest_sha256'] == sha(manifest), 'frontend manifest mismatch'
    def evaluate_one(e):
        rows = []
        source = corpus / e['source']
        assert sha(source) == e['sha256'], f'changed corpus source: {source}'
        case = output / e['id']
        case.mkdir(exist_ok=True)
        cpp = source.suffix != '.c'
        includes = []
        if cpp:
            base = args.sysroot / 'include/c++/15.2.0'
            includes = ['-isystem', base, '-isystem', base / 'riscv-none-elf']
        if frontend_dir:
            original = frontend_dir / e['id']
            command = original / 'frontend.command.json'
            assert str(source) in json.loads(command.read_text()), 'frontend source mismatch'
            shutil.copy2(original / 'raw.bc', case / 'raw.bc')
            front = dict(exit_code=0, seconds=0, peak_rss_bytes=None,
                         reused_from=str(original / 'raw.bc'),
                         input_sha256=sha(case / 'raw.bc'),
                         command_provenance=str(command), command_sha256=sha(command),
                         compiler_sha256=previous['compiler']['clang'])
        else:
            front = run([build / 'bin/clang', '--target=riscv64-unknown-elf',
                '-march=rv64gcv_zba_zbb_zbc_zbs_zfh_zvfh_zvbb_zvl128b',
                '-mcpu=xiangshan-kunminghu', '-mabi=lp64d', '-mcmodel=medany',
                '-mno-relax', '-mrvv-vector-bits=128', '--sysroot=' + str(args.sysroot),
                *includes, '-isystem', args.sysroot / 'include',
                '-std=c++17' if cpp else '-std=c11', '-DBENCH_NO_MAIN', '-ffp-contract=off',
                '-O3', '-gline-tables-only', '-gcolumn-info', '-fno-discard-value-names',
                '-Xclang', '-disable-llvm-passes', '-emit-llvm', '-c', source,
                '-o', case / 'raw.bc'], case, 'frontend')
            front['input_sha256'] = sha(case / 'raw.bc') if not front['exit_code'] else None
        for placement, relaxed in [('baseline', False), ('early', False), ('late', False), ('early', True), ('late', True)]:
            tag = placement + ('-reordered' if relaxed else '-ordered')
            flags = [] if placement == 'baseline' else [
                '-enable-scalar-fission', '-scalar-fission-early=' + str(placement == 'early').lower(),
                '-scalar-fission-allow-fp-reordering=' + str(relaxed).lower()]
            flags += ['-force-vector-interleave=1', '-hints-allow-reordering=false']
            opt = run([build / 'bin/opt', '-passes=default<O3>', '-verify-each',
                *flags, '-pass-remarks-output=' + str(case / (tag + '.yaml')),
                '-pass-remarks-filter=(scalar-fission|loop-vectorize)', '-debug-pass-manager',
                '-S', case / 'raw.bc', '-o', case / (tag + '.ll')], case, tag) if not front['exit_code'] else front
            evidence = records(case / (tag + '.yaml'), e)
            codegen = run([build / 'bin/llc', '-verify-machineinstrs', case / (tag + '.ll'),
                '-o', case / (tag + '.s')], case, tag + '-codegen') if not opt['exit_code'] else None
            row = dict(id=e['id'], source=e['source'], source_sha256=e['sha256'], placement=placement,
                       fp_reordering=relaxed, frontend=front, optimization=opt, codegen=codegen, **evidence)
            if opt['exit_code'] or (codegen and codegen['exit_code']): row['fission'] = 'error'
            rows.append(row)
        (case / 'rows.json').write_text(json.dumps(rows, indent=2)+'\n')
        return rows
    rows = []
    with ThreadPoolExecutor(max_workers=4) as pool:
        futures = [pool.submit(evaluate_one, e) for e in entries]
        for future in as_completed(futures):
            group = future.result()
            rows.extend(group)
            print(group[0]['id'], [r['fission'] for r in group], flush=True)
            (output/'progress.json').write_text(json.dumps(dict(completed=len(rows), total=5*len(entries)))+'\n')
    rows.sort(key=lambda r: (r['id'], r['placement'], r['fp_reordering']))
    summaries = {}
    for placement, relaxed in {(r['placement'], r['fp_reordering']) for r in rows}:
        group = [r for r in rows if r['placement'] == placement and r['fp_reordering'] == relaxed]
        summaries[f'{placement}-fp{int(relaxed)}'] = dict(Counter(r['fission'] for r in group))
        summaries[f'{placement}-fp{int(relaxed)}']['compile_seconds'] = sum(r['optimization']['seconds'] for r in group)
        summaries[f'{placement}-fp{int(relaxed)}']['peak_rss_bytes'] = max(r['optimization']['peak_rss_bytes'] or 0 for r in group)
    result = dict(schema=1, manifest_sha256=sha(manifest), rows=rows, summary=summaries,
                  compiler={x: sha(build/'bin'/x) for x in ['clang','opt','llc']},
                  rvv='machine verification only', performance='unmeasured')
    (output/'result.json').write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps(summaries, indent=2))

if __name__ == '__main__': main()
