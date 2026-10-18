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

    exercise_tail(checker, ir, name, certify, producer_index)
    if not evl:
        yield from exercise_widths(checker, ir, name, certify, increment, index)

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

    # Both add operand orders and all demonstrated integer flag spellings are
    # equivalent for this bounded traversal. In particular keep the inherited
    # EVL fixture's unflagged, step-first increment valid.
    operands = re.fullmatch(r'%[-\w.$]+ = add(?: nuw)?(?: nsw)? i64 (%[-\w.$]+), (%[-\w.$]+)', increment)
    assert operands, increment
    for flags in ('', 'nuw ', 'nuw nsw '):
        for left, right in (operands.groups(), operands.groups()[::-1]):
            changed = f'{next_index} = add {flags}i64 {left}, {right}'
            if changed == increment:
                continue
            candidate = ir.replace(body, body.replace(increment, changed, 1), 1)
            assert candidate != ir and body.count(increment) == 1
            certify(candidate)
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


def exercise_tail(checker, ir, name, certify, producer_index):
    """Mutate the complete scalar tail of actual transformed consumers."""
    body = checker.function_definition(ir, name)
    blocks = {label: checker.chunk_instructions(code)
              for label, code in checker.loop_blocks(body).items()}
    tail, resume = 'scalar.fission.consumer.body', 'scalar.ph'
    if tail not in blocks:
        return  # EVL has no scalar tail.
    addresses = [m for line in blocks[tail] if (m := re.fullmatch(
        r'(%[-\w.$]+) = getelementptr inbounds \[\d+ x (?:i32|i64|double|float)\], '
        r'ptr %scalar\.fission\.scratch[-\w.$]*, i32 0, i64 (%[-\w.$]+)', line))]
    assert len(addresses) >= 2
    assert len({m[2] for m in addresses}) == 1
    index = addresses[0][2]
    phi = next(line for line in blocks[tail] if line.startswith(index + ' = phi i64 '))
    inputs = re.findall(r'\[ ([^,\]]+), %([-\w.$]+) \]', phi)
    assert len(inputs) == 2 and sorted(p for _, p in inputs) == sorted([resume, tail])
    incoming = {p: v for v, p in inputs}
    update, seed = incoming[tail], incoming[resume]
    increment = next(line for line in blocks[tail] if line.startswith(update + ' = '))
    seed_phi = next(line for line in blocks[resume] if line.startswith(seed + ' = phi i64 '))
    assert sorted(re.findall(r'\[ ([^,\]]+), %([-\w.$]+) \]', seed_phi)) == sorted([
        ('%n.vec', 'middle.block'), ('0', 'scalar.fission.consumer.ph')])

    def reject(old, new):
        assert old != new and body.count(old) == 1, (name, old, new)
        candidate = ir.replace(body, body.replace(old, new, 1), 1)
        assert candidate != ir
        try:
            certify(candidate)
        except AssertionError:
            return
        raise AssertionError(name + ': accepted tail traversal corruption: ' + old + ' -> ' + new)

    for wrong in ('0', '%n.vec', producer_index):
        reject(phi, phi.replace('[ ' + seed + ',', '[ ' + wrong + ','))
    # Retain the zero-backedge mutation which exposed the missing proof.
    reject(phi, phi.replace('[ ' + update + ',', '[ 0,'))
    reject(phi, phi.replace('%' + tail + ' ]', '%' + resume + ' ]'))
    reject(phi, phi.replace('%' + resume + ' ]', '%middle.block ]'))
    reject(phi, phi + ', [ ' + update + ', %' + tail + ' ]')
    reject(seed_phi, seed_phi.replace('[ %n.vec,', '[ ' + update + ','))
    reject(seed_phi, seed_phi.replace('[ 0,', '[ 1,'))
    reject(seed_phi, seed_phi.replace('%middle.block ]', '%scalar.fission.consumer.ph ]'))
    reject(seed_phi, seed_phi + ', [ 0, %scalar.fission.consumer.ph ]')
    for stride in ('0', '2', '-1'):
        assert increment.endswith(', 1'), increment
        reject(increment, increment[:-1] + stride)
    reject(increment, increment.replace(' = add ', ' = sub '))
    compare = next(line for line in blocks[tail] if line.startswith('%fission.consumer.more = '))
    for wrong in (index, seed, producer_index):
        reject(compare, compare.replace(update + ',', wrong + ','))
    reject(compare, compare.replace('icmp ne ', 'icmp eq '))
    reject(compare, re.sub(r', %[-\w.$]+$', ', %n.vec', compare))
    branch = blocks[tail][-1]
    match = re.fullmatch(r'br i1 (%[-\w.$]+), label %([-\w.$]+), label %([-\w.$]+)', branch)
    assert match and match[2] == tail
    reject(branch, f'br i1 {match[1]}, label %{match[3]}, label %{match[2]}')
    for address in addresses:
        for wrong in ('0', update, seed, producer_index):
            reject(address[0], address[0].replace('i64 ' + index, 'i64 ' + wrong))
        load = next(line for line in blocks[tail] if re.search(
            r' = load (?:i32|i64|double|float), ptr ' + re.escape(address[1]) + r',', line))
        reject(load, load.replace('ptr ' + address[1] + ',', 'ptr %p,'))


