"""Lossless, scoped parser for this checkout's VPlan report_version=2 renderer.

Numbers representing costs use tagged rational JSON objects. Other renderer
inputs retain their spelling. Every node retains its raw source and line.
Only known IR/recipe graph payloads are opaque; strict mode rejects new records
and fields. This API describes LLVM costs before Python's spill replacement.
"""
from __future__ import annotations

import argparse
from fractions import Fraction
import json
from pathlib import Path
import re
import sys

from model_errors import ToolError

SCHEMA_VERSION = 1
MAX_Q = 2**63 - 1
MIN_Q = -(2**63)


class ReportError(ToolError):
    pass


# Inventory from VPlanCostReport.{h,cpp} and all VP_COST_* instrumentation.
# The first field identifies records printed without an explicit record name.
RECORDS = {
    'target', 'cost_kind', 'scalar-baseline', 'register-pressure-policy',
    'epilogue-selection', 'selected-for-main', 'selected-for-epilogue',
    'selected_interleave_count', 'outcome', 'invalid-cost', 'discarded',
    'known_trip_count', 'no-plan', 'selection-override', 'rejection',
    'outside-loop-profitability', 'interleave-selection', 'interleave-register-class',
    'ranking-context', 'scalar-baseline-details', 'scalar', 'scalar-block',
    'legacy-instruction', 'legacy-fallback', 'legacy', 'region-backedge',
    'legacy_precomputed', 'vector_region_body', 'vector_region', 'register_class',
    'register_pressure', 'candidate_cost', 'validity-checks', 'not-evaluated',
    'cost', 'owner', 'vf', 'ir', 'term', 'operation', 'cast', 'replication',
    'memory', 'interleave', 'replacement', 'predication', 'div-rem',
    'predication_divisor', 'weighted_subtotal', 'coverage', 'outside-loop',
    'getInstructionCost', 'hoisted-memory-checks',
    'scalar_operation', 'replicated_operations', 'unweighted_subtotal',
}
FIELDS = set('''report_version module invocation function loop header depth target cpu scalar_tail tail_folded
cost_kind units opt_for_size tuning_vscale user_vf user_ic location cost vf enabled interleave-register-class
reason occurrences status plan source_plan selected_interleave_count outcome recipe
scope source ir category contribution coverage owner forced region legacy_precomputed
vector_region_body vector_region register_pressure spill_cost policy candidate_cost
passed recipes count phase maximum_trip_count has_tail known_trip_count scalar_tail_policy
real_scalar_cost incumbent_sentinel reused_body_cost local_peak invariant_usage limit
induction_heuristic register_limited_ic runtime_checks scalar_iteration_cost
vector_iteration_cost early_exit middle_block total epilogue_cost estimated_width
denominator min_tc_1 min_tc_2 max_min_tc align_to_vf min_tc expected_trip_count decision
bypass vectorization_reason interleave_reason block instruction_sum divisor weighted_cost
raw_cost original replacement_cost register_class excess getRegisterClassSpillCost
getRegisterClassReloadCost spill_plus_reload multiply vf opcode type source_type
result_type context_hint single_scalar minimum_lanes scalable alignment address_space
masked consecutive factor mask_for_gaps reverse members replacement predication_divisor
numerator weighted_subtotal header_frequency block_frequency rounded_divisor scalarization_cost
masked_cost getInstructionCost minimum result term rule'''.split())
COST_FIELDS = set('''cost contribution legacy_precomputed vector_region_body vector_region
spill_cost candidate_cost real_scalar_cost incumbent_sentinel reused_body_cost runtime_checks
scalar_iteration_cost vector_iteration_cost early_exit middle_block total instruction_sum
weighted_cost raw_cost original replacement_cost getRegisterClassSpillCost
getRegisterClassReloadCost spill_plus_reload multiply scalarization_cost masked_cost
getInstructionCost weighted_subtotal result'''.split())


def number(value):
    if value in ('Invalid', 'not-evaluated'):
        return {'state': 'invalid' if value == 'Invalid' else 'not-evaluated'}
    try:
        f = Fraction(value)
    except (ValueError, ZeroDivisionError) as exc:
        raise ReportError(f'invalid exact cost {value!r}') from exc
    return {'state': 'valid', 'numerator': f.numerator, 'denominator': f.denominator}


def rational(value):
    return Fraction(value['numerator'], value['denominator']) if value['state'] == 'valid' else value['state']


