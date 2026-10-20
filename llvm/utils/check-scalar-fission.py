#!/usr/bin/env python3
# Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
# See https://llvm.org/LICENSE.txt for license information.
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
"""Execute scalar fission against original IR and independent scalar oracles.

No cross-target execution is inferred from machine verification. Reports name
exact tool hashes, source hashes, commands, capacities, FP policy and outcomes.
"""
import argparse
import ctypes as C
import hashlib
import json
import math
from pathlib import Path
import random
import re
import shutil
import struct
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
TESTS = ROOT / 'llvm/test/Transforms/ScalarFission'
VERIFY = 'verify<domtree>,verify<loops>,verify<scalar-evolution>'


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def run(cmd, work, **kw):
    cmd = list(map(str, cmd))
    with (work / 'commands.jsonl').open('a') as f:
        f.write(json.dumps(cmd) + '\n')
    p = subprocess.run(cmd, text=True, capture_output=True, **kw)
    if p.returncode:
        raise RuntimeError(f'{cmd}\n{p.stdout}\n{p.stderr}')
    return p


def native(path, tag, build, work):
    # llc, built with the pass, lowers both original and transformed modules.
    # The host driver compiler only links objects and defines the test helpers.
    triple = run([shutil.which('cc'), '-dumpmachine'], work).stdout.strip()
    obj = work / (tag + '.o')
    run([build / 'bin/llc', '-mtriple=' + triple, '-filetype=obj',
         '-relocation-model=pic', '-verify-machineinstrs', path, '-o', obj], work)
    lib = work / (tag + ('.dylib' if sys.platform == 'darwin' else '.so'))
    run([shutil.which('cc'), '-shared', '-O0', '-ffp-contract=off', obj,
         TESTS / 'Inputs/helpers.c', '-o', lib], work)
    return C.CDLL(str(lib))


def fpbits(x):
    return struct.pack('d', x)


