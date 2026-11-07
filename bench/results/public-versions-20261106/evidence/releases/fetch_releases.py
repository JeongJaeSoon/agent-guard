#!/usr/bin/env python3
"""공개 릴리스의 원문·실제 자산·SHA256을 보존한다. 재시도하지 않는다."""
import datetime,hashlib,json,pathlib,subprocess,tarfile
REPO='JeongJaeSoon/agent-guard'
BASE=pathlib.Path(__file__).resolve().parent
LAB=pathlib.Path('/workspace/agent-guard-lab/releases')
VERSIONS=['3.6.13','3.6.14','3.6.15','3.7.0','3.7.1','3.8.0','3.8.1']
manifest=[]
for version in VERSIONS:
    tag='v'+version
    path=BASE/tag; path.mkdir(exist_ok=True)
    assets=LAB/tag/'assets'; assets.mkdir(parents=True,exist_ok=True)
    result=subprocess.run(['gh','api',f'repos/{REPO}/releases/tags/{tag}'],capture_output=True)
    (path/'api.stderr').write_bytes(result.stderr)
    (path/'release.json').write_bytes(result.stdout)
    row={'tag':tag,'checked_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'api_returncode':result.returncode,'assets':[]}
    if result.returncode:
        manifest.append(row);continue
    rel=json.loads(result.stdout)
    row.update(commit=subprocess.check_output(['git','rev-parse',f'{tag}^{{commit}}'],text=True).strip(),tag_object=subprocess.check_output(['git','rev-parse',tag],text=True).strip(),published_at=rel['published_at'],draft=rel['draft'],prerelease=rel['prerelease'],url=rel['html_url'])
    for asset in rel['assets']:
        name=asset['name']
        if not (name in [f'agent-guard-{version}.tar.gz',f'agent-guard-{version}.tar.gz.sha256','bootstrap.sh','install.sh','agent-guard.rb','native-validation.json'] or name.startswith('agent-guard-redact-x86_64-unknown-linux-musl')):continue
        dest=assets/name
        proc=subprocess.run(['curl','--fail','--location','--silent','--show-error',asset['browser_download_url'],'--output',str(dest)],capture_output=True)
        (path/(name+'.download.stderr')).write_bytes(proc.stderr)
        item={'name':name,'url':asset['browser_download_url'],'declared_size':asset['size'],'github_digest':asset.get('digest'),'download_returncode':proc.returncode}
        if dest.exists():
            item.update(size=dest.stat().st_size,sha256=hashlib.sha256(dest.read_bytes()).hexdigest())
            item['github_digest_matches']=not asset.get('digest') or asset['digest']=='sha256:'+item['sha256']
        row['assets'].append(item)
    archive=assets/f'agent-guard-{version}.tar.gz'
    if archive.exists():
        checksum=assets/(archive.name+'.sha256')
        row['archive_checksum_matches']=checksum.exists() and checksum.read_text().split()[0]==hashlib.sha256(archive.read_bytes()).hexdigest()
        payload=LAB/tag/'payload';payload.mkdir(exist_ok=True)
        with tarfile.open(archive) as tar:tar.extractall(payload,filter='data')
        files=[]
        for f in sorted(payload.rglob('*')):
            if f.is_file():files.append({'path':str(f.relative_to(payload)),'size':f.stat().st_size,'sha256':hashlib.sha256(f.read_bytes()).hexdigest()})
        (path/'payload-files.json').write_text(json.dumps(files,indent=2)+'\n')
        row['payload_files']=len(files);row['payload_file_bytes']=sum(f['size'] for f in files)
        native=[]
        for f in payload.glob('libexec/agent-guard-redact-*'):
            if f.suffix=='.sha256':continue
            checksum=pathlib.Path(str(f)+'.sha256')
            native.append({'name':f.name,'sha256':hashlib.sha256(f.read_bytes()).hexdigest(),'checksum_matches':checksum.exists() and checksum.read_text().split()[0]==hashlib.sha256(f.read_bytes()).hexdigest()})
        row['packaged_native']=native
    manifest.append(row)
    (BASE/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
    print(tag,row['commit'],row.get('archive_checksum_matches'),row.get('payload_file_bytes'),flush=True)
