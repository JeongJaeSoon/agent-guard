import hashlib
import json
import pathlib
import subprocess
import sys
import tarfile

version, expected_sha, destination = sys.argv[1:]
root = pathlib.Path(destination)
root.mkdir(parents=True, exist_ok=False)
repo = "JeongJaeSoon/agent-guard"
metadata = json.loads(subprocess.check_output([
    "gh", "api", f"repos/{repo}/releases/tags/v{version}"
]))
assert not metadata["draft"] and not metadata["prerelease"]
assert metadata["tag_name"] == f"v{version}"
tag = json.loads(subprocess.check_output([
    "gh", "api", f"repos/{repo}/git/ref/tags/v{version}"
]))
assert tag["object"]["type"] == "commit"
assert tag["object"]["sha"] == expected_sha
(root / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
targets = ["x86_64-unknown-linux-musl", "aarch64-unknown-linux-musl",
           "x86_64-apple-darwin", "aarch64-apple-darwin"]
archive = f"agent-guard-{version}.tar.gz"
expected = {archive, archive + ".sha256", "agent-guard.rb", "install.sh",
            "bootstrap.sh", "THIRD_PARTY_NOTICES.md", "native-validation.json"}
for target in targets:
    expected.update({f"agent-guard-redact-{target}", f"agent-guard-redact-{target}.sha256"})
assert {a["name"] for a in metadata["assets"]} == expected
assets = []
for asset in metadata["assets"]:
    name = asset["name"]
    url = asset["browser_download_url"]
    assert url == f"https://github.com/{repo}/releases/download/v{version}/{name}"
    subprocess.run(["curl", "-fLsS", url, "-o", str(root / name)], check=True)
    digest = hashlib.sha256((root / name).read_bytes()).hexdigest()
    assert asset["digest"] == "sha256:" + digest, name
    assets.append({"name": name, "sha256": digest, "verified": True})
for checksum in root.glob("*.sha256"):
    digest, name = checksum.read_text().strip().split()
    assert name == checksum.name.removesuffix(".sha256")
    assert hashlib.sha256((root / name).read_bytes()).hexdigest() == digest
qualification = json.loads((root / "native-validation.json").read_text())
assert qualification["release_sha"] == expected_sha
assert set(qualification["targets"]) == set(targets)
prefix = f"https://github.com/{repo}/actions/runs/"
assert qualification["native_workflow_url"].startswith(prefix)
run_id = qualification["native_workflow_url"][len(prefix):]
assert run_id.isdigit()
run = json.loads(subprocess.check_output(["gh", "api", f"repos/{repo}/actions/runs/{run_id}"]))
assert run["head_sha"] == expected_sha and run["conclusion"] == "success"
assert run["event"] == "push" and run["head_branch"] == "main"
assert run["path"] == ".github/workflows/native-platforms.yml"
for name in ["bootstrap.sh", "install.sh", "THIRD_PARTY_NOTICES.md"]:
    reviewed = subprocess.check_output(["git", "show", f"{expected_sha}:{name}"])
    assert (root / name).read_bytes() == reviewed, name
archive_digest = hashlib.sha256((root / archive).read_bytes()).hexdigest()
formula = subprocess.check_output(["sh", "scripts/render-homebrew-formula.sh", version, archive_digest])
assert (root / "agent-guard.rb").read_bytes() == formula
payload = root / "payload"
payload.mkdir()
with tarfile.open(root / archive) as tf:
    for member in tf.getmembers():
        path = pathlib.PurePosixPath(member.name)
        assert not path.is_absolute() and ".." not in path.parts
        assert member.isdir() or member.isfile()
        dest = payload.joinpath(*path.parts)
        if member.isdir():
            dest.mkdir(parents=True, exist_ok=True)
        else:
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(tf.extractfile(member).read())
            dest.chmod(member.mode & 0o777)
for name in ["install.sh", "THIRD_PARTY_NOTICES.md"]:
    assert (payload / name).read_bytes() == (root / name).read_bytes()
for target in targets:
    name = f"agent-guard-redact-{target}"
    assert (payload / "libexec" / name).read_bytes() == (root / name).read_bytes()
    assert (payload / "libexec" / (name + ".sha256")).read_bytes() == (root / (name + ".sha256")).read_bytes()
assert (payload / "bin/agent-guard").read_bytes() == subprocess.check_output(["git", "show", f"{expected_sha}:plugins/agent-guard/bin/agent-guard"])
assert subprocess.check_output([str(payload / "bin/agent-guard"), "version"], text=True).strip() == "agent-guard " + version
for manifest in [".claude-plugin/plugin.json", ".codex-plugin/plugin.json"]:
    assert json.loads((payload / manifest).read_text())["version"] == version
    assert (payload / manifest).read_bytes() == subprocess.check_output(["git", "show", f"{expected_sha}:plugins/agent-guard/{manifest}"])
summary = {"tag": "v" + version, "release_sha": expected_sha,
           "assets": assets, "all_native_assets_match_archive": True,
           "cli_and_host_versions_match": True, "reviewed_installers_and_notices_match": True,
           "rendered_formula_matches": True, "qualification_is_exact_main_push": True}
(root / "verification.json").write_text(json.dumps(summary, indent=2) + "\n")
print(json.dumps(summary, indent=2))