def exercise(lib, reference, relaxed=False):
    rng = random.Random(90210)
    count = 0
    u32, u64, ptr = C.c_uint32, C.c_uint64, C.POINTER(C.c_uint32)
    def function(handle, name, args, result=u32):
        f = getattr(handle, name)
        f.argtypes, f.restype = args, result
        return f
    def equal_fp(a, b, tolerance=0):
        if fpbits(a) == fpbits(b) or (math.isnan(a) and math.isnan(b)): return
        assert relaxed and math.isfinite(a) and math.isfinite(b) and not (a == b == 0.0) and abs(a-b) <= tolerance, (a,b,tolerance)
    if hasattr(lib, 'indices'):
        dp = C.POINTER(C.c_double)
        for name in ['indices', 'conditional_indices']:
            f = function(lib, name, [dp, dp, dp, u64, C.c_uint8, C.c_double], C.c_double)
            ref = function(reference, name, f.argtypes, C.c_double)
            values = [rng.uniform(-1, 1) for _ in range(520)]
            data = (C.c_double * len(values))(*values)
            for end in [254, 255, 0, 1, 13, 252, 253]:
                for offset in [0, 3, 256]:
                    for seed in [0., -0., 7., float('inf'), float('nan')]:
                        equal_fp(f(data, data, data, offset, end, seed),
                                 ref(data, data, data, offset, end, seed))
                        count += 1
        g = function(lib, 'suffix', [dp, u64, C.c_double, C.c_double], C.c_double)
        refg = function(reference, 'suffix', g.argtypes, C.c_double)
        for n in [0, 1, 2, 3, 4, 7, 64, 65, 256]:
            for scale in [-2., 0., 0.25, 3.]:
                for seed in [0., -0., 7.]:
                    equal_fp(g(data, n, scale, seed), refg(data, n, scale, seed))
                    count += 1
    if hasattr(lib, 'sequential'):
        dp = C.POINTER(C.c_double)
        for name in ['sequential', 'enclosing']:
            f = function(lib, name, [dp, dp, u64, C.c_double], C.c_double)
            ref = function(reference, name, f.argtypes, C.c_double)
            data = (C.c_double * 128)(*[rng.uniform(-8, 8) for _ in range(128)])
            for n in [0, 1, 2, 3, 7]:
                for seed in [0., -0., 3., float('inf'), float('nan')]:
                    equal_fp(f(data, data, n, seed), ref(data, data, n, seed))
                    count += 1
    if hasattr(lib, 'bounded'):
        dp = C.POINTER(C.c_double)
        for name in ['exact', 'bounded', 'one']:
            f = function(lib, name, [dp, u64, C.c_double], C.c_double)
            ref = function(reference, name, f.argtypes, C.c_double)
            for n in [0, 1, 2, 3, 7, 8, 9, 64, (1 << 64) - 1]:
                for seed in [0., -0., 3., float('inf'), float('nan')]:
                    data = (C.c_double * 8)(*[rng.uniform(-8, 8) for _ in range(8)])
                    equal_fp(f(data, n, seed), ref(data, n, seed))
                    count += 1
    if hasattr(lib, 'shared'):
        f = function(lib, 'shared', [C.POINTER(C.c_double), u64, C.c_double], C.c_double)
        ref = function(reference, 'shared', f.argtypes, C.c_double)
        g = function(lib, 'conditions', [ptr, u64, u32])
        refg = function(reference, 'conditions', g.argtypes)
        for n in [0, 1, 2, 3, 4, 7, 8, 9, 31, 63, 64, 65, 1023, 1024, 1025, 4097]:
            for seed in [0.0, -0.0, 1.0, -7.5, float('inf'), float('nan')]:
                values = [rng.uniform(-16, 16) for _ in range(n)]
                if seed == 0: values = [seed] * n
                data = (C.c_double * max(n, 1))(*values)
                s, t = seed, 1.0
                for x in values:
                    value = (x * x + 1.25) * 0.5
                    s = s + (value + 3.0)
                    t = t - (value * 2.0)
                expected = s + t if n else seed
                result = f(data, n, seed)
                tolerance=16*sys.float_info.epsilon*(n+1)*(abs(seed)+1+sum(abs((x*x+1.25)*0.5+3)+abs(x*x+1.25) for x in values))
                equal_fp(result, ref(data, n, seed), tolerance)
                equal_fp(result, expected, tolerance)
                count += 1
            for seed in [0, 1, 0x7fffffff, 0x80000000, 0xffffffff]:
                values = [rng.randrange(1 << 32) for _ in range(n)]
                data = (u32 * max(n, 1))(*values)
                s, t = seed, 7
                for i, x in enumerate(values):
                    v = ((x*x+3) ^ 9) & 0xffffffff
                    if C.c_int32(v).value > 8: s = (s + v) & 0xffffffff
                    if i & 1: t = (3*t - v) & 0xffffffff
                expected = s ^ t if n else seed
                assert g(data, n, seed) == refg(data, n, seed) == expected
                count += 1
        f = function(lib, 'data_exit', [ptr])
        ref = function(reference, 'data_exit', [ptr])
        for n in [0, 1, 2, 3, 17, 1025]:
            values = list(range(1, n + 1)) + [0]
            data = (u32 * len(values))(*values)
            assert f(data) == ref(data) == (19 + sum((3*x+7)**2+5 for x in values)) & 0xffffffff
            count += 1
    if hasattr(lib, 'vector_pair'):
        f=function(lib,'vector_pair',[ptr,u64,u32])
        ref=function(reference,'vector_pair',f.argtypes)
        for n in [0,1,2,3,7,8,9,64,65,1023,1024,1025,4097]:
            for seed in [0,17,0x80000000,0xffffffff]:
                values=[rng.randrange(1<<32) for _ in range(n)]
                data=(u32*max(n,1))(*values)
                total,other=seed,7
                for x in values:
                    value=((x*x+3)^9)&0xffffffff
                    total=(total+value+1)&0xffffffff
                    other ^= value^7
                assert f(data,n,seed)==ref(data,n,seed)==(total^other if n else seed)
                count+=1
    if hasattr(lib, 'coupled'):
        f=function(lib,'coupled',[ptr,u64,u32]); ref=function(reference,'coupled',f.argtypes)
        for n in [0,1,2,3,7,64,65,1025]:
            for seed in [0,17,0xffffffff]:
                values=[rng.randrange(1<<32) for _ in range(n)]
                data=(u32*max(n,1))(*values); a,b=seed,7
                for x in values:
                    arg=(x*x+3)&0xffffffff
                    a,b=(a+b+arg*arg+5)&0xffffffff,b^a
                assert f(data,n,seed)==ref(data,n,seed)==(a^b if n else seed)
                count+=1
    if hasattr(lib, 'compensated'):
        fma=C.CDLL(None).fma; fma.argtypes=[C.c_double]*3; fma.restype=C.c_double
        for name in ['compensated','state_fma']:
            f=function(lib,name,[C.POINTER(C.c_double),u64,C.c_double],C.c_double)
            ref=function(reference,name,f.argtypes,C.c_double)
            for n in [0,1,2,3,7,64,65,1025]:
                for seed in [-0.0,1.0,-1.0e10,float('inf'),float('nan')]:
                    values=[rng.uniform(-4,4) for _ in range(n)]
                    data=(C.c_double*max(n,1))(*values); total,error=seed,0.0
                    for x in values:
                        value=(x*0.5+1.25)**2+1.0
                        if name=='state_fma': total=fma(total,0.5,value)
                        else:
                            y=value-error; updated=total+y
                            error=(updated-total)-y; total=updated
                    equal_fp(f(data,n,seed),ref(data,n,seed))
                    equal_fp(f(data,n,seed),total)
                    count+=1
    if hasattr(lib, 'nested'):
        f = function(lib, 'nested', [ptr, u64, u32])
        ref = function(reference, 'nested', f.argtypes)
        for n in [0, 1, 2, 3, 4, 9, 65, 1025]:
            for seed in [0, 17, 0xffffffff]:
                a, b = u32(19), u32(19)
                state, total = 19, seed
                for _ in range(n):
                    inner = 0
                    for _ in range(3):
                        state = (state*1664525 + 1013904223) & 0xffffffff
                        inner = (inner + state*3) & 0xffffffff
                    total = (total + inner) & 0xffffffff
                assert f(C.byref(a), n, seed) == ref(C.byref(b), n, seed) == total
                assert a.value == b.value == state
                count += 1
    if hasattr(lib, 'stable'):
        for name in ['stable', 'snapshot', 'computed_snapshot', 'identity_relay']:
            f = function(lib, name, [ptr, ptr, u64])
            ref = function(reference, name, f.argtypes)
            for n in [1, 2, 3, 4, 8, 65, 1025]:
                for shift in ([None] if name == 'stable' else [None, 0, 1, -1]):
                    values = [rng.randrange(1 << 32) for _ in range(n + 4)]
                    a, b = (u32 * len(values))(*values), (u32 * len(values))(*values)
                    ap, bp = C.cast(C.byref(a, 4), ptr), C.cast(C.byref(b, 4), ptr)
                    ao, bo = u32(0xdeadbeef), u32(0xdeadbeef)
                    aq = C.byref(ao) if shift is None else C.cast(C.byref(a, 4*(1+shift)), ptr)
                    bq = C.byref(bo) if shift is None else C.cast(C.byref(b, 4*(1+shift)), ptr)
                    assert f(ap, aq, n) == ref(bp, bq, n)
                    assert list(a) == list(b) and ao.value == bo.value
                    count += 1
    if hasattr(lib, 'reuse'):
        f = function(lib, 'reuse', [ptr,u64])
        ref = function(reference, 'reuse', [ptr,u64])
        for n in [1,2,3,4,64,65,1025]:
            a,b=(u32*(n+2))(),(u32*(n+2))()
            a[n]=b[n]=0xdeadbeef
            assert f(a,n)==ref(b,n)==(9+((54*54+5)**2+5)*n)&0xffffffff
            assert list(a)==list(b)==[((54*54+5)**2+5)&0xffffffff]*n+[0xdeadbeef,0]
            count+=1
    return count


