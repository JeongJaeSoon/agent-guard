#!/usr/bin/env python3
"""공개 배포본만 내려받아 기록된 SHA-256과 비교한다. 재시도/대체 없음."""
import argparse, hashlib, json, os, subprocess, tarfile, time, urllib.request
from pathlib import Path

BASE=Path(__file__).resolve().parents[1]

def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def save_json(path, value): path.write_text(json.dumps(value,ensure_ascii=False,indent=2)+'\n')
def fetch(url,path,sha=None):
    started=time.monotonic()
    with urllib.request.urlopen(url,timeout=60) as source, path.open('wb') as dest:
        while block:=source.read(1024*1024): dest.write(block)
    actual=digest(path)
    row=dict(url=url,file=str(path),download_seconds=time.monotonic()-started,size=path.stat().st_size,sha256=actual,expected_sha256=sha)
    save_json(path.with_suffix(path.suffix+'.download.json'),row)
    if sha is not None and actual!=sha: raise ValueError(f'checksum mismatch: {path}')
    return row

def extract(archive,target,strip=0):
    target.mkdir(parents=True,exist_ok=False)
    with tarfile.open(archive) as tar:
        for item in tar.getmembers():
            parts=Path(item.name).parts
            if item.name.startswith('/') or '..' in parts or item.isdev(): raise ValueError('unsafe archive member')
            if strip:
                parts=parts[strip:]
                if not parts: continue
                item.name='/'.join(parts)
            if item.issym() and (item.linkname.startswith('/') or '..' in Path(item.linkname).parts): raise ValueError('unsafe archive symlink')
            tar.extract(item,target,filter='data')

p=argparse.ArgumentParser(); p.add_argument('--lab',required=True); p.add_argument('--manifest',default=str(BASE/'evidence/releases/manifest.json')); p.add_argument('--evidence',required=True)
a=p.parse_args(); lab=Path(a.lab).resolve(); ev=Path(a.evidence).resolve(); lab.mkdir(parents=True,exist_ok=True); ev.mkdir(parents=True,exist_ok=True)
manifest=json.loads(Path(a.manifest).read_text()); rows=[]
for version in manifest:
    tag=version['tag']; dest=lab/'releases'/tag; (dest/'assets').mkdir(parents=True,exist_ok=False)
    if version.get('draft') or version.get('prerelease'): raise ValueError(f'not public stable release {tag}')
    for asset in version['assets']:
        path=dest/'assets'/asset['name']; rows.append(fetch(asset['url'],path,asset['sha256']))
        if path.name.endswith('.tar.gz'):
            extract(path,dest/'payload')
    tarpath=dest/'assets'/f"agent-guard-{tag[1:]}.tar.gz"
    check=tarpath.with_suffix(tarpath.suffix+'.sha256').read_text().split()[0]
    if digest(tarpath)!=check: raise ValueError('published archive checksum mismatch')
    for check in (dest/'payload/libexec').glob('*.sha256'):
        named=check.read_text().split(); binary=check.parent/named[-1]
        if digest(binary)!=named[0]: raise ValueError('packaged native checksum mismatch')
    source=dest/'source.tar.gz'
    rows.append(fetch(f"https://codeload.github.com/JeongJaeSoon/agent-guard/tar.gz/{version['commit']}",source))
    extract(source,dest/'source',strip=1)
    if (dest/'source/plugins/agent-guard/bin/agent-guard').read_bytes()!=(dest/'payload/bin/agent-guard').read_bytes(): raise ValueError('source plugin/release CLI mismatch')
    save_json(ev/'downloads.json',rows)
scanner=lab/'scanners/official'; scanner.mkdir(parents=True,exist_ok=False)
archive=scanner.parent/'official.tar.gz'; rows.append(fetch('https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_linux_x64.tar.gz',archive,'551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb'))
with tarfile.open(archive) as tar:
    member=tar.getmember('gitleaks')
    if not member.isfile(): raise ValueError('scanner is not a regular file')
    scanner.joinpath('gitleaks').write_bytes(tar.extractfile(member).read())
scanner.joinpath('gitleaks').chmod(0o755)
if digest(scanner/'gitleaks')!='88f91962aa2f93ac6ab281d553b9e125f5197bbbce38f9f2437f7299c32e5509': raise ValueError('scanner binary checksum mismatch')
save_json(ev/'downloads.json',rows)
save_json(ev/'scanner-official.json',dict(version=subprocess.check_output([str(scanner/'gitleaks'),'version'],text=True).strip(),sha256=digest(scanner/'gitleaks'),archive_sha256=digest(archive)))
