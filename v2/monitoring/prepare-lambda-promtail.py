#!/usr/bin/env python3
"""공식 Lambda 패키지의 SHA-256과 실행 아키텍처를 검사한 뒤 로컬에 준비한다."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import zipfile


def verify(path, release):
    # GitHub release asset의 digest와 고정한 SHA-256이 같아야 배포한다.
    if hashlib.sha256(path.read_bytes()).hexdigest() != release['sha256']:
        raise ValueError('Lambda 패키지 SHA-256 불일치')
    with zipfile.ZipFile(path) as archive:
        bootstrap = archive.read('bootstrap')
        if bootstrap[:4] != b'\x7fELF' or int.from_bytes(bootstrap[18:20], 'little') != 62:
            raise ValueError('Linux x86_64 bootstrap이 아님')
        if not (archive.getinfo('bootstrap').external_attr >> 16) & 0o111:
            raise ValueError('bootstrap 실행 권한 없음')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, help='이미 내려받은 공식 ZIP을 검증해서 사용')
    args = parser.parse_args()
    root = Path(__file__).resolve().parent
    release = json.loads((root / 'lambda-promtail.release.json').read_text())
    output = root / '.artifacts' / release['filename']
    output.parent.mkdir(exist_ok=True)
    if output.exists():
        verify(output, release)
        print('검증된 패키지 준비됨:', output)
        return
    with tempfile.TemporaryDirectory(dir=output.parent) as temp:
        candidate = Path(temp) / release['filename']
        if args.source:
            shutil.copyfile(args.source, candidate)
        else:
            subprocess.run(['curl', '-fSL', '--retry', '2', '--connect-timeout', '10',
                            '--max-time', '120', release['url'], '-o', str(candidate)], check=True)
        verify(candidate, release)
        candidate.replace(output)
    print('공식 패키지 검증 완료:', output)


if __name__ == '__main__':
    main()
