#!/usr/bin/env python3
"""Package immutable benchmark evidence; planning is the default.

Run --execute only after every producer has stopped. Source data are never moved,
rewritten, normalized or deleted. Output is built in a sibling staging directory
and committed atomically only after hashes, metadata and source stability pass.
"""
from __future__ import annotations
import argparse,csv,hashlib,json,os,pathlib,re,shutil,stat,tempfile,time,zipfile
P=pathlib.Path
PRIMARY={
 '42224583403':{f'public-version-benchmark-linux-{s}-{h}' for s in ('official','homebrew') for h in ('claude','codex')}|{f'public-version-correctness-linux-{s}-{p}' for s in ('official','homebrew') for p in ('fixed','packaged')},
 '42224583622':{f'public-version-rss-linux-{s}-{h}' for s in ('official','homebrew') for h in ('claude','codex')},
 '42227732499':{'public-version-installation-compact-linux'},
}
CONTROLLED_ARTIFACTS={f'public-version-controlled-linux-{s}-{h}' for s in ('official','homebrew') for h in ('claude','codex')}
SHIPPING_RUN_IDS=frozenset(PRIMARY)
CONTROLLED_RUN='42232755942'
PRIMARY[CONTROLLED_RUN]=set(CONTROLLED_ARTIFACTS)
CATEGORIES={
 'local-installation':('installation',),
 'local-correctness':('correctness',),
 'components-local':('runtime/components-local',),
 'runtime-local':('runtime/local-pilot','runtime/local-pilot-attribution','runtime/policy-access-local','runtime/policy-access-local-ptrace-enabled','runtime/common-policy-proof-local','runtime/*.py','runtime/*.sh','runtime/*.ko.md','runtime/*.json','runtime/Dockerfile'),
 'ci-attempts':('evidence/ci',),
}
SUSPECTS={
 'authorization-credential':re.compile(rb'Authorization\s*:\s*(?:Bearer|Basic|token)\s+(?!\*|<|\$)[A-Za-z0-9_+=/.-]{16,}',re.I),
 'github-token-like':re.compile(rb'(?:github_pat_[A-Za-z0-9_]{30,}|gh[pousr]_[A-Za-z0-9]{30,})'),
 'signed-download-url':re.compile(rb'https?://[^\s"<>]+[?&](?:X-Amz-(?:Signature|Credential|Security-Token)|X-Goog-Signature|sig)=[^\s"<>]+',re.I),
}
def sha_file(path):
 h=hashlib.sha256()
 with path.open('rb') as f:
  for block in iter(lambda:f.read(1024*1024),b''):h.update(block)
 return h.hexdigest()
def snapshot(path):
 s=path.lstat();return (s.st_dev,s.st_ino,s.st_size,s.st_mtime_ns,s.st_mode)
def gather(base,roots,ci_attempts=False):
 result=[]
 expanded=[p for pattern in roots for p in (sorted(base.glob(pattern)) if any(c in pattern for c in '*?[') else [base/pattern])]
 for root in expanded:
  if not root.exists() and not root.is_symlink():continue
  if root.is_file() or root.is_symlink():result.append(root);continue
  for parent,dirs,files in os.walk(root,followlinks=False):
   dirs[:]=sorted(d for d in dirs if d!='__pycache__' and not (ci_attempts and (d=='extracted' or d.startswith(('extracted-','recovered-')))))
   for d in tuple(dirs):
    path=P(parent)/d
    if path.is_symlink():result.append(path);dirs.remove(d)
   for name in sorted(files):
    path=P(parent)/name
    if name.endswith(('.pyc','.pyo')):continue
    if ci_attempts and name.endswith('.zip'):continue
    if not path.is_file() and not path.is_symlink():raise RuntimeError('unsupported special source: '+str(path))
    result.append(path)
 return sorted(set(result),key=lambda p:p.relative_to(base).as_posix())
