#!/usr/bin/env python3
# Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
# See https://llvm.org/LICENSE.txt for license information.
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
"""Execute fixed-vscale fission specializations on the host, not an RVV emulator.

Requires a build containing opt, llc, and both RISCV and the host backend, plus
a host C compiler. The original scalar IR is the reference. Logs, generated IR,
objects and a JSON result are retained in --work-dir when supplied.
"""

import argparse
import json
import re
import shutil
import subprocess
import tempfile
from pathlib import Path


def run(command, **kwargs):
    return subprocess.run(
        [str(arg) for arg in command], check=True, text=True, capture_output=True,
        **kwargs
    )


def specialize(ir, scale):
    ir = re.sub(r"<vscale x (\d+) x ", lambda m: f"<{int(m[1]) * scale} x ", ir)
    ir = re.sub(r"\.nxv(\d+)", lambda m: f".v{int(m[1]) * scale}", ir)
    ir = re.sub(r"call i(\d+) @llvm.vscale.i\d+\(\)",
                lambda m: f"add i{m[1]} 0, {scale}", ir)
    return ir


def host_ir(ir):
    ir = re.sub(r'^target (?:triple|datalayout) = .*$', '', ir, flags=re.M)
    ir = re.sub(r'"(?:target-[^"]+|tune-cpu)"="[^"]*"', '', ir)
    ir = re.sub(r'vscale_range\([^)]*\)', '', ir)
    for group in re.findall(r'^attributes #(\d+) = \{\s*\}$', ir, re.M):
        ir = re.sub(rf'^attributes #{group} = \{{\s*\}}$', '', ir, flags=re.M)
        ir = re.sub(rf' #{group}\b', '', ir)
    return ir


