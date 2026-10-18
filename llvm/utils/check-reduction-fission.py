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


command_log_dir = None


def run(command, **kwargs):
    command = [str(arg) for arg in command]
    if command_log_dir:
        with (command_log_dir / 'commands.jsonl').open('a') as log:
            log.write(json.dumps({'command': command}) + '\n')
    try:
        return subprocess.run(command, check=True, text=True, capture_output=True, **kwargs)
    except subprocess.CalledProcessError as error:
        if command_log_dir:
            (command_log_dir / 'failed-command.json').write_text(json.dumps({
                'command': command, 'exit_code': error.returncode,
                'stdout': error.stdout, 'stderr': error.stderr,
            }, indent=2) + '\n')
            if 'input' in kwargs:
                (command_log_dir / 'failed-command.stdin').write_text(kwargs['input'])
        raise


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


def check_compact_count(producer, consumer, name, evl):
    # These fixtures have one i64 compact counter and one latch. SCEV can
    # forward the single-input LCSSA export to its incoming latch value when
    # expanding the consumer trip count. A later LV invocation forms LCSSA
    # again, exporting that latch value through merge.lcssa in the guard.
    # Accept only these demonstrated forms, after checking their linkage and
    # entry edges. This is a bounded fixture check, not an equivalence solver.
    def require(pattern, text):
        match = re.search(pattern, text, re.M)
        assert match, f'@{name}: compact count provenance: {pattern}\n{text}'
        return match

    def block(text, label):
        return require(rf'^{re.escape(label)}:[^\n]*\n'
                       r'((?s:.*?))(?=^[\w.$-]+:|^}|\Z)', text)[1]

    def branch(text, condition, on_true, on_false):
        require(rf'^  br i1 {re.escape(condition)}, label %{re.escape(on_true)}, '
                rf'label %{re.escape(on_false)}(?:, ![^\n]*)?$', text)

    whole = producer + 'scalar.fission.consumer.ph:\n' + consumer

    def single_entry(label, predecessor):
        # Each of these fixture blocks has exactly one incoming branch edge.
        # Together with the named source block this checks the small dominance
        # chain, without trusting printed predecessor comments or PHI spelling.
        edge = rf'\blabel %{re.escape(label)}(?=[,\s]|$)'
        assert len(re.findall(edge, whole)) == 1, whole
        require(rf'^  br [^\n]*{edge}', predecessor)

    counter = '%fission.participating'
    merged, exported = counter + '.merge', counter + '.count'
    header = 'inner' if name == 'compact_nested' else 'loop'
    preheader = 'inner.ph' if name == 'compact_nested' else 'preheader'

    def phi_inputs(text, value, ty='i64'):
        line = require(rf'^  {re.escape(value)} = phi {ty} '
                       r'(.+?)(?:, ![^\n]*)?$', text)[1]
        inputs = re.findall(r'\[ ([^,\]\n]+), (%[-\w.$]+) \]', line)
        # Do not silently ignore a malformed or additional incoming operand.
        assert ', '.join(f'[ {v}, {edge} ]' for v, edge in inputs) == line, line
        return inputs

    assert phi_inputs(block(producer, header), counter) == [
        ('0', '%' + preheader), (merged, '%latch')], producer
    assert sorted(phi_inputs(block(producer, 'latch'), merged)) == sorted([
        (counter + '.next', '%left'),
        (counter, '%' + ('right' if name in ('compact_diamond', 'compact_nested')
                         else header))]), producer
    require(r'^  %fission\.participating\.next = add nuw i64 '
            r'%fission\.participating, 1(?:, ![^\n]*)?$', block(producer, 'left'))
    guard = block(producer, 'scalar.fission.consumer.guard')
    single_entry('scalar.fission.consumer.guard', block(producer, 'latch'))
    single_entry('scalar.fission.consumer.ph', guard)
    assert phi_inputs(guard, exported) == [(merged, '%latch')], guard
    count_values = [merged, exported]
    forwarded = merged + '.lcssa'
    if re.search(rf'^  {re.escape(forwarded)} = ', whole, re.M):
        assert phi_inputs(guard, forwarded) == [(merged, '%latch')], guard
        count_values.append(forwarded)
    counts = '(?:' + '|'.join(map(re.escape, count_values)) + ')'
    require(rf'^  %fission\.empty = icmp eq i64 {counts}, 0$', guard)
    branch(guard, '%fission.empty', 'scalar.fission.consumer.exit',
           'scalar.fission.consumer.ph')

    starts = {
        'compact_triangle': [('r0', 'i32', '17'), ('r1', 'i32', '-7'),
                             ('rd', 'double', '%start'), ('rf', 'float', '%fstart')],
        'compact_diamond': [('r0', 'i32', '17'), ('r1', 'i32', '-7'),
                            ('rd', 'double', '%start'), ('rf', 'float', '%fstart')],
        'compact_integer': [('sum', 'i64', '%initial'), ('sum2', 'i64', '0')],
        'compact_nested': [('sum', 'i32', '%carry'), ('dsum', 'double', '%dcarry')],
    }
    exit_block = block(consumer, 'scalar.fission.consumer.exit')
    results = {}
    for value, ty, start in starts[name]:
        inputs = phi_inputs(exit_block, f'%{value}.result', ty)
        assert len(inputs) == 2, exit_block
        assert inputs[0] == (start, '%scalar.fission.consumer.guard'), exit_block
        assert inputs[1][1] == '%scalar.fission.consumer.loopexit', exit_block
        assert re.fullmatch(r'%[-\w.$]+', inputs[1][0]), exit_block
        results[value] = inputs[1][0]

    vector = block(consumer, 'vector.body')
    if evl:
        entry = re.split(r'^[\w.$-]+:', consumer, maxsplit=1, flags=re.M)[0]
        single_entry('vector.ph', entry)
        require(r'^  br label %vector\.body(?:, ![^\n]*)?$', block(consumer, 'vector.ph'))
        require(rf'^  %avl = phi i64 \[ {counts}, %vector\.ph \], '
                r'\[ %avl\.next, %vector\.body \]', vector)
        length = require(r'^  (%[-\w.$]+) = call i32 '
                         r'@llvm\.experimental\.get\.vector\.length\.i64'
                         r'\(i64 %avl, i32 4, i1 true\)', vector)[1]
        step = require(rf'^  (%[-\w.$]+) = zext i32 {re.escape(length)} to i64', vector)[1]
        require(rf'^  %avl\.next = sub nuw i64 %avl, {re.escape(step)}(?:, ![^\n]*)?$', vector)
        for line in vector.splitlines():
            if re.search(r'@llvm\.vp\.(?:load|reduce\.fadd)\.', line):
                require(rf', i32 {re.escape(length)}\)(?:, ![^\n]*)?$', line)
        done = require(r'^  (%[-\w.$]+) = icmp eq i64 %avl\.next, 0(?:, ![^\n]*)?$', vector)[1]
        branch(vector, done, 'middle.block', 'vector.body')
        # The second LV also forwards ordered FP results out of vector.body.
        # Accept either the actual result or exactly one single-input PHI in
        # middle.block on that edge. Scalar integer reductions are already in
        # middle.block. Keep every empty-path start and the nonempty join edge.
        middle = block(consumer, 'middle.block')
        single_entry('middle.block', vector)
        single_entry('scalar.fission.consumer.loopexit', middle)
        require(r'^  br label %scalar\.fission\.consumer\.exit(?:, ![^\n]*)?$',
                block(consumer, 'scalar.fission.consumer.loopexit'))
        integers = re.findall(r'^  (%[-\w.$]+) = call i(?:32|64) '
                              r'@llvm\.vector\.reduce\.add\.nxv4i(?:32|64)\(', middle, re.M)
        integer_starts = [value for value, ty, _ in starts[name] if ty.startswith('i')]
        assert [results[value] for value in integer_starts] == integers, exit_block
        for value, ty, _ in starts[name]:
            if ty.startswith('i'):
                continue
            reduced = require(rf'^  (%[-\w.$]+) = call {ty} '
                              r'@llvm\.vp\.reduce\.fadd\.', vector)[1]
            if results[value] != reduced:
                assert phi_inputs(middle, results[value], ty) == [
                    (reduced, '%vector.body')], middle
    else:
        # Check the vector bound's rounding input, its bypass/tail checks, and
        # the scalar tail's terminating bound. Incidental/dead uses do not count.
        require(rf'^  %min\.iters\.check = icmp ult i64 {counts}, %[-\w.$]+', consumer)
        branch(consumer, '%min.iters.check', 'scalar.ph', 'vector.ph')
        rounding = block(consumer, 'vector.ph')
        require(rf'^  %n\.mod\.vf = urem i64 {counts}, %[-\w.$]+', rounding)
        require(rf'^  %n\.vec = sub i64 {counts}, %n\.mod\.vf(?:, ![^\n]*)?$', rounding)
        done = require(r'^  (%[-\w.$]+) = icmp eq i64 %[-\w.$]+, %n\.vec(?:, ![^\n]*)?$', vector)[1]
        branch(vector, done, 'middle.block', 'vector.body')
        middle = block(consumer, 'middle.block')
        require(rf'^  %cmp\.n = icmp eq i64 {counts}, %n\.vec(?:, ![^\n]*)?$', middle)
        branch(middle, '%cmp.n', 'scalar.fission.consumer.loopexit', 'scalar.ph')
        tail = block(consumer, 'scalar.fission.consumer.body')
        require(r'^  %fission\.consumer\.more = icmp ne i64 '
                rf'%fission\.consumer\.next, {counts}(?:, ![^\n]*)?$', tail)
        branch(tail, '%fission.consumer.more', 'scalar.fission.consumer.body',
               'scalar.fission.consumer.loopexit')