def frontier_execution(lib, reference):
    """Independent wraparound oracles for each graph shape, including aliases."""
    names = ['reconvergent', 'private_suffixes', 'repeated_group_input',
             'direct_shared_root', 'compound_group', 'coupled_group',
             'sharing_levels', 'independent_root', 'partial_coverage',
             'short_alongside_deep', 'freeze_boundary', 'aggregate_results',
             'computed_phi']
    rng, mask, count = random.Random(7219), (1 << 32) - 1, 0
    for name in names:
        f, ref = getattr(lib, name), getattr(reference, name)
        for fun in [f, ref]:
            fun.argtypes = [C.POINTER(C.c_uint32), C.c_uint64, C.c_uint32]
            fun.restype = C.c_uint32
        for n in [0, 1, 2, 3, 7, 64, 65, 1025]:
            for seed in [0, 7, 0x80000000, mask]:
                values = [rng.randrange(1 << 32) for _ in range(max(n, 1))]
                a, b, memory = seed, seed, values[:]
                for i in range(n):
                    x = memory[i]
                    v = ((x*x+3) & mask) ^ 9
                    left, right = (v+7) & mask, v ^ 11
                    if name == 'reconvergent': a += left*right
                    elif name in ['private_suffixes', 'freeze_boundary']:
                        a, b = a+left, b^right
                    elif name == 'repeated_group_input': a = ((a+v)&mask)^v
                    elif name == 'direct_shared_root': a, b = a+v, b^v
                    elif name == 'compound_group': a = ((a+left)&mask)^right
                    elif name == 'coupled_group':
                        a, b = ((a+b+left)&mask)^right, b+a+v*5
                    elif name == 'sharing_levels':
                        common = (v*13)&mask
                        l, r = (common*7)&mask, (common+11)&mask
                        a = (((((a+l+3)&mask)^(l^9))+r+5)&mask)^(r^17)
                    elif name == 'independent_root':
                        independent = ((x*13+17)&mask)^21
                        a = (((a+left)&mask)^right)+independent
                    elif name == 'partial_coverage':
                        a, b = a+left, b^(v^memory[0])
                        memory[0] = x
                    elif name == 'short_alongside_deep':
                        a = (((a+left)&mask)^right)+x+17
                    elif name == 'aggregate_results': a, b = a+v+5, b^(v^13)
                    elif name == 'computed_phi': a += v if x&1 else ((x*13+17)&mask)^21
                    a, b = a&mask, b&mask
                paired = name in ['private_suffixes', 'direct_shared_root',
                                  'coupled_group', 'partial_coverage',
                                  'freeze_boundary', 'aggregate_results']
                expected = (a^b if paired else a) if n else seed
                for fun in [f, ref]:
                    data = (C.c_uint32*len(values))(*values)
                    assert fun(data, n, seed) == expected, (name, n, seed)
                    assert list(data) == memory, (name, 'memory')
                count += 1
    return count


