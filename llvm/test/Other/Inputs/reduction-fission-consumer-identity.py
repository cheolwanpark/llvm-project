"""Exercise certificates using actual transformed fixture IR.

Mutations are constructed and asserted nonidentical before rejection handling.
Find the test operands from the scratch GEPs, independently of the checker's
PHI-based discovery. Alpha-renaming is confined to two local SSA definitions
and their uses; the producer and all semantic instructions remain unchanged.
"""
import re


def exercise(checker, ir, name, evl, certify, probe=None):
    body = checker.function_definition(ir, name)
    blocks = {label: checker.chunk_instructions(code)
              for label, code in checker.loop_blocks(body).items()}
    vectors = [label for label in blocks if label.startswith('vector.body')]
    if not vectors:
        return
    assert len(vectors) == 1
    vector = vectors[0]
    code = blocks[vector]
    addresses = [m for line in code if (m := re.fullmatch(
        r'%[-\w.$]+ = getelementptr inbounds \[\d+ x (?:i32|i64|double|float)\], '
        r'ptr %scalar\.fission\.scratch[-\w.$]*, i32 0, i64 (%[-\w.$]+)', line))]
    assert len(addresses) >= 2
    indices = {m[1] for m in addresses}
    assert len(indices) == 1
    index = indices.pop()
    ordinal = next(line for line in code if line.startswith(index + ' = phi i64 '))
    incoming = dict((edge, value) for value, edge in re.findall(
        r'\[ ([^,\]]+), %([-\w.$]+) \]', ordinal))
    assert incoming.keys() == {'vector.ph', vector} and incoming['vector.ph'] == '0'
    next_index = incoming[vector]
    increment = next(line for line in code if line.startswith(next_index + ' = '))
    assert ' = add ' in increment
    input_address = next(line for line in blocks['loop'] if line.startswith('%p = getelementptr '))
    producer_index = re.fullmatch(
        r'%p = getelementptr i32, ptr %a, i64 (%[-\w.$]+)', input_address)[1]
    assert any(line.startswith(producer_index + ' = ') for line in blocks['loop'])
    assert index != producer_index and next_index != producer_index

    def local_rename(mapping):
        assert len(set(mapping.values())) == len(mapping)
        for old, new in mapping.items():
            assert old != new and new not in re.findall(r'%[-\w.$]+', body)
            assert sum(line.startswith(old + ' = ') for line in code) == 1
        candidate_body = re.sub(r'%[-\w.$]+', lambda m: mapping.get(m[0], m[0]), body)
        candidate = ir.replace(body, candidate_body, 1)
        assert candidate != ir
        return candidate

    # Both increment-result spellings and wholly unrelated legal names must
    # work. Renaming only the increment also catches result-name assumptions.
    for mapping in ({next_index: '%advance.token'},
                    {index: '%cursor.token', next_index: '%advance.token'}):
        candidate = local_rename(mapping)
        certify(candidate)
        if probe:
            checked = probe(candidate)
            # Input/store probes keep the global producer ordinal. Consumption
            # probes use this consumer's local PHI, including after renaming.
            if 'call void @record_nc_consume(' in checked:
                assert 'call void @record_nc_consume(i64 ' + mapping.get(index, index) + ',' in checked
                assert 'call void @record_nc_iteration(i64 ' + producer_index + ',' in checked
                assert 'call void @record_nc_store(i64 ' + producer_index + ',' in checked
        yield candidate

    def reject(old, new):
        assert old != new and body.count(old) == 1, (name, old, new)
        candidate_body = body.replace(old, new, 1)
        candidate = ir.replace(body, candidate_body, 1)
        assert candidate != ir
        try:
            certify(candidate)
        except AssertionError:
            return
        raise AssertionError(name + ': accepted consumer identity corruption: ' + old + ' -> ' + new)

    reject(ordinal, ordinal.replace('[ 0, %vector.ph ]', '[ 1, %vector.ph ]'))
    reject(ordinal, ordinal.replace('%vector.ph', '%scalar.fission.producer.ph'))
    reject(ordinal, ordinal.replace(', %' + vector + ' ]', ', %loop ]'))
    reject(ordinal, ordinal.replace('[ ' + next_index + ',', '[ ' + producer_index + ','))
    reject(ordinal, ordinal.replace('[ ' + next_index + ', %' + vector + ' ]', '[ 0, %vector.ph ]'))

    def replace_value(line, old, new):
        return re.sub(r'%[-\w.$]+', lambda m: new if m[0] == old else m[0], line)

    reject(increment, replace_value(increment, index, producer_index))
    operands = re.fullmatch(r'%[-\w.$]+ = add(?: nuw)?(?: nsw)? i64 (%[-\w.$]+), (%[-\w.$]+)', increment)
    assert operands, increment
    step = next(value for value in operands.groups() if value != index)
    reject(increment, replace_value(increment, step, '1'))
    reject(increment, increment.replace(' = add ', ' = sub '))
    for address in addresses:
        line = address[0]
        for wrong in (producer_index, next_index, '0'):
            reject(line, line.replace('i64 ' + index, 'i64 ' + wrong))
    compare = next(line for line in code if ' = icmp eq i64 ' in line)
    operand = '%avl.next' if evl else next_index
    assert operand + ', ' in compare
    for wrong in (producer_index, index, next_index if evl else '%fission.consumer.count'):
        reject(compare, compare.replace(operand + ', ', wrong + ', '))
