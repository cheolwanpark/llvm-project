#!/usr/bin/env python3
"""Regenerate the reviewed opcode map from the pinned, locally downloaded RTL.

Usage: python rules/extract.py /path/to/VecDecoder.scala > rules/opcodes.json
The input SHA is checked; no branch head or network access is used.
"""
import hashlib
import json
from pathlib import Path
import re
import sys

REVISION = 'e7bab53e66dfb3c4a1d11cf9519b0396f8576cae'

def extract(text):
    defaults = dict(re.findall(r'case class (\w+)\([\s\S]*?uopSplitType: BitPat = UopSplitType\.(\w+)', text))
    rows = {}
    # Decode rows are deliberately restricted to literal opcode/case-class
    # records. Generated memory patterns have separate reviewed rules.
    for match in re.finditer(r'^\s*(\w+)\s*->\s*(\w+)\(([^\n]+)\)', text, re.M):
        opcode, constructor, args = match.groups()
        fu = re.search(r'FuType\.(\w+)', args)
        if not fu or constructor not in defaults:
            continue
        splits = re.findall(r'UopSplitType\.(\w+)', args)
        split = splits[0] if splits else defaults[constructor]
        rows[opcode] = dict(split=split, fu=fu[1], line=text[:match.start()].count('\n') + 1)
    return rows

if __name__ == '__main__':
    path = Path(sys.argv[1])
    data = path.read_bytes()
    if hashlib.sha256(data).hexdigest() != '3eec0be04f5e3a375e57fea33b101a43d46184bcefbfec163b7942efdabf9aa6':
        raise SystemExit('input is not the pinned VecDecoder.scala revision')
    print(json.dumps(dict(revision=REVISION, source='src/main/scala/xiangshan/backend/decode/VecDecoder.scala',
                          sha256=hashlib.sha256(data).hexdigest(), opcodes=extract(data.decode())), indent=2, sort_keys=True))
