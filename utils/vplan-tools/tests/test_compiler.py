"""Run with VPLAN_CLANG=/absolute/build/bin/clang after building this checkout."""
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest
import vplan_tools as vt
from cost_model import Settings, identity, score_observation
from observations import bind_observation, validate_manifest

CLANG = os.environ.get('VPLAN_CLANG')


@unittest.skipUnless(CLANG, 'set VPLAN_CLANG to run compiler integration')
class CompilerIntegration(unittest.TestCase):
    def test_machine_value_proof_limits(self):
        root = Path(__file__).resolve().parents[3]
        fixture = (root / 'llvm/test/CodeGen/RISCV/vplan-ra/memory-facts.mir').read_text()
        llc = Path(CLANG).resolve().parent / 'llc'
        opaque = fixture.replace('    $x13 = IMPLICIT_DEF', '    INLINEASM &"nop", 1\n    $x13 = IMPLICIT_DEF')
        middle = fixture.replace('    $x0 = PseudoVSETIVLI 3, 208', '    $x0 = PseudoVSETIVLI 5, 208')
        cases = [(fixture, [3, 3, 3, 4, None, 2]),
                 (fixture.replace('tracksRegLiveness: true', 'tracksRegLiveness: false'), [None] * 6),
                 (opaque, [None] * 6), (middle, [None, None, None, 4, None, 2])]
        with vt.temporary_directory() as td:
            p = Path(td)
            for text, expected in cases:
                (p / 'input.mir').write_text(text)
                result = subprocess.run([str(llc), '-mtriple=riscv64', '-mcpu=xiangshan-kunminghu',
                    '-run-pass=riscv-vplan-analytics', '-verify-machineinstrs', '-vplan-ra-run-id=test',
                    '-vplan-probe-candidate=facts:0:0:s2', '-vplan-analytics-output=' + str(p / 'facts.json'),
                    str(p / 'input.mir'), '-o', str(p / 'out.mir')], capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stderr)
                ops = json.loads((p / 'facts.json').read_text())['instructions']
                self.assertEqual([o['vl'] for o in ops if o['load']], expected)

    def test_discovery_probe_fixed_model_and_verified_replay(self):
        root = Path(__file__).resolve().parents[3]
        clang = Path(CLANG).resolve()
        driver = root / 'utils/vplan-meta-compile'
        source = 'double a[1024], b[1024]; void selected_kernel(void) { for (int i=0;i<1024;i++) a[i] = b[i]+1.; }'
        flags = ['--target=riscv64-unknown-elf', '-march=rv64gcv', '-mcpu=xiangshan-kunminghu',
                 '-mrvv-vector-bits=128', '-O3', '-fno-unroll-loops', '-fno-slp-vectorize',
                 '-mllvm', '-scalable-vectorization=always', '-mllvm', '-force-vector-interleave=1',
                 '-mllvm', '-enable-epilogue-vectorization=false', '-mllvm', '-riscv-v-register-bit-width-lmul=8']
        with vt.temporary_directory() as td:
            p = Path(td); src = p / 'kernel.c'; src.write_text(source)
            def run(work, extra):
                return subprocess.run([sys.executable, str(driver), '--clang', str(clang), '--input', str(src),
                    '--work-dir', str(p / work), '--extract-function', 'selected_kernel', *extra, '--', *flags],
                    capture_output=True, text=True, timeout=120)
            result = run('raw', ['--analytics-only', '--stop-after-ra'])
            self.assertEqual(result.returncode, 0, result.stderr)
            manifest = json.loads((p / 'raw/candidates.json').read_text())
            validate_manifest(manifest, manifest['run_id'])
            self.assertTrue(any(c['vf'] == 's1' for c in manifest['candidates']))
            self.assertTrue(all(c['middle_end']['configuration_unit_quarters'] is not None for c in manifest['candidates']))
            for i, c in enumerate(manifest['candidates']):
                a = json.loads((p / f'raw/probe-{i:04d}.analytics.json').read_text())
                a = bind_observation(a, c, manifest['loops'][0], manifest['run_id'])
                self.assertEqual(a['error'], '')
                self.assertTrue((p / f'raw/probe-{i:04d}.mir').stat().st_size)
                self.assertTrue(all(a['instructions'][id_]['role'] == 'body' for id_ in a['body_order']))
            result = run('replayed', ['--output', str(p / 'final.s'), '--emit', 'asm'])
            self.assertEqual(result.returncode, 0, result.stderr)
            chosen = json.loads((p / 'replayed/selection.json').read_text())['selections']
            final = json.loads((p / 'replayed/final.manifest.json').read_text())['selections']
            self.assertEqual(chosen, final)
            self.assertFalse(final[0]['scalar'])
            self.assertGreater((p / 'final.s').stat().st_size, 0)
            statuses = json.loads((p / 'replayed/candidate-status.json').read_text())
            self.assertEqual(statuses['policy'], identity())
            for status, c in zip(statuses['candidates'], manifest['candidates'], strict=True):
                index = manifest['candidates'].index(c)
                a = json.loads((p / f'raw/probe-{index:04d}.analytics.json').read_text())
                a = bind_observation(a, c, manifest['loops'][0], manifest['run_id'])
                expected = score_observation(a)
                self.assertEqual(status['status'], 'scored')
                self.assertEqual(status['score'], expected['score'])
                self.assertEqual(status['breakdown']['coefficients'], expected['coefficients'])
                self.assertEqual(status['breakdown']['identity'], identity())
                self.assertEqual(status['breakdown']['body_cost'], expected['body_cost'])
                self.assertEqual(status['breakdown']['features'], expected['features'])
            settings = Settings(body_scale='3/2')
            result = run('alternate', ['--output', str(p / 'alternate.s'), '--emit', 'asm',
                                      '--body-scale', '3/2'])
            self.assertEqual(result.returncode, 0, result.stderr)
            statuses = json.loads((p / 'alternate/candidate-status.json').read_text())
            self.assertEqual(statuses['policy'], identity(settings))
            for status, c in zip(statuses['candidates'], manifest['candidates'], strict=True):
                index = manifest['candidates'].index(c)
                a = json.loads((p / f'raw/probe-{index:04d}.analytics.json').read_text())
                a = bind_observation(a, c, manifest['loops'][0], manifest['run_id'])
                self.assertEqual(status['score_exact'], score_observation(a, settings)['score_exact'])
            self.assertEqual(json.loads((p / 'alternate/selection.json').read_text())['selections'],
                             json.loads((p / 'alternate/final.manifest.json').read_text())['selections'])
