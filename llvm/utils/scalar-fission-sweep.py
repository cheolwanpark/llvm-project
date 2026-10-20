#!/usr/bin/env python3
# Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
# See https://llvm.org/LICENSE.txt for license information.
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
"""Sweep VF/IC metadata on ONE frozen scalar-fission IR artifact.

Requires PyYAML. A VF is 1 (scalar), fN (fixed) or sN (scalable, including s1).
The original input, FP flags, scratch, chunk schedule and all instructions are
identical across pairs. Unmet VF/IC requests are unavailable, never successful
forced configurations. Optional --run-command is an external target benchmark
command template with {ir} and {assembly}; its stdout and wall time are saved.
"""
import argparse
import hashlib
import itertools
import json
from pathlib import Path
import re
import shlex
import subprocess
import time
import yaml

class Loader(yaml.SafeLoader): pass
Loader.add_multi_constructor('!', lambda loader, tag, node: loader.construct_mapping(node))


def vf(text):
    scalable = text.startswith('s')
    width = int(text[1:] if text[:1] in ['f','s'] else text)
    if width < 1 or width & (width-1): raise ValueError('VF must be a power of two')
    return width, scalable


def configure(source, producer, consumer, ic, consumer_ic=None):
    consumer_ic = ic if consumer_ic is None else consumer_ic
    ids = [int(x) for x in re.findall(r'^!(\d+)\s*=', source, re.M)]
    next_id = max(ids, default=0) + 1
    definitions = dict(re.findall(r'^!(\d+)\s*=\s*(.*)$', source, re.M))
    appended = []
    stages = 0
    def rewrite(match):
        nonlocal next_id, stages
        ident, body = match.groups()
        if not body.startswith('distinct !{'): return match[0]
        refs = re.findall(r'!(\d+)', body)
        stage = None
        stage_ic = ic
        for ref in refs[1:]:
            if '"llvm.loop.scalar_fission.producer"' in definitions.get(ref, ''): stage = producer
            if '"llvm.loop.scalar_fission.consumer"' in definitions.get(ref, ''):
                stage = consumer
                stage_ic = consumer_ic
        if stage is None: return match[0]
        stages += 1
        keep = [refs[0]]
        for ref in refs[1:]:
            item = definitions.get(ref, '')
            if any(x in item for x in ['llvm.loop.vectorize.', 'llvm.loop.interleave.',
                                      'llvm.loop.scalar_fission.requested_']): continue
            keep.append(ref)
        width, scalable = vf(stage)
        for key, bits, value in [('vectorize.width',32,width),
                                ('vectorize.scalable.enable',1,int(scalable)),
                                ('vectorize.enable',1,int(width != 1 or scalable)),
                                ('interleave.count',32,stage_ic),
                                ('scalar_fission.requested_vf',32,width),
                                ('scalar_fission.requested_scalable',1,int(scalable)),
                                ('scalar_fission.requested_ic',32,stage_ic)]:
            keep.append(str(next_id))
            literal = ('true' if value else 'false') if bits == 1 else str(value)
            appended.append(f'!{next_id} = !{{!"llvm.loop.{key}", i{bits} {literal}}}')
            next_id += 1
        return f'!{ident} = distinct !{{' + ', '.join('!'+r for r in keep) + '}'
    result = re.sub(r'^!(\d+)\s*=\s*(.*)$', rewrite, source, flags=re.M)
    if stages < 2: raise ValueError('input must contain producer and consumer stage IDs')
    # Only loop metadata changes. Make this invariant executable.
    strip = lambda ir: '\n'.join(x for x in ir.splitlines() if not x.startswith('!'))
    assert strip(result) == strip(source)
    return result + '\n' + '\n'.join(appended) + '\n'


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('input', type=Path)
    p.add_argument('--build-dir', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--producer', nargs='+', default=['1','f2','f4'])
    p.add_argument('--consumer', nargs='+', default=['1','f2','f4'])
    p.add_argument('--interleave', type=int, default=1)
    p.add_argument('--producer-interleave', type=int)
    p.add_argument('--consumer-interleave', type=int)
    p.add_argument('--target-arg', action='append', default=[])
    p.add_argument('--llc-arg', action='append', default=[])
    p.add_argument('--run-command')
    a = p.parse_args()
    pic = a.interleave if a.producer_interleave is None else a.producer_interleave
    cic = a.interleave if a.consumer_interleave is None else a.consumer_interleave
    for ic in [a.interleave, pic, cic]:
        if ic < 1 or ic & (ic-1): p.error('interleave must be a power of two')
    source = a.input.read_text()
    work = a.output.resolve(); work.mkdir(parents=True, exist_ok=True)
    rows = []
    for producer, consumer in itertools.product(a.producer,a.consumer):
        tag = producer + '-' + consumer
        path, output, remarks, assembly = [work/(tag+ext) for ext in ['.ll','-lv.ll','.yaml','.s']]
        path.write_text(configure(source, producer, consumer, pic, cic))
        cmd = [str(a.build_dir/'bin/opt'), '-passes=loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>',
               '-verify-each', '-pass-remarks-output='+str(remarks), '-pass-remarks-filter=scalar-fission',
               *a.target_arg, '-S', str(path), '-o', str(output)]
        r = subprocess.run(cmd, capture_output=True, text=True)
        row = dict(producer=producer,consumer=consumer,interleave=a.interleave, producer_interleave=pic, consumer_interleave=cic, command=cmd,
                   stderr=r.stderr, status='unavailable', actual=[], performance='unmeasured')
        if r.returncode: row['reason']='compiler-error'
        else:
            matches = []
            for record in yaml.load_all(remarks.read_text(), Loader=Loader):
                if not record or record.get('Name') != 'Stage': continue
                fields = {k:v for item in record.get('Args',[]) for k,v in item.items() if k != 'DebugLoc'}
                stage = fields.get('Stage')
                if stage not in ['producer','consumer']: continue
                request = producer if stage == 'producer' else consumer
                width,scalable = vf(request)
                actual = str(fields.get('ProducerVF' if stage == 'producer' else 'AccumulatorVF'))
                expected = f'vscale x {width}' if scalable else str(width)
                requested_ic = pic if stage == 'producer' else cic
                matched = actual == expected and int(fields.get('ActualIC',0)) == requested_ic
                matches.append(matched)
                row['actual'].append(dict(function=record.get('Function'),stage=stage,vf=actual,
                                          ic=fields.get('ActualIC'),available=matched))
            stages = {r['stage'] for r in row['actual']}
            if matches and all(matches) and stages == {'producer','consumer'}: row['status']='available'
            else: row['reason']='requested-VF-or-IC-not-realized'
            codegen = [str(a.build_dir/'bin/llc'), '-verify-machineinstrs', *a.llc_arg, str(output), '-o', str(assembly)]
            machine = subprocess.run(codegen, capture_output=True, text=True)
            row['codegen_command'],row['codegen_exit'],row['codegen_stderr']=codegen,machine.returncode,machine.stderr
            if machine.returncode: row['status'],row['reason']='unavailable','codegen-error'
            if a.run_command and row['status']=='available':
                command = [part.format(ir=str(output),assembly=str(assembly)) for part in shlex.split(a.run_command)]
                start=time.perf_counter(); execution=subprocess.run(command,capture_output=True,text=True)
                row['performance']=dict(command=command,seconds=time.perf_counter()-start,
                                        exit_code=execution.returncode,stdout=execution.stdout,stderr=execution.stderr,
                                        scope='external benchmark command wall time')
        rows.append(row)
    result=dict(input_sha256=hashlib.sha256(source.encode()).hexdigest(), rows=rows,
                target_args=a.target_arg,llc_args=a.llc_arg,
                opt_sha256=hashlib.sha256((a.build_dir/'bin/opt').read_bytes()).hexdigest())
    (work/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({r['producer']+'/'+r['consumer']:r['status'] for r in rows},indent=2))

if __name__=='__main__': main()
