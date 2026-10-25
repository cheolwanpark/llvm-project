#!/usr/bin/env python3
"""Run the focused LLVM RUN-line corpus using an LLVM_INCLUDE_TESTS=OFF build.

Build llc, opt, FileCheck, split-file and not first. For normal LLVM development
these files also run unchanged under lit with an LLVM_INCLUDE_TESTS=ON build.
"""
import argparse
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[3]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-dir', type=Path, default=ROOT / 'build-vplan-tools')
    args = parser.parse_args()
    binaries = args.build_dir.resolve() / 'bin'
    for name in ('llc', 'opt', 'FileCheck', 'split-file', 'not'):
        if not (binaries / name).is_file(): parser.error(f'missing {binaries / name}; build this target first')
    env = dict(os.environ, PATH=str(binaries) + os.pathsep + os.environ.get('PATH', ''))
    cases = sorted((ROOT / 'llvm/test/CodeGen/RISCV/vplan-ra').glob('*.*'))
    cases += sorted((ROOT / 'llvm/test/Transforms/LoopVectorize/RISCV').glob('vplan-ra*.ll'))
    failures, passed = [], 0
    temporary_root = ROOT / '.cache/tmp'
    temporary_root.mkdir(parents=True, exist_ok=True)
    for path in cases:
        if not path.is_file(): continue
        commands = [line.split('RUN: ', 1)[1] for line in path.read_text().splitlines() if re.match(r'[#;] RUN: ', line)]
        if not commands: continue
        with tempfile.TemporaryDirectory(prefix='vplan-backend-', dir=temporary_root) as td:
            for command in commands:
                command = command.replace('%python', sys.executable).replace('%S', str(path.parent)).replace('%s', str(path)).replace('%t', td + '/temp')
                result = subprocess.run(['bash', '-o', 'pipefail', '-c', command], env=env, capture_output=True, text=True)
                if result.returncode:
                    failures.append(dict(test=str(path.relative_to(ROOT)), command=command, stderr=result.stderr, stdout=result.stdout))
                    break
            else: passed += 1
    print(f'{passed}/{passed + len(failures)} backend/transport regression files passed')
    for f in failures:
        print(f"{f['test']}\n{f['command']}\n{f['stderr']}\n{f['stdout']}", file=sys.stderr)
    return bool(failures)


if __name__ == '__main__':
    raise SystemExit(main())
