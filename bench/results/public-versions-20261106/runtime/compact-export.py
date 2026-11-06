#!/usr/bin/env python3
"""Copy existing measurement evidence; never invoke an installer or measured CLI."""
import argparse,csv,hashlib,json,shutil,zipfile
from pathlib import Path,PurePosixPath

ROOT=Path(__file__).resolve().parents[1]
EXPECTED_ID=13504968499
EXPECTED_SIZE=893256346
EXPECTED_SHA='ef01d7c3a1aa7a73532215ecd261e3ac33a35636ccb06dcda01cd9bb1e842ed7'

def digest_stream(stream):
    h=hashlib.sha256();magic=b''
    while block:=stream.read(1024*1024):
        if not magic:magic=block[:4]
        h.update(block)
    return h.hexdigest(),magic

def known_public():
    hashes={}
    for version in json.loads((ROOT/'evidence/releases/manifest.json').read_text()):
        tag=version['tag']
        for asset in version['assets']:
            hashes.setdefault(asset['sha256'],[]).append(asset['url'])
        for file in json.loads((ROOT/'evidence/releases'/tag/'payload-files.json').read_text()):
            hashes.setdefault(file['sha256'],[]).append(f"release:{tag}/{file['path']}")
    hashes['551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb']=['https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_linux_x64.tar.gz']
    hashes['88f91962aa2f93ac6ab281d553b9e125f5197bbbce38f9f2437f7299c32e5509']=['official:gitleaks-8.30.1-linux_x64/gitleaks']
    return hashes

def export(archive,metadata,out,check_pin=True):
    if out.exists():raise ValueError('refusing to overwrite previous export')
    meta=json.loads(metadata.read_text())
    with archive.open('rb') as f:actual,_=digest_stream(f)
    if check_pin and (meta['id']!=EXPECTED_ID or archive.stat().st_size!=EXPECTED_SIZE or actual!=EXPECTED_SHA or meta['digest']!='sha256:'+EXPECTED_SHA):
        raise ValueError('original artifact identity/digest mismatch; no replacement allowed')
    public=known_public();out.mkdir(parents=True);rows=[]
    with zipfile.ZipFile(archive) as source:
        for item in source.infolist():
            if item.is_dir():continue
            path=PurePosixPath(item.filename)
            if path.is_absolute() or '..' in path.parts:raise ValueError('unsafe archive path')
            with source.open(item) as f:sha,magic=digest_stream(f)
            is_work=bool(path.parts) and path.parts[0]=='installation-work'
            binary=magic in [b'\x7fELF',b'\xcf\xfa\xed\xfe',b'\xce\xfa\xed\xfe',b'\xfe\xed\xfa\xcf',b'\xfe\xed\xfa\xce',b'\xca\xfe\xba\xbe']
            entrypoint=path.name=='agent-guard' and any(x.endswith('/bin/agent-guard') for x in public.get(sha,[]))
            archive_copy=path.name.endswith(('.tar.gz','.tgz'))
            omit=is_work and sha in public and (binary or entrypoint or archive_copy)
            row=dict(path=str(path),size=item.file_size,compressed_size=item.compress_size,sha256=sha,zip_crc32=f'{item.CRC:08x}',zip_mode=oct(item.external_attr>>16),retained=not omit,omission_reason='verified copy of downloadable public executable/archive' if omit else '',public_sources=' | '.join(public.get(sha,[])))
            rows.append(row)
            if not omit:
                dest=out/path;dest.parent.mkdir(parents=True,exist_ok=True)
                with source.open(item) as src,dest.open('wb') as dst:shutil.copyfileobj(src,dst,1024*1024)
    with (out/'work-file-manifest.csv').open('w',newline='') as f:
        w=csv.DictWriter(f,fieldnames=list(rows[0]));w.writeheader();w.writerows(rows)
    (out/'source-artifact.json').write_text(json.dumps(meta,ensure_ascii=False,indent=2)+'\n')
    summary=dict(source_run_id=42224583403,source_artifact_id=meta['id'],source_artifact_size=archive.stat().st_size,source_artifact_sha256=actual,source_artifact_url=f"https://github.com/JeongJaeSoon/agent-guard/actions/runs/42224583403/artifacts/{meta['id']}",source_artifact_expires_at=meta.get('expires_at'),files=len(rows),retained_files=sum(r['retained'] for r in rows),omitted_files=sum(not r['retained'] for r in rows),retained_bytes=sum(r['size'] for r in rows if r['retained']),omitted_public_bytes=sum(r['size'] for r in rows if not r['retained']),scope='read-only export of existing measurements; no product CLI, installer, scanner or benchmark rerun; omit only SHA-verified downloadable public executables/archives under installation-work; retain all other evidence')
    (out/'export-summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2)+'\n')
    (out/'EXPORT.ko.md').write_text('''# 설치 원시 자료의 소형 내보내기

이 자료는 이미 완료한 설치 실험의 기존 artifact를 읽어서 만든다. 설치나 성능 측정을 다시 실행하지 않는다. 원본 ZIP의 ID·크기·SHA-256을 고정 검증한다.

`installation-work` 안에서 공개 릴리스/고정 scanner와 SHA-256이 일치하는 실행 파일·배포 압축 파일의 반복 복사만 제외했다. 그 밖의 결과 JSON, 로그, 전송 기록, 반환 상태, 사용자 설정 sentinel, `.bashrc`, 보존 파일 및 중간 생성물은 유지한다. 모든 원본 파일의 경로·크기·SHA-256·ZIP mode와 제외 사유는 `work-file-manifest.csv`에 남는다.

원본 전체 artifact의 URL과 만료일은 `source-artifact.json` 및 `export-summary.json`을 참고한다. GitHub 원본의 보존 기간은 30일이며 영구 보존이라고 주장하지 않는다. 이 소형 원시 자료는 보고서 저장소에 함께 보존한다.
''')
    return summary

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--archive',type=Path,required=True);p.add_argument('--metadata',type=Path,required=True);p.add_argument('--out',type=Path,required=True);a=p.parse_args();print(json.dumps(export(a.archive,a.metadata,a.out),ensure_ascii=False))