def check_scalar_function(ir, name, evl, probe=False, fixed_narrow=False):
    body = function_definition(ir, name)
    producer, consumer = scalar_consumer(body, name)
    compact = name.startswith('compact_')
    acyclic = name in ('acyclic_serial', 'acyclic_nested', 'acyclic_three_way', 'acyclic_enclosing')
    if acyclic:
        enclosing = name == 'acyclic_enclosing'
        assert producer.count('call i32 @scalar_helper(') == 1, producer
        assert producer.count('load i32,') == 1, producer
        assert producer.count('load double,') == 1, producer
        assert '<vscale x' not in producer and 'fadd ' not in producer, producer
        assert body.count('alloca [65 x i32]') == 1, body
        assert body.count('alloca [65 x double]') == 1, body
        assert body.count('alloca [65 x float]') == (0 if enclosing else 1), body
        # Compare all retained producer edges and contribution PHIs to the
        # original fixture. Neither block order nor debug metadata IDs matter.
        source = (Path(__file__).resolve().parents[1] /
                  'test/Transforms/LoopVectorize/RISCV/'
                  'reduction-fission-scalar-acyclic.ll').read_text()
        original = function_definition(source, name)

        def blocks(text):
            return dict(re.findall(r'^([-\w.$]+):[^\n]*\n(.*?)'
                                   r'(?=^[-\w.$]+:|^}|\Z)', text, re.M | re.S))

        before, after = blocks(original), blocks(producer)
        header = 'inner' if enclosing else 'loop'
        labels = list(before)
        labels = labels[labels.index(header):labels.index('latch') + 1]
        def normalize(line):
            return re.sub(r'\s+', '', line.split(', !')[0])
        for label in labels:
            assert label in after, producer
            if label != 'latch':
                edge = re.search(r'^  br [^\n]+', before[label], re.M)[0]
                assert normalize(edge) in normalize(after[label]), (name, label, producer)
            for phi in re.findall(r'^  %(?:first\.[cd]|inner\.[cd]|c|dc) = phi [^\n]+',
                                  before[label], re.M):
                assert normalize(phi) in normalize(after[label]), (name, label, producer)
        assert re.search(r'br i1 %done, label %scalar\.fission\.consumer\.ph, '
                         rf'label %{header}\b', after['latch']), producer
        assert after['latch'].count('store i32 %c,') == 1, producer
        assert after['latch'].count('store double %dc,') == 1, producer
        assert sum(block.count('store ') for label, block in after.items()
                   if label in labels and label != 'latch') == 0, producer
        if not enclosing:
            assert 'sdiv i32 840, %x' in after['left'], producer
            assert producer.count('sdiv ') == 1, producer
            assert 'load double, ptr %dp' in after['right'], producer
            assert producer.count('load double') == 1, producer
            assert after['latch'].count('store float %fc,') == 1, producer
        # The unconditional stream contains exactly N values, including tails.
        if evl:
            assert re.search(r'%avl = phi i64 \[ %n, %vector\.ph \]', consumer), consumer
        else:
            assert '%min.iters.check = icmp ult i64 %n,' in consumer, consumer
            assert '%n.mod.vf = urem i64 %n,' in consumer, consumer
            assert '%fission.consumer.done = icmp eq i64 %fission.consumer.next, %n' in consumer, consumer
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
        check_compact_count(producer, consumer, name, evl)
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
                          'diamond_arithmetic', 'scalar_diamond_nested') or compact or acyclic or fixed_narrow
    if vectorized:
        vector = re.search(r'^vector\.body[^:]*:[^\n]*\n(.*?)(?=^[\w.$-]+:|^})',
                           consumer, re.M | re.S)
        assert vector, f'@{name}: missing vector consumer\n{consumer}'
        if name in ('scalar_mixed', 'scalar_nested', 'scalar_diamond',
                    'scalar_diamond_nested', 'compact_triangle', 'compact_diamond',
                    'compact_nested', 'acyclic_serial', 'acyclic_nested', 'acyclic_three_way',
                    'acyclic_enclosing'):
            types = [('double', 'f64')]
            if name in ('scalar_mixed', 'scalar_diamond', 'compact_triangle', 'compact_diamond',
                        'acyclic_serial', 'acyclic_nested', 'acyclic_three_way'):
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
        if name in ('scalar_mixed', 'scalar_diamond', 'compact_triangle', 'compact_diamond',
                    'acyclic_serial', 'acyclic_nested', 'acyclic_three_way'):
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
            if name in ('scalar_diamond', 'scalar_diamond_nested') or compact or acyclic:
                instrumented, tails = re.subn(
                    r'(^scalar\.fission\.consumer\.body:[^\n]*\n(?:[^\n]* = phi [^\n]*\n)*)',
                    r'\1  call void @record_scalar_consumer_tail()\n',
                    instrumented, count=1, flags=re.M)
                assert tails == 1, f'@{name}: missing scalar-tail probe site'
            if acyclic:
                for label, recorder in [(header, 'iteration'), ('latch', 'latch')]:
                    producer, visits = re.subn(
                        rf'(^{label}:[^\n]*\n(?:[^\n]* = phi [^\n]*\n)*)',
                        rf'\1  call void @record_acyclic_{recorder}()\n',
                        producer, count=1, flags=re.M)
                    assert visits == 1, f'@{name}: missing producer {label} probe'
                return producer + 'scalar.fission.consumer.ph:\n' + instrumented
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