def normalize_digest(value):
 value=(value or '').removeprefix('sha256:')
 return value.lower() if re.fullmatch('[0-9a-fA-F]{64}',value) else None
def artifact_records(ci):
 records=[]
 def walk(x):
  if isinstance(x,dict):
   if 'id' in x and 'name' in x and ('size' in x or 'size_in_bytes' in x) and 'digest' in x:records.append(x)
   for value in x.values():walk(value)
  elif isinstance(x,list):
   for value in x:walk(value)
 for run in sorted(ci.iterdir()) if ci.exists() else []:
  if not run.is_dir():continue
  for p in sorted(run.glob('*.json')):
   try:walk(json.loads(p.read_text()))
   except (json.JSONDecodeError,UnicodeDecodeError):continue
 return records
def find_metadata(path,records,digest=None):
 sidecar=path.with_suffix('.artifact.json')
 meta=json.loads(sidecar.read_text()) if sidecar.exists() else None
 matches=([r for r in records if r.get('id')==meta.get('id')] if meta else [r for r in records if digest and normalize_digest(r.get('digest'))==digest])
 if matches:
  full=max(matches,key=len)
  if meta and normalize_digest(full.get('digest'))!=normalize_digest(meta.get('digest')):raise RuntimeError('artifact sidecar conflicts with API metadata: '+str(path))
  meta={**full,**(meta or {})}
 return meta

def plan(base):
 categories={name:gather(base,roots,name=='ci-attempts') for name,roots in CATEGORIES.items()}
 ci=base/'evidence/ci';archives=sorted(ci.glob('*/*.zip')) if ci.exists() else []
 missing=[]
 if not CONTROLLED_RUN:missing.append('controlled-run-id-required:4new-common-policy-artifacts')
 for run,expected in PRIMARY.items():
  available={p.stem for p in (ci/run).glob('*.zip')}
  missing += [f'{run}/{name}.zip' for name in sorted(expected-available)]
 return categories,archives,missing

def scan_ci_credentials(paths,base):
 # Corpus deliberately contains synthetic secrets. Only CI status/log sources are
 # scanned here. Findings contain location/detector only, never credential bytes.
 findings=[]
 for path in paths:
  if path.is_symlink():continue
  previous=b''
  with path.open('rb') as f:
   for block in iter(lambda:f.read(1024*1024),b''):
    data=previous+block
    for name,pattern in SUSPECTS.items():
     if pattern.search(data):findings.append({'path':path.relative_to(base).as_posix(),'detector':name});break
    previous=data[-2048:]
 return list({(x['path'],x['detector']):x for x in findings}.values())
def csv_write(path,rows,fields):
 with path.open('w',newline='',encoding='utf-8') as f:
  writer=csv.DictWriter(f,fieldnames=fields);writer.writeheader();writer.writerows(rows)
def write_local_archive(path,files,base,manifest):
 records=[]
 with zipfile.ZipFile(path,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=6,allowZip64=True) as archive:
  for source in files:
   before=snapshot(source);name=source.relative_to(base).as_posix();h=hashlib.sha256();size=0
   if source.is_symlink():
    stamp=time.localtime(source.lstat().st_mtime)[:6];info=zipfile.ZipInfo(name,stamp if stamp[0]>=1980 else (1980,1,1,0,0,0));info.compress_type=zipfile.ZIP_DEFLATED
    info.create_system=3;info.external_attr=(stat.S_IFLNK|0o777)<<16;payload=os.fsencode(os.readlink(source));archive.writestr(info,payload);h.update(payload);size=len(payload);kind='symlink'
   else:
    info=zipfile.ZipInfo.from_file(source,name,strict_timestamps=False);info.compress_type=zipfile.ZIP_DEFLATED
    with source.open('rb') as stream,archive.open(info,'w',force_zip64=True) as target:
     for block in iter(lambda:stream.read(1024*1024),b''):target.write(block);h.update(block);size+=len(block)
    kind='regular'
   if snapshot(source)!=before:raise RuntimeError('source changed during packaging: '+name)
   records.append(dict(archive=path.name,member=name,bytes=size,sha256=h.hexdigest(),type=kind))
 csv_write(manifest,records,['archive','member','bytes','sha256','type'])
 return records

