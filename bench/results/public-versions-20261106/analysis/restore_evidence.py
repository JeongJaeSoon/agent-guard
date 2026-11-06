#!/usr/bin/env python3
"""Safely restore the archived benchmark evidence offline (Linux).

Default: verify and plan only. --execute restores new files, reuses identical
existing bytes without changing them, and refuses any conflicting existing data.
All archive hashes, member hashes and retained CI artifact metadata are checked
before creating destination files. No network calls or source deletion.
"""
from __future__ import annotations
import argparse,csv,hashlib,json,os,pathlib,re,stat,tempfile,zipfile
P=pathlib.Path

def digest_file(path):
 h=hashlib.sha256()
 with path.open('rb') as f:
  for block in iter(lambda:f.read(1024*1024),b''):h.update(block)
 return h.hexdigest()
def relative_parts(value,allow_dot=False):
 if not isinstance(value,str) or '\x00' in value or '\\' in value or re.match(r'^[A-Za-z]:',value):raise RuntimeError('unsafe archive path')
 path=pathlib.PurePosixPath(value)
 if path.is_absolute() or '..' in path.parts or not path.parts and not allow_dot:raise RuntimeError('ZipSlip/empty path rejected')
 return path.parts

def safe_raw_file(raw,value):
 parts=relative_parts(value);path=raw.joinpath(*parts)
 current=raw
 for part in parts:
  current=current/part
  if current.is_symlink():raise RuntimeError('symlink in raw source path rejected')
 if not path.is_file():raise RuntimeError('missing raw source: '+value)
 return path

def normalized_sha(value):
 value=(value or '').removeprefix('sha256:')
 return value.lower() if re.fullmatch('[A-Fa-f0-9]{64}',value) else None

def checksum_sources(raw):
 sums=safe_raw_file(raw,'SHA256SUMS');result={}
 for line in sums.read_text().splitlines():
  expected,name=line.split('  ',1)
  if not normalized_sha(expected) or name in result:raise RuntimeError('invalid or duplicate SHA256SUMS entry')
  path=safe_raw_file(raw,name)
  if digest_file(path)!=expected:raise RuntimeError('raw source hash mismatch: '+name)
  result[name]=expected
 if 'index.json' not in result:raise RuntimeError('index.json absent from SHA256SUMS')
 return result

def artifact_records(index,raw):
 records=[]
 def walk(value):
  if isinstance(value,dict):
   if 'id' in value and 'name' in value and 'digest' in value and ('size' in value or 'size_in_bytes' in value):records.append(value)
   for x in value.values():walk(x)
  elif isinstance(value,list):
   for x in value:walk(x)
 for row in index['archives']:
  if row.get('kind')!='ci-attempts':continue
  with zipfile.ZipFile(safe_raw_file(raw,row['path'])) as archive:
   for info in archive.infolist():
    if info.is_dir() or not info.filename.endswith('.json'):continue
    try:walk(json.loads(archive.read(info)))
    except (json.JSONDecodeError,UnicodeDecodeError):continue
 return records

def verify_sources(raw):
 sums=checksum_sources(raw);index=json.loads(safe_raw_file(raw,'index.json').read_text());ci_records=artifact_records(index,raw);seen_archives=set()
 for row in index['archives']:
  name=row['path'];manifest=row['member_manifest']
  if name in seen_archives:raise RuntimeError('duplicate archive index entry')
  seen_archives.add(name)
  if name not in sums or manifest not in sums:raise RuntimeError('archive/manifest missing from global checksum inventory')
  path=safe_raw_file(raw,name)
  if sums[name]!=row['sha256'] or path.stat().st_size!=row['bytes']:raise RuntimeError('archive index hash/size mismatch: '+name)
  if sums[manifest]!=row['member_manifest_sha256']:raise RuntimeError('member manifest index hash mismatch')
  if row.get('kind')=='ci-original-artifact' and row.get('metadata_sha_verified'):
   matches=[r for r in ci_records if r.get('id')==row.get('artifact_id') and (not row.get('artifact_name') or r.get('name')==row['artifact_name']) and normalized_sha(r.get('digest'))==row['sha256'] and int(r.get('size_in_bytes',r.get('size',-1)))==row['bytes']]
   if not matches:raise RuntimeError('retained CI artifact metadata does not verify original ZIP: '+name)
 return index,sums