def check_affine_function(ir, source, name, evl, probe=False):
    """Check the exact retained control and the separate consumer of a fixture."""
    body = function_definition(ir, name)
    original = function_definition(source, name)
    producer, consumer = scalar_consumer(body, name)
    enclosing = name == 'affine_enclosing'
    compact = name == 'affine_compact'
    header, ph = ('inner', 'inner.ph') if enclosing else ('loop', 'preheader')

    def blocks(text):
        return dict(re.findall(r'^([-\w.$]+):[^\n]*\n(.*?)'
                               r'(?=^[-\w.$]+:|^}|\Z)', text, re.M | re.S))

    def normalize(line):
        # Normalize one complete instruction at a time. An attachment on an
        # earlier instruction must not hide the rest of its block, and a
        # retained instruction must not match a prefix or span two lines.
        line = line.split(', !', 1)[0]
        # The fixture's exact dyadic FP literals (3.0, 0.5, -1.0) print in
        # scientific notation after opt. Compare values as well as retaining
        # every opcode, operand order and flag, without relying on spelling.
        line = re.sub(r'(?<![\w.])(-?\d+\.\d+(?:[eE][+-]?\d+)?)(?![\w.])',
                      lambda m: float(m[0]).hex(), line)
        return re.sub(r'\s+', '', line)

    before, after = blocks(original), blocks(body)
    after_instructions = {
        label: {normalize(line) for line in block.splitlines() if line.strip()}
        for label, block in after.items()
    }
    labels = list(before)
    labels = labels[labels.index(header):labels.index('latch') + 1]
    # The fixtures deliberately use the IV in addressing and internal control.
    # Require every retained instruction/edge in its original block, including
    # flags and operand order. Only reduction state and the exit edge change.
    header_reduction = r'%(?:r0|r1|rd|rf|sum|dsum) = phi '
    update = r'%(?:u0|u1|ud|uf|update|dupdate) = '
    merge = r'%(?:m0|m1|md|mf) = phi '
    for label in ['entry', ph] + labels:
        for line in before[label].splitlines():
            if (not line.strip() or re.match(r'  ' + update, line) or
                (label == header and re.match(r'  ' + header_reduction, line)) or
                (compact and label == 'latch' and re.match(r'  ' + merge, line))):
                continue
            if label == 'latch' and line.strip().startswith('br '):
                old_exit = 'row.exit' if enclosing else 'exit'
                new_exit = ('scalar.fission.consumer.guard' if compact
                            else 'scalar.fission.consumer.ph')
                line = line.replace('label %' + old_exit, 'label %' + new_exit)
            assert normalize(line) in after_instructions[label], (name, label, line, body)
    assert '<vscale x' not in producer and 'fadd ' not in producer, producer
    assert producer.count('call i32 @scalar_helper(') == 1, producer
    for ty in ['i32', 'double'] + ([] if enclosing else ['float']):
        assert body.count(f'alloca [65 x {ty}]') == 1, body
    assert producer.count('load i32,') == 1, producer
    assert producer.count('load double,') == 1, producer
    active = after['left'] if compact else after['latch']
    assert active.count('store ') == (2 if enclosing else 3), body
    ordinal = '%fission.participating' if compact else '%fission.ordinal'
    addresses = re.findall(r'^  (%[-\w.$]+) = getelementptr inbounds '
                           r'\[65 x (?:i32|double|float)\], ptr %scalar.fission.scratch[\d]*, '
                           rf'i32 0, i64 {re.escape(ordinal)}(?:, ![^\n]*)?$', active, re.M)
    assert len(addresses) == (2 if enclosing else 3), body
    for address in addresses:
        assert re.search(rf'^  store (?:i32|double|float) %[-\w.$]+, '
                         rf'ptr {re.escape(address)},', active, re.M), body
    for label in labels:
        if label != ('left' if compact else 'latch'):
            assert 'store ' not in after[label], body
    if not enclosing:
        assert 'sdiv i32 840, %x' in after['left'], body
        assert producer.count('sdiv ') == 1, body
    if compact:
        # Same narrow triangle, counters, P=0 results and count provenance as
        # the accepted compact fixture. Its original induction is now strided.
        check_compact_count(producer, consumer, 'compact_triangle', evl)
    else:
        assert (f'%fission.ordinal = phi i64 [ 0, %{ph} ], '
                '[ %fission.completed, %latch ]') in producer, body
        assert '%fission.completed = add nuw i64 %fission.ordinal, 1' in producer, body
        assert re.search(r'^  %fission.completed.count = phi i64 '
                         r'\[ %fission.completed, %latch \]', consumer, re.M), body
        # For the original fixtures, the preserved arithmetic proves N=n and
        # SE may use n as the exit value of the ordinal. The modular relational
        # siblings may exit earlier and must use the actual completed count.
        # Other accepted aliases must be single-input exports on the latch edge.
        counts = ['%fission.completed', '%fission.completed.count']
        if not name.endswith('_early'):
            counts.append('%n')
        for value, incoming in re.findall(
                r'^  (%[-\w.$]+) = phi i64 \[ (%[-\w.$]+), %latch \](?:, ![^\n]*)?$',
                consumer, re.M):
            if incoming == '%fission.completed':
                counts.append(value)
        count = '(?:' + '|'.join(map(re.escape, counts)) + ')'
        if evl:
            assert re.search(rf'%avl = phi i64 \[ {count}, %vector\.ph \]', consumer), body
        else:
            for instruction in [rf'%min.iters.check = icmp ult i64 {count},',
                                rf'%n.mod.vf = urem i64 {count},',
                                rf'%fission.consumer.more = icmp ne i64 '
                                rf'%fission.consumer.next, {count}']:
                assert re.search(instruction, consumer), (name, instruction, body)
    vector = re.search(r'^vector\.body[^:]*:[^\n]*\n(.*?)(?=^[\w.$-]+:|^})',
                       consumer, re.M | re.S)
    assert vector, f'@{name}: missing vector consumer\n{body}'
    intrinsic = r'vp\.reduce' if evl else r'vector\.reduce'
    for ty, suffix in [('double', 'f64')] + ([] if enclosing else [('float', 'f32')]):
        assert re.search(rf'call {ty} @llvm\.{intrinsic}\.fadd\.nxv4{suffix}\(', vector[0]), body
    assert '@llvm.vector.reduce.add.nxv4i32' in consumer, body
    load = r'call <vscale x 4 x i32> @llvm\.vp\.load\.' if evl else r'load <vscale x 4 x i32>'
    assert len(re.findall(load, vector[0])) == 1, body
    assert not re.search(r'\b(?:fadd|call)\s+[^\n]*\breassoc\b', body), body
    if probe:
        for label, recorder in [(header, 'acyclic_iteration'), ('latch', 'acyclic_latch'),
                                ('vector.body', 'scalar_consumer_vector'),
                                ('scalar.fission.consumer.body', 'scalar_consumer_tail')] + (
                                    [('left', 'compact_participant')] if compact else []):
            body, sites = re.subn(
                rf'(^{re.escape(label)}:[^\n]*\n(?:[^\n]* = phi [^\n]*\n)*)',
                rf'\1  call void @record_{recorder}()\n', body, count=1, flags=re.M)
            assert sites == 1, (name, label, body)
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
    global command_log_dir
    command_log_dir = work
    root = Path(__file__).resolve().parents[2]
    tests = root / 'llvm/test/Transforms/LoopVectorize/RISCV'
    opt, llc = (args.build_dir / 'bin' / name for name in ('opt', 'llc'))
    triple = run([args.cc, '-dumpmachine']).stdout.strip()
    objects, records = [], []
    declarations, combined_rows, induction_rows, fp_rows = [], [], [], []
    scalar_rows, mixed_rows, constant_rows, nested_rows, diamond_rows = [], [], [], [], []
    compact_rows, compact_integer_rows, compact_nested_rows = [], [], []
    acyclic_rows = []
    acyclic_bound_rows = []
    affine_rows = []
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
        ('scalar-acyclic', ['acyclic_serial', 'acyclic_nested', 'acyclic_three_way',
                            'acyclic_enclosing'], 'scalar-acyclic.c:12:3'),
        ('scalar-affine', ['affine_const', 'affine_runtime', 'affine_unsigned',
                           'affine_signed', 'affine_down', 'affine_signed_down',
                           'affine_compact', 'affine_enclosing', 'affine_wrap',
                           'affine_current', 'affine_unsigned_early',
                           'affine_signed_early', 'affine_down_early',
                           'affine_signed_down_early'], 'scalar-affine.c:12:3'),
    ]:
        source = keep_functions((tests / f'reduction-fission-{fixture}.ll').read_text(),
                                functions)
        reference = source
        for function in functions:
            reference = reference.replace(f'@{function}(', f'@ref_{function}(')
        compile_ir(f'reference_{fixture}', reference)
        if fixture == 'scalar-affine':
            for function in functions:
                ty = 'ScalarNestedFn' if function == 'affine_enclosing' else 'AffineFn'
                declarations.append(f'extern {ty} ref_{function};')
        # The early path retains ordered FP independently of the separate
        # VPlan reassociation option. Exercise both option settings and keep
        # the default EVL artifact distinct from scalar-tail host execution.
        for relaxed, repeats in [(r, n) for r in (False, True)
                                 for n in ((1, 2) if fixture in ('scalar-acyclic', 'scalar-affine') else (1,))]:
            for tail_policy in ('default-evl', 'scalar-remainder'):
                evl = tail_policy == 'default-evl'
                options = flags + (['-vplan-reduction-fission-allow-fp-reordering']
                                   if relaxed else [])
                if repeats == 2:
                    options = [option.replace('-passes=loop-vectorize,',
                                              '-passes=loop-vectorize,loop-vectorize,')
                               for option in options]
                if not evl:
                    options += ['-tail-folding-policy=dont-fold-tail',
                                '-enable-epilogue-vectorization=false']
                result = run([opt, *options], input=source)
                tag = f'{fixture}_{"option_on" if relaxed else "ordered"}_{tail_policy}'
                if fixture in ('scalar-acyclic', 'scalar-affine'):
                    tag += f'_lv{repeats}'
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
                if fixture == 'scalar-acyclic':
                    for loc, size in [('12:3', 1044), ('22:5', 1044), ('42:9', 1044), ('32:7', 784)]:
                        assert re.search(
                            rf'scalar-acyclic.c:{loc}: split scalar-IR reduction loop;[^\n]*'
                            rf'scratch capacity 65, scratch bytes {size}\b', result.stderr), result.stderr
                        for stage, vf in [('producer', '1'), ('consumer', 'vscale x 4')]:
                            assert (f'scalar-acyclic.c:{loc}: scalar-IR fission {stage} VF {vf}'
                                    in result.stderr), result.stderr
                if fixture == 'scalar-affine':
                    for line in range(12, 143, 10):
                        size = 784 if line == 82 else 1044
                        assert re.search(
                            rf'scalar-affine.c:{line}:3: split scalar-IR reduction loop;[^\n]*'
                            rf'scratch capacity 65, scratch bytes {size}\b', result.stderr), result.stderr
                        for stage, vf in [('producer', '1'), ('consumer', 'vscale x 4')]:
                            assert (f'scalar-affine.c:{line}:3: scalar-IR fission {stage} VF {vf}'
                                    in result.stderr), result.stderr
                assert not re.search(r'\b(?:fadd|call)\s+[^\n]*\breassoc\b', result.stdout), result.stdout
                instrumented = result.stdout
                for function in functions:
                    body = function_definition(result.stdout, function)
                    if fixture == 'scalar-affine':
                        checked = check_affine_function(result.stdout, source, function, evl,
                                                        probe=not evl)
                    else:
                        checked = check_scalar_function(result.stdout, function, evl,
                                                        probe=not evl)
                    instrumented = instrumented.replace(body, checked, 1)
                # Uninstrumented RVV codegen is independent of host execution.
                run([llc, '-mtriple=riscv64', '-mattr=+v', '-verify-machineinstrs',
                     '-o', str(work / f'{tag}.s')], input=result.stdout)
                if evl:
                    records.append({'fixture': fixture, 'fp_reordering_option': relaxed,
                                    'loop_vectorize_invocations': repeats,
                                    'tail_policy': tail_policy,
                                    'validation': 'RVV codegen and machine verification only',
                                    'executed': False, 'options': options,
                                    'selection_remarks': result.stderr})
                    print(f'RVV codegen verified {tag} (not executed)', flush=True)
                    continue
                instrumented += '\ndeclare void @record_scalar_consumer_vector()\n'
                if fixture in ('scalar-diamond', 'scalar-compact', 'scalar-acyclic', 'scalar-affine'):
                    instrumented += '\ndeclare void @record_scalar_consumer_tail()\n'
                if fixture == 'scalar-compact':
                    instrumented += ('\ndeclare void @record_compact_participant()\n'
                                     'declare void @record_compact_iteration()\n')
                if fixture in ('scalar-acyclic', 'scalar-affine'):
                    instrumented += ('\ndeclare void @record_acyclic_iteration()\n'
                                     'declare void @record_acyclic_latch()\n')
                if fixture == 'scalar-affine':
                    instrumented += '\ndeclare void @record_compact_participant()\n'
                for scale in args.vscales:
                    fixed = specialize(instrumented, scale)
                    for function in functions:
                        name = f'{function}_{"option_on" if relaxed else "o"}_s{scale}'
                        if fixture in ('scalar-acyclic', 'scalar-affine'):
                            name += f'_lv{repeats}'
                        fixed = fixed.replace(f'@{function}(', f'@{name}(')
                        if function.startswith('affine_') and function != 'affine_enclosing':
                            declarations.append(f'extern AffineFn {name};')
                            control = {'affine_unsigned_early': 1, 'affine_signed_early': 2,
                                       'affine_down_early': 3, 'affine_signed_down_early': 4}.get(function, 0)
                            affine_rows.append(f'{{"{name}", {name}, ref_{function}, {4 * scale}, '
                                               f'{str(function == "affine_signed_down").lower()}, '
                                               f'{str(function == "affine_compact").lower()}, {control}}}')
                        elif function in ('compact_triangle', 'compact_diamond'):
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
                        elif function in ('acyclic_serial', 'acyclic_nested', 'acyclic_three_way'):
                            declarations.append(f'extern ScalarMixedFn {name};')
                            acyclic_rows.append(f'{{"{name}", {name}, ref_{function}, {4 * scale}, '
                                                f'{str(function != "acyclic_serial").lower()}}}')
                        elif function in ('scalar_nested', 'scalar_diamond_nested', 'acyclic_enclosing', 'affine_enclosing'):
                            declarations.append(f'extern ScalarNestedFn {name};')
                            nested_rows.append(f'{{"{name}", {name}, ref_{function}, {4 * scale}, '
                                               f'{str(function != "scalar_nested").lower()}, '
                                               f'{str(function in ("acyclic_enclosing", "affine_enclosing")).lower()}}}')
                        else:
                            declarations.append(f'extern ScalarConstantFn {name};')
                            constant_rows.append(f'{{"{name}", {name}, ref_{function}, false}}')
                    compile_ir(f'{tag}_s{scale}', fixed)
                    records.append({'fixture': fixture, 'fp_reordering_option': relaxed,
                                    'loop_vectorize_invocations': repeats,
                                    'tail_policy': tail_policy,
                                    'comparison': ('exact integer/non-NaN FP bits; NaN classification'
                                                   if fixture in ('scalar-compact', 'scalar-acyclic', 'scalar-affine') else
                                                   'exact, including ordered FP'),
                                    'vector_execution': 'host-only consumer entry probe',
                                    'scalar_tail_probe': fixture in ('scalar-diamond', 'scalar-compact', 'scalar-acyclic', 'scalar-affine'),
                                    'producer_iteration_and_participant_probes': fixture == 'scalar-compact',
                                    'producer_iteration_and_latch_probes': fixture in ('scalar-acyclic', 'scalar-affine'),
                                    'affine_compact_participant_probe': fixture == 'scalar-affine',
                                    'vscale': scale, 'options': options,
                                    'selection_remarks': result.stderr})
                    print(f'Built host scalar-tail variant {tag}, vscale={scale}', flush=True)

    # Execute the actual split at the representable IV and default scratch
    # ceilings too. These are deliberately scalar stages; the mixed acyclic
    # fixtures above separately prove vector and tail execution.
    for fixture, bounds in [
        ('scalar-acyclic', [('acyclic_one', 1), ('acyclic_i8_max', 255),
                            ('acyclic_default_limit', 16384)]),
        ('scalar-affine', [('affine_one', 1), ('affine_i8_max', 255),
                           ('affine_default_limit', 16384),
                           ('affine_relational_limit', 16384),
                           ('affine_relational_i8_max', 255)]),
    ]:
        source = keep_functions((tests / f'reduction-fission-{fixture}-bounds.ll').read_text(),
                                [name for name, _ in bounds])
        reference = source
        for function, _ in bounds:
            reference = reference.replace(f'@{function}(', f'@ref_{function}(')
        compile_ir(f'reference_{fixture}_bounds', reference)
        for relaxed, repeats in [(r, n) for r in (False, True)
                                 for n in ((1, 2) if fixture == 'scalar-affine' else (1,))]:
            options = [flag for flag in common if flag != '-enable-scalar-reduction-fission=false'
                       and flag != '-force-vector-interleave=1']
            options += ['-force-vector-width=1', '-force-vector-interleave=0',
                        '-force-target-max-scalar-interleave=1', '-scalable-vectorization=off']
            if relaxed:
                options += ['-vplan-reduction-fission-allow-fp-reordering']
            if repeats == 2:
                options = [option.replace('-passes=loop-vectorize,',
                                          '-passes=loop-vectorize,loop-vectorize,')
                           for option in options]
            result = run([opt, *options], input=source)
            tag = f'{fixture}_bounds_{"option_on" if relaxed else "ordered"}_lv{repeats}'
            (work / f'{tag}.remarks').write_text(result.stderr)
            (work / f'{tag}.rvv.ll').write_text(result.stdout)
            assert result.stderr.count('split scalar-IR reduction loop;') == len(bounds), result.stderr
            run([llc, '-mtriple=riscv64', '-mattr=+v', '-verify-machineinstrs',
                 '-o', str(work / f'{tag}.s')], input=result.stdout)
            instrumented = result.stdout
            for function, count in bounds:
                body = function_definition(result.stdout, function)
                producer, consumer = scalar_consumer(body, function)
                assert body.count(f'alloca [{count} x i32]') == 1, body
                assert '<vscale x' not in body and 'vector.body:' not in body, body
                assert 'store i32 %c,' in producer, body
                if fixture == 'scalar-affine':
                    assert '%fission.ordinal = phi ' in producer, body
                    assert '%fission.completed = add nuw ' in producer, body
                    assert re.search(r'%fission.completed.count = phi i(?:8|32) '
                                     r'\[ %fission.completed, %latch \]', consumer), body
                    assert re.search(r'%fission.consumer.next = add nuw i(?:8|32) '
                                     r'%fission.consumer.iv, 1', consumer), body
                for label, recorder in [('loop', 'acyclic_iteration'), ('latch', 'acyclic_latch')]:
                    producer, visits = re.subn(
                        rf'(^{label}:[^\n]*\n(?:[^\n]* = phi [^\n]*\n)*)',
                        rf'\1  call void @record_{recorder}()\n', producer, count=1, flags=re.M)
                    assert visits == 1, body
                consumer, visits = re.subn(
                    r'(^scalar\.fission\.consumer\.body:[^\n]*\n(?:[^\n]* = phi [^\n]*\n)*)',
                    r'\1  call void @record_scalar_consumer_tail()\n', consumer, count=1, flags=re.M)
                assert visits == 1, body
                instrumented = instrumented.replace(
                    body, producer + 'scalar.fission.consumer.ph:\n' + consumer, 1)
                name = f'{function}_{tag}'
                instrumented = instrumented.replace(f'@{function}(', f'@{name}(')
                declarations.append(f'extern ScalarConstantFn {name}, ref_{function};')
                acyclic_bound_rows.append(f'{{"{name}", {name}, ref_{function}, {count}}}')
            instrumented += ('\ndeclare void @record_acyclic_iteration()\n'
                             'declare void @record_acyclic_latch()\n'
                             'declare void @record_scalar_consumer_tail()\n')
            compile_ir(tag, instrumented)
            records.append({'fixture': fixture + '-bounds', 'fp_reordering_option': relaxed,
                            'loop_vectorize_invocations': repeats,
                            'comparison': 'original scalar IR and independent C formula, exact integer',
                            'producer_latch_consumer_counts': [1, 255, 16384],
                            'options': options, 'selection_remarks': result.stderr})

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
                      ('COMPACT_NESTED', compact_nested_rows), ('ACYCLIC', acyclic_rows),
                      ('ACYCLIC_BOUNDS', acyclic_bound_rows), ('AFFINE', affine_rows)]:
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
        'acyclic_counts': list(range(66)) + [66, 2**64 - 1],
        'affine_counts': list(range(66)) + [66, 2**64 - 1],
        'affine_compact_participants': list(range(66)),
        'affine_modular_relational_controls': ['unsigned ascending', 'signed ascending',
                                              'unsigned descending', 'signed descending'],
        'affine_modular_requirements': 'early exits and full capacity, nonzero actual '
                                      'vector and tail visits for each control; actual '
                                      'completed counts rather than equality witnesses',
        'affine_comparison': 'original IR and independent formulas, exact producer/latch/'
                             'participant/vector/tail visits, signed zero, inactive invalid '
                             'operands, canaries, aliases, runtime starts, enclosing reuse; '
                             'one and two ordinary LV invocations; host execution only',
        'acyclic_comparison': 'original scalar IR and independent C scalar formulas; '
                              'exact producer/latch/vector/tail counts; unchanged inputs, '
                              'canaries, aliases, enclosing-loop scratch reuse and repeated LV',
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