def depth_execution(lib, reference):
    rng, mask, count = random.Random(7218), (1 << 32)-1, 0
    for name in ['one_operation', 'two_operations', 'three_operations',
                 'casts_and_addresses', 'parallel_work', 'raw_load',
                 'opaque_call_is_one', 'opaque_call_chain', 'invariant_arithmetic', 'iv_only', 'internal_control']:
        f, ref = getattr(lib, name), getattr(reference, name)
        for fun in [f, ref]:
            fun.argtypes = [C.POINTER(C.c_uint32), C.c_uint64, C.c_uint32]
            fun.restype = C.c_uint32
        for n in [0, 1, 2, 3, 7, 64, 65, 1025]:
            for seed in [0, 7, 0x80000000, mask]:
                values = [rng.randrange(1 << 32) for _ in range(max(n, 1))]
                expected = seed
                for index, x in enumerate(values[:n]):
                    if name == 'one_operation': expected += x*x
                    elif name in ['two_operations', 'casts_and_addresses']: expected += x*x+7
                    elif name == 'three_operations': expected += ((x*x+3)&mask)^9
                    elif name == 'parallel_work': expected = (((expected+x*3)&mask)^((x*7)&mask))+x*11
                    elif name in ['opaque_call_is_one', 'opaque_call_chain']:
                        value = x
                        for _ in range(1 if name == 'opaque_call_is_one' else 3):
                            value = (value*13+5)&mask
                        expected += value
                    elif name == 'invariant_arithmetic': expected += ((seed*13+7)&mask)^9
                    elif name == 'iv_only': expected += index
                    elif name == 'internal_control': expected += ((x*13+7)&mask)>19
                    else: expected += x
                    expected &= mask
                data = (C.c_uint32*len(values))(*values)
                assert f(data, n, seed) == ref(data, n, seed) == expected, (name, n, seed)
                count += 1
    # The data-dependent control-only rejection has no general finite trip
    # bound, so its negative decision is checked without executing it.
    f, ref = lib.cleanup_becomes_shallow, reference.cleanup_becomes_shallow
    for fun in [f, ref]:
        fun.argtypes, fun.restype = [C.POINTER(C.c_double), C.c_uint64, C.c_double], C.c_double
    for n in [1, 2, 3, 7, 65]:
        data = (C.c_double*n)(*[rng.uniform(-4, 4) for _ in range(n)])
        assert fpbits(f(data, n, 0.25)) == fpbits(ref(data, n, 0.25))
        count += 1
    f, ref = lib.address_stream_is_zero, reference.address_stream_is_zero
    for fun in [f, ref]:
        fun.argtypes = [C.POINTER(C.c_double), C.POINTER(C.c_double),
                        C.POINTER(C.c_uint64), C.c_uint64]
        fun.restype = C.c_double
    for n in [1, 2, 3, 7, 65]:
        a = (C.c_double*128)(*[rng.uniform(-4, 4) for _ in range(128)])
        b = (C.c_double*128)(*[rng.uniform(-4, 4) for _ in range(128)])
        offsets = (C.c_uint64*n)(*[i%5 for i in range(n)])
        assert fpbits(f(a, b, offsets, n)) == fpbits(ref(a, b, offsets, n))
        count += 1
    return count


