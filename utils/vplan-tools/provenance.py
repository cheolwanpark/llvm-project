"""Small reproducibility snapshot for fixed evaluations and detail corpora."""
import hashlib
from pathlib import Path
import subprocess


def digest(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def snapshot(checkout, database, clang):
    checkout, clang = Path(checkout), Path(clang)
    def git(*args):
        return subprocess.run(['git', '-C', str(checkout), *args], capture_output=True,
                              text=True, check=True).stdout.strip()
    files = sorted((checkout / 'utils/vplan-tools').glob('*.py'))
    files += [checkout / 'utils/vplan-meta-compile', checkout / 'utils/vplan-tools/evaluate',
              checkout / 'utils/vplan-tools/print-vplans', checkout / 'utils/vplan-tools/validate-detail-corpus',
              checkout / 'utils/vplan-tools/write-updated-report']
    files = [p for p in files if p.is_file()]
    return dict(database_sha256=digest(database), head=git('rev-parse', 'HEAD'),
                working_tree=git('status', '--short'),
                tracked_diff_sha256=hashlib.sha256(git('diff', 'HEAD', '--', 'utils').encode()).hexdigest(),
                code_sha256={str(p.relative_to(checkout)): digest(p) for p in files},
                compiler_sha256=digest(clang) if clang.is_file() else None,
                compiler_version=subprocess.run([str(clang), '--version'], capture_output=True,
                    text=True, check=True).stdout.strip() if clang.is_file() else None)