def manifest_existing_archive(path,manifest):
 records=[]
 with zipfile.ZipFile(path) as archive:
  for info in archive.infolist():
   if info.is_dir():continue
   h=hashlib.sha256();size=0
   with archive.open(info) as stream:
    for block in iter(lambda:stream.read(1024*1024),b''):h.update(block);size+=len(block)
   if size!=info.file_size:raise RuntimeError('archive member size mismatch: '+path.name)
   records.append(dict(archive=path.name,member=info.filename,bytes=size,sha256=h.hexdigest(),type='symlink' if stat.S_ISLNK(info.external_attr>>16) else 'regular'))
 csv_write(manifest,records,['archive','member','bytes','sha256','type']);return records

def execute(base,output,categories,archives,missing):
 if missing:raise RuntimeError('primary artifacts not complete: '+', '.join(missing))
 if output.exists():raise RuntimeError('refusing to overwrite prior package: '+str(output))
 suspects=scan_ci_credentials(categories['ci-attempts'],base)
 if suspects:raise RuntimeError('possible credential material; ask parent to inspect without printing values: '+json.dumps(suspects))
 compact_inputs=base/'evidence/ci/42227732499/extracted/public-version-installation-compact-linux'
 source_files=sorted({p for files in categories.values() for p in files}|set(archives)|{compact_inputs/'source-artifact.json',compact_inputs/'work-file-manifest.csv'});before={p:snapshot(p) for p in source_files}
 records=artifact_records(base/'evidence/ci');index=[]
 with tempfile.TemporaryDirectory(prefix='.evidence-package-',dir=base) as tmp:
  stage=P(tmp)/'raw';stage.mkdir();manifests=stage/'manifests';manifests.mkdir()
  for name,files in categories.items():
   dest=stage/(name+'.zip');manifest=manifests/(name+'.members.csv');members=write_local_archive(dest,files,base,manifest)
   index.append(dict(kind=name,status='supplemental-local' if name!='ci-attempts' else 'provenance-and-failures',path=dest.name,bytes=dest.stat().st_size,sha256=sha_file(dest),member_count=len(members),member_manifest=manifest.relative_to(stage).as_posix(),member_manifest_sha256=sha_file(manifest),source_paths=list(CATEGORIES[name]),extraction_root='.',metadata_sha_verified=None,run_id=None,artifact_id=None,source_url=None,expires_at=None))
  for source in archives:
   run=source.parent.name;primary=run in PRIMARY and source.stem in PRIMARY[run]
   digest=sha_file(source);meta=find_metadata(source,records,digest)
   expected=normalize_digest(meta.get('digest')) if meta else None
   expected_size=(meta.get('size_in_bytes',meta.get('size'))) if meta else None
   verified=bool(meta and expected==digest and int(expected_size)==source.stat().st_size)
   if primary and not verified:raise RuntimeError('primary artifact metadata SHA/size verification failed: '+str(source))
   if primary and meta.get('name')!=source.stem:raise RuntimeError('required artifact filename differs from API name: '+str(source))
   metadata_run=(meta.get('run') or meta.get('workflow_run',{}).get('id')) if meta else None
   if metadata_run is not None and str(metadata_run)!=run:raise RuntimeError('artifact API run identity differs from source directory: '+str(source))
   if expected and expected!=digest:raise RuntimeError('artifact metadata SHA mismatch, including quarantined attempt: '+str(source))
   dest=stage/((f'ci-{run}-' if primary else f'cancelled-or-partial-ci-{run}-')+source.name);shutil.copyfile(source,dest)
   if sha_file(dest)!=digest:raise RuntimeError('artifact byte copy changed: '+source.name)
   manifest=manifests/(dest.stem+'.members.csv');members=manifest_existing_archive(dest,manifest)
   artifact_name=meta.get('name',source.stem) if meta else source.stem
   cohort=('common-policy' if run==CONTROLLED_RUN else 'shipping-policy' if source.stem.startswith(('public-version-benchmark-','public-version-rss-')) else 'installation' if 'installation' in source.stem else 'accuracy-auxiliary') if primary else 'cancelled-or-partial'
   index.append(dict(kind='ci-original-artifact',status=(('controlled-primary-complete' if cohort=='common-policy' else cohort+'-complete') if primary else 'quarantined-cancelled-or-partial'),cohort=cohort,required_final_artifact=primary,path=dest.name,bytes=dest.stat().st_size,sha256=digest,member_count=len(members),member_manifest=manifest.relative_to(stage).as_posix(),member_manifest_sha256=sha_file(manifest),source_paths=[source.relative_to(base).as_posix()],extraction_root=f'evidence/ci/{run}/extracted/{artifact_name}' if primary else f'evidence/ci/{run}/extracted-cancelled/{source.stem}',metadata_sha_verified=verified,run_id=run,artifact_name=artifact_name,artifact_id=meta.get('id') if meta else None,source_commit=meta.get('workflow_run',{}).get('head_sha') if meta else None,source_url=meta.get('url',f"https://api.github.com/repos/JeongJaeSoon/agent-guard/actions/artifacts/{meta['id']}") if meta else None,expires_at=meta.get('expires_at') if meta else None))
  # Include the compact omission explanation and complete repeated-public-file
  # manifest as independently hashed, directly readable raw-sidecar evidence.
  compact=base/'evidence/ci/42227732499/extracted/public-version-installation-compact-linux'
  supporting=[]
  for name in ['source-artifact.json','work-file-manifest.csv']:
   src=compact/name
   if not src.is_file():raise RuntimeError('compact source provenance missing: '+str(src))
   dest=stage/('compact-installation-'+name);shutil.copyfile(src,dest)
   supporting.append(dict(path=dest.name,bytes=dest.stat().st_size,sha256=sha_file(dest),source=src.relative_to(base).as_posix()))
  omitted=json.loads((compact/'source-artifact.json').read_text())
  note={'omitted_repeated_public_payload_archive':omitted,'reason':'893MB original installation artifact repeats already-public immutable payload copies for each sample. Compact export preserved every measured row, log, transfer and test sentinel plus complete8712-fileSHA/size manifest; it did not rerun measurements. Original source URL and expiry are retained. Public release asset hashes are tracked in evidence/releases.','supporting_files':supporting}
  (stage/'compact-installation-provenance.json').write_text(json.dumps(note,ensure_ascii=False,indent=2)+'\n')
  payload={'schema':1,'archives':index,'supporting_files':supporting,'omitted_repeated_public_payload_artifact':omitted,'exclusions':['__pycache__','*.pyc','*.pyo','CI extracted/recovered trees (original artifact ZIPs retained byte-for-byte)' ],'member_manifest_scope':'Every non-directory archive member has a SHA256 and uncompressed size in its external CSV. Symlink hashes cover link-target bytes, without following links. Manifests are outside archives and indexed by their own SHA256.','restore':'Local ZIP member paths are relative to benchmark base; CI original ZIPs must be extracted under their index extraction_root. Never merge quarantined cancelled/partial artifacts into primary roots.'}
  (stage/'index.json').write_text(json.dumps(payload,ensure_ascii=False,indent=2)+'\n')
  flat=[{k:(json.dumps(v,ensure_ascii=False) if isinstance(v,list) else v) for k,v in row.items()} for row in index]
  csv_write(stage/'index.csv',flat,list(dict.fromkeys(k for row in flat for k in row)))
  # Re-open archives and verify every member manifest before publication.
  validation=[]
  for row in index:
   path=stage/row['path'];assert sha_file(path)==row['sha256']
   with (stage/row['member_manifest']).open(newline='',encoding='utf-8') as f:expected=list(csv.DictReader(f))
   with zipfile.ZipFile(path) as archive:
    for member in expected:
     h=hashlib.sha256();size=0
     with archive.open(member['member']) as stream:
      for block in iter(lambda:stream.read(1024*1024),b''):h.update(block);size+=len(block)
     if h.hexdigest()!=member['sha256'] or size!=int(member['bytes']):raise RuntimeError('reopened member verification failed')
   validation.append({'path':row['path'],'members_verified':len(expected),'sha256':row['sha256']})
  after_categories,after_archives,after_missing=plan(base)
  if after_missing or after_archives!=archives or any(after_categories[k]!=v for k,v in categories.items()):raise RuntimeError('evidence file set changed during packaging')
  if any(snapshot(p)!=value for p,value in before.items()):raise RuntimeError('source metadata changed during packaging')
  (stage/'validation.json').write_text(json.dumps({'source_files_unchanged':len(before),'archives':validation,'all_member_hashes_verified':True,'required_final_artifacts':sum(map(len,PRIMARY.values())),'controlled_primary_artifacts':sum(name.startswith('public-version-controlled-') for names in PRIMARY.values() for name in names),'shipping_runtime_rss_artifacts':sum(name.startswith(('public-version-benchmark-','public-version-rss-')) for names in PRIMARY.values() for name in names)},ensure_ascii=False,indent=2)+'\n')
  # SHA256SUMS intentionally excludes itself (self-referential hash impossible).
  files=sorted(p for p in stage.rglob('*') if p.is_file())
  (stage/'SHA256SUMS').write_text(''.join(sha_file(p)+'  '+p.relative_to(stage).as_posix()+'\n' for p in files))
  output.parent.mkdir(parents=True,exist_ok=True);os.replace(stage,output)
 return payload