def check(args, work):
    root = Path(__file__).resolve().parents[2]
    tests = root / 'llvm/test/Transforms/LoopVectorize/RISCV'
    opt, llc = (args.build_dir / 'bin' / name for name in ('opt', 'llc'))
    triple = run([args.cc, '-dumpmachine']).stdout.strip()
    objects, records = [], []
    declarations, combined_rows, induction_rows, fp_rows = [], [], [], []
    common = [
        '-passes=loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>',
        '-verify-each', '-mtriple=riscv64', '-mattr=+v',
        '-force-vector-interleave=1', '-hints-allow-reordering=false',
        '-enable-vplan-reduction-fission', '-vplan-reduction-fission-min-chain-depth=4',
        '-pass-remarks=vplan-reduction-fission', '-S', '-o', '-',
    ]

    def compile_ir(name, ir):
        path = work / f'{name}.ll'
        path.write_text(host_ir(ir))
        obj = path.with_suffix('.o')
        run([llc, f'-mtriple={triple}', '-filetype=obj', '-verify-machineinstrs',
             path, '-o', obj])
        objects.append(obj)

    for fixture, functions in [
        ('combined', ['combined']),
        ('induction', ['induction', 'negative_step', 'truncated']),
        ('fp-reordering', ['fp_reordering']),
    ]:
        source = (tests / f'reduction-fission-{fixture}.ll').read_text()
        # These fixtures also contain rejection cases, which must not be
        # included repeatedly under their original names in the host objects.
        source = re.sub(
            r'^define[^\n]*?@([^ (]+)\([^\n]*\{.*?^}',
            lambda m: m[0] if m[1] in functions else '', source, flags=re.M | re.S)
        reference = source
        for function in functions:
            reference = reference.replace(f'@{function}(', f'@ref_{function}(')
        compile_ir(f'reference_{fixture}', reference)
        for relaxed in ([False, True] if fixture == 'combined' else
                        [fixture == 'fp-reordering']):
            flags = list(common)
            if fixture != 'fp-reordering':
                flags += [f'-vplan-reduction-fission-force-producer-vf={8 if fixture == "combined" else 16}',
                          '-vplan-reduction-fission-force-accumulator-vf=2']
            if relaxed:
                flags.append('-vplan-reduction-fission-allow-fp-reordering')
            result = run([opt, *flags], input=source)
            tag = f'{fixture}_{"relaxed" if relaxed else "ordered"}'
            (work / f'{tag}.remarks').write_text(result.stderr)
            assert result.stdout.count('vector.fission.producer.body:') == len(functions), result.stderr
            # RVV machine verification is independent of host execution.
            run([llc, '-mtriple=riscv64', '-mattr=+v', '-verify-machineinstrs',
                 '-o', str(work / f'{tag}.s')], input=result.stdout)
            for scale in args.vscales:
                fixed = specialize(result.stdout, scale)
                for function in functions:
                    name = f'{function}_{"r" if relaxed else "o"}_s{scale}'
                    fixed = fixed.replace(f'@{function}(', f'@{name}(')
                    if fixture == 'combined':
                        declarations.append(f'extern CombinedFn {name};')
                        combined_rows.append(f'{{"{name}", {str(relaxed).lower()}, {name}}}')
                    elif fixture == 'induction':
                        declarations.append(f'extern InductionFn {name};')
                        induction_rows.append(f'{{"{name}", {name}, ref_{function}}}')
                    else:
                        declarations.append(f'extern FPFn {name};')
                        fp_rows.append(f'{{"{name}", {name}}}')
                compile_ir(f'{tag}_s{scale}', fixed)
                records.append({'fixture': fixture, 'reordering': relaxed,
                                'vscale': scale, 'options': flags,
                                'selection_remarks': result.stderr})
                print(f'Built {tag}, vscale={scale}', flush=True)

    harness = (root / 'llvm/utils/reduction-fission-execution.c.in').read_text()
    for key, rows in [('DECLARATIONS', declarations), ('COMBINED', combined_rows),
                      ('INDUCTIONS', induction_rows), ('FP', fp_rows)]:
        harness = harness.replace(f'@{key}@', '\n'.join(rows) if key == 'DECLARATIONS'
                                   else ',\n'.join(rows))
    harness_path = work / 'harness.c'
    harness_path.write_text(harness)
    executable = work / 'check'
    run([args.cc, '-std=c11', '-O2', '-ffp-contract=off', harness_path, *objects,
         '-lm', '-o', executable])
    result = run([executable])
    print(result.stdout, end='')
    (work / 'results.json').write_text(json.dumps({
        'execution': 'host fixed-vscale specialization (not RVV execution)',
        'host_triple': triple, 'cases': records, 'result': result.stdout,
        'runtime_trip_counts': [0, 1, 2, 3, 7, 8, 15, 16, 17, 31, 32, 33,
                                63, 64, 65, 257, 1023, 1024, 1025],
        'comparison': {
            'integer_and_ordered_fp': 'exact against scalar IR',
            'relaxed_fp': 'NaN/Inf classification, signed zero, absolute error '
                          '<= 16 * DBL_EPSILON * (N + 1) * sum of magnitudes',
        },
    }, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-dir', type=Path, required=True)
    parser.add_argument('--work-dir', type=Path)
    parser.add_argument('--cc', default=shutil.which('cc'))
    parser.add_argument('--vscales', nargs='+', type=int, default=[1, 2, 4, 8, 32])
    args = parser.parse_args()
    if not args.cc or any(scale <= 0 for scale in args.vscales):
        parser.error('a host C compiler and positive vscales are required')
    if args.work_dir:
        args.work_dir.mkdir(parents=True, exist_ok=True)
        check(args, args.work_dir.resolve())
    else:
        with tempfile.TemporaryDirectory(prefix='fission-execution-') as directory:
            check(args, Path(directory))


if __name__ == '__main__':
    try:
        main()
    except subprocess.CalledProcessError as error:
        print(error.stdout or '', end='')
        print(error.stderr or '', end='')
        raise
