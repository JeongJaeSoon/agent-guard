#!/usr/bin/env python3
"""보고서·원시 자료·재현 도구를 ZIP으로 묶고 모든 member를 다시 검증한다."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import zipfile


def sha(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--repo', required=True)
    parser.add_argument('--out', required=True)
    args = parser.parse_args()
    repo = Path(args.repo).resolve()
    out = Path(args.out).resolve()
    base = Path('bench/results/public-versions-20261106')
    assert not out.exists(), 'Refuse to overwrite an existing delivery archive'
    names = subprocess.check_output([
        'git', '-C', str(repo), 'ls-files', '--cached', '--others',
        '--exclude-standard', '-z', '--', str(base),
    ]).decode().split('\0')
    extras = ['tests/fixtures/native-contracts.json']
    extras += [str(p.relative_to(repo)) for p in (repo/'.github/workflows').glob('*public-version*.yml')]
    names = sorted(set(x for x in names + extras if x))
    names = [x for x in names if x != str(base/'analysis/delivery-validation.json')]
    records = []
    with zipfile.ZipFile(out, 'x', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name in names:
            path = repo/name
            if path.is_symlink() or not path.is_file():
                raise RuntimeError(f'Unexpected non-regular file: {name}')
            data = path.read_bytes()
            archive.writestr(name, data)
            records.append(dict(path=name, size=len(data), sha256=sha(data)))
        manifest = dict(scope='Frozen report, preserved raw evidence, reproduction tools; no public product binaries', files=records)
        archive.writestr('DELIVERY-MANIFEST.json', json.dumps(manifest, ensure_ascii=False, indent=2)+'\n')
        archive.writestr('START-HERE.ko.md', '# Agent Guard 공개 7버전 실측 보고서\n\n'
            'ZIP을 푼 뒤 [한국어 HTML](bench/results/public-versions-20261106/report/report.ko.html)을 연다. '
            'HTML에는 데이터·스크립트·스타일이 내장되어 있다. 관리 브라우저의 file URL 정책은 별도다.\n\n'
            '[Markdown](bench/results/public-versions-20261106/report/README.ko.md), '
            '[재현 방법](bench/results/public-versions-20261106/REPRODUCE.ko.md), '
            '[원시 자료 인덱스](bench/results/public-versions-20261106/raw/index.json)를 함께 제공한다.\n\n'
            '측정을 재현하려면 Git 저장소를 준비하고 동일 상대 경로에 파일을 둔다. '
            '공개 배포 파일은 고정 URL에서 다시 받고 SHA를 검증한다. 제품 변경·병합·새 릴리스는 포함하지 않는다.\n')
    with zipfile.ZipFile(out) as archive:
        assert archive.testzip() is None
        for record in records:
            assert sha(archive.read(record['path'])) == record['sha256'], record['path']
        assert json.loads(archive.read('DELIVERY-MANIFEST.json')) == manifest
    result = dict(archive=str(out), size=out.stat().st_size, sha256=sha(out.read_bytes()),
                  verified_files=len(records), all_member_hashes_equal=True,
                  manifest_inside_archive='DELIVERY-MANIFEST.json')
    (repo/base/'analysis/delivery-validation.json').write_text(json.dumps(result, ensure_ascii=False, indent=2)+'\n')
    print(json.dumps(result, ensure_ascii=False))


if __name__ == '__main__':
    main()