def decision_records(path):
    # Read only scalar-fission decisions; keep the checker stdlib-only.
    records = []
    for document in re.split(r'^---.*$', path.read_text(), flags=re.M):
        def field(name):
            match = re.search(r'^\s*(?:- )?'+name+r':\s*(.*?)\s*$', document, re.M)
            return match.group(1).strip("'\"") if match else None
        if field('Pass') == 'scalar-fission' and field('Name') in ['Selected', 'Rejected']:
            records.append({key: field(key) for key in
                            ['Name', 'Function', 'Reason', 'ProducerDepth']})
    return records


def require_decisions(source, output, decisions, fixture):
    negatives = {
        'snapshot': 'load-snapshot-required',
        'identity_relay': 'load-snapshot-required',
        'one_operation': 'producer-too-shallow',
        'two_operations': 'producer-too-shallow',
        'casts_and_addresses': 'producer-too-shallow',
        'parallel_work': 'producer-too-shallow',
        'control_does_not_count': 'producer-too-shallow',
        'cleanup_becomes_shallow': 'producer-too-shallow',
        'raw_load': 'no-computed-boundary',
        'opaque_call_is_one': 'producer-too-shallow',
        'invariant_arithmetic': 'no-computed-boundary',
        'iv_only': 'no-computed-boundary',
        'internal_control': 'producer-too-shallow',
        'address_stream_is_zero': 'producer-too-shallow',
    }
    original, transformed = source.read_text(), output.read_text()
    functions = re.findall(r'^define [^@]*@([^ (]+)', original, re.M)
    for name in functions:
        if name in ['pair', 'very_expensive_named_call']: continue  # No loop in this aggregate-return helper.
        records = [r for r in decisions if r['Function'] == name]
        body = re.search(r'^define [^@]*@'+re.escape(name)+r'\([\s\S]*?^}',
                         transformed, re.M | re.S).group()
        if name in negatives:
            assert not any(r['Name'] == 'Selected' for r in records), (fixture, name, records)
            assert any(r['Reason'] == negatives[name] for r in records), (fixture, name, records)
            assert 'scalar.fission.chunk' not in body, (fixture, name)
        else:
            selected = [r for r in records if r['Name'] == 'Selected']
            assert selected and 'scalar.fission.chunk' in body, (fixture, name, records)
            assert all(int(r['ProducerDepth']) >= 3 for r in selected), (fixture, name)
    return decisions


