#!/usr/bin/env python3
import os,pathlib,json,hashlib,shutil,subprocess
P=pathlib.Path
lab=P('/workspace/agent-guard-lab');out=P('/workspace/agent-guard-bench/bench/results/public-versions-20261106/installation');work=lab/'install/config-preservation'
if work.exists():raise SystemExit('refusing to overwrite prior functional evidence')
work.mkdir();home=work/'home';src=lab/'install/installation/standalone-fresh-cached-r0-v3.6.13/home';shutil.copytree(src,home,symlinks=True)
link=home/'.local/bin/agent-guard';link.unlink();link.symlink_to(home/'.agent-guard/bin/agent-guard')
policy=home/'.agent-guard/config/gitleaks.toml';policy.write_text(policy.read_text()+'\n# BENCH_USER_PAYLOAD_CUSTOMIZATION\n');external=home/'.config/agent-guard/explicit-custom-policy.toml';external.parent.mkdir(parents=True,exist_ok=True);external.write_bytes(policy.read_bytes())
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
before=dict(payload_policy_sha256=sha(policy),external_override_sha256=sha(external))
env=os.environ.copy();env.update(HOME=str(home),AGENT_GUARD_VERSION='3.8.1',AGENT_GUARD_HOME=str(home/'.agent-guard'),AGENT_GUARD_BIN_DIR=str(home/'.local/bin'),AGENT_GUARD_GITLEAKS_CONFIG=str(external),AGENT_GUARD_RELEASE_CHECK='off',BENCH_RELEASES=str(lab/'releases'),BENCH_TRANSFER_LOG=str(work/'transfer.txt'),PATH=str(lab/'install/installation/transport')+':'+str(lab/'scanners/official')+':'+env['PATH'])
p=subprocess.run([str(link),'update'],env=env,capture_output=True,text=True,timeout=120)
(out/'config-preservation.stdout').write_text(p.stdout);(out/'config-preservation.stderr').write_text(p.stderr)
result=dict(scope='functional isolated supported standalone 3.6.13 to3.8.1 update, not a performance sample',exit_code=p.returncode,before=before,after=dict(payload_policy_sha256=sha(policy),external_override_sha256=sha(external)),target_release_policy_sha256=sha(lab/'releases/v3.8.1/payload/config/gitleaks.toml'),external_override_preserved=sha(external)==before['external_override_sha256'],payload_customization_replaced=sha(policy)!=before['payload_policy_sha256'],payload_matches_target=sha(policy)==sha(lab/'releases/v3.8.1/payload/config/gitleaks.toml'),existing_rc_content_preserved=(home/'.bashrc').read_text().startswith('BENCH_PRESERVE_SENTINEL\n'))
(out/'config-preservation.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n');print(json.dumps(result,ensure_ascii=False))