def add(a, b):
    if isinstance(a, str) or isinstance(b, str):
        return 'invalid' if 'invalid' in (a, b) else 'not-evaluated'
    return min(Fraction(MAX_Q, 4), max(Fraction(MIN_Q, 4), a + b))


def fields(text, strict=True):
    """Parse renderer field boundaries, preserving types, terms and terminal IR.

    Terms have their own delimiter (result=), since their expression can contain
    equals signs. Payload delimiters inside balanced types/values are ignored.
    """
    out = {}
    text = text.strip()
    if text.startswith('term='):
        m = re.fullmatch(r'term=(.*?) result=(\S+) coverage=(\S+)', text)
        if not m:
            raise ReportError('malformed term/result/coverage')
        return {'term': m[1], 'result': number(m[2]), 'coverage': m[3]}
    matches = list(re.finditer(r'(?<!\S)([A-Za-z_][\w-]*)=', text))
    accepted = []
    last = 0
    stack = []
    for m in matches:
        for ch in text[last:m.start()]:
            if ch in '([{<':
                stack.append(ch)
            elif ch in ')]}>' and stack:
                stack.pop()
        last = m.start()
        if stack:
            continue
        accepted.append(m)
        if m[1] in ('ir', 'location'):
            break
    for index, m in enumerate(accepted):
        key = m[1]
        if strict and key not in FIELDS:
            raise ReportError(f'unsupported field {key!r}')
        if key in out:
            raise ReportError(f'duplicate field {key!r}')
        end = accepted[index + 1].start() if index + 1 < len(accepted) else len(text)
        value = text[m.end():end].rstrip()
        # A diagnostic's occurrences suffix follows its otherwise terminal reason.
        suffix = re.search(r' occurrences=(\d+)$', value)
        if suffix and key == 'reason':
            out['occurrences'] = suffix[1]
            value = value[:suffix.start()]
        out[key] = number(value) if key in COST_FIELDS and not (key == 'cost' and value == 'reused') else value
    if not accepted:
        raise ReportError('record contains no fields')
    return out


def _comparison(text):
    if text == 'not-evaluated':
        return {'state': 'not-evaluated'}
    m = re.fullmatch(r'(yes|no) \((.*?); (.*)\)', text)
    if not m:
        raise ReportError('malformed comparison')
    return {'state': 'evaluated', 'result': m[1] == 'yes', 'against': m[2], 'reason': m[3]}


def _ranges(text):
    ids = []
    for item in text.split(','):
        m = re.fullmatch(r'R(\d+)(?:-R(\d+))?', item.strip())
        if not m:
            raise ReportError('invalid recipe range')
        a, b = int(m[1]), int(m[2] or m[1])
        if b < a:
            raise ReportError('backwards recipe range')
        ids.extend(range(a, b + 1))
    if len(set(ids)) != len(ids):
        raise ReportError('duplicate recipe in range')
    return ids


