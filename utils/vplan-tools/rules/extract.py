#!/usr/bin/env python3
"""Verify literal datasheet records against locally supplied pinned RTL files.

Usage: python rules/extract.py /path/to/rtl-directory
Supply the flat files named in SOURCE_HASHES; no runtime download or generation.
"""
import hashlib
from pathlib import Path
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from kunminghu_v2 import (FIXED_TIMING_ROWS, ROB_ENTRIES, SCALAR_OPCODES, SCALAR_VECTOR_DECODER,
                         SOURCE_HASHES, VECTOR_OPCODES)


def extract(text):
    defaults = dict(re.findall(r'case class (\w+)\([\s\S]*?uopSplitType: BitPat = UopSplitType\.(\w+)', text))
    rows = {}
    for match in re.finditer(r'^\s*(\w+)\s*->\s*(\w+)\(([^\n]+)\)', text, re.M):
        opcode, constructor, args = match.groups()
        fu = re.search(r'FuType\.(\w+)', args)
        if not fu or constructor not in defaults: continue
        splits = re.findall(r'UopSplitType\.(\w+)', args)
        rows[opcode] = (fu[1], splits[0] if splits else defaults[constructor], text[:match.start()].count('\n') + 1)
    return rows


def verify(directory):
    for name, expected in SOURCE_HASHES.items():
        if hashlib.sha256((directory / name).read_bytes()).hexdigest() != expected:
            raise ValueError('not pinned RTL: ' + name)
    config = (directory / 'Configs.scala').read_text().split('class MinimalConfig', 1)[1].split('\nclass ', 1)[0]
    rob = re.search(r'\bRobSize\s*=\s*(\d+)', config)
    if not rob or int(rob[1]) != ROB_ENTRIES:
        raise ValueError('MinimalConfig ROB size differs from datasheet')
    vector = extract((directory / 'VecDecoder.scala').read_text())
    if {k: v for k, v in vector.items() if k.startswith('V')} != VECTOR_OPCODES:
        raise ValueError('vector opcode records differ from RTL')
    scalar = {}
    text = (directory / 'DecodeUnit.scala').read_text()
    for m in re.finditer(r'^\s*(\w+)\s*->\s*(?:XSDecode|FDecode)\([^\n]*?FuType\.(\w+)', text, re.M):
        scalar[m[1]] = (m[2], text[:m.start()].count('\n') + 1)
    fp = {k: (v[0], v[2]) for k, v in vector.items() if not k.startswith('V')}
    if scalar | fp != SCALAR_OPCODES or set(fp) != SCALAR_VECTOR_DECODER:
        raise ValueError('scalar opcode records differ from RTL')
    text = (directory / 'FuConfig.scala').read_text()
    for name, (config, literal) in FIXED_TIMING_ROWS.items():
        block = re.search(r'  val ' + config + r'\b[\s\S]*?(?=\n  val |\Z)', text)
        if not block or not re.search(r'piped\s*=\s*true', block[0]):
            raise ValueError('fixed timing FU is not piped: ' + name)
        latency = re.search(r'latency\s*=\s*CertainLatency\((\d+)\)', block[0])
        if (int(latency[1]) if latency else 0) != literal:
            raise ValueError('fixed timing literal differs: ' + name)
    print(f'Verified {len(VECTOR_OPCODES)} vector and {len(SCALAR_OPCODES)} scalar records, '
          f'{len(FIXED_TIMING_ROWS)} fixed timing records, ROB size {ROB_ENTRIES}; '
          f'{len(SOURCE_HASHES)} pinned source hashes.')


if __name__ == '__main__': verify(Path(sys.argv[1]))