def exercise_widths(checker, ir, name, certify, increment, index):
    """Shared and stage-local VF positives; unique definition/order negatives."""
    body = checker.function_definition(ir, name)
    blocks = {label: checker.chunk_instructions(code)
              for label, code in checker.loop_blocks(body).items()}
    entry, preheader, vector = 'scalar.fission.consumer.ph', 'vector.ph', 'vector.body'
    minimum = next(line for line in blocks[entry] if line.startswith('%min.iters.check = '))
    rounding = next(line for line in blocks[preheader] if line.startswith('%n.mod.vf = '))
    entry_width = re.search(r', (%[-\w.$]+)$', minimum)[1]
    round_width = re.search(r', (%[-\w.$]+)$', rounding)[1]
    operands = re.fullmatch(r'%[-\w.$]+ = add(?: nuw)?(?: nsw)? i64 (%[-\w.$]+), (%[-\w.$]+)', increment)
    assert operands
    advance_width = next(v for v in operands.groups() if v != index)

    def token(line, old, new):
        changed = re.sub(r'%[-\w.$]+', lambda m: new if m[0] == old else m[0], line)
        assert changed != line
        return changed

    def changed(edits):
        candidate_body = body
        for old, new in edits:
            assert old != new and candidate_body.count(old) == 1, (name, old, new)
            candidate_body = candidate_body.replace(old, new, 1)
        candidate = ir.replace(body, candidate_body, 1)
        assert candidate != ir
        return candidate

    for prefix in ('shared', 'rounding', 'advance'):
        assert '%' + prefix + '.width' not in body and '%' + prefix + '.scale' not in body

    shared = '  %shared.scale = call i64 @llvm.vscale.i64()\n  %shared.width = shl nuw i64 %shared.scale, 2\n'
    candidate = changed([
        (minimum, shared.lstrip() + '  ' + token(minimum, entry_width, '%shared.width')),
        (rounding, token(rounding, round_width, '%shared.width')),
        (increment, token(increment, advance_width, '%shared.width'))])
    certify(candidate)
    yield candidate
    # Separate vscale calls are equal by the intrinsic contract. Each width
    # must still dominate its use; sharing an SSA spelling is not required.
    candidate = changed([
        (rounding, '%rounding.scale = call i64 @llvm.vscale.i64()\n'
         '  %rounding.width = shl nuw i64 %rounding.scale, 2\n  ' +
         token(rounding, round_width, '%rounding.width')),
        (increment, '%advance.scale = call i64 @llvm.vscale.i64()\n'
         '  %advance.width = shl nuw i64 %advance.scale, 2\n  ' +
         token(increment, advance_width, '%advance.width'))])
    certify(candidate)
    yield candidate

    def reject(edits):
        candidate = changed(edits)  # Construction is outside rejection handling.
        try:
            certify(candidate)
        except AssertionError:
            return
        raise AssertionError(name + ': accepted invalid consumer VF definitions: ' + str(edits))

    width_line = next(line for code in blocks.values() for line in code
                      if line.startswith(entry_width + ' = '))
    scale = re.fullmatch(r'%[-\w.$]+ = shl(?: nuw)? i64 (%[-\w.$]+), 2', width_line)[1]
    scale_line = next(line for code in blocks.values() for line in code if line.startswith(scale + ' = '))
    reject([(width_line, width_line[:-1] + '1')])
    reject([(scale_line, scale + ' = add i64 0, 7')])
    reject([(minimum, token(minimum, entry_width, '%n'))])
    reject([(rounding, token(rounding, round_width, '%n'))])
    reject([(increment, token(increment, advance_width, '%n'))])
    reject([(width_line, width_line + '\n  ' + width_line)])
    reject([(scale_line, scale_line + '\n  ' + scale_line)])
    # Exact definitions on the wrong path, or after the actual use, fail even
    # though a whole-function text search would still find the right formula.
    reject([(width_line, ''), (minimum, minimum + '\n  ' + width_line)])
    reject([(scale_line, ''), (minimum, minimum + '\n  ' + scale_line)])
    reject([(width_line, ''), (rounding, width_line + '\n  ' + rounding)])
