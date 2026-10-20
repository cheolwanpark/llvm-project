"""Renderer inventory fixtures, scoped identities, and strict error paths."""
from fractions import Fraction
import json
from pathlib import Path
import subprocess
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from vplan_report import parse_reports, ReportError, rational, RECORDS, fields, validate_manifest_costs

FIXTURES = Path(__file__).parent / 'fixtures'
DETAIL = (FIXTURES / 'gesummv-detail.txt').read_text()
VARIANTS = (FIXTURES / 'renderer-variants.txt').read_text()


def nodes(items):
    for n in items:
        yield n
        yield from nodes(n.get('events', []))
        yield from nodes(n.get('children', []))


def all_nodes(parsed):
    for r in parsed['reports']:
        yield from nodes(r['events'])
        for p in r['plans']:
            for e in p['evaluations']:
                yield from nodes(e['events'])


class ReportTests(unittest.TestCase):
    def test_real_detail_and_full_renderer_record_inventory(self):
        seen = set()
        for text in (DETAIL, VARIANTS):
            parsed = parse_reports(text)
            self.assertFalse(parsed['unsupported'])
            seen.update(n['kind'] for n in all_nodes(parsed))
        self.assertEqual(RECORDS - seen, set())

    def test_multiple_reports_and_stage_identity_are_preserved(self):
        parsed = parse_reports(VARIANTS * 2, stage='probe-0001')
        self.assertEqual([r['occurrence'] for r in parsed['reports']], list(range(4)))
        self.assertTrue(all(r['stage'] == 'probe-0001' for r in parsed['reports']))
        self.assertIn('external diagnostic', parsed['diagnostics'][0]['raw'])
        r = parsed['reports'][0]
        self.assertEqual(r['header']['module'], 'module with spaces.bc')
        self.assertEqual([e['id'] for e in r['plans'][0]['evaluations']], [0, 1])
        self.assertEqual([e['vf'] for e in r['plans'][0]['evaluations']], ['f2', 'f2'])

    def test_nested_calculation_payloads_and_exact_numbers(self):
        r = parse_reports(VARIANTS)['reports'][0]
        e = r['plans'][0]['evaluations'][0]
        recipe = next(n for n in e['events'] if n['kind'] == 'recipe')
        calc = recipe['events'][0]
        nested = next(n for n in calc['children'] if n['kind'] == 'calculation')
        term = nested['children'][0]['fields']
        self.assertEqual(term['term'], 'I == RetI ? (RedCost + ExtraExtCost) : 0')
        self.assertEqual(rational(term['result']), Fraction(5, 4))
        cast = next(n for n in calc['children'] if n['kind'] == 'cast')['fields']
        self.assertEqual(cast['result_type'], '<2 x { i32, i64 }>')
        self.assertEqual(cast['source_type'], '{ i32, i64 }')
        g = r['plans'][0]['graph']
        self.assertEqual([n['id'] for n in g['recipes']], [0, 1, 2])
        self.assertEqual(g['connections'][0]['targets'], ['body'])
        self.assertIn('payload { i32, i64 }', g['recipes'][0]['payload'])
        self.assertEqual(r['singletons']['selected-for-epilogue']['fields']['cost'], 'reused')
        override = next(n for n in r['events'] if n['kind'] == 'selection-override')['fields']
        self.assertEqual(rational(override['real_scalar_cost']), Fraction(3, 2))

    def test_json_serializable_and_invalid_not_evaluated_zero_differ(self):
        json.dumps(parse_reports(VARIANTS), allow_nan=False)
        for cost, state in (('Invalid', 'invalid'), ('not-evaluated', 'not-evaluated'), ('0', 'valid')):
            self.assertEqual(fields('cost=' + cost)['cost']['state'], state)

    def test_epilogue_evaluation_and_header_payload(self):
        text = VARIANTS.replace('module with spaces.bc', 'module with [unclosed brace {.bc')
        text = text.replace('evaluation=0 plan=0 vf=f2 phase=main-selection',
                            'evaluation=0 plan=0 vf=f2 phase=epilogue-selection')
        parse_reports(text)

    def test_repeated_graph_labels_have_distinct_ids(self):
        start = VARIANTS.index("VPlan 'fixture")
        end = VARIANTS.index('    costs vf=', start)
        graph = """VPlan 'repeated labels' {
entry:
Successor(s): pred.load
<xVFxUF> pred.load: {
  repeated:
    [R0] IR load ptr %p
  No successors
}
No successors
<xVFxUF> pred.load: {
  repeated:
    [R1] IR load ptr %q
    [R2] IR ret void
  No successors
}
No successors
}
"""
        parsed = parse_reports(VARIANTS[:start] + graph + VARIANTS[end:])
        g = parsed['reports'][0]['plans'][0]['graph']
        self.assertEqual(len({b['id'] for b in g['blocks']}), 3)
        self.assertEqual([b['label'] for b in g['blocks']], ['entry', 'repeated', 'repeated'])
        self.assertIsNone(g['connections'][0]['target_refs'][0]['id'])
        self.assertEqual(g['connections'][0]['target_refs'][0]['candidates'], ['G0', 'G1'])

    def test_invalid_cost_accounting_propagates(self):
        text = VARIANTS.replace('| 3 | 3 | code-size', '| Invalid | Invalid | code-size')
        text = text.replace('contribution=1.25', 'contribution=Invalid')
        text = text.replace('vector_region_body=1.75', 'vector_region_body=Invalid')
        text = text.replace('vector_region=1.75', 'vector_region=Invalid')
        text = text.replace('candidate_cost=3', 'candidate_cost=Invalid')
        parse_reports(text)

    def test_corrupt_boundaries_versions_fields_and_accounting(self):
        mutations = [
            lambda t: t.replace('report_version=2', 'report_version=3', 1),
            lambda t: t.replace('End VPlan report', '', 1),
            lambda t: t.replace('        calculation=expanded-fixture {', '        calculation=expanded-fixture'),
            lambda t: t.replace('          }', '            }', 1),
            lambda t: t.replace('  details:', '  unknown-record value=1\n  details:', 1),
            lambda t: t.replace('opcode=add type=', 'opcode=add mystery=1 type=', 1),
            lambda t: t.replace('  outcome=vectorization-emitted', '  outcome=vectorization-emitted\n  outcome=vectorization-emitted', 1),
            lambda t: t.replace('[R1] IR', '[R0] IR', 1),
            lambda t: t.replace('R0 scope=', 'R99 scope=', 1),
            lambda t: t.replace('owner=R0', 'owner=R99', 1),
            lambda t: t.replace('evaluation=1', 'evaluation=0', 1),
            lambda t: t.replace('evaluation=0 plan=0', 'evaluation=0 plan=9', 1),
            lambda t: t.replace('vector_region_body=1.75', 'vector_region_body=2', 1),
            lambda t: t.replace('candidate_cost=3', 'candidate_cost=4', 1),
            lambda t: t.replace('      candidate_cost=3 status=evaluated\n', '', 1),
            lambda t: t.replace('instruction_sum=3', 'instruction_sum=4', 1),
            lambda t: t.replace('weighted_cost=1.5', 'weighted_cost=1', 1),
            lambda t: t.replace('passed=1 recipes=R1', 'passed=1 recipes=R9', 1),
            lambda t: t.replace('coverage=tti-leaf', 'coverage=imagined-internals', 1),
            lambda t: t.replace('depth=2', 'depth=1', 1),
        ]
        for mutate in mutations:
            with self.subTest(mutation=mutate(VARIANTS)[:50]), self.assertRaisesRegex(ReportError, r'line \d+'):
                parse_reports(mutate(VARIANTS))
        for text in (DETAIL[:-100], DETAIL[:1000], 'End VPlan report'):
            with self.assertRaises(ReportError):
                parse_reports(text)

    def test_lenient_retains_new_records(self):
        parsed = parse_reports(VARIANTS.replace('  details:', '  future-event x=1\n  details:', 1), strict=False)
        self.assertEqual(len(parsed['unsupported']), 1)

    def test_original_manifest_match_is_separate_from_backend_costs(self):
        parsed = parse_reports(DETAIL)
        c = dict(id='selected_kernel:0:2:s8', function='selected_kernel', loop=0, vf='s8',
                 middle_end={'original': 360, 'precomputed': 4, 'vector_region': 356, 'estimated_spill': 0})
        self.assertEqual(validate_manifest_costs(parsed, {'candidates': [c]}), 1)
        c['middle_end']['original'] = 552
        with self.assertRaisesRegex(ReportError, 'original manifest mismatch'):
            validate_manifest_costs(parsed, {'candidates': [c]})

    def test_cli_stdin_and_source_identity(self):
        cli = Path(__file__).resolve().parents[1] / 'vplan_report.py'
        p = subprocess.run([sys.executable, '-B', str(cli), '--stage', 'discover'], input=VARIANTS,
                           capture_output=True, text=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(json.loads(p.stdout)['stage'], 'discover')


if __name__ == '__main__':
    unittest.main()
