import importlib.util,pathlib,tempfile,zipfile,json,hashlib,csv,shutil,stat
ROOT=pathlib.Path(__file__).resolve().parent
def module(name):
 s=importlib.util.spec_from_file_location(name,ROOT/(name+'.py'));m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m
pack=module('package_evidence');restore=module('restore_evidence');pack.PRIMARY={'1':{'dummy'}};pack.CONTROLLED_RUN='1'
checks=[]
with tempfile.TemporaryDirectory(dir='/tmp',prefix='restore-evidence-check-') as td:
 root=pathlib.Path(td);source=root/'source';(source/'installation').mkdir(parents=True);(source/'installation/data.bin').write_bytes(bytes(range(256)));(source/'installation/한글\nname.txt').write_text('원문\n');(source/'installation/broken-link').symlink_to('../missing')
 ci=source/'evidence/ci/1';ci.mkdir(parents=True);z=ci/'dummy.zip'
 with zipfile.ZipFile(z,'w') as a:a.writestr('sample.json','{"sample":1}\n')
 (ci/'dummy.artifact.json').write_text(json.dumps({'id':42,'name':'dummy','digest':pack.sha_file(z),'size':z.stat().st_size}))
 compact=source/'evidence/ci/42227732499/extracted/public-version-installation-compact-linux';compact.mkdir(parents=True);(compact/'source-artifact.json').write_text('{"id":893,"expires_at":"2026-12-06T00:00:00Z"}');(compact/'work-file-manifest.csv').write_text('path,size,sha256\n')
 cats,arcs,missing=pack.plan(source);pack.execute(source,source/'raw',cats,arcs,missing);raw=source/'raw';target=root/'restored'
 planned=restore.restore(raw,target);assert not target.exists();done=restore.restore(raw,target,True);assert done['all_restored_hashes_verified'];assert (target/'installation/data.bin').read_bytes()==bytes(range(256));assert (target/'evidence/ci/1/extracted/dummy/sample.json').read_text()=='{"sample":1}\n';assert (target/'installation/broken-link').is_symlink();assert (target/'installation/broken-link').readlink()==pathlib.Path('../missing');checks.append('offline round trip:binary/UTF8/newline/broken-symlink and exact CI extraction root')
 original=(target/'installation/data.bin').stat();again=restore.restore(raw,target,True);later=(target/'installation/data.bin').stat();assert again['new_files']==0 and original.st_ino==later.st_ino and original.st_mtime_ns==later.st_mtime_ns;checks.append('identical existing files reused without changing inode or mtime')
 conflict=root/'conflict';(conflict/'installation').mkdir(parents=True);(conflict/'installation/data.bin').write_bytes(b'keep original')
 try:restore.restore(raw,conflict,True)
 except RuntimeError as e:assert 'overwrite existing' in str(e)
 else:raise AssertionError('existing different bytes overwritten')
 assert (conflict/'installation/data.bin').read_bytes()==b'keep original';assert not (conflict/'evidence').exists();checks.append('conflicting existing data refused before any destination writes')
 outside=root/'outside';outside.mkdir();symlink_target=root/'symlink-parent';symlink_target.mkdir();(symlink_target/'installation').symlink_to(outside,target_is_directory=True)
 try:restore.restore(raw,symlink_target,True)
 except RuntimeError as e:assert 'symlink parent' in str(e)
 else:raise AssertionError('existing symlink parent accepted')
 assert not list(outside.iterdir());checks.append('existing symlink directory traversal refused')
 # Self-consistent hashes must still not authorize a malicious destination path.
 evil=root/'evil-raw';evil.mkdir();ez=evil/'evil.zip'
 with zipfile.ZipFile(ez,'w') as a:a.writestr('../escape.txt','bad')
 manifest=evil/'members.csv'
 with manifest.open('w',newline='') as f:
  w=csv.DictWriter(f,fieldnames=['archive','member','bytes','sha256','type']);w.writeheader();w.writerow(dict(archive='evil.zip',member='../escape.txt',bytes=3,sha256=hashlib.sha256(b'bad').hexdigest(),type='regular'))
 idx={'archives':[dict(kind='local-installation',path='evil.zip',bytes=ez.stat().st_size,sha256=pack.sha_file(ez),member_manifest='members.csv',member_manifest_sha256=pack.sha_file(manifest),member_count=1,extraction_root='.')]} ;(evil/'index.json').write_text(json.dumps(idx))
 def sums(directory):
  files=[p for p in directory.iterdir() if p.is_file() and p.name!='SHA256SUMS'];(directory/'SHA256SUMS').write_text(''.join(pack.sha_file(p)+'  '+p.name+'\n' for p in files))
 sums(evil)
 try:restore.restore(evil,root/'evil-target',True)
 except RuntimeError as e:assert 'ZipSlip' in str(e)
 else:raise AssertionError('ZipSlip accepted')
 assert not (root/'escape.txt').exists();assert not (root/'evil-target').exists();checks.append('ZipSlip refused despite self-consistent ZIP/index/SHA256SUMS')
 bad=root/'bad-metadata';shutil.copytree(raw,bad);index=json.loads((bad/'index.json').read_text());next(r for r in index['archives'] if r['kind']=='ci-original-artifact')['artifact_id']=999;(bad/'index.json').write_text(json.dumps(index));sums(bad)
 # sums() only handles root files; retain nested manifest checksum lines too.
 lines=(bad/'SHA256SUMS').read_text();lines+=''.join(pack.sha_file(p)+'  '+p.relative_to(bad).as_posix()+'\n' for p in (bad/'manifests').iterdir());(bad/'SHA256SUMS').write_text(lines)
 try:restore.restore(bad,root/'bad-target',True)
 except RuntimeError as e:assert 'CI artifact metadata' in str(e)
 else:raise AssertionError('CI metadata ID mismatch accepted')
 assert not (root/'bad-target').exists();checks.append('retained CI artifact metadata ID/SHA verified independently of index')
 result={'success':True,'scope':'temporary synthetic fixtures only; no real benchmark ZIP packaging/restoration or source mutation','checks':checks,'valid_restore':done}
(ROOT/'evidence-restore-tool-validation.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n');print(json.dumps(result,ensure_ascii=False))
