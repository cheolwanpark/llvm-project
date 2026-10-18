#!/usr/bin/env python3
# Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
# See https://llvm.org/LICENSE.txt for license information.
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
"""Execute fixed-vscale fission specializations on the host, not an RVV emulator.

Requires a build containing opt, llc, and both RISCV and the host backend, plus
a host C compiler. The original scalar IR is the reference. Logs, generated IR,
objects and a JSON result are retained in --work-dir when supplied.

Early scalar-fission fixtures keep the default EVL/VP path for RVV codegen
verification. Host execution uses the separately labeled dont-fold-tail
variant; specialize() deliberately rejects EVL/VP rather than approximating
their mask, inactive-lane or vector-length semantics.
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
    unsupported = re.search(r'@llvm\.(?:vp\.[\w.]+|experimental\.get\.vector\.length[\w.]*)', ir)
    if unsupported:
        raise ValueError(f'fixed-vscale host specialization does not support '
                         f'{unsupported[0]}; use the scalar-remainder variant')
    ir = re.sub(r"<vscale x (\d+) x ", lambda m: f"<{int(m[1]) * scale} x ", ir)
    ir = re.sub(r"\.nxv(\d+)", lambda m: f".v{int(m[1]) * scale}", ir)
    ir = re.sub(r"call i(\d+) @llvm.vscale.i\d+\(\)",
                lambda m: f"add i{m[1]} 0, {scale}", ir)
    return ir


# LLVM prints the closing function brace at the start of a line. Match whole
# definitions, including multiline argument lists, without crossing that brace.
# All fixtures use unquoted function names.
FUNCTION_DEFINITION = re.compile(
    r'^define\b[^@]*@(?P<name>[-\w.$]+)\(.*?^}', re.M | re.S)


def function_definition(ir, name):
    matches = [m[0] for m in FUNCTION_DEFINITION.finditer(ir) if m['name'] == name]
    if len(matches) != 1:
        found = ', '.join(m['name'] for m in FUNCTION_DEFINITION.finditer(ir))
        raise ValueError(f'expected one definition for @{name}, found {len(matches)}; '
                         f'available definitions: {found or "none"}')
    return matches[0]


def keep_functions(ir, names):
    for name in names:
        function_definition(ir, name)
    return FUNCTION_DEFINITION.sub(
        lambda m: m[0] if m['name'] in names else '', ir)


def scalar_consumer(body, name):
    parts = re.split(r'^scalar\.fission\.consumer\.ph:[^\n]*\n', body, flags=re.M)
    if len(parts) != 2:
        raise ValueError(f'@{name}: expected exactly one scalar fission consumer')
    return parts


def check_scalar_function(ir, name, evl, probe=False, fixed_narrow=False):
    body = function_definition(ir, name)
    producer, consumer = scalar_consumer(body, name)
    compact = name.startswith('compact_')
    if name in ('scalar_helper_sum', 'scalar_mixed', 'scalar_nested',
                'scalar_diamond', 'scalar_diamond_nested',
                'compact_triangle', 'compact_diamond', 'compact_nested'):
        assert producer.count('call i32 @scalar_helper(') == 1, body
        assert '<vscale x' not in producer, producer
    if name in ('scalar_mixed', 'scalar_diamond', 'compact_triangle', 'compact_diamond'):
        assert body.count('alloca [65 x i32]') == 1, body
        assert body.count('alloca [65 x double]') == 1, body
        assert body.count('alloca [65 x float]') == 1, body
    if name in ('scalar_nested', 'scalar_diamond_nested', 'compact_nested'):
        assert body.count('alloca [65 x i32]') == 1, body
        assert body.count('alloca [65 x double]') == 1, body
    if name in ('scalar_diamond', 'scalar_diamond_nested'):
        # Check actual preserved control and merge placement, independently of
        # the vector consumer. Unsafe arm operations must remain conditional.
        header, arms = re.split(r'^left:[^\n]*\n', producer, maxsplit=1, flags=re.M)
        left, rest = re.split(r'^right:[^\n]*\n', arms, maxsplit=1, flags=re.M)
        right, latch = re.split(r'^latch:[^\n]*\n', rest, maxsplit=1, flags=re.M)
        assert 'br i1 %choose, label %left, label %right' in header, header
        assert 'call i32 @scalar_helper(' in left, left
        assert '%c = phi i32' in latch and latch.count('store i32 %c,') == 1, latch
        assert 'store i32' not in left + right, producer
        if name == 'scalar_diamond':
            assert 'sdiv i32 840, %x' in left, left
            assert 'load double, ptr %dp' in right, right
            assert 'sdiv ' not in header + right + latch, producer
            assert 'load double' not in header + left + latch, producer
    if compact:
        header, arms = re.split(r'^left:[^\n]*\n', producer, maxsplit=1, flags=re.M)
        active, rest = re.split(r'^(?:right|latch):[^\n]*\n', arms, maxsplit=1, flags=re.M)
        successors = {'compact_triangle': ('left', 'latch'),
                      'compact_diamond': ('right', 'left'),
                      'compact_integer': ('latch', 'left'),
                      'compact_nested': ('left', 'right')}
        first, second = successors[name]
        assert f'br i1 %choose, label %{first}, label %{second}' in header, header
        assert '<vscale x' not in producer, producer
        assert producer.count('fission.participating.next = add nuw i64') == 1, producer
        assert 'fadd ' not in producer, producer
        assert 'store ' not in header + rest, producer
        assert active.count('store ') == (1 if name == 'compact_integer' else
                                          2 if name == 'compact_nested' else 3), active
        assert ('%fission.empty = icmp eq i64 %fission.participating.count, 0'
                in producer), producer
        assert ('br i1 %fission.empty, label %scalar.fission.consumer.exit, '
                'label %scalar.fission.consumer.ph') in producer, producer
        assert 'fission.participating.count' in consumer, consumer
        if name in ('compact_triangle', 'compact_diamond'):
            assert 'sdiv i32 840, %x' in active, active
            assert 'load double, ptr %dp' in active, active
            assert 'sdiv ' not in header + rest, producer
            assert 'load double' not in header + rest, producer
    # Reduction checks refer to this consumer, never another function or the
    # (possibly vectorized) arithmetic producer. A width too large for a
    # constant/one-iteration loop is allowed to leave its consumer scalar.
    vectorized = name in ('scalar_helper_sum', 'arithmetic_sum', 'scalar_mixed',
                          'scalar_nested', 'scalar_diamond',
                          'diamond_arithmetic', 'scalar_diamond_nested') or compact or fixed_narrow
    if vectorized:
        vector = re.search(r'^vector\.body[^:]*:[^\n]*\n(.*?)(?=^[\w.$-]+:|^})',
                           consumer, re.M | re.S)
        assert vector, f'@{name}: missing vector consumer\n{consumer}'
        if name in ('scalar_mixed', 'scalar_nested', 'scalar_diamond',
                    'scalar_diamond_nested', 'compact_triangle', 'compact_diamond',
                    'compact_nested'):
            types = [('double', 'f64')]
            if name in ('scalar_mixed', 'scalar_diamond', 'compact_triangle', 'compact_diamond'):
                types.append(('float', 'f32'))
            for ty, suffix in types:
                intrinsic = r'vp\.reduce' if evl else r'vector\.reduce'
                # No flags before the result type: FP remains ordered under
                # both settings of the separate fission FP-reordering option.
                assert re.search(rf'call {ty} @llvm\.{intrinsic}\.fadd\.nxv4{suffix}\(',
                                 vector[0]), f'@{name}: missing ordered {ty} reduction\n{consumer}'
        width = 'v4' if fixed_narrow else 'nxv4'
        assert re.search(rf'call i(?:32|64) @llvm\.vector\.reduce\.add\.{width}',
                         consumer), f'@{name}: missing integer consumer reduction\n{consumer}'
        if evl:
            assert '@llvm.experimental.get.vector.length.' in vector[0], consumer
            assert '@llvm.vp.load.' in vector[0], consumer
        else:
            if not fixed_narrow:  # 200 is a multiple of the fixed VF, 4.
                assert 'scalar.fission.consumer.body:' in consumer, consumer
            lanes = '4' if fixed_narrow else 'vscale x 4'
            assert f'load <{lanes} x' in vector[0], consumer
        if name in ('scalar_mixed', 'scalar_diamond', 'compact_triangle', 'compact_diamond'):
            loads = (r'call <vscale x 4 x i32> @llvm\.vp\.load\.' if evl
                     else r'load <vscale x 4 x i32>')
            assert len(re.findall(loads, vector[0])) == 1, consumer
        if probe:
            # Insert after all PHIs of this exact consumer header. The helper
            # is present only in host test IR, never the RVV codegen input.
            instrumented, probes = re.subn(
                r'(^vector\.body[^:]*:[^\n]*\n(?:[^\n]* = phi [^\n]*\n)*)',
                r'\1  call void @record_scalar_consumer_vector()\n',
                consumer, count=1, flags=re.M)
            assert probes == 1, f'@{name}: missing vector-consumer probe site'
            if name in ('scalar_diamond', 'scalar_diamond_nested') or compact:
                instrumented, tails = re.subn(
                    r'(^scalar\.fission\.consumer\.body:[^\n]*\n(?:[^\n]* = phi [^\n]*\n)*)',
                    r'\1  call void @record_scalar_consumer_tail()\n',
                    instrumented, count=1, flags=re.M)
                assert tails == 1, f'@{name}: missing scalar-tail probe site'
            if compact:
                producer, visits = re.subn(
                    r'(^left:[^\n]*\n(?:[^\n]* = phi [^\n]*\n)*)',
                    r'\1  call void @record_compact_participant()\n',
                    producer, count=1, flags=re.M)
                assert visits == 1, f'@{name}: missing participation probe'
                producer, visits = re.subn(
                    r'(^(?:loop|inner):[^\n]*\n(?:[^\n]* = phi [^\n]*\n)*)',
                    r'\1  call void @record_compact_iteration()\n',
                    producer, count=1, flags=re.M)
                assert visits == 1, f'@{name}: missing producer iteration probe'
                return producer + 'scalar.fission.consumer.ph:\n' + instrumented
            return body.replace(consumer, instrumented, 1)
    return body


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
    scalar_rows, mixed_rows, constant_rows, nested_rows, diamond_rows = [], [], [], [], []
    compact_rows, compact_integer_rows, compact_nested_rows = [], [], []
    common = [
        '-passes=loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>',
        '-verify-each', '-mtriple=riscv64', '-mattr=+v',
        '-force-vector-interleave=1', '-hints-allow-reordering=false',
        '-enable-vplan-reduction-fission', '-vplan-reduction-fission-min-chain-depth=4',
        # Existing fixtures deliberately exercise the VPlan-only architecture.
        '-enable-scalar-reduction-fission=false',
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
        source = keep_functions(source, functions)
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
            for function in functions:
                body = function_definition(result.stdout, function)
                assert body.count('vector.fission.producer.body:') == 1, body
                assert body.count('vector.fission.accumulator.body:') == 1, body
                consumer = body.split('vector.fission.accumulator.body:')[1]
                assert re.search(r'@llvm.vector.reduce\.(?:add|fadd)\.', consumer), body
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

    # Exercise the early path with a helper which has no vector mapping. The
    # scalar helper is supplied by the C harness, not optimized into the IR.
    flags = [flag for flag in common
             if flag != '-enable-scalar-reduction-fission=false']
    flags += ['-force-vector-width=4', '-scalable-vectorization=always']
    for fixture, functions, location in [
        ('scalar-ir', ['scalar_helper_sum', 'arithmetic_sum', 'scalar_mixed',
                       'narrow_constant', 'one_iteration'], 'scalar-ir.c:12:3'),
        ('scalar-ir-nested', ['scalar_nested'], 'scalar-nested.c:22:5'),
        ('scalar-diamond', ['scalar_diamond', 'diamond_arithmetic',
                            'scalar_diamond_nested'], 'scalar-diamond.c:32:7'),
        ('scalar-compact', ['compact_triangle', 'compact_diamond',
                            'compact_integer', 'compact_nested'], 'scalar-compact.c:12:3'),
    ]:
        source = keep_functions((tests / f'reduction-fission-{fixture}.ll').read_text(),
                                functions)
        reference = source
        for function in functions:
            reference = reference.replace(f'@{function}(', f'@ref_{function}(')
        compile_ir(f'reference_{fixture}', reference)
        # The early path retains ordered FP independently of the separate
        # VPlan reassociation option. Exercise both option settings and keep
        # the default EVL artifact distinct from scalar-tail host execution.
        for relaxed in (False, True):
            for tail_policy in ('default-evl', 'scalar-remainder'):
                evl = tail_policy == 'default-evl'
                options = flags + (['-vplan-reduction-fission-allow-fp-reordering']
                                   if relaxed else [])
                if not evl:
                    options += ['-tail-folding-policy=dont-fold-tail',
                                '-enable-epilogue-vectorization=false']
                result = run([opt, *options], input=source)
                tag = f'{fixture}_{"option_on" if relaxed else "ordered"}_{tail_policy}'
                (work / f'{tag}.remarks').write_text(result.stderr)
                (work / f'{tag}.rvv.ll').write_text(result.stdout)
                assert result.stderr.count('split scalar-IR reduction loop;') == len(functions), result.stderr
                assert f'{location}: split scalar-IR reduction loop;' in result.stderr, result.stderr
                assert f'{location}: scalar-IR fission producer VF 1' in result.stderr, result.stderr
                assert f'{location}: scalar-IR fission consumer VF vscale x 4' in result.stderr, result.stderr
                if fixture == 'scalar-diamond':
                    for loc, size in [('32:7', 1044), ('42:3', 1040), ('62:5', 784)]:
                        assert re.search(
                            rf'scalar-diamond.c:{loc}: split scalar-IR reduction loop;[^\n]*'
                            rf'scratch capacity 65, scratch bytes {size}\b', result.stderr), result.stderr
                        assert (f'scalar-diamond.c:{loc}: scalar-IR fission consumer VF '
                                'vscale x 4') in result.stderr, result.stderr
                        assert (f'scalar-diamond.c:{loc}: scalar-IR fission producer VF '
                                in result.stderr), result.stderr
                    assert ('scalar-diamond.c:62:5: scalar-IR fission producer VF 1'
                            in result.stderr), result.stderr
                if fixture == 'scalar-compact':
                    for loc, size in [('12:3', 1044), ('22:5', 1044),
                                      ('32:7', 520), ('42:9', 784)]:
                        assert re.search(
                            rf'scalar-compact.c:{loc}: split scalar-IR reduction loop;[^\n]*'
                            rf'scratch capacity 65, scratch bytes {size}\b', result.stderr), result.stderr
                        assert (f'scalar-compact.c:{loc}: scalar-IR fission consumer VF '
                                'vscale x 4') in result.stderr, result.stderr
                        assert f'scalar-compact.c:{loc}: scalar-IR fission producer VF ' in result.stderr
                assert not re.search(r'\b(?:fadd|call)\s+[^\n]*\breassoc\b', result.stdout), result.stdout
                instrumented = result.stdout
                for function in functions:
                    body = function_definition(result.stdout, function)
                    checked = check_scalar_function(result.stdout, function, evl,
                                                    probe=not evl)
                    instrumented = instrumented.replace(body, checked, 1)
                # Uninstrumented RVV codegen is independent of host execution.
                run([llc, '-mtriple=riscv64', '-mattr=+v', '-verify-machineinstrs',
                     '-o', str(work / f'{tag}.s')], input=result.stdout)
                if evl:
                    records.append({'fixture': fixture, 'fp_reordering_option': relaxed,
                                    'tail_policy': tail_policy,
                                    'validation': 'RVV codegen and machine verification only',
                                    'executed': False, 'options': options,
                                    'selection_remarks': result.stderr})
                    print(f'RVV codegen verified {tag} (not executed)', flush=True)
                    continue
                instrumented += '\ndeclare void @record_scalar_consumer_vector()\n'
                if fixture in ('scalar-diamond', 'scalar-compact'):
                    instrumented += '\ndeclare void @record_scalar_consumer_tail()\n'
                if fixture == 'scalar-compact':
                    instrumented += ('\ndeclare void @record_compact_participant()\n'
                                     'declare void @record_compact_iteration()\n')
                for scale in args.vscales:
                    fixed = specialize(instrumented, scale)
                    for function in functions:
                        name = f'{function}_{"option_on" if relaxed else "o"}_s{scale}'
                        fixed = fixed.replace(f'@{function}(', f'@{name}(')
                        if function in ('compact_triangle', 'compact_diamond'):
                            declarations.append(f'extern ScalarMixedFn {name};')
                            compact_rows.append(f'{{"{name}", {name}, ref_{function}, {4 * scale}}}')
                        elif function == 'compact_integer':
                            declarations.append(f'extern ScalarSumFn {name};')
                            compact_integer_rows.append(f'{{"{name}", {name}, ref_{function}, {4 * scale}}}')
                        elif function == 'compact_nested':
                            declarations.append(f'extern ScalarNestedFn {name};')
                            compact_nested_rows.append(f'{{"{name}", {name}, ref_{function}, {4 * scale}}}')
                        elif function in ('scalar_helper_sum', 'arithmetic_sum',
                                        'diamond_arithmetic'):
                            declarations.append(f'extern ScalarSumFn {name};')
                            scalar_rows.append(f'{{"{name}", {name}, ref_{function}, {4 * scale}}}')
                        elif function == 'scalar_mixed':
                            declarations.append(f'extern ScalarMixedFn {name};')
                            mixed_rows.append(f'{{"{name}", {name}, {4 * scale}}}')
                        elif function == 'scalar_diamond':
                            declarations.append(f'extern ScalarMixedFn {name};')
                            diamond_rows.append(f'{{"{name}", {name}, {4 * scale}}}')
                        elif function in ('scalar_nested', 'scalar_diamond_nested'):
                            declarations.append(f'extern ScalarNestedFn {name};')
                            nested_rows.append(f'{{"{name}", {name}, ref_{function}, {4 * scale}, '
                                               f'{str(function == "scalar_diamond_nested").lower()}}}')
                        else:
                            declarations.append(f'extern ScalarConstantFn {name};')
                            constant_rows.append(f'{{"{name}", {name}, ref_{function}, false}}')
                    compile_ir(f'{tag}_s{scale}', fixed)
                    records.append({'fixture': fixture, 'fp_reordering_option': relaxed,
                                    'tail_policy': tail_policy,
                                    'comparison': ('exact integer/non-NaN FP bits; NaN classification'
                                                   if fixture == 'scalar-compact' else
                                                   'exact, including ordered FP'),
                                    'vector_execution': 'host-only consumer entry probe',
                                    'scalar_tail_probe': fixture in ('scalar-diamond', 'scalar-compact'),
                                    'producer_iteration_and_participant_probes': fixture == 'scalar-compact',
                                    'vscale': scale, 'options': options,
                                    'selection_remarks': result.stderr})
                    print(f'Built host scalar-tail variant {tag}, vscale={scale}', flush=True)

    # The scalable vectorizer can conservatively retain a scalar consumer for
    # the i8 IV. Also exercise its supported fixed VF=4 consumer, with an entry
    # probe, so the narrow-index comparison cannot pass using scalar code alone.
    source = keep_functions((tests / 'reduction-fission-scalar-ir.ll').read_text(),
                            ['narrow_constant'])
    for relaxed in (False, True):
        options = [flag for flag in flags if flag != '-scalable-vectorization=always']
        options += ['-scalable-vectorization=off', '-tail-folding-policy=dont-fold-tail',
                    '-enable-epilogue-vectorization=false']
        if relaxed:
            options.append('-vplan-reduction-fission-allow-fp-reordering')
        result = run([opt, *options], input=source)
        tag = f'narrow_fixed_{"option_on" if relaxed else "ordered"}'
        (work / f'{tag}.remarks').write_text(result.stderr)
        (work / f'{tag}.rvv.ll').write_text(result.stdout)
        assert result.stderr.count('split scalar-IR reduction loop;') == 1, result.stderr
        body = function_definition(result.stdout, 'narrow_constant')
        instrumented = result.stdout.replace(
            body, check_scalar_function(result.stdout, 'narrow_constant', evl=False,
                                        probe=True, fixed_narrow=True), 1)
        run([llc, '-mtriple=riscv64', '-mattr=+v', '-verify-machineinstrs',
             '-o', str(work / f'{tag}.s')], input=result.stdout)
        instrumented += '\ndeclare void @record_scalar_consumer_vector()\n'
        name = f'narrow_constant_{tag}'
        compile_ir(tag, specialize(instrumented, 1).replace('@narrow_constant(', f'@{name}('))
        declarations.append(f'extern ScalarConstantFn {name};')
        constant_rows.append(f'{{"{name}", {name}, ref_narrow_constant, true}}')
        records.append({'fixture': 'scalar-ir-narrow-fixed',
                        'fp_reordering_option': relaxed, 'vf': 4,
                        'tail_policy': 'dont-fold-tail',
                        'comparison': 'exact integer',
                        'vector_execution': 'host-only consumer entry probe',
                        'options': options, 'selection_remarks': result.stderr})

    harness = (root / 'llvm/utils/reduction-fission-execution.c.in').read_text()
    for key, rows in [('DECLARATIONS', declarations), ('COMBINED', combined_rows),
                      ('INDUCTIONS', induction_rows), ('FP', fp_rows),
                      ('SCALARS', scalar_rows), ('SCALAR_MIXED', mixed_rows),
                      ('SCALAR_CONSTANTS', constant_rows),
                      ('SCALAR_NESTED', nested_rows), ('SCALAR_DIAMOND', diamond_rows),
                      ('COMPACT', compact_rows), ('COMPACT_INTEGER', compact_integer_rows),
                      ('COMPACT_NESTED', compact_nested_rows)]:
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
        'scalar_ir_runtime_trip_counts': [0, 1, 2, 3, 4, 5, 7, 8, 9, 15, 16, 17, 31,
                                         32, 33, 63, 64, 65, 66, 2**64 - 1],
        'scalar_ir_constant_trip_counts': [1, 200],
        'scalar_ir_nested_outer_counts': [0, 1, 2, 4, 5, 2**64 - 1],
        'scalar_diamond_branch_sequences': ['all division (null FP input)',
                                            'all load (zero divisors)',
                                            'alternating', 'runs', 'random'],
        'compact_participant_counts': list(range(66)),
        'compact_probes': 'exact original iteration, participating arm, vector consumer '
                          'and scalar-tail counts; per-row counts for nests and aliases',
        'compact_fp_comparison': 'bitwise for all non-NaN results, including signed zero; '
                                 'NaN classification without payload assumptions',
        'scalar_ir_host_tail_policy': 'dont-fold-tail, scalar remainder',
        'scalar_ir_default_evl': 'RVV codegen/machine verification only, not executed',
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
