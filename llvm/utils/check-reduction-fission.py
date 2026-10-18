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
from dataclasses import asdict, dataclass
from itertools import product
from pathlib import Path


@dataclass(frozen=True)
class InterleaveFixture:
    fixture: str
    function: str
    factor: int
    ordered_fp: bool
    outputs: int
    scratch_bytes_per_iteration: int
    reread_loads: int
    vf_pairs: tuple
    source_file: str = ''
    source_line: int = 0
    preferred_depth: int = 8


# Explicit semantic/layout metadata: names do not determine factors, types,
# output counts, scratch layouts, diagnostics or independently legal VF pairs.
INTERLEAVE_FIXTURES = (
    InterleaveFixture('interleave', 'interleave2', 2, False, 2, 4, 0,
                      ((2, 4), (4, 2)), 'interleave.c', 10),
    InterleaveFixture('interleave', 'interleave3', 3, False, 2, 4, 0,
                      ((2, 4), (4, 2)), 'interleave.c', 30),
    InterleaveFixture('interleave', 'interleave2_ordered', 2, True, 2, 8, 0,
                      ((2, 4), (4, 2)), 'interleave.c', 50),
    InterleaveFixture('interleave', 'interleave3_ordered', 3, True, 2, 8, 0,
                      ((2, 4), (2, 1)), 'interleave.c', 70),
    InterleaveFixture('interleave', 'interleave2_members', 2, False, 2, 8, 0,
                      ((2, 4), (4, 2)), 'interleave.c', 90),
    InterleaveFixture('interleave', 'interleave3_members', 3, False, 3, 12, 0,
                      ((2, 4), (4, 2)), 'interleave.c', 110),
    InterleaveFixture('interleave-duplication', 'interleave_reread', 2, False,
                      2, 4, 2, ((2, 4), (4, 2))),
    InterleaveFixture('interleave-duplication', 'interleave3_reread', 3, False,
                      2, 4, 3, ((2, 4), (4, 2))),
    InterleaveFixture('interleave-wide', 'interleave4', 4, False, 2, 4, 0,
                      ((2, 4), (4, 2), (2, 1)), 'interleave-wide.c', 10),
    InterleaveFixture('interleave-wide', 'interleave4_members', 4, False, 5, 16, 0,
                      ((2, 4), (4, 2), (2, 1)), 'interleave-wide.c', 30),
    InterleaveFixture('interleave-wide', 'interleave5', 5, False, 2, 4, 0,
                      ((2, 4), (2, 1)), 'interleave-wide.c', 50),
    InterleaveFixture('interleave-wide', 'interleave5_members', 5, False, 6, 20, 0,
                      ((2, 4), (2, 1)), 'interleave-wide.c', 70),
    InterleaveFixture('interleave-wide', 'interleave6', 6, False, 2, 4, 0,
                      ((2, 4), (2, 1)), 'interleave-wide.c', 90),
    InterleaveFixture('interleave-wide', 'interleave6_members', 6, False, 7, 24, 0,
                      ((2, 4), (2, 1)), 'interleave-wide.c', 110),
    InterleaveFixture('interleave-wide', 'interleave7', 7, False, 2, 4, 0,
                      ((2, 4), (2, 1)), 'interleave-wide.c', 130),
    InterleaveFixture('interleave-wide', 'interleave7_members', 7, False, 8, 28, 0,
                      ((2, 4), (2, 1)), 'interleave-wide.c', 150),
    InterleaveFixture('interleave-wide', 'interleave8', 8, False, 2, 4, 0,
                      ((2, 4), (2, 1)), 'interleave-wide.c', 170),
    InterleaveFixture('interleave-wide', 'interleave8_members', 8, False, 9, 32, 0,
                      ((2, 4), (2, 1)), 'interleave-wide.c', 190),
    InterleaveFixture('interleave-wide-ordered', 'interleave4_ordered', 4, True,
                      2, 8, 0, ((1, 2), (2, 1)), 'interleave-wide-ordered.c', 10),
    InterleaveFixture('interleave-wide-ordered', 'interleave8_ordered', 8, True,
                      2, 8, 0, ((1, 2),), 'interleave-wide-ordered.c', 30),
    InterleaveFixture('interleave-wide-reread', 'interleave5_reread', 5, False,
                      2, 4, 5, ((1, 2), (2, 1)),
                      'interleave-wide-reread.c', 10, 16),
    InterleaveFixture('interleave-wide-reread', 'interleave8_reread', 8, False,
                      2, 4, 8, ((1, 2), (2, 1)),
                      'interleave-wide-reread.c', 30, 16),
)

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


def execution_symbol(label):
    """Keep artifact labels separate from portable C/IR external symbols."""
    # Only hyphens are normalized. Reject other punctuation rather than
    # silently merging more labels. Avoid reserved leading underscores and
    # C11 keywords as these symbols also appear in the C execution harness.
    symbol = label.replace('-', '_')
    keywords = set(('auto break case char const continue default do double else '
                    'enum extern float for goto if inline int long register restrict '
                    'return short signed sizeof static struct switch typedef union '
                    'unsigned void volatile while').split())
    if not re.fullmatch(r'[A-Za-z][A-Za-z0-9_]*', symbol) or symbol in keywords:
        raise ValueError(f'invalid execution symbol label: {label!r}')
    return symbol


def rename_execution_functions(ir, labels, used_symbols):
    """Rename fixture definitions and all unquoted references in one step.

    used_symbols spans every object linked into the execution harness. Reject
    duplicate normalized names, including repeated requests, before changing
    it. This is fixture naming, not a general LLVM IR parser.
    """
    names = {}
    occupied = set(re.findall(r'@([-\w.$]+)', ir)) - labels.keys()
    for function, label in labels.items():
        function_definition(ir, function)
        name = execution_symbol(label)
        if name in used_symbols or name in occupied or name in names.values():
            raise ValueError(f'colliding execution symbol: {name!r} (label {label!r})')
        names[function] = name
    ir = re.sub(r'@([-\w.$]+)', lambda m: '@' + names.get(m[1], m[1]), ir)
    used_symbols.update(names.values())
    return ir, names


def boundary_variant(ir, bounds, tag, references, used_symbols):
    """Use the same symbols in boundary IR, C declarations and dispatch rows."""
    labels = {function: f'{function}_{tag}' for function, _ in bounds}
    if len(labels) != len(bounds):
        raise ValueError('duplicate boundary function')
    ir, names = rename_execution_functions(ir, labels, used_symbols)
    declarations, rows = [], []
    for function, count in bounds:
        name, reference = names[function], references[function]
        declarations.append(f'extern ScalarConstantFn {name}, {reference};')
        rows.append(f'{{"{name}", {name}, {reference}, {count}}}')
    return ir, declarations, rows


def check_export_signature(ir, name):
    """Check the fixture ABI represented by the C harness's ExportFn typedef."""
    body = function_definition(ir, name)
    signature = re.match(r'define void @' + re.escape(name) + r'\((.*?)\)', body, re.S)
    parameters = ([r'ptr(?: readonly)? %[-\w.$]+'] * 6 +
                  [r'i64 %[-\w.$]+', r'i64 %[-\w.$]+', r'double %[-\w.$]+'])
    if not signature or not re.fullmatch(r'\s*' + r',\s*'.join(parameters) + r'\s*',
                                         signature[1]):
        raise ValueError(f'ExportFn signature mismatch for @{name}')


def export_reference_declarations(source, reference, references):
    """Declare the actual mapped references, requiring exact original bodies.

    Both modules contain only the selected fixture definitions. Keep this a
    fixture ABI/origin check, rather than attempting to infer C types from IR.
    """
    functions = {m['name'] for m in FUNCTION_DEFINITION.finditer(source)}
    if set(references) != functions:
        raise ValueError('export reference mapping does not cover source definitions')
    if len(set(references.values())) != len(references):
        raise ValueError('duplicate export reference symbol')
    declarations = []
    for function, name in references.items():
        if execution_symbol(name) != name:
            raise ValueError(f'noncanonical export reference symbol: {name!r}')
        check_export_signature(source, function)
        check_export_signature(reference, name)
        expected = re.sub(r'@([-\w.$]+)',
                          lambda m: '@' + references.get(m[1], m[1]),
                          function_definition(source, function))
        if function_definition(reference, name) != expected:
            raise ValueError(f'export reference definition mismatch for @{function}: @{name}')
        declarations.append(f'extern ExportFn {name};')
    if {m['name'] for m in FUNCTION_DEFINITION.finditer(reference)} != set(references.values()):
        raise ValueError('export reference definitions do not match mapping')
    return declarations


def export_variant(ir, functions, tag, references, used_symbols, first_mode, lanes):
    """Use one mapping for export definitions, declarations and dispatch rows."""
    if len(set(functions)) != len(functions):
        raise ValueError('duplicate export function')
    if set(references) != set(functions):
        raise ValueError('export reference mapping does not cover variant functions')
    for function in functions:
        check_export_signature(ir, function)
    ir, names = rename_execution_functions(
        ir, {function: f'{function}_{tag}' for function in functions}, used_symbols)
    declarations, rows = [], []
    for mode, function in enumerate(functions, first_mode):
        name = names[function]
        declarations.append(f'extern ExportFn {name};')
        rows.append(f'{{"{name}", {name}, {references[function]}, {mode}, {lanes}}}')
    return ir, declarations, rows


def scalar_consumer(body, name):
    parts = re.split(r'^scalar\.fission\.consumer\.ph:[^\n]*\n', body, flags=re.M)
    if len(parts) != 2:
        raise ValueError(f'@{name}: expected exactly one scalar fission consumer')
    return parts


def check_compact_count(producer, consumer, name, evl, starts=None,
                        vectorized=True, recurrence=False, delay=False, bypass_edges=None,
                        chunked=False, producer_preheader=None, freeze_count=False):
    # These fixtures have one i64 compact counter and one latch. SCEV can
    # forward the single-input LCSSA export to its incoming latch value when
    # expanding the consumer trip count. A later LV invocation forms LCSSA
    # again, exporting that latch value through merge.lcssa in the guard.
    # Accept only these demonstrated forms, after checking their linkage and
    # entry edges. This is a bounded fixture check, not an equivalence solver.
    def need(condition, obligation):
        assert condition, f'@{name}: compact count provenance: {obligation}'

    def require(pattern, text):
        match = re.search(pattern, text, re.M)
        need(match, f'instruction {pattern}\n{text}')
        return match

    def block(text, label):
        return require(rf'^{re.escape(label)}:[^\n]*\n'
                       r'((?s:.*?))(?=^[\w.$-]+:|^}|\Z)', text)[1]

    def instructions(text):
        # Ignore printed predecessor comments and instruction metadata. Neither
        # is an edge or an executable instruction in these canonical fixtures.
        lines = [re.sub(r', ![^\n]*$', '', line.split(';', 1)[0]).strip()
                 for line in text.splitlines()]
        return [line for line in lines if line]

    def branch(label, condition, on_true, on_false):
        expected = f'br i1 {condition}, label %{on_true}, label %{on_false}'
        need(instructions(blocks[label])[-1] == expected, label + ': branch ' + expected)

    def jump(label, target):
        expected = f'br label %{target}'
        need(instructions(blocks[label])[-1] == expected, label + ': branch ' + expected)

    whole = producer + 'scalar.fission.consumer.ph:\n' + consumer
    blocks = loop_blocks(whole)
    successors = {}
    predecessors = {label: [] for label in blocks}
    for label, code in blocks.items():
        lines = instructions(code)
        need(lines, label + ': missing terminator')
        terminator = lines[-1]
        unconditional = re.fullmatch(r'br label %([-\w.$]+)', terminator)
        conditional = re.fullmatch(r'br i1 (?:%[-\w.$]+|true|false), '
                                   r'label %([-\w.$]+), label %([-\w.$]+)', terminator)
        if unconditional:
            successors[label] = [unconditional[1]]
        elif conditional:
            successors[label] = [conditional[1], conditional[2]]
        else:
            need(terminator.startswith('ret '), label + ': terminator ' + terminator)
            successors[label] = []
        for target in successors[label]:
            need(target in blocks, label + ': missing successor ' + target)
            predecessors[target].append(label)

    def single_entry(label, predecessor):
        need(predecessors[label] == [predecessor],
             f'{label}: predecessors {predecessors[label]}, expected [{predecessor}]')

    counter = '%fission.participating'
    merged, exported = counter + '.merge', counter + '.count'
    header = 'inner' if re.search(r'^inner:', producer, re.M) else 'loop'
    preheader = producer_preheader or ('scalar.fission.producer.ph' if chunked else
                                      'inner.ph' if header == 'inner' else 'preheader')

    def phi_inputs(text, value, ty='i64'):
        line = require(rf'^  {re.escape(value)} = phi {ty} '
                       r'(.+?)(?:, ![^\n]*)?$', text)[1]
        inputs = re.findall(r'\[ ([^,\]\n]+), (%[-\w.$]+) \]', line)
        # Do not silently ignore a malformed or additional incoming operand.
        assert ', '.join(f'[ {v}, {edge} ]' for v, edge in inputs) == line, line
        return inputs

    assert phi_inputs(block(producer, header), counter) == [
        ('0', '%' + preheader), (merged, '%latch')], producer
    if bypass_edges is None:
        bypass_edges = ['right' if re.search(r'^right:', producer, re.M) else header]
    expected_edges = [(counter + '.next', '%left')] + [
        (counter, '%' + edge) for edge in bypass_edges]
    need(sorted(phi_inputs(block(producer, 'latch'), merged)) == sorted(expected_edges),
         'latch participation value/edge')
    need(sorted(predecessors['latch']) == sorted(['left', *bypass_edges]),
         'latch participation predecessors')
    require(r'^  %fission\.participating\.next = add nuw i64 '
            r'%fission\.participating, 1(?:, ![^\n]*)?$', block(producer, 'left'))
    guard = block(producer, 'scalar.fission.consumer.guard')
    single_entry('scalar.fission.consumer.guard', 'latch')
    single_entry('scalar.fission.consumer.ph', 'scalar.fission.consumer.guard')
    assert phi_inputs(guard, exported) == [(merged, '%latch')], guard
    count_values = [merged, exported]
    if freeze_count:
        require(r'^  %fission\.consumer\.count = freeze i64 ' + re.escape(exported) + r'$', guard)
        count_values = ['%fission.consumer.count']
    forwarded = merged + '.lcssa'
    if re.search(rf'^  {re.escape(forwarded)} = ', whole, re.M):
        assert phi_inputs(guard, forwarded) == [(merged, '%latch')], guard
        if not freeze_count:
            count_values.append(forwarded)
    counts = '(?:' + '|'.join(map(re.escape, count_values)) + ')'
    require(rf'^  %fission\.empty = icmp eq i64 {counts}, 0$', guard)
    branch('scalar.fission.consumer.guard', '%fission.empty', 'scalar.fission.consumer.exit',
           'scalar.fission.consumer.ph')

    starts = starts if starts is not None else {
        'compact_triangle': [('r0', 'i32', '17'), ('r1', 'i32', '-7'),
                             ('rd', 'double', '%start'), ('rf', 'float', '%fstart')],
        'compact_diamond': [('r0', 'i32', '17'), ('r1', 'i32', '-7'),
                            ('rd', 'double', '%start'), ('rf', 'float', '%fstart')],
        'compact_integer': [('sum', 'i64', '%initial'), ('sum2', 'i64', '0')],
        'compact_nested': [('sum', 'i32', '%carry'), ('dsum', 'double', '%dcarry')],
        'export_compact': [('r0', 'i32', '17'), ('r1', 'i32', '-7'),
                           ('rd', 'double', '%start'), ('rf', 'float', '%fstart')],
        'export_nested': [('r0', 'i32', '%carry'), ('r1', 'i32', '%carry1'),
                          ('rd', 'double', '%dcarry'), ('rf', 'float', '%fcarry')],
    }[name]
    exit_block = block(consumer, 'scalar.fission.consumer.exit')
    need(sorted(predecessors['scalar.fission.consumer.exit']) == [
        'scalar.fission.consumer.guard', 'scalar.fission.consumer.loopexit'],
        'scalar.fission.consumer.exit: predecessors')
    results = {}
    for value, ty, start in starts:
        inputs = phi_inputs(exit_block, f'%{value}.result', ty)
        assert len(inputs) == 2, exit_block
        need(inputs[0] == (start, '%scalar.fission.consumer.guard'),
             'empty-stream start value/edge for ' + value)
        assert inputs[1][1] == '%scalar.fission.consumer.loopexit', exit_block
        assert re.fullmatch(r'%[-\w.$]+', inputs[1][0]), exit_block
        results[value] = inputs[1][0]

    if not vectorized:
        scalar = block(consumer, 'scalar.fission.consumer.body')
        assert phi_inputs(scalar, '%fission.consumer.iv') == [
            ('0', '%scalar.fission.consumer.ph'),
            ('%fission.consumer.next', '%scalar.fission.consumer.body')], scalar
        require(r'^  %fission\.consumer\.next = add(?: nuw)?(?: nsw)? i64 '
                r'%fission\.consumer\.iv, 1(?:, ![^\n]*)?$', scalar)
        require(r'^  %fission\.consumer\.more = icmp ne i64 '
                rf'%fission\.consumer\.next, {counts}(?:, ![^\n]*)?$', scalar)
        branch('scalar.fission.consumer.body', '%fission.consumer.more', 'scalar.fission.consumer.body',
               'scalar.fission.consumer.loopexit')
        loop_exit = block(consumer, 'scalar.fission.consumer.loopexit')
        for value, ty, start in starts:
            inputs = phi_inputs(scalar, '%' + value + '.consume', ty)
            assert len(inputs) == 2 and inputs[0] == (
                start, '%scalar.fission.consumer.ph'), scalar
            assert inputs[1][1] == '%scalar.fission.consumer.body', scalar
            assert phi_inputs(loop_exit, results[value], ty) == [inputs[1]], loop_exit
        return

    vector = block(consumer, 'vector.body')
    if evl:
        single_entry('vector.ph', 'scalar.fission.consumer.ph')
        jump('scalar.fission.consumer.ph', 'vector.ph')
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
        branch('vector.body', done, 'middle.block', 'vector.body')
        # The second LV also forwards ordered FP results out of vector.body.
        # Accept either the actual result or exactly one single-input PHI in
        # middle.block on that edge. Scalar integer reductions are already in
        # middle.block. Keep every empty-path start and the nonempty join edge.
        middle = block(consumer, 'middle.block')
        single_entry('middle.block', 'vector.body')
        single_entry('scalar.fission.consumer.loopexit', 'middle.block')
        require(r'^  br label %scalar\.fission\.consumer\.exit(?:, ![^\n]*)?$',
                block(consumer, 'scalar.fission.consumer.loopexit'))
        integers = re.findall(r'^  (%[-\w.$]+) = call i(?:32|64) '
                              r'@llvm\.vector\.reduce\.add\.nxv4i(?:32|64)\(', middle, re.M)
        integer_starts = [value for value, ty, _ in starts if ty.startswith('i')]
        assert [results[value] for value in integer_starts] == integers, exit_block
        for value, ty, _ in starts:
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
        branch('scalar.fission.consumer.ph', '%min.iters.check', 'scalar.ph', 'vector.ph')
        rounding = block(consumer, 'vector.ph')
        require(rf'^  %n\.mod\.vf = urem i64 {counts}, %[-\w.$]+', rounding)
        require(rf'^  %n\.vec = sub i64 {counts}, %n\.mod\.vf(?:, ![^\n]*)?$', rounding)
        done = require(r'^  (%[-\w.$]+) = icmp eq i64 %[-\w.$]+, %n\.vec(?:, ![^\n]*)?$', vector)[1]
        branch('vector.body', done, 'middle.block', 'vector.body')
        middle = block(consumer, 'middle.block')
        require(rf'^  %cmp\.n = icmp eq i64 {counts}, %n\.vec(?:, ![^\n]*)?$', middle)
        branch('middle.block', '%cmp.n', 'scalar.fission.consumer.loopexit', 'scalar.ph')
        tail = block(consumer, 'scalar.fission.consumer.body')
        require(r'^  %fission\.consumer\.more = icmp ne i64 '
                rf'%fission\.consumer\.next, {counts}(?:, ![^\n]*)?$', tail)
        if name in ('export_compact', 'export_nested'):
            tail_label = 'scalar.fission.consumer.body'
            join_label = 'scalar.fission.consumer.loopexit'
            assert len(successors[tail_label]) == 2, tail
            scalar_exit = successors[tail_label][1]
            branch(tail_label, '%fission.consumer.more', tail_label, scalar_exit)
            assert sorted(predecessors[tail_label]) == sorted(['scalar.ph', tail_label]), tail
            assert sorted(predecessors['scalar.ph']) == ['middle.block', 'scalar.fission.consumer.ph'], consumer
            jump('scalar.ph', tail_label)
            single_entry('middle.block', 'vector.body')
            # The direct exit names the join itself; its incoming scalar edge is
            # still from the tail. Otherwise the checked forwarding block below
            # supplies both the join edge and its exported scalar values.
            scalar_join_predecessor = tail_label if scalar_exit == join_label else scalar_exit
            assert sorted(predecessors[join_label]) == sorted([
                'middle.block', scalar_join_predecessor]), whole
            join = blocks[join_label]
            jump(join_label, 'scalar.fission.consumer.exit')

            # Identify each scalar result by its actual recurrence and update, not
            # by a .lcssa suffix. The update must consume this accumulator and a
            # typed contribution load. Ordered FP never accepts fast-math flags.
            updates, resumes = {}, {}
            for value, ty, _ in starts:
                accumulator = f'%{value}.consume'
                inputs = phi_inputs(tail, accumulator, ty)
                assert len(inputs) == 2, tail
                incoming = dict((edge, v) for v, edge in inputs)
                assert set(incoming) == {'%scalar.ph', '%' + tail_label}, tail
                update = incoming['%' + tail_label]
                operation = 'add' if ty.startswith('i') else 'fadd'
                operands = require(rf'^  {re.escape(update)} = {operation} {ty} '
                                   r'(%[-\w.$]+), (%[-\w.$]+)(?:, ![^\n]*)?$', tail)
                assert [operands[1], operands[2]].count(accumulator) == 1, tail
                if not ty.startswith('i'):
                    assert operands[1] == accumulator, tail
                contribution = operands[2] if operands[1] == accumulator else operands[1]
                require(rf'^  {re.escape(contribution)} = load {ty}, ptr %[-\w.$]+(?:,|$)', tail)
                updates[value] = update
                resumes[value] = incoming['%scalar.ph']

            scalar_results = dict(updates)
            if scalar_exit != join_label:
                # Repeated LV can split the scalar exit for LCSSA. Accept exactly
                # one block on the *actual* exit edge, with the consumer as its
                # sole predecessor, only typed single-input update PHIs, and an
                # unconditional branch to the existing vector/scalar join.
                single_entry(scalar_exit, tail_label)
                forwarding = blocks[scalar_exit]
                jump(scalar_exit, join_label)
                phis = instructions(forwarding)[:-1]
                assert len(phis) == len(starts), forwarding
                remaining = {(ty, updates[value]): value for value, ty, _ in starts}
                for line in phis:
                    phi = re.fullmatch(r'(%[-\w.$]+) = phi (i32|i64|double|float) .+', line)
                    assert phi, forwarding
                    inputs = phi_inputs(forwarding, phi[1], phi[2])
                    assert len(inputs) == 1 and inputs[0][1] == '%' + tail_label, forwarding
                    key = (phi[2], inputs[0][0])
                    assert key in remaining, forwarding
                    scalar_results[remaining.pop(key)] = phi[1]
                assert not remaining, forwarding

            integers = re.findall(r'^  (%[-\w.$]+) = call (i32|i64) '
                                  r'@llvm\.vector\.reduce\.add\.nxv4i(?:32|64)\(', middle, re.M)
            integer_types = [ty for _, ty, _ in starts if ty.startswith('i')]
            assert [ty for _, ty in integers] == integer_types, middle
            integer_results = iter(value for value, _ in integers)
            for value, ty, start in starts:
                inputs = phi_inputs(join, results[value], ty)
                assert len(inputs) == 2, join
                incoming = dict((edge, v) for v, edge in inputs)
                assert set(incoming) == {'%middle.block', '%' + scalar_join_predecessor}, join
                assert incoming['%' + scalar_join_predecessor] == scalar_results[value], join
                vector_result = incoming['%middle.block']
                if ty.startswith('i'):
                    assert vector_result == next(integer_results), join
                else:
                    reduced = require(rf'^  (%[-\w.$]+) = call {ty} '
                                      r'@llvm\.vector\.reduce\.fadd\.', vector)[1]
                    if vector_result != reduced:
                        assert phi_inputs(middle, vector_result, ty) == [
                            (reduced, '%vector.body')], middle
                # The scalar tail resumes the same vector result (or original
                # start on vector bypass) that reaches the final nonempty join.
                assert sorted(phi_inputs(block(consumer, 'scalar.ph'), resumes[value], ty)) == sorted([
                    (vector_result, '%middle.block'),
                    (start, '%scalar.fission.consumer.ph')]), consumer
        else:
            check_compact_scalar_results(whole, starts, results, recurrence=recurrence,
                                         delay=delay)


def check_compact_scalar_results(body, starts, results, recurrence=False, delay=False):
    """Certify the demonstrated compact scalar-tail joins, not arbitrary IR."""
    # Ignore printed predecessor comments and metadata, never instructions.
    blocks = re.findall(r'^([-\w.$]+):[^\n]*\n(.*?)'
                        r'(?=^[-\w.$]+:|^}|\Z)', body, re.M | re.S)
    assert len({label for label, _ in blocks}) == len(blocks), 'compact scalar results: duplicate label'
    table = dict(blocks)
    table = {label: [line.split(', !', 1)[0].strip() for line in text.splitlines()
                     if line.strip() and not line.lstrip().startswith(';')]
             for label, text in table.items()}

    def need(condition, obligation):
        assert condition, 'compact scalar results: ' + obligation

    def match(pattern, label):
        matches = [m for line in table.get(label, [])
                   if (m := re.fullmatch(pattern, line))]
        need(len(matches) == 1, label + ': instruction ' + pattern)
        return matches[0]

    ssa = r'%[-\w.$]+'

    def phi(label, value, ty):
        text = match(re.escape(value) + r' = phi ' + re.escape(ty) + r' (.+)', label)[1]
        pairs = re.findall(r'\[ (insertelement \([^()\n]+\)|[^,\]\n]+), %([-\w.$]+) \]', text)
        need(', '.join(f'[ {v}, %{edge} ]' for v, edge in pairs) == text,
             label + ': PHI operands')
        return sorted(pairs)

    def incoming(destination):
        # Also count unexpected switch/invoke label operands. They cannot
        # hide an extra predecessor behind otherwise plausible PHI text.
        return sorted(label for label, lines in table.items() for line in lines
                      for target in re.findall(r'\blabel %([-\w.$]+)', line)
                      if target == destination)

    def jump(label):
        target = match(r'br label %([-\w.$]+)', label)[1]
        need(table[label][-1] == 'br label %' + target, label + ': terminator')
        return target

    def forwarded(value, ty, source, destination):
        # One typed LCSSA PHI, with no name/suffix assumptions or copy chains.
        candidates = [m[1] for line in table.get(destination, []) if (m := re.fullmatch(
            rf'({ssa}) = phi {re.escape(ty)} \[ {re.escape(value)}, %{re.escape(source)} \]', line))]
        need(len(candidates) == 1, destination + ': forwarding PHI for ' + value)
        return candidates[0]

    tail, middle = 'scalar.fission.consumer.body', 'middle.block'
    join, end = 'scalar.fission.consumer.loopexit', 'scalar.fission.consumer.exit'
    entry, resume = 'scalar.fission.consumer.ph', 'scalar.ph'
    need(incoming('vector.ph') == [entry], 'vector preheader predecessors')
    need(incoming('vector.body') == ['vector.body', 'vector.ph'], 'vector body predecessors')
    need(incoming(middle) == ['vector.body'], 'middle predecessors')
    need(incoming(resume) == sorted([entry, middle]), 'resume predecessors')
    need(incoming(tail) == sorted([resume, tail]), 'tail predecessors')
    need(jump(resume) == tail, 'resume edge')
    match(r'br i1 %cmp\.n, label %' + re.escape(join) + r', label %scalar\.ph', middle)
    destination = match(r'br i1 %fission\.consumer\.more, label %' + re.escape(tail) +
                        r', label %([-\w.$]+)', tail)[1]
    need(destination == join or (destination not in (tail, middle, resume, end) and
         incoming(destination) == [tail] and jump(destination) == join),
         'tail forwarding edge/predecessors')
    need(incoming(join) == sorted([middle, tail if destination == join else destination]),
         'join predecessors')
    need(jump(join) == end, 'join edge')
    need(incoming(end) == sorted(['scalar.fission.consumer.guard', join]), 'result predecessors')

    # Resume at zero on the vector bypass, or at the rounded vector bound.
    # Canonical consumers can retain nsw as well as nuw on their unit step.
    iv = match(r'(' + ssa + r') = add nuw(?: nsw)? i64 (' + ssa + r'), 1', tail)
    need(iv[1] == '%fission.consumer.next', 'tail increment')
    resume_iv = phi(tail, iv[2], 'i64')
    need(('%fission.consumer.next', tail) in resume_iv and len(resume_iv) == 2,
         'tail induction')
    seed = [v for v, edge in resume_iv if edge == resume]
    need(len(seed) == 1 and phi(resume, seed[0], 'i64') == sorted([
        ('0', entry), ('%n.vec', middle)]), 'resume induction')

    # Integer result calls occur in reduction order in middle.block; ordered
    # FP calls occur in vector.body. Their operands may pass through exactly
    # one typed PHI in middle.block after the second LV invocation.
    integer_calls = [m for line in table[middle] if (m := re.fullmatch(
        rf'({ssa}) = call (i32|i64) @llvm\.vector\.reduce\.add\.nxv4\2'
        rf'\(<vscale x 4 x (i32|i64)> ({ssa})\)', line))]
    need(len(integer_calls) == sum(ty.startswith('i') for _, ty, _ in starts),
         'integer vector results')
    forwards, middle_forwards = [], []
    integer_count = len(integer_calls)
    for value, ty, start in starts:
        # Keep the output-interface mode independent of this reduction's SSA.
        recurrence_value = '%' + value + '.consume'
        tail_inputs = phi(tail, recurrence_value, ty)
        update = [v for v, edge in tail_inputs if edge == tail]
        initial = [v for v, edge in tail_inputs if edge == resume]
        need(len(update) == len(initial) == 1 and len(tail_inputs) == 2, 'tail recurrence')
        op = r'add(?: nuw)?(?: nsw)?' if ty.startswith('i') else 'fadd'
        arithmetic = match(re.escape(update[0]) + rf' = {op} {ty} ({ssa}), ({ssa})', tail)
        operands = [arithmetic[1], arithmetic[2]]
        need(operands.count(recurrence_value) == 1, 'tail reduction update')
        contribution = operands[1] if operands[0] == recurrence_value else operands[0]
        match(re.escape(contribution) + rf' = load {ty}, ptr {ssa}(?:, align \d+)?', tail)
        if not ty.startswith('i'):
            need(operands[0] == recurrence_value, 'ordered tail operands')

        vty = '<vscale x 4 x ' + ty + '>'
        if ty.startswith('i'):
            call = integer_calls.pop(0)
            need(call[2] == call[3] == ty, 'integer reduction type')
            vector_result, vector_update = call[1], call[4]
            if any(line.startswith(vector_update + ' = phi ') for line in table[middle]):
                middle_forwards.append(vector_update)
                pairs = phi(middle, vector_update, vty)
                need(len(pairs) == 1 and pairs[0][1] == 'vector.body', 'vector forwarding PHI')
                vector_update = pairs[0][0]
            arithmetic = match(rf'{re.escape(vector_update)} = add {re.escape(vty)} '
                               rf'({ssa}), ({ssa})', 'vector.body')
            vector_operands = [arithmetic[1], arithmetic[2]]
        else:
            suffix = 'f64' if ty == 'double' else 'f32'
            call = match(rf'({ssa}) = call {ty} @llvm\.vector\.reduce\.fadd\.nxv4{suffix}'
                         rf'\({ty} ({ssa}), {re.escape(vty)} ({ssa})\)', 'vector.body')
            vector_update, vector_operands = call[1], [call[2], call[3]]
            vector_result = vector_update
            if any(line.startswith(vector_result + ' = ') for line in table[middle]):
                need(False, 'redefined vector result')
            # The scalar resume PHI and the result join must use the same
            # direct result or the demonstrated single LCSSA forwarding PHI.
            resume_pairs = phi(resume, initial[0], ty)
            candidate = [v for v, edge in resume_pairs if edge == middle]
            need(len(candidate) == 1, 'resume vector result')
            if candidate[0] != vector_result:
                need(phi(middle, candidate[0], ty) == [(vector_result, 'vector.body')],
                     'FP vector forwarding PHI')
                vector_result = candidate[0]
                middle_forwards.append(vector_result)

        # Locate the vector recurrence by its checked update, not an SSA suffix.
        vector_phis = [operand for operand in vector_operands if any(
            line.startswith(operand + ' = phi ') for line in table['vector.body'])]
        need(len(vector_phis) == 1, 'vector recurrence')
        vector_phi = vector_phis[0]
        loaded = vector_operands[1] if vector_operands[0] == vector_phi else vector_operands[0]
        match(re.escape(loaded) + rf' = load {re.escape(vty)}, ptr {ssa}(?:, align \d+)?',
              'vector.body')
        if not ty.startswith('i'):
            need(vector_operands[0] == vector_phi, 'ordered vector operands')
        pairs = phi('vector.body', vector_phi, vty if ty.startswith('i') else ty)
        if ty.startswith('i'):
            seed = 'zeroinitializer' if start == '0' else (
                f'insertelement ({vty} zeroinitializer, {ty} {start}, i32 0)')
            # Dynamic integer starts use an instruction in vector.ph.
            init = [v for v, edge in pairs if edge == 'vector.ph']
            if len(init) == 1 and re.fullmatch(ssa, init[0]):
                match(re.escape(init[0]) + rf' = insertelement {re.escape(vty)} '
                      rf'zeroinitializer, {ty} {re.escape(start)}, i32 0', 'vector.ph')
                seed = init[0]
        else:
            seed = start
        need(pairs == sorted([(seed, 'vector.ph'), (vector_update, 'vector.body')]),
             'vector recurrence start/backedge')
        need(phi(resume, initial[0], ty) == sorted([(start, entry), (vector_result, middle)]),
             'resume reduction')
        tail_result = update[0]
        if destination != join:
            tail_result = forwarded(tail_result, ty, tail, destination)
            forwards.append(tail_result)
        need(phi(join, results[value], ty) == sorted([
            (tail_result, destination if destination != join else tail), (vector_result, middle)]),
             'join reduction ' + value)
    if destination != join:
        need(len(table[destination]) == len(forwards) + 1, 'tail forwarding work')
    need(len(table[middle]) == integer_count + len(middle_forwards) + 2, 'middle forwarding work')
    need(len(table[resume]) == len(starts) + 2, 'resume work')
    need(len(table[join]) == len(starts) + 1, 'join work')
    need(len(table[end]) == len(starts) + 1, 'result work')

    # Follow the compact results to the fixture's observable stores. The
    # nested fixture instead exports row values which also carry to outer.
    if delay:
        destination = jump(end)
        output = '%sum.result'
        if destination != 'exit':
            output = forwarded(output, 'i32', end, destination)
            need(incoming(destination) == [end] and jump(destination) == 'exit' and
                 len(table[destination]) == 2, 'delay output forwarding')
        predecessor = end if destination == 'exit' else destination
        need(incoming('exit') == [predecessor], 'delay output predecessors')
        returned = match(r'ret i32 (' + ssa + ')', 'exit')[1]
        need(returned == output or
             phi('exit', returned, 'i32') == [(output, predecessor)], 'delay output')
        match(r'ret i32 17', 'bypass')
        return
    if recurrence:
        # The three-reduction recurrence fixtures have two shared integer
        # contributions and one ordered double stream. Keep the inherited
        # vector/tail/start/forwarding proof above; only their output interface
        # differs from the older four-stream compact fixtures below.
        nested = any(start == '%carry0' for _, _, start in starts)
        final = 'row.exit' if nested else 'exit'
        destination = jump(end)
        output = {}
        for value, ty, _ in starts:
            result = '%' + value + '.result'
            output[value] = (forwarded(result, ty, end, destination)
                             if destination != final else result)
        if destination != final:
            need(incoming(destination) == [end] and jump(destination) == final and
                 len(table[destination]) == len(starts) + 1, 'output forwarding')
        predecessor = destination if destination != final else end
        need(incoming(final) == sorted([predecessor] + ([] if nested else ['entry'])),
             'output predecessors')
        for value, ty, start in starts:
            result, pointer = {'r0': ('%v0', '%out'), 'r1': ('%v1', '%o1'),
                               'rd': ('%vd', '%dout')}[value]
            need(phi(final, result, ty) == sorted([(output[value], predecessor)] +
                 ([] if nested else [(start, 'entry')])), 'output PHI ' + value)
            match(rf'store {ty} {re.escape(result)}, ptr {re.escape(pointer)}'
                  r'(?:, align \d+)?', final)
        match(r'%o1 = getelementptr i32, ptr %out, i64 1', final)
        if nested:
            for carry, value, ty, start in [('%carry0', '%v0', 'i32', '17'),
                                          ('%carry1', '%v1', 'i32', '-7'),
                                          ('%dcarry', '%vd', 'double', '%start')]:
                need(phi('outer', carry, ty) == sorted([
                    (start, 'outer.ph'), (value, 'row.exit')]), 'row reduction carry')
        else:
            match(r'ret void', final)
        return
    final = 'row.exit' if starts[0][0] == 'sum' and starts[0][1] == 'i32' else 'exit'
    destination = jump(end)
    output = {}
    for value, ty, start in starts:
        result = '%' + value + '.result'
        if destination != final:
            output[value] = forwarded(result, ty, end, destination)
        else:
            output[value] = result
    if destination != final:
        need(incoming(destination) == [end] and jump(destination) == final and
             len(table[destination]) == len(starts) + 1, 'output forwarding')
    predecessor = destination if destination != final else end
    need(incoming(final) == sorted([predecessor] + ([] if final == 'row.exit' else ['entry'])),
         'output predecessors')
    names = (['%row.sum', '%row.dsum'] if final == 'row.exit' else
             ['%result', '%result2'] if starts[0][1] == 'i64' else ['%v0', '%v1', '%vd', '%vf'])
    for (value, ty, start), result in zip(starts, names):
        need(phi(final, result, ty) == sorted([(output[value], predecessor)] +
             ([] if final == 'row.exit' else [(start, 'entry')])), 'output PHI ' + value)
    stores = ([('i32', '%row.sum', '%dst'), ('double', '%row.dsum', '%ddst')]
              if final == 'row.exit' else [('i64', '%combined', '%out')]
              if starts[0][1] == 'i64' else
              [('i32', '%v0', '%out'), ('i32', '%v1', '%o1'),
               ('double', '%vd', '%dout'), ('float', '%vf', '%fout')])
    if starts[0][1] == 'i64':
        match(r'%combined = add i64 %result, %result2', final)
    elif final == 'exit':
        match(r'%o1 = getelementptr i32, ptr %out, i64 1', final)
    else:
        match(r'%dst = getelementptr i32, ptr %out, i64 %row', final)
        match(r'%ddst = getelementptr double, ptr %dout, i64 %row', final)
    for ty, value, pointer in stores:
        match(rf'store {ty} {re.escape(value)}, ptr {re.escape(pointer)}(?:, align \d+)?', final)
    need(len(table[final]) == (9 if final == 'row.exit' else
                              5 if starts[0][1] == 'i64' else 10), 'output work')
    if final == 'exit':
        match(r'ret void', final)
    if final == 'row.exit':
        need(phi('outer', '%carry', 'i32') == sorted([('19', 'outer.ph'), ('%row.sum', 'row.exit')]) and
             phi('outer', '%dcarry', 'double') == sorted([('%start', 'outer.ph'), ('%row.dsum', 'row.exit')]),
             'row reduction carry')


EXPORT_FUNCTIONS = ('export_unconditional', 'export_diamond',
                    'export_compact', 'export_nested')
EXPORT_CONTROL_BASES = {
    'export_offset': 'export_unconditional',
    'export_stride': 'export_diamond',
    'export_down': 'export_diamond',
    'export_current': 'export_unconditional',
    'export_affine_compact': 'export_compact',
    'export_serial': 'export_diamond',
    'export_acyclic_nested': 'export_diamond',
    'export_enclosing': 'export_nested',
}
EXPORT_CONTROL_FUNCTIONS = tuple(EXPORT_CONTROL_BASES)

# These fixtures share the existing typed compact consumer/result/export
# contract, while independently checking their complete original producer CFG.
COMPACT_CFG_BASES = {
    'compact_cfg_serial': 'export_compact',
    'compact_cfg_nested': 'export_compact',
    'compact_cfg_affine': 'export_compact',
    'compact_cfg_enclosing': 'export_nested',
}
COMPACT_CFG_FUNCTIONS = tuple(COMPACT_CFG_BASES)
STATE_CFG_FUNCTIONS = ('state_cfg_serial', 'state_cfg_nested', 'state_cfg_affine')
COMPACT_CFG_BASES.update(dict.fromkeys(STATE_CFG_FUNCTIONS, 'export_compact'))


def state_cfg_execution_counts(stdout, expected_functions):
    """Count completed focused comparisons, separately from the planned matrix."""
    completed = {}
    for match in re.finditer(r'^State CFG participation (\S+): comparisons=(\d+) '
                             r'rows=(\d+) cases=(\d+)$', stdout, re.M):
        name = match[1]
        assert name not in completed, 'state CFG execution: duplicate ' + name
        comparisons, rows, cases = map(int, match.groups()[1:])
        assert (comparisons, rows, cases) == (28, 2, 7), (
            'state CFG execution: incomplete focused cases', name, match[0])
        completed[name] = comparisons
    assert set(completed) == set(expected_functions), (
        'state CFG execution: missing/unexpected configuration', completed, expected_functions)
    return {'completed_comparisons': sum(completed.values()), 'configurations': completed}


EXPORT_FAMILIES = (
    ('reduction-fission-scalar-exports.ll', EXPORT_FUNCTIONS, 0,
     'scalar-exports.c', 'exports'),
    ('reduction-fission-scalar-export-controls.ll', EXPORT_CONTROL_FUNCTIONS, 4,
     'scalar-export-controls.c', 'export_controls'),
    ('reduction-fission-scalar-compact-cfg.ll', COMPACT_CFG_FUNCTIONS, 12,
     'scalar-compact-cfg.c', 'compact_cfg'),
    ('reduction-fission-scalar-state-cfg.ll', STATE_CFG_FUNCTIONS, 16,
     'scalar-state-cfg.c', 'state_cfg'),
)


def check_compact_cfg_producer(producer, name):
    """Exact compact scratch-index certificate for the four finite CFG fixtures."""
    blocks = loop_blocks(producer)
    active = blocks['left']

    def need(ok, detail):
        assert ok, f'@{name}: compact CFG: {detail}'

    need(re.search(r'^  br label %latch(?:, ![^\n]*)?$', active, re.M),
         'terminal update edge')
    need(producer.count('fission.participating.next = add nuw i64') == 1,
         'one participant increment')
    need(not re.search(r'^  %(?:r0|r1|rd|rf|u0|u1|ud|uf|m0|m1|md|mf) = ',
                       producer, re.M), 'producer reduction state removed')
    need('fadd ' not in producer, 'no producer or bypass additions')
    need(producer.count('sdiv ') == 1, 'one original guarded division')
    need(len(re.findall(r'^  store ', producer, re.M)) == 3,
         'no bypass scratch stores')
    for ty, contribution in [('i32', '%lc'), ('double', '%ld'), ('float', '%lf')]:
        slots = re.findall(r'^  (%[-\w.$]+) = alloca \[65 x ' + ty + r'\]', producer, re.M)
        need(len(slots) == 1, ty + ' unique full-capacity array')
        addresses = re.findall(r'^  (%[-\w.$]+) = getelementptr inbounds \[65 x ' +
                               ty + r'\], ptr ' + re.escape(slots[0]) +
                               r', i32 0, i64 %fission.participating(?:, ![^\n]*)?$',
                               active, re.M)
        need(len(addresses) == 1, ty + ' compact index')
        need(len(re.findall(r'^  store ' + ty + ' ' + re.escape(contribution) +
                            r', ptr ' + re.escape(addresses[0]) + r', align \d+(?:, ![^\n]*)?$',
                            active, re.M)) == 1, ty + ' participating store')
    # Every original edge/operation (including branch polarity, exports and
    # inactive routing) is checked separately by check_export_control_producer.
    return ['right', 'right1', 'right2'] if name in (
        'compact_cfg_affine', 'compact_cfg_enclosing', 'state_cfg_affine') else ['right']


def check_scalar_function(ir, name, evl, probe=False, fixed_narrow=False):
    body = function_definition(ir, name)
    producer, consumer = scalar_consumer(body, name)
    cfg_name = name if name in COMPACT_CFG_BASES else None
    # New controls reuse the same typed consumer/participation contract. Their
    # retained producer is independently checked against the original below.
    name = COMPACT_CFG_BASES.get(name, EXPORT_CONTROL_BASES.get(name, name))
    exports = name in EXPORT_FUNCTIONS
    compact = name.startswith('compact_') or name in ('export_compact', 'export_nested')
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
                'compact_triangle', 'compact_diamond', 'compact_nested') or exports:
        assert producer.count('call i32 @scalar_helper(') == 1, body
        assert '<vscale x' not in producer, producer
    if name in ('scalar_mixed', 'scalar_diamond', 'compact_triangle', 'compact_diamond') or exports:
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
    if compact and cfg_name:
        bypass_edges = check_compact_cfg_producer(producer, cfg_name)
        check_compact_count(producer, consumer, name, evl, bypass_edges=bypass_edges)
    elif compact:
        header, arms = re.split(r'^left:[^\n]*\n', producer, maxsplit=1, flags=re.M)
        active, rest = re.split(r'^(?:right|latch):[^\n]*\n', arms, maxsplit=1, flags=re.M)
        successors = {'compact_triangle': ('left', 'latch'),
                      'compact_diamond': ('right', 'left'),
                      'compact_integer': ('latch', 'left'),
                      'compact_nested': ('left', 'right'),
                      'export_compact': ('left', 'right'),
                      'export_nested': ('left', 'right')}
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
                          'diamond_arithmetic', 'scalar_diamond_nested') or compact or acyclic or exports or fixed_narrow
    if vectorized:
        vector = re.search(r'^vector\.body[^:]*:[^\n]*\n(.*?)(?=^[\w.$-]+:|^})',
                           consumer, re.M | re.S)
        assert vector, f'@{name}: missing vector consumer\n{consumer}'
        if name in ('scalar_mixed', 'scalar_nested', 'scalar_diamond',
                    'scalar_diamond_nested', 'compact_triangle', 'compact_diamond',
                    'compact_nested', 'acyclic_serial', 'acyclic_nested', 'acyclic_three_way',
                    'acyclic_enclosing') or exports:
            types = [('double', 'f64')]
            if name in ('scalar_mixed', 'scalar_diamond', 'compact_triangle', 'compact_diamond',
                        'acyclic_serial', 'acyclic_nested', 'acyclic_three_way') or exports:
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
                    'acyclic_serial', 'acyclic_nested', 'acyclic_three_way') or exports:
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
            if name in ('scalar_diamond', 'scalar_diamond_nested') or compact or acyclic or exports:
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


def check_export_control_producer(body, original, name, header, latch, exit_label, compact):
    """Bounded certificate for finite export/control and compact CFG fixtures.

    Retain every original producer instruction/edge, with only the existing
    one-way integer nowrap refinement. Exhaust the fixture's finite control
    domain (N=1..65, row=0..3), independently of function names, to certify
    N versus the actual controlling consumer bounds. This is test machinery,
    not a compiler count proof or arbitrary IR equivalence engine.
    """
    before, after = loop_blocks(original), loop_blocks(body)

    def need(ok, detail):
        assert ok, f'@{name}: export control: {detail}'

    def normalize(line):
        line = line.split(', !', 1)[0]
        line = re.sub(r'(?<![\w.])(-?\d+\.\d+(?:[eE][+-]?\d+)?)(?![\w.])',
                      lambda m: float(m[0]).hex(), line)
        return re.sub(r'\s+', '', line)

    labels = list(before)
    labels = labels[:labels.index(latch) + 1]
    for label in labels:
        need(label in after, 'missing original block ' + label)
        for line in before[label].splitlines():
            if not line.strip() or line.lstrip().startswith(';'):
                continue
            if re.match(r'  %(?:r0|r1|rd|rf|u0|u1|ud|uf|m0|m1|md|mf) = ', line):
                continue
            if label == latch and line.strip().startswith('br '):
                line = line.replace('label %' + ('row.exit' if header == 'inner' else 'producer.exit'),
                                    'label %' + exit_label)
            need(any(affine_instruction_refines(line, candidate, normalize)
                     for candidate in after[label].splitlines()), label + ': ' + line)
    if compact:
        return  # Existing compact certificate checks P and all result edges.

    ph = 'inner.ph' if header == 'inner' else 'preheader'
    for label, line in [
        (header, f'%fission.ordinal = phi i64 [ 0, %{ph} ], [ %fission.completed, %{latch} ]'),
        (latch, '%fission.completed = add nuw i64 %fission.ordinal, 1'),
        (exit_label, f'%fission.completed.count = phi i64 [ %fission.completed, %{latch} ]'),
    ]:
        need(any(affine_instruction_refines('  ' + line, candidate, normalize)
                 for candidate in after[label].splitlines()), label + ': ordinal/count')

    def definitions(blocks):
        result = {}
        for label, block in blocks.items():
            for value, expression in re.findall(r'^  (%[-\w.$]+) = (.+)', block, re.M):
                need(value not in result, 'duplicate definition ' + value)
                result[value] = (label, expression.split(', !', 1)[0])
        return result

    old_defs, new_defs = definitions(before), definitions(after)
    mask = (1 << 64) - 1
    signed = lambda x: x if x < (1 << 63) else x - (1 << 64)

    def evaluate(value, defs, inputs, seen=(), remaining=None):
        if remaining is None:
            remaining = [128]
        remaining[0] -= 1
        need(remaining[0] >= 0, 'count expression budget')
        if not value.startswith('%'):
            return int(value) & mask
        if value in inputs:
            return inputs[value] & mask
        need(value in defs and value not in seen and len(seen) < 32,
             'unproved count operand ' + value)
        label, expression = defs[value]
        # Only the producer's dedicated-exit single-edge completed-count
        # aliases are accepted. Never chase unrelated PHIs or predecessor edges.
        phi = re.fullmatch(r'phi i64 \[ %fission.completed, %' + latch + r' \]', expression)
        if phi:
            need(label == exit_label, 'count forwarding edge')
            return inputs['%fission.completed']
        binary = re.fullmatch(r'(add|sub|mul|shl|lshr|and|or|xor)((?: (?:nuw|nsw))*) i64 '
                              r'(%[-\w.$]+|-?\d+), (%[-\w.$]+|-?\d+)', expression)
        intrinsic = re.fullmatch(r'call i64 @llvm\.(umax|umin|smax|smin)\.i64'
                                 r'\(i64 (%[-\w.$]+|-?\d+), i64 (%[-\w.$]+|-?\d+)\)', expression)
        need(binary or intrinsic, 'unsupported count definition ' + expression)
        match = binary or intrinsic
        a, b = [evaluate(x, defs, inputs, seen + (value,), remaining) for x in
                ((match[3], match[4]) if binary else (match[2], match[3]))]
        op = match[1]
        if op in ('shl', 'lshr'):
            need(b < 64, 'count shift')
        result = {'add': lambda: a+b, 'sub': lambda: a-b, 'mul': lambda: a*b,
                  'shl': lambda: a << b, 'lshr': lambda: a >> b,
                  'and': lambda: a & b, 'or': lambda: a | b, 'xor': lambda: a ^ b,
                  'umax': lambda: max(a,b), 'umin': lambda: min(a,b),
                  'smax': lambda: max(signed(a),signed(b)),
                  'smin': lambda: min(signed(a),signed(b))}[op]()
        if binary and 'nuw' in binary[2]:
            need(0 <= result <= mask, 'poison count nuw')
        if binary and 'nsw' in binary[2]:
            mathematical = {'add': lambda: signed(a)+signed(b),
                            'sub': lambda: signed(a)-signed(b),
                            'mul': lambda: signed(a)*signed(b),
                            'shl': lambda: signed(a) << b}[op]()
            need(-(1 << 63) <= mathematical < (1 << 63), 'poison count nsw')
        return result & mask

    # Source fixtures need not use opt's whitespace spelling.
    iv = re.search(r'phi i64 \[\s*(-?\d+), %' + ph + r'\]', old_defs['%iv'][1])
    need(iv, 'original IV start')
    control = re.fullmatch(r'icmp (eq|ne|ult|ule|ugt|uge|slt|sle|sgt|sge) i64 '
                           r'(%iv|%next), (%[-\w.$]+|-?\d+)', old_defs['%done'][1])
    need(control, 'original exit predicate')
    bounds = []
    consumer = scalar_consumer(body, name)[1]
    for pattern in [r'%avl = phi i64 \[ (%[-\w.$]+), %vector.ph \]',
                    r'%min.iters.check = icmp ult i64 (%[-\w.$]+),',
                    r'%n.mod.vf = urem i64 (%[-\w.$]+),',
                    r'%n.vec = sub i64 (%[-\w.$]+), %n.mod.vf',
                    r'%cmp.n = icmp eq i64 (%[-\w.$]+), %n.vec',
                    r'%fission.consumer.more = icmp ne i64 %fission.consumer.next, (%[-\w.$]+)']:
        bounds.extend(re.findall(pattern, consumer))
    need(len(bounds) in (1, 5), 'actual consumer count sites')
    for n in range(1, 66):
        for row in range(4 if header == 'inner' else 1):
            inputs = {'%n': n, '%row': row}
            current = int(iv[1]) & mask
            for iteration in range(1, 66):
                state = dict(inputs, **{'%iv': current})
                following = evaluate('%next', old_defs, state)
                state['%next'] = following
                a, b = [evaluate(x, old_defs, state) for x in control.group(2, 3)]
                predicate = control[1]
                if predicate.startswith('s'):
                    a, b = signed(a), signed(b)
                done = {'eq': a == b, 'ne': a != b, 'lt': a < b,
                        'le': a <= b, 'gt': a > b, 'ge': a >= b}[
                            predicate if predicate in ('eq', 'ne') else predicate[1:]]
                if done:
                    break
                current = following
            need(done and iteration == n, 'original actual N')
            inputs.update({'%fission.completed': iteration,
                           '%fission.completed.count': iteration})
            for bound in bounds:
                need(evaluate(bound, new_defs, inputs) == iteration,
                     'wrong iteration count ' + bound)


def check_state_cfg_retention(body, original, name):
    """Check retained state paths/order separately from moved result closure."""
    before, after = loop_blocks(original), loop_blocks(body)
    moved = re.compile(r'  %(?:r0|r1|rd|rf|u0|u1|ud|uf|m0|m1|md|mf) = ')
    for label in list(before)[:list(before).index('latch') + 1]:
        candidates = after[label].splitlines()
        position = -1
        for line in before[label].splitlines():
            if not line.strip() or moved.match(line):
                continue
            if label == 'latch' and line.startswith('  br '):
                line = line.replace('label %producer.exit', 'label %scalar.fission.consumer.guard')
            # These fixtures contain integer state only; FP spelling is already
            # checked by the shared original-producer certificate above.
            normalize = lambda s: re.sub(r'\s+', '', s.split(', !', 1)[0])
            if any(token in line for token in ('double', 'float')):
                continue
            matches = [i for i, candidate in enumerate(candidates)
                       if affine_instruction_refines(line, candidate, normalize)]
            assert len(matches) == 1 and matches[0] > position, (
                f'@{name}: retained state order/path: {label}: {line}')
            position = matches[0]
    producer, consumer = scalar_consumer(body, name)
    assert producer.count('%state.next = add i32') == 1, name + ': retained update count'
    assert not re.search(r'(?<![\w.])%(?:state|state\.next|state\.merge)(?![\w.])', consumer), (
        name + ': consumer observes producer state')


def check_producer_exports(ir, name, evl, probe=False, source=None, scalar=False):
    """Check six exact producer exports, not arbitrary PHI equivalence.

    The fixtures deliberately have a dedicated original exit. Only the named
    one-edge producer forwarding PHIs and original exit PHIs are accepted.
    The existing compact proof separately verifies P and reduction results,
    including its bounded repeated-LV consumer-exit forwarding case.
    """
    body = function_definition(ir, name)
    producer, consumer = scalar_consumer(body, name)
    base = COMPACT_CFG_BASES.get(name, EXPORT_CONTROL_BASES.get(name, name))
    extended = name in EXPORT_CONTROL_BASES or name in COMPACT_CFG_BASES
    compact = base in ('export_compact', 'export_nested')
    nested = base == 'export_nested'
    header = 'inner' if nested else 'loop'
    latch = 'loop' if base == 'export_unconditional' else 'latch'
    original_exit = 'row.exit' if nested else 'producer.exit'
    producer_exit = ('scalar.fission.consumer.guard' if compact else
                     'scalar.fission.consumer.ph')
    blocks = loop_blocks(body)

    def require(pattern, text):
        match = re.search(pattern, text, re.M)
        assert match, f'@{name}: producer export: {pattern}\n{text}'
        return match

    def phi(label, value, ty):
        line = require(rf'^  %{re.escape(value)} = phi {ty} (.+?)(?:, ![^\n]*)?$',
                       blocks[label])[1]
        inputs = re.findall(r'\[ ([^,\]\n]+), (%[-\w.$]+) \]', line)
        assert ', '.join(f'[ {v}, {edge} ]' for v, edge in inputs) == line, line
        return inputs

    def instructions(label):
        return [line.strip().split(', !', 1)[0]
                for line in blocks[label].splitlines()
                if line.strip() and not line.lstrip().startswith(';')]

    successors = {label: re.findall(r'\blabel %([-\w.$]+)', instructions(label)[-1])
                  for label in blocks}
    predecessors = lambda label: {pred for pred, targets in successors.items() if label in targets}
    # Ordinary LV adds the vector middle edge for unconditional consumers.
    # Every original export edge must carry exactly the producer forwarding
    # value. No PHI chasing (even for current/next IV) is needed or accepted.
    if compact:
        final_edges = {'scalar.fission.consumer.exit'}
    elif evl:
        final_edges = {'middle.block'}
    else:
        tail_label = 'scalar.fission.consumer.body'
        if extended:
            tail_exit = require(r'^  br i1 %fission\.consumer\.more, '
                                r'label %scalar\.fission\.consumer\.body, label %([-\w.$]+)',
                                blocks[tail_label])[1]
        else:
            tail_exit = require(r'^  br i1 %fission\.consumer\.done, '
                                r'label %([-\w.$]+), label %scalar\.fission\.consumer\.body',
                                blocks[tail_label])[1]
        if tail_exit != original_exit:
            # Repeated ordinary LV may dedicate this scalar exit. Accept at
            # most one block containing only each actual reduction update's
            # typed LCSSA PHI, then a branch to the original result join.
            assert predecessors(tail_exit) == {tail_label}, blocks[tail_exit]
            assert instructions(tail_exit)[-1] == f'br label %{original_exit}'
            remaining = {}
            for value, ty in [('r0', 'i32'), ('r1', 'i32'), ('rd', 'double'), ('rf', 'float')]:
                update = dict((edge, v) for v, edge in phi(tail_label, value + '.consume', ty))[
                    '%' + tail_label]
                remaining[(ty, update)] = value
            forwarding = instructions(tail_exit)[:-1]
            assert len(forwarding) == 4, blocks[tail_exit]
            for line in forwarding:
                match = re.fullmatch(r'%([-\w.$]+) = phi (i32|double|float) .+', line)
                assert match, line
                inputs = phi(tail_exit, match[1], match[2])
                assert len(inputs) == 1 and inputs[0][1] == '%' + tail_label, line
                assert remaining.pop((match[2], inputs[0][0]), None), line
            assert not remaining
        final_edges = {'middle.block', tail_exit if tail_exit != original_exit else tail_label}
    assert predecessors(original_exit) == final_edges, blocks[original_exit]
    require(rf'^  br i1 %done, label %{re.escape(producer_exit)}, '
            rf'label %{header}(?:, ![^\n]*)?$', blocks[latch])
    stateful = name in STATE_CFG_FUNCTIONS
    exports = [('x', 'i32', '-99'), ('c', 'i32', '-101'),
               ('c.copy', 'i32', '23' if stateful else '-101'), ('iv', 'i64', '-1'),
               ('next', 'i64', '0'), ('dc', 'double', '-0.000000e+00'),
               ('fc', 'float', '-0.000000e+00')]
    for value, ty, start in exports:
        producer_value = ('state.merge' if stateful else 'c') if value == 'c.copy' else value
        assert phi(producer_exit, producer_value + '.fission.export', ty) == [
            ('%' + producer_value, '%' + latch)], f'@{name}: producer export {value}: final latch value/edge'
        if not compact and evl:
            # VPlan deletes the unreachable scalar loop and its single-entry
            # exit PHIs. This one exact fold forwards our invariant directly;
            # it does not justify following any other PHI or recomputation.
            assert not re.search(rf'^  %out\.{re.escape(value)} = ',
                                 blocks[original_exit], re.M), blocks[original_exit]
            final_value = '%' + producer_value + '.fission.export'
        else:
            assert sorted(phi(original_exit, 'out.' + value, ty)) == sorted(
                ('%' + producer_value + '.fission.export', '%' + edge)
                for edge in final_edges), f'@{name}: producer export {value}: result value/edge'
            final_value = '%out.' + value
        if not nested:
            assert phi('exit', 'final.' + value, ty) == [
                (start, '%entry'), (final_value, '%producer.exit')], f'@{name}: producer export {value}: zero-entry/result edge'
    assert len(re.findall(r'^  %[-\w.$]+\.fission\.export = phi ', body, re.M)) == (7 if stateful else 6), body
    assert len(re.findall(r' = alloca ', body)) == 3, body
    assert len(re.findall(r' = load i32, ptr %p,', producer)) == 1, producer
    assert len(re.findall(r' = load double, ptr %dp,', producer)) == 1, producer
    assert '@scalar_helper' not in consumer, consumer
    assert not re.search(r'\bptr %(?:a|fp|base|dbase|p|dp)\b', consumer), consumer
    assert 'freeze ' not in body, body
    if not extended and base != 'export_unconditional':
        require(r'^  %choose = icmp ne i32 %x, 0$', blocks[header])
        require(r'^  br i1 %choose, label %left, label %right', blocks[header])
        require(r'^  %q = sdiv i32 840, %x$', blocks['left'])
        assert producer.count('sdiv ') == 1, producer
        require(r'^  %rc = xor i32 %x, 7$', blocks['right'])
        assert phi('latch', 'c', 'i32') == [('%lc', '%left'), ('%rc', '%right')]
        assert phi('latch', 'dc', 'double') == [('%ld', '%left'), ('-0.000000e+00', '%right')]
        assert phi('latch', 'fc', 'float') == [('%lf', '%left'), ('-0.000000e+00', '%right')]
        assert 'sdiv ' not in blocks[header] + blocks['right'] + blocks['latch']
        assert 'load double' not in blocks[header] + blocks['right'] + blocks['latch']
    if nested:
        assert phi('outer', 'salt', 'i32') == [('3', '%outer.ph'), ('%out.c', '%row.exit')], f'@{name}: export control: outer salt'
        for value, ty, start in [('carry', 'i32', '17'), ('carry1', 'i32', '-7'),
                                 ('dcarry', 'double', '%start'), ('fcarry', 'float', '%fstart')]:
            result = {'carry': 'r0', 'carry1': 'r1', 'dcarry': 'rd', 'fcarry': 'rf'}[value]
            assert phi('outer', value, ty) == [(start, '%outer.ph'),
                                               ('%out.' + result, '%row.exit')]
    check_loop_provenance(ir, blocks[latch], 'producer')
    for label, code in blocks.items():
        if label.startswith('vector.body') or label == 'scalar.fission.consumer.body':
            check_loop_provenance(ir, code, 'consumer')
    if extended:
        assert source is not None, 'original producer required for ' + name
        check_export_control_producer(body, function_definition(source, name),
                                      name, header, latch, producer_exit, compact)
        if stateful:
            check_state_cfg_retention(body, function_definition(source, name), name)
            if not evl:
                require(r'^  %fission\.consumer\.next = add nuw(?: nsw)? i64 '
                        r'%fission\.consumer\.iv, 1(?:, ![^\n]*)?$',
                        blocks['scalar.fission.consumer.body'])
    if scalar:
        assert stateful and not evl
        edges = check_compact_cfg_producer(producer, name)
        starts = [('r0', 'i32', '17'), ('r1', 'i32', '-7'),
                  ('rd', 'double', '%start'), ('rf', 'float', '%fstart')]
        check_compact_count(producer, consumer, base, False, starts=starts,
                            vectorized=False, bypass_edges=edges)
        assert '<vscale x' not in body, body
        tail = blocks['scalar.fission.consumer.body']
        for value, ty, _ in starts:
            update = dict((edge, v) for v, edge in phi(
                'scalar.fission.consumer.body', value + '.consume', ty))[
                    '%scalar.fission.consumer.body']
            operation = 'add' if ty == 'i32' else 'fadd'
            operands = require(rf'^  {re.escape(update)} = {operation} {ty} '
                               r'(%[-\w.$]+), (%[-\w.$]+)(?:, ![^\n]*)?$', tail)
            accumulator = '%' + value + '.consume'
            assert [operands[1], operands[2]].count(accumulator) == 1, tail
            if ty != 'i32':
                assert operands[1] == accumulator, tail
            contribution = operands[2] if operands[1] == accumulator else operands[1]
            require(rf'^  {re.escape(contribution)} = load {ty}, ptr %[-\w.$]+(?:,|$)', tail)
        checked = body
        if probe:
            for label, recorder in [('loop', 'compact_iteration'), ('left', 'compact_participant'),
                                     ('scalar.fission.consumer.body', 'scalar_consumer_tail')]:
                checked, count = re.subn(
                    rf'(^{re.escape(label)}:[^\n]*\n(?:[^\n]* = phi [^\n]*\n)*)',
                    rf'\1  call void @record_{recorder}()\n', checked, flags=re.M)
                assert count == 1, label
    else:
        checked = check_scalar_function(ir, name, evl, probe=probe)
    if probe:
        if not compact:
            checked, count = re.subn(
                rf'(^{header}:[^\n]*\n(?:[^\n]* = phi [^\n]*\n)*)',
                r'\1  call void @record_compact_iteration()\n'
                r'  call void @record_compact_participant()\n', checked, flags=re.M)
            assert count == 1, checked
        else:
            checked, count = re.subn(
                r'(^scalar\.fission\.consumer\.guard:[^\n]*\n(?:[^\n]* = phi [^\n]*\n)*)',
                r'\1  call void @record_export_guard(i64 %fission.participating.count)\n',
                checked, flags=re.M)
            assert count == 1, checked
        # Count the actual original entry-bypass edge, rather than inferring
        # execution from input N. This block exists only in host probe IR.
        checked, count = re.subn(
            r'(br i1 %(?:inner\.enter|enter), label %(?:preheader|outer\.ph), label %)exit\b',
            r'\1export.zero.entry', checked)
        assert count == 1, checked
        exit_block = loop_blocks(checked)['exit']
        forwarded_bypass = re.sub(r'( = phi [^\n]*?)%entry(?= \])',
                                   r'\1%export.zero.entry', exit_block)
        exit_label = require(r'^exit:[^\n]*\n', checked)
        assert checked[exit_label.end():].startswith(exit_block), checked
        checked = (checked[:exit_label.start()] + 'export.zero.entry:\n'
                   '  call void @record_export_bypass()\n'
                   '  br label %exit\n\nexit:\n' + forwarded_bypass +
                   checked[exit_label.end() + len(exit_block):])
        if base != 'export_unconditional':
            checked, count = re.subn(
                rf'(^{original_exit}:[^\n]*\n(?:[^\n]* = phi [^\n]*\n)*)',
                r'\1  call void @record_export_final(i32 %out.x)\n', checked, flags=re.M)
            assert count == 1, checked
        if name in COMPACT_CFG_BASES:
            edges = check_compact_cfg_producer(producer, name)
            for index, edge in enumerate(edges):
                checked, count = re.subn(
                    rf'(^{edge}:[^\n]*\n(?:[^\n]* = phi [^\n]*\n)*)',
                    rf'\1  call void @record_compact_cfg_bypass(i32 {index})\n',
                    checked, flags=re.M)
                assert count == 1, f'@{name}: missing bypass probe {edge}'
    return checked


def lower_fixed_deinterleaves(ir):
    """Host adapter for canonical, direct, fixed-width deinterleave calls.

    For transformed fission IR, run after the unchanged scalable module passes
    RVV machine verification. Standalone fixed-width probes test this adapter
    separately. Some host backends cannot select deinterleave factors > 4.
    Expand each call in place: member j, lane k is input[F*k+j]. All masks
    select the first shuffle operand, so poison/undef in an input lane stays
    confined to that lane; no freeze or noundef assumption is introduced.
    Every aggregate member is inserted exactly once, preserving extractvalue
    identity and repeated uses without touching loads, CFG, or scratch.

    This is deliberately not an LLVM IR parser. Accept the canonical forms
    emitted by opt, validate both declarations and calls against the mangled
    signature, and fail closed on other uses/forms instead of leaving a host
    intrinsic behind. Integer, float and double SSA/poison/undef/zero inputs
    suffice for this checker; pointers and other FP formats are unsupported.
    """
    prefix = '@llvm.vector.deinterleave'
    symbol = re.compile(r'@llvm\.vector\.deinterleave[^\s(,]*')
    local = r'%[-a-zA-Z$._0-9]+'
    vector = r'<\s*[1-9][0-9]*\s+x\s+(?:i[1-9][0-9]*|float|double)\s*>'
    declaration = re.compile(
        r'\s*declare\s+(?P<result>\{[^{}]+\})\s+@[^ (]+\('
        rf'(?P<input>{vector})\)\s*(?:#\d+)?\s*')
    call = re.compile(
        rf'(?P<indent>[ \t]*)(?P<name>{local})\s*=\s*'
        r'(?:(?:tail|notail)\s+)?call\s+(?P<result>\{[^{}]+\})\s+@[^ (]+\('
        rf'(?P<input>{vector})\s+(?P<operand>{local}|poison|undef|zeroinitializer)'
        r'\)(?:\s+#\d+)?(?P<debug>(?:,\s*!dbg\s+!\d+)?)\s*')

    def compact(text):
        return re.sub(r'\s+', '', text)

    signatures, declarations, calls = {}, {}, {}
    lines = ir.splitlines(keepends=True)
    for index, line in enumerate(lines):
        code = line.split(';', 1)[0].rstrip()
        if not re.search(r'@"?llvm\.vector\.deinterleave', code):
            continue
        refs = list(symbol.finditer(code))
        if len(refs) != 1:
            raise ValueError(f'unsupported deinterleave reference: {code}')
        intrinsic = refs[0][0]
        overload = re.fullmatch(
            r'@llvm\.vector\.deinterleave([2-8])\.v([1-9][0-9]*)'
            r'(i[1-9][0-9]*|f32|f64)', intrinsic)
        if not overload:
            raise ValueError(f'unsupported fixed deinterleave signature: {intrinsic}')
        factor, width = int(overload[1]), int(overload[2])
        element = {'f32': 'float', 'f64': 'double'}.get(overload[3], overload[3])
        if width % factor or width > 2147483647:
            raise ValueError(f'invalid deinterleave input width: {intrinsic}')
        lanes = width // factor
        input_type = f'<{width} x {element}>'
        member_type = f'<{lanes} x {element}>'
        result_type = '{ ' + ', '.join([member_type] * factor) + ' }'
        decl, invocation = declaration.fullmatch(code), call.fullmatch(code)
        match = decl or invocation
        if not match:
            raise ValueError(f'unsupported deinterleave form: {code}')
        # Whitespace is immaterial, but all member types/counts and the input
        # type must agree with the one overload. Do not infer from a fixture.
        if (compact(match['result']) != compact(result_type) or
                compact(match['input']) != compact(input_type)):
            raise ValueError(f'inconsistent deinterleave signature: {code}')
        signatures[intrinsic] = (factor, lanes, input_type, member_type, result_type)
        if decl:
            if intrinsic in declarations:
                raise ValueError(f'duplicate deinterleave declaration: {intrinsic}')
            declarations[intrinsic] = index
        else:
            calls[index] = (intrinsic, invocation)
    missing = signatures.keys() - declarations.keys()
    if missing:
        raise ValueError(f'missing deinterleave declarations: {sorted(missing)}')

    # Use named temporaries even in modules with numbered SSA values. Avoid
    # collisions with both values and labels, across every function.
    used = set(re.findall(local, ir))
    used.update('%' + label for label in re.findall(r'^([-a-zA-Z$._0-9]+):', ir, re.M))
    # A quoted/hex-escaped name elsewhere in the module can denote the same
    # identifier as a generated bare name, even though call operands are bare.
    quoted = r'"((?:[^"\\]|\\[0-9a-fA-F]{2})*)"'
    for name in re.findall('%' + quoted, ir) + re.findall('^' + quoted + ':', ir, re.M):
        name = re.sub(r'\\([0-9a-fA-F]{2})', lambda m: chr(int(m[1], 16)), name)
        used.add('%' + name)
    serial = 0

    def fresh():
        nonlocal serial
        while True:
            name = f'%host.deinterleave.{serial}'
            serial += 1
            if name not in used:
                used.add(name)
                return name

    for index, (intrinsic, invocation) in calls.items():
        factor, lanes, input_type, member_type, result_type = signatures[intrinsic]
        indent, debug = invocation['indent'], invocation['debug']
        aggregate, expanded = 'poison', []
        for member in range(factor):
            value = fresh()
            mask = ', '.join(f'i32 {factor * lane + member}' for lane in range(lanes))
            expanded.append(
                f'{indent}{value} = shufflevector {input_type} {invocation["operand"]}, '
                f'{input_type} poison, <{lanes} x i32> <{mask}>{debug}')
            result = invocation['name'] if member == factor - 1 else fresh()
            expanded.append(
                f'{indent}{result} = insertvalue {result_type} {aggregate}, '
                f'{member_type} {value}, {member}{debug}')
            aggregate = result
        comment = lines[index].partition(';')[2].rstrip()
        if comment:
            expanded[-1] += ' ;' + comment
        lines[index] = '\n'.join(expanded) + '\n'
    for index in declarations.values():
        lines[index] = ''
    result = ''.join(lines)
    if any(prefix in line.split(';', 1)[0] for line in result.splitlines()):
        raise ValueError('unlowered deinterleave reference')
    return result


def deinterleave_adapter_cases():
    """Independent host adapter probes; the C oracle uses scalar indexing.

    These fixed-width probes test the adapter, not RVV target legality. Each
    aggregate member is extracted twice, with the second use stored in reverse
    member order. Width one and non-power-of-two widths exercise boundaries;
    width 128 covers the largest specialization in the fission matrix.
    """
    definitions, declarations, cases, poison_cases = [], {}, [], []
    for factor, lanes, (element, code, size) in product(
        range(2, 9), (1, 2, 3, 4, 8, 32, 64, 128),
        (('i32', 'i32', 4), ('i64', 'i64', 8), ('double', 'f64', 8)),
    ):
        count = factor * lanes
        wide, member = f'<{count} x {element}>', f'<{lanes} x {element}>'
        aggregate = '{ ' + ', '.join([member] * factor) + ' }'
        intrinsic = f'@llvm.vector.deinterleave{factor}.v{count}{code}'
        declarations[intrinsic] = f'declare {aggregate} {intrinsic}({wide})'
        name = f'adapter_{factor}_{lanes}_{code}'
        body = [f'define void @{name}(ptr %input, ptr %output) {{',
                f'  %wide = load {wide}, ptr %input, align {size}',
                f'  %parts = call {aggregate} {intrinsic}({wide} %wide)']
        for use, j in product(range(2), range(factor)):
            slot = (j if use == 0 else factor - 1 - j) + use * factor
            body += [
                f'  %v{use}_{j} = extractvalue {aggregate} %parts, {j}',
                f'  %p{use}_{j} = getelementptr {element}, ptr %output, i64 {slot * lanes}',
                f'  store {member} %v{use}_{j}, ptr %p{use}_{j}, align {size}',
            ]
        definitions.append('\n'.join(body + ['  ret void', '}']))
        cases.append({'function': name, 'factor': factor, 'lanes': lanes,
                      'element': element, 'element_bytes': size})

        if element == 'i32' and lanes in (1, 3):
            # Only these two defined lanes are observed. Poison in every
            # other input lane must not contaminate either selected lane.
            name = f'adapter_poison_{factor}_{lanes}'
            definitions.append('\n'.join([
                f'define i32 @{name}() {{',
                f'  %first = insertelement {wide} poison, i32 17, i64 0',
                f'  %last = insertelement {wide} %first, i32 -19, i64 {count - 1}',
                f'  %parts = call {aggregate} {intrinsic}({wide} %last)',
                f'  %a = extractvalue {aggregate} %parts, 0',
                f'  %b = extractvalue {aggregate} %parts, {factor - 1}',
                f'  %x = extractelement {member} %a, i64 0',
                f'  %y = extractelement {member} %b, i64 {lanes - 1}',
                '  %r = xor i32 %x, %y', '  ret i32 %r', '}',
            ]))
            poison_cases.append(name)
    ir = '\n\n'.join(definitions + list(declarations.values())) + '\n'
    return ir, cases, poison_cases

def affine_instruction_refines(original, candidate, normalize):
    if normalize(original) == normalize(candidate):
        return True
    # Dropping nuw/nsw refines poison to the integer operation's wrapping
    # result. On every originally defined execution the result is unchanged.
    # This is deliberately one-way, scalar-integer-only, and cannot change an
    # opcode, type, operand, other flag, or placement. In particular it does not
    # admit added flags, exact/disjoint changes, FP flags, or reassociation.
    integer = re.compile(r'\s*(%[-\w.$]+) = (add|sub|mul|shl)'
                         r'((?: (?:nuw|nsw))*) (i[1-9]\d*) '
                         r'(%[-\w.$]+|-?\d+), (%[-\w.$]+|-?\d+)\s*')
    old, new = (integer.fullmatch(line.split(', !', 1)[0])
                for line in (original, candidate))
    if not old or not new:
        return False
    for instruction in (old, new):
        flags = instruction[3].split()
        if len(flags) != len(set(flags)):
            return False
        width = int(instruction[4][1:])
        for operand in (instruction[5], instruction[6]):
            if not operand.startswith('%') and not -(1 << (width - 1)) <= int(operand) < (1 << width):
                return False
        if instruction[2] == 'shl':
            # Only the demonstrated constant, in-range shift form is checked.
            if instruction[6].startswith('%') or not 0 <= int(instruction[6]) < width:
                return False
    return (tuple(old[i] for i in (1, 2, 4, 5, 6)) ==
            tuple(new[i] for i in (1, 2, 4, 5, 6)) and
            set(new[3].split()) <= set(old[3].split()))


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

    def definitions(text):
        result = {}
        for label, block in blocks(text).items():
            for position, line in enumerate(block.splitlines()):
                definition = re.fullmatch(r'  (%[-\w.$]+) = (.+)', line.split(', !', 1)[0])
                if definition:
                    value, expression = definition.groups()
                    assert value not in result, (name, 'duplicate SSA definition', value)
                    result[value] = (label, position, expression)
        arguments = set(re.findall(r'%[-\w.$]+', text.split('{', 1)[0]))
        assert not arguments.intersection(result), (name, 'redefined argument')
        return result

    definitions(original)
    defined = definitions(body)
    after_instructions = {
        label: {normalize(line) for line in block.splitlines() if line.strip()}
        for label, block in after.items()
    }
    labels = list(before)
    labels = labels[labels.index(header):labels.index('latch') + 1]

    def full_count_kind():
        # Small certificates for these fixtures, independent of function names.
        # Matching an SSA name alone proves nothing: check its defining i64
        # arithmetic, guard dominance, all producer edges and the actual exit.
        # No relational modular early-exit sibling has one of these controls.
        def has(block, *instructions):
            return all(any(affine_instruction_refines('  ' + instruction, line, normalize)
                           for line in block.splitlines()) for instruction in instructions)

        def instructions(block):
            return [line.split(', !', 1)[0].strip() for line in block.splitlines()
                    if line.strip() and not line.lstrip().startswith(';')]

        def edges(block):
            lines = instructions(block)
            branches = [line for line in lines if line.startswith('br ')]
            if len(branches) != 1 or branches[0] != lines[-1]:
                return None
            return re.findall(r'label %([-\w.$]+)', branches[0])

        def incoming(table, destination):
            # Count label operands even on an unexpected switch/invoke, so
            # an unsupported terminator cannot hide an extra predecessor.
            return sorted(label for label, block in table.items()
                          for line in instructions(block)
                          for target in re.findall(r'\blabel %([-\w.$]+)', line)
                          if target == destination)

        def enclosing_exit(table):
            # Ordinary LV may split the outer exit edge for LoopSimplify.
            # Discover that dedicated block from the true successor, never
            # from its name. The row comparison/polarity and false backedge
            # must remain exact. Accept at most one forwarding hop containing
            # only an unconditional branch: no PHIs, calls or other work.
            successors = edges(table['row.exit'])
            if not successors or len(successors) != 2:
                return False
            destination, backedge = successors
            if backedge != 'outer' or not has(
                    table['row.exit'],
                    f'br i1 %rows.done, label %{destination}, label %outer'):
                return False
            predecessor = 'row.exit'
            if destination != 'exit':
                if (destination not in table or
                        incoming(table, destination) != ['row.exit'] or
                        instructions(table[destination]) != ['br label %exit']):
                    return False
                predecessor = destination
            # Entry must still bypass the whole nest on a failed guard. No
            # other edge may bypass the row exit or join its forwarding hop.
            return incoming(table, 'exit') == sorted(['entry', predecessor])

        if not has(before['entry'], '%valid = icmp ule i64 %n, 65',
                   '%nonzero = icmp ne i64 %n, 0'):
            return None
        if not all(re.search(r'(?:\(|,)\s*i64 %n(?=[,)])', text.split('{', 1)[0])
                   for text in (original, body)):
            return None
        # Verify the finite, forward producer DAG. Every entered iteration
        # reaches the latch exactly once; its branch is the only loop exit.
        region = [ph] + labels
        exit_label = 'row.exit' if enclosing else 'exit'
        for i, label in enumerate(region):
            successors = edges(before[label])
            if not successors or (label != 'latch' and any(
                    target not in region[i + 1:] for target in successors)):
                return None
            if label == 'latch' and sorted(successors) != sorted([header, exit_label]):
                return None
            replacement = ['scalar.fission.consumer.ph' if t == exit_label else t
                           for t in successors]
            if edges(after[label]) != replacement:
                return None
        for table in (before, after):
            if incoming(table, header) != sorted([ph, 'latch']):
                return None
            if incoming(table, ph) != (['outer'] if enclosing else ['entry']):
                return None
        if incoming(after, 'scalar.fission.consumer.ph') != ['latch']:
            return None
        consumer_edges = ['vector.ph'] if evl else ['scalar.ph', 'vector.ph']
        if (edges(after['scalar.fission.consumer.ph']) != consumer_edges or
                incoming(after, 'vector.ph') != ['scalar.fission.consumer.ph'] or
                edges(after['vector.ph']) != ['vector.body']):
            return None
        if enclosing:
            for table in (before, after):
                if not (has(table['entry'], '%rows.valid = icmp ule i64 %rows, 4',
                            '%rows.nonzero = icmp ne i64 %rows, 0',
                            '%rows.enter = and i1 %rows.valid, %rows.nonzero',
                            '%inner.enter = and i1 %valid, %nonzero',
                            '%enter = and i1 %rows.enter, %inner.enter',
                            'br i1 %enter, label %outer.ph, label %exit') and
                        has(table['outer.ph'], 'br label %outer') and
                        has(table['outer'], '%row = phi i64 [ 0, %outer.ph ], [ %row.next, %row.exit ]',
                            'br label %inner.ph') and
                        has(table['row.exit'], '%row.next = add nuw i64 %row, 1',
                            '%rows.done = icmp eq i64 %row.next, %rows') and
                        edges(table['entry']) == ['outer.ph', 'exit'] and
                        edges(table['outer.ph']) == ['outer'] and
                        edges(table['outer']) == ['inner.ph'] and
                        enclosing_exit(table) and
                        incoming(table, 'outer.ph') == ['entry'] and
                        incoming(table, 'outer') == ['outer.ph', 'row.exit']):
                    return None
        elif not has(before['entry'], '%enter = and i1 %valid, %nonzero',
                     'br i1 %enter, label %preheader, label %exit'):
            return None

        # 1<=n<=65. Each tuple describes the *completed* count, not a storage
        # bound. Relational forms have bounded origins and cannot wrap. For the
        # equality wrap form, +2 first reaches begin+2*n at n (<2^63) steps.
        controls = [
            ('unit', '7', ['%limit = add nuw nsw i64 %n, 7'],
             '%next = add nuw nsw i64 %iv, 1', '%done = icmp eq i64 %limit, %next', False),
            ('twice', '%origin', ['%bits = and i64 %begin, 31',
             '%origin = add nuw nsw i64 %bits, 1', '%span = shl nuw nsw i64 %n, 1',
             '%limit = add nuw nsw i64 %origin, %span'],
             '%next = add nuw nsw i64 %iv, 2', '%done = icmp ne i64 %next, %limit', True),
            ('thirds', '9', ['%span = mul nuw nsw i64 %n, 3',
             '%limit = add nuw nsw i64 %span, 9'],
             '%next = add nuw nsw i64 %iv, 3', '%done = icmp ult i64 %next, %limit', True),
            ('signed', '%origin', ['%origin = or i64 %begin, -32',
             '%span = shl nuw nsw i64 %n, 1', '%limit = add nsw i64 %origin, %span'],
             '%next = add nsw i64 %iv, 2', '%done = icmp sgt i64 %limit, %next', True),
            ('down', '201', ['%span = mul nuw nsw i64 %n, 3',
             '%limit = sub nuw nsw i64 201, %span'],
             '%next = sub nuw nsw i64 %iv, 3', '%done = icmp ugt i64 %next, %limit', True),
            ('signed.down', '%origin', ['%bits = and i64 %begin, 31',
             '%origin = sub nsw i64 %bits, 17', '%span = shl nuw nsw i64 %n, 1',
             '%limit = sub nsw i64 %origin, %span'],
             '%next = add nsw i64 %iv, -2', '%done = icmp sge i64 %limit, %next', False),
            ('twice', '%begin', ['%span = shl nuw nsw i64 %n, 1',
             '%limit = add i64 %begin, %span'],
             '%next = add i64 %iv, 2', '%done = icmp eq i64 %limit, %next', False),
            ('current', '7', ['%last = sub nuw nsw i64 %n, 1',
             '%span = shl nuw nsw i64 %last, 1', '%limit = add nuw nsw i64 %span, 7'],
             '%next = add nuw nsw i64 %iv, 2', '%done = icmp uge i64 %iv, %limit', False),
        ]
        if enclosing:
            # 0<=row<rows<=4, origin=row+5, last next=origin+2*n<=138.
            controls = [('enclosing', '%origin', ['%origin = add nuw nsw i64 %row, 5',
                         '%span = shl nuw nsw i64 %n, 1',
                         '%limit = add nuw nsw i64 %origin, %span'],
                         '%next = add nuw nsw i64 %iv, 2',
                         '%done = icmp slt i64 %next, %limit', True)]
        for kind, origin, setup, step, comparison, continue_true in controls:
            true, false = (header, exit_label) if continue_true else (exit_label, header)
            if (has(before[ph], *setup) and
                    has(before[header], f'%iv = phi i64 [ {origin}, %{ph} ], [ %next, %latch ]') and
                    has(before['latch'], step, comparison,
                        f'br i1 %done, label %{true}, label %{false}')):
                return kind
        return None

    def count_expressions(kind):
        # Recognize only retained straight-line expansion chains. Each operand
        # is the preceding checked SSA definition; every operation is i64 and
        # stays in this block, in this order. No arbitrary live-in, cast, PHI,
        # or same-valued/dead instruction can establish count provenance.
        patterns = {
            # span=2*n in [2,130]: ((span-2)>>1)+1=n, including n=1.
            'twice': [('add i64 %span, -2', 'lshr i64 {0}, 1', 'add nuw i64 {1}, 1'),
                      ('sub i64 %span, 2', 'lshr i64 {0}, 1', 'add nuw i64 {1}, 1')],
            # n=1: umin(3*n-3,1)=0. n>=2: it is 1, and
            # floor((3*n-4)/3)=n-2. Both paths therefore yield n.
            'thirds': [('add i64 %span, -3', 'call i64 @llvm.umin.i64(i64 {0}, i64 1)',
                        'sub i64 %span, {1}', 'add i64 {2}, -3', 'udiv i64 {3}, 3',
                        'add i64 {1}, {4}', 'add i64 {5}, 1')],
            # origin in [-32,-1], limit=origin+2*n >= origin+2.
            'signed': [('add nsw i64 %origin, 2',
                        'call i64 @llvm.smax.i64(i64 %limit, i64 {0})',
                        'sub i64 {1}, %origin', 'add i64 {2}, -1',
                        'lshr i64 {3}, 1', 'add nuw i64 {4}, 1')],
            # bits in [0,31], origin=bits-17, limit=origin-2*n <= bits-19.
            'signed.down': [('add nsw i64 %bits, -19',
                             'call i64 @llvm.smin.i64(i64 %limit, i64 {0})',
                             'sub i64 %bits, {1}', 'add i64 {2}, -18',
                             'lshr i64 {3}, 1', 'add nuw i64 {4}, 1')],
            # Current-IV test performs the last contribution before exiting.
            'current': [('shl i64 %n, 1', 'add i64 {0}, -1',
                         'lshr i64 {1}, 1', 'add nuw i64 {2}, 1')],
            # smax(row+5+2*n,row+7)=row+5+2*n; subtract row+6.
            # Checked outer guard and recurrence above establish 0<=row<=3.
            'enclosing': [('shl i64 %n, 1', 'add i64 {0}, 5', 'add i64 {1}, %row',
                           'add i64 %row, 7', 'call i64 @llvm.smax.i64(i64 {2}, i64 {3})',
                           'mul nsw i64 %row, -1', 'add i64 {5}, -6',
                           'add i64 {4}, {6}', 'lshr i64 {7}, 1', 'add nuw i64 {8}, 1')],
        }
        # The enclosing chain spans two checked dominating blocks. All other
        # observed chains are wholly in the single-entry consumer preheader.
        locations = (['outer.ph', 'outer'] if kind == 'enclosing'
                     else ['scalar.fission.consumer.ph'])
        instructions = [(value, label, expression) for value, (label, _, expression) in defined.items()
                        if label in locations and not (kind == 'enclosing' and expression.startswith('phi '))]
        aliases = []
        for pattern in patterns.get(kind, []):
            for start in range(len(instructions) - len(pattern) + 1):
                values = []
                for (value, label, expression), expected in zip(instructions[start:], pattern):
                    expected_block = ('outer.ph' if len(values) < 2 else 'outer') if kind == 'enclosing' else locations[0]
                    if label != expected_block or not affine_instruction_refines(
                            '  ' + value + ' = ' + expected.format(*values),
                            '  ' + value + ' = ' + expression, normalize):
                        break
                    values.append(value)
                else:
                    aliases.append(values[-1])
        return aliases

    # The fixtures deliberately use the IV in addressing and internal control.
    # Require every retained instruction/edge in its original block, including
    # operand order. Integer nowrap flags may only be removed by the refinement
    # above. Only reduction state and the exit edge otherwise change.
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
            value = re.match(r'  (%[-\w.$]+) = ', line)
            candidate = defined.get(value[1]) if value else None
            assert (normalize(line) in after_instructions[label] or
                    (candidate and candidate[0] == label and affine_instruction_refines(
                        line, '  ' + value[1] + ' = ' + candidate[2], normalize))), (name, label, line, body)
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
        # The zero-based ordinal advances once at the sole latch, including
        # the exiting iteration. The finite producer DAG and capacity proof
        # bound N by 65, so ordinal+1 is exactly the actual completed count
        # and cannot overflow i64, even for modular early exits where N<n.
        # Ordinary LV may remove its nuw flag. The same one-way refinement as
        # for retained arithmetic preserves every originally defined result;
        # it cannot change this SSA identity, type, operands, step or block.
        # The ordinal and completed-export PHIs still require exact edges.
        for value, label, expression in [
            ('%fission.ordinal', header,
             f'phi i64 [ 0, %{ph} ], [ %fission.completed, %latch ]'),
            ('%fission.completed', 'latch', 'add nuw i64 %fission.ordinal, 1'),
            ('%fission.completed.count', 'scalar.fission.consumer.ph',
             'phi i64 [ %fission.completed, %latch ]'),
        ]:
            assert value in defined and defined[value][0] == label, (name, value, body)
            if value == '%fission.completed':
                assert affine_instruction_refines(
                    '  ' + value + ' = ' + expression,
                    '  ' + value + ' = ' + defined[value][2], normalize), (name, value, body)
            else:
                assert normalize(defined[value][2]) == normalize(expression), (name, value, body)
        # Permit n and observed expanded expressions only after a certificate
        # for the original control proves N=n. An equality witness bounding
        # storage is insufficient, particularly for modular relational exits.
        # Function names are never count certificates.
        counts = ['%fission.completed', '%fission.completed.count']
        kind = full_count_kind()
        if kind:
            counts.append('%n')
            counts.extend(count_expressions(kind))
        for value, incoming in re.findall(
                r'^  (%[-\w.$]+) = phi i64 \[ (%[-\w.$]+), %latch \](?:, ![^\n]*)?$',
                consumer, re.M):
            if incoming == '%fission.completed' and defined[value][0] == 'scalar.fission.consumer.ph':
                counts.append(value)
        count = '(?:' + '|'.join(map(re.escape, counts)) + ')'
        if evl:
            assert re.search(rf'^  %avl = phi i64 \[ {count}, %vector\.ph \], '
                             r'\[ %avl\.next, %vector\.body \](?:, ![^\n]*)?$', consumer, re.M), body
        else:
            for instruction in [rf'%min\.iters\.check = icmp ult i64 {count}, %[-\w.$]+',
                                rf'%n\.mod\.vf = urem i64 {count}, %[-\w.$]+',
                                rf'%n\.vec = sub i64 {count}, %n\.mod\.vf',
                                rf'%fission\.consumer\.more = icmp ne i64 '
                                rf'%fission\.consumer\.next, {count}']:
                assert re.search(rf'^  {instruction}(?:, ![^\n]*)?$', consumer, re.M), (name, instruction, body)
    vector = re.search(r'^vector\.body[^:]*:[^\n]*\n(.*?)(?=^[\w.$-]+:|^})',
                       consumer, re.M | re.S)
    assert vector, f'@{name}: missing vector consumer\n{body}'
    intrinsic = r'vp\.reduce' if evl else r'vector\.reduce'
    for ty, suffix in [('double', 'f64')] + ([] if enclosing else [('float', 'f32')]):
        assert re.search(rf'call {ty} @llvm\.{intrinsic}\.fadd\.nxv4{suffix}\(', vector[0]), body
    assert '@llvm.vector.reduce.add.nxv4i32' in consumer, body
    load = r'call <vscale x 4 x i32> @llvm\.vp\.load\.' if evl else r'load <vscale x 4 x i32>'
    assert len(re.findall(load, vector[0])) == 1, body
    assert not re.search(r'\b(?:fadd|fsub|fmul|fdiv|frem|fcmp|call)\s+'
                         r'(?:fast|reassoc|nnan|ninf|nsz|arcp|contract|afn)\b', body), body
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


# Explicit reserved-byte expectations follow the fixture's stream order.
# Integer-first i32[65], double[65] needs 260+4+520=784 bytes; reversed
# accumulator PHIs in recurrence_runtime give double[65], i32[65], hence
# 520+260=780. There is no padding after the last stream. Capacity and
# traffic are separate: both orders store/load 12 bytes each per iteration.
# Keep this table visible to the focused lit regression as well as execution.
RECURRENCE_CASES = [
    ('recurrence_first', 65, False, False, False, 12, 260 + 4 + 520),
    ('recurrence_two', 65, True, False, False, 22, 260 + 4 + 520),
    ('recurrence_affine', 65, True, False, False, 32, 260 + 4 + 520),
    ('recurrence_runtime', 65, True, False, False, 42, 520 + 260),
    ('recurrence_branch', 65, True, True, False, 52, 260 + 4 + 520),
    ('recurrence_enclosing', 65, True, True, True, 62, 260 + 4 + 520),
    ('recurrence_first_affine', 65, False, True, False, 102, 260 + 4 + 520),
    ('recurrence_first_enclosing', 65, False, True, True, 112, 260 + 4 + 520),
    ('recurrence_one', 1, True, False, False, 72, 4 + 4 + 8),
    ('recurrence_255', 255, True, False, False, 82, 1020 + 4 + 2040),
    ('recurrence_limit', 5461, True, False, False, 92, 21844 + 4 + 43688),
]

# name, full-trip capacity, conditional state update, enclosing reuse,
# original-loop location, insertion-order reserved bytes (no final padding).
COMPACT_RECURRENCE_CASES = [
    ('compact_recurrence', 65, False, False, 12, 260 + 4 + 520),
    ('compact_recurrence_reverse', 65, False, False, 22, 520 + 260),
    ('compact_recurrence_merge', 65, True, False, 32, 260 + 4 + 520),
    ('compact_recurrence_affine', 65, True, False, 42, 260 + 4 + 520),
    ('compact_recurrence_runtime', 65, False, False, 52, 520 + 260),
    ('compact_recurrence_enclosing', 65, True, True, 62, 260 + 4 + 520),
    ('compact_recurrence_one', 1, True, False, 72, 4 + 4 + 8),
    ('compact_recurrence_255', 255, False, False, 82, 1020 + 4 + 2040),
    ('compact_recurrence_limit', 5461, True, False, 92, 21844 + 4 + 43688),
]

# Historical whole-loop rejections become safe retention/export cases when
# integrating the two contracts. Keep the exact original functions executable.
RETAINED_EXPORT_CASES = (
    ('recurrence_phi_feedback', 0), ('recurrence_update_feedback', 1),
    ('recurrence_other_reduction', 2), ('recurrence_address_feedback', 3),
    ('recurrence_predicate_feedback', 4), ('recurrence_partial_export', 5),
    ('recurrence_state_export', 6), ('compact_recurrence_reject_predicate', 7),
    ('compact_recurrence_reject_state', 8), ('compact_recurrence_reject_address', 9),
    ('compact_recurrence_reject_state_export', 10),
)


def check_retained_export(ir, source, name, mode, vectorized, evl, probe=False):
    body, original = (function_definition(text, name) for text in (ir, source))
    producer, consumer = scalar_consumer(body, name)
    moved = ['r1', 'rd', 'u1', 'ud'] + (['m1', 'md'] if mode >= 7 else [])
    if mode in (6, 10):
        moved += ['r0', 'u0'] + (['m0'] if mode == 10 else [])
    pattern = re.compile(r'  %(?:' + '|'.join(moved) + ') = ')
    before, after = loop_blocks(original), loop_blocks(producer)
    latch = 'latch' if 'latch' in before else 'loop'
    target = 'scalar.fission.consumer.guard' if mode >= 7 else 'scalar.fission.consumer.ph'
    def normalize(s):
        s = s.split(', !', 1)[0]
        s = re.sub(r'(?<![\w.])(-?\d+\.\d+(?:[eE][+-]?\d+)?)(?![\w.])',
                   lambda m: float(m[0]).hex(), s)
        return re.sub(r'\s+', '', s)
    for label in list(before)[:list(before).index(latch) + 1]:
        position = -1
        for line in before[label].splitlines():
            if not line.strip() or line.lstrip().startswith(';') or pattern.match(line):
                continue
            if label == latch and line.startswith('  br '):
                line = line.replace('label %exit,', 'label %' + target + ',')
            # Normalize decimal signed zero consistently with LLVM printing.
            line = line.replace('-0.0,', '-0.000000e+00,')
            matches = [i for i, candidate in enumerate(after[label].splitlines())
                       if affine_instruction_refines(line, candidate, normalize)]
            assert len(matches) == 1 and matches[0] > position, (
                f'@{name}: retained export instruction/order: {line}')
            position = matches[0]
    assert not re.search(pattern, producer), name + ': moved state still in producer'
    for value in ['r1', 'rd'] + (['r0'] if mode in (6, 10) else []):
        assert '%' + value + '.consume = phi ' in consumer or evl, name
    if mode not in (6, 10):
        assert '%r0 = phi i32' in producer and '%r0.consume = phi ' not in consumer, name
    assert producer.count('call i32 @scalar_helper(') == original.count('call i32 @scalar_helper('), name
    assert '@scalar_helper(' not in consumer, name
    assert body.count('alloca [65 x i32]') == body.count('alloca [65 x double]') == 1, name
    assert 'reassoc' not in body and ' fast ' not in body, name
    check_loop_provenance(ir, after[latch], 'producer')
    for label, code in loop_blocks(body).items():
        if label.startswith('vector.body') or label == 'scalar.fission.consumer.body':
            check_loop_provenance(ir, code, 'consumer')
    if vectorized:
        assert 'vector.body:' in consumer, name
        assert ('@llvm.vp.reduce.fadd.' if evl else '@llvm.vector.reduce.fadd.') in consumer, name
    else:
        assert '<vscale x' not in body, name
    if probe:
        for label, recorder in [('loop', 'acyclic_iteration'), (latch, 'acyclic_latch'),
                                 ('scalar.fission.consumer.body', 'scalar_consumer_tail')] + (
                                     [('vector.body', 'scalar_consumer_vector')] if vectorized else []):
            body, count = re.subn(
                rf'(^{re.escape(label)}:[^\n]*\n(?:[^\n]* = phi [^\n]*\n)*)',
                rf'\1  call void @record_{recorder}()\n', body, flags=re.M)
            assert count == 1, (name, label)
    return body


def check_recurrence_remarks(remarks, name, capacity, scratch_bytes, line,
                             vectorized=True, source_file='scalar-recurrence.c'):
    """Check exact fixture accounting and stage VFs at the original loop."""
    location = re.escape(f'{source_file}:{line}:3:')
    selected = (location + r' split scalar-IR reduction loop;[^\n]*' +
                f'scratch capacity {capacity}, scratch bytes {scratch_bytes}' + r'\b')
    assert len(re.findall(selected, remarks)) == 1, f'@{name}: scratch remark\n{remarks}'
    for stage, vf in [('producer', '1'), ('consumer', 'vscale x 4' if vectorized else '1')]:
        pattern = location + re.escape(f' scalar-IR fission {stage} VF {vf}') + r'\b'
        # Repeated LV may visit a stage again; it must not split it again.
        assert re.search(pattern, remarks), f'@{name}: {stage} VF remark\n{remarks}'


def check_recurrence_function(ir, source, name, evl, vectorized=True,
                              probe=False, capacity=65, compact=False):
    """Small fixture certificate: retained state, full counts and scratch slots."""
    body, original = (function_definition(text, name) for text in (ir, source))
    producer, consumer = scalar_consumer(body, name)
    blocks = lambda text: dict(re.findall(
        r'^([-\w.$]+):[^\n]*\n(.*?)(?=^[-\w.$]+:|^}|\Z)', text, re.M | re.S))

    def normalize(line):
        line = line.split(', !', 1)[0]
        line = re.sub(r'(?<![\w.])(-?\d+\.\d+(?:[eE][+-]?\d+)?)(?![\w.])',
                      lambda m: float(m[0]).hex(), line)
        return re.sub(r'\s+', '', line)

    def require(condition, what):
        assert condition, f'@{name}: recurrence {what}\n{body}'

    before, after = blocks(original), blocks(producer)
    header = 'inner' if 'inner' in before else 'loop'
    ph = 'inner.ph' if header == 'inner' else 'preheader'
    latch = 'latch' if 'latch' in before else header
    labels = list(before)
    labels = labels[labels.index(ph):labels.index(latch) + 1]
    moved = re.compile(r'  %(r0|r1|rd|u0|u1|ud' + ('|m0|m1|md' if compact else '') + ') = ')
    # Each retained instruction occurs once, in its original block and order.
    # Allow only normal LV's one-way removal of integer nowrap flags.
    for label in ['entry'] + labels:
        require(label in after, 'producer block')
        position = -1
        candidates = after[label].splitlines()
        for line in before[label].splitlines():
            if not line.strip() or moved.match(line):
                continue
            if label == latch and line.startswith('  br '):
                target = 'scalar.fission.consumer.guard' if compact else 'scalar.fission.consumer.ph'
                line = line.replace('label %row.exit,', f'label %{target},')
                line = line.replace('label %exit,', f'label %{target},')
            matches = [i for i, candidate in enumerate(candidates)
                       if affine_instruction_refines(line, candidate, normalize)]
            require(len(matches) == 1 and matches[0] > position,
                    'retained instruction/order: ' + line)
            position = matches[0]
    require(not re.search(moved, producer),
            'accumulator extraction')
    for opcode in ('load i32,', 'load double,', 'call i32 @scalar_helper('):
        require(producer.count(opcode) == original.count(opcode), 'no duplication: ' + opcode)
    if compact:
        for opcode in ('fadd', 'fsub', 'fcmp'):
            pattern = r' = ' + opcode + r'\b'
            expected = sum(bool(re.search(pattern, line))
                           for label in ['entry'] + labels
                           for line in before[label].splitlines() if not moved.match(line))
            require(len(re.findall(pattern, producer)) == expected,
                    'retained FP operation count: ' + opcode)
    require('<vscale x' not in producer, 'scalar producer')
    require('@scalar_helper(' not in consumer, 'no consumer recomputation')
    require(not re.search(r'\b(?:fast|reassoc|nnan|ninf|nsz|arcp|contract|afn)\b', body),
            'ordered FP flags')

    # The original guards and control (also matched above in the transformed
    # producer) prove full N=n: canonical +1, bounded +3 from 7, or bounded +2
    # from begin&255. Affine control values are at most 385: no wrap/early exit.
    require(normalize(f'%valid = icmp ule i64 %n, {capacity}') in
            normalize(before['entry']), 'capacity guard')
    control = normalize(before[header] + before[latch])
    if normalize('%iv = phi i64 [0, %' + ph + '], [%next, %' + latch + ']') in control:
        kind, index = 'unit', '%iv'
        setup, step, compare = [], 1, '%done = icmp eq i64 %next, %n'
    elif normalize('%iv = phi i64 [7, %' + ph + '], [%next, %' + latch + ']') in control:
        kind, index = 'thirds', '%fission.ordinal'
        setup, step, compare = ['%span = mul nuw nsw i64 %n, 3',
                               '%limit = add nuw nsw i64 %span, 7'], 3, \
                              '%done = icmp uge i64 %next, %limit'
    else:
        kind, index = 'twice', '%fission.ordinal'
        setup, step, compare = ['%origin = and i64 %begin, 255',
                               '%span = shl nuw nsw i64 %n, 1',
                               '%limit = add nuw nsw i64 %origin, %span'], 2, \
                              '%done = icmp eq i64 %next, %limit'
        require(normalize('%iv = phi i64 [%origin, %' + ph + '], [%next, %' + latch + ']')
                in control, 'runtime origin')
    for line in setup:
        require(normalize(line) in normalize(before[ph]), 'control setup')
    require(normalize(f'%next = add nuw nsw i64 %iv, {step}') in control and
            normalize(compare) in control, 'full-count control')
    counts = ['%n']
    if compact:
        index = '%fission.participating'
        starts = [('r0', 'i32', '%carry0' if header == 'inner' else '17'),
                  ('r1', 'i32', '%carry1' if header == 'inner' else '-7'),
                  ('rd', 'double', '%dcarry' if header == 'inner' else '%start')]
        # Integer result calls follow the extracted PHI order. Retained PHIs
        # may appear anywhere; the reverse siblings intentionally invert it.
        phi_order = re.findall(r'^  %(r0|r1|rd) = phi ', before[header], re.M)
        starts = sorted(starts, key=lambda item: phi_order.index(item[0]))
        # Check integer results in their actual extracted order. The output
        # certificate associates stores with values independently of that order.
        check_compact_count(producer, consumer, name, evl, starts=starts,
                            vectorized=vectorized, recurrence=True)
        counts = ['%fission.participating.merge', '%fission.participating.count',
                  '%fission.participating.merge.lcssa']
    elif index != '%iv':
        require(normalize('%fission.ordinal = phi i64 [0, %' + ph +
                          '], [%fission.completed, %' + latch + ']') in
                normalize(after[header]), 'ordinal recurrence')
        require(any(affine_instruction_refines(
            '  %fission.completed = add nuw i64 %fission.ordinal, 1', line, normalize)
                    for line in after[latch].splitlines()), 'completed count')
        counts += ['%fission.completed']
        # SCEV can expand the exact full count in the consumer preheader. These
        # two bounded arithmetic identities are shared with the affine tests.
        chains = {
            'twice': [('add i64 %span, -2', 'lshr i64 {0}, 1', 'add nuw i64 {1}, 1')],
            'thirds': [('add i64 %span, -3', 'call i64 @llvm.umin.i64(i64 {0}, i64 1)',
                        'sub i64 %span, {1}', 'add i64 {2}, -3', 'udiv i64 {3}, 3',
                        'add i64 {1}, {4}', 'add i64 {5}, 1')],
        }
        ph_lines = consumer.split('vector.ph:', 1)[0]
        definitions = re.findall(r'^  (%[-\w.$]+) = ([^\n]+)', ph_lines, re.M)
        for chain in chains[kind]:
            values, last = [], -1
            for expression in chain:
                expected = expression.format(*values)
                matches = [(i, value) for i, (value, actual) in enumerate(definitions)
                           if i > last and affine_instruction_refines(
                               '  ' + value + ' = ' + expected,
                               '  ' + value + ' = ' + actual, normalize)]
                if len(matches) != 1:
                    break
                last, value = matches[0]
                values.append(value)
            else:
                counts.append(values[-1])
        # One-input completed-count LCSSA exports may be retained by LV2.
        counts += re.findall(r'^  (%[-\w.$]+) = phi i64 \[ %fission.completed, %' +
                             re.escape(latch) + r' \](?:, ![^\n]*)?$', consumer, re.M)

    active = after['left'] if compact else after[latch]
    slots = {}
    for ty, contribution in [('i32', '%c'), ('double', '%dc')]:
        allocations = re.findall(r'^  (%[-\w.$]+) = alloca \[' + str(capacity) +
                                 ' x ' + ty + r'\]', producer, re.M)
        require(len(allocations) == 1, 'scratch capacity/type')
        slot = allocations[0]
        stores = re.findall(r'^  store ' + ty + ' ' + re.escape(contribution) +
                            r', ptr (%[-\w.$]+), align \d+(?:, ![^\n]*)?$', active, re.M)
        require(len(stores) == 1, 'scratch store')
        expected = ('  ' + stores[0] + ' = getelementptr inbounds [' + str(capacity) +
                    ' x ' + ty + '], ptr ' + slot + ', i32 0, i64 ' + index)
        require(any(normalize(line) == normalize(expected) for line in active.splitlines()),
                'scratch index')
        slots[ty] = slot
    require(sum(len(re.findall(r'^  store ', after[label], re.M)) for label in labels) == 2,
            'scratch store count')
    count = '(?:' + '|'.join(map(re.escape, counts)) + ')'
    if vectorized:
        vector = re.search(r'^vector\.body:[^\n]*\n(.*?)(?=^[-\w.$]+:)', consumer, re.M | re.S)
        require(vector is not None, 'vector consumer')
        intrinsic = r'vp\.reduce' if evl else r'vector\.reduce'
        require(re.search(r'call double @llvm\.' + intrinsic + r'\.fadd\.nxv4f64\(', vector[0]),
                'ordered vector FP')
        require('@llvm.vector.reduce.add.nxv4i32' in consumer, 'integer vector reduction')
        for ty, suffix in [('i32', 'i32'), ('double', 'f64')]:
            load = (r'call <vscale x 4 x ' + ty + r'> @llvm\.vp\.load\.nxv4' + suffix
                    if evl else r'load <vscale x 4 x ' + ty + '>')
            require(len(re.findall(load, vector[0])) == 1, 'unique vector scratch load')
            address = re.search(r'^  (%[-\w.$]+) = getelementptr inbounds \[' + str(capacity) +
                                ' x ' + ty + r'\], ptr ' + re.escape(slots[ty]) +
                                r', i32 0, i64 (%[-\w.$]+)(?:, ![^\n]*)?$', vector[0], re.M)
            require(address is not None, 'vector scratch provenance')
            require(re.search(load + (r'\.p0\(ptr align \d+ ' if evl else r', ptr ') +
                              re.escape(address[1]) + r',', vector[0]), 'vector scratch load provenance')
        if evl:
            require(re.search(r'%avl = phi i64 \[ ' + count + r', %vector\.ph \]', consumer),
                    'EVL actual count')
        else:
            require(re.search(r'%n\.mod\.vf = urem i64 ' + count + ',', consumer),
                    'vector actual count')
    if not evl:
        scalar = blocks(consumer)['scalar.fission.consumer.body']
        loaded = {}
        for ty, slot in slots.items():
            address = re.search(r'^  (%[-\w.$]+) = getelementptr inbounds \[' + str(capacity) +
                                ' x ' + ty + r'\], ptr ' + re.escape(slot) +
                                r', i32 0, i64 %fission.consumer.iv(?:, ![^\n]*)?$', scalar, re.M)
            require(address is not None, 'scalar scratch index')
            value = re.search(r'^  (%[-\w.$]+) = load ' + ty + r', ptr ' +
                              re.escape(address[1]) + r', align \d+(?:, ![^\n]*)?$', scalar, re.M)
            require(value is not None, 'scalar scratch load')
            loaded[ty] = value[1]
        require(re.search(r'icmp (?:eq|ne) i64 %fission.consumer.next, ' + count + r'(?:, ![^\n]*)?$',
                          scalar, re.M), 'scalar actual count')
        require(re.search(r'%ud.consume = fadd double %rd.consume, ' + re.escape(loaded['double']) +
                          r'(?:, ![^\n]*)?$', scalar, re.M),
                'ordered scalar FP')
        for expression in ['%u0.consume = add i32 %r0.consume, ' + loaded['i32'],
                           '%u1.consume = add i32 ' + loaded['i32'] + ', %r1.consume']:
            require(re.search(r'^  ' + re.escape(expression) + r'(?:, ![^\n]*)?$', scalar, re.M),
                    'shared scalar contribution')
    if probe:
        probes = [(header, 'acyclic_iteration'), (latch, 'acyclic_latch'),
                  ('scalar.fission.consumer.body', 'scalar_consumer_tail')]
        if vectorized:
            probes.append(('vector.body', 'scalar_consumer_vector'))
        if compact:
            probes.append(('left', 'compact_participant'))
        for label, recorder in probes:
            # A single-block producer receives both counters at the same site.
            body, sites = re.subn(
                rf'(^{re.escape(label)}:[^\n]*\n(?:[^\n]* = phi [^\n]*\n)*)',
                rf'\1  call void @record_{recorder}()\n', body, count=1, flags=re.M)
            require(sites == 1, 'probe site')
    return body


def check_compact_delay_function(ir, source, evl, vectorized, probe=False):
    """Certificate for the unchanged formerly rejected recurrence_compact."""
    name = 'recurrence_compact'
    body, original = (function_definition(text, name) for text in (ir, source))
    producer, consumer = scalar_consumer(body, name)
    blocks = lambda text: dict(re.findall(
        r'^([-\w.$]+):[^\n]*\n(.*?)(?=^[-\w.$]+:|^}|\Z)', text, re.M | re.S))
    before, after = blocks(original), blocks(producer)
    normalize = lambda line: re.sub(r'\s+', '', line.split(', !', 1)[0])
    for label in ['entry', 'preheader', 'loop', 'left', 'latch']:
        position = -1
        candidates = after[label].splitlines()
        for line in before[label].splitlines():
            if not line.strip() or re.match(r'  %(sum|update|merge) = ', line):
                continue
            if line == '  %x = load i32, ptr %p':
                # Printing the historical omitted alignment makes the ABI
                # default explicit. It does not change the load's contract.
                line += ', align 4'
            if label == 'latch' and line.startswith('  br '):
                line = line.replace('label %exit,', 'label %scalar.fission.consumer.guard,')
            matches = [i for i, candidate in enumerate(candidates)
                       if affine_instruction_refines(line, candidate, normalize)]
            assert len(matches) == 1 and matches[0] > position, (name, line, body)
            position = matches[0]
    assert producer.count('load i32,') == producer.count('@scalar_helper(') == 1, body
    assert not re.search(r'  %(sum|update|merge) = ', producer), body
    assert '<vscale x' not in producer and '@scalar_helper(' not in consumer, body
    check_compact_count(producer, consumer, name, evl,
                        starts=[('sum', 'i32', '17')], vectorized=vectorized, delay=True)
    slot = re.findall(r'^  (%[-\w.$]+) = alloca \[65 x i32\]', producer, re.M)
    assert len(slot) == 1, body
    address = re.search(r'^  (%[-\w.$]+) = getelementptr inbounds \[65 x i32\], ptr ' +
                        re.escape(slot[0]) + r', i32 0, i64 %fission.participating$', after['left'], re.M)
    assert address and re.search(r'^  store i32 %c, ptr ' + re.escape(address[1]) +
                                 r', align 4$', after['left'], re.M), body
    assert len(re.findall(r'^  store ', producer, re.M)) == 1, body
    assert slot[0] in consumer, body
    if not evl:
        tail = blocks(consumer)['scalar.fission.consumer.body']
        pointer = re.search(r'^  (%[-\w.$]+) = getelementptr inbounds \[65 x i32\], ptr ' +
                            re.escape(slot[0]) + r', i32 0, i64 %fission.consumer.iv'
                            r'(?:, ![^\n]*)?$', tail, re.M)
        assert pointer, body
        loaded = re.search(r'^  (%[-\w.$]+) = load i32, ptr ' +
                           re.escape(pointer[1]) + r', align 4(?:, ![^\n]*)?$', tail, re.M)
        assert loaded and '%update.consume = add i32 %sum.consume, ' + loaded[1] in tail, body
    if probe:
        sites = [('loop', 'acyclic_iteration'), ('latch', 'acyclic_latch'),
                 ('left', 'compact_participant'), ('scalar.fission.consumer.body', 'scalar_consumer_tail')]
        if vectorized:
            sites.append(('vector.body', 'scalar_consumer_vector'))
        for label, recorder in sites:
            body, count = re.subn(
                rf'(^{re.escape(label)}:[^\n]*\n(?:[^\n]* = phi [^\n]*\n)*)',
                rf'\1  call void @record_{recorder}()\n', body, count=1, flags=re.M)
            assert count == 1, (name, label)
    return body


def host_ir(ir):
    ir = re.sub(r'^target (?:triple|datalayout) = .*$', '', ir, flags=re.M)
    ir = re.sub(r'"(?:target-[^"]+|tune-cpu)"="[^"]*"', '', ir)
    ir = re.sub(r'vscale_range\([^)]*\)', '', ir)
    # VFABI mappings guide the original optimization, which is already done.
    # The host executes explicit fixed-width calls to exact helper definitions;
    # retaining the scalable mappings would misdescribe their specialized ABI.
    ir = re.sub(r'"vector-function-abi-variant"="[^"]*"', '', ir)
    for group in re.findall(r'^attributes #(\d+) = \{\s*\}$', ir, re.M):
        ir = re.sub(rf'^attributes #{group} = \{{\s*\}}$', '', ir, flags=re.M)
        ir = re.sub(rf' #{group}\b', '', ir)
    return ir


def define_independent_call_helpers(ir, vector=False):
    """Supply exact lane-wise integer helpers after vectorization decisions.

    Declarations in the fixture exercise VFABI selection. These definitions
    only make the selected calls executable on the host; no library, FP or
    errno assumptions are needed. Internal linkage keeps each specialization's
    helper definitions private.
    """
    for is_vector in ([False, True] if vector else [False]):
        i32 = '<vscale x 2 x i32>' if is_vector else 'i32'
        i64 = '<vscale x 2 x i64>' if is_vector else 'i64'
        shift = 'splat (i64 32)' if is_vector else '32'
        for scalar_name in ('foo', 'bar'):
            name = f'vec{scalar_name}' if is_vector else scalar_name
            params = (f'{i64} %x' if scalar_name == 'foo'
                      else f'{i32} %lo, {i64} %x')
            body = f'  %hi64 = lshr {i64} %x, {shift}\n'
            body += f'  %hi = trunc {i64} %hi64 to {i32}\n'
            if scalar_name == 'foo':
                body += f'  %lo = trunc {i64} %x to {i32}\n'
            opcode = 'xor' if scalar_name == 'foo' else 'add'
            body += f'  %result = {opcode} {i32} %lo, %hi\n  ret {i32} %result\n'
            definition = (
                f'define internal {i32} @{name}({params}) '
                f'nounwind willreturn speculatable memory(none) {{\n{body}}}')
            ir, replaced = re.subn(
                rf'^declare [^\n]* @{name}\([^\n]*$', lambda _: definition,
                ir, flags=re.M)
            assert replaced == 1, f'missing declaration of {name}'
    return ir


def loop_blocks(body):
    """The checker fixtures use unquoted labels and single-block vector loops."""
    pairs = re.findall(r'^([\w.$-]+):[^\n]*\n'
                       r'((?s:.*?))(?=^[\w.$-]+:|^}|\Z)', body, re.M)
    assert len(pairs) == len(dict(pairs)), body
    return dict(pairs)


def check_loop_provenance(ir, body, tag):
    # Check the ID actually attached to each latch, not an unused metadata
    # string elsewhere in the module. Explicit follow-up IDs can replace it.
    ids = re.findall(r'!llvm.loop !(\d+)', body)
    assert ids, body
    for loop_id in ids:
        node = re.search(rf'^!{loop_id} = distinct !\{{([^\n]*)\}}$', ir, re.M)
        assert node, loop_id
        refs = re.findall(r'!(\d+)', node[1])
        assert any(re.search(rf'^!{ref} = !\{{!"llvm.loop.reduction_fission\.'
                             rf'{tag}"\}}$', ir, re.M) for ref in refs), node[0]


def check_dispatch_interleave(ir, name, factor, repeated, evl):
    """Audit every VPlan stage and any later ordinary-LV tail in this fixture.

    Return the emitted ordinary tail widths/labels for host instrumentation.
    Default EVL tails are checked before RVV codegen and never specialized.
    A forwarding body.middle block is not an executing scalar iteration.
    """
    body = function_definition(ir, name)
    blocks = loop_blocks(body)
    tails, accounted = [], set()
    for role, vf, scratch_op, end in (
            ('producer', 2, 'store', 'vector.fission.accumulator.ph'),
            ('accumulator', 4, 'load', 'vector.fission.done')):
        main = f'vector.fission.{role}.body'
        scalar = f'scalar.fission.{role}.body'
        begin = f'scalar.fission.{role}.ph'
        assert main in blocks and begin in blocks and end in blocks, body
        assert re.search(rf'\b{scratch_op} <vscale x {vf} x i32>', blocks[main]), blocks[main]
        accounted.add(main)
        region = body.split(begin + ':', 1)[1].split(end + ':', 1)[0]
        ordinary = re.findall(r'^vector\.body[\w.$-]*:', region, re.M)
        assert len(ordinary) <= 1, region
        if not repeated:
            assert not ordinary, region
        tail = {'role': role, 'label': None, 'vf': 0, 'mode': 'scalar',
                'vector_entries': '0', 'vector_lanes': '0',
                'scalar_entries': f'N % ({vf}*vscale)'}
        if ordinary:
            label = ordinary[0][:-1]
            code = blocks[label]
            accounted.add(label)
            # followup_all in this fixture requests VF4. Tie the accounting
            # width to the actual scratch access, not the group input width.
            access = (rf'@llvm\.vp\.{scratch_op}\.nxv4i32\.' if evl else
                      rf'\b{scratch_op} <vscale x 4 x i32>')
            assert len(re.findall(access, code)) == 1, code
            tail.update(label=label, vf=4, mode='evl' if evl else 'full-chunks',
                        vector_entries=f'ceil((N % ({vf}*vscale))/(4*vscale))' if evl else
                                       f'floor((N % ({vf}*vscale))/(4*vscale))',
                        vector_lanes=f'N % ({vf}*vscale)' if evl else
                                     f'floor((N % ({vf}*vscale))/(4*vscale))*(4*vscale)',
                        scalar_entries='0' if evl else f'(N % ({vf}*vscale)) % (4*vscale)')
            if evl:
                # Prove that the tail AVL is the original stage remainder,
                # and that the same EVL controls scratch and loop progress.
                prefix = body.split(begin + ':', 1)[0]
                rem = re.search(r'(%[-\w.$]+) = urem i64 %n, (%[-\w.$]+)',
                                prefix[prefix.rfind('vector.fission.accumulator.ph:'):] if
                                role == 'accumulator' else prefix)
                assert rem, prefix
                rounded = re.search(r'(%[-\w.$]+) = sub i64 %n, ' +
                                    re.escape(rem[1]) + r'\b', prefix)
                assert rounded, prefix
                guard = blocks[f'scalar.fission.{role}.check']
                empty = re.search(r'(%[-\w.$]+) = icmp eq i64 ' +
                                  re.escape(rounded[1]) + ', %n', guard)
                assert empty and re.search(
                    r'br i1 ' + re.escape(empty[1]) + ', label %' + re.escape(end) +
                    ', label %' + re.escape(begin) + r'\b', guard), guard
                width = re.search(rf'{re.escape(rem[2])} = mul nuw i64 '
                                  rf'(%[-\w.$]+), {vf}\b', prefix)
                assert width and re.search(rf'{re.escape(width[1])} = call i64 '
                                           r'@llvm\.vscale\.i64\(\)', prefix), prefix
                avl = re.search(r'(%[-\w.$]+) = phi i64 \[ ' + re.escape(rem[1]) +
                                r', %([-\w.$]+) \], \[ (%[-\w.$]+), %' +
                                re.escape(label) + r' \]', code)
                assert avl, code
                assert re.fullmatch(r'\s*br label %' + re.escape(avl[2]) +
                                    r'(?:, !dbg !\d+)?\s*', blocks[begin]), blocks[begin]
                assert re.search(r'br label %' + re.escape(label) + r'(?:,|\s|$)',
                                 blocks[avl[2]]), blocks[avl[2]]
                length = re.search(r'(%[-\w.$]+) = call i32 '
                                   r'@llvm\.experimental\.get\.vector\.length\.i64'
                                   r'\(i64 ' + re.escape(avl[1]) + r', i32 4, i1 true\)', code)
                assert length, code
                step = re.search(r'(%[-\w.$]+) = zext i32 ' + re.escape(length[1]) +
                                 r' to i64', code)
                assert step, code
                assert re.search(re.escape(avl[3]) + r' = sub nuw i64 ' +
                                 re.escape(avl[1]) + ', ' + re.escape(step[1]), code), code
                index = re.search(r'(%[-\w.$]+) = phi i64 \[ 0, %' +
                                  re.escape(avl[2]) + r' \], \[ (%[-\w.$]+), %' +
                                  re.escape(label) + r' \]', code)
                assert index and re.search(re.escape(index[2]) + r' = add (?:nuw )?i64 ' +
                                            re.escape(step[1]) + ', ' + re.escape(index[1]), code), code
                resumed = re.search(r'(%[-\w.$]+) = add i64 ' + re.escape(rounded[1]) +
                                    ', ' + re.escape(index[1]), code)
                assert resumed, code
                address = re.search(r'(%[-\w.$]+) = getelementptr i32, ptr '
                                    r'%fission\.scratch, i64 ' + re.escape(resumed[1]), code)
                assert address, code
                done = re.search(r'(%[-\w.$]+) = icmp eq i64 ' + re.escape(avl[3]) + ', 0', code)
                assert done and re.search(r'br i1 ' + re.escape(done[1]) +
                                          r', label %[-\w.$]+, label %' + re.escape(label) + r'[,\n]', code), code
                scratch = [line for line in code.splitlines() if re.search(access, line)]
                assert len(scratch) == 1 and re.search(
                    r', <vscale x 4 x i1> splat \(i1 true\), i32 ' +
                    re.escape(length[1]) + r'\)', scratch[0]), code
                assert re.search(r'ptr align 4 ' + re.escape(address[1]) + ',', scratch[0]), code
                if role == 'producer':
                    grouped_length = re.search(r'(%[-\w.$]+) = mul nuw nsw i32 ' +
                                               re.escape(length[1]) + f', {factor}\\b', code)
                    assert grouped_length and re.search(
                        rf'@llvm\.vp\.load\.nxv{4 * factor}i32\.[^\n]+, '
                        rf'<vscale x {4 * factor} x i1> splat \(i1 true\), i32 ' +
                        re.escape(grouped_length[1]) + r'\)', code), code
                    assert f'@llvm.vector.deinterleave{factor}.nxv{4 * factor}i32' in code, code
        if repeated and evl:
            assert ordinary and scalar not in blocks, region
            forwarding = blocks[scalar + '.middle'].strip()
            assert re.fullmatch(r'br label %[-\w.$]+(?:, !dbg !\d+)?', forwarding), forwarding
        else:
            assert scalar in blocks, region
            accounted.add(scalar)
        tails.append(tail)
    # Every loop here is a single block. Also detect untagged self backedges
    # so dropping both a familiar label and its metadata cannot hide a loop.
    latches = {label for label, code in blocks.items()
               if '!llvm.loop ' in code or any(
                   re.search(r'\blabel %' + re.escape(label) + r'(?=[,\s]|$)', line)
                   for line in code.splitlines() if line.startswith('  br '))}
    assert latches == accounted, (latches, accounted, body)
    for label in accounted:
        check_loop_provenance(ir, blocks[label], 'stage')
    return tails


def dispatch_stage_vfs(remarks):
    """Exactly four early selections at the original dispatch loop locations."""
    selected = re.findall(r'dispatch\.c:(\d+):5: split ([^\n]+)', remarks)
    assert len(re.findall(r': split (?:scalar-IR )?reduction loop[;:]', remarks)) == 4, remarks
    assert len(selected) == 4 and {int(line) for line, _ in selected} == {10, 20, 30, 50}, remarks
    assert all(text.startswith('scalar-IR reduction loop;') for _, text in selected), remarks
    assert 'split reduction loop:' not in remarks, remarks
    result = {}
    for name, line, size, exports, traffic in (
            ('interleave2', 10, 260, 1, 4), ('interleave3', 20, 260, 1, 4),
            ('interleave2_ordered', 30, 520, 0, 8), ('compact_nested', 50, 784, 0, 12)):
        assert re.search(
            rf'dispatch.c:{line}:5: split scalar-IR reduction loop;[^\n]*'
            rf'scratch capacity 65, scratch bytes {size}, producer live-outs {exports}, '
            rf'scratch store bytes/iteration {traffic}, scratch load bytes/iteration {traffic}, '
            r'producer reread bytes/iteration 0, duplicated producer instructions 0\b', remarks), remarks
        widths = []
        for stage in ('producer', 'consumer'):
            matches = re.findall(rf'dispatch.c:{line}:5: scalar-IR fission {stage} VF '
                                 r'(1|vscale x [1-9][0-9]*)\b', remarks)
            # Later LV invocations report VF 1 when revisiting an already
            # vectorized stage. Explicit follow-up hints may also vectorize a
            # scalar remainder; the IR certificate accounts for that loop
            # separately, never replacing the primary stage's first width.
            scalable = [int(vf.split()[-1]) for vf in matches if vf != '1']
            if name == 'compact_nested' and stage == 'producer':
                assert matches and not scalable, (name, stage, remarks)
                widths.append(0)
            else:
                assert scalable and matches[0] != '1', (name, stage, remarks)
                assert len(scalable) <= (2 if line in (10, 20) else 1), (name, stage, remarks)
                widths.append(scalable[0])
        assert (widths == [0, 4] if name == 'compact_nested' else all(widths)), (name, widths)
        result[name] = widths
    return result


def dispatch_entry_certificates(body, producer_vf, consumer_vf, tail_vfs=(0, 0)):
    """Certify the two ordinary-LV dispatch stages with scalar remainders.

    This is a small fixture vocabulary, not an IR interpreter. Each vector
    loop has a zero-based unit-VF induction, an unsigned entry comparison,
    urem/sub rounding and an equality exit. A second LV invocation can apply
    the same structure to N minus the primary resume index. Resolve threshold
    definitions in the whole function: CSE can share them across stages, but
    each stage must prove its own comparison, edges, width and resume value.
    """
    blocks = {label: chunk_instructions(code) for label, code in loop_blocks(body).items()}
    definitions = {}
    for label, code in blocks.items():
        for line in code:
            match = re.fullmatch(r'(%[-\w.$]+) = (.+)', line)
            if match:
                assert match[1] not in definitions, 'dispatch entry: duplicate SSA'
                definitions[match[1]] = (label, match[2])
    successors = {label: re.findall(r'\blabel %([-\w.$]+)', code[-1])
                  for label, code in blocks.items()}
    predecessors = {label: {p for p, targets in successors.items() if label in targets}
                    for label in blocks}

    def need(ok, detail):
        assert ok, 'dispatch entry: ' + detail

    def expression(value, label=None):
        need(value in definitions and (label is None or definitions[value][0] == label),
             'definition ' + value)
        return definitions[value][1]

    def instruction(label, pattern, detail):
        matches = [m for line in blocks[label] if (m := re.fullmatch(pattern, line))]
        need(len(matches) == 1, detail)
        return matches[0]

    def width(value, vf):
        expr = expression(value)
        if vf == 1 and expr == 'call i64 @llvm.vscale.i64()':
            return
        match = re.fullmatch(r'(mul|shl) (?:nuw )?(?:nsw )?i64 (%[-\w.$]+), (\d+)', expr)
        need(match, 'threshold/step width form')
        need((int(match[3]) == vf if match[1] == 'mul' else
              int(match[3]) < 64 and (1 << int(match[3])) == vf) and
             expression(match[2]) == 'call i64 @llvm.vscale.i64()', 'threshold/step width operand')

    def threshold(value, vf):
        expr = expression(value)
        match = re.fullmatch(r'call i64 @llvm\.umax\.i64\(i64 (%[-\w.$]+|\d+), '
                             r'i64 (%[-\w.$]+|\d+)\)', expr)
        minimum = 0
        if match:
            operands = match.groups()
            constants = [int(v) for v in operands if v.isdecimal()]
            variables = [v for v in operands if v.startswith('%')]
            need(len(constants) == len(variables) == 1 and 0 < constants[0] <= 0xffffffff,
                 'threshold umax operands')
            minimum, value = constants[0], variables[0]
        width(value, vf)
        return minimum

    # The original participation guard controls both stages and every probe.
    for line in ('%bounded = icmp ule i64 %n, 65', '%nonzero = icmp ne i64 %n, 0',
                 '%enter = and i1 %bounded, %nonzero',
                 'br i1 %enter, label %preheader, label %bypass'):
        need(line in blocks['entry'], 'original bounded/nonzero entry')
    need(predecessors['preheader'] == {'entry'}, 'original preheader edge')

    def finished(label, end):
        if label == end:
            return
        # Repeated LV can add one LCSSA forwarding block at a stage exit.
        need(label in blocks and blocks[label][-1] == f'br label %{end}' and
             all(re.fullmatch(r'%[-\w.$]+ = phi .+', line) for line in blocks[label][:-1]),
             'stage exit forwarding')

    def vector_loop(label, guard, vf, count, base, end):
        induction = instruction(label, r'(%[-\w.$]+) = phi i64 \[ 0, %([-\w.$]+) \], '
                                r'\[ (%[-\w.$]+), %' + re.escape(label) + r' \]', 'vector induction')
        index, vector_ph, next_index = induction.groups()
        need(blocks[vector_ph][-1] == f'br label %{label}' and
             predecessors[vector_ph] == {guard} and
             predecessors[label] == {vector_ph, label}, 'vector preheader edges')
        step = re.fullmatch(r'add (?:nuw )?i64 ' + re.escape(index) + r', (%[-\w.$]+)',
                            expression(next_index, label))
        need(step, 'vector step')
        width(step[1], vf)
        remainder = instruction(vector_ph, r'(%[-\w.$]+) = urem i64 ' + re.escape(count) +
                                r', (%[-\w.$]+)', 'vector rounding remainder')
        width(remainder[2], vf)
        rounded = instruction(vector_ph, r'(%[-\w.$]+) = sub i64 ' + re.escape(count) +
                              ', ' + re.escape(remainder[1]), 'vector rounded count')[1]
        branch = re.fullmatch(r'br i1 (%[-\w.$]+), label %([-\w.$]+), label %' +
                              re.escape(label), blocks[label][-1])
        need(branch and expression(branch[1], label) ==
             f'icmp eq i64 {next_index}, {rounded}', 'vector rounded exit')
        middle = branch[2]
        need(predecessors[middle] == {label}, 'vector middle edge')
        check = re.fullmatch(r'br i1 (%[-\w.$]+), label %([-\w.$]+), label %([-\w.$]+)',
                             blocks[guard][-1])
        need(check, 'entry branch')
        comparison = re.fullmatch(r'icmp (ult|uge|ugt|ule) i64 (%[-\w.$]+), (%[-\w.$]+)',
                                  expression(check[1], guard))
        need(comparison, 'entry comparison')
        pred, lhs, rhs = comparison.groups()
        if lhs == count and pred in ('ult', 'uge'):
            limit, scalar_on_true = rhs, pred == 'ult'
        else:
            need(rhs == count and pred in ('ugt', 'ule'), 'entry comparison operands/polarity')
            limit, scalar_on_true = lhs, pred == 'ugt'
        minimum = threshold(limit, vf)
        scalar_ph = check[2] if scalar_on_true else check[3]
        need((check[3] if scalar_on_true else check[2]) == vector_ph and
             scalar_ph != vector_ph, 'entry branch destinations')
        need(predecessors[scalar_ph] == {guard, middle}, 'scalar fallback edges')
        done = re.fullmatch(r'br i1 (%[-\w.$]+), label %([-\w.$]+), label %' +
                            re.escape(scalar_ph), blocks[middle][-1])
        need(done and expression(done[1], middle) == f'icmp eq i64 {count}, {rounded}',
             'empty remainder check')
        finished(done[2], end)
        resumed = rounded
        if base != '0':
            resumed = instruction(vector_ph, r'(%[-\w.$]+) = add i64 ' + re.escape(base) +
                                  ', ' + re.escape(rounded), 'ordinary resume offset')[1]
            scratch_index = instruction(label, r'(%[-\w.$]+) = add i64 ' + re.escape(base) +
                                        ', ' + re.escape(index), 'ordinary scratch offset')[1]
        else:
            scratch_index = index
        instruction(label, r'%[-\w.$]+ = getelementptr inbounds \[65 x (?:i32|double)\], '
                    r'ptr %scalar\.fission\.scratch, i32 0, i64 ' + re.escape(scratch_index),
                    'vector scratch index')
        resume = instruction(scalar_ph, r'(%[-\w.$]+) = phi i64 \[ ' + re.escape(resumed) +
                             ', %' + re.escape(middle) + r' \], \[ ' + re.escape(base) +
                             ', %' + re.escape(guard) + r' \]', 'scalar fallback resume')[1]
        return {'vf': vf, 'minimum': minimum, 'guard': guard, 'threshold': limit,
                'count': count, 'rounded': rounded, 'scalar_ph': scalar_ph, 'resume': resume}

    result = []
    producer, consumer = scalar_consumer(body, 'dispatch entry')
    for half, role, vf, tail_vf, guard, scalar, end in (
            (producer, 'producer', producer_vf, tail_vfs[0], 'preheader', 'loop',
             'scalar.fission.consumer.ph'),
            (consumer, 'consumer', consumer_vf, tail_vfs[1], 'scalar.fission.consumer.ph',
             'scalar.fission.consumer.body', 'exit')):
        vectors = [label for label in loop_blocks(half) if re.fullmatch(r'vector\.body[\w.$-]*', label)]
        need(len(vectors) == (2 if tail_vf else 1), role + ' vector loop count')
        primary = vector_loop(vectors[0], guard, vf, '%n', '0', end)
        scalar_ph, resume = primary['scalar_ph'], primary['resume']
        ordinary = None
        if tail_vf:
            count = instruction(scalar_ph, r'(%[-\w.$]+) = sub i64 %n, ' + re.escape(resume),
                                role + ' ordinary remaining count')[1]
            ordinary = vector_loop(vectors[1], scalar_ph, tail_vf, count, resume, end)
            scalar_ph, resume = ordinary['scalar_ph'], ordinary['resume']
        need(blocks[scalar_ph][-1] == f'br label %{scalar}' and
             predecessors[scalar] == {scalar_ph, scalar}, role + ' scalar entry edges')
        induction = instruction(scalar, r'(%[-\w.$]+) = phi i64 \[ ' + re.escape(resume) +
                                ', %' + re.escape(scalar_ph) + r' \], \[ (%[-\w.$]+), %' +
                                re.escape(scalar) + r' \]', role + ' scalar induction')
        instruction(scalar, r'%[-\w.$]+ = getelementptr inbounds \[65 x (?:i32|double)\], '
                    r'ptr %scalar\.fission\.scratch, i32 0, i64 ' + re.escape(induction[1]),
                    role + ' scalar scratch index')
        need(expression(induction[2], scalar) in (f'add i64 {induction[1]}, 1',
                                                 f'add nuw i64 {induction[1]}, 1'),
             role + ' scalar step')
        branch = re.fullmatch(r'br i1 (%[-\w.$]+), label %([-\w.$]+), label %' +
                              re.escape(scalar), blocks[scalar][-1])
        need(branch and expression(branch[1], scalar) == f'icmp eq i64 {induction[2]}, %n',
             role + ' scalar exit')
        finished(branch[2], end)
        result.append({'role': role, 'primary': primary, 'ordinary': ordinary})
    return result


def dispatch_entry_fields(certificates):
    """C row minima; zero keeps the inherited VF-only VPlan convention."""
    return ', '.join(str(stage[part]['minimum'] if stage[part] else 0)
                     for part in ('primary', 'ordinary') for stage in certificates)


def check_dispatch_scalar_interleave(ir, name, factor, evl, producer_vf, consumer_vf,
                                    probe=False, stages=None):
    """Fixture certificate for retained XOR and a separately vectorized add.

    Bind reductions to the actual scratch values, outputs to typed forwarding
    PHIs/updates, and every emitted loop to its attached role/source location.
    Independent C formulas additionally check seeds, every contribution and
    the latest result on executed vector/tail/alias paths. No VPlan certificate
    is relaxed: check_dispatch_interleave still checks isolated VPlan modules.
    """
    body = function_definition(ir, name)
    producer, consumer = scalar_consumer(body, name)
    blocks = loop_blocks(body)

    def need(ok, detail):
        assert ok, f'@{name}: dispatch {detail}'

    def terminator(code):
        return [line for line in code.splitlines() if line.strip()][-1]

    need(body.count('alloca [65 x i32]') == 1 and
         '%scalar.fission.scratch = alloca [65 x i32]' in body, 'scratch capacity')
    need('vector.fission.' not in body and 'scalar.fission.chunk:' not in body, 'early schedule')
    need(not re.search(r'(?<![\w.])%(?:sum|update) = ', producer), 'add extraction')
    need('@llvm.vector.reduce.add.' not in producer and
         '@llvm.vector.reduce.xor.' not in consumer, 'reduction roles')
    need(not re.search(r'ptr %a\b|%term\b|%bits\.consume\b', consumer), 'no reread/recomputation')
    scope = re.search(r'^define[^\n]+!dbg !(\d+) \{', body, re.M)
    need(scope, 'function location')
    expected_line = 10 if factor == 2 else 20
    subprogram = re.search(rf'^!{scope[1]} = distinct !DISubprogram\(name: "{name}", '
                           rf'[^\n]*file: !(\d+), line: {expected_line},', ir, re.M)
    need(subprogram and re.search(rf'^!{subprogram[1]} = !DIFile\(filename: "dispatch.c",', ir, re.M),
         'original source file/function')
    vectors, tails, roots = [], [], []
    for half, role, vf, scalar, operation in (
            (producer, 'producer', producer_vf, 'loop', 'xor'),
            (consumer, 'consumer', consumer_vf, 'scalar.fission.consumer.body', 'add')):
        region = loop_blocks(half)
        vector = [label for label in region if re.fullmatch(r'vector\.body[\w.$-]*', label)]
        need(1 <= len(vector) <= (1 if evl else 2), role + ' vector loop count')
        vectors.append(vector[0])
        expected = set(vector) | ({scalar} if not evl else set())
        loops = {label for label, code in region.items() if '!llvm.loop ' in code or any(
            re.search(r'\blabel %' + re.escape(label) + r'(?=[,\s]|$)', line)
            for line in code.splitlines() if line.startswith('  br '))}
        need(loops == expected, role + ' complete loop accounting')
        for label in loops:
            try:
                check_loop_provenance(ir, region[label], role)
            except AssertionError:
                need(False, role + ' attached provenance')
            # A stage remark must describe the same original target as its
            # actual latch, including after the second LV invocation.
            branch = terminator(region[label])
            dbg = re.search(r'!dbg !(\d+)', branch)
            need(dbg and re.search(rf'^!{dbg[1]} = !DILocation\(line: {expected_line}, '
                                   rf'column: 5, scope: !{scope[1]}\)', ir, re.M),
                 role + ' attached source location')
        emitted_widths, extra_vf = [], 0
        for ordinal, vector_label in enumerate(vector):
            code = region[vector_label]
            # Widths are bound to the actual scratch value type, not the wide
            # AoS input type, hints or a later scalar-revisit remark.
            access = (r'(?:store <vscale x (\d+) x i32>|@llvm\.vp\.store\.nxv(\d+)i32\.)'
                      if role == 'producer' else
                      r'(?:load <vscale x (\d+) x i32>|@llvm\.vp\.load\.nxv(\d+)i32\.)')
            accesses = re.findall(access, code)
            # Producer input loads cannot satisfy this store-type check;
            # consumers contain only their single scratch input stream.
            need(len(accesses) == 1, role + ' scratch stream count')
            actual_vf = int(next(width for width in accesses[0] if width))
            need(actual_vf > 0 and (ordinal != 0 or actual_vf == vf), role + ' observed VF')
            if ordinal:
                extra_vf = actual_vf
            ty = f'<vscale x {actual_vf} x i32>'
            if role == 'producer':
                need(code.count(f'@llvm.vector.deinterleave{factor}.nxv{actual_vf * factor}i32') == 1,
                     'producer interleave width')
                store = (re.search(rf'@llvm\.vp\.store\.nxv{actual_vf}i32\.p0\({re.escape(ty)} '
                                   r'(%[-\w.$]+), ptr align 4 (%[-\w.$]+),', code) if evl else
                         re.search(rf'\bstore {re.escape(ty)} (%[-\w.$]+), ptr (%[-\w.$]+), align 4', code))
                need(store, 'producer scratch store')
                value, address = store.groups()
                need(re.search(re.escape(address) + r' = getelementptr inbounds \[65 x i32\], '
                               r'ptr %scalar\.fission\.scratch, i32 0, i64 %[-\w.$]+', code),
                     'producer scratch address')
                need(re.search(r' = xor ' + re.escape(ty) + r' (?:' + re.escape(value) +
                               r', %[-\w.$]+|%[-\w.$]+, ' + re.escape(value) + r')(?:, ![^\n]*)?$',
                               code, re.M), 'retained vector XOR contribution')
            else:
                load = (re.search(r'(%[-\w.$]+) = call ' + re.escape(ty) +
                                  rf' @llvm\.vp\.load\.nxv{actual_vf}i32\.p0\(ptr align 4 (%[-\w.$]+),', code)
                        if evl else re.search(r'(%[-\w.$]+) = load ' + re.escape(ty) +
                                               r', ptr (%[-\w.$]+), align 4', code))
                need(load, 'consumer scratch load')
                value, address = load.groups()
                need(re.search(re.escape(address) + r' = getelementptr inbounds \[65 x i32\], '
                               r'ptr %scalar\.fission\.scratch, i32 0, i64 %[-\w.$]+', code),
                     'consumer scratch address')
                need(re.search(r' = add ' + re.escape(ty) + r' (?:' + re.escape(value) +
                               r', %[-\w.$]+|%[-\w.$]+, ' + re.escape(value) + r')(?:, ![^\n]*)?$',
                               code, re.M), 'moved vector add contribution')
            emitted_widths.append(actual_vf)
        reduced = re.findall(r'(%[-\w.$]+) = call i32 @llvm\.vector\.reduce\.' + operation +
                             r'\.nxv([1-9][0-9]*)i32\(', half)
        need(sorted(int(width) for _, width in reduced) == sorted(emitted_widths),
             role + ' vector results/widths')
        roots.append({value for value, _ in reduced})
        tails.append({'label': vector[1] if len(vector) == 2 else None, 'vf': extra_vf})
        if not evl:
            update = '%updated.bits' if role == 'producer' else '%update.consume'
            accumulator = '%bits' if role == 'producer' else '%sum.consume'
            contribution = '%term' if role == 'producer' else '%fission.contribution'
            need(f'{update} = {operation} i32 {accumulator}, {contribution}' in region[scalar],
                 role + ' scalar update')
            roots[-1].add(update)

    # Follow only typed PHIs on actual predecessor edges. Vector results and
    # scalar updates must both reach their respective observable output; an
    # unused correct reduction elsewhere cannot satisfy this certificate.
    definitions = {value: (label, expression) for label, code in blocks.items()
                   for value, expression in re.findall(r'^  (%[-\w.$]+) = (.+?)(?:, ![^\n]*)?$',
                                                       code, re.M)}
    predecessors = {label: {pred for pred, code in blocks.items()
                           if label in re.findall(r'\blabel %([-\w.$]+)', terminator(code))}
                    for label in blocks}
    for pointer, result_roots in (('%out', roots[1]), ('%o1', roots[0])):
        stores = re.findall(r'^  store i32 (%[-\w.$]+), ptr ' + re.escape(pointer) +
                            r', align 4(?:, ![^\n]*)?$', blocks['exit'], re.M)
        need(len(stores) == 1, 'output store ' + pointer)
        seen = set()

        def forward(value, trail=()):
            need(value not in trail and len(trail) < 8, 'result forwarding cycle/depth')
            if value in result_roots:
                seen.add(value)
                return
            need(value in definitions, 'result definition')
            label, expression = definitions[value]
            need(expression.startswith('phi i32 '), 'typed result forwarding')
            inputs = re.findall(r'\[ (%[-\w.$]+), %([-\w.$]+) \]', expression[8:])
            need(expression == 'phi i32 ' + ', '.join(f'[ {v}, %{p} ]' for v, p in inputs) and
                 len(inputs) == len(predecessors[label]) and
                 {p for _, p in inputs} == predecessors[label], 'result value/edge')
            for incoming, _ in inputs:
                forward(incoming, trail + (value,))

        forward(stores[0])
        need(seen == result_roots, 'all vector/tail results reach output')
    need('%o1 = getelementptr i32, ptr %out, i64 1' in blocks['exit'], 'XOR output address')
    for instruction in ('store i32 17, ptr %out, align 4',
                        '%b1 = getelementptr i32, ptr %out, i64 1',
                        'store i32 23, ptr %b1, align 4'):
        need(instruction in blocks['bypass'], 'zero-entry results')
    entries = (None if evl else dispatch_entry_certificates(
        body, producer_vf, consumer_vf, [tail['vf'] for tail in tails]))
    if stages is not None:
        stages.update(primary_labels=vectors, ordinary_tails=tails, entries=entries)
    if probe:
        need(not evl, 'host scalar-remainder policy')
        for stage, label in enumerate((vectors[0], 'loop', vectors[1], 'scalar.fission.consumer.body')):
            pattern = (rf'^{re.escape(label)}:[^\n]*\n'
                       r'(?:[ \t]+%[^\n]* = phi [^\n]*\n)*')
            body, count = re.subn(pattern, lambda m: m[0] +
                                  f'  call void @fission_interleave_probe(i32 {stage})\n',
                                  body, flags=re.M)
            need(count == 1, 'stage probe ' + str(stage))
        for role, tail in enumerate(tails):
            if not tail['vf']:
                continue
            pattern = (rf'^{re.escape(tail["label"])}:[^\n]*\n'
                       r'(?:[ \t]+%[^\n]* = phi [^\n]*\n)*')
            code = (f'  %fission.dispatch.probe.scale.{role} = call i64 @llvm.vscale.i64()\n'
                    f'  %fission.dispatch.probe.lanes.{role} = mul i64 '
                    f'%fission.dispatch.probe.scale.{role}, {tail["vf"]}\n'
                    f'  call void @fission_interleave_tail_probe(i32 {role}, '
                    f'i64 %fission.dispatch.probe.lanes.{role})\n')
            body, count = re.subn(pattern, lambda m: m[0] + code, body, flags=re.M)
            need(count == 1, 'ordinary vector remainder probe')
    return body


def instrument_interleave_stages(ir, functions, ordinary_tails=None):
    """Host-only entry counters, after PHIs, for each actual emitted stage.

    The uninstrumented scalable IR is separately submitted for RVV codegen.
    Keep the original four counters. Additional ordinary vector tails get
    separate entry and lane counters; their residual scalar iterations still
    use the original scalar slots. The C oracle requires exact N accounting.
    """
    labels = ('vector.fission.producer.body', 'scalar.fission.producer.body',
              'vector.fission.accumulator.body', 'scalar.fission.accumulator.body')
    for function in functions:
        pattern = rf'^define[^\n]* @{function}\([^\n]*\{{.*?^}}'
        matches = list(re.finditer(pattern, ir, re.M | re.S))
        assert len(matches) == 1, f'missing/duplicate function {function}'
        body = matches[0][0]
        for stage, label in enumerate(labels):
            header = (rf'^{re.escape(label)}:[^\n]*\n'
                      r'(?:[ \t]+%[^\n]* = phi [^\n]*\n)*')
            body, count = re.subn(
                header, lambda m: m[0] +
                f'  call void @fission_interleave_probe(i32 {stage})\n',
                body, flags=re.M)
            assert count == 1, f'{function}: missing/duplicate {label}'
        for role, tail in enumerate((ordinary_tails or {}).get(function, ())):
            if not tail['vf']:
                continue
            label, vf = tail['label'], tail['vf']
            header = (rf'^{re.escape(label)}:[^\n]*\n'
                      r'(?:[ \t]+%[^\n]* = phi [^\n]*\n)*')
            # This path is instrumented before specialization. Use the actual
            # emitted width; specialize() replaces vscale along with the IR.
            probe = (f'  %fission.tail.probe.scale.{role} = call i64 @llvm.vscale.i64()\n'
                     f'  %fission.tail.probe.lanes.{role} = mul i64 '
                     f'%fission.tail.probe.scale.{role}, {vf}\n'
                     f'  call void @fission_interleave_tail_probe(i32 {role}, '
                     f'i64 %fission.tail.probe.lanes.{role})\n')
            body, count = re.subn(header, lambda m: m[0] + probe, body, flags=re.M)
            assert count == 1, f'{function}: missing/duplicate {label}'
        ir = ir[:matches[0].start()] + body + ir[matches[0].end():]
    return (ir + '\ndeclare void @fission_interleave_probe(i32)\n'
            'declare void @fission_interleave_tail_probe(i32, i64)\n')


def check_dispatch_overlap(ir, evl, producer_vf, consumer_vf, probe=False, capacity=65, stages=None):
    """Both paths accept this AoS loop; default dispatch must split early once.

    Ordinary LV selects each width independently. Check the actual widths from
    source-located stage remarks and reuse the four-stage C oracle. Find the
    headers in each half separately: suffixes vary for the second vector body.
    """
    name = 'interleave2_ordered'
    body = function_definition(ir, name)
    producer, consumer = scalar_consumer(body, name)
    assert body.count(f'alloca [{capacity} x double]') == 1, body
    assert 'vector.fission.' not in body, body
    for half, tag, scalar in ((producer, 'producer', 'loop'),
                              (consumer, 'consumer', 'scalar.fission.consumer.body')):
        assert len(re.findall(r'^vector\.body[\w.$-]*:', half, re.M)) == 1, half
        for label, code in loop_blocks(half).items():
            if label.startswith('vector.body') or label == scalar:
                check_loop_provenance(ir, code, tag)
    assert re.search(rf'(?:store <vscale x {producer_vf} x double>|'
                     rf'@llvm\.(?:vp|masked)\.store\.nxv{producer_vf}f64\.)',
                     producer), producer
    reduction = r'vp\.reduce' if evl else r'vector\.reduce'
    assert len(re.findall(rf'call double @llvm\.{reduction}\.fadd\.nxv{consumer_vf}f64\(',
                          consumer)) == 2, consumer
    assert not re.search(r'\bfadd\s+[^\n]*\breassoc\b', body), body
    # Chunk overlap uses a different entering count/capacity and retains its
    # dedicated chunk certificates. Only the full-trip dispatch uses this ABI.
    if capacity == 65 and not evl:
        entries = dispatch_entry_certificates(body, producer_vf, consumer_vf)
        if stages is not None:
            stages.update(entries=entries)
    if probe:
        def instrument(half, label, stage):
            header = (rf'^{label}:[^\n]*\n'
                      r'(?:[ \t]+%[^\n]* = phi [^\n]*\n)*')
            half, count = re.subn(
                header, lambda m: m[0] +
                f'  call void @fission_interleave_probe(i32 {stage})\n',
                half, flags=re.M)
            assert count == 1, f'@{name}: missing/duplicate stage {stage}\n{half}'
            return half
        producer = instrument(producer, r'vector\.body[\w.$-]*', 0)
        producer = instrument(producer, 'loop', 1)
        consumer = instrument(consumer, r'vector\.body[\w.$-]*', 2)
        consumer = instrument(consumer, r'scalar\.fission\.consumer\.body', 3)
        return producer + 'scalar.fission.consumer.ph:\n' + consumer
    return body


def chunk_instructions(code):
    # Normalize each instruction separately. Metadata/comments cannot hide a
    # later instruction or satisfy a complete arithmetic/edge check by prefix.
    return [re.sub(r', ![^\n]*$', '', line.split(';', 1)[0]).strip()
            for line in code.splitlines() if line.split(';', 1)[0].strip()]


def require_chunk_instruction(body, label, instruction):
    blocks = loop_blocks(body)
    # LV may drop an integer no-wrap promise. Permit only removal of the
    # flags present in this expectation, keeping the entire instruction exact.
    # In particular this never normalizes FP flags, operands or integer types.
    variants = {instruction}
    match = re.match(r'%[-\w.$]+ = (?:add|sub|mul|shl) ((?:nuw |nsw )+)i\d+ ', instruction)
    if match:
        spellings = {match[1]}
        for flag in match[1].split():
            spellings |= {flags.replace(flag + ' ', '', 1) for flags in list(spellings)}
        variants = {instruction[:match.start(1)] + flags + instruction[match.end(1):]
                    for flags in spellings}
    assert sum(line in variants for line in chunk_instructions(blocks[label])) == 1, (
        label, instruction, body)
    if instruction.startswith('%'):
        value = instruction.split(' = ', 1)[0]
        assert len(re.findall(rf'^[ \t]+{re.escape(value)} = ', body, re.M)) == 1, body


def check_chunk_controller(body, capacity, ty='i64', preheader='preheader',
                           exit='producer.exit', count='%n', compact=False):
    # Fixed, checked controller vocabulary, shared by scalar and vector-stage
    # fixtures. N is the actual entering count, never a capacity witness.
    for label, instructions in (
        (preheader, ['br label %scalar.fission.chunk']),
        ('scalar.fission.chunk', [
            f'%fission.chunk.base = phi {ty} [ 0, %{preheader} ], '
            '[ %fission.chunk.next, %scalar.fission.chunk.latch ]',
            f'%fission.chunk.remaining = sub nuw {ty} {count}, %fission.chunk.base',
            f'%fission.chunk.partial = icmp ult {ty} %fission.chunk.remaining, {capacity}',
            f'%fission.chunk.count = select i1 %fission.chunk.partial, {ty} '
            f'%fission.chunk.remaining, {ty} {capacity}',
            'br label %scalar.fission.producer.ph']),
        ('scalar.fission.chunk.latch', [
            f'%fission.chunk.next = add nuw {ty} %fission.chunk.base, ' +
            ('%fission.producer.completed' if compact else '%fission.chunk.count'),
            f'%fission.chunk.more = icmp ne {ty} %fission.chunk.next, {count}',
            f'br i1 %fission.chunk.more, label %scalar.fission.chunk, label %{exit}'])):
        for instruction in instructions:
            require_chunk_instruction(body, label, instruction)


def check_aos_chunk_results(body, evl, vf):
    """Prove the two ordered consumer states, including LV's exit forwarding.

    This is a bounded fixture proof, not name-based result matching or an IR
    equivalence solver. Roots are the actual recurrence updates. A result may
    only be a root or typed PHIs on real CFG edges; each edge must carry the
    most recent update on that path. Four forwarding PHIs cover the dedicated
    scalar exit added by repeated LV as well as middle/result LCSSA joins.
    """
    blocks = {label: chunk_instructions(code) for label, code in loop_blocks(body).items()}
    definitions = {}
    for label, code in blocks.items():
        for line in code:
            match = re.match(r'(%[-\w.$]+) = (.+)$', line)
            if match:
                assert match[1] not in definitions, (match[1], body)
                definitions[match[1]] = (label, match[2])
    successors = {label: re.findall(r'\blabel %([-\w.$]+)', code[-1])
                  for label, code in blocks.items()}
    predecessors = {label: {p for p, targets in successors.items() if label in targets}
                    for label in blocks}
    # All fixture blocks are reachable. Compute availability at an incoming
    # edge, so a correctly named value defined on another path cannot pass.
    dominators = {label: set(blocks) for label in blocks}
    dominators['entry'] = {'entry'}
    changed = True
    while changed:
        changed = False
        for label in blocks.keys() - {'entry'}:
            assert predecessors[label], label
            dom = {label} | set.intersection(*(dominators[p] for p in predecessors[label]))
            if dom != dominators[label]:
                dominators[label] = dom
                changed = True

    def phi(value, ty):
        label, expression = definitions[value]
        assert expression.startswith(f'phi {ty} '), (value, expression)
        inputs = re.findall(r'\[ ([^,\]\n]+), %([-\w.$]+) \]', expression[len(f'phi {ty} '):])
        assert expression == f'phi {ty} ' + ', '.join(f'[ {v}, %{p} ]' for v, p in inputs)
        assert len(inputs) == len(predecessors[label]), (value, inputs, predecessors[label])
        assert {p for _, p in inputs} == predecessors[label], (value, inputs, predecessors[label])
        return label, dict((p, v) for v, p in inputs)

    def forward(value, use, roots, ty, trail=()):
        # Stop at an executed update (or at consumer entry when proving a
        # scalar resume seed). No controller backedge, producer recurrence,
        # arbitrary arithmetic, freeze, select or stale accumulator is chased.
        def reaching(label, seen=()):
            if label in roots:
                return {label}
            assert label not in seen and label != 'scalar.fission.chunk', (label, roots)
            assert predecessors[label], label
            return set.union(*(reaching(p, seen + (label,)) for p in predecessors[label]))

        origins = reaching(use)
        if len(origins) == 1:
            origin = next(iter(origins))
            if value == roots[origin]:
                assert definitions[value][0] in dominators[use], (value, use)
                return
        assert value not in trail and len(trail) < 4, (value, trail)
        label, inputs = phi(value, ty)
        assert label in dominators[use] and reaching(label) == origins, (value, use)
        for pred, incoming in inputs.items():
            forward(incoming, pred, roots, ty, trail + (value,))

    consumer = scalar_consumer(body, 'interleave2_ordered')[1]
    vectors = [label for label in loop_blocks(consumer) if label.startswith('vector.body')]
    assert len(vectors) == 1, vectors
    vector = vectors[0]
    vector_ty = f'<vscale x {vf} x double>'
    reduction = 'vp.reduce' if evl else 'vector.reduce'
    # Bind both ordered recurrences to the same actual scratch load, including
    # the VP mask/EVL when present. No unrestricted intrinsic/name match.
    loads = [(value, expr) for value, (label, expr) in definitions.items()
             if label == vector and (expr.startswith(f'load {vector_ty}, ') or
                                     expr.startswith(f'call {vector_ty} @llvm.vp.load.'))]
    assert len(loads) == 1, loads
    contribution, load = loads[0]
    if evl:
        match = re.fullmatch(rf'call {re.escape(vector_ty)} @llvm\.vp\.load\.nxv{vf}f64\.p0'
                             rf'\(ptr align 8 (%[-\w.$]+), (<vscale x {vf} x i1> splat \(i1 true\)), '
                             r'i32 (%[-\w.$]+)\)', load)
        assert match, load
        address, mask, length = match.groups()
        arguments = f', {mask}, i32 {length}'
    else:
        match = re.fullmatch(rf'load {re.escape(vector_ty)}, ptr (%[-\w.$]+), align 8', load)
        assert match, load
        address, arguments = match[1], ''
    assert definitions[address][0] == vector, address
    assert re.fullmatch(r'getelementptr inbounds \[64 x double\], ptr %scalar\.fission\.scratch, '
                        r'i32 0, i64 %[-\w.$]+', definitions[address][1]), definitions[address]
    results = []
    for r, u, start in [('sum', 'update', '%start'), ('bits', 'updated.bits', '-0.000000e+00')]:
        carry = f'%{r}.chunk.carry'
        label, inputs = phi(carry, 'double')
        assert label == 'scalar.fission.chunk' and inputs['preheader'] == start, (carry, inputs)
        result = inputs['scalar.fission.chunk.latch']
        candidates = []
        for value, (label, expression) in definitions.items():
            if label == vector and expression.startswith('phi double '):
                _, incoming = phi(value, 'double')
                if carry in incoming.values():
                    candidates.append((value, incoming))
        assert len(candidates) == 1, (carry, candidates)
        accumulator, incoming = candidates[0]
        assert len(incoming) == 2 and vector in incoming, incoming
        vector_ph = next(p for p in incoming if p != vector)
        assert incoming[vector_ph] == carry and definitions[carry][0] in dominators[vector_ph]
        update = incoming[vector]
        assert definitions[update] == (vector,
            f'call double @llvm.{reduction}.fadd.nxv{vf}f64(double {accumulator}, '
            f'{vector_ty} {contribution}{arguments})'), definitions[update]
        roots = {vector: update}
        scalar = 'scalar.fission.consumer.body'
        if scalar in blocks:
            assert not evl, body
            label, incoming = phi(f'%{r}.consume', 'double')
            assert label == scalar and len(incoming) == 2, incoming
            scalar_update = f'%{u}.consume'
            assert incoming[scalar] == scalar_update, incoming
            seed_pred = next(p for p in incoming if p != scalar)
            forward(incoming[seed_pred], seed_pred,
                    {'scalar.fission.consumer.ph': carry, vector: update}, 'double')
            require_chunk_instruction(body, scalar,
                                      f'{scalar_update} = fadd double %{r}.consume, %fission.contribution')
            load_label, load = definitions['%fission.contribution']
            match = re.fullmatch(r'load double, ptr (%[-\w.$]+), align 8', load)
            assert load_label == scalar and match, load
            require_chunk_instruction(body, scalar,
                                      f'{match[1]} = getelementptr inbounds [64 x double], '
                                      'ptr %scalar.fission.scratch, i32 0, i64 %fission.consumer.iv')
            roots[scalar] = scalar_update
        forward(result, 'scalar.fission.chunk.latch', roots, 'double')
        require_chunk_instruction(body, 'exit',
                                  f'%{u}.lcssa = phi double [ {result}, %scalar.fission.chunk.latch ]')
        assert phi(f'%{u}.lcssa', 'double') == (
            'exit', {'scalar.fission.chunk.latch': result})
        results.append(result)
    assert results[0] != results[1], results
    for instruction in ['store double %update.lcssa, ptr %out, align 8',
                        '%o1 = getelementptr double, ptr %out, i64 1',
                        'store double %updated.bits.lcssa, ptr %o1, align 8']:
        require_chunk_instruction(body, 'exit', instruction)
    return results


def check_aos_chunk_scalar(ir):
    """Exact pre-LV proof for the vectorizable dispatch boundary fixture."""
    body = function_definition(ir, 'interleave2_ordered')
    blocks = loop_blocks(body)
    check_chunk_controller(body, 64, exit='exit')
    assert body.count('alloca [64 x double]') == body.count('alloca ') == 1, body
    assert 'fission.export' not in body and '<vscale x' not in body, body
    for instruction in ['%bounded = icmp ule i64 %n, 65',
                        '%nonzero = icmp ne i64 %n, 0',
                        '%enter = and i1 %bounded, %nonzero',
                        'br i1 %enter, label %preheader, label %bypass']:
        require_chunk_instruction(body, 'entry', instruction)
    for instruction in [
        '%i = phi i64 [ %fission.chunk.base, %scalar.fission.producer.ph ], [ %next, %loop ]',
        '%fission.producer.ordinal = phi i64 [ 0, %scalar.fission.producer.ph ], '
        '[ %fission.producer.next, %loop ]',
        '%next = add nuw i64 %i, 1',
        '%fission.producer.next = add nuw i64 %fission.producer.ordinal, 1',
        '%fission.producer.more = icmp ne i64 %fission.producer.next, %fission.chunk.count',
        'br i1 %fission.producer.more, label %loop, label %scalar.fission.consumer.ph']:
        require_chunk_instruction(body, 'loop', instruction)
    for label, ordinal, opcode in [('loop', 'fission.producer.ordinal', 'store'),
                                  ('scalar.fission.consumer.body', 'fission.consumer.iv', 'load')]:
        code = blocks[label]
        address = re.findall(r'^  (%[-\w.$]+) = getelementptr inbounds \[64 x double\], '
                             rf'ptr %scalar.fission.scratch, i32 0, i64 %{ordinal}(?:, ![^\n]*)?$',
                             code, re.M)
        assert len(address) == 1, code
        require_chunk_instruction(body, label,
                                  f'{address[0]} = getelementptr inbounds [64 x double], '
                                  f'ptr %scalar.fission.scratch, i32 0, i64 %{ordinal}')
        instruction = (f'store double %term, ptr {address[0]}, align 8' if opcode == 'store'
                       else f'%fission.contribution = load double, ptr {address[0]}, align 8')
        require_chunk_instruction(body, label, instruction)
    for reduction, update, start in [('sum', 'update', '%start'),
                                     ('bits', 'updated.bits', '-0.000000e+00')]:
        for label, instruction in [
            ('scalar.fission.chunk', f'%{reduction}.chunk.carry = phi double [ {start}, %preheader ], '
             f'[ %{reduction}.chunk.result, %scalar.fission.chunk.latch ]'),
            ('scalar.fission.consumer.body', f'%{reduction}.consume = phi double '
             f'[ %{reduction}.chunk.carry, %scalar.fission.consumer.ph ], '
             f'[ %{update}.consume, %scalar.fission.consumer.body ]'),
            ('scalar.fission.chunk.latch', f'%{reduction}.chunk.result = phi double '
             f'[ %{update}.consume, %scalar.fission.consumer.body ]')]:
            require_chunk_instruction(body, label, instruction)
        require_chunk_instruction(body, 'exit', f'%{update}.lcssa = phi double '
                                  f'[ %{reduction}.chunk.result, %scalar.fission.chunk.latch ]')
    require_chunk_instruction(body, 'scalar.fission.consumer.body',
                             '%fission.consumer.more = icmp ne i64 %fission.consumer.next, %fission.chunk.count')
    for instruction in [
        '%fission.consumer.iv = phi i64 [ 0, %scalar.fission.consumer.ph ], '
        '[ %fission.consumer.next, %scalar.fission.consumer.body ]',
        '%fission.consumer.next = add nuw i64 %fission.consumer.iv, 1',
        '%update.consume = fadd double %sum.consume, %fission.contribution',
        '%updated.bits.consume = fadd double %bits.consume, %fission.contribution',
        'br i1 %fission.consumer.more, label %scalar.fission.consumer.body, label %scalar.fission.chunk.latch']:
        require_chunk_instruction(body, 'scalar.fission.consumer.body', instruction)
    return body


def check_aos_chunk(ir, evl, producer_vf, consumer_vf, probe=False):
    body = check_dispatch_overlap(ir, evl, producer_vf, consumer_vf, capacity=64)
    check_chunk_controller(body, 64, exit='exit')
    blocks = loop_blocks(body)
    check_loop_provenance(ir, blocks['scalar.fission.chunk.latch'], 'stage')
    sum_result, bits_result = check_aos_chunk_results(body, evl, consumer_vf)
    assert body.count('alloca ') == 1 and 'fission.export' not in body, body
    if not probe:
        return body
    assert not evl

    def before_terminator(label, instructions):
        nonlocal body
        code = loop_blocks(body)[label]
        changed, count = re.subn(r'(?=^  (?:br |ret ))', lambda _: instructions, code, flags=re.M)
        assert count == 1, code
        body = body.replace(code, changed, 1)

    before_terminator('scalar.fission.chunk',
                  '  call void @record_aos_chunk_begin(i64 %fission.chunk.base, '
                  'i64 %fission.chunk.count, double %sum.chunk.carry, double %bits.chunk.carry)\n')
    before_terminator('scalar.fission.chunk.latch',
                  f'  call void @record_aos_chunk_end(double {sum_result}, double {bits_result})\n')
    before_terminator('bypass', '  call void @record_aos_chunk_bypass()\n')
    producer, consumer = scalar_consumer(body, 'interleave2_ordered')
    for half, role, vf, scalar in [(producer, 'producer', producer_vf, 'loop'),
                                  (consumer, 'consumer', consumer_vf, 'scalar.fission.consumer.body')]:
        for label, code in loop_blocks(half).items():
            vector = label.startswith('vector.body')
            if not vector and label != scalar:
                continue
            element = f'<vscale x {vf} x double>' if vector else 'double'
            address_pattern = (rf'store {re.escape(element)} %[-\w.$]+, ptr (%[-\w.$]+), align 8'
                               if role == 'producer' else
                               rf'load {re.escape(element)}, ptr (%[-\w.$]+), align 8')
            addresses = re.findall(address_pattern, code)
            assert len(addresses) == 1, code
            prefix = ''
            lanes = '1'
            if vector:
                prefix = (f'  %aos.probe.scale.{role} = call i64 @llvm.vscale.i64()\n'
                          f'  %aos.probe.lanes.{role} = mul i64 %aos.probe.scale.{role}, {vf}\n')
                lanes = f'%aos.probe.lanes.{role}'
            arguments = f'ptr %scalar.fission.scratch, ptr {addresses[0]}, i64 {lanes}, i32 {int(vector)}'
            if role == 'producer':
                input_element = f'<vscale x {2 * vf} x double>' if vector else 'double'
                inputs = re.findall(rf'load {re.escape(input_element)}, ptr (%[-\w.$]+), align 8', code)
                assert len(inputs) == (1 if vector else 2), code
                arguments = f'ptr {inputs[0]}, ' + arguments
            before_terminator(label, prefix + f'  call void @record_aos_chunk_{role}({arguments})\n')
    return body


CHUNK_FUNCTIONS = ('chunk_mixed', 'chunk_narrow', 'chunk_ne', 'chunk_nested')


def check_chunk_function(ir, name, capacity, evl=False, scalar=False, probe=False):
    """Bounded scheduler proof, then probes in the actual generated stages.

    The scalar-only run checks exact carry/result/export edges before ordinary
    LV changes consumer exits. Execution runs check stage provenance and count
    every chunk, original producer iteration, vector consumer and scalar tail.
    C independently checks each chunk's count/order and all observable results.
    """
    body = function_definition(ir, name)
    blocks = loop_blocks(body)
    narrow, nested = name == 'chunk_narrow', name == 'chunk_nested'
    ty = 'i8' if narrow else 'i64'
    header = 'inner' if nested else 'loop'
    original_ph = 'inner.ph' if nested else 'preheader'
    original_exit = 'row.exit' if nested else 'producer.exit'
    check_chunk_controller(body, capacity, ty, original_ph, original_exit, '%n8' if narrow else '%n')
    chunk = blocks['scalar.fission.chunk']
    latch = blocks['scalar.fission.chunk.latch']
    producer = blocks[header]
    forward = blocks['scalar.fission.consumer.ph']
    for element in ('i32', 'double', 'float'):
        assert body.count(f'alloca [{capacity} x {element}]') == 1, body
    assert body.count('alloca ') == 3, body
    assert body.count('call i32 @scalar_helper(') == 1, body
    assert producer.count('load i32,') == 1 and producer.count('load double,') == 1, producer
    assert producer.count('store ') == 3 and 'fadd ' not in producer, producer
    assert '<vscale x' not in producer, producer

    def check_scratch_indices(code, ordinal):
        addresses = re.findall(
            rf'(%[-\w.$]+) = getelementptr inbounds \[{capacity} x (i32|double|float)\], '
            r'ptr (%[-\w.$]+), i32 0, i64 (%[-\w.$]+)', code)
        assert len(addresses) == 3, code
        assert {element for _, element, _, _ in addresses} == {'i32', 'double', 'float'}
        for address, element, slot, index in addresses:
            assert f'{slot} = alloca [{capacity} x {element}]' in body, body
            if narrow:
                assert f'{index} = zext i8 %{ordinal} to i64' in code, code
            else:
                assert index == '%' + ordinal, code
            if ordinal == 'fission.producer.ordinal':
                contribution = {'i32': 'c', 'double': 'dc', 'float': 'fc'}[element]
                assert f'store {element} %{contribution}, ptr {address},' in code, code
            else:
                assert f'load {element}, ptr {address},' in code, code

    check_scratch_indices(producer, 'fission.producer.ordinal')
    # The shared controller proof above checks complete instructions, including
    # the narrow count and exit edges. Use the same no-wrap-removal policy for
    # inherited producer assertions, without substring/prefix alternatives.
    for instruction in [
        f'%iv = phi {ty} [ %fission.chunk.base, %scalar.fission.producer.ph ], [ %next, %{header} ]',
        f'%fission.producer.ordinal = phi {ty} [ 0, %scalar.fission.producer.ph ], '
        f'[ %fission.producer.next, %{header} ]',
        f'%next = add nuw {ty} %iv, 1',
        f'%fission.producer.next = add nuw {ty} %fission.producer.ordinal, 1',
        f'%fission.producer.more = icmp ne {ty} %fission.producer.next, %fission.chunk.count',
        f'br i1 %fission.producer.more, label %{header}, label %scalar.fission.consumer.ph']:
        require_chunk_instruction(body, header, instruction)
    for value, element in [('x', 'i32'), ('c', 'i32'),
                           ('wide' if narrow else 'iv', 'i64'),
                           ('wide.next' if narrow else 'next', 'i64'),
                           ('dc', 'double'), ('fc', 'float')]:
        assert (f'%{value}.fission.export = phi {element} [ %{value}, %{header} ]'
                in forward), forward
    assert forward.count(' = phi ') == 6, forward
    assert not re.search(r'\b(?:fadd|call)\s+[^\n]*\breassoc\b', body), body
    check_loop_provenance(ir, producer, 'producer')
    check_loop_provenance(ir, latch, 'stage')
    vectors = [label for label in blocks if label.startswith('vector.body')]
    assert len(vectors) <= 1, body
    if scalar:
        assert not vectors, body
        consumer = blocks['scalar.fission.consumer.body']
        check_scratch_indices(consumer, 'fission.consumer.iv')
        starts = ['%carry', '%carry1', '%dcarry', '%fcarry'] if nested else [
            '17', '-7', '%start', '%fstart']
        for r, u, element, start in zip(('r0', 'r1', 'rd', 'rf'),
                                       ('u0', 'u1', 'ud', 'uf'),
                                       ('i32', 'i32', 'double', 'float'), starts):
            assert (f'%{r}.chunk.carry = phi {element} [ {start}, %{original_ph} ], '
                    f'[ %{r}.chunk.result, %scalar.fission.chunk.latch ]') in chunk, chunk
            assert (f'%{r}.chunk.result = phi {element} [ %{u}.consume, '
                    '%scalar.fission.consumer.body ]') in latch, latch
            assert (f'%{r}.consume = phi {element} [ %{r}.chunk.carry, '
                    '%scalar.fission.consumer.ph ]') in consumer, consumer
            assert (f'%out.{r} = phi {element} [ %{r}.chunk.result, '
                    '%scalar.fission.chunk.latch ]') in blocks[original_exit], body
        assert '%ud.consume = fadd double %rd.consume,' in consumer, consumer
        assert '%uf.consume = fadd float %rf.consume,' in consumer, consumer
        for value, element in [('x', 'i32'), ('c', 'i32'), ('c.copy', 'i32'),
                               ('iv', 'i64'), ('next', 'i64'),
                               ('dc', 'double'), ('fc', 'float')]:
            source = 'c' if value == 'c.copy' else value
            if narrow and source in ('iv', 'next'):
                source = 'wide' if source == 'iv' else 'wide.next'
            assert (f'%out.{value} = phi {element} [ %{source}.fission.export, '
                    '%scalar.fission.chunk.latch ]') in blocks[original_exit], body
    if vectors:
        vector = blocks[vectors[0]]
        check_loop_provenance(ir, vector, 'consumer')
        # Integer vector accumulators are finalized in the consumer's middle
        # block; ordered FP updates execute in each actual vector iteration.
        consumer_code = body.split('scalar.fission.consumer.ph:', 1)[1]
        assert '@llvm.vector.reduce.add.nxv4i32' in consumer_code, consumer_code
        for element, suffix in [('double', 'f64'), ('float', 'f32')]:
            reduction = 'vp.reduce' if evl else 'vector.reduce'
            assert f'call {element} @llvm.{reduction}.fadd.nxv4{suffix}(' in vector, vector
        if evl:
            assert '@llvm.experimental.get.vector.length.' in vector, vector
        else:
            for element in ('i32', 'double', 'float'):
                assert vector.count(f'load <vscale x 4 x {element}>') == 1, vector
    if 'scalar.fission.consumer.body' in blocks:
        check_loop_provenance(ir, blocks['scalar.fission.consumer.body'], 'consumer')
    if not probe:
        return body

    def insert(label, instructions):
        nonlocal body
        body, count = re.subn(
            rf'(^{re.escape(label)}:[^\n]*\n(?:[^\n]* = phi [^\n]*\n)*)',
            lambda m: m[0] + instructions, body, flags=re.M)
        assert count == 1, f'@{name}: missing/duplicate probe site {label}'

    # Count and verify local scratch ordinals and global producer IVs, not
    # reconstructed input trip counts. Widening narrow values is probe-only.
    global_iv, ordinal = '%iv', '%fission.producer.ordinal'
    if narrow:
        insert(header, '  %chunk.probe.global = zext i8 %iv to i64\n'
                       '  %chunk.probe.local = zext i8 %fission.producer.ordinal to i64\n'
                       '  call void @record_chunk_producer(i64 %chunk.probe.global, i64 %chunk.probe.local)\n')
    else:
        insert(header, f'  call void @record_chunk_producer(i64 {global_iv}, i64 {ordinal})\n')
    # Count is defined after the header PHIs; insert at its terminator.
    code = loop_blocks(body)['scalar.fission.chunk']
    begin = ('  %chunk.probe.base = zext i8 %fission.chunk.base to i64\n'
             '  %chunk.probe.count = zext i8 %fission.chunk.count to i64\n'
             '  call void @record_chunk_begin(i64 %chunk.probe.base, i64 %chunk.probe.count)\n'
             if narrow else '  call void @record_chunk_begin(i64 %fission.chunk.base, i64 %fission.chunk.count)\n')
    changed, count = re.subn(r'(?=^  br label %scalar.fission.producer.ph)',
                             lambda _: begin, code, flags=re.M)
    assert count == 1, code
    body = body.replace(code, changed, 1)
    insert('scalar.fission.chunk.latch', '  call void @record_chunk_end()\n')
    for label in vectors:
        insert(label, '  call void @record_chunk_vector()\n')
    if 'scalar.fission.consumer.body' in blocks:
        insert('scalar.fission.consumer.body', '  call void @record_chunk_tail()\n')
    return body



COMPACT_CHUNK_FUNCTIONS = ('compact_chunk_diamond', 'compact_chunk_cfg',
                           'compact_chunk_narrow', 'compact_chunk_rows')


def check_compact_chunk_remarks(remarks, name, capacity, size, vectorized):
    mode = COMPACT_CHUNK_FUNCTIONS.index(name)
    loc = f'scalar-compact-chunks.c:{12 + 10 * mode}:3:'
    chunk = ', chunked schedule, trip bound 65' if capacity < 65 else ''
    carries = ', producer state carries 2' if capacity < 65 else ''
    expected = (rf'{re.escape(loc)} split scalar-IR reduction loop;[^\n]*'
                rf'scratch capacity {capacity}, scratch bytes {size}, producer live-outs 6'
                rf'{chunk}, scratch store bytes/iteration 12, scratch load bytes/iteration 12, '
                rf'producer reread bytes/iteration 0, duplicated producer instructions 0{carries}\n')
    assert len(re.findall(expected, remarks)) == 1, (name, remarks)
    for role, vf in [('producer', '1'), ('consumer', 'vscale x 4' if vectorized else '1')]:
        assert f'{loc} scalar-IR fission {role} VF {vf}\n' in remarks, (name, remarks)
    # A correct first visit must not hide a later lost location under repeated
    # LV. Every stage in this fixture has one of the four exact target sites.
    for line in remarks.splitlines():
        if 'scalar-IR fission ' in line:
            assert re.fullmatch(r'remark: scalar-compact-chunks.c:(12|22|32|42):3: '
                                r'scalar-IR fission (producer|consumer) VF (1|vscale x 4)',
                                line), (name, line)


def check_compact_chunk(ir, original, name, capacity, scalar=False, evl=False, probe=False):
    """Certify the original producer, both local counts and every carry/export.

    The existing consumer certificate checks P-based entry/rounding/tail bounds,
    scalar/vector joins and exact empty starts. Its only new option is the
    chunk-local counter's zero-entry edge; no inherited obligations are removed.
    """
    body = function_definition(ir, name)
    blocks = loop_blocks(body)
    source = loop_blocks(function_definition(original, name))
    mode = COMPACT_CHUNK_FUNCTIONS.index(name)
    narrow, nested, cfg = mode == 2, mode == 3, mode in (1, 3)
    chunked = capacity < 65
    ty, n = ('i8', '%n8') if narrow else ('i64', '%n')
    ph, end = ('inner.ph', 'row.exit') if nested else ('preheader', 'producer.exit')
    guard = 'scalar.fission.consumer.guard'
    initial = ['%carry0', '%carry1', '%carryd'] if nested else ['17', '-7', '%start']
    state_starts = ['%seed', '%oldseed'] if nested else ['23', '-11']
    starts = [(r, t, f'%{r}.chunk.carry' if chunked else start)
              for r, t, start in zip(('r0', 'r1', 'rd'), ('i32', 'i32', 'double'), initial)]
    if chunked:
        check_chunk_controller(body, capacity, ty, ph, end, n, compact=True)
        for instruction in [
                f'%fission.producer.completed = phi {ty} [ %fission.producer.next, %latch ]']:
            require_chunk_instruction(body, guard, instruction)
        for instruction in [
                f'%fission.producer.ordinal = phi {ty} [ 0, %scalar.fission.producer.ph ], '
                '[ %fission.producer.next, %latch ]',
                f'%iv = phi {ty} [ %fission.chunk.base, %scalar.fission.producer.ph ], [ %next, %latch ]']:
            require_chunk_instruction(body, 'loop', instruction)
        for instruction in [
                f'%fission.producer.next = add nuw {ty} %fission.producer.ordinal, 1',
                f'%fission.producer.more = icmp ne {ty} %fission.producer.next, %fission.chunk.count',
                f'br i1 %fission.producer.more, label %loop, label %{guard}']:
            require_chunk_instruction(body, 'latch', instruction)
        for r, t, start in zip(('r0', 'r1', 'rd'), ('i32', 'i32', 'double'), initial):
            require_chunk_instruction(body, 'scalar.fission.chunk',
                                      f'%{r}.chunk.carry = phi {t} [ {start}, %{ph} ], '
                                      f'[ %{r}.result, %scalar.fission.chunk.latch ]')
        require_chunk_instruction(body, 'scalar.fission.consumer.exit',
                                  'br label %scalar.fission.chunk.latch')
        check_loop_provenance(ir, blocks['scalar.fission.chunk.latch'], 'stage')
    else:
        assert 'scalar.fission.chunk:' not in body, body
        require_chunk_instruction(body, 'scalar.fission.consumer.exit', f'br label %{end}')
    for state, start, backedge in zip(('prev', 'older'), state_starts, ('state.next', 'prev')):
        if chunked:
            require_chunk_instruction(body, 'scalar.fission.chunk',
                                      f'%{state}.chunk.carry = phi i32 [ {start}, %{ph} ], '
                                      f'[ %{state}.chunk.backedge, %scalar.fission.chunk.latch ]')
            require_chunk_instruction(body, guard,
                                      f'%{state}.chunk.backedge = phi i32 [ %{backedge}, %latch ]')
            start = f'%{state}.chunk.carry'
        require_chunk_instruction(body, 'loop',
                                  f'%{state} = phi i32 [ {start}, %' +
                                  ('scalar.fission.producer.ph' if chunked else ph) +
                                  f' ], [ %{backedge}, %latch ]')

    # Exact original operations and branches, including coupled state control,
    # entry/row guards, conditional loads and simultaneous outer recurrence.
    # Only the IV/state preheader edges, scheduling exits and extracted sums
    # change. Check sequence as well as membership, without FP normalization.
    producer_labels = list(source)[:list(source).index('latch') + 1]
    for label in producer_labels:
        position = -1
        for instruction in chunk_instructions(source[label]):
            if re.match(r'%(iv|prev|older|r0|r1|rd|m0|m1|md|u0|u1|ud) = ', instruction):
                continue
            if label == 'latch' and instruction.startswith('br '):
                if chunked:
                    continue
                instruction = instruction.replace('%' + end, '%' + guard)
            if chunked and label == ph and instruction.startswith('br '):
                instruction = 'br label %scalar.fission.chunk'
            instruction = re.sub(r'\[\s*([^\]]*?)\s*\]', r'[ \1 ]', instruction)
            require_chunk_instruction(body, label, instruction)
            candidates = chunk_instructions(blocks[label])
            # These fixtures have no integer flags except on next/row.next.
            value = instruction.split(' = ')[0]
            found = [i for i, line in enumerate(candidates)
                     if (line.startswith(value + ' = ') if instruction.startswith('%') else line == instruction)]
            assert len(found) == 1 and found[0] > position, (name, label, instruction)
            position = found[0]
    assert not re.search(r'^  %(?:r0|r1|rd|m0|m1|md|u0|u1|ud) = ',
                         body.split('scalar.fission.consumer.guard:')[0], re.M), body
    producer, consumer = scalar_consumer(body, name)
    assert producer.count('call i32 @scalar_helper(') == 1, body
    assert len(re.findall(r'^  store ', producer, re.M)) == 2, producer
    assert blocks['left'].count('store ') == 2, body
    assert producer.count('load double') == blocks['left'].count('load double') == 1, producer
    assert '<vscale x' not in producer, producer
    for t, c in [('i32', 'c'), ('double', 'dc')]:
        slot = re.findall(rf'(%[-\w.$]+) = alloca \[{capacity} x {t}\]', producer)
        assert len(slot) == 1, body
        addresses = re.findall(
            rf'(%[-\w.$]+) = getelementptr inbounds \[{capacity} x {t}\], '
            rf'ptr {re.escape(slot[0])}, i32 0, i64 (%[-\w.$]+)(?:\n|,)', blocks['left'])
        assert len(addresses) == 1, (name, blocks['left'])
        addr, index = addresses[0]
        if narrow:
            require_chunk_instruction(body, 'left',
                                      f'{index} = zext i8 %fission.participating to i64')
        else:
            assert index == '%fission.participating', body
        assert f'store {t} %{c}, ptr {addr},' in blocks['left'], body
    assert body.count('alloca ') == 2, body
    for instruction in chunk_instructions(source[end]):
        match = re.fullmatch(r'(%out\.[-\w.$]+) = phi (i8|i32|i64|double) \[\s*(%[-\w.$]+), %latch\s*\]', instruction)
        if match:
            out, t, value = match.groups()
            if out in ('%out.r0', '%out.r1', '%out.rd'):
                replacement = {'%out.r0': '%r0.result', '%out.r1': '%r1.result', '%out.rd': '%rd.result'}[out]
            else:
                require_chunk_instruction(body, guard, f'{value}.fission.export = phi {t} [ {value}, %latch ]')
                replacement = value + '.fission.export'
            require_chunk_instruction(body, end, f'{out} = phi {t} [ {replacement}, %' +
                                      ('scalar.fission.chunk.latch' if chunked else 'scalar.fission.consumer.exit') + ' ]')
        else:
            require_chunk_instruction(body, end, instruction)
    vectors = [label for label in blocks if label.startswith('vector.body')]
    assert len(vectors) <= 1 and (not scalar or not vectors), body
    if vectors:
        vector = blocks[vectors[0]]
        check_loop_provenance(ir, vector, 'consumer')
        if evl:
            length = re.search(r'(%[-\w.$]+) = call i32 '
                               r'@llvm.experimental.get.vector.length.i64'
                               r'\(i64 %avl, i32 4, i1 true\)', vector)[1]
            step = re.search(r'(%[-\w.$]+) = zext i32 ' + re.escape(length) + ' to i64', vector)[1]
            next_index = re.search(r'(%[-\w.$]+) = add i64 ' + re.escape(step) + ', %index', vector)[1]
        else:
            next_index = '%index.next'
            step = re.search(r'%index.next = add nuw i64 %index, (%[-\w.$]+)', vector)[1]
            modulus_step = re.search(r'%n.mod.vf = urem i64 %[-\w.$]+, (%[-\w.$]+)',
                                     blocks['vector.ph'])[1]
            assert step == modulus_step, (name, vector)
            # Entry check can have a distinct, equivalent VF computation.
            minimum = re.search(r'%min.iters.check = icmp ult i64 %[-\w.$]+, (%[-\w.$]+)',
                                blocks['scalar.fission.consumer.ph'])[1]
            scales = []
            for width in (step, minimum):
                scale = re.search(re.escape(width) + r' = shl nuw i64 (%[-\w.$]+), 2', body)[1]
                assert re.search(re.escape(scale) + r' = call i64 @llvm.vscale.i64\(\)', body)
                scales.append(scale)
            assert len(set(scales)) == 1, body
        require_chunk_instruction(body, 'vector.body',
                                  '%index = phi i64 [ 0, %vector.ph ], '
                                  f'[ {next_index}, %vector.body ]')
        for t, suffix in [('i32', 'i32'), ('double', 'f64')]:
            slot = re.findall(rf'(%[-\w.$]+) = alloca \[{capacity} x {t}\]', producer)[0]
            addresses = re.findall(
                rf'(%[-\w.$]+) = getelementptr inbounds \[{capacity} x {t}\], '
                rf'ptr {re.escape(slot)}, i32 0, i64 %index(?:\n|,)', vector)
            assert len(addresses) == 1, (name, vector)
            if evl:
                pattern = (rf'call <vscale x 4 x {t}> @llvm.vp.load.nxv4{suffix}.p0'
                           rf'\(ptr align \d+ {re.escape(addresses[0])}, '
                           rf'<vscale x 4 x i1> splat \(i1 true\), i32 {re.escape(length)}\)')
            else:
                pattern = rf'load <vscale x 4 x {t}>, ptr {re.escape(addresses[0])},'
            assert len(re.findall(pattern, vector)) == 1, (name, vector)
    # Narrow execution deliberately uses scalar consumers. Its vector codegen
    # remains covered by the lit fixture; i64 fixtures execute vector consumers.
    assert not narrow or scalar, name
    check_compact_count(producer.replace('i8', 'i64') if narrow else producer,
                        consumer.replace('i8', 'i64') if narrow else consumer,
                        'export_compact', evl, starts=starts, vectorized=bool(vectors),
                        bypass_edges=['right', 'right1', 'right2'] if cfg else ['right'],
                        chunked=chunked,
                        producer_preheader='scalar.fission.producer.ph' if chunked else ph)
    if 'scalar.fission.consumer.body' in blocks:
        loads = {}
        consumer_body = blocks['scalar.fission.consumer.body']
        for t in ('i32', 'double'):
            slot = re.findall(rf'(%[-\w.$]+) = alloca \[{capacity} x {t}\]', producer)[0]
            addresses = re.findall(
                rf'(%[-\w.$]+) = getelementptr inbounds \[{capacity} x {t}\], '
                rf'ptr {re.escape(slot)}, i32 0, i64 (%[-\w.$]+)(?:\n|,)', consumer_body)
            assert len(addresses) == 1, consumer_body
            addr, index = addresses[0]
            if narrow:
                require_chunk_instruction(body, 'scalar.fission.consumer.body',
                                          f'{index} = zext i8 %fission.consumer.iv to i64')
            else:
                assert index == '%fission.consumer.iv', body
            load = re.findall(rf'(%[-\w.$]+) = load {t}, ptr {re.escape(addr)},', consumer_body)
            assert len(load) == 1, consumer_body
            loads[t] = load[0]
        for instruction in [f'%u0.consume = add i32 %r0.consume, {loads["i32"]}',
                            f'%u1.consume = add i32 {loads["i32"]}, %r1.consume',
                            f'%ud.consume = fadd double %rd.consume, {loads["double"]}']:
            require_chunk_instruction(body, 'scalar.fission.consumer.body', instruction)
        require_chunk_instruction(body, 'scalar.fission.consumer.loopexit',
                                  'br label %scalar.fission.consumer.exit')
    check_loop_provenance(ir, blocks['latch'], 'producer')
    if not probe:
        return body

    def insert(label, instructions, at_end=False):
        nonlocal body
        code = loop_blocks(body)[label]
        if at_end:
            changed, count = re.subn(r'(?=^  br )', lambda _: instructions, code, flags=re.M)
        else:
            changed, count = re.subn(r'\A((?:\s*%[-\w.$]+ = phi [^\n]*\n)*)',
                                     lambda m: m[0] + instructions, code)
        assert count == 1, (name, label)
        body = body.replace(code, changed, 1)

    begin = 'scalar.fission.chunk' if chunked else ph
    base, count = ('%fission.chunk.base', '%fission.chunk.count') if chunked else ('0', '%n')
    state = ['%prev.chunk.carry', '%older.chunk.carry'] if chunked else state_starts
    accum = [start for _, _, start in starts]
    prefix = ''
    if narrow and chunked:
        prefix = ('  %cc.base = zext i8 %fission.chunk.base to i64\n'
                  '  %cc.count = zext i8 %fission.chunk.count to i64\n')
        base, count = '%cc.base', '%cc.count'
    insert(begin, prefix + f'  call void @record_cc_begin(i64 {base}, i64 {count}, '
           f'i32 {state[0]}, i32 {state[1]}, i32 {accum[0]}, i32 {accum[1]}, double {accum[2]})\n', True)
    local = '%fission.producer.ordinal' if chunked else '%iv'
    prefix = ''
    if narrow:
        prefix = '  %cc.global = zext i8 %iv to i64\n'
        if chunked:
            prefix += '  %cc.local = zext i8 %fission.producer.ordinal to i64\n'
        local = '%cc.local' if chunked else '%cc.global'
    insert('loop', prefix + f'  call void @record_cc_producer(i64 ' +
           ('%cc.global' if narrow else '%iv') + f', i64 {local})\n')
    prefix = '  %cc.p = zext i8 %fission.participating to i64\n' if narrow else ''
    insert('left', prefix + '  call void @record_cc_participant(i64 ' +
           ('%cc.p' if narrow else '%fission.participating') + ')\n', True)
    completed = '%fission.producer.completed' if chunked else '%n'
    p = '%fission.participating.count'
    prefix = ''
    if narrow:
        prefix = '  %cc.total = zext i8 %fission.participating.count to i64\n'
        if chunked:
            prefix += '  %cc.completed = zext i8 %fission.producer.completed to i64\n'
            completed = '%cc.completed'
        p = '%cc.total'
    insert(guard, prefix + f'  call void @record_cc_guard(i64 {completed}, i64 {p}, '
           'i32 %prev.fission.export, i32 %older.fission.export, '
           'i32 %state.next.fission.export, double %last.dc.fission.export)\n')
    insert('scalar.fission.consumer.exit', '  call void @record_cc_end(i32 %r0.result, '
           'i32 %r1.result, double %rd.result)\n')
    for label in vectors:
        insert(label, '  call void @record_cc_vector()\n')
    if 'scalar.fission.consumer.body' in blocks:
        insert('scalar.fission.consumer.body', '  call void @record_cc_tail()\n')
    return body


def compact_chunk_execution_counts(stdout, configurations):
    fields = ('comparisons', 'producer', 'consumer', 'chunks', 'empty', 'vector', 'tail',
              'zero', 'multi', 'partial', 'full', 'state', 'final-inactive', 'empty-then-active')
    completed = {}
    for match in re.finditer(r'^Compact chunks (\S+): ' + ' '.join(
            re.escape(key) + r'=(\d+)' for key in fields) + '$', stdout, re.M):
        name = match[1]
        assert name in configurations and name not in completed, name
        row = dict(zip(fields, map(int, match.groups()[1:])))
        mode, capacity, lanes = configurations[name]
        nested = mode == 3
        row_sum, row_choices, entering_choices = (7, 6, 3) if nested else (2, 2, 2)
        repetitions = 9 * 4 * 2  # patterns, signed-zero/nonidentity starts, aliases
        full = repetitions * row_sum * sum(n // capacity for n in range(1, 66))
        partial = repetitions * row_sum * sum(n % capacity != 0 for n in range(1, 66))
        expected = dict(
            comparisons=68 * row_choices * repetitions,
            producer=repetitions * row_sum * sum(range(1, 66)),
            chunks=full + partial, full=full, partial=partial,
            zero=(68 * row_choices - 65 * entering_choices) * repetitions,
            multi=max(0, 65 - capacity) * entering_choices * repetitions,
            state=65 * repetitions)
        assert all(row[key] == value for key, value in expected.items()), (name, row, expected)
        assert row['producer'] >= row['consumer'] > 0 and row['chunks'] > row['empty'] > 0, (name, row)
        assert row['consumer'] == row['vector'] * lanes + row['tail'], (name, row)
        assert all(row[key] > 0 for key in ('zero', 'state', 'final-inactive', 'full')), (name, row)
        if capacity < 65:
            assert row['multi'] and row['empty-then-active'], (name, row)
        if capacity > 1:
            assert row['partial'] or capacity == 65, (name, row)
        if lanes and lanes <= capacity:
            assert row['vector'] > 0, (name, row)
        else:
            assert row['vector'] == 0, (name, row)
        completed[name] = row
    assert set(completed) == set(configurations), (set(completed), set(configurations))
    return completed


STATE_CHUNK_FUNCTIONS = ('chunk_state_delay', 'chunk_state_pair',
                         'chunk_state_fp', 'chunk_state_nested')

CFG_CHUNK_FUNCTIONS = ('chunk_cfg_diamond', 'chunk_cfg_serial',
                       'chunk_cfg_nested', 'chunk_cfg_header')


def check_state_chunk_remarks(remarks, name, capacity, size, vectorized):
    assert size == ((4 * capacity + 7) // 8) * 8 + 8 * capacity, (capacity, size)
    cfg = name in CFG_CHUNK_FUNCTIONS
    mode = CFG_CHUNK_FUNCTIONS.index(name) if cfg else STATE_CHUNK_FUNCTIONS.index(name)
    pair = cfg or mode in (1, 3)
    file = 'scalar-chunk-cfg.c' if cfg else 'scalar-chunk-state.c'
    loc = f'{file}:{12 + 10 * mode}:3:'
    selection = (rf'{re.escape(loc)} split scalar-IR reduction loop;[^\n]*'
                 rf'scratch capacity {capacity}, scratch bytes {size}, '
                 rf'producer live-outs {8 if pair else 7}, chunked schedule, trip bound 65, '
                 r'scratch store bytes/iteration 12, scratch load bytes/iteration 12, '
                 r'producer reread bytes/iteration 0, duplicated producer instructions 0, '
                 rf'producer state carries {3 if pair else 2}\b')
    assert len(re.findall(selection, remarks)) == 1, (name, remarks)
    # Independently observed roles: the scalar helper keeps the producer scalar.
    for role, vf in [('producer', '1'),
                     ('consumer', 'vscale x 4' if vectorized else '1')]:
        assert f'{loc} scalar-IR fission {role} VF {vf}\n' in remarks, (name, remarks)


def check_state_chunk_consumer(body, capacity, preheader, exit, initial, evl):
    """Certify these fixtures' emitted scalar, scalar-tail and EVL layouts.

    The emitted CFG decides the contract: requesting vectors can still leave
    a wholly scalar consumer (notably C=1). A tail starts at n.vec with resumed
    reductions; a wholly scalar consumer starts at zero with chunk carries.
    This deliberately bounded certificate also follows LV's LCSSA bridges.
    """
    blocks = {label: chunk_instructions(code) for label, code in loop_blocks(body).items()}
    definitions = {}
    for label, code in blocks.items():
        for line in code:
            match = re.fullmatch(r'(%[-\w.$]+) = (.+)', line)
            if match:
                assert match[1] not in definitions, (match[1], body)
                definitions[match[1]] = (label, match[2])
    successors = {label: re.findall(r'\blabel %([-\w.$]+)', code[-1])
                  for label, code in blocks.items()}
    assert all(set(targets) <= blocks.keys() for targets in successors.values()), body
    predecessors = {label: {p for p, targets in successors.items() if label in targets}
                    for label in blocks}

    def phi(value, ty, label):
        assert value in definitions and definitions[value][0] == label, (value, label)
        expression = definitions[value][1]
        inputs = re.findall(r'\[ ([^,\]\n]+), %([-\w.$]+) \]', expression)
        assert expression == f'phi {ty} ' + ', '.join(f'[ {v}, %{p} ]' for v, p in inputs), expression
        assert len(inputs) == len(predecessors[label]), (value, inputs, predecessors[label])
        assert {p for _, p in inputs} == predecessors[label], (value, inputs, predecessors[label])
        return {p: v for v, p in inputs}

    def single(label, pattern):
        found = [m for line in blocks[label] if (m := re.fullmatch(pattern, line))]
        assert len(found) == 1, (label, pattern, body)
        return found[0]

    scalar = 'scalar.fission.consumer.body'
    entry, latch = 'scalar.fission.consumer.ph', 'scalar.fission.chunk.latch'
    vectors = [label for label in blocks if label.startswith('vector.body')]
    assert len(vectors) <= 1, body
    vector = vectors[0] if vectors else None
    scalar_entry = 'scalar.ph' if vector else entry
    scalar_exit = latch
    bridges = set()
    if scalar in blocks:
        # Bind the actual terminating branch, not a dead compare or a prefix.
        scalar_exit = single(scalar, r'br i1 %fission.consumer.more, label %' +
                             re.escape(scalar) + r', label %([-\w.$]+)')[1]
        label = scalar_exit
        while label != latch:
            assert label not in bridges and len(bridges) < 2, (label, body)
            assert predecessors[label] == ({scalar} if not bridges else {previous}), body
            bridges.add(label)
            previous, label = label, single(label, r'br label %([-\w.$]+)')[1]
        require_chunk_instruction(body, scalar,
                                  '%fission.consumer.next = add nuw i64 %fission.consumer.iv, 1')
        require_chunk_instruction(body, scalar,
                                  '%fission.consumer.more = icmp ne i64 %fission.consumer.next, %fission.chunk.count')
        require_chunk_instruction(body, scalar_entry, f'br label %{scalar}')
        assert phi('%fission.consumer.iv', 'i64', scalar) == {
            scalar_entry: '%bc.resume.val' if vector else '0', scalar: '%fission.consumer.next'}
    else:
        assert vector and evl, body

    # A result can traverse only a real, single-predecessor LCSSA bridge, and
    # must arrive from the executed update on that edge. No arithmetic, stale
    # seed, swapped reduction, select or arbitrary name counts as forwarding.
    def forward(value, use, root, origin, ty, depth=0):
        if use == origin:
            assert value == root, (value, root, use)
            return
        assert depth < 4 and use in bridges | {'middle.block'}, (value, use, origin)
        assert len(predecessors[use]) == 1, (use, predecessors[use])
        pred = next(iter(predecessors[use]))
        if value in definitions and definitions[value][0] == use:
            value = phi(value, ty, use)[pred]
        forward(value, pred, root, origin, ty, depth + 1)

    vector_results = {}
    if vector:
        assert predecessors[vector] == {'vector.ph', vector}, body
        if evl:
            assert scalar not in blocks, body
            require_chunk_instruction(body, entry, 'br label %vector.ph')
            assert phi('%avl', 'i64', vector) == {'vector.ph': '%fission.chunk.count', vector: '%avl.next'}
            length = single(vector, r'(%[-\w.$]+) = call i32 @llvm.experimental.get.vector.length.i64'
                            r'\(i64 %avl, i32 4, i1 true\)')[1]
            step = single(vector, r'(%[-\w.$]+) = zext i32 ' + re.escape(length) + ' to i64')[1]
            next_index = '%current.iteration.next'
            require_chunk_instruction(body, vector, f'{next_index} = add nuw i64 {step}, %index')
            require_chunk_instruction(body, vector, f'%avl.next = sub nuw i64 %avl, {step}')
            condition = single(vector, r'(%[-\w.$]+) = icmp eq i64 %avl.next, 0')[1]
            vp_args = f', <vscale x 4 x i1> splat (i1 true), i32 {length}'
        else:
            assert scalar in blocks, body
            minimum = single(entry, r'%min.iters.check = icmp ult i64 %fission.chunk.count, (%[-\w.$]+)')[1]
            require_chunk_instruction(body, entry, 'br i1 %min.iters.check, label %scalar.ph, label %vector.ph')
            step = single('vector.ph', r'%n.mod.vf = urem i64 %fission.chunk.count, (%[-\w.$]+)')[1]
            scales = []
            for width in (minimum, step):
                owner, expression = definitions[width]
                match = re.fullmatch(r'shl nuw i64 (%[-\w.$]+), 2', expression)
                assert match and owner in (entry, 'vector.ph'), (width, expression)
                assert definitions[match[1]] == (entry, 'call i64 @llvm.vscale.i64()'), body
                scales.append(match[1])
            assert scales[0] == scales[1], body
            require_chunk_instruction(body, 'vector.ph', '%n.vec = sub i64 %fission.chunk.count, %n.mod.vf')
            next_index = '%index.next'
            require_chunk_instruction(body, vector, f'{next_index} = add nuw i64 %index, {step}')
            condition = single(vector, r'(%[-\w.$]+) = icmp eq i64 %index.next, %n.vec')[1]
            assert phi('%bc.resume.val', 'i64', 'scalar.ph') == {
                'middle.block': '%n.vec', entry: '0'}
            require_chunk_instruction(body, 'middle.block', '%cmp.n = icmp eq i64 %fission.chunk.count, %n.vec')
            require_chunk_instruction(body, 'middle.block', f'br i1 %cmp.n, label %{latch}, label %scalar.ph')
            vp_args = ''
        assert phi('%index', 'i64', vector) == {'vector.ph': '0', vector: next_index}
        require_chunk_instruction(body, 'vector.ph', f'br label %{vector}')
        require_chunk_instruction(body, vector, f'br i1 {condition}, label %middle.block, label %{vector}')
        if evl:
            require_chunk_instruction(body, 'middle.block', f'br label %{latch}')
        loads = {}
        for ty, suffix, alignment in [('i32', 'i32', 4), ('double', 'f64', 8)]:
            slot = single('entry', rf'(%[-\w.$]+) = alloca \[{capacity} x {ty}\], align {alignment}')[1]
            address = single(vector, rf'(%[-\w.$]+) = getelementptr inbounds \[{capacity} x {ty}\], '
                             rf'ptr {re.escape(slot)}, i32 0, i64 %index')[1]
            load = (rf'call <vscale x 4 x {ty}> @llvm.vp.load.nxv4{suffix}.p0'
                    rf'\(ptr align {alignment} {re.escape(address)}{re.escape(vp_args)}\)' if evl else
                    rf'load <vscale x 4 x {ty}>, ptr {re.escape(address)}, align {alignment}')
            loads[ty] = single(vector, rf'(%[-\w.$]+) = {load}')[1]
        for r, ty in [('r0', 'i32'), ('r1', 'i32'), ('rd', 'double')]:
            carry = f'%{r}.chunk.carry'
            if ty == 'i32':
                seed = single('vector.ph', r'(%[-\w.$]+) = insertelement <vscale x 4 x i32> zeroinitializer, '
                              rf'i32 {re.escape(carry)}, i32 0')[1]
                vector_ty = '<vscale x 4 x i32>'
            else:
                seed, vector_ty = carry, 'double'
            accumulators = [value for value, (owner, expression) in definitions.items()
                            if owner == vector and expression.startswith(f'phi {vector_ty} ')
                            and phi(value, vector_ty, vector).get('vector.ph') == seed]
            assert len(accumulators) == 1, (r, accumulators)
            acc = accumulators[0]
            update = phi(acc, vector_ty, vector)[vector]
            if ty == 'i32':
                arithmetic = (f'add {vector_ty} {acc}, {loads[ty]}' if r == 'r0' else
                              f'add {vector_ty} {loads[ty]}, {acc}')
                if evl:
                    raw = single(vector, rf'(%[-\w.$]+) = {re.escape(arithmetic)}')[1]
                    require_chunk_instruction(body, vector, f'{update} = call {vector_ty} @llvm.vp.merge.nxv4i32('
                                              f'<vscale x 4 x i1> splat (i1 true), {vector_ty} {raw}, '
                                              f'{vector_ty} {acc}, i32 {length})')
                else:
                    require_chunk_instruction(body, vector, f'{update} = {arithmetic}')
                reductions = []
                for line in blocks['middle.block']:
                    match = re.fullmatch(r'(%[-\w.$]+) = call i32 @llvm.vector.reduce.add.nxv4i32'
                                         r'\(<vscale x 4 x i32> (%[-\w.$]+)\)', line)
                    if match:
                        reductions.append(match.groups())
                assert len(reductions) == 2, reductions
                # Match each finalizer by its real update, not its numeric name.
                result, operand = reductions[0 if r == 'r0' else 1]
                forward(operand, 'middle.block', update, vector, vector_ty)
                vector_results[r] = (result, 'middle.block')
            else:
                reduction = 'vp.reduce' if evl else 'vector.reduce'
                require_chunk_instruction(body, vector,
                                          f'{update} = call double @llvm.{reduction}.fadd.nxv4f64('
                                          f'double {acc}, <vscale x 4 x double> {loads[ty]}{vp_args})')
                vector_results[r] = (update, vector)

    loads = {}
    if scalar in blocks:
        for ty, alignment in [('i32', 4), ('double', 8)]:
            slot = single('entry', rf'(%[-\w.$]+) = alloca \[{capacity} x {ty}\], align {alignment}')[1]
            address = single(scalar, rf'(%[-\w.$]+) = getelementptr inbounds \[{capacity} x {ty}\], '
                             rf'ptr {re.escape(slot)}, i32 0, i64 %fission.consumer.iv')[1]
            loads[ty] = single(scalar, rf'(%[-\w.$]+) = load {ty}, ptr {re.escape(address)}, align {alignment}')[1]
        assert sum(' = load ' in line for line in blocks[scalar]) == 2, body
        for instruction in [f'%u0.consume = add i32 %r0.consume, {loads["i32"]}',
                            f'%u1.consume = add i32 {loads["i32"]}, %r1.consume',
                            f'%ud.consume = fadd double %rd.consume, {loads["double"]}']:
            require_chunk_instruction(body, scalar, instruction)
    for r, u, ty, start in zip(('r0', 'r1', 'rd'), ('u0', 'u1', 'ud'),
                               ('i32', 'i32', 'double'), initial):
        carries = phi(f'%{r}.chunk.carry', ty, 'scalar.fission.chunk')
        assert carries[preheader] == start, (r, carries)
        result = carries[latch]
        if scalar in blocks:
            incoming = phi(f'%{r}.consume', ty, scalar)
            assert incoming[scalar] == f'%{u}.consume', incoming
            seed = incoming[scalar_entry]
            if vector:
                resumed = phi(seed, ty, scalar_entry)
                assert resumed[entry] == f'%{r}.chunk.carry', resumed
                forward(resumed['middle.block'], 'middle.block', *vector_results[r], ty)
            else:
                assert seed == f'%{r}.chunk.carry', seed
        if not vector:
            assert phi(result, ty, latch) == {scalar: f'%{u}.consume'}, body
        elif evl:
            assert predecessors[latch] == {'middle.block'}, body
            forward(result, 'middle.block', *vector_results[r], ty)
        else:
            incoming = phi(result, ty, latch)
            forward(incoming['middle.block'], 'middle.block', *vector_results[r], ty)
            tail = previous if bridges else scalar
            assert set(incoming) == {'middle.block', tail}, incoming
            forward(incoming[tail], tail, f'%{u}.consume', scalar, ty)
        assert phi(f'%out.{r}', ty, exit) == {latch: result}, body


NC_CHUNK_FUNCTIONS = ('nc_offset', 'nc_stride', 'nc_down', 'nc_early',
                      'nc_current', 'nc_compact', 'nc_narrow')


def check_original_chunk_control(ir, original, name, capacity):
    """Exact small fallback certificate; no endpoint/count substitution.

    Also used for the historical offset/swapped admission probes. The original
    branch determines polarity. Check real PHIs/terminators, including the
    continuation used AFTER consumption, rather than incidental comparison text.
    """
    body = function_definition(ir, name)
    before = loop_blocks(function_definition(original, name))
    blocks = loop_blocks(body)
    latch = 'latch' if 'latch' in before else 'loop'
    old = chunk_instructions(before[latch])
    branch = re.fullmatch(r'br i1 (%[-\w.$]+), label %([-\w.$]+), label %([-\w.$]+)', old[-1])
    assert branch and 'loop' in branch.groups()[1:], old
    true_continues = branch[2] == 'loop'
    end = branch[3] if true_continues else branch[2]
    iv = re.search(r'%iv = phi (i\d+) \[\s*([^,]+), %preheader\s*\]', before['loop'])
    assert iv, before['loop']
    ty, start = iv.groups()
    ph = 'scalar.fission.consumer.guard' if 'scalar.fission.consumer.guard' in blocks else 'scalar.fission.consumer.ph'
    require = lambda label, inst: require_chunk_instruction(body, label, inst)
    require('preheader', 'br label %scalar.fission.chunk')
    require('scalar.fission.producer.ph', 'br label %loop')
    require('scalar.fission.chunk', f'%fission.chunk.base = phi {ty} [ {start.strip()}, %preheader ], '
            '[ %fission.producer.iv.next, %scalar.fission.chunk.latch ]')
    require('loop', f'%iv = phi {ty} [ %fission.chunk.base, %scalar.fission.producer.ph ], [ %next, %{latch} ]')
    require('loop', f'%fission.producer.ordinal = phi {ty} [ 0, %scalar.fission.producer.ph ], '
            f'[ %fission.producer.next, %{latch} ]')
    for stem, t, operand in [('iv.next', ty, '%next'), ('completed', ty, '%fission.producer.next'),
                             ('continue', 'i1', branch[1] if true_continues else '%fission.original.continue')]:
        require(ph, f'%fission.producer.{stem} = phi {t} [ {operand}, %{latch} ]')
    if not true_continues:
        require(latch, f'%fission.original.continue = xor i1 {branch[1]}, true')
    cont = branch[1] if true_continues else '%fission.original.continue'
    require(latch, f'%fission.producer.next = add nuw {ty} %fission.producer.ordinal, 1')
    require(latch, f'%fission.producer.more = icmp ne {ty} %fission.producer.next, {capacity}')
    require(latch, f'%fission.producer.continuing = and i1 {cont}, %fission.producer.more')
    if true_continues:
        require(latch, f'br i1 %fission.producer.continuing, label %loop, label %{ph}')
    else:
        require(latch, '%fission.producer.done = xor i1 %fission.producer.continuing, true')
        require(latch, f'br i1 %fission.producer.done, label %{ph}, label %loop')
    require('scalar.fission.chunk.latch', 'br i1 %fission.producer.continue, '
            f'label %scalar.fission.chunk, label %{end}')
    assert not re.search(r'%fission.chunk.(?:remaining|partial|count|next|more)\b', body), body
    # Every count/IV/decision export has exactly the real predecessor set.
    for label in ('scalar.fission.chunk', 'loop', ph):
        preds = {p for p, code in blocks.items() if label in re.findall(
            r'\blabel %([-\w.$]+)', chunk_instructions(code)[-1])}
        for line in chunk_instructions(blocks[label]):
            if ' = phi ' in line:
                edges = re.findall(r', %([-\w.$]+) \]', line)
                assert len(edges) == len(preds) and set(edges) == preds, (line, preds)
    # The defining original comparison and IV operation are still exact.
    for line in old:
        if line.startswith(('%next = ', branch[1] + ' = ')):
            require(latch, line)
    return body


def check_noncanonical_chunk(ir, original, name, capacity, evl=False, probe=False):
    body = check_original_chunk_control(ir, original, name, capacity)
    blocks, source = loop_blocks(body), loop_blocks(function_definition(original, name))
    compact, narrow = name == 'nc_compact', name == 'nc_narrow'
    ty = 'i8' if narrow else 'i64'
    ph = 'scalar.fission.consumer.guard' if compact else 'scalar.fission.consumer.ph'
    require = lambda label, inst: require_chunk_instruction(body, label, inst)
    for state, t, seed, back in [('prev', 'i32', '23', 'state.next'),
                                ('older', 'i32', '-11', 'prev'),
                                ('dstate', 'double', '%start', 'dnext')]:
        require('scalar.fission.chunk', f'%{state}.chunk.carry = phi {t} [ {seed}, %preheader ], '
                f'[ %{state}.chunk.backedge, %scalar.fission.chunk.latch ]')
        require('loop', f'%{state} = phi {t} [ %{state}.chunk.carry, %scalar.fission.producer.ph ], '
                f'[ %{back}, %latch ]')
        require(ph, f'%{state}.chunk.backedge = phi {t} [ %{back}, %latch ]')
    # Every retained instruction stays in its original block and sequence.
    # This includes entry/bypass guards, participation, memory and FP flags.
    for label in ('entry', 'preheader', 'loop', 'left', 'latch', 'bypass'):
        if label not in source:
            continue
        position = -1
        actual = chunk_instructions(blocks[label])
        for line in chunk_instructions(source[label]):
            if re.match(r'%(iv|prev|older|dstate|r0|r1|rd|u0(?:\.merge)?|u1(?:\.merge)?|ud(?:\.merge)?) = ', line):
                continue
            if label in ('preheader', 'latch') and line.startswith('br '):
                continue
            require(label, line)
            indices = [i for i, value in enumerate(actual) if value == line]
            assert len(indices) == 1 and indices[0] > position, (name, line, actual)
            position = indices[0]
    assert body.count('alloca ') == 2 and body.count('call i32 @scalar_helper(') == 1, body
    store_block = 'left' if compact else 'latch'
    index = '%fission.participating' if compact else '%fission.producer.ordinal'
    addresses = {}
    for t, value in [('i32', 'c'), ('double', 'dc')]:
        slot = re.findall(rf'(%[-\w.$]+) = alloca \[{capacity} x {t}\]', body)
        assert len(slot) == 1, body
        found = re.findall(rf'(%[-\w.$]+) = getelementptr inbounds \[{capacity} x {t}\], '
                           rf'ptr {re.escape(slot[0])}, i32 0, i64 (%[-\w.$]+)', blocks[store_block])
        assert len(found) == 1, body
        address, offset = found[0]
        if narrow:
            require(store_block, f'{offset} = zext i8 {index} to i64')
        else:
            assert offset == index, (name, offset, index)
        require(store_block, f'store {t} %{value}, ptr {address}, align ' + ('4' if t == 'i32' else '8'))
        addresses[t] = address
    for line in chunk_instructions(source['producer.exit']):
        m = re.fullmatch(r'(%out\.[-\w.$]+) = phi (i8|i32|i64|double) \[\s*(%[-\w.$]+), %latch\s*\]', line)
        if not m:
            require('producer.exit', line)
        elif m[1] not in ('%out.r0', '%out.r1', '%out.rd'):
            out, t, value = m.groups()
            require(ph, f'{value}.fission.export = phi {t} [ {value}, %latch ]')
            require('producer.exit', f'{out} = phi {t} [ {value}.fission.export, %scalar.fission.chunk.latch ]')
    vectors = [label for label in blocks if label.startswith('vector.body')]
    assert len(vectors) <= 1 and not (narrow and vectors), body
    if compact:
        producer, consumer = scalar_consumer(body, name)
        check_compact_count(producer, consumer, 'export_compact', evl,
                            starts=[(r, t, f'%{r}.chunk.carry') for r, t in
                                    [('r0', 'i32'), ('r1', 'i32'), ('rd', 'double')]],
                            vectorized=bool(vectors), bypass_edges=['loop'], chunked=True, freeze_count=True)
        for r, t, seed in [('r0', 'i32', '17'), ('r1', 'i32', '-7'), ('rd', 'double', '%start')]:
            require('scalar.fission.chunk', f'%{r}.chunk.carry = phi {t} [ {seed}, %preheader ], '
                    f'[ %{r}.result, %scalar.fission.chunk.latch ]')
            require('producer.exit', f'%out.{r} = phi {t} [ %{r}.result, %scalar.fission.chunk.latch ]')
    elif not narrow:
        # Pure alpha-renaming: the fallback has no chunk.count definition or
        # uses (certified above). Reuse the full scalar/tail/EVL result proof,
        # with the actual completed-count SSA value as its only bound.
        require(ph, '%fission.consumer.count = freeze i64 %fission.producer.completed')
        check_state_chunk_consumer(body.replace('%fission.consumer.count', '%fission.chunk.count'),
                                   capacity, 'preheader', 'producer.exit', ['17', '-7', '%start'], evl)
    else:
        for inst in ['%fission.consumer.iv = phi i8 [ 0, %scalar.fission.consumer.ph ], '
                     '[ %fission.consumer.next, %scalar.fission.consumer.body ]',
                     '%fission.consumer.next = add nuw i8 %fission.consumer.iv, 1',
                     '%fission.consumer.more = icmp ne i8 %fission.consumer.next, %fission.consumer.count',
                     'br i1 %fission.consumer.more, label %scalar.fission.consumer.body, label %scalar.fission.chunk.latch']:
            require('scalar.fission.consumer.body', inst)
        require(ph, '%fission.consumer.count = freeze i8 %fission.producer.completed')
        loaded = {}
        for t, alignment in [('i32', 4), ('double', 8)]:
            slot = re.findall(rf'(%[-\w.$]+) = alloca \[{capacity} x {t}\]', body)[0]
            found = re.findall(rf'(%[-\w.$]+) = getelementptr inbounds \[{capacity} x {t}\], '
                               rf'ptr {re.escape(slot)}, i32 0, i64 (%[-\w.$]+)', blocks['scalar.fission.consumer.body'])
            assert len(found) == 1, body
            address, offset = found[0]
            require('scalar.fission.consumer.body', f'{offset} = zext i8 %fission.consumer.iv to i64')
            loads = re.findall(rf'(%[-\w.$]+) = load {t}, ptr {re.escape(address)}, align {alignment}',
                               blocks['scalar.fission.consumer.body'])
            assert len(loads) == 1, body
            loaded[t] = loads[0]
        for r, u, t, seed, operation in [('r0', 'u0', 'i32', '17', f'add i32 %r0.consume, {loaded["i32"]}'),
                                        ('r1', 'u1', 'i32', '-7', f'add i32 {loaded["i32"]}, %r1.consume'),
                                        ('rd', 'ud', 'double', '%start', f'fadd double %rd.consume, {loaded["double"]}')]:
            require('scalar.fission.chunk', f'%{r}.chunk.carry = phi {t} [ {seed}, %preheader ], '
                    f'[ %{r}.chunk.result, %scalar.fission.chunk.latch ]')
            require('scalar.fission.consumer.body', f'%{r}.consume = phi {t} [ %{r}.chunk.carry, %scalar.fission.consumer.ph ], '
                    f'[ %{u}.consume, %scalar.fission.consumer.body ]')
            require('scalar.fission.consumer.body', f'%{u}.consume = {operation}')
            require('scalar.fission.chunk.latch', f'%{r}.chunk.result = phi {t} [ %{u}.consume, %scalar.fission.consumer.body ]')
            require('producer.exit', f'%out.{r} = phi {t} [ %{r}.chunk.result, %scalar.fission.chunk.latch ]')
    check_loop_provenance(ir, blocks['latch'], 'producer')
    check_loop_provenance(ir, blocks['scalar.fission.chunk.latch'], 'stage')
    for label in vectors + (['scalar.fission.consumer.body'] if 'scalar.fission.consumer.body' in blocks else []):
        check_loop_provenance(ir, blocks[label], 'consumer')
    if not probe:
        return body
    assert not evl

    def insert(label, code):
        nonlocal body
        block = loop_blocks(body)[label]
        changed, count = re.subn(r'(?=^  (?:br |ret ))', lambda _: code, block, flags=re.M)
        assert count == 1, (label, block)
        body = body.replace(block, changed, 1)

    def wide(value, stem, value_ty=ty):
        return ('', value) if value_ty == 'i64' else (f'  %{stem} = zext {value_ty} {value} to i64\n', '%' + stem)

    code, base = wide('%fission.chunk.base', 'nc.base')
    insert('scalar.fission.chunk', code + f'  call void @record_nc_begin(i64 {base}, '
           'i32 %prev.chunk.carry, i32 %older.chunk.carry, double %dstate.chunk.carry)\n')
    code = ''
    args = []
    for value, stem in [('%iv', 'iv'), ('%next', 'next'), ('%fission.producer.ordinal', 'local')]:
        prefix, operand = wide(value, 'nc.' + stem)
        code += prefix
        args.append(operand)
    original_branch = chunk_instructions(source['latch'])[-1]
    cont = '%done' if 'label %loop, label %producer.exit' in original_branch else '%fission.original.continue'
    code += f'  %nc.cont = zext i1 {cont} to i32\n'
    insert('latch', code + f'  call void @record_nc_iteration(i64 %index, i64 {args[0]}, i64 {args[1]}, '
           f'i64 {args[2]}, i32 %nc.cont, i32 %prev, i32 %older, i32 %state.next, '
           'double %dstate, double %dnext)\n')
    prefix, local = wide(index, 'nc.store.index')
    insert(store_block, prefix + f'  call void @record_nc_store(i64 %index, i64 {local}, i32 %c, double %dc, '
           f'ptr {addresses["i32"]}, ptr {addresses["double"]})\n')
    prefix, completed = wide('%fission.producer.completed', 'nc.completed')
    code, next_iv = wide('%fission.producer.iv.next', 'nc.carried.iv')
    insert('scalar.fission.chunk.latch', prefix + code + '  %nc.carried.cont = zext i1 %fission.producer.continue to i32\n'
           f'  call void @record_nc_end(i64 {completed}, i32 %nc.carried.cont, i64 {next_iv})\n')
    for label in vectors + (['scalar.fission.consumer.body'] if 'scalar.fission.consumer.body' in blocks else []):
        vector = label in vectors
        prefix, ordinal = wide('%index' if vector else '%fission.consumer.iv', 'nc.consume.index',
                               'i64' if vector else ty)
        lanes = '1'
        if vector:
            prefix += '  %nc.scale = call i64 @llvm.vscale.i64()\n  %nc.lanes = mul i64 %nc.scale, 4\n'
            lanes = '%nc.lanes'
        consumer_addresses = {}
        for t in ('i32', 'double'):
            slot = re.findall(rf'(%[-\w.$]+) = alloca \[{capacity} x {t}\]', body)[0]
            found = re.findall(rf'(%[-\w.$]+) = getelementptr inbounds \[{capacity} x {t}\], '
                               rf'ptr {re.escape(slot)}, i32 0, i64 (%[-\w.$]+)', blocks[label])
            assert len(found) == 1, (name, label)
            addr, offset = found[0]
            if narrow:
                require(label, f'{offset} = zext i8 %fission.consumer.iv to i64')
            else:
                assert offset == ('%index' if vector else '%fission.consumer.iv'), body
            consumer_addresses[t] = addr
        insert(label, prefix + f'  call void @record_nc_consume(i64 {ordinal}, i64 {lanes}, '
               f'ptr {consumer_addresses["i32"]}, ptr {consumer_addresses["double"]}, i32 {int(vector)})\n')
    return body


def check_state_chunk(ir, original, name, capacity, scalar=False, evl=False, probe=False):
    """Fixture-scoped exact state/edge certificate, independent of C formulas.

    Retained operations must be the original instruction sequence. Every carry
    forwards the original backedge (including prev -> older simultaneously);
    original current/next exports remain separate. Scalar results are also
    certified before LV changes consumer exits. Execution covers actual LV code.
    """
    body = function_definition(ir, name)
    blocks = loop_blocks(body)
    source = loop_blocks(function_definition(original, name))
    cfg = name in CFG_CHUNK_FUNCTIONS
    mode = CFG_CHUNK_FUNCTIONS.index(name) if cfg else STATE_CHUNK_FUNCTIONS.index(name)
    pair, nested = cfg or mode in (1, 3), not cfg and mode == 3
    latch = 'latch' if cfg else 'loop'
    ph, exit = ('inner.ph', 'row.exit') if nested else ('preheader', 'producer.exit')
    check_chunk_controller(body, capacity, preheader=ph, exit=exit)
    starts = (['%seed', '%oldseed', '%dseed'] if nested else
              ['23', '-11', '%start'])
    states = [('prev', 'i32', starts[0], 'state.next' if pair else 'x')]
    if pair:
        states += [('older', 'i32', starts[1], 'prev')]
    states += [('dstate', 'double', starts[2], 'dnext')]
    for state, ty, start, backedge in states:
        for label, instruction in [
                ('scalar.fission.chunk',
                 f'%{state}.chunk.carry = phi {ty} [ {start}, %{ph} ], '
                 f'[ %{state}.chunk.backedge, %scalar.fission.chunk.latch ]'),
                ('loop', f'%{state} = phi {ty} [ %{state}.chunk.carry, '
                 f'%scalar.fission.producer.ph ], [ %{backedge}, %{latch} ]'),
                ('scalar.fission.consumer.ph',
                 f'%{state}.chunk.backedge = phi {ty} [ %{backedge}, %{latch} ]')]:
            require_chunk_instruction(body, label, instruction)

    # Keep original arithmetic/flags/operand order, loads and calls. Check
    # sequence, not just membership, and do not normalize FP flags.
    producer_labels = (['loop', 'left', 'positive', 'negative', 'right', 'latch']
                       if cfg and mode == 2 else
                       ['loop', 'left', 'right', 'first.merge', 'positive', 'negative', 'latch']
                       if cfg and mode == 1 else
                       ['loop', 'left', 'right', 'latch'] if cfg else ['loop'])
    for label in producer_labels:
        retained = []
        for instruction in chunk_instructions(source[label]):
            if (re.match(r'%(iv|prev|older|dstate|r0|r1|rd) = phi ', instruction) or
                    re.match(r'%(u0|u1|ud|done) = ', instruction) or
                    (label == latch and instruction.startswith('br '))):
                continue
            instruction = re.sub(r'\[\s*([^\]]*?)\s*\]', r'[ \1 ]', instruction)
            require_chunk_instruction(body, label, instruction)
            retained.append(instruction)
        actual = chunk_instructions(blocks[label])
        positions = [actual.index(instruction) if instruction in actual else
                     next(i for i, line in enumerate(actual)
                          if line.startswith(instruction.split(' = ')[0] + ' = '))
                     for instruction in retained]
        assert positions == sorted(positions), (name, label, positions)
        assert '<vscale x' not in blocks[label], (name, label)
    for instruction in [
            f'%iv = phi i64 [ %fission.chunk.base, %scalar.fission.producer.ph ], [ %next, %{latch} ]',
            '%fission.producer.ordinal = phi i64 [ 0, %scalar.fission.producer.ph ], '
            f'[ %fission.producer.next, %{latch} ]']:
        require_chunk_instruction(body, 'loop', instruction)
    for instruction in [
            '%fission.producer.next = add nuw i64 %fission.producer.ordinal, 1',
            '%fission.producer.more = icmp ne i64 %fission.producer.next, %fission.chunk.count',
            'br i1 %fission.producer.more, label %loop, label %scalar.fission.consumer.ph']:
        require_chunk_instruction(body, latch, instruction)
    assert body.count('alloca ') == 2, body
    assert body.count('call i32 @scalar_helper(') == 1, body
    producer = ''.join(blocks[label] for label in producer_labels)
    assert producer.count('load ') == 2 and producer.count('store ') == 2, body
    assert blocks[latch].count('store ') == 2 and 'freeze ' not in body, body
    for ty, value in [('i32', 'c'), ('double', 'dc')]:
        slot = re.findall(rf'(%[-\w.$]+) = alloca \[{capacity} x {ty}\]', body)
        assert len(slot) == 1, body
        addresses = re.findall(
            rf'(%[-\w.$]+) = getelementptr inbounds \[{capacity} x {ty}\], '
            rf'ptr {re.escape(slot[0])}, i32 0, i64 %fission.producer.ordinal',
            blocks[latch])
        assert len(addresses) == 1, body
        assert f'store {ty} %{value}, ptr {addresses[0]},' in blocks[latch], body

    # Derive final export edges from exact original IR, never a last-value
    # surrogate. Same-type swaps and current/next conflation must fail.
    for instruction in chunk_instructions(source[exit]):
        match = re.fullmatch(r'(%out\.[-\w.$]+) = phi (i32|i64|double) '
                             rf'\[\s*(%[-\w.$]+), %{latch}\s*\]', instruction)
        if not match:
            require_chunk_instruction(body, exit, instruction)
            continue
        if match[1] in ('%out.r0', '%out.r1', '%out.rd'):
            continue
        out, ty, value = match.groups()
        require_chunk_instruction(body, 'scalar.fission.consumer.ph',
                                  f'{value}.fission.export = phi {ty} [ {value}, %{latch} ]')
        require_chunk_instruction(body, exit, f'{out} = phi {ty} '
                                  f'[ {value}.fission.export, %scalar.fission.chunk.latch ]')
    # The enclosing recurrence consumes next prev, previous prev, next FP and
    # final reductions through original row-exit LCSSA. No consumer state seed.
    if nested:
        for instruction in chunk_instructions(source['outer']):
            instruction = re.sub(r'\[\s*([^\]]*?)\s*\]', r'[ \1 ]', instruction)
            require_chunk_instruction(body, 'outer', instruction)
    check_loop_provenance(ir, blocks[latch], 'producer')
    check_loop_provenance(ir, blocks['scalar.fission.chunk.latch'], 'stage')
    vectors = [label for label in blocks if label.startswith('vector.body')]
    assert len(vectors) <= 1 and (not scalar or not vectors), body
    initial = ['%carry0', '%carry1', '%carryd'] if nested else ['17', '-7', '%start']
    check_state_chunk_consumer(body, capacity, ph, exit, initial, evl)
    if vectors:
        vector = blocks[vectors[0]]
        check_loop_provenance(ir, vector, 'consumer')
        assert ('@llvm.vp.reduce.fadd.nxv4f64' if evl else
                '@llvm.vector.reduce.fadd.nxv4f64') in vector, vector
        assert '@llvm.vector.reduce.add.nxv4i32' in body, body
        if not evl:
            assert vector.count('load <vscale x 4 x i32>') == 1, vector
            assert vector.count('load <vscale x 4 x double>') == 1, vector
    if 'scalar.fission.consumer.body' in blocks:
        check_loop_provenance(ir, blocks['scalar.fission.consumer.body'], 'consumer')
    if not probe:
        return body

    def insert(label, instructions, at_end=False):
        nonlocal body
        code = loop_blocks(body)[label]
        if at_end:
            changed, count = re.subn(r'(?=^  br )', lambda _: instructions, code, flags=re.M)
        else:
            changed, count = re.subn(
                r'\A((?:\s*%[-\w.$]+ = phi [^\n]*\n)*)',
                lambda m: m[0] + instructions, code)
        assert count == 1, (name, label, code)
        body = body.replace(code, changed, 1)

    oldcarry = '%older.chunk.carry' if pair else '-11'
    insert('scalar.fission.chunk',
           '  call void @record_state_chunk_begin(i64 %fission.chunk.base, '
           'i64 %fission.chunk.count, i32 %prev.chunk.carry, '
           f'i32 {oldcarry}, double %dstate.chunk.carry)\n', True)
    insert('loop', '  call void @record_state_chunk_producer(i64 %iv, '
                   'i64 %fission.producer.ordinal)\n')
    if cfg:
        for edge, label in enumerate(('left', 'right', 'positive', 'negative')):
            if label in blocks:
                insert(label, f'  call void @record_state_chunk_cfg_branch(i32 {edge})\n')
        addresses = {}
        for ty in ('i32', 'double'):
            slot = re.findall(rf'(%[-\w.$]+) = alloca \[{capacity} x {ty}\]', body)[0]
            addresses[ty] = re.findall(
                rf'(%[-\w.$]+) = getelementptr inbounds \[{capacity} x {ty}\], '
                rf'ptr {re.escape(slot)}, i32 0, i64 %fission.producer.ordinal',
                loop_blocks(body)[latch])[0]
        insert(latch, '  call void @record_state_chunk_cfg_store(i64 %iv, '
               'i64 %fission.producer.ordinal, i32 %c, double %dc, '
               f'ptr {addresses["i32"]}, ptr {addresses["double"]})\n', True)
    oldexport = '%older.fission.export' if pair else '-11'
    nextexport = '%state.next.fission.export' if pair else '%x.fission.export'
    insert('scalar.fission.chunk.latch',
           '  call void @record_state_chunk_end(i32 %prev.fission.export, '
           f'i32 {oldexport}, i32 {nextexport}, double %dstate.fission.export, '
           'double %dnext.fission.export)\n')
    for label in vectors:
        insert(label, '  call void @record_chunk_vector()\n')
    if 'scalar.fission.consumer.body' in blocks:
        insert('scalar.fission.consumer.body', '  call void @record_chunk_tail()\n')
    return body



def state_chunk_execution_counts(stdout, configurations):
    """Completed stdout only; planned rows are not execution evidence."""
    completed = {}
    pattern = (r'^State chunks (\S+): comparisons=(\d+) producer=(\d+) consumer=(\d+) '
               r'chunks=(\d+) vector=(\d+) tail=(\d+) complete=(\d+) partial=(\d+) '
               r'zero=(\d+) multi=(\d+)$')
    fields = ('comparisons', 'producer', 'consumer', 'chunks', 'vector', 'tail',
              'complete', 'partial', 'zero', 'multi')
    for match in re.finditer(pattern, stdout, re.M):
        name = match[1]
        assert name in configurations and name not in completed, name
        mode, capacity, lanes = configurations[name]
        nested = mode == 3
        row_sum, active_rows = (7, 3) if nested else (1, 1)
        iterations = 16 * row_sum * sum(range(1, 66))
        full = 16 * row_sum * sum(n // capacity for n in range(1, 66))
        partial = 16 * row_sum * sum(n % capacity != 0 for n in range(1, 66))
        vectors = 16 * row_sum * sum(
            (n // capacity) * (capacity // lanes) + (n % capacity) // lanes
            for n in range(1, 66)) if lanes else 0
        comparisons = 68 * 16 * (6 if nested else 1)
        expected = dict(comparisons=comparisons, producer=iterations, consumer=iterations,
                        chunks=full + partial, vector=vectors, tail=iterations - vectors * lanes,
                        complete=full, partial=partial, zero=comparisons - 65 * 16 * active_rows,
                        multi=(65 - capacity) * 16 * active_rows)
        observed = dict(zip(fields, map(int, match.groups()[1:])))
        assert observed == expected, (name, observed, expected)
        completed[name] = observed
    assert set(completed) == set(configurations), (set(completed), set(configurations))
    return completed


def integration_execution_counts(stdout, configurations):
    """Require completed per-configuration comparisons, not generated rows."""
    completed = {}
    fields = ('comparisons', 'vector', 'tail', 'bypass', 'multi', 'full', 'partial')
    pattern = (r'^Integration (\S+): comparisons=(\d+) vector=(\d+) tail=(\d+) '
               r'bypass=(\d+) multi=(\d+) full=(\d+) partial=(\d+)$')
    counts = list(range(67)) + [127, 128, 129, 254, 255, 256, 257, 2**64 - 1]
    for match in re.finditer(pattern, stdout, re.M):
        name = match[1]
        assert name in configurations and name not in completed, name
        mode, capacity, lanes = configurations[name]
        entered = [n for n in counts if 0 < n <= (255 if mode == 2 else 65)]
        vectors = sum((n // capacity) * (capacity // lanes) + (n % capacity) // lanes
                      if capacity else n // lanes for n in entered)
        expected = dict(comparisons=1200, vector=16 * vectors,
                        tail=16 * (sum(entered) - lanes * vectors),
                        bypass=16 * (len(counts) - len(entered)),
                        multi=16 * sum(n > capacity for n in entered) if capacity else 0,
                        full=16 * sum(n // capacity for n in entered) if capacity else 0,
                        partial=16 * sum(n % capacity != 0 for n in entered) if capacity else 0)
        observed = dict(zip(fields, map(int, match.groups()[1:])))
        assert observed == expected, (name, observed, expected)
        completed[name] = observed
    assert set(completed) == set(configurations), (set(completed), set(configurations))
    return completed


def check_integration(ir, original, name, evl, probe=False, capacity=65):
    """Check the small mixed integration module before adding path probes."""
    body = function_definition(ir, name)
    producer, consumer = scalar_consumer(body, name)
    blocks = loop_blocks(body)
    chunked = name == 'integration_chunk' or (name == 'integration_cross_edge' and capacity < 65)
    affine = name == 'integration_affine'
    assert body.count(f'alloca [{capacity} x i32]') == 1, body
    assert producer.count('call i32 @scalar_helper(i32 %arg)') == 1, producer
    assert '<vscale x' not in producer, producer
    assert '@scalar_helper' not in consumer, consumer
    assert not re.search(r'\bptr %(?:a|p)\b', consumer), consumer
    assert 'scalar.fission.chunk:' in body if chunked else 'scalar.fission.chunk:' not in body
    assert re.search(r'call i32 @llvm.vector.reduce.add.nxv4i32\(', consumer), consumer
    # Preserve every original non-reduction operation, including the original
    # affine compare and the acyclic cross edge. Only the canonical chunk
    # schedule replaces the producer's exiting branch.
    source = function_definition(original, name)
    before = loop_blocks(source)
    latch = 'latch' if name == 'integration_cross_edge' else 'loop'
    labels = list(before)
    labels = labels[labels.index('loop'):labels.index(latch) + 1]
    normalize = lambda text: re.sub(r'\s+', '', text.split(', !', 1)[0])
    for label in labels:
        for line in before[label].splitlines():
            if not line.strip() or re.search(r'%(?:sum|update) = ', line):
                continue
            if chunked and ((label == latch and line.lstrip().startswith('br ')) or
                            re.search(r'%(?:iv|done) = ', line)):
                continue
            if label == latch and line.lstrip().startswith('br '):
                line = line.replace('label %exit,', 'label %scalar.fission.consumer.ph,')
            retained = any(affine_instruction_refines(line.strip(), candidate.strip(), normalize)
                           for candidate in blocks[label].splitlines())
            assert retained, (name, label, line, body)
    if affine:
        assert '%fission.ordinal = phi i64 [ 0, %preheader ]' in producer, producer
        require_chunk_instruction(body, 'loop',
                                  '%fission.completed = add nuw i64 %fission.ordinal, 1')
        assert re.search(r'%fission.completed.count = phi i64 '
                         r'\[ %fission.completed, %loop \]', consumer), consumer
        assert not re.search(r'\b%limit\b', consumer), consumer
    if chunked:
        check_chunk_controller(body, capacity, exit='exit.loopexit')
        require_chunk_instruction(body, 'loop',
                                  '%iv = phi i64 [ %fission.chunk.base, %scalar.fission.producer.ph ], '
                                  f'[ %next, %{latch} ]')
        require_chunk_instruction(body, 'loop',
                                  '%fission.producer.ordinal = phi i64 [ 0, %scalar.fission.producer.ph ], '
                                  f'[ %fission.producer.next, %{latch} ]')
        for instruction in [
                '%fission.producer.next = add nuw i64 %fission.producer.ordinal, 1',
                '%fission.producer.more = icmp ne i64 %fission.producer.next, %fission.chunk.count',
                'br i1 %fission.producer.more, label %loop, label %scalar.fission.consumer.ph']:
            require_chunk_instruction(body, latch, instruction)
        address = re.findall(rf'(%[-\w.$]+) = getelementptr inbounds \[{capacity} x i32\], '
                             r'ptr %scalar.fission.scratch, i32 0, i64 %fission.producer.ordinal', blocks[latch])
        assert len(address) == 1, body
        assert f'store i32 %c, ptr {address[0]},' in blocks[latch], body
        check_loop_provenance(ir, blocks['scalar.fission.chunk.latch'], 'stage')
    check_loop_provenance(ir, blocks[latch], 'producer')
    for label, code in blocks.items():
        if label.startswith('vector.body') or label == 'scalar.fission.consumer.body':
            check_loop_provenance(ir, code, 'consumer')
    if not probe:
        return body

    def insert(label, code, at_end=False):
        nonlocal body
        if at_end:
            block = loop_blocks(body)[label]
            changed, count = re.subn(r'(?=^  br )', lambda _: code, block, flags=re.M)
            assert count == 1, block
            body = body.replace(block, changed, 1)
        else:
            body, count = re.subn(
                rf'(^{re.escape(label)}:[^\n]*\n(?:[^\n]* = phi [^\n]*\n)*)',
                lambda m: m[0] + code, body, flags=re.M)
            assert count == 1, (label, body)
    if chunked:
        insert('scalar.fission.chunk', '  call void @record_chunk_begin(i64 %fission.chunk.base, i64 %fission.chunk.count)\n', True)
        insert('loop', '  call void @record_chunk_producer(i64 %iv, i64 %fission.producer.ordinal)\n')
        insert('scalar.fission.chunk.latch', '  call void @record_chunk_end()\n', True)
    else:
        insert('loop', '  call void @record_acyclic_iteration()\n')
        insert(latch, '  call void @record_acyclic_latch()\n')
    insert('vector.body', '  call void @' + ('record_chunk_vector' if chunked else
                                            'record_scalar_consumer_vector') + '()\n')
    insert('scalar.fission.consumer.body', '  call void @' + ('record_chunk_tail' if chunked else
                                                            'record_scalar_consumer_tail') + '()\n')
    return body


def check(args, work):
    global command_log_dir
    command_log_dir = work
    root = Path(__file__).resolve().parents[2]
    tests = root / 'llvm/test/Transforms/LoopVectorize/RISCV'
    opt, llc = (args.build_dir / 'bin' / name for name in ('opt', 'llc'))
    triple = run([args.cc, '-dumpmachine']).stdout.strip()
    objects, records = [], []
    used_symbols = set()
    declarations, combined_rows, induction_rows, fp_rows = [], [], [], []
    scalar_rows, mixed_rows, constant_rows, nested_rows, diamond_rows = [], [], [], [], []
    compact_rows, compact_integer_rows, compact_nested_rows = [], [], []
    export_rows = []
    chunk_rows = []
    aos_chunk_rows = []
    short_int_rows, short_fp_rows = [], []
    fixed_call_rows, bounded_call_rows = [], []
    interleave_int_rows, interleave_fp_rows = [], []

    acyclic_rows = []
    acyclic_bound_rows = []
    affine_rows = []
    integration_rows = []
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
        path.write_text(host_ir(lower_fixed_deinterleaves(ir)))
        obj = path.with_suffix('.o')
        run([llc, f'-mtriple={triple}', '-filetype=obj', '-verify-machineinstrs',
             path, '-o', obj])
        objects.append(obj)

    adapter_ir, adapter_cases, poison_cases = deinterleave_adapter_cases()
    (work / 'deinterleave-adapter.input.ll').write_text(adapter_ir)
    adapter_ir, _ = rename_execution_functions(
        adapter_ir, {m['name']: m['name'] for m in FUNCTION_DEFINITION.finditer(adapter_ir)},
        used_symbols)
    compile_ir('deinterleave-adapter', adapter_ir)
    adapter_rows = []
    for case in adapter_cases:
        name = case['function']
        declarations.append(f'extern AdapterFn {name};')
        adapter_rows.append(f'{{"{name}", {case["factor"]}, {case["lanes"]}, '
                            f'{case["element_bytes"]}, {name}}}')
    for name in poison_cases:
        declarations.append(f'extern uint32_t {name}(void);')

    for fixture, functions in [
        ('combined', ['combined']),
        ('induction', ['induction', 'negative_step', 'truncated']),
        ('fp-reordering', ['fp_reordering']),
        ('short-producers', ['short_one', 'short_two', 'short_ordered',
                             'short_ordered_two']),
        ('independent-vfs', ['independent_vfs', 'independent_vfs_bounded']),
    ]:
        source = (tests / f'reduction-fission-{fixture}.ll').read_text()
        # These fixtures also contain rejection cases, which must not be
        # included repeatedly under their original names in the host objects.
        source = keep_functions(source, functions)
        reference, references = rename_execution_functions(
            source, {function: f'ref_{function}' for function in functions}, used_symbols)
        if fixture == 'independent-vfs':
            reference = define_independent_call_helpers(reference)
        compile_ir(f'reference_{fixture}', reference)
        for relaxed in ([False, True] if fixture in ('combined', 'short-producers') else
                        [fixture == 'fp-reordering']):
            flags = list(common)
            if fixture in ('combined', 'induction'):
                flags += [f'-vplan-reduction-fission-force-producer-vf={8 if fixture == "combined" else 16}',
                          '-vplan-reduction-fission-force-accumulator-vf=2']
            if fixture == 'independent-vfs':
                flags += ['-vplan-reduction-fission-force-producer-vf=2',
                          '-vplan-reduction-fission-force-accumulator-vf=8']
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
                reductions = 'xor' if function == 'independent_vfs_bounded' else '(?:add|fadd)'
                assert re.search(rf'@llvm.vector.reduce\.{reductions}\.', consumer), body
            if fixture == 'independent-vfs':
                for location in ('10:5', '30:7'):
                    assert re.search(
                        rf'independent-vfs.c:{location}: split reduction loop: '
                        r'baseline VF .*, producer VF vscale x 2, accumulator VF '
                        r'vscale x 8, trip count .*, scratch capacity 65, '
                        r'scratch bytes 260, scratch store bytes/iteration 4, '
                        r'scratch load bytes/iteration 4, duplicated recipes 0, '
                        r'reread loads/iteration 0', result.stderr), result.stderr
                assert 'call <vscale x 2 x i32> @vecfoo(' in result.stdout
                assert 'call <vscale x 2 x i32> @vecbar(' in result.stdout
                assert 'load <vscale x 8 x i32>' in result.stdout
            if fixture == 'short-producers' and not relaxed:
                assert 'reduction sum: ordered' in result.stderr, result.stderr
                assert 'fadd reassoc' not in result.stdout, result.stdout
                assert 'call double @llvm.vector.reduce.fadd.' in result.stdout
            # RVV machine verification is independent of host execution.
            run([llc, '-mtriple=riscv64', '-mattr=+v', '-verify-machineinstrs',
                 '-o', str(work / f'{tag}.s')], input=result.stdout)
            for scale in args.vscales:
                ir = result.stdout
                if fixture == 'independent-vfs':
                    ir = define_independent_call_helpers(ir, vector=True)
                fixed, names = rename_execution_functions(
                    specialize(ir, scale),
                    {function: f'{function}_{"r" if relaxed else "o"}_s{scale}'
                     for function in functions}, used_symbols)
                for function in functions:
                    name = names[function]
                    if fixture == 'combined':
                        declarations.append(f'extern CombinedFn {name};')
                        combined_rows.append(f'{{"{name}", {str(relaxed).lower()}, {name}}}')
                    elif fixture == 'induction':
                        declarations.append(f'extern InductionFn {name};')
                        induction_rows.append(f'{{"{name}", {name}, {references[function]}}}')
                    elif fixture == 'short-producers':
                        if function in ('short_one', 'short_two'):
                            declarations.append(f'extern ShortIntFn {name};')
                            short_int_rows.append(
                                f'{{"{name}", {name}, {references[function]}}}')
                        else:
                            declarations.append(f'extern ShortFPFn {name};')
                            outputs = 2 if function == 'short_ordered_two' else 1
                            short_fp_rows.append(
                                f'{{"{name}", {str(relaxed).lower()}, {outputs}, '
                                f'{name}, {references[function]}}}')
                    elif fixture == 'independent-vfs':
                        if function == 'independent_vfs':
                            declarations.append(f'extern FixedCallFn {name};')
                            fixed_call_rows.append(f'{{"{name}", {name}}}')
                        else:
                            declarations.append(f'extern BoundedCallFn {name};')
                            bounded_call_rows.append(f'{{"{name}", {name}}}')
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
        reference, references = rename_execution_functions(
            source, {function: f'ref_{function}' for function in functions}, used_symbols)
        compile_ir(f'reference_{fixture}', reference)
        if fixture == 'scalar-affine':
            for function in functions:
                ty = 'ScalarNestedFn' if function == 'affine_enclosing' else 'AffineFn'
                declarations.append(f'extern {ty} {references[function]};')
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
                    suffix = f'{"option_on" if relaxed else "o"}_s{scale}'
                    if fixture in ('scalar-acyclic', 'scalar-affine'):
                        suffix += f'_lv{repeats}'
                    fixed, names = rename_execution_functions(
                        specialize(instrumented, scale),
                        {function: f'{function}_{suffix}' for function in functions}, used_symbols)
                    for function in functions:
                        name, reference = names[function], references[function]
                        if function.startswith('affine_') and function != 'affine_enclosing':
                            declarations.append(f'extern AffineFn {name};')
                            control = {'affine_unsigned_early': 1, 'affine_signed_early': 2,
                                       'affine_down_early': 3, 'affine_signed_down_early': 4}.get(function, 0)
                            affine_rows.append(f'{{"{name}", {name}, {reference}, {4 * scale}, '
                                               f'{str(function == "affine_signed_down").lower()}, '
                                               f'{str(function == "affine_compact").lower()}, {control}}}')
                        elif function in ('compact_triangle', 'compact_diamond'):
                            declarations.append(f'extern ScalarMixedFn {name};')
                            compact_rows.append(f'{{"{name}", {name}, {reference}, {4 * scale}}}')
                        elif function == 'compact_integer':
                            declarations.append(f'extern ScalarSumFn {name};')
                            compact_integer_rows.append(f'{{"{name}", {name}, {reference}, {4 * scale}}}')
                        elif function == 'compact_nested':
                            declarations.append(f'extern ScalarNestedFn {name};')
                            compact_nested_rows.append(f'{{"{name}", {name}, {reference}, {4 * scale}}}')
                        elif function in ('scalar_helper_sum', 'arithmetic_sum',
                                        'diamond_arithmetic'):
                            declarations.append(f'extern ScalarSumFn {name};')
                            scalar_rows.append(f'{{"{name}", {name}, {reference}, {4 * scale}}}')
                        elif function == 'scalar_mixed':
                            declarations.append(f'extern ScalarMixedFn {name};')
                            mixed_rows.append(f'{{"{name}", {name}, {4 * scale}}}')
                        elif function == 'scalar_diamond':
                            declarations.append(f'extern ScalarMixedFn {name};')
                            diamond_rows.append(f'{{"{name}", {name}, {4 * scale}}}')
                        elif function in ('acyclic_serial', 'acyclic_nested', 'acyclic_three_way'):
                            declarations.append(f'extern ScalarMixedFn {name};')
                            acyclic_rows.append(f'{{"{name}", {name}, {reference}, {4 * scale}, '
                                                f'{str(function != "acyclic_serial").lower()}}}')
                        elif function in ('scalar_nested', 'scalar_diamond_nested', 'acyclic_enclosing', 'affine_enclosing'):
                            declarations.append(f'extern ScalarNestedFn {name};')
                            nested_rows.append(f'{{"{name}", {name}, {reference}, {4 * scale}, '
                                               f'{str(function != "scalar_nested").lower()}, '
                                               f'{str(function in ("acyclic_enclosing", "affine_enclosing")).lower()}}}')
                        else:
                            declarations.append(f'extern ScalarConstantFn {name};')
                            constant_rows.append(f'{{"{name}", {name}, {reference}, false}}')
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
        reference, references = rename_execution_functions(
            source, {function: f'ref_{function}' for function, _ in bounds}, used_symbols)
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
            instrumented, variant_declarations, variant_rows = boundary_variant(
                instrumented, bounds, tag, references, used_symbols)
            declarations.extend(variant_declarations)
            acyclic_bound_rows.extend(variant_rows)
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
        fixed, names = rename_execution_functions(
            specialize(instrumented, 1), {'narrow_constant': f'narrow_constant_{tag}'}, used_symbols)
        name = names['narrow_constant']
        compile_ir(tag, fixed)
        declarations.append(f'extern ScalarConstantFn {name};')
        constant_rows.append(f'{{"{name}", {name}, ref_narrow_constant, true}}')
        records.append({'fixture': 'scalar-ir-narrow-fixed',
                        'fp_reordering_option': relaxed, 'vf': 4,
                        'tail_policy': 'dont-fold-tail',
                        'comparison': 'exact integer',
                        'vector_execution': 'host-only consumer entry probe',
                        'options': options, 'selection_remarks': result.stderr})
    groups = {}
    for case in INTERLEAVE_FIXTURES:
        key = (case.fixture, case.vf_pairs, case.preferred_depth)
        groups.setdefault(key, []).append(case)
        signature = 'ShortFPFn' if case.ordered_fp else 'ShortIntFn'
        declarations.append(f'extern {signature} ref_{case.function};')
    for (fixture, vf_pairs, depth), cases in groups.items():
        functions = [case.function for case in cases]
        source = (tests / f'reduction-fission-{fixture}.ll').read_text()
        source = re.sub(
            r'^define[^\n]*?@([^ (]+)\([^\n]*\{.*?^}',
            lambda m: m[0] if m[1] in functions else '', source, flags=re.M | re.S)
        reference, references = rename_execution_functions(
            source, {function: f'ref_{function}' for function in functions}, used_symbols)
        compile_ir(f'reference_{fixture}_{functions[0]}', reference)
        for (producer_vf, accumulator_vf), (tail_policy, tail_flags) in product(
            vf_pairs,
            (('default', []),
             ('scalar-tail', ['-tail-folding-policy=dont-fold-tail']),
             ('data-mask', ['-tail-folding-policy=must-fold-tail',
                            '-force-tail-folding-style=data'])),
        ):
            flags = list(common) + tail_flags + [
                f'-vplan-reduction-fission-min-chain-depth={depth}',
                f'-vplan-reduction-fission-force-producer-vf={producer_vf}',
                f'-vplan-reduction-fission-force-accumulator-vf={accumulator_vf}',
                '-pass-remarks-missed=vplan-reduction-fission',
            ]
            result = run([opt, *flags], input=source)
            tag = f'{fixture}_{functions[0]}_p{producer_vf}_a{accumulator_vf}_{tail_policy}'
            (work / f'{tag}.remarks').write_text(result.stderr)
            (work / f'{tag}.scalable.ll').write_text(result.stdout)
            assert result.stdout.count('vector.fission.producer.body:') == len(functions), result.stderr
            assert 'fadd reassoc' not in result.stdout, result.stdout
            for case in cases:
                size = case.scratch_bytes_per_iteration
                location = (rf'{re.escape(case.source_file)}:{case.source_line}:5: '
                            if case.source_file else '')
                duplicated = r'[1-9][0-9]*' if case.reread_loads else '0'
                assert re.search(
                    location + r'split reduction loop: '
                    rf'baseline VF .*, producer VF vscale x {producer_vf}, '
                    rf'accumulator VF vscale x {accumulator_vf}, '
                    rf'trip count bounded-runtime, scratch capacity 65, '
                    rf'scratch bytes {65 * size}, scratch store bytes/iteration '
                    rf'{size}, scratch load bytes/iteration {size}, '
                    rf'duplicated recipes {duplicated}, '
                    rf'reread loads/iteration {case.reread_loads}\b',
                    result.stderr), result.stderr
                body = re.search(
                    rf'^define[^\n]* @{case.function}\([^\n]*\{{.*?^}}',
                    result.stdout, re.M | re.S)[0]
                # Check every function, including both actual group instances
                # in reread cases, without counting declarations or neighbors.
                intrinsic = f'@llvm.vector.deinterleave{case.factor}.'
                assert body.count(intrinsic) == (2 if case.reread_loads else 1), body
                slots = size // (8 if case.ordered_fp else 4)
                assert body.count('alloca [65 x ') == slots, body
            run([llc, '-mtriple=riscv64', '-mattr=+v', '-verify-machineinstrs',
                 '-o', str(work / f'{tag}.s')], input=result.stdout)
            for scale in args.vscales:
                fixed, names = rename_execution_functions(
                    specialize(result.stdout, scale),
                    {function: f'{function}_p{producer_vf}_a{accumulator_vf}_'
                               f'{tail_policy}_s{scale}' for function in functions}, used_symbols)
                for case in cases:
                    function = case.function
                    name = names[function]
                    fp, factor = case.ordered_fp, case.factor
                    declarations.append(f'extern {"ShortFPFn" if fp else "ShortIntFn"} {name};')
                    row = (f'{{"{name}", {factor}, {case.outputs}, {producer_vf * scale}, '
                           f'{accumulator_vf * scale}, {name}, {references[function]}, 0, 0}}')
                    (interleave_fp_rows if fp else interleave_int_rows).append(row)
                fixed = instrument_interleave_stages(fixed, names.values())
                compile_ir(f'{tag}_s{scale}', fixed)
                records.append({'fixture': fixture, 'vscale': scale,
                                'functions': [asdict(case) for case in cases],
                                'producer_vf': producer_vf,
                                'accumulator_vf': accumulator_vf,
                                'tail_policy': tail_policy,
                                'execution': 'host fixed-vscale, four stage entry counters',
                                'options': flags, 'selection_remarks': result.stderr})
                print(f'Built {tag}, vscale={scale}', flush=True)

    # Default dispatch now retains XOR in each AoS producer and extracts add.
    # Its bodies are identical to the independent original scalar references
    # above (only debug locations and LV metadata differ). Keep all inherited
    # matrices intact and append these comparisons, including a second LV run.
    source = keep_functions((tests / 'reduction-fission-dispatch.ll').read_text(),
                            ['interleave2', 'interleave3', 'interleave2_ordered',
                             'compact_nested'])
    dispatch_reference, dispatch_references = rename_execution_functions(
        source, {function: f'ref_dispatch_{function}' for function in
                 ('interleave2', 'interleave3', 'interleave2_ordered', 'compact_nested')}, used_symbols)
    compile_ir('reference_dispatch', dispatch_reference)
    dispatch_common = [flag for flag in common
                       if flag != '-enable-scalar-reduction-fission=false']
    dispatch_common.append('-scalable-vectorization=always')
    dispatch_host_functions = set()
    for repeated, relaxed, evl in product((False, True), (False, True), (True, False)):
        options = list(dispatch_common) + [
            '-vplan-reduction-fission-force-producer-vf=2',
            '-vplan-reduction-fission-force-accumulator-vf=4',
            '-pass-remarks-missed=vplan-reduction-fission',
        ]
        if repeated:
            options[0] = ('-passes=loop-vectorize,loop-vectorize,verify<domtree>,'
                          'verify<loops>,verify<scalar-evolution>')
        if relaxed:
            options.append('-vplan-reduction-fission-allow-fp-reordering')
        if not evl:
            options += ['-tail-folding-policy=dont-fold-tail',
                        '-enable-epilogue-vectorization=false']
        tag = (f'dispatch_{"twice" if repeated else "once"}_'
               f'{"option_on" if relaxed else "ordered"}_'
               f'{"default_evl" if evl else "scalar_remainder"}')
        result = run([opt, *options], input=source)
        (work / f'{tag}.remarks').write_text(result.stderr)
        (work / f'{tag}.rvv.ll').write_text(result.stdout)
        stage_vfs = dispatch_stage_vfs(result.stderr)
        overlap_vfs = stage_vfs['interleave2_ordered']
        instrumented = result.stdout
        layouts = {name: {} for name in ('interleave2', 'interleave3', 'interleave2_ordered')}
        for name, factor in (('interleave2', 2), ('interleave3', 3)):
            checked = check_dispatch_scalar_interleave(result.stdout, name, factor, evl,
                                                        *stage_vfs[name], probe=not evl,
                                                        stages=layouts[name])
            instrumented = instrumented.replace(function_definition(result.stdout, name), checked, 1)
        for name, checked in (
            ('interleave2_ordered', check_dispatch_overlap(result.stdout, evl,
                                                          *overlap_vfs, probe=not evl,
                                                          stages=layouts['interleave2_ordered'])),
            ('compact_nested', check_scalar_function(result.stdout, 'compact_nested',
                                                      evl, probe=not evl)),
        ):
            instrumented = instrumented.replace(function_definition(result.stdout, name),
                                                  checked, 1)
        # Always verify the exact scalable module before probes/specialization.
        run([llc, '-mtriple=riscv64', '-mattr=+v', '-verify-machineinstrs',
             '-o', str(work / f'{tag}.s')], input=result.stdout)
        if evl:
            records.append({'fixture': 'dispatch', 'repeated_lv': repeated,
                            'fp_reordering_option': relaxed, 'tail_policy': 'default-evl',
                            'stage_vfs': stage_vfs, 'emitted_stages': layouts,
                            'accounting': 'actual early producer/consumer stages; retained XOR '
                                          'and moved add; EVL is machine verified, not host executed',
                            'executed': False, 'options': options,
                            'selection_remarks': result.stderr})
            continue
        instrumented += ('\ndeclare void @fission_interleave_probe(i32)\n'
                         'declare void @fission_interleave_tail_probe(i32, i64)\n'
                         'declare void @record_scalar_consumer_vector()\n'
                         'declare void @record_scalar_consumer_tail()\n'
                         'declare void @record_compact_participant()\n'
                         'declare void @record_compact_iteration()\n')
        for scale in args.vscales:
            functions = ('interleave2', 'interleave3', 'interleave2_ordered', 'compact_nested')
            fixed, names = rename_execution_functions(
                specialize(instrumented, scale),
                {function: f'{function}_{tag}_s{scale}' for function in functions}, used_symbols)
            for function, factor in (('interleave2', 2), ('interleave3', 3),
                                     ('interleave2_ordered', 2), ('compact_nested', 0)):
                name = names[function]
                reference = dispatch_references[function]
                if function == 'compact_nested':
                    declarations.append(f'extern ScalarNestedFn {name}, {reference};')
                    compact_nested_rows.append(
                        f'{{"{name}", {name}, {reference}, {4 * scale}}}')
                else:
                    fp = function == 'interleave2_ordered'
                    pvf, avf = stage_vfs[function]
                    declarations.append(f'extern {"ShortFPFn" if fp else "ShortIntFn"} {name}, {reference};')
                    # Keep the integer formula opt-in, then append independent
                    # certified minima for both primary and ordinary stages.
                    formula = '' if fp else ', true'
                    if not fp:
                        dispatch_host_functions.add(name)
                    tail_vfs = ([0, 0] if fp else
                                [tail['vf'] * scale for tail in layouts[function]['ordinary_tails']])
                    row = (f'{{"{name}", {factor}, 2, {pvf * scale}, {avf * scale}, '
                           f'{name}, {reference}, {tail_vfs[0]}, {tail_vfs[1]}{formula}, '
                           f'{dispatch_entry_fields(layouts[function]["entries"])}'
                           f'{", true" if fp else ""}}}')
                    (interleave_fp_rows if fp else interleave_int_rows).append(row)
            compile_ir(f'{tag}_s{scale}', fixed)
            records.append({'fixture': 'dispatch', 'repeated_lv': repeated,
                            'fp_reordering_option': relaxed, 'tail_policy': 'scalar-remainder',
                            'vscale': scale, 'options': options, 'stage_vfs': stage_vfs,
                            'emitted_stages': layouts,
                            'comparison': 'exact original dispatch IR and independent C sum/XOR '
                                          'formulas; inherited ordered overlap and compact nest',
                            'probes': 'actual producer vector/scalar and consumer vector/scalar '
                                      'entries; independently certified entry thresholds and rounded counts; '
                                      'exact N lane totals at emitted widths; '
                                      'per-configuration execution totals; exact nested N/P/vector/tail',
                            'selection_remarks': result.stderr})
            print(f'Built combined default dispatch {tag}, vscale={scale}', flush=True)

    # Preserve the old VPlan dispatch/tail certificates explicitly under
    # isolation. Default dispatch no longer reaches this architecture, but its
    # four original stages and repeated-LV ordinary tails remain obligations.
    isolated_source = keep_functions(source, ['interleave2', 'interleave3'])
    for repeated, relaxed, evl in product((False, True), (False, True), (True, False)):
        options = list(dispatch_common) + [
            '-enable-scalar-reduction-fission=false',
            '-vplan-reduction-fission-force-producer-vf=2',
            '-vplan-reduction-fission-force-accumulator-vf=4',
        ]
        if repeated:
            options[0] = ('-passes=loop-vectorize,loop-vectorize,verify<domtree>,'
                          'verify<loops>,verify<scalar-evolution>')
        if relaxed:
            options.append('-vplan-reduction-fission-allow-fp-reordering')
        if not evl:
            options += ['-tail-folding-policy=dont-fold-tail', '-enable-epilogue-vectorization=false']
        tag = (f'dispatch_isolated_lv{2 if repeated else 1}_'
               f'{"reordered" if relaxed else "strict"}_{"evl" if evl else "tail"}')
        result = run([opt, *options], input=isolated_source)
        (work / f'{tag}.remarks').write_text(result.stderr)
        (work / f'{tag}.rvv.ll').write_text(result.stdout)
        assert result.stderr.count('split reduction loop:') == 2, result.stderr
        assert 'split scalar-IR reduction loop;' not in result.stderr, result.stderr
        ordinary_tails = {}
        for name, factor, line in (('interleave2', 2, 10), ('interleave3', 3, 20)):
            assert re.search(rf'dispatch.c:{line}:5: split reduction loop: baseline VF .*, '
                             r'producer VF vscale x 2, accumulator VF vscale x 4, '
                             r'trip count bounded-runtime, scratch capacity 65, scratch bytes 260, '
                             r'scratch store bytes/iteration 4, scratch load bytes/iteration 4, '
                             r'duplicated recipes 0, reread loads/iteration 0', result.stderr), result.stderr
            body = function_definition(result.stdout, name)
            assert body.count('alloca [65 x i32]') == 1 and 'scalar.fission.scratch' not in body, body
            group = loop_blocks(body)['vector.fission.producer.body']
            assert group.count(f'@llvm.vector.deinterleave{factor}.') == 1, group
            ordinary_tails[name] = check_dispatch_interleave(result.stdout, name, factor, repeated, evl)
        run([llc, '-mtriple=riscv64', '-mattr=+v', '-verify-machineinstrs',
             '-o', str(work / f'{tag}.s')], input=result.stdout)
        if not evl:
            instrumented = instrument_interleave_stages(result.stdout, ordinary_tails, ordinary_tails)
            for scale in args.vscales:
                fixed, names = rename_execution_functions(
                    specialize(instrumented, scale),
                    {function: f'{function}_{tag}_s{scale}' for function in ordinary_tails}, used_symbols)
                for function, factor in (('interleave2', 2), ('interleave3', 3)):
                    name, reference = names[function], dispatch_references[function]
                    tails = [tail['vf'] * scale for tail in ordinary_tails[function]]
                    declarations.append(f'extern ShortIntFn {name}, {reference};')
                    interleave_int_rows.append(f'{{"{name}", {factor}, 2, {2 * scale}, {4 * scale}, '
                                               f'{name}, {reference}, {tails[0]}, {tails[1]}}}')
                compile_ir(f'{tag}_s{scale}', fixed)
        records.append({'fixture': 'dispatch-isolated-vplan', 'repeated_lv': repeated,
                        'fp_reordering_option': relaxed, 'tail_policy': 'default-evl' if evl else 'scalar-remainder',
                        'vscales': [] if evl else args.vscales, 'host_variants_generated': not evl,
                        'vplan_ordinary_tails': ordinary_tails, 'options': options,
                        'selection_remarks': result.stderr})

    # Final producer exports are an additional matrix. Keep all inherited
    # fixtures, reference origins, probes and adapter comparisons unchanged.
    state_cfg_host_functions = set()
    for filename, functions, first_mode, location, fixture in EXPORT_FAMILIES:
        source = keep_functions((tests / filename).read_text(),
                                functions)
        reference, references = rename_execution_functions(
            source, {function: f'ref_{function}' for function in functions}, used_symbols)
        declarations.extend(export_reference_declarations(source, reference, references))
        compile_ir('reference_' + fixture, reference)
        export_flags = [flag for flag in common
                        if flag != '-enable-scalar-reduction-fission=false' and
                        not flag.startswith('-passes=')]
        export_flags += ['-force-vector-width=4', '-scalable-vectorization=always']
        modes = ('tail', 'evl', 'scalar') if first_mode == 16 else ('tail', 'evl')
        for repeated, relaxed, execution_mode in product((False, True), (False, True), modes):
            evl, scalar = execution_mode == 'evl', execution_mode == 'scalar'
            passes = 'loop-vectorize,' * (2 if repeated else 1)
            options = export_flags + [f'-passes={passes}verify<domtree>,verify<loops>,'
                                      'verify<scalar-evolution>']
            if first_mode:
                options += ['-vplan-reduction-fission-max-scratch-bytes=1044']
            if scalar:
                options = [flag for flag in options if not flag.startswith(
                    ('-force-vector-width=', '-force-vector-interleave=', '-scalable-vectorization='))]
                options += ['-force-vector-width=1', '-force-vector-interleave=0',
                            '-force-target-max-scalar-interleave=1', '-scalable-vectorization=off']
            if relaxed:
                options += ['-vplan-reduction-fission-allow-fp-reordering']
            if not evl:
                options += ['-tail-folding-policy=dont-fold-tail',
                            '-enable-epilogue-vectorization=false']
            result = run([opt, *options], input=source)
            tag = f'{fixture}_{"twice" if repeated else "once"}_{"option_on" if relaxed else "strict"}_{execution_mode}'
            (work / f'{tag}.remarks').write_text(result.stderr)
            (work / f'{tag}.rvv.ll').write_text(result.stdout)
            assert result.stderr.count('split scalar-IR reduction loop;') == len(functions), result.stderr
            instrumented = result.stdout
            for mode, function in enumerate(functions):
                loc = f'{location}:{12 + 10 * mode}:3'
                exports = 7 if first_mode == 16 else 6
                assert re.search(rf'{re.escape(loc)}: split scalar-IR reduction loop;[^\n]*'
                                 rf'scratch capacity 65, scratch bytes 1044, producer live-outs {exports}\b',
                                 result.stderr), result.stderr
                for stage, vf in (('producer', '1'), ('consumer', '1' if scalar else 'vscale x 4')):
                    assert f'{loc}: scalar-IR fission {stage} VF {vf}' in result.stderr, result.stderr
                checked = check_producer_exports(result.stdout, function, evl, probe=not evl,
                                                  source=source, scalar=scalar)
                instrumented = instrumented.replace(function_definition(result.stdout, function),
                                                      checked, 1)
            run([llc, '-mtriple=riscv64', '-mattr=+v', '-verify-machineinstrs',
                 '-o', str(work / f'{tag}.s')], input=result.stdout)
            record = {'fixture': fixture, 'functions': functions, 'repeated_lv': repeated,
                      'fp_reordering_option': relaxed, 'tail_policy': 'default-evl' if evl else 'scalar-remainder',
                      'options': options, 'selection_remarks': result.stderr,
                      'producer_exports': exports, 'forwarding_phis': exports, 'additional_blocks': 0,
                      'scratch_capacity_bytes': 1044, 'logical_scratch_bytes_per_participant': 32,
                      'input_rereads': 0, 'duplicated_producer_operations': 0}
            if evl:
                records.append(dict(record, executed=False,
                                    validation='RVV machine verification only; not target execution'))
                continue
            instrumented += ('\ndeclare void @record_scalar_consumer_vector()\n'
                             'declare void @record_scalar_consumer_tail()\n'
                             'declare void @record_compact_iteration()\n'
                             'declare void @record_compact_participant()\n'
                             'declare void @record_export_guard(i64)\n'
                             'declare void @record_export_bypass()\n'
                             'declare void @record_export_final(i32)\n'
                             'declare void @record_compact_cfg_bypass(i32)\n')
            for scale in ([1] if scalar else args.vscales):
                fixed, variant_declarations, rows = export_variant(
                    specialize(instrumented, scale), functions, f'{tag}_s{scale}',
                    references, used_symbols, first_mode, 0 if scalar else 4 * scale)
                declarations.extend(variant_declarations)
                export_rows.extend(rows)
                if first_mode == 16:
                    state_cfg_host_functions.update(f'{function}_{tag}_s{scale}'
                                                    for function in functions)
                compile_ir(f'{tag}_s{scale}', fixed)
                records.append(dict(record, vscale=scale,
                                    execution='host fixed-vscale scalar remainder, not RVV',
                                    comparison='all exports and reductions: original IR and independent C, exact bits',
                                    probes='exact N/P/vector/tail, P=0 guard, entry-bypass edge and '
                                           'final-inactive result exit; per-configuration nonzero counters'))

    # Chunk scheduling is additional coverage. Original references, matrices
    # and every inherited assertion above remain unchanged.
    source = keep_functions((tests / 'reduction-fission-scalar-chunks.ll').read_text(),
                            CHUNK_FUNCTIONS)
    reference, references = rename_execution_functions(
        source, {function: f'ref_{function}' for function in CHUNK_FUNCTIONS}, used_symbols)
    declarations.extend(export_reference_declarations(source, reference, references))
    compile_ir('reference_scalar_chunks', reference)
    for capacity, ceiling in ((1, 20), (9, 148), (16, 256)):
        # Exact scalar carry/forwarding proof, independent of LV exit folding.
        scalar_flags = [flag for flag in export_flags
                        if not flag.startswith(('-force-vector-width=',
                                                '-scalable-vectorization=',
                                                '-force-vector-interleave='))]
        scalar_options = scalar_flags + [
            '-passes=loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>',
            '-force-vector-width=1', '-force-vector-interleave=0',
            '-force-target-max-scalar-interleave=1', '-scalable-vectorization=off',
            f'-vplan-reduction-fission-max-scratch-bytes={ceiling}']
        scalar = run([opt, *scalar_options], input=source)
        (work / f'chunks_c{capacity}.scalar.ll').write_text(scalar.stdout)
        (work / f'chunks_c{capacity}.scalar.remarks').write_text(scalar.stderr)
        assert scalar.stderr.count('split scalar-IR reduction loop;') == len(CHUNK_FUNCTIONS), scalar.stderr
        for function in CHUNK_FUNCTIONS:
            check_chunk_function(scalar.stdout, function, capacity, scalar=True)
        for repeated, relaxed, evl in product((False, True), (False, True), (False, True)):
            passes = 'loop-vectorize,' * (2 if repeated else 1)
            options = export_flags + [
                f'-passes={passes}verify<domtree>,verify<loops>,verify<scalar-evolution>',
                f'-vplan-reduction-fission-max-scratch-bytes={ceiling}']
            if relaxed:
                options += ['-vplan-reduction-fission-allow-fp-reordering']
            if not evl:
                options += ['-tail-folding-policy=dont-fold-tail',
                            '-enable-epilogue-vectorization=false']
            result = run([opt, *options], input=source)
            tag = (f'chunks_c{capacity}_{"twice" if repeated else "once"}_'
                   f'{"option_on" if relaxed else "ordered"}_{"evl" if evl else "tail"}')
            (work / f'{tag}.remarks').write_text(result.stderr)
            (work / f'{tag}.rvv.ll').write_text(result.stdout)
            assert result.stderr.count('split scalar-IR reduction loop;') == len(CHUNK_FUNCTIONS), result.stderr
            instrumented, vectorized = result.stdout, {}
            for function, line, bound in zip(CHUNK_FUNCTIONS, (12, 22, 32, 42),
                                             (65, 255, 65, 65)):
                loc = f'scalar-chunks.c:{line}:3'
                assert re.search(rf'{re.escape(loc)}: split scalar-IR reduction loop;[^\n]*'
                                 rf'scratch capacity {capacity}, scratch bytes {ceiling}, '
                                 rf'producer live-outs 6, chunked schedule, trip bound {bound}, '
                                 r'scratch store bytes/iteration 16, scratch load bytes/iteration 16, '
                                 r'producer reread bytes/iteration 0, duplicated producer instructions 0\b',
                                 result.stderr), result.stderr
                assert f'{loc}: scalar-IR fission producer VF 1' in result.stderr, result.stderr
                body = function_definition(result.stdout, function)
                vectorized[function] = bool(re.search(r'^vector\.body[\w.$-]*:', body, re.M))
                assert vectorized[function] or capacity == 1, body
                vf = 'vscale x 4' if vectorized[function] else '1'
                assert f'{loc}: scalar-IR fission consumer VF {vf}' in result.stderr, result.stderr
                checked = check_chunk_function(result.stdout, function, capacity, evl,
                                               probe=not evl)
                instrumented = instrumented.replace(body, checked, 1)
            run([llc, '-mtriple=riscv64', '-mattr=+v', '-verify-machineinstrs',
                 '-o', str(work / f'{tag}.s')], input=result.stdout)
            record = {'fixture': 'scalar-chunks', 'capacity': capacity,
                      'allocated_bytes': ceiling,
                      'trip_bounds': dict(zip(CHUNK_FUNCTIONS, (65, 255, 65, 65))),
                      'repeated_lv': repeated, 'fp_reordering_option': relaxed,
                      'options': options, 'selection_remarks': result.stderr,
                      'producer_live_outs': 6, 'streams': 3, 'reductions': 4,
                      'logical_scratch_store_bytes_per_iteration': 16,
                      'logical_scratch_load_bytes_per_iteration': 16,
                      'input_rereads': 0, 'duplicated_producer_operations': 0}
            if evl:
                records.append(dict(record, executed=False,
                                    validation='RVV machine verification only; not target execution'))
                continue
            instrumented += ('\ndeclare void @record_chunk_begin(i64, i64)\n'
                             'declare void @record_chunk_end()\n'
                             'declare void @record_chunk_producer(i64, i64)\n'
                             'declare void @record_chunk_vector()\n'
                             'declare void @record_chunk_tail()\n')
            for scale in args.vscales:
                fixed, names = rename_execution_functions(
                    specialize(instrumented, scale),
                    {function: f'{function}_{tag}_s{scale}' for function in CHUNK_FUNCTIONS}, used_symbols)
                for function in CHUNK_FUNCTIONS:
                    name = names[function]
                    declarations.append(f'extern ExportFn {name};')
                    lanes = 4 * scale if vectorized[function] else 0
                    chunk_rows.append(f'{{"{name}", {name}, {references[function]}, '
                                      f'{int(function == "chunk_nested")}, {capacity}, {lanes}, '
                                      f'{255 if function == "chunk_narrow" else 65}}}')
                compile_ir(f'{tag}_s{scale}', fixed)
                records.append(dict(record, vscale=scale,
                                    execution='host fixed-vscale scalar remainder, not RVV',
                                    comparison='all reductions/exports and alias state against original IR and independent C',
                                    probes='every chunk begin/end, exact count and local/global producer indices, '
                                           'complete producer before consumer, exact vector/tail lanes'))


    # Compact canonical scheduling, including original producer state and
    # empty chunks. Keep all inherited matrices above/below this addition.
    compact_chunk_rows = []
    compact_chunk_host_configurations = {}
    source = (tests / 'reduction-fission-scalar-compact-chunks.ll').read_text()
    reference, references = rename_execution_functions(
        source, {name: f'ref_{name}' for name in COMPACT_CHUNK_FUNCTIONS}, used_symbols)
    declarations.extend(export_reference_declarations(source, reference, references))
    compile_ir('reference_compact_chunks', reference)
    for capacity, ceiling in ((1, 16), (9, 112), (16, 192), (65, 784)):
        for repeated, relaxed, kind in product((False, True), (False, True),
                                               ('scalar', 'tail', 'evl')):
            scalar, evl = kind == 'scalar', kind == 'evl'
            functions = [name for name in COMPACT_CHUNK_FUNCTIONS
                         if scalar or name != 'compact_chunk_narrow']
            fixture = keep_functions(source, functions)
            flags = [flag for flag in export_flags if not flag.startswith(
                ('-passes=', '-force-vector-width=', '-force-vector-interleave=',
                 '-scalable-vectorization='))]
            options = flags + [
                '-passes=' + 'loop-vectorize,' * (2 if repeated else 1) +
                'verify<domtree>,verify<loops>,verify<scalar-evolution>',
                f'-vplan-reduction-fission-max-scratch-bytes={ceiling}',
                '-force-vector-width=' + ('1' if scalar else '4'),
                '-force-vector-interleave=' + ('0' if scalar else '1'),
                '-scalable-vectorization=' + ('off' if scalar else 'always')]
            if scalar:
                options += ['-force-target-max-scalar-interleave=1']
            if relaxed:
                options += ['-vplan-reduction-fission-allow-fp-reordering']
            if kind == 'tail':
                options += ['-tail-folding-policy=dont-fold-tail',
                            '-enable-epilogue-vectorization=false']
            result = run([opt, *options], input=fixture)
            tag = (f'compact_chunks_c{capacity}_lv{2 if repeated else 1}_'
                   f'{"reordered" if relaxed else "strict"}_{kind}')
            (work / f'{tag}.rvv.ll').write_text(result.stdout)
            (work / f'{tag}.remarks').write_text(result.stderr)
            assert result.stderr.count('split scalar-IR reduction loop;') == len(functions), result.stderr
            instrumented, widths = result.stdout, {}
            for name in functions:
                body = function_definition(result.stdout, name)
                vectorized = bool(re.search(r'^vector\.body[\w.$-]*:', body, re.M))
                assert vectorized or scalar or capacity == 1, body
                widths[name] = 4 if vectorized else 0
                actual_widths = set(map(int, re.findall(r'<vscale x (\d+) x (?:i32|double)>', body)))
                assert actual_widths == ({4} if vectorized else set()), (name, actual_widths)
                check_compact_chunk_remarks(result.stderr, name, capacity, ceiling, vectorized)
                checked = check_compact_chunk(result.stdout, source, name, capacity,
                                              scalar=scalar, evl=evl, probe=not evl)
                instrumented = instrumented.replace(body, checked, 1)
            run([llc, '-mtriple=riscv64', '-mattr=+v', '-verify-machineinstrs',
                 '-o', str(work / f'{tag}.s')], input=result.stdout)
            record = dict(fixture='scalar-compact-chunks', capacity=capacity, scratch_bytes=ceiling,
                          options=options, policy='reordered' if relaxed else 'strict',
                          lv_invocations=2 if repeated else 1, kind=kind,
                          producer_vf=1, consumer_vfs=widths, retained_producer_phis=2,
                          producer_carries=2 if capacity < 65 else 0,
                          logical_store_bytes_per_participant=12, logical_load_bytes_per_participant=12,
                          rereads=0, duplicated_operations=0, empty_stream_guards=1,
                          new_versioning_guards=0)
            if evl:
                records.append(dict(record, executed=False,
                                    validation='uninstrumented RVV machine verification; no target execution'))
                continue
            instrumented += (
                '\ndeclare void @record_cc_begin(i64, i64, i32, i32, i32, i32, double)\n'
                'declare void @record_cc_producer(i64, i64)\n'
                'declare void @record_cc_participant(i64)\n'
                'declare void @record_cc_guard(i64, i64, i32, i32, i32, double)\n'
                'declare void @record_cc_end(i32, i32, double)\n'
                'declare void @record_cc_vector()\n'
                'declare void @record_cc_tail()\n')
            run([opt, '-passes=verify', '-disable-output'], input=instrumented)
            (work / f'{tag}.instrumented.ll').write_text(instrumented)
            for scale in ((1,) if scalar else args.vscales):
                fixed, names = rename_execution_functions(
                    specialize(instrumented, scale),
                    {name: f'{name}_{tag}_s{scale}' for name in functions}, used_symbols)
                for function in functions:
                    name = names[function]
                    mode = COMPACT_CHUNK_FUNCTIONS.index(function)
                    declarations.append(f'extern ExportFn {name};')
                    compact_chunk_rows.append(f'{{"{name}", {name}, {references[function]}, '
                                              f'{mode}, {capacity}, {widths[function] * scale}}}')
                    compact_chunk_host_configurations[name] = (mode, capacity, widths[function] * scale)
                compile_ir(f'{tag}_s{scale}', fixed)
                records.append(dict(record, vscale=scale, execution='host fixed-vscale, not RVV',
                                    comparison='exact original IR and independent nonchunked C oracle',
                                    probes='completed/participating/consumer counts, every carry/export, empty later chunks'))

    # Canonical retained producer state across bounded chunks. This matrix is
    # additional to every inherited matrix. Scalar configurations execute too;
    # EVL remains uninstrumented RVV codegen-only evidence.
    state_chunk_rows = []
    state_chunk_host_configurations = {}
    source = (tests / 'reduction-fission-scalar-chunk-state.ll').read_text()
    reference, references = rename_execution_functions(
        source, {name: f'ref_{name}' for name in STATE_CHUNK_FUNCTIONS}, used_symbols)
    declarations.extend(export_reference_declarations(source, reference, references))
    compile_ir('reference_state_chunks', reference)
    for capacity, ceiling in ((1, 16), (9, 112), (16, 192)):
        for repeated, relaxed, kind in product((False, True), (False, True),
                                                ('scalar', 'tail', 'evl')):
            scalar, evl = kind == 'scalar', kind == 'evl'
            flags = [flag for flag in export_flags if not flag.startswith(
                ('-passes=', '-force-vector-width=', '-force-vector-interleave=',
                 '-scalable-vectorization='))]
            options = flags + [
                '-passes=' + 'loop-vectorize,' * (2 if repeated else 1) +
                'verify<domtree>,verify<loops>,verify<scalar-evolution>',
                f'-vplan-reduction-fission-max-scratch-bytes={ceiling}',
                '-force-vector-width=' + ('1' if scalar else '4'),
                '-force-vector-interleave=' + ('0' if scalar else '1'),
                '-scalable-vectorization=' + ('off' if scalar else 'always')]
            if scalar:
                options += ['-force-target-max-scalar-interleave=1']
            if relaxed:
                options += ['-vplan-reduction-fission-allow-fp-reordering']
            if kind == 'tail':
                options += ['-tail-folding-policy=dont-fold-tail',
                            '-enable-epilogue-vectorization=false']
            result = run([opt, *options], input=source)
            tag = (f'state_chunks_c{capacity}_lv{2 if repeated else 1}_'
                   f'{"reordered" if relaxed else "strict"}_{kind}')
            (work / f'{tag}.rvv.ll').write_text(result.stdout)
            (work / f'{tag}.remarks').write_text(result.stderr)
            assert result.stderr.count('split scalar-IR reduction loop;') == 4, result.stderr
            instrumented, widths = result.stdout, {}
            for name in STATE_CHUNK_FUNCTIONS:
                body = function_definition(result.stdout, name)
                vectorized = bool(re.search(r'^vector\.body[\w.$-]*:', body, re.M))
                assert vectorized or scalar or capacity == 1, body
                actual_widths = set(map(int, re.findall(
                    r'<vscale x (\d+) x (?:i32|double)>', body)))
                assert actual_widths == ({4} if vectorized else set()), (name, actual_widths)
                widths[name] = next(iter(actual_widths)) if vectorized else 0
                check_state_chunk_remarks(result.stderr, name, capacity, ceiling, vectorized)
                checked = check_state_chunk(result.stdout, source, name, capacity,
                                            scalar=scalar, evl=evl, probe=not evl)
                instrumented = instrumented.replace(body, checked, 1)
            run([llc, '-mtriple=riscv64', '-mattr=+v', '-verify-machineinstrs',
                 '-o', str(work / f'{tag}.s')], input=result.stdout)
            record = dict(fixture='scalar-chunk-state', capacity=capacity, scratch_bytes=ceiling,
                          selection_remarks=result.stderr,
                          options=options, policy='reordered' if relaxed else 'strict',
                          lv_invocations=2 if repeated else 1, kind=kind,
                          producer_vf=1, consumer_vfs=widths, producer_carries=[2, 3, 2, 3],
                          observed_consumer_vfs={name: f'vscale x {vf}' if vf else '1'
                                                 for name, vf in widths.items()},
                          logical_store_bytes_per_iteration=12, logical_load_bytes_per_iteration=12,
                          rereads=0, duplicated_operations=0, added_runtime_guards=0,
                          schedule_controls='per-chunk min/select, producer/consumer latches, continuation')
            if evl:
                records.append(dict(record, executed=False,
                                    validation='uninstrumented RVV machine verification; no target execution'))
                continue
            instrumented += (
                '\ndeclare void @record_state_chunk_begin(i64, i64, i32, i32, double)\n'
                'declare void @record_state_chunk_end(i32, i32, i32, double, double)\n'
                'declare void @record_state_chunk_producer(i64, i64)\n'
                'declare void @record_chunk_vector()\n'
                'declare void @record_chunk_tail()\n')
            # Validate the actual instrumented scalable module before host
            # adaptation. Verification is distinct from compilation/execution.
            run([opt, '-passes=verify', '-disable-output'], input=instrumented)
            (work / f'{tag}.instrumented.ll').write_text(instrumented)
            for scale in ((1,) if scalar else args.vscales):
                fixed, names = rename_execution_functions(
                    specialize(instrumented, scale),
                    {name: f'{name}_{tag}_s{scale}' for name in STATE_CHUNK_FUNCTIONS}, used_symbols)
                for mode, function in enumerate(STATE_CHUNK_FUNCTIONS):
                    name = names[function]
                    declarations.append(f'extern ExportFn {name};')
                    state_chunk_rows.append(f'{{"{name}", {name}, {references[function]}, '
                                            f'{mode}, {capacity}, {widths[function] * scale}}}')
                    state_chunk_host_configurations[name] = (
                        mode, capacity, widths[function] * scale)
                (work / f'{tag}_s{scale}.instrumented.ll').write_text(fixed)
                run([opt, '-passes=verify', '-disable-output'], input=fixed)
                compile_ir(f'{tag}_s{scale}', fixed)
                records.append(dict(record, vscale=scale, execution='host fixed-vscale, not RVV',
                                    comparison='exact original IR and independent nonchunked C oracle',
                                    probes='chunk entry/exit state, exact producer/global/local and consumer lanes'))


    # Unconditional acyclic producers across bounded chunks. This matrix is
    # additional to every inherited matrix. Scalar configurations execute too;
    # EVL remains uninstrumented RVV codegen-only evidence.
    cfg_chunk_rows = []
    cfg_chunk_host_configurations = {}
    source = (tests / 'reduction-fission-scalar-chunk-cfg.ll').read_text()
    reference, references = rename_execution_functions(
        source, {name: f'ref_{name}' for name in CFG_CHUNK_FUNCTIONS}, used_symbols)
    declarations.extend(export_reference_declarations(source, reference, references))
    compile_ir('reference_cfg_chunks', reference)
    for capacity, ceiling, size in ((1, 16, 16), (8, 111, 96), (9, 112, 112), (16, 192, 192)):
        for repeated, relaxed, kind in product((False, True), (False, True),
                                                ('scalar', 'tail', 'evl')):
            scalar, evl = kind == 'scalar', kind == 'evl'
            flags = [flag for flag in export_flags if not flag.startswith(
                ('-passes=', '-force-vector-width=', '-force-vector-interleave=',
                 '-scalable-vectorization='))]
            options = flags + [
                '-passes=' + 'loop-vectorize,' * (2 if repeated else 1) +
                'verify<domtree>,verify<loops>,verify<scalar-evolution>',
                f'-vplan-reduction-fission-max-scratch-bytes={ceiling}',
                '-force-vector-width=' + ('1' if scalar else '4'),
                '-force-vector-interleave=' + ('0' if scalar else '1'),
                '-scalable-vectorization=' + ('off' if scalar else 'always')]
            if scalar:
                options += ['-force-target-max-scalar-interleave=1']
            if relaxed:
                options += ['-vplan-reduction-fission-allow-fp-reordering']
            if kind == 'tail':
                options += ['-tail-folding-policy=dont-fold-tail',
                            '-enable-epilogue-vectorization=false']
            result = run([opt, *options], input=source)
            tag = (f'cfg_chunks_c{capacity}_lv{2 if repeated else 1}_'
                   f'{"reordered" if relaxed else "strict"}_{kind}')
            (work / f'{tag}.rvv.ll').write_text(result.stdout)
            (work / f'{tag}.remarks').write_text(result.stderr)
            assert result.stderr.count('split scalar-IR reduction loop;') == 4, result.stderr
            instrumented, widths = result.stdout, {}
            for name in CFG_CHUNK_FUNCTIONS:
                body = function_definition(result.stdout, name)
                vectorized = bool(re.search(r'^vector\.body[\w.$-]*:', body, re.M))
                assert vectorized or scalar or capacity == 1, body
                actual_widths = set(map(int, re.findall(
                    r'<vscale x (\d+) x (?:i32|double)>', body)))
                assert actual_widths == ({4} if vectorized else set()), (name, actual_widths)
                widths[name] = next(iter(actual_widths)) if vectorized else 0
                check_state_chunk_remarks(result.stderr, name, capacity, size, vectorized)
                checked = check_state_chunk(result.stdout, source, name, capacity,
                                            scalar=scalar, evl=evl, probe=not evl)
                instrumented = instrumented.replace(body, checked, 1)
            run([llc, '-mtriple=riscv64', '-mattr=+v', '-verify-machineinstrs',
                 '-o', str(work / f'{tag}.s')], input=result.stdout)
            record = dict(fixture='scalar-chunk-cfg', capacity=capacity, scratch_bytes=size, scratch_ceiling=ceiling,
                          selection_remarks=result.stderr,
                          options=options, policy='reordered' if relaxed else 'strict',
                          lv_invocations=2 if repeated else 1, kind=kind,
                          producer_vf=1, consumer_vfs=widths, producer_carries=[3, 3, 3, 3],
                          observed_consumer_vfs={name: f'vscale x {vf}' if vf else '1'
                                                 for name, vf in widths.items()},
                          logical_store_bytes_per_iteration=12, logical_load_bytes_per_iteration=12,
                          rereads=0, duplicated_operations=0, added_runtime_guards=0,
                          schedule_controls='per-chunk min/select, producer/consumer latches, continuation')
            if evl:
                records.append(dict(record, executed=False,
                                    validation='uninstrumented RVV machine verification; no target execution'))
                continue
            instrumented += (
                '\ndeclare void @record_state_chunk_begin(i64, i64, i32, i32, double)\n'
                'declare void @record_state_chunk_end(i32, i32, i32, double, double)\n'
                'declare void @record_state_chunk_producer(i64, i64)\n'
                'declare void @record_state_chunk_cfg_store(i64, i64, i32, double, ptr, ptr)\n'
                'declare void @record_state_chunk_cfg_branch(i32)\n'
                'declare void @record_chunk_vector()\n'
                'declare void @record_chunk_tail()\n')
            # Validate the actual instrumented scalable module before host
            # adaptation. Verification is distinct from compilation/execution.
            run([opt, '-passes=verify', '-disable-output'], input=instrumented)
            (work / f'{tag}.instrumented.ll').write_text(instrumented)
            for scale in ((1,) if scalar else args.vscales):
                fixed, names = rename_execution_functions(
                    specialize(instrumented, scale),
                    {name: f'{name}_{tag}_s{scale}' for name in CFG_CHUNK_FUNCTIONS}, used_symbols)
                for mode, function in enumerate(CFG_CHUNK_FUNCTIONS):
                    name = names[function]
                    declarations.append(f'extern ExportFn {name};')
                    cfg_chunk_rows.append(f'{{"{name}", {name}, {references[function]}, '
                                            f'{mode + 4}, {capacity}, {widths[function] * scale}}}')
                    cfg_chunk_host_configurations[name] = (
                        mode + 4, capacity, widths[function] * scale)
                (work / f'{tag}_s{scale}.instrumented.ll').write_text(fixed)
                run([opt, '-passes=verify', '-disable-output'], input=fixed)
                compile_ir(f'{tag}_s{scale}', fixed)
                records.append(dict(record, vscale=scale, execution='host fixed-vscale, not RVV',
                                    comparison='exact original IR and independent nonchunked C oracle',
                                    probes='chunk entry/exit state, exact producer/global/local and consumer lanes'))


    # Vectorizable AoS producer at the old dispatch scratch boundary. Keep
    # the entire inherited full-trip/exports/chunk matrices above intact.
    source = keep_functions((tests / 'reduction-fission-dispatch.ll').read_text(),
                            ['interleave2_ordered'])
    reference, references = rename_execution_functions(
        source, {'interleave2_ordered': 'ref_chunk_ordered'}, used_symbols)
    compile_ir('reference_aos_chunks', reference)
    scalar_options = [flag for flag in dispatch_common
                      if not flag.startswith(('-force-vector-interleave=', '-scalable-vectorization='))]
    scalar_options += ['-force-vector-width=1', '-force-vector-interleave=0',
                       '-force-target-max-scalar-interleave=1', '-scalable-vectorization=off',
                       '-vplan-reduction-fission-max-scratch-bytes=519']
    scalar = run([opt, *scalar_options], input=source)
    (work / 'aos_chunks.scalar.ll').write_text(scalar.stdout)
    check_aos_chunk_scalar(scalar.stdout)
    for repeated, relaxed, evl in product((False, True), (False, True), (False, True)):
        options = list(dispatch_common) + ['-vplan-reduction-fission-max-scratch-bytes=519']
        options[0] = ('-passes=' + 'loop-vectorize,' * (2 if repeated else 1) +
                      'verify<domtree>,verify<loops>,verify<scalar-evolution>')
        if relaxed:
            options += ['-vplan-reduction-fission-allow-fp-reordering']
        if not evl:
            options += ['-tail-folding-policy=dont-fold-tail', '-enable-epilogue-vectorization=false']
        result = run([opt, *options], input=source)
        tag = (f'aos_chunks_{"twice" if repeated else "once"}_'
               f'{"option_on" if relaxed else "ordered"}_{"evl" if evl else "tail"}')
        (work / f'{tag}.rvv.ll').write_text(result.stdout)
        (work / f'{tag}.remarks').write_text(result.stderr)
        assert result.stderr.count(': split ') == 1, result.stderr
        assert re.search(r'dispatch.c:30:5: split scalar-IR reduction loop;[^\n]*'
                         r'scratch capacity 64, scratch bytes 512, producer live-outs 0, '
                         r'chunked schedule, trip bound 65, scratch store bytes/iteration 8, '
                         r'scratch load bytes/iteration 8, producer reread bytes/iteration 0, '
                         r'duplicated producer instructions 0\b', result.stderr), result.stderr
        vfs = []
        for stage in ('producer', 'consumer'):
            match = re.search(rf'dispatch.c:30:5: scalar-IR fission {stage} VF '
                              r'vscale x ([1-9][0-9]*)\b', result.stderr)
            assert match, result.stderr
            vfs.append(int(match[1]))
        checked = check_aos_chunk(result.stdout, evl, *vfs, probe=not evl)
        run([llc, '-mtriple=riscv64', '-mattr=+v', '-verify-machineinstrs',
             '-o', str(work / f'{tag}.s')], input=result.stdout)
        record = dict(fixture='aos-chunks', capacity=64, allocated_bytes=512,
                      repeated_lv=repeated, fp_reordering_option=relaxed, stage_vfs=vfs,
                      options=options, selection_remarks=result.stderr)
        if evl:
            records.append(dict(record, executed=False, validation='uninstrumented RVV machine verification'))
            continue
        instrumented = result.stdout.replace(function_definition(result.stdout, 'interleave2_ordered'), checked, 1)
        instrumented += ('\ndeclare void @record_aos_chunk_begin(i64, i64, double, double)\n'
                         'declare void @record_aos_chunk_end(double, double)\n'
                         'declare void @record_aos_chunk_bypass()\n'
                         'declare void @record_aos_chunk_producer(ptr, ptr, ptr, i64, i32)\n'
                         'declare void @record_aos_chunk_consumer(ptr, ptr, i64, i32)\n')
        for scale in args.vscales:
            fixed, names = rename_execution_functions(
                specialize(instrumented, scale),
                {'interleave2_ordered': f'interleave2_ordered_{tag}_s{scale}'}, used_symbols)
            name = names['interleave2_ordered']
            declarations.append(f'extern ShortFPFn {name};')
            aos_chunk_rows.append(f'{{"{name}", {name}, {vfs[0] * scale}, {vfs[1] * scale}}}')
            compile_ir(f'{tag}_s{scale}', fixed)
            records.append(dict(record, vscale=scale, execution='host fixed-vscale, not RVV',
                                probes='actual chunk/carry, input-global and scratch-local addresses, '
                                       'producer/consumer vector and scalar lanes, zero-entry edge',
                                comparison='exact bits against original dispatch IR and independent nonchunked C'))

    # All three schedules in one module, through the real unspecialized LV
    # dispatch. References and variants use the same linked-symbol registry.
    functions = ('integration_affine', 'integration_cross_edge', 'integration_chunk')
    source = keep_functions((tests / 'reduction-fission-scalar-integration.ll').read_text(), functions)
    reference, references = rename_execution_functions(
        source, {function: f'ref_{function}' for function in functions}, used_symbols)
    compile_ir('reference_integration', reference)
    integration_host_configurations = {}
    # Preserve the inherited full-trip matrix, then execute the newly admitted
    # cross-edge chunk path at the first byte below its full-trip allocation.
    for ceiling, repeated, relaxed, evl in product((260, 259), (False, True),
                                                  (False, True), (False, True)):
        capacity = ceiling // 4
        selected = functions if ceiling == 260 else functions[1:]
        candidate = keep_functions(source, selected)
        options = export_flags + [
            '-passes=' + 'loop-vectorize,' * (2 if repeated else 1) +
            'verify<domtree>,verify<loops>,verify<scalar-evolution>',
            f'-vplan-reduction-fission-max-scratch-bytes={ceiling}']
        if relaxed:
            options += ['-vplan-reduction-fission-allow-fp-reordering']
        if not evl:
            options += ['-tail-folding-policy=dont-fold-tail', '-enable-epilogue-vectorization=false']
        result = run([opt, *options], input=candidate)
        tag = f'integration-c{capacity}-lv{2 if repeated else 1}-{"reordered" if relaxed else "strict"}-{"evl" if evl else "tail"}'
        (work / f'{tag}.rvv.ll').write_text(result.stdout)
        (work / f'{tag}.remarks').write_text(result.stderr)
        assert result.stderr.count('split scalar-IR reduction loop;') == len(selected), result.stderr
        instrumented = result.stdout
        for function in selected:
            checked = check_integration(result.stdout, source, function, evl, probe=not evl, capacity=capacity)
            instrumented = instrumented.replace(function_definition(result.stdout, function), checked, 1)
        run([llc, '-mtriple=riscv64', '-mattr=+v', '-verify-machineinstrs',
             '-o', str(work / f'{tag}.s')], input=result.stdout)
        record = dict(fixture='scalar-integration', repeated_lv=repeated,
                      fp_reordering_option=relaxed, options=options,
                      selection_remarks=result.stderr, capacity=capacity, scratch_bytes=4 * capacity,
                      scratch_ceiling=ceiling, logical_store_bytes_per_iteration=4,
                      logical_load_bytes_per_iteration=4, rereads=0, duplicated_operations=0)
        if evl:
            records.append(dict(record, executed=False, validation='uninstrumented RVV machine verification'))
            continue
        instrumented += ('\ndeclare void @record_acyclic_iteration()\n'
                         'declare void @record_acyclic_latch()\n'
                         'declare void @record_scalar_consumer_vector()\n'
                         'declare void @record_scalar_consumer_tail()\n'
                         'declare void @record_chunk_begin(i64, i64)\n'
                         'declare void @record_chunk_producer(i64, i64)\n'
                         'declare void @record_chunk_vector()\n'
                         'declare void @record_chunk_tail()\n'
                         'declare void @record_chunk_end()\n')
        run([opt, '-passes=verify', '-disable-output'], input=instrumented)
        for scale in args.vscales:
            fixed, names = rename_execution_functions(
                specialize(instrumented, scale),
                {function: f'{function}-{tag}-s{scale}' for function in selected}, used_symbols)
            for function in selected:
                mode = functions.index(function)
                chunk_capacity = capacity if mode == 2 or (mode == 1 and capacity < 65) else 0
                name, ref = names[function], references[function]
                declarations.append(f'extern ScalarSumFn {name}, {ref};')
                integration_rows.append(f'{{"{name}", {name}, {ref}, {mode}, {4 * scale}, {chunk_capacity}}}')
                integration_host_configurations[name] = (mode, chunk_capacity, 4 * scale)
            run([opt, '-passes=verify', '-disable-output'], input=fixed)
            compile_ir(f'{tag}_s{scale}', fixed)
            records.append(dict(record, vscale=scale, execution='host fixed-vscale, not RVV',
                                comparison='original IR/transformed/independent C; exact counts, aliases and canaries'))


    # Producer-local recurrences use one focused fixture matrix. Certificates
    # inspect actual opt output before adding any host-only probes.
    recurrence_flags = [flag for flag in common if flag != '-enable-scalar-reduction-fission=false']
    recurrence_flags += ['-force-vector-width=4', '-scalable-vectorization=always']
    recurrence_rows = []
    compact_recurrence_rows = []
    for compact, fixture, recurrence_cases in [
            (False, 'scalar-recurrence', RECURRENCE_CASES),
            (True, 'scalar-compact-recurrence',
             [(name, cap, True, conditional, nested, line, size)
              for name, cap, conditional, nested, line, size in COMPACT_RECURRENCE_CASES])]:
        recurrence_source = (tests / f'reduction-fission-{fixture}.ll').read_text()
        reference, references = rename_execution_functions(
            recurrence_source, {name: f'ref_{name}' for name, *_ in recurrence_cases}, used_symbols)
        compile_ir('reference_' + fixture.replace('-', '_'), reference)
        declarations.extend(f'extern RecurrenceFn {value};' for value in references.values())
        for boundary in (False, True):
            cases = [case for case in recurrence_cases if (case[1] != 65) == boundary]
            source = keep_functions(recurrence_source, [case[0] for case in cases])
            for relaxed in (False, True):
                for repeats in (1, 2):
                    for mode in (('scalar',) if boundary else
                                 ('evl', 'tail', 'scalar') if compact else ('evl', 'tail')):
                        evl, vectorized = mode == 'evl', mode != 'scalar'
                        options = list(recurrence_flags)
                        if not vectorized:
                            options = [option for option in options if option not in (
                                '-force-vector-width=4', '-scalable-vectorization=always',
                                '-force-vector-interleave=1')]
                            options += ['-force-vector-width=1', '-force-vector-interleave=0',
                                        '-force-target-max-scalar-interleave=1',
                                        '-scalable-vectorization=off']
                        if relaxed:
                            options += ['-vplan-reduction-fission-allow-fp-reordering']
                        if repeats == 2:
                            options = [option.replace('-passes=loop-vectorize,',
                                                       '-passes=loop-vectorize,loop-vectorize,')
                                       for option in options]
                        if mode == 'tail':
                            options += ['-tail-folding-policy=dont-fold-tail',
                                        '-enable-epilogue-vectorization=false']
                        result = run([opt, *options], input=source)
                        tag = ((fixture.replace('-', '_') if compact else 'recurrence') + '_' +
                               ('bounds' if boundary else mode) +
                               f'_{"option_on" if relaxed else "ordered"}_lv{repeats}')
                        (work / f'{tag}.remarks').write_text(result.stderr)
                        (work / f'{tag}.rvv.ll').write_text(result.stdout)
                        assert result.stderr.count('split scalar-IR reduction loop;') == len(cases), result.stderr
                        instrumented = result.stdout
                        for name, capacity, two, branch, nested, line, size in cases:
                            check_recurrence_remarks(result.stderr, name, capacity, size,
                                                     line, vectorized=vectorized,
                                                     source_file=fixture + '.c')
                            checked = check_recurrence_function(
                                result.stdout, source, name, evl, vectorized=vectorized,
                                probe=not evl, capacity=capacity, compact=compact)
                            body = function_definition(result.stdout, name)
                            instrumented = instrumented.replace(body, checked, 1)
                        # Codegen uses the uninstrumented original target module.
                        run([llc, '-mtriple=riscv64', '-mattr=+v', '-verify-machineinstrs',
                             '-o', str(work / f'{tag}.s')], input=result.stdout)
                        if not evl:
                            instrumented += ('\ndeclare void @record_acyclic_iteration()\n'
                                             'declare void @record_acyclic_latch()\n'
                                             'declare void @record_scalar_consumer_tail()\n')
                            if vectorized:
                                instrumented += 'declare void @record_scalar_consumer_vector()\n'
                            if compact:
                                instrumented += 'declare void @record_compact_participant()\n'
                            for scale in (args.vscales if vectorized else [1]):
                                fixed, names = rename_execution_functions(
                                    specialize(instrumented, scale),
                                    {name: f'{name}_{tag}_s{scale}' for name, *_ in cases}, used_symbols)
                                for name, capacity, two, branch, nested, line, size in cases:
                                    symbol = names[name]
                                    declarations.append(f'extern RecurrenceFn {symbol};')
                                    if compact:
                                        compact_recurrence_rows.append(
                                            f'{{"{symbol}", {symbol}, {references[name]}, {capacity}, '
                                            f'{4 * scale if vectorized else 0}, '
                                            f'{str(branch).lower()}, {str(nested).lower()}, '
                                            f'{str(name == "compact_recurrence_reverse").lower()}}}')
                                    else:
                                        recurrence_rows.append(
                                            f'{{"{symbol}", {symbol}, {references[name]}, {capacity}, '
                                            f'{0 if boundary else 4 * scale}, {str(two).lower()}, '
                                            f'{str(branch).lower()}, {str(nested).lower()}}}')
                                compile_ir(f'{tag}_s{scale}', fixed)
                        records.append({'fixture': fixture, 'boundary': boundary,
                                        'fp_reordering_option': relaxed,
                                        'loop_vectorize_invocations': repeats, 'evl': evl,
                                        'consumer_path': mode, 'compact': compact,
                                        'executed': not evl, 'options': options,
                                        'selection_remarks': result.stderr,
                                        'comparison': 'original IR / transformed / independent recurrence; '
                                                      'ordered FP and integer; exact N, vector/tail visits; '
                                                      'enclosing carry, aliases, canaries and scratch reuse'})
                        print(f'Validated recurrence artifact {tag}; host execution pending link', flush=True)

    # Execute the exact historical rejection, without changing its IR/interface.
    delay_rows = []
    delay_source = (tests / 'reduction-fission-scalar-recurrence-compact-legacy.ll').read_text()
    reference, references = rename_execution_functions(
        delay_source, {'recurrence_compact': 'ref_recurrence_compact'}, used_symbols)
    compile_ir('reference_compact_delay', reference)
    declarations.append('extern CompactDelayFn ref_recurrence_compact;')
    for relaxed in (False, True):
        for repeats in (1, 2):
            for mode in ('scalar', 'tail', 'evl'):
                vectorized, evl = mode != 'scalar', mode == 'evl'
                options = list(recurrence_flags)
                if not vectorized:
                    options = [option for option in options if option not in (
                        '-force-vector-width=4', '-scalable-vectorization=always',
                        '-force-vector-interleave=1')]
                    options += ['-force-vector-width=1', '-force-vector-interleave=0',
                                '-force-target-max-scalar-interleave=1', '-scalable-vectorization=off']
                if relaxed:
                    options += ['-vplan-reduction-fission-allow-fp-reordering']
                if repeats == 2:
                    options = [option.replace('-passes=loop-vectorize,',
                                               '-passes=loop-vectorize,loop-vectorize,') for option in options]
                if mode == 'tail':
                    options += ['-tail-folding-policy=dont-fold-tail', '-enable-epilogue-vectorization=false']
                result = run([opt, *options], input=delay_source)
                tag = f'compact_delay_{mode}_option_{int(relaxed)}_lv{repeats}'
                (work / f'{tag}.rvv.ll').write_text(result.stdout)
                (work / f'{tag}.remarks').write_text(result.stderr)
                check_recurrence_remarks(result.stderr, 'recurrence_compact', 65, 260, 12,
                                         vectorized=vectorized)
                checked = check_compact_delay_function(result.stdout, delay_source, evl,
                                                       vectorized, probe=not evl)
                run([llc, '-mtriple=riscv64', '-mattr=+v', '-verify-machineinstrs',
                     '-o', str(work / f'{tag}.s')], input=result.stdout)
                if not evl:
                    body = function_definition(result.stdout, 'recurrence_compact')
                    instrumented = result.stdout.replace(body, checked, 1)
                    for recorder in ['acyclic_iteration', 'acyclic_latch', 'compact_participant',
                                     'scalar_consumer_tail'] + (['scalar_consumer_vector'] if vectorized else []):
                        instrumented += f'\ndeclare void @record_{recorder}()\n'
                    for scale in (args.vscales if vectorized else [1]):
                        fixed, names = rename_execution_functions(
                            specialize(instrumented, scale),
                            {'recurrence_compact': f'recurrence_compact_{tag}_s{scale}'}, used_symbols)
                        symbol = names['recurrence_compact']
                        declarations.append(f'extern CompactDelayFn {symbol};')
                        delay_rows.append(f'{{"{symbol}", {symbol}, ref_recurrence_compact, '
                                          f'{4 * scale if vectorized else 0}}}')
                        compile_ir(f'{tag}_s{scale}', fixed)
                records.append({'fixture': 'scalar-recurrence-compact-legacy', 'options': options,
                                'fp_reordering_option': relaxed, 'loop_vectorize_invocations': repeats,
                                'evl': evl, 'executed': not evl, 'selection_remarks': result.stderr})

    cross_rows = []
    cross_name = 'reject_compact_cross_reduction'
    cross_source = keep_functions((tests / 'reduction-fission-scalar-compact-reject.ll').read_text(),
                                  [cross_name])
    reference, references = rename_execution_functions(
        cross_source, {cross_name: 'ref_' + cross_name}, used_symbols)
    compile_ir('reference_cross_retention', reference)
    for relaxed, repeats in product((False, True), (1, 2)):
        options = [flag for flag in recurrence_flags if not flag.startswith('-passes=')]
        options += ['-passes=' + 'loop-vectorize,' * repeats +
                    'verify<domtree>,verify<loops>,verify<scalar-evolution>',
                    '-tail-folding-policy=dont-fold-tail', '-enable-epilogue-vectorization=false']
        if relaxed:
            options += ['-vplan-reduction-fission-allow-fp-reordering']
        result = run([opt, *options], input=cross_source)
        tag = f'cross_retention_option_{int(relaxed)}_lv{repeats}'
        (work / f'{tag}.rvv.ll').write_text(result.stdout)
        (work / f'{tag}.remarks').write_text(result.stderr)
        body = function_definition(result.stdout, cross_name)
        producer, consumer = scalar_consumer(body, cross_name)
        assert '%sum = phi i32' in producer and '%sum.consume = phi ' not in body, body
        assert producer.count('store i32 %sum,') == 1, body
        assert body.count('alloca [65 x i32]') == 1, body
        assert result.stderr.count('split scalar-IR reduction loop;') == 1, result.stderr
        run([llc, '-mtriple=riscv64', '-mattr=+v', '-verify-machineinstrs',
             '-o', str(work / f'{tag}.s')], input=result.stdout)
        for scale in args.vscales:
            fixed, names = rename_execution_functions(
                specialize(result.stdout, scale), {cross_name: f'{cross_name}_{tag}_s{scale}'}, used_symbols)
            symbol, ref = names[cross_name], references[cross_name]
            declarations.append(f'extern CompactDelayFn {symbol}, {ref};')
            cross_rows.append(f'{{"{symbol}", {symbol}, {ref}}}')
            compile_ir(f'{tag}_s{scale}', fixed)
        records.append(dict(fixture=cross_name, options=options, selection_remarks=result.stderr,
                            repeated_lv=repeats, fp_reordering_option=relaxed,
                            contract='observed sum retained; closed dead sum2 only extracted'))

    retained_export_rows = []
    for compact in (False, True):
        cases = [(name, mode) for name, mode in RETAINED_EXPORT_CASES if (mode >= 7) == compact]
        fixture = 'scalar-compact-recurrence-reject' if compact else 'scalar-recurrence-reject'
        source = keep_functions((tests / f'reduction-fission-{fixture}.ll').read_text(),
                                [name for name, _ in cases])
        reference, references = rename_execution_functions(
            source, {name: f'ref_{name}' for name, _ in cases}, used_symbols)
        compile_ir('reference_retained_' + fixture, reference)
        for relaxed, repeats, mode in product((False, True), (1, 2), ('scalar', 'tail', 'evl')):
            evl, vectorized = mode == 'evl', mode != 'scalar'
            options = [flag for flag in recurrence_flags if not flag.startswith('-passes=')]
            options += ['-passes=' + 'loop-vectorize,' * repeats +
                        'verify<domtree>,verify<loops>,verify<scalar-evolution>']
            if not vectorized:
                options = [flag for flag in options if not flag.startswith(
                    ('-force-vector-width=', '-force-vector-interleave=', '-scalable-vectorization='))]
                options += ['-force-vector-width=1', '-force-vector-interleave=0',
                            '-force-target-max-scalar-interleave=1', '-scalable-vectorization=off']
            if relaxed:
                options += ['-vplan-reduction-fission-allow-fp-reordering']
            if mode == 'tail':
                options += ['-tail-folding-policy=dont-fold-tail', '-enable-epilogue-vectorization=false']
            result = run([opt, *options], input=source)
            tag = f'retained_exports_{int(compact)}_{mode}_option_{int(relaxed)}_lv{repeats}'
            (work / f'{tag}.rvv.ll').write_text(result.stdout)
            (work / f'{tag}.remarks').write_text(result.stderr)
            assert result.stderr.count('split scalar-IR reduction loop;') == len(cases), result.stderr
            loc = 'scalar-compact-recurrence.c' if compact else 'scalar-recurrence.c'
            assert len(re.findall(re.escape(loc + ':12:3: split scalar-IR reduction loop;') +
                                  r'[^\n]*scratch capacity 65, scratch bytes 784\b',
                                  result.stderr)) == (1 if compact else len(cases)), result.stderr
            if compact:
                for line in (22, 32, 42):
                    assert f'{loc}:{line}:3: split scalar-IR reduction loop;' in result.stderr, result.stderr
            for stage, vf in [('producer', '1'), ('consumer', 'vscale x 4' if vectorized else '1')]:
                for line in ((12,22,32,42) if compact else (12,)):
                    stage_pattern = re.escape(f'{loc}:{line}:3: scalar-IR fission {stage} VF {vf}') + r'\b'
                    assert len(re.findall(stage_pattern, result.stderr)) >= (1 if compact else len(cases)), result.stderr
            instrumented = result.stdout
            for name, kind in cases:
                checked = check_retained_export(result.stdout, source, name, kind,
                                                 vectorized, evl, probe=not evl)
                instrumented = instrumented.replace(function_definition(result.stdout, name), checked, 1)
            run([llc, '-mtriple=riscv64', '-mattr=+v', '-verify-machineinstrs',
                 '-o', str(work / f'{tag}.s')], input=result.stdout)
            if not evl:
                instrumented += ('\ndeclare void @record_acyclic_iteration()\n'
                                 'declare void @record_acyclic_latch()\n'
                                 'declare void @record_scalar_consumer_tail()\n'
                                 'declare void @record_scalar_consumer_vector()\n')
                for scale in (args.vscales if vectorized else [1]):
                    fixed, names = rename_execution_functions(
                        specialize(instrumented, scale),
                        {name: f'{name}_{tag}_s{scale}' for name, _ in cases}, used_symbols)
                    for name, kind in cases:
                        symbol, ref = names[name], references[name]
                        declarations.append(f'extern RecurrenceFn {symbol}, {ref};')
                        retained_export_rows.append(f'{{"{symbol}", {symbol}, {ref}, {kind}, '
                                                    f'{4 * scale if vectorized else 0}}}')
                    compile_ir(f'{tag}_s{scale}', fixed)
            records.append(dict(fixture=fixture, options=options, selection_remarks=result.stderr,
                                fp_reordering_option=relaxed, repeated_lv=repeats,
                                execution='host fixed-vscale' if not evl else 'RVV machine verification only',
                                functions=[name for name, _ in cases], scratch_bytes=784,
                                address_feedback_domain='N=0/1 and entry bypass only; original R0 GEP unbounded'))

    # Noncanonical bounded fallback: original control, actual IV/state carries,
    # completed counts and compact participation are independently certified.
    nc_chunk_rows = []
    nc_configurations = set()
    nc_source = (tests / 'reduction-fission-scalar-affine-chunks.ll').read_text()
    reference, references = rename_execution_functions(
        nc_source, {name: f'ref_{name}' for name in NC_CHUNK_FUNCTIONS}, used_symbols)
    compile_ir('reference_nc_chunks', reference)
    for (capacity, ceiling), repeats, relaxed, kind in product(
            ((1, 16), (8, 111), (9, 112), (16, 192)), (1, 2), (False, True),
            ('scalar', 'tail', 'evl')):
        scalar, evl = kind == 'scalar', kind == 'evl'
        names = NC_CHUNK_FUNCTIONS if scalar else NC_CHUNK_FUNCTIONS[:-1]
        source = keep_functions(nc_source, names)
        options = ['-mtriple=riscv64', '-mattr=+v', '-verify-each',
                   '-enable-vplan-reduction-fission', '-hints-allow-reordering=false',
                   '-pass-remarks=vplan-reduction-fission', '-pass-remarks-missed=vplan-reduction-fission',
                   '-passes=' + 'loop-vectorize,' * repeats +
                   'verify<domtree>,verify<loops>,verify<scalar-evolution>',
                   f'-vplan-reduction-fission-max-scratch-bytes={ceiling}',
                   '-force-vector-width=' + ('1' if scalar else '4'),
                   '-force-vector-interleave=' + ('0' if scalar else '1'),
                   '-scalable-vectorization=' + ('off' if scalar else 'always'), '-S']
        if scalar:
            options += ['-force-target-max-scalar-interleave=1']
        if relaxed:
            options += ['-vplan-reduction-fission-allow-fp-reordering']
        if kind == 'tail':
            options += ['-tail-folding-policy=dont-fold-tail', '-enable-epilogue-vectorization=false']
        result = run([opt, *options], input=source)
        tag = f'nc_c{capacity}_lv{repeats}_{"reordered" if relaxed else "strict"}_{kind}'
        (work / f'{tag}.rvv.ll').write_text(result.stdout)
        (work / f'{tag}.remarks').write_text(result.stderr)
        instrumented, widths = result.stdout, {}
        size = (4 * capacity + 7) // 8 * 8 + 8 * capacity
        for name in names:
            body = function_definition(result.stdout, name)
            vector = bool(re.search(r'^vector\.body[-\w.$]*:', body, re.M))
            assert vector or scalar or capacity == 1, body
            widths[name] = 4 if vector else 0
            line = 12 + 10 * NC_CHUNK_FUNCTIONS.index(name)
            loc = f'scalar-affine-chunks.c:{line}:3: '
            assert re.search(re.escape(loc) + r'split scalar-IR reduction loop;[^\n]*' +
                             f'scratch capacity {capacity}, scratch bytes {size},[^\n]*chunked schedule', result.stderr), result.stderr
            for stage, vf in [('producer', '1'), ('consumer', 'vscale x 4' if vector else '1')]:
                assert loc + f'scalar-IR fission {stage} VF {vf}' in result.stderr, result.stderr
            assert 'scratch store bytes/iteration 12, scratch load bytes/iteration 12, ' in result.stderr, result.stderr
            assert ('producer reread bytes/iteration 0, duplicated producer instructions 0, producer state carries 3'
                    in result.stderr), result.stderr
            checked = check_noncanonical_chunk(result.stdout, source, name, capacity, evl, probe=not evl)
            instrumented = instrumented.replace(body, checked, 1)
        run([llc, '-mtriple=riscv64', '-mattr=+v', '-verify-machineinstrs',
             '-o', work / f'{tag}.s'], input=result.stdout)
        records.append(dict(fixture='scalar-affine-chunks', capacity=capacity, padded_bytes=size,
                            options=options, policy='reordered' if relaxed else 'strict',
                            lv_invocations=repeats, kind=kind, selection_remarks=result.stderr,
                            producer_vf=1, consumer_vfs=widths, private_count_freeze=True,
                            logical_store_bytes_per_iteration=12, logical_load_bytes_per_iteration=12,
                            execution='RVV machine verification only' if evl else 'host fixed-vscale',
                            equality_witness_is_count=False, endpoint_arithmetic=False,
                            traffic_per_participant=24, rereads=0, duplicated_operations=0))
        if evl:
            continue
        instrumented += ('\ndeclare void @record_nc_begin(i64, i32, i32, double)\n'
                         'declare void @record_nc_iteration(i64, i64, i64, i64, i32, i32, i32, i32, double, double)\n'
                         'declare void @record_nc_store(i64, i64, i32, double, ptr, ptr)\n'
                         'declare void @record_nc_consume(i64, i64, ptr, ptr, i32)\n'
                         'declare void @record_nc_end(i64, i32, i64)\n')
        run([opt, '-passes=verify', '-disable-output'], input=instrumented)
        (work / f'{tag}.instrumented.ll').write_text(instrumented)
        for scale in ([1] if scalar else args.vscales):
            fixed, renamed = rename_execution_functions(specialize(instrumented, scale),
                {name: f'{name}_{tag}_s{scale}' for name in names}, used_symbols)
            run([opt, '-passes=verify', '-disable-output'], input=fixed)
            compile_ir(f'{tag}_s{scale}', fixed)
            for name in names:
                symbol = renamed[name]
                declarations.append(f'extern NCChunkFn {symbol}, {references[name]};')
                nc_chunk_rows.append(f'{{"{symbol}", {symbol}, {references[name]}, '
                                     f'{NC_CHUNK_FUNCTIONS.index(name)}, {capacity}, {widths[name] * scale}}}')
                nc_configurations.add(symbol)

    nc_offset_rows, nc_reverse_rows = [], []
    historical_names = ('chunk_noncanonical', 'chunk_reverse_equality')
    historical = keep_functions((tests / 'reduction-fission-scalar-chunks-reject.ll').read_text(), historical_names)
    reference, references = rename_execution_functions(historical,
        {name: f'ref_{name}' for name in historical_names}, used_symbols)
    compile_ir('reference_nc_historical', reference)
    for repeats, relaxed in product((1, 2), (False, True)):
        options = ['-mtriple=riscv64', '-mattr=+v', '-verify-each', '-enable-vplan-reduction-fission',
                   '-passes=' + 'loop-vectorize,' * repeats +
                   'verify<domtree>,verify<loops>,verify<scalar-evolution>',
                   '-force-vector-width=1', '-force-vector-interleave=0',
                   '-force-target-max-scalar-interleave=1', '-scalable-vectorization=off',
                   '-vplan-reduction-fission-max-scratch-bytes=4', '-S']
        if relaxed:
            options += ['-vplan-reduction-fission-allow-fp-reordering']
        result = run([opt, *options], input=historical)
        for name in historical_names:
            check_original_chunk_control(result.stdout, historical, name, 1)
        tag = f'nc_historical_lv{repeats}_{relaxed}'
        run([llc, '-mtriple=riscv64', '-mattr=+v', '-verify-machineinstrs', '-o', work / f'{tag}.s'], input=result.stdout)
        renamed, names = rename_execution_functions(result.stdout,
            {name: f'{name}_{tag}' for name in historical_names}, used_symbols)
        compile_ir(tag, renamed)
        for name, ty, rows in [('chunk_noncanonical', 'NCOffsetFn', nc_offset_rows),
                               ('chunk_reverse_equality', 'NCReverseFn', nc_reverse_rows)]:
            declarations.append(f'extern {ty} {names[name]}, {references[name]};')
            rows.append(f'{{{names[name]}, {references[name]}}}')

    harness = (root / 'llvm/utils/reduction-fission-execution.c.in').read_text()
    harness = harness.replace('@INTERLEAVE_MAX_FACTOR@',
                              str(max(case.factor for case in INTERLEAVE_FIXTURES)))
    harness = harness.replace('@INTERLEAVE_MAX_OUTPUTS@',
                              str(max(case.outputs for case in INTERLEAVE_FIXTURES)))
    harness = harness.replace('@ADAPTER_MAX_ELEMENTS@',
                              str(max(case['factor'] * case['lanes']
                                      for case in adapter_cases)))
    for key, rows in [('DECLARATIONS', declarations), ('COMBINED', combined_rows),
                      ('INDUCTIONS', induction_rows), ('FP', fp_rows),
                      ('SCALARS', scalar_rows), ('SCALAR_MIXED', mixed_rows),
                      ('SCALAR_CONSTANTS', constant_rows),
                      ('SCALAR_NESTED', nested_rows), ('SCALAR_DIAMOND', diamond_rows),
                      ('COMPACT', compact_rows), ('COMPACT_INTEGER', compact_integer_rows),
                      ('COMPACT_NESTED', compact_nested_rows),
                      ('RECURRENCES', recurrence_rows),
                      ('COMPACT_RECURRENCES', compact_recurrence_rows),
                      ('COMPACT_DELAYS', delay_rows),
                      ('RETAINED_EXPORTS', retained_export_rows),
                      ('CROSS_RETENTION', cross_rows),
                      ('INTEGRATION', integration_rows),
                      ('ACYCLIC', acyclic_rows),
                      ('ACYCLIC_BOUNDS', acyclic_bound_rows), ('AFFINE', affine_rows),
                      ('EXPORTS', export_rows),
                      ('CHUNKS', chunk_rows),
                      ('STATE_CHUNKS', state_chunk_rows + cfg_chunk_rows),
                      ('NC_CHUNKS', nc_chunk_rows),
                      ('NC_OFFSET', nc_offset_rows), ('NC_REVERSE', nc_reverse_rows),
                      ('COMPACT_CHUNKS', compact_chunk_rows),
                      ('AOS_CHUNKS', aos_chunk_rows),
                      ('SHORT_INT', short_int_rows), ('SHORT_FP', short_fp_rows),
                      ('FIXED_CALL', fixed_call_rows),
                      ('BOUNDED_CALL', bounded_call_rows),
                      ('ADAPTER', adapter_rows),
                      ('ADAPTER_POISON', [f'{{"{name}", {name}}}'
                                          for name in poison_cases]),
                      ('INTERLEAVE_INT', interleave_int_rows),
                      ('INTERLEAVE_FP', interleave_fp_rows)]:
        harness = harness.replace(f'@{key}@', '\n'.join(rows) if key == 'DECLARATIONS'
                                   else ',\n'.join(rows))
    harness_path = work / 'harness.c'
    harness_path.write_text(harness)
    executable = work / 'check'
    run([args.cc, '-std=c11', '-O2', '-ffp-contract=off', harness_path, *objects,
         '-lm', '-o', executable])
    result = run([executable])
    print(result.stdout, end='')
    nc_completed = {}
    for row in re.finditer(r'^Noncanonical chunks (\S+): comparisons=(\d+) vector=(\d+) '
                           r'tail=(\d+) empty=(\d+) full=(\d+) partial=(\d+) bypass=(\d+) early=(\d+)$', result.stdout, re.M):
        assert row[1] not in nc_completed and int(row[2]) == 3264, row[0]
        nc_completed[row[1]] = dict(zip(('comparisons', 'vector', 'tail', 'empty', 'full', 'partial', 'bypass', 'early'),
                                       map(int, row.groups()[1:])))
    assert set(nc_completed) == nc_configurations, (nc_completed.keys(), nc_configurations)
    all_state_chunk_execution = state_chunk_execution_counts(
        result.stdout, dict(state_chunk_host_configurations, **cfg_chunk_host_configurations))
    state_chunk_execution = {name: all_state_chunk_execution[name]
                             for name in state_chunk_host_configurations}
    cfg_chunk_execution = {name: all_state_chunk_execution[name]
                           for name in cfg_chunk_host_configurations}
    assert len(state_chunk_execution) == 48 * (1 + len(args.vscales))
    assert sum(row['comparisons'] for row in state_chunk_execution.values()) == (
        9792 * 12 * (1 + len(args.vscales)))
    assert len(cfg_chunk_execution) == 64 * (1 + len(args.vscales))
    assert sum(row['comparisons'] for row in cfg_chunk_execution.values()) == (
        69632 * (1 + len(args.vscales)))
    integration_execution = integration_execution_counts(result.stdout, integration_host_configurations)
    assert len(integration_execution) == 20 * len(args.vscales)
    assert sum(row['comparisons'] for row in integration_execution.values()) == 24000 * len(args.vscales)
    compact_chunk_execution = compact_chunk_execution_counts(
        result.stdout, compact_chunk_host_configurations)
    # Count completed input cases, each comparing all three implementations.
    # Scalar: 16 configurations per function, with 3*9792 + 29376 cases.
    # Per vector vscale: 16 configurations for each i64 function, with
    # 2*9792 + 29376 cases. Narrow consumers remain scalar-only here.
    compact_chunk_planned_configurations = 64 + 48 * len(args.vscales)
    compact_chunk_planned_comparisons = 940032 + 783360 * len(args.vscales)
    assert len(compact_chunk_execution) == compact_chunk_planned_configurations
    assert sum(row['comparisons'] for row in compact_chunk_execution.values()) == (
        compact_chunk_planned_comparisons)
    dispatch_execution = {}
    for match in re.finditer(r'^Dispatch (\S+): comparisons=(\d+) aliases=(\d+) bypasses=(\d+) '
                             r'producer-vector=(\d+) producer-tail=(\d+) '
                             r'consumer-vector=(\d+) consumer-tail=(\d+) '
                             r'producer-ordinary=(\d+) producer-ordinary-lanes=(\d+) '
                             r'consumer-ordinary=(\d+) consumer-ordinary-lanes=(\d+)$', result.stdout, re.M):
        name = match[1]
        assert name not in dispatch_execution, name
        dispatch_execution[name] = dict(zip(
            ('comparisons', 'aliases', 'bypasses', 'producer_vector', 'producer_tail',
             'consumer_vector', 'consumer_tail', 'producer_ordinary', 'producer_ordinary_lanes',
             'consumer_ordinary', 'consumer_ordinary_lanes'), map(int, match.groups()[1:])))
        # All N=0..66 plus inherited 257/1023/1024/1025, twenty trials;
        # N=2..65 also run once with output aliasing the input. These totals
        # come from the fixture domain, never from the observed stage probes.
        assert (dispatch_execution[name]['comparisons'], dispatch_execution[name]['aliases'],
                dispatch_execution[name]['bypasses']) == (1484, 64, 120), dispatch_execution[name]
    assert set(dispatch_execution) == dispatch_host_functions, dispatch_execution
    assert len(dispatch_execution) == 8 * len(args.vscales), dispatch_execution
    assert len(state_cfg_host_functions) == len(STATE_CFG_FUNCTIONS) * 4 * (len(args.vscales) + 1)
    state_cfg_execution = state_cfg_execution_counts(result.stdout, state_cfg_host_functions)
    (work / 'results.json').write_text(json.dumps({
        'execution': 'host fixed-vscale specialization (not RVV execution)',
        'host_triple': triple, 'cases': records, 'result': result.stdout,
        'dispatch_execution': dispatch_execution,
        'state_cfg_focused_execution': state_cfg_execution,
        'state_chunk_execution': state_chunk_execution,
        'cfg_chunk_execution': cfg_chunk_execution,
        'integration_execution': integration_execution,
        'noncanonical_chunk_execution': nc_completed,
        'cfg_chunks': {
            'functions': CFG_CHUNK_FUNCTIONS, 'capacities': [1, 8, 9, 16],
            'scratch_bytes': [16, 96, 112, 192], 'scratch_ceilings': [16, 111, 112, 192],
            'planned_configurations': 64 * (1 + len(args.vscales)),
            'planned_comparisons': 69632 * (1 + len(args.vscales)),
            'completed_configurations': len(cfg_chunk_execution),
            'completed_comparisons': sum(row['comparisons'] for row in cfg_chunk_execution.values()),
            'verification': 'instrumented scalable modules verified; uninstrumented RVV machine verified',
            'execution': 'actual original/transformed/independent C; scalar and fixed-vscale vector/tail',
            'rvv_execution': False, 'speedup_measurement': False,
            'policies': ['strict', 'explicit fission FP reordering only'], 'lv_invocations': [1, 2],
            'producer_carries': [3, 3, 3, 3], 'input_rereads': 0,
            'logical_store_bytes_per_iteration': 12, 'logical_load_bytes_per_iteration': 12,
            'checks': 'original branches/merges/guarded operations, simultaneous state, '
                      'current/next/IV exports, every local scratch store address/value, '
                      'actual vector/tail lanes, full/partial/one/zero/multiple chunks',
            'evl': 'uninstrumented RVV machine verification only',
        },
        'compact_chunk_execution': compact_chunk_execution,
        'compact_chunks': {
            'functions': COMPACT_CHUNK_FUNCTIONS, 'capacities': [1, 9, 16, 65],
            'scratch_bytes': [16, 112, 192, 784],
            'planned_configurations': compact_chunk_planned_configurations,
            'planned_comparisons': compact_chunk_planned_comparisons,
            'completed_configurations': len(compact_chunk_execution),
            'completed_comparisons': sum(c['comparisons'] for c in compact_chunk_execution.values()),
            'logical_store_bytes_per_participant': 12, 'logical_load_bytes_per_participant': 12,
            'rereads': 0, 'duplication': 0, 'empty_stream_guards': 1,
            'narrow': 'scalar execution and separate vector lit/codegen',
            'evl': 'RVV machine verification only',
        },
        'state_chunks': {
            'functions': STATE_CHUNK_FUNCTIONS, 'capacities': [1, 9, 16],
            'scratch_bytes': [16, 112, 192], 'producer_carries': [2, 3, 2, 3],
            'counts': list(range(67)) + [2**64 - 1],
            'rows': [0, 1, 2, 4, 5, 2**64 - 1],
            'planned_configurations': 48 + 48 * len(args.vscales),
            'planned_comparisons': 9792 * 12 * (1 + len(args.vscales)),
            'completed_configurations': len(state_chunk_execution),
            'completed_comparisons': sum(c['comparisons'] for c in state_chunk_execution.values()),
            'verification': 'instrumented scalable modules verified; uninstrumented RVV machine verified',
            'execution': 'original/transformed/independent C; scalar and fixed-vscale vector/tail, not RVV',
            'policies': ['strict', 'explicit fission FP reordering only'],
            'lv_invocations': [1, 2], 'input_rereads': 0,
            'logical_store_bytes_per_iteration': 12, 'logical_load_bytes_per_iteration': 12,
            'checks': 'per-chunk simultaneous carry and separate current/next state, exact stage '
                      'iterations, entries, full/partial chunks, row exports, aliases and canaries',
        },
        'coverage_mapping': {
            'vplan_head': '5829f993afeabaabca2dd8e728c5cc637a56ea13',
            'scalar_head': '16d3d9df9d01e0a24000ccf672293ddff87d1fde',
            'shared': 'combined, induction/negative_step/truncated and fp-reordering; '
                      'same isolated VPlan flags, references, FP contracts and vscales',
            'shared_scalar_counts': [0, 1, 2, 3, 7, 8, 15, 16, 17, 31, 32, 33,
                                     63, 64, 65, 257, 1023, 1024, 1025],
            'shared_vplan_counts_superset_additions': [4, 5, 9, 66],
            'default_vscales_expected': {
                'scalar_matrix': 227300, 'vplan_matrix': 351600,
                'shared_comparisons': 7800, 'inherited_union': 571100,
                'additional_dispatch': 127440, 'union_with_dispatch': 698540,
                'additional_isolated_dispatch': 19040,
                'union_with_dispatch_and_isolated': 717580,
                'additional_adapter': 1358,
            },
            'certified_dispatch_counts': list(range(67)) + [257, 1023, 1024, 1025],
            'certified_dispatch_planned_calls_per_configuration': 1484,
            'dispatch_count_expansion': 'default sum/XOR and ordered overlap only: 1008 additional '
                                        'comparisons per configuration; 60480 at default vscales. '
                                        'Isolated VPlan and all other inherited matrices unchanged.',
            'dispatch': 'two early retained-XOR/moved-add AoS splits, one ordered early AoS overlap, '
                        'one compact nest; single/repeated LV and both FP options; '
                        'all inherited N/P, aliases, canaries and probes retained',
            'reference_origins': {
                'interleave2': 'reduction-fission-interleave.ll:interleave2',
                'interleave3': 'reduction-fission-interleave.ll:interleave3',
                'interleave2_ordered': 'reduction-fission-interleave.ll:interleave2_ordered',
                'compact_nested': 'reduction-fission-scalar-compact.ll:compact_nested',
            },
        },
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
        'producer_exports': {
            'functions': EXPORT_FUNCTIONS, 'distinct_values': 6, 'exit_phi_edges': 7,
            'default_vscales': [1, 2, 4, 8, 32],
            'expected_additional_comparisons': 347760,
            'expected_total_with_inherited': 985820,
            'contracts': 'ordered FP under both fission options; no extra math/errno assumptions',
            'execution': 'single/repeated LV, host scalar remainder; RVV EVL separately machine verified',
            'checks': 'all exports/reductions against original IR and independent C; aliases, '
                      'outer final-value feedback, canaries, zero entry and P=0/1/N, all P at N=65, '
                      'last-inactive iterations, exact producer/consumer/tail/empty counters',
            'counts': 'additional comparisons and per-configuration path counters printed by C; '
                      'historical inherited totals describe standalone subsets; see coverage_mapping '
                      'for expanded default dispatch counts. Adapter counts are unchanged',
        },
        'producer_export_controls': {
            'functions': EXPORT_CONTROL_FUNCTIONS,
            'distinct_values': 6, 'exit_phi_edges': 7,
            'scratch_capacity': 65, 'scratch_bytes': 1044,
            'expected_additional_comparisons': 753480,
            'expected_export_comparisons_with_inherited': 1101240,
            'contracts': 'original/transformed/independent exact-bit mixed-type comparisons; '
                         'separate strict/reordered policies, single/repeated LV; no added FP flags',
            'execution': 'host fixed vscales 1/2/4/8/32 with vector and scalar-tail probes; '
                         'unmodified EVL and scalar-tail RVV modules machine verified separately',
            'checks': 'zero entry, N=1 and N=65, all P=0..65, current/next values, '
                      'positive/negative stride, serial/nested latch merges, duplicate users, '
                      'prefix/suffix/sparse participation, final inactive iteration, '
                      'enclosing-loop exports, scratch reuse and aliases',
            'count_certificate': 'original producer preservation plus exhaustive N=1..65,row=0..3 '
                                 'integer control/count evaluation; at most 32 dependency levels '
                                 'and 128 operand evaluations per expression; '
                                 'compact P uses the existing exact typed count/result certificate',
        },
        'compact_cfg': {
            'functions': COMPACT_CFG_FUNCTIONS,
            'scratch_capacity': 65, 'padded_scratch_bytes': 1044,
            'scratch_store_bytes_per_participant': 16,
            'scratch_load_bytes_per_participant': 16,
            'input_rereads': 0, 'duplicated_producer_instructions': 0,
            'expected_additional_comparisons': 521640,
            'expected_export_comparisons_with_inherited': 1622880,
            'contracts': 'one terminal participation block; exact count/value on every '
                         'latch edge; compact store indices; original producer instructions '
                         'and branch polarity; ordered mixed reductions and empty starts; '
                         'exact final producer exports independent of participation',
            'execution': 'actual original/transformed IR and independent C; both fission '
                         'FP policies, once/twice LV, fixed host vscales 1/2/4/8/32; '
                         'uninstrumented EVL/tail RVV machine verification separately',
            'checks': 'N=0/1/65, all P=0..65, prefix/suffix/sparse and first/last-only '
                      'participation, final inactive iterations, exact per-edge bypass '
                      'counts, nonzero vector/tail/empty/entry-bypass evidence, aliases '
                      'and enclosing-loop scratch reuse; lanes>65 must execute no vector',
        },
        'state_cfg_interactions': {
            'functions': STATE_CFG_FUNCTIONS,
            'scratch_capacity': 65, 'padded_scratch_bytes': 1044,
            'scratch_store_bytes_per_participant': 16, 'scratch_load_bytes_per_participant': 16,
            'producer_exports': 7, 'retained_state_arrays': 0,
            'contracts': 'one common terminal reduction edge; retained state updates only on '
                         'one original bypass edge and affects participation/contributions; '
                         'final state/value exports independent of P; no retained-state chunking',
            'execution': 'original/transformed/independent C; strict/reordered, once/twice LV; '
                         'scalar consumers and vector/scalar tails at fixed host vscales 1/2/4/8/32; '
                         'uninstrumented EVL separately machine verified',
            'expected_additional_comparisons_at_default_vscales': 417312,
            'focused_participation': {
                'planned_comparisons_per_configuration': 28,
                'planned_comparisons_at_default_vscales': 2016,
                'N': 3, 'rows': [1, 2], 'starts': ['-0.0', '0.25'],
                'checks': 'seven literal original-fixture participation masks and final states, '
                          'including pattern=1 first/last-only and parity-disabled nonzero final input; '
                          'original/transformed/oracle whole-state comparisons, canaries and exact '
                          'N/P/vector/tail/empty/bypass/final-arm counters',
                'completed': 'see state_cfg_focused_execution; never inferred from generated variants',
            },
            'status': 'counts are planned until the generated C harness links and executes',
        },
        'retained_feedback_exports': {
            'functions': RETAINED_EXPORT_CASES,
            'cross_retention': 'reject_compact_cross_reduction',
            'scratch_capacity': 65, 'padded_scratch_bytes': 784,
            'contracts': 'observed state remains in producer; closed sums may consume its '
                         'values; original final exports and partial observable results preserved',
            'execution': 'original/transformed/independent formulas; both policies, once/twice LV, '
                         'scalar/vector/tail consumers and aliases; exact N/vector/tail probes',
            'address_feedback_limit': 'the exact original unbounded R0 address fixture is '
                                      'executed only for N=0/1 and entry bypass; bounded analogous '
                                      'state-dependent addresses remain covered by inherited matrices',
        },

        'acyclic_counts': list(range(66)) + [66, 2**64 - 1],
        'recurrence_counts': list(range(66)) + [66, 2**64 - 1],
        'recurrence_capacities': [1, 65, 255, 5461],
        'compact_recurrence_modes': ['empty', 'all', 'integer state sparse',
                                     'first only', 'last only', 'ordered FP state sparse'],
        'compact_recurrence_comparison': 'original IR / actual transformed scalar or vector/tail '
                                         '/ independent formulas; exact N and P, per-row counts '
                                         'including alias writes, retained PHIs/updates/flags/branches, '
                                         'ordered FP starts and operands, scratch types/indices, '
                                         'capacity boundaries and repeated LV; EVL machine verification only',
        'recurrence_comparison': 'original IR / actual transformed stages / independent formulas; '
                                 'integer bits and ordered non-NaN FP bits; retained state, '
                                 'scratch/count provenance, vector/tail/producer/latch visits; '
                                 'aliases, enclosing carry/reuse, canaries and repeated LV',
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
        'integration': {
            'functions': ['integration_affine', 'integration_cross_edge', 'integration_chunk'],
            'full_trip_capacity': 65, 'chunk_capacity': 65, 'scratch_bytes': 260,
            'new_comparisons_at_default_vscales': 72000,
            'checks': 'actual LV1/LV2, separate strict/reordered options, every N=0..66, '
                      '127/128/129/254/255/256/257/UINT64_MAX, wrapping integer seeds, '
                      'zero/nonzero/random inputs, original/transformed/independent C, aliases/canaries, '
                      'exact producer/latch/vector/tail and chunk ordering/local/global counts',
            'accounting': 'Historical expected_total_with_inherited fields above/below describe '
                          'their standalone subsets; the merged run additionally includes every '
                          'acyclic/affine row and this integration matrix. Retain all stdout totals.',
        },
        'bounded_chunks': {
            'functions': CHUNK_FUNCTIONS, 'capacities': [1, 9, 16],
            'allocated_bytes': [20, 148, 256],
            'trip_bounds': dict(zip(CHUNK_FUNCTIONS, (65, 255, 65, 65))),
            'expected_additional_comparisons': 313200,
            'expected_total_with_inherited': 1299020,
            'policies': 'ordinary ordered FP, independently with fission FP reordering off/on',
            'checks': 'N=0/1/C-1/C/C+1, complete chunks plus final partial, i8 global counts, '
                      'i8 N=127/128/129/254/255 and rejected 256, exact carried state and final exports, alias-sensitive enclosing rows; '
                      'actual chunk/local/global/vector/tail probes and original IR/independent C bits',
            'limits': 'host fixed-vscale execution only; EVL and RVV separately machine verified; '
                      'vector dynamic entries only when emitted lanes <= chunk capacity; no speedup measurement',
        },
        'vectorizable_producer_chunks': {
            'function': 'interleave2_ordered', 'source': 'dispatch.c:30:5',
            'capacity': 64, 'allocated_bytes': 512, 'limit': 519,
            'expected_additional_comparisons': 6400,
            'expected_total_with_inherited': 1305420,
            'contracts': 'ordered FP independently under both fission policy settings',
            'checks': 'original dispatch IR and independent nonchunked C, N=0/63/64/65, '
                      'actual chunk/carry/zero-entry/global-input/local-scratch probes, '
                      'exact per-chunk producer and consumer vector/tail visits, aliases and canaries',
            'limits': 'host scalar remainder only; uninstrumented RVV EVL and remainder machine verification separately',
        },
        'scalar_ir_default_evl': 'RVV codegen/machine verification only, not executed',
        'adapter': {
            'cases': adapter_cases, 'poison_probes': poison_cases,
            'trials_per_case': 8,
            'oracle': 'independent C scalar input[factor*lane+member] indexing; '
                      'bitwise comparisons, reversed repeated aggregate uses, '
                      'input preservation and output canaries',
            'scope': 'host lane adapter only; not RVV legality or execution',
        },
        'runtime_trip_counts': [0, 1, 2, 3, 4, 5, 7, 8, 9, 15, 16, 17, 31, 32,
                                33, 63, 64, 65, 66, 257, 1023, 1024, 1025],
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
