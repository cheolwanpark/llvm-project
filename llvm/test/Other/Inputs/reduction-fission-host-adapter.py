# Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
# See https://llvm.org/LICENSE.txt for license information.
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

"""Structural/rejection tests; executable scalar-index comparisons live in C."""

import argparse
import importlib.util
import re
import sys
import unittest
from itertools import product


def fixture(factor=5, lanes=2, element='i32'):
    code = {'float': 'f32', 'double': 'f64'}.get(element, element)
    wide = f'<{factor * lanes} x {element}>'
    member = f'<{lanes} x {element}>'
    result = '{ ' + ', '.join([member] * factor) + ' }'
    intrinsic = f'@llvm.vector.deinterleave{factor}.v{factor * lanes}{code}'
    return (f'define {result} @arbitrary_name({wide} %input) {{\n'
            f'  %parts = tail call {result} {intrinsic}({wide} %input)\n'
            f'  ret {result} %parts\n}}\n'
            f'declare {result} {intrinsic}({wide}) #7\n')


class AdapterTests(unittest.TestCase):
    def test_mixed_fixed_scalable_declarations(self):
        for operation, ty, code in (('fadd', 'double', 'f64'),
                                    ('mul', 'i32', 'i32'),
                                    ('smin', 'i64', 'i64')):
            prefix = ty + ', ' if operation == 'fadd' else ''
            scalable = (f'declare {ty} @llvm.vector.reduce.{operation}.nxv4{code}'
                        f'({prefix}<vscale x 4 x {ty}>) #2\n')
            fixed = scalable.replace('.nxv4', '.v4').replace('<vscale x 4 x ', '<4 x ')
            for source in (scalable + fixed, fixed + scalable):
                self.assertEqual(checker.specialize(source, 1), fixed)
                widened = checker.specialize(source, 2)
                self.assertEqual(widened.count('declare '), 2)
                self.assertIn(f'.v8{code}', widened)
                self.assertIn(f'.v4{code}', widened)
            with self.assertRaisesRegex(ValueError, 'duplicate intrinsic declaration'):
                checker.specialize(scalable + scalable, 1)
            with self.assertRaisesRegex(ValueError, 'duplicate intrinsic declaration'):
                checker.specialize(scalable + fixed + fixed, 1)
            with self.assertRaisesRegex(ValueError, 'incompatible specialized declarations'):
                checker.specialize(scalable + fixed.replace('#2', '#3'), 1)
            with self.assertRaisesRegex(ValueError, 'incompatible specialized declarations'):
                checker.specialize(scalable + fixed.replace('<4 x ', '<8 x '), 1)

    def test_factors_types_widths_and_boundary_lanes(self):
        for factor, lanes, element in product(
            range(2, 9), (1, 2, 3, 8, 128), ('i1', 'i8', 'i32', 'i64', 'float', 'double')
        ):
            with self.subTest(factor=factor, lanes=lanes, element=element):
                output = checker.lower_fixed_deinterleaves(fixture(factor, lanes, element))
                self.assertNotIn('@llvm.vector.deinterleave', output)
                self.assertEqual(output.count(' = shufflevector '), factor)
                self.assertEqual(output.count(' = insertvalue '), factor)
                masks = re.findall(r'poison, <\d+ x i32> <([^>]+)>', output)
                self.assertEqual(len(masks), factor)
                for member, mask in enumerate(masks):
                    indices = [int(x) for x in re.findall(r'i32 (\d+)', mask)]
                    self.assertEqual(len(indices), lanes)
                    self.assertEqual(indices[0], member)
                    self.assertEqual(indices[-1], factor * (lanes - 1) + member)
                    self.assertEqual(indices, list(range(member, factor * lanes, factor)))
                members = re.findall(r' = insertvalue .*?, (\d+)\n', output)
                self.assertEqual(members, [str(j) for j in range(factor)])
                self.assertIn('  %parts = insertvalue ', output)
                self.assertEqual(checker.lower_fixed_deinterleaves(output), output)

    def test_preserve_original_instructions_repeated_uses_and_debug(self):
        result = '{ <2 x i32>, <2 x i32> }'
        source = f'''define i32 @not_a_fixture(ptr %input, ptr %scratch) {{
entry:
  %host.deinterleave.0 = add i32 0, 1
  br label %host.deinterleave.1
host.deinterleave.1:
  %wide = load <4 x i32>, ptr %input, align 4
  %parts = call {result} @llvm.vector.deinterleave2.v4i32(<4 x i32> %wide), !dbg !7
  %a = extractvalue {result} %parts, 1
  %again = extractvalue {result} %parts, 1
  store <2 x i32> %a, ptr %scratch, align 4
  call void @fission_interleave_probe(i32 0)
  %x = extractelement <2 x i32> %again, i32 1
  ret i32 %x
}}
declare {result} @llvm.vector.deinterleave2.v4i32(<4 x i32>)
'''
        output = checker.lower_fixed_deinterleaves(source)
        for line in source.splitlines():
            if '@llvm.vector.deinterleave' not in line:
                self.assertIn(line + '\n', output)
        definitions = re.findall(r'^  (%host\.deinterleave\.\d+) =', output, re.M)
        self.assertEqual(len(definitions), len(set(definitions)))
        self.assertNotIn('%host.deinterleave.1 =', output)
        self.assertEqual(output.count(', !dbg !7'), 4)

    def test_poison_undef_and_zero(self):
        for operand in ('poison', 'undef', 'zeroinitializer'):
            source = fixture().replace('x i32> %input)', f'x i32> {operand})')
            # Change only the call operand, keeping the function parameter.
            source = source.replace(f'@arbitrary_name(<10 x i32> {operand})',
                                    '@arbitrary_name(<10 x i32> %input)')
            output = checker.lower_fixed_deinterleaves(source)
            self.assertEqual(output.count(f'shufflevector <10 x i32> {operand},'), 5)
            self.assertNotIn('freeze', output)
            self.assertNotIn('noundef', output)

    def test_quoted_and_escaped_temporary_collisions_elsewhere(self):
        source = fixture().replace('  %parts =',
                                  '  %"host.deinterleave.0" = add i32 0, 1\n'
                                  '  %"host\\2Edeinterleave\\2E1" = add i32 0, 1\n'
                                  '  %parts =')
        output = checker.lower_fixed_deinterleaves(source)
        self.assertNotIn('%host.deinterleave.0 =', output)
        self.assertNotIn('%host.deinterleave.1 =', output)
        self.assertIn('%host.deinterleave.2 = shufflevector', output)

    def test_duplicate_calls_share_declaration(self):
        source = fixture()
        invocation = next(line for line in source.splitlines() if 'tail call' in line)
        source = source.replace(invocation, invocation + '\n' +
                                invocation.replace('%parts =', '%other ='))
        output = checker.lower_fixed_deinterleaves(source)
        self.assertEqual(output.count(' = shufflevector '), 10)
        self.assertIn('%other = insertvalue', output)
        names = re.findall(r'(%host\.deinterleave\.\d+) =', output)
        self.assertEqual(len(names), len(set(names)))

    def test_multiple_intrinsic_signatures(self):
        source = fixture(2, 1, 'i32') + fixture(8, 3, 'double').replace(
            '@arbitrary_name(', '@another_name(')
        output = checker.lower_fixed_deinterleaves(source)
        self.assertEqual(output.count(' = shufflevector '), 10)
        self.assertIn('<24 x double>', output)
        self.assertIn('<2 x i32>', output)

    def test_specialize_before_lowering(self):
        source = fixture(3, 2, 'double')
        scalable = re.sub(r'<(\d+) x ', r'<vscale x \1 x ', source)
        scalable = scalable.replace('.v6f64', '.nxv6f64')
        with self.assertRaisesRegex(ValueError, 'deinterleave'):
            checker.lower_fixed_deinterleaves(scalable)
        for scale in (1, 2, 4, 8, 32):
            fixed = checker.specialize(scalable, scale)
            output = checker.lower_fixed_deinterleaves(fixed)
            self.assertIn(f'shufflevector <{6 * scale} x double>', output)
            self.assertIn(f'<{2 * scale} x i32>', output)
            self.assertNotIn('vscale', output)
            self.assertNotIn('@llvm.vector.deinterleave', output)

    def test_ir_without_calls_and_comments(self):
        source = '; @llvm.vector.deinterleave9.v0i32 is only a comment\n'
        self.assertEqual(checker.lower_fixed_deinterleaves(source), source)
        declaration = fixture().splitlines()[-1] + '\n'
        self.assertEqual(checker.lower_fixed_deinterleaves(declaration), '')

    def test_reject_malformed_or_unsupported_signatures(self):
        source = fixture()
        variants = [
            source.replace('deinterleave5', 'deinterleave1'),
            source.replace('deinterleave5', 'deinterleave9'),
            source.replace('.v10i32', '.nxv10i32'),
            source.replace('.v10i32', '.v0i32'),
            source.replace('.v10i32', '.v11i32'),
            source.replace('.v10i32', '.v10f64'),
            source.replace('<10 x i32>', '<15 x i32>'),
            source.replace('<2 x i32>', '<3 x i32>'),
            source.replace('tail call { <2 x i32>', 'tail call { <2 x i64>'),
            source.replace('v10i32', 'v2147483650i32'),
            source.replace(', <2 x i32> }', ' }'),
            source.replace('i32', 'ptr').replace('v10ptr', 'v10p0'),
            source.replace('i32', 'half').replace('v10half', 'v10f16'),
            source.replace('<10 x i32>', '<vscale x 10 x i32>'),
            source.replace('tail call', 'musttail call'),
            source.replace('tail call', 'call fastcc'),
            source.replace('tail call', 'invoke'),
            source.replace('<10 x i32> %input)', '<10 x i32> %input, i32 0)'),
            source.replace('x i32> %input)\n', 'x i32> %input) [ "deopt"() ]\n'),
            source.replace('x i32> %input)\n', 'x i32> %input), !unknown !0\n'),
            source.replace('x i32> %input)\n', 'x i32> noundef %input)\n'),
            source.replace('x i32> %input)\n', 'x i32> splat (i32 1))\n'),
            source.replace('x i32> %input)\n', 'x i32> %"quoted")\n'),
            source.replace('@llvm.vector.deinterleave5.v10i32',
                           '@"llvm.vector.deinterleave5.v10i32"'),
            '\n'.join(source.splitlines()[:-1]) + '\n',  # no declaration
            source + source.splitlines()[-1] + '\n',  # duplicate declaration
            source + '@escape = global ptr @llvm.vector.deinterleave5.v10i32\n',
            source.replace('declare ', 'define '),
            source.replace('declare {', 'declare\n{'),  # noncanonical form
        ]
        for invalid in variants:
            with self.subTest(invalid=invalid):
                with self.assertRaisesRegex(ValueError, 'deinterleave'):
                    checker.lower_fixed_deinterleaves(invalid)

    def test_executable_probes_cover_required_boundaries(self):
        source, cases, poison_cases = checker.deinterleave_adapter_cases()
        self.assertEqual({case['factor'] for case in cases}, set(range(2, 9)))
        self.assertEqual({case['element'] for case in cases}, {'i32', 'i64', 'double'})
        self.assertEqual({case['lanes'] for case in cases}, {1, 2, 3, 4, 8, 32, 64, 128})
        self.assertEqual(len(cases), 168)
        self.assertEqual(len(poison_cases), 14)
        output = checker.lower_fixed_deinterleaves(source)
        self.assertNotIn('@llvm.vector.deinterleave', output)
        self.assertNotIn('freeze', output)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('checker')
    parser.add_argument('--emit-ir', action='store_true')
    args = parser.parse_args()
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location('fission_checker', args.checker)
    checker = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = checker
    spec.loader.exec_module(checker)
    if args.emit_ir:
        source, _, _ = checker.deinterleave_adapter_cases()
        print(checker.lower_fixed_deinterleaves(source), end='')
    else:
        unittest.main(argv=[sys.argv[0]])
