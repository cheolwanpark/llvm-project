"""Measurement-free candidate scoring and protocol-4 replay decisions."""
from cost_model import identity, score_observation, Settings, ranking_score
from model_errors import ToolError


class Policy:
    def __init__(self, settings=Settings()):
        self.settings = settings
        self.identity = identity(settings)

    def evaluate(self, candidate, observation):
        report = score_observation(observation, self.settings)
        return dict(status='scored', score=report['score'], score_exact=report['score_exact'], breakdown=report)

    def choose(self, rows):
        rows = [(c, s) for c, s in rows if c['vf'].startswith('s') and s['status'] == 'scored']
        return min(rows, key=lambda r: (ranking_score(r[1]), int(r[0]['vf'][1:]), r[0]['id']))[0] if rows else None


def select_loops(policy, manifest, statuses):
    if [c['id'] for c in manifest['candidates']] != [s['id'] for s in statuses]:
        raise ToolError('candidate/status identity mismatch')
    selections = []
    for loop in manifest['loops']:
        selected = policy.choose([(c, s) for c, s in zip(manifest['candidates'], statuses, strict=True)
                                  if (c['function'], c['loop']) == (loop['function'], loop['loop'])])
        choice = dict(function=loop['function'], loop=loop['loop'], scalar=selected is None, ic=1, epilogue_vf='f0')
        if selected: choice['id'] = selected['id']
        else: choice['reason'] = 'no supported scalable local-model candidates'
        selections.append(choice)
    return selections