class Parser:
    def __init__(self, strict=True, stage=None):
        self.strict, self.stage = strict, stage
        self.report = self.plan = self.evaluation = self.recipe = None
        self.graph = None
        self.calculations = []
        self.line = 0

    def error(self, message):
        context = '' if self.report is None else f" report={self.report['occurrence']}"
        if self.plan is not None:
            context += f" plan={self.plan['id']}"
        if self.evaluation is not None:
            context += f" evaluation={self.evaluation['id']}"
        raise ReportError(f'line {self.line}{context}: {message}')

    def node(self, kind, raw, data=None):
        return {'kind': kind, 'line': self.line, 'raw': raw,
                'fields': data if data is not None else fields(raw, self.strict)}

    def events(self):
        if self.calculations:
            return self.calculations[-1]['children']
        if self.recipe is not None:
            return self.recipe['events']
        if self.evaluation is not None:
            return self.evaluation['events']
        return self.report['events']

    def boundary(self):
        if self.calculations:
            self.error('unclosed calculation')
        self.recipe = None

    def parse(self, text):
        result = {'schema_version': SCHEMA_VERSION, 'report_version': 2,
                  'cost_basis': 'original-llvm', 'stage': self.stage, 'reports': [],
                  'diagnostics': [], 'unsupported': []}
        for self.line, raw in enumerate(text.splitlines(), 1):
            try:
                if raw.startswith('VPlan report_version='):
                    if self.report is not None:
                        self.error('nested report or truncated graph')
                    header = re.fullmatch(r'VPlan report_version=(\S+) module=(.*?) invocation=(\d+) '
                        r'function=(.*?) loop=(\d+) header=(.*?) depth=(\d+)', raw)
                    if header is None:
                        self.error('malformed report header')
                    h = dict(zip(('report_version', 'module', 'invocation', 'function', 'loop', 'header', 'depth'), header.groups()))
                    if h.get('report_version') != '2':
                        self.error('unsupported VPlan report version')
                    if any(k not in h for k in ('module', 'invocation', 'function', 'loop', 'header', 'depth')):
                        self.error('incomplete report header')
                    if h['depth'] not in ('1', '2'):
                        self.error('invalid detail depth')
                    self.report = {'occurrence': len(result['reports']), 'stage': self.stage,
                        'header': h, 'line': self.line, 'raw_header': raw, 'raw_lines': [],
                        'events': [], 'candidates': [], 'plans': [], 'singletons': {}}
                    self.details = self.table = self.table_header = False
                    self.plan = self.evaluation = self.recipe = self.graph = None
                    continue
                if self.report is None:
                    if raw == 'End VPlan report':
                        self.error('report end without header')
                    result['diagnostics'].append({'line': self.line, 'raw': raw, 'stage': self.stage})
                    continue
                if raw == 'End VPlan report':
                    if self.graph is not None:
                        self.error('unclosed graph')
                    self.boundary()
                    self.validate()
                    self.report['end_line'] = self.line
                    result['reports'].append(self.report)
                    self.report = None
                    continue
                self.report['raw_lines'].append(raw)
                if self.graph is not None:
                    self.graph_line(raw)
                    continue
                s = raw.strip()
                indent = len(raw) - len(raw.lstrip())
                if not s:
                    continue
                if s == 'candidates:':
                    if self.table:
                        self.error('duplicate candidate table')
                    self.table = True
                    continue
                if s.startswith('phase |'):
                    if not self.table or self.table_header:
                        self.error('unexpected candidate table header')
                    self.table_header = True
                    continue
                if s == 'none' and self.table and not self.details:
                    continue
                if re.match(r'(main|epilogue) \|', s):
                    if not self.table_header:
                        self.error('candidate outside table')
                    cols = [x.strip() for x in s.split('|')]
                    if len(cols) != 10:
                        self.error('malformed candidate table row')
                    phase, plan, vf, width, cost, score, kind, incumbent, scalar, reason = cols
                    if not re.fullmatch('[fs][1-9][0-9]*', vf) or int(width) <= 0:
                        self.error('invalid candidate geometry')
                    row = self.node('candidate', raw, dict(phase=phase, plan=int(plan), vf=vf,
                        estimated_width=int(width), body_cost=number(cost), score=number(score),
                        score_kind=kind, vs_incumbent=_comparison(incumbent),
                        vs_scalar=_comparison(scalar), reason=reason))
                    self.report['candidates'].append(row)
                    continue
                if s == 'details:':
                    self.boundary()
                    if self.details or self.report['header']['depth'] != '2':
                        self.error('unexpected details section')
                    self.details = True
                    continue
                if indent == 2 and re.fullmatch(r'plan=\d+', s):
                    self.boundary()
                    if not self.details:
                        self.error('plan outside details')
                    self.plan = {'id': int(s[5:]), 'line': self.line, 'graph': None, 'evaluations': []}
                    self.report['plans'].append(self.plan)
                    self.evaluation = None
                    self.cost_vf = None
                    continue
                if s.startswith('tail_folded='):
                    if self.plan is None or 'tail' in self.plan:
                        self.error('unexpected/duplicate plan tail context')
                    self.plan['tail'] = fields(raw, self.strict)
                    continue
                if raw.startswith("VPlan '"):
                    if self.plan is None or self.plan['graph'] is not None:
                        self.error('unexpected/duplicate graph')
                    if not raw.endswith(' {'):
                        self.error('malformed graph header')
                    self.graph = {'line': self.line, 'header': raw, 'lines': [], 'recipes': [],
                                  'blocks': [], 'connections': [], 'regions': []}
                    self.plan['graph'] = self.graph
                    self.graph_depth = 1
                    self.graph_block = None
                    self.graph_regions = []
                    continue
                if s.startswith('costs vf='):
                    self.boundary()
                    if self.plan is None:
                        self.error('costs outside plan')
                    self.cost_vf = fields(s, self.strict)['vf']
                    continue
                if s.startswith('evaluation='):
                    self.boundary()
                    f = fields(s.replace('evaluation=', 'count=', 1), self.strict)
                    if self.plan is None or int(f['plan']) != self.plan['id'] or f['vf'] != self.cost_vf:
                        self.error('evaluation plan/VF mismatch')
                    if f['phase'] not in ('candidate-validation', 'main-selection', 'epilogue-selection',
                                          'interleave-selection', 'outside-loop-profitability', 'invalid-cost-remarks'):
                        self.error('unsupported evaluation phase')
                    self.evaluation = {'id': int(f['count']), 'plan': int(f['plan']),
                        'vf': f['vf'], 'phase': f['phase'], 'line': self.line, 'events': []}
                    self.plan['evaluations'].append(self.evaluation)
                    continue
                if s.startswith('calculation='):
                    if not self.details or not s.endswith(' {'):
                        self.error('malformed calculation')
                    if self.calculations and indent != self.calculations[-1]['indent'] + 2:
                        self.error('invalid calculation indentation')
                    node = self.node('calculation', raw, {'name': s[len('calculation='):-2]})
                    node.update(children=[], indent=indent)
                    self.events().append(node)
                    self.calculations.append(node)
                    continue
                if s == '}':
                    if not self.calculations or indent != self.calculations[-1]['indent']:
                        self.error('unbalanced calculation boundary')
                    self.calculations.pop()['end_line'] = self.line
                    continue
                m = re.fullmatch(r'R(\d+) scope=(\S+)', s)
                if m:
                    self.boundary()
                    if self.evaluation is None or indent != 6:
                        self.error('recipe outside evaluation')
                    if m[2] not in ('vector-region', 'validity-only', 'outside-loop-profitability', 'invalid-cost-remarks'):
                        self.error('unsupported recipe scope')
                    self.recipe = {'kind': 'recipe', 'id': int(m[1]), 'scope': m[2],
                                   'line': self.line, 'raw': raw, 'events': []}
                    self.evaluation['events'].append(self.recipe)
                    continue
                if s.startswith(('ranking-context ', 'scalar-baseline-details ')):
                    self.boundary()
                    self.evaluation = None
                # Evaluation events use six columns, recipe results eight.
                if indent <= 6:
                    self.boundary()
                if indent <= 4 and not s.startswith(('scalar ', 'scalar-block ', 'ranking-context ')):
                    self.evaluation = None
                first = re.split(r'[ =]', s, maxsplit=1)[0]
                if first not in RECORDS:
                    if self.strict:
                        self.error(f'unsupported record {first!r}')
                    result['unsupported'].append({'line': self.line, 'raw': raw})
                    self.events().append(self.node('unsupported', raw, {}))
                    continue
                if first in ('legacy', 'region-backedge', 'legacy_precomputed', 'vector_region_body',
                             'vector_region', 'register_class', 'register_pressure', 'candidate_cost',
                             'validity-checks', 'not-evaluated') and (self.evaluation is None or indent != 6):
                    self.error('accounting record outside evaluation')
                if first == 'cost' and (self.recipe is None or indent != 8 or self.calculations):
                    self.error('recipe result outside recipe')
                if first == 'term' and not self.calculations:
                    self.error('term outside calculation')
                if not self.details and first not in {'target', 'cost_kind', 'scalar-baseline',
                        'register-pressure-policy', 'epilogue-selection', 'selected-for-main',
                        'selected-for-epilogue', 'selected_interleave_count', 'outcome', 'invalid-cost',
                        'discarded', 'known_trip_count', 'no-plan', 'selection-override', 'rejection',
                        'outside-loop-profitability', 'interleave-selection', 'interleave-register-class'}:
                    self.error('detail record without details section')
                if first in ('scalar_operation', 'replicated_operations', 'unweighted_subtotal'):
                    # Instrumented arithmetic expressions, with optional pointer type.
                    expression, sep, pointer = s.partition(' pointer_type=')
                    node = self.node(first, raw, {'expression': expression.split(' = ', 1)[1],
                                                **({'pointer_type': pointer} if sep else {})})
                else:
                    node = self.node(first, raw)
                if 'coverage' in node['fields'] and node['fields']['coverage'] not in ('expanded', 'tti-leaf', 'opaque-legacy'):
                    self.error('unsupported coverage label')
                if first in ('target', 'cost_kind', 'scalar-baseline', 'selected-for-main',
                             'selected-for-epilogue', 'selected_interleave_count', 'outcome'):
                    if first in self.report['singletons']:
                        self.error(f'duplicate singleton {first}')
                    self.report['singletons'][first] = node
                self.events().append(node)
                if first == 'cost' and self.recipe is not None:
                    self.recipe = None
            except (ReportError, ValueError, KeyError, IndexError, ZeroDivisionError) as exc:
                if isinstance(exc, ReportError) and str(exc).startswith('line '):
                    raise
                self.error(str(exc))
        if self.report is not None:
            self.error('truncated report/graph/calculation')
        return result

    def graph_line(self, raw):
        self.graph['lines'].append({'line': self.line, 'raw': raw})
        s = raw.strip()
        m = re.match(r'\[R(\d+)\] (.*)', s)
        if m:
            self.graph['recipes'].append({'id': int(m[1]), 'block': self.graph_block,
                'line': self.line, 'raw': raw, 'payload': m[2],
                'value_refs': re.findall(r'(?:vp|ir)<[^>]*>', m[2])})
        elif s.startswith('<') and s.endswith(': {'):
            self.graph_depth += 1
            name = s.split('> ', 1)[1][:-3]
            region = {'id': 'G' + str(len(self.graph['regions'])), 'label': name,
                      'parent': self.graph_regions[-1] if self.graph_regions else None,
                      'line': self.line, 'raw': raw}
            self.graph_regions.append(region['id'])
            self.graph['regions'].append(region)
        elif s.endswith(':') and s != 'Successor(s):':
            self.graph_block = 'B' + str(len(self.graph['blocks']))
            self.graph['blocks'].append({'id': self.graph_block, 'label': s[:-1],
                'parent': self.graph_regions[-1] if self.graph_regions else None,
                'line': self.line, 'raw': raw})
        elif s.startswith('Successor(s):'):
            self.graph['connections'].append({'source': self.graph_block,
                'targets': s[len('Successor(s):'):].strip().split(', '), 'line': self.line, 'raw': raw})
        elif s == 'No successors':
            self.graph['connections'].append({'source': self.graph_block, 'targets': [],
                                             'line': self.line, 'raw': raw})
        elif s == '}':
            self.graph_depth -= 1
            if self.graph_depth == 0:
                graph_nodes = self.graph['blocks'] + self.graph['regions']
                by_id = {n['id']: n for n in graph_nodes}
                for edge in self.graph['connections']:
                    if edge['source'] not in by_id:
                        self.error('graph edge without source block/region')
                    parent = by_id[edge['source']]['parent']
                    edge['target_refs'] = []
                    for label in edge['targets']:
                        candidates = [n['id'] for n in graph_nodes if n['label'] == label and n['parent'] == parent]
                        if not candidates:
                            candidates = [n['id'] for n in graph_nodes if n['label'] == label]
                        if not candidates:
                            self.error('graph successor label is absent')
                        # The renderer can reuse labels for sibling replicate
                        # regions. Preserve that ambiguity instead of guessing.
                        edge['target_refs'].append({'label': label, 'candidates': candidates,
                            'id': candidates[0] if len(candidates) == 1 else None})
                self.graph['end_line'] = self.line
                self.graph = None
            elif self.graph_regions:
                self.graph_block = self.graph_regions.pop()

    def validate(self):
        r = self.report
        for key in ('scalar-baseline', 'selected-for-main', 'selected-for-epilogue',
                    'selected_interleave_count', 'outcome', 'cost_kind'):
            if key not in r['singletons']:
                self.error(f'missing singleton {key}')
        if not self.table_header:
            self.error('missing candidate table')
        rows = {}
        for n in r['candidates']:
            f = n['fields']; key = (f['phase'], f['plan'], f['vf'])
            if key in rows:
                self.error('duplicate candidate row')
            rows[key] = f
            if f['score_kind'] == 'cost-per-lane' and f['score']['state'] == 'valid':
                if rational(f['score']) != rational(f['body_cost']) / f['estimated_width']:
                    self.error('candidate per-lane score mismatch')
        if r['header']['depth'] == '2' and not self.details:
            self.error('missing details section')
        plans, evaluations = {}, set()
        for p in r['plans']:
            if p['id'] in plans or p['graph'] is None:
                self.error('duplicate plan or missing graph')
            plans[p['id']] = p
            ids = [n['id'] for n in p['graph']['recipes']]
            if len(ids) != len(set(ids)):
                self.error('duplicate graph recipe ID')
            ids = set(ids)
            for e in p['evaluations']:
                if e['id'] in evaluations:
                    self.error('duplicate evaluation ID')
                evaluations.add(e['id'])
                legacy = recipe_sum = backedges = Fraction(0)
                components = {}; seen = set()
                for n in e['events']:
                    kind = n['kind']; f = n.get('fields', {})
                    if kind == 'recipe':
                        if n['id'] not in ids:
                            self.error('recipe missing from graph')
                        results = [a for a in n['events'] if a['kind'] == 'cost']
                        if len(results) != 1:
                            self.error('missing/duplicate recipe result')
                        for a in n['events']:
                            if a['kind'] == 'owner' and int(a['fields']['owner'][1:]) not in ids:
                                self.error('recipe owner missing from graph')
                        contribution = rational(results[0]['fields']['contribution'])
                        if n['scope'] != 'vector-region' and contribution not in (0, 'invalid'):
                            self.error('non-body recipe contributes to body')
                        recipe_sum = add(recipe_sum, contribution)
                    elif kind == 'legacy':
                        legacy = add(legacy, rational(f['contribution']))
                    elif kind == 'region-backedge':
                        backedges = add(backedges, rational(f['cost']))
                    elif kind in ('legacy_precomputed', 'vector_region_body', 'vector_region', 'register_pressure', 'candidate_cost'):
                        if kind in seen:
                            self.error(f'duplicate evaluation component {kind}')
                        seen.add(kind)
                        components[kind] = rational(f['spill_cost' if kind == 'register_pressure' else kind])
                    elif kind in ('validity-checks', 'not-evaluated'):
                        refs = _ranges(f['recipes'])
                        if not set(refs) <= ids or len(refs) != int(f.get('count', f.get('passed'))):
                            self.error('invalid recipe coverage range/count')
                if 'legacy_precomputed' in components and components['legacy_precomputed'] != legacy:
                    self.error('legacy contribution sum mismatch')
                if 'vector_region_body' in components and components['vector_region_body'] != add(recipe_sum, backedges):
                    self.error('vector contribution sum mismatch')
                if 'candidate_cost' in components:
                    if not {'legacy_precomputed', 'vector_region', 'register_pressure'} <= components.keys():
                        self.error('incomplete candidate accounting')
                    if components['candidate_cost'] != add(add(legacy, components['vector_region']), components['register_pressure']):
                        self.error('candidate component sum mismatch')
                    if e['phase'] in ('main-selection', 'epilogue-selection'):
                        phase = 'main' if e['phase'] == 'main-selection' else 'epilogue'
                        row = rows.get((phase, p['id'], e['vf']))
                        if row is None or rational(row['body_cost']) != components['candidate_cost']:
                            self.error('candidate summary cost mismatch')
                elif e['phase'] in ('main-selection', 'epilogue-selection', 'candidate-validation', 'interleave-selection'):
                    self.error('incomplete evaluation accounting')
        if self.details:
            for f in rows.values():
                if f['plan'] not in plans:
                    self.error('summary references missing plan')
            for key in ('selected-for-main', 'selected-for-epilogue'):
                f = r['singletons'][key]['fields']
                for name in ('plan', 'source_plan'):
                    if name in f and f[name] != 'none' and int(f[name]) not in plans:
                        self.error('selection references missing plan')
            for n in r['events']:
                f = n['fields']
                if n['kind'] in ('ranking-context', 'invalid-cost', 'interleave-selection', 'discarded') and 'plan' in f:
                    if int(f['plan']) not in plans:
                        self.error('record references missing plan')
                    if 'recipe' in f:
                        ids = {a['id'] for a in plans[int(f['plan'])]['graph']['recipes']}
                        if not re.fullmatch(r'R\d+', f['recipe']) or int(f['recipe'][1:]) not in ids:
                            self.error('diagnostic recipe missing from graph')
            contexts = {}
            for n in r['events']:
                if n['kind'] != 'ranking-context':
                    continue
                f = n['fields']; key = (f['phase'], int(f['plan']), f['vf'])
                if key in contexts or key not in rows:
                    self.error('duplicate or unbound ranking context')
                contexts[key] = f
            from cost_model import total
            for key, row in rows.items():
                if row['score_kind'] != 'whole-loop':
                    continue
                if key not in contexts:
                    self.error('missing whole-loop ranking context')
                f = contexts[key]
                def quarters(cost):
                    value = rational(cost)
                    if value == 'invalid':
                        return None
                    if value == 'not-evaluated' or (value * 4).denominator != 1:
                        self.error('non-quarter body/scalar cost in ranking')
                    return int(value * 4)
                score = total(quarters(row['body_cost']), row['estimated_width'],
                    quarters(r['singletons']['scalar-baseline']['fields']['cost']),
                    int(f['maximum_trip_count']), f['has_tail'] == '1')
                expected = 'invalid' if score is None else Fraction(score, 4)
                if rational(row['score']) != expected:
                    self.error('whole-loop ranking score mismatch')
        # Scalar baseline can be evaluated repeatedly; each section owns blocks.
        instruction_sum = weighted_sum = Fraction(0)
        scalar_active = False
        for n in r['events']:
            k, f = n['kind'], n['fields']
            if k == 'scalar-baseline-details':
                if scalar_active and (instruction_sum != 0 or weighted_sum != rational(r['singletons']['scalar-baseline']['fields']['cost'])):
                    self.error('incomplete scalar section or scalar baseline mismatch')
                instruction_sum = weighted_sum = Fraction(0); scalar_active = True
            elif k == 'scalar' and 'cost' in f:
                instruction_sum = add(instruction_sum, rational(f['cost']))
            elif k == 'scalar-block':
                subtotal = rational(f['instruction_sum']); divisor = int(f['divisor'])
                if not scalar_active or subtotal != instruction_sum or divisor <= 0:
                    self.error('scalar instruction sum/divisor mismatch')
                expected = Fraction(int(subtotal * 4 / divisor), 4) if not isinstance(subtotal, str) else subtotal
                if rational(f['weighted_cost']) != expected:
                    self.error('scalar block weighting mismatch')
                weighted_sum = add(weighted_sum, expected); instruction_sum = Fraction(0)
                n['validated_weighted_sum'] = number(str(weighted_sum)) if not isinstance(weighted_sum, str) else {'state': weighted_sum}
        if scalar_active and (instruction_sum != 0 or weighted_sum != rational(r['singletons']['scalar-baseline']['fields']['cost'])):
            self.error('scalar baseline sum mismatch')