def legacy_integer(lib, reference, kind):
    """Independent wraparound arithmetic for the original nine integer fixtures."""
    rng = random.Random(72031)
    mask32, mask64 = (1 << 32)-1, (1 << 64)-1
    comparisons = 0
    for shape in ['full', 'compact', 'affine']:
        name = kind + '_' + shape
        f, ref = getattr(lib, name), getattr(reference, name)
        for fun in [f, ref]:
            fun.argtypes = [C.POINTER(C.c_uint32), C.POINTER(C.c_uint32), C.POINTER(C.c_uint64), C.c_uint64, C.c_uint32, C.c_uint32]
            fun.restype = None
        for n in [0, 1, 2, 3, 4, 8, 9, 17, 18, 31, 64, 65, 66]:
            for mode in range(8):
                for shift in [0, 1, -1, 70]:
                    seed = rng.choice([0,1,0x7fffffff,0x80000000,0xffffffff])
                    initial = [rng.randrange(1 << 32) for _ in range(160)]
                    memory = initial[:]
                    expected = [0xa5a5a5a5a5a5a5a5]*20
                    a0,a1,o0,o1 = (-251691430)&mask32,1515890085,324508639,610839776
                    x0,x1=81985529216486895,(-81985529216486896)&mask64
                    b0,b1,q0,q1=13,229,17,(-7)&mask32
                    state=seed
                    if 0 < n <= 65:
                        for i in range(n):
                            x=memory[2+i]; previous=state
                            c=((state*13+7)&mask32)^x; dc=(state<<32)|c
                            active = shape != 'compact' or [True,False,bool(i&1),i==0,i==n-1,i%18>=9,bool(state&8),i==0 or i==n-1][mode]
                            state=((state+x) if kind=='bitwise' else (state*x))&mask32
                            memory[2+shift+i]=state
                            if not active: continue
                            if kind=='minmax':
                                a0=min([a0,c],key=lambda v:v^0x80000000)
                                a1=min([c,a1],key=lambda v:v^0x80000000)
                                o0=max([o0,c],key=lambda v:v^0x80000000)
                                o1=max([c,o1],key=lambda v:v^0x80000000)
                                x0,x1=min(x0,dc),max(x1,dc)
                                b0,b1=min(b0,c&255),max(b1,c&255)
                                q0,q1=(q0+c)&mask32,(q1*c)&mask32
                            else:
                                o0,o1=o0|c,o1|c
                                if kind=='multiply':
                                    a0,a1=(a0*c)&mask32,(a1*c)&mask32
                                    x0,x1=(x0*dc)&mask64,(x1*dc)&mask64
                                    b0,b1=(b0*c)&255,(b1*c)&255
                                else:
                                    a0,a1=a0&c,a1&c
                                    x0,x1=x0^dc,x1^dc
                        result=[a0,a1,o0,o1,x0,x1,previous,state,c,dc,
                                7+3*(n-1) if shape=='affine' else n-1,
                                7+3*n if shape=='affine' else n]
                        if kind != 'bitwise': result += [b0,b1]
                        if kind == 'minmax': result += [q0,q1]
                        expected[1:1+len(result)]=result
                    for fun in [f,ref]:
                        data=(C.c_uint32*160)(*initial)
                        out=(C.c_uint64*20)(*[0xa5a5a5a5a5a5a5a5]*20)
                        fun(C.cast(C.byref(data,8),C.POINTER(C.c_uint32)),
                            C.cast(C.byref(data,4*(2+shift)),C.POINTER(C.c_uint32)),
                            C.cast(C.byref(out,8),C.POINTER(C.c_uint64)),n,mode,seed)
                        assert list(data)==memory, (name,n,mode,shift,'memory')
                        assert list(out)==expected, (name,n,mode,shift,list(out),expected)
                    comparisons+=1
    return comparisons