def inspect_parent_components(base,parts):
 current=base
 for part in parts[:-1]:
  current=current/part
  try:mode=current.lstat().st_mode
  except FileNotFoundError:continue
  if not stat.S_ISDIR(mode) or stat.S_ISLNK(mode):raise RuntimeError('existing non-directory/symlink parent rejected')

def existing_state(base,entry):
 parts=entry['parts'];inspect_parent_components(base,parts);path=base.joinpath(*parts)
 try:mode=path.lstat().st_mode
 except FileNotFoundError:return 'new'
 if entry['type']=='symlink':
  if not stat.S_ISLNK(mode) or os.fsencode(os.readlink(path))!=entry['link_bytes']:raise RuntimeError('refusing to overwrite existing data: '+entry['relative'])
 elif not stat.S_ISREG(mode) or digest_file(path)!=entry['sha256']:
  raise RuntimeError('refusing to overwrite existing data: '+entry['relative'])
 return 'reuse-identical'

def plan_entries(raw,base,index):
 planned={};members_verified=0
 for row in index['archives']:
  root_parts=relative_parts(row.get('extraction_root','.'),allow_dot=True)
  with safe_raw_file(raw,row['member_manifest']).open(newline='',encoding='utf-8') as f:manifest=list(csv.DictReader(f))
  if len(manifest)!=row['member_count']:raise RuntimeError('member count mismatch')
  with zipfile.ZipFile(safe_raw_file(raw,row['path'])) as archive:
   infos=archive.infolist();names=[i.filename for i in infos if not i.is_dir()]
   if len(set(names))!=len(names):raise RuntimeError('duplicate ZIP member paths rejected')
   for info in infos:relative_parts(info.filename)
   if set(names)!={r['member'] for r in manifest}:raise RuntimeError('manifest does not cover exact ZIP member set')
   for member in manifest:
    info=archive.getinfo(member['member']);parts=root_parts+relative_parts(info.filename);relative='/'.join(parts)
    h=hashlib.sha256();length=0;link_chunks=[];kind='symlink' if stat.S_ISLNK(info.external_attr>>16) else 'regular'
    if kind!=member['type'] or not normalized_sha(member['sha256']):raise RuntimeError('member type/SHA invalid')
    with archive.open(info) as stream:
     for block in iter(lambda:stream.read(1024*1024),b''):
      h.update(block);length+=len(block)
      if kind=='symlink':
       if length>1024*1024:raise RuntimeError('oversized symlink target rejected')
       link_chunks.append(block)
    if length!=int(member['bytes']) or h.hexdigest()!=member['sha256']:raise RuntimeError('member byte hash/size mismatch')
    entry={'parts':parts,'relative':relative,'sha256':member['sha256'],'bytes':length,'type':kind,'archive':row['path'],'member':info.filename,'mode':(info.external_attr>>16)&0o777}
    if kind=='symlink':
     entry['link_bytes']=b''.join(link_chunks)
     if b'\x00' in entry['link_bytes']:raise RuntimeError('NUL symlink target rejected')
    if relative in planned:
     prior=planned[relative]
     if any(prior[k]!=entry[k] for k in ['sha256','bytes','type']):raise RuntimeError('conflicting archive destinations')
    else:planned[relative]=entry
    members_verified+=1
 for entry in planned.values():
  for n in range(1,len(entry['parts'])):
   if '/'.join(entry['parts'][:n]) in planned:raise RuntimeError('planned file/symlink parent traversal rejected')
  entry['action']=existing_state(base,entry)
 return list(planned.values()),members_verified