def parse_reports(text, *, strict=True, stage=None):
    return Parser(strict, stage).parse(text)


def validate_manifest_costs(parsed, manifest):
    """Compare only original LLVM components, never derived backend costs."""
    matched = 0
    for c in manifest['candidates']:
        matches = []
        for r in parsed['reports']:
            h = r['header']
            if h['function'] != c['function'] or int(h['loop']) != c['loop']:
                continue
            plan_id = int(c['id'].rsplit(':', 2)[1])
            for p in r['plans']:
                if p['id'] != plan_id:
                    continue
                for e in p['evaluations']:
                    if e['vf'] == c['vf'] and e['phase'] in ('main-selection', 'candidate-validation'):
                        components = {n['kind']: n['fields'] for n in e['events'] if 'fields' in n}
                        if 'candidate_cost' in components:
                            matches.append(components)
        if not matches:
            raise ReportError(f"no original detail accounting for {c['id']}")
        for components in matches:
            for key, record, field in (('original', 'candidate_cost', 'candidate_cost'),
                    ('precomputed', 'legacy_precomputed', 'legacy_precomputed'),
                    ('vector_region', 'vector_region', 'vector_region'),
                    ('estimated_spill', 'register_pressure', 'spill_cost')):
                expected = c['middle_end'][key]
                actual = rational(components[record][field])
                if actual != ('invalid' if expected is None else Fraction(expected, 4)):
                    raise ReportError(f"original manifest mismatch: {c['id']} {key}")
        matched += 1
    return matched


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', nargs='?', default='-', help='log file, or - for stdin')
    parser.add_argument('-o', '--output', type=Path)
    parser.add_argument('--stage', help='compiler stage identity for this log')
    parser.add_argument('--lenient', action='store_true', help='retain unsupported records; structural/accounting checks remain enabled')
    args = parser.parse_args(argv)
    try:
        text = sys.stdin.read() if args.input == '-' else Path(args.input).read_text()
        result = parse_reports(text, strict=not args.lenient, stage=args.stage)
        output = json.dumps(result, indent=2, allow_nan=False) + '\n'
        if args.output:
            args.output.write_text(output)
        else:
            sys.stdout.write(output)
    except (ToolError, OSError) as exc:
        print(str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