def check(build, work, fixtures=None):
    records = []
    for fixture in fixtures or ['basic', 'nested', 'memory', 'vector-pair', 'coupled-state', 'fp-policy',
                    'overhead', 'bounded-schedule', 'scratch-lifetime', 'frontier',
                    'producer-depth', 'bitwise', 'multiply', 'minmax']:
        legacy = fixture in ['bitwise','multiply','minmax']
        source = ((ROOT/'llvm/test/Transforms/LoopVectorize/RISCV'/('reduction-fission-scalar-'+fixture+'.ll'))
                  if legacy else TESTS / (fixture + '.ll'))
        reference = native(source, fixture + '-ref', build, work)
        for capacity in [1, 3, 64]:
            for relaxed in [False, True]:
                tag = f'{fixture}-c{capacity}-fp{int(relaxed)}'
                output = work / (tag + '.ll')
                remarks = work / (tag + '.yaml')
                command = [build / 'bin/opt', '-passes=scalar-fission,' + VERIFY,
                           '-verify-each', f'-scalar-fission-chunk-capacity={capacity}',
                           f'-scalar-fission-allow-fp-reordering={str(relaxed).lower()}',
                           '-pass-remarks=scalar-fission',
                           '-pass-remarks-output=' + str(remarks),
                           '-pass-remarks-filter=scalar-fission', '-S', source, '-o', output]
                result = run(command, work)
                decisions = require_decisions(source, output, decision_records(remarks), fixture)
                lib = native(output, tag, build, work)
                comparisons = (legacy_integer(lib, reference, fixture) if legacy else
                               frontier_execution(lib, reference) if fixture == 'frontier' else
                               depth_execution(lib, reference) if fixture == 'producer-depth' else
                               exercise(lib, reference))
                # Independently machine-verify actual RVV output, never call it
                # executed or infer performance from static instruction counts.
                rvv = work / (tag + '-rvv.ll')
                run([build / 'bin/opt', '-passes=loop-vectorize,' + VERIFY,
                     '-verify-each', '-mtriple=riscv64', '-mattr=+v', '-S',
                     output, '-o', rvv], work)
                run([build / 'bin/llc', '-mtriple=riscv64', '-mattr=+v',
                     '-verify-machineinstrs', rvv, '-o', work / (tag + '.s')], work)
                vector_comparisons=0
                if fixture == 'basic':
                    host_vector=work/(tag+'-host-lv.ll')
                    run([build/'bin/opt','-passes=loop-vectorize,'+VERIFY,
                         '-verify-each','-force-vector-width=4','-force-vector-interleave=1',
                         '-S',output,'-o',host_vector],work)
                    vector_lib=native(host_vector,tag+'-host-lv',build,work)
                    vector_comparisons=exercise(vector_lib,reference,relaxed=relaxed)
                records.append(dict(fixture=fixture, capacity=capacity,
                                    fp_reordering=relaxed, decisions=decisions,
                                    host_comparisons=comparisons,
                                    host_lv_comparisons=vector_comparisons,
                                    rvv='machine-verified; not executed',
                                    source_sha256=sha(source), output_sha256=sha(output)))
    report = dict(schema=1, records=records,
                  host_comparisons=sum(r['host_comparisons']+r['host_lv_comparisons'] for r in records),
                  compiler={name: sha(build / 'bin' / name) for name in ['opt', 'llc']},
                  performance='unmeasured')
    (work / 'execution.json').write_text(json.dumps(report, indent=2) + '\n')
    print(f"PASS: {report['host_comparisons']} host comparisons; RVV machine verification")


def execute_sweep(build, work, sweep):
    """Execute the vector-pair regression fixture's available fixed VF pairs."""
    data=json.loads((sweep/'result.json').read_text())
    reference=native(TESTS/'vector-pair.ll','sweep-reference',build,work)
    for row in data['rows']:
        if row['status']!='available': continue
        if row['producer'].startswith('s') or row['consumer'].startswith('s'):
            row['execution']='unavailable: scalable IR requires a target runner'
            continue
        tag=row['producer']+'-'+row['consumer']
        lib=native(sweep/(tag+'-lv.ll'),tag+'-run',build,work)
        row['host_comparisons']=exercise(lib,reference)
    (work/'sweep-execution.json').write_text(json.dumps(data,indent=2)+'\n')
    print('PASS: fixed VF sweep host comparisons',sum(r.get('host_comparisons',0) for r in data['rows']))


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--build-dir', type=Path, required=True)
    p.add_argument('--work-dir', type=Path, required=True)
    p.add_argument('--fixture', action='append', help='check only the named fixture; may be repeated')
    p.add_argument('--sweep-dir', type=Path, help='execute an existing vector-pair.ll fixed VF regression sweep instead')
    args = p.parse_args()
    args.work_dir.mkdir(parents=True, exist_ok=True)
    if args.sweep_dir:
        execute_sweep(args.build_dir.resolve(),args.work_dir.resolve(),args.sweep_dir.resolve())
    else:
        check(args.build_dir.resolve(), args.work_dir.resolve(),
              list(dict.fromkeys(args.fixture)) if args.fixture else None)


if __name__ == '__main__':
    main()