def parent_fd(base_fd,parts,create=False):
 fd=os.dup(base_fd)
 try:
  for part in parts[:-1]:
   if create:
    try:os.mkdir(part,0o755,dir_fd=fd)
    except FileExistsError:pass
   child=os.open(part,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=fd);os.close(fd);fd=child
  return fd
 except BaseException:os.close(fd);raise

def restore(raw,base,execute=False):
 raw=raw.resolve();base=base.resolve()
 if base==raw or raw in base.parents:raise RuntimeError('destination must not be raw source or inside it')
 if base.exists() and (not base.is_dir() or base.is_symlink()):raise RuntimeError('invalid target directory')
 index,sums=verify_sources(raw);entries,member_count=plan_entries(raw,base,index)
 summary={'mode':'execute' if execute else 'verify-and-plan-only','archives_verified':len(index['archives']),'members_verified':member_count,'unique_destinations':len(entries),'new_files':sum(e['action']=='new' for e in entries),'reused_identical':sum(e['action']=='reuse-identical' for e in entries),'source_mutations':'none','different_existing_data':'refused','cohort_separation':'index extraction roots preserve shipping-policy, controlled and cancelled/partial original paths'}
 if not execute:return summary
 base.parent.mkdir(parents=True,exist_ok=True);base.mkdir(exist_ok=True)
 base_fd=os.open(base,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
 try:
  # Stage all new regular content on the destination filesystem before publication.
  with tempfile.TemporaryDirectory(prefix='.evidence-restore-',dir=base) as temp:
   staged={}
   for n,entry in enumerate(entries):
    if entry['action']!='new' or entry['type']!='regular':continue
    path=P(temp)/str(n);h=hashlib.sha256()
    with zipfile.ZipFile(safe_raw_file(raw,entry['archive'])) as archive,archive.open(entry['member']) as stream,path.open('xb') as target:
     for block in iter(lambda:stream.read(1024*1024),b''):target.write(block);h.update(block)
    if h.hexdigest()!=entry['sha256']:raise RuntimeError('raw ZIP changed during restore')
    os.chmod(path,entry['mode'] or 0o644);staged[entry['relative']]=path
   # Regular files first, links last. dirfd + O_NOFOLLOW blocks symlink-parent races.
   ordered=sorted(entries,key=lambda e:e['type']=='symlink')
   for entry in ordered:
    if entry['action']=='reuse-identical':continue
    fd=parent_fd(base_fd,entry['parts'],create=True)
    try:
     if entry['type']=='regular':os.link(staged[entry['relative']],entry['parts'][-1],dst_dir_fd=fd,follow_symlinks=False)
     else:os.symlink(os.fsdecode(entry['link_bytes']),entry['parts'][-1],dir_fd=fd)
    finally:os.close(fd)
   # Verify every restored/reused byte; do not modify reused files or their modes.
   for entry in entries:
    fd=parent_fd(base_fd,entry['parts'])
    try:
     if entry['type']=='symlink':actual=hashlib.sha256(os.fsencode(os.readlink(entry['parts'][-1],dir_fd=fd))).hexdigest()
     else:
      f=os.open(entry['parts'][-1],os.O_RDONLY|os.O_NOFOLLOW,dir_fd=fd);h=hashlib.sha256()
      with os.fdopen(f,'rb') as stream:
       for block in iter(lambda:stream.read(1024*1024),b''):h.update(block)
      actual=h.hexdigest()
     if actual!=entry['sha256']:raise RuntimeError('restored/reused content changed')
    finally:os.close(fd)
 finally:os.close(base_fd)
 # Original raw source bytes must remain unchanged after all operations.
 for name,expected in sums.items():
  if digest_file(safe_raw_file(raw,name))!=expected:raise RuntimeError('raw source changed during restore')
 summary['all_restored_hashes_verified']=True;return summary

def main():
 ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--raw',type=P,required=True);ap.add_argument('--base',type=P,required=True);ap.add_argument('--execute',action='store_true');args=ap.parse_args();print(json.dumps(restore(args.raw,args.base,args.execute),ensure_ascii=False,indent=2))
if __name__=='__main__':main()