def main():
 global CONTROLLED_RUN
 ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--base',type=P,default=P(__file__).resolve().parents[1]);ap.add_argument('--output',type=P);ap.add_argument('--controlled-run',default=CONTROLLED_RUN,help='required final common-policy run ID; adds four mandatory artifacts');ap.add_argument('--execute',action='store_true',help='only after parent final signal and producers have stopped');ap.add_argument('--plan-file',type=P);args=ap.parse_args()
 if args.controlled_run:
  if not str(args.controlled_run).isdigit():raise SystemExit('controlled run ID must be numeric')
  CONTROLLED_RUN=str(args.controlled_run)
  if CONTROLLED_RUN in SHIPPING_RUN_IDS:raise SystemExit('controlled run must be independent of shipping-policy/RSS/export runs')
  for prior in tuple(PRIMARY):
   if prior not in SHIPPING_RUN_IDS and prior!=CONTROLLED_RUN:del PRIMARY[prior]
  PRIMARY[CONTROLLED_RUN]=set(CONTROLLED_ARTIFACTS)
 base=args.base.resolve();output=(args.output or base/'raw').resolve()
 if output==base or base in output.parents and output.relative_to(base).parts[0] in ('installation','correctness','runtime','evidence'):raise SystemExit('output must not overlap input evidence categories')
 categories,archives,missing=plan(base)
 report={'mode':'execute' if args.execute else 'plan-only-no-evidence-write','category_files':{k:len(v) for k,v in categories.items()},'category_source_bytes_uncompressed':{k:sum(p.lstat().st_size for p in v) for k,v in categories.items()},'ci_archives':[str(p.relative_to(base)) for p in archives],'missing_primary_artifacts':missing,'output':str(output),'source_mutations':'none; final packaging refuses existing output and changed input sources'}
 if args.plan_file:args.plan_file.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
 if args.execute:
  result=execute(base,output,categories,archives,missing);report['archive_count']=len(result['archives'])
 print(json.dumps(report,ensure_ascii=False,indent=2))
if __name__=='__main__':main()
