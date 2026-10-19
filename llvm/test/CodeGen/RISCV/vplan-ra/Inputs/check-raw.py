"""Compare selected fields of raw analytics, with no cost model dependency."""
import json
import sys


def check(actual, expected, path='$'):
    if isinstance(expected, dict):
        for key, value in expected.items():
            assert key in actual, (path, key)
            check(actual[key], value, path + '.' + key)
    elif isinstance(expected, list):
        assert len(actual) == len(expected), (path, len(actual), len(expected))
        for index, (a, e) in enumerate(zip(actual, expected)):
            check(a, e, f'{path}[{index}]')
    else:
        assert actual == expected, (path, actual, expected)


with open(sys.argv[1]) as stream:
    actual = json.load(stream)
with open(sys.argv[2]) as stream:
    expected = json.load(stream)[sys.argv[3]]
check(actual, expected)
assert not any(k in json.dumps(actual) for k in ('work8', 'resource_demand', 'latency'))
