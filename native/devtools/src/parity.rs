use crate::common::*;
use crate::hooks::{hook_command, hook_event, key_block, Sandbox};
use serde_json::{json, Map, Value};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::os::unix::process::ExitStatusExt;
use std::path::Path;

// What two runs of one build may differ in, and what is therefore left out of
// the comparison. Everything else is compared byte for byte.
const UNSTABLE: &[&str] = &[
    "audit events: run_id, time and duration_seconds, and the event file's name",
    "the CLI's cache files in the state directory (gitleaks-probe, gitleaks-clean, deny-path-regex, gitleaks-helper): content, and in their names every run of digits and every run of 8 or more hexadecimal characters (times, file identities, hashes)",
    "inside the repository's .git: content of the logs and the objects (the logs hold times; an object is named by its content), and the index beyond what git ls-files --stage -v lists (file times and sizes)",
    "the warning directory: the user number in its name, and a line of digits only in a marker (the time it was written)",
    "each side's own plugin root in output, read as one placeholder",
];

struct Side {
    cli: String,
    root: String,
    shell: Option<String>,
}
/// One thing a step changed: a label safe to publish, the name compared, the
/// permission bits, and the bytes compared (empty where only the name is).
type Change = (&'static str, String, u32, Vec<u8>);
/// An entry of the sandbox: its permission bits and what it holds.
type Entry = (u32, Vec<u8>);
struct Outcome {
    status: i32,
    stdout: Vec<u8>,
    stderr: Vec<u8>,
    state: Vec<Change>,
}

/// Replace the corpus placeholders. The text of a case is never echoed.
fn expand(value: &Value, vars: &[(&str, String)]) -> Result<Value> {
    Ok(match value {
        Value::String(text) => {
            let mut text = text.clone();
            for (name, replacement) in vars {
                text = text.replace(name, replacement);
            }
            ensure(!text.contains("{{"), "unknown placeholder")?;
            Value::String(text)
        }
        Value::Array(items) => Value::Array(
            items
                .iter()
                .map(|item| expand(item, vars))
                .collect::<Result<_>>()?,
        ),
        Value::Object(fields) => {
            let mut out = Map::new();
            for (key, item) in fields {
                out.insert(key.clone(), expand(item, vars)?);
            }
            Value::Object(out)
        }
        other => other.clone(),
    })
}

/// A file name without the parts that change from run to run.
fn stable_name(path: &str) -> String {
    let mut out = String::new();
    let mut run = String::new();
    let flush = |run: &mut String, out: &mut String| {
        if !run.is_empty() && (run.len() >= 8 || run.chars().all(|c| c.is_ascii_digit())) {
            out.push('#');
        } else {
            out.push_str(run);
        }
        run.clear();
    };
    for c in path.chars() {
        if c.is_ascii_hexdigit() {
            run.push(c);
        } else {
            flush(&mut run, &mut out);
            out.push(c);
        }
    }
    flush(&mut run, &mut out);
    out
}

/// Every entry of the sandbox but the scanner directory: the repository,
/// home, state and temporary directories and anything left beside them. A
/// directory is an entry of its own (named with a trailing slash): an empty
/// one can be state, and so can its permissions. Anything that cannot be read fails the
/// comparison; only an entry that vanished meanwhile is skipped.
fn tree(base: &Path) -> Result<BTreeMap<String, Entry>> {
    use std::os::unix::fs::PermissionsExt;
    fn gone<T>(result: std::io::Result<T>) -> Result<Option<T>> {
        match result {
            Ok(value) => Ok(Some(value)),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(format!("cannot read the state a step left: {error}").into()),
        }
    }
    fn walk(dir: &Path, prefix: &str, out: &mut BTreeMap<String, Entry>) -> Result<()> {
        let Some(entries) = gone(std::fs::read_dir(dir))? else {
            return Ok(());
        };
        for entry in entries {
            let Some(entry) = gone(entry)? else { continue };
            let file_name = entry.file_name();
            let file_name = file_name.to_string_lossy();
            // The scanner directory both sides share is watched apart.
            if prefix.is_empty() && file_name == "bin" {
                continue;
            }
            let name = if prefix.is_empty() {
                file_name.to_string()
            } else {
                format!("{prefix}/{file_name}")
            };
            let Some(meta) = gone(std::fs::symlink_metadata(entry.path()))? else {
                continue;
            };
            let mode = meta.permissions().mode() & 0o7777;
            let kind = meta.file_type();
            if kind.is_dir() {
                out.insert(format!("{name}/"), (mode, Vec::new()));
                walk(&entry.path(), &name, out)?;
            } else if kind.is_file() {
                if let Some(bytes) = gone(std::fs::read(entry.path()))? {
                    out.insert(name, (mode, bytes));
                }
            } else if kind.is_symlink() {
                if let Some(target) = gone(std::fs::read_link(entry.path()))? {
                    out.insert(
                        name,
                        (0, format!("link to {}", target.display()).into_bytes()),
                    );
                }
            } else {
                out.insert(name, (mode, b"not a regular file".to_vec()));
            }
        }
        Ok(())
    }
    let mut out = BTreeMap::new();
    walk(base, "", &mut out)?;
    Ok(out)
}

/// One entry of a directory: name, size, mode and modification time.
type Listed = (String, u64, u32, i64, i64);
/// The entries of the scanner directory with what a write would change.
fn scanner_directory(bin: &Path) -> Result<Vec<Listed>> {
    use std::os::unix::fs::MetadataExt;
    let mut entries = Vec::new();
    for entry in std::fs::read_dir(bin)? {
        let entry = entry?;
        let meta = std::fs::symlink_metadata(entry.path())?;
        entries.push((
            entry.file_name().to_string_lossy().to_string(),
            meta.len(),
            meta.mode(),
            meta.mtime(),
            meta.mtime_nsec(),
        ));
    }
    entries.sort();
    Ok(entries)
}

/// How one path is compared, and the label the report may show for it.
fn change(path: &str, entry: &Entry) -> Change {
    const CACHES: [&str; 4] = [
        "s/agent-guard/gitleaks-probe",
        "s/agent-guard/gitleaks-clean/",
        "s/agent-guard/deny-path-regex-",
        "s/agent-guard/gitleaks-helper/",
    ];
    // The logs hold times; an object is named by its content.
    const GIT_VOLATILE: [&str; 2] = ["repo/.git/logs/", "repo/.git/objects/"];
    let (mode, bytes) = (entry.0, entry.1.as_slice());
    let directory = path.ends_with('/');
    let (dir, name) = path.rsplit_once('/').unwrap_or(("", path));
    let warning = path
        .strip_prefix("t/agent-guard-warnings-")
        .filter(|rest| rest.starts_with(|c: char| c.is_ascii_digit()));
    let (label, name, bytes): (&'static str, String, Vec<u8>) =
        if path.starts_with("s/") && name.starts_with("event-") {
            let events: Vec<String> = String::from_utf8_lossy(bytes)
                .lines()
                .map(|line| match parse(line.as_bytes()) {
                    Ok(Value::Object(mut event)) => {
                        for key in ["run_id", "time", "duration_seconds"] {
                            event.remove(key);
                        }
                        Value::Object(event).to_string()
                    }
                    _ => line.to_owned(),
                })
                .collect();
            (
                "audit-event",
                format!("{dir}/event"),
                events.join("\n").into_bytes(),
            )
        } else if CACHES.iter().any(|cache| path.starts_with(cache)) {
            ("cache", stable_name(path), Vec::new())
        } else if let Some(rest) = warning {
            // The warning directory is named for the user, and a marker in it
            // holds the time it was written on a line of its own.
            let lines: Vec<&[u8]> = bytes
                .split(|byte| *byte == b'\n')
                .map(|line| {
                    if !line.is_empty() && line.iter().all(u8::is_ascii_digit) {
                        b"#".as_slice()
                    } else {
                        line
                    }
                })
                .collect();
            let marker = rest.trim_start_matches(|c: char| c.is_ascii_digit());
            let label = if directory {
                "temporary-directory"
            } else {
                "temporary-file"
            };
            (
                label,
                format!("t/agent-guard-warnings-#{marker}"),
                lines.join(&b'\n'),
            )
        } else if path == "s/agent-guard/rundir-reap" {
            // A line per temp directory, led by the time it was last reaped.
            let lines: Vec<Vec<u8>> = bytes
                .split(|byte| *byte == b'\n')
                .map(|line| {
                    let digits = line.iter().take_while(|byte| byte.is_ascii_digit()).count();
                    if digits == 0 {
                        line.to_vec()
                    } else {
                        [b"#".as_slice(), &line[digits..]].concat()
                    }
                })
                .collect();
            ("state-file", path.to_owned(), lines.join(&b'\n'))
        } else if path.starts_with("repo/.git/") {
            let volatile = GIT_VOLATILE.iter().any(|prefix| path.starts_with(prefix));
            (
                "git-internal",
                path.to_owned(),
                if volatile { Vec::new() } else { bytes.to_vec() },
            )
        } else {
            // Everything else is compared as it is, name and content.
            let label = match (path.split('/').next().unwrap_or_default(), directory) {
                ("s", true) => "state-directory",
                ("s", false) => "state-file",
                ("t", true) => "temporary-directory",
                ("t", false) => "temporary-file",
                ("repo", _) => "repository-file",
                ("home", _) => "home-file",
                _ => "sandbox-file",
            };
            (label, path.to_owned(), bytes.to_vec())
        };
    (label, name, mode, bytes)
}

/// The sandbox as a step leaves it. The index is read as Git lists it: its
/// bytes hold file times, its entries (mode, object, stage, flags) do not.
fn snapshot(sandbox: &Sandbox) -> Result<BTreeMap<String, Entry>> {
    let mut entries = tree(&sandbox.base)?;
    if let Some(index) = entries.get_mut("repo/.git/index") {
        let command = ["git", "-C", &sandbox.repo, "ls-files", "--stage", "-v"].map(String::from);
        let mut env = sandbox.env();
        env.insert("GIT_OPTIONAL_LOCKS".into(), "0".into());
        let (_, out) = invoke_isolated(&command, b"", &env, None, 30.0)?;
        index.1 = [format!("{}\n", out.status).into_bytes(), out.stdout].concat();
    }
    Ok(entries)
}

/// Remove whatever a side left in the sandbox beside the scanner directory.
fn clear(base: &Path) -> Result<()> {
    for entry in std::fs::read_dir(base)? {
        let entry = entry?;
        if entry.file_name() == "bin" {
            continue;
        }
        if entry.file_type()?.is_dir() {
            remove_tree(&entry.path())?;
        } else {
            std::fs::remove_file(entry.path())?;
        }
    }
    Ok(())
}

/// What one step changed, in a fixed order.
fn transition(before: &BTreeMap<String, Entry>, after: &BTreeMap<String, Entry>) -> Vec<Change> {
    let mut out: Vec<Change> = after
        .iter()
        .filter(|(path, entry)| before.get(*path) != Some(entry))
        .map(|(path, entry)| change(path, entry))
        .collect();
    for path in before.keys().filter(|path| !after.contains_key(*path)) {
        out.push(("removed", change(path, &(0, Vec::new())).1, 0, Vec::new()));
    }
    out.sort();
    out
}

/// What a host reads from a plugin manifest. The command of an event that a
/// step ran is left out: it was compared by running it. Every other command
/// is compared as text, so a change this corpus did not exercise still shows.
fn dispatch(root: &str, host: &str, ran: &[(String, String)]) -> Result<Value> {
    let file = if host == "codex" {
        "hooks.json"
    } else {
        "hooks/hooks.json"
    };
    let mut manifest = read_json(Path::new(root).join(file))?;
    let events = manifest["hooks"]
        .as_object_mut()
        .ok_or("invalid plugin manifest")?;
    for (event, groups) in events {
        let groups = groups.as_array_mut().ok_or("invalid plugin manifest")?;
        // Only the first command of an event is run here.
        ensure(
            groups.len() == 1
                && groups[0]["hooks"]
                    .as_array()
                    .is_some_and(|hooks| hooks.len() == 1),
            format!("the {host} manifest has more than one command for {event}"),
        )?;
        if ran.iter().any(|(h, e)| h == host && e == event) {
            groups[0]["hooks"][0]
                .as_object_mut()
                .ok_or("invalid plugin manifest")?
                .remove("command");
        }
    }
    Ok(manifest)
}

/// A fixed word for what the host is told: never a value from the output.
fn decision(status: i32, stdout: &[u8]) -> String {
    if status < 0 {
        return format!("signal-{}", -status);
    }
    if status == 2 {
        return "block".into();
    }
    if status != 0 {
        return format!("exit-{status}");
    }
    if stdout.is_empty() {
        return "allow".into();
    }
    let Ok(value) = parse(stdout) else {
        return "text".into();
    };
    let specific = &value["hookSpecificOutput"];
    let mut labels = Vec::new();
    if value["decision"] == "block" {
        labels.push("block");
    }
    match specific["permissionDecision"].as_str() {
        Some("allow") => labels.push("permission-allow"),
        Some("deny") => labels.push("permission-deny"),
        Some("ask") => labels.push("permission-ask"),
        Some(_) => labels.push("permission-other"),
        None => {}
    }
    if value["continue"] == false {
        labels.push("stop");
    }
    for (key, label) in [
        ("updatedToolOutput", "rewrite-output"),
        ("updatedInput", "rewrite-input"),
        ("additionalContext", "context"),
    ] {
        if !specific[key].is_null() {
            labels.push(label);
        }
    }
    if !value["systemMessage"].is_null() {
        labels.push("message");
    }
    if labels.is_empty() {
        "json".into()
    } else {
        labels.join("+")
    }
}

fn replace(bytes: &[u8], from: &[u8], to: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i..].starts_with(from) {
            out.extend_from_slice(to);
            i += from.len();
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    out
}

/// Equality, sizes and the first differing offset: never the bytes.
fn compared(a: &[u8], b: &[u8]) -> Value {
    let first = a
        .iter()
        .zip(b)
        .position(|(x, y)| x != y)
        .or((a.len() != b.len()).then(|| a.len().min(b.len())));
    json!({"equal": a == b, "bytes": [a.len(), b.len()], "first_difference": first})
}

const CORPUS: &str = "tests/fixtures/cli-differential.json";

/// The report of a comparison that could not start or finish says so; an
/// earlier report at the same path never outlives a failed run.
pub fn differential(args: &Args) -> Result<()> {
    use std::os::unix::fs::MetadataExt;
    let out_path = std::path::PathBuf::from(args.get("--out")?);
    // The report never replaces a file the comparison reads.
    let identity = |path: &Path| std::fs::metadata(path).ok().map(|m| (m.dev(), m.ino()));
    if let Some(out) = identity(&out_path) {
        let mut inputs: Vec<String> = [
            "--baseline",
            "--candidate",
            "--scanner",
            "--corpus",
            "--baseline-shell",
            "--candidate-shell",
        ]
        .iter()
        .filter_map(|option| args.get(option).ok())
        .collect();
        inputs.extend(
            root()
                .ok()
                .map(|root| root.join(CORPUS).display().to_string()),
        );
        inputs.extend(version(&["sh", "-c", "command -v gitleaks"]).ok());
        ensure(
            !inputs
                .iter()
                .any(|input| identity(Path::new(input)) == Some(out)),
            "--out names a file the comparison reads",
        )?;
    }
    match std::fs::remove_file(&out_path) {
        Err(error) if error.kind() != std::io::ErrorKind::NotFound => return Err(error.into()),
        _ => {}
    }
    if let Some(parent) = out_path.parent().filter(|p| !p.as_os_str().is_empty()) {
        std::fs::create_dir_all(parent)?;
    }
    let result = compare(args, &out_path);
    if let (Err(error), false) = (&result, out_path.exists()) {
        write_json(
            &out_path,
            &json!({"tool": "cli-differential", "complete": false, "aborted": {"case": null, "error": error.to_string()}}),
        )?;
    }
    result
}

/// The commands a report may name; any other first argument is "other".
const COMMANDS: [&str; 12] = [
    "hook-pre-tool",
    "hook-post-tool",
    "hook-post-tool-failure",
    "hook-stop",
    "hook-user-prompt",
    "hook-session-start",
    "scan-staged",
    "scan-working-tree",
    "scan-path",
    "exec",
    "pii-filter",
    "version",
];

fn compare(args: &Args, out_path: &Path) -> Result<()> {
    let timeout: f64 = args.opt("--timeout", "60").parse()?;
    ensure(
        timeout.is_finite() && timeout > 0.0,
        "timeout must be positive",
    )?;
    let entry = args.opt("--entry", "direct");
    ensure(
        ["direct", "manifest"].contains(&entry.as_str()),
        "entry must be direct or manifest",
    )?;
    let manifest = entry == "manifest";
    let side = |name: &str| -> Result<Side> {
        let cli = absolute(args.get(&format!("--{name}"))?)?;
        let root = Path::new(&cli)
            .parent()
            .and_then(Path::parent)
            .ok_or("the CLI has no plugin root")?
            .display()
            .to_string();
        let shell = args.get(&format!("--{name}-shell")).ok();
        ensure(
            !manifest || shell.is_none(),
            "a manifest command chooses its own shell",
        )?;
        Ok(Side { cli, root, shell })
    };
    let sides = [side("baseline")?, side("candidate")?];
    let scanner = absolute(args.opt(
        "--scanner",
        version(&["sh", "-c", "command -v gitleaks"]).unwrap_or_default(),
    ))?;
    let corpus_path = match args.get("--corpus") {
        Ok(path) => path,
        Err(_) => root()?.join(CORPUS).display().to_string(),
    };
    let corpus = read_json(&corpus_path)?;
    let selected = args.all("--case");
    // The locale every hook runs in; without the option they get none. One
    // this system lacks would leave both sides in the C locale without a
    // word, so the name has to be one that `locale -a` lists.
    let locale = match args.get("--locale") {
        Ok(name) => {
            ensure(
                !name.is_empty()
                    && name
                        .chars()
                        .all(|c| c.is_ascii_alphanumeric() || "_.@-".contains(c)),
                "locale must be a locale name",
            )?;
            // The name this system lists is the one a hook gets: another
            // spelling can pass here and still not be a locale to the C library.
            let plain = |name: &str| name.to_ascii_lowercase().replace('-', "");
            let installed = version(&["locale", "-a"])?
                .lines()
                .find(|listed| plain(listed) == plain(&name))
                .map(str::to_owned)
                .ok_or(format!("this system has no locale {name}"))?;
            Some(installed)
        }
        Err(_) => None,
    };

    let sandbox = Sandbox::new()?;
    eprintln!("sandbox {}", sandbox.base.display());
    // Outside the directories a reset rebuilds, so both sides run one file.
    let bin = sandbox.base.join("bin");
    std::fs::create_dir(&bin)?;
    std::fs::copy(&scanner, bin.join("gitleaks"))?;
    let installed = scanner_directory(&bin)?;
    // Asked before any step: a side may leave no repository to ask from.
    let scanner_version =
        sandbox.version(&[&bin.join("gitleaks").display().to_string(), "version"])?;
    let digest = |label: &str| format!("{:x}", Sha256::digest(label));
    let vars = [
        ("{{REPO}}", sandbox.repo.clone()),
        ("{{KEY_BLOCK}}", key_block()),
        (
            "{{TOKEN}}",
            format!("{}{}", "ghp_", &digest("synthetic token")[..36]),
        ),
        ("{{HEX}}", digest("synthetic value")[..40].to_owned()),
    ];
    // The whole corpus is checked before anything runs.
    let mut cases = Vec::new();
    for case in corpus.as_array().ok_or("the corpus is not an array")? {
        let name = case["name"].as_str().ok_or("a case has no name")?;
        let invalid = |what: &str| format!("case {name}: {what}");
        let case = expand(case, &vars).map_err(|error| invalid(&error.to_string()))?;
        ensure(
            ["claude", "codex"].contains(&case["host"].as_str().unwrap_or("claude")),
            invalid("unknown host"),
        )?;
        let steps = case["steps"].as_array().filter(|steps| !steps.is_empty());
        for step in steps.ok_or_else(|| invalid("no steps"))? {
            let args = step["args"].as_array().filter(|args| !args.is_empty());
            ensure(
                args.is_some_and(|args| args.iter().all(Value::is_string))
                    && (step["stdin"].is_string() != step.get("input").is_some()),
                invalid("a step needs args and either input or stdin"),
            )?;
        }
        for (field, key_ok) in [("env", true), ("files", false)] {
            let fields = case.get(field).map(|v| v.as_object().ok_or(()));
            let ok = match fields {
                None => true,
                Some(Err(())) => false,
                Some(Ok(fields)) => fields.iter().all(|(key, value)| {
                    value.is_string()
                        && if key_ok {
                            // No path but one that names nothing: a path
                            // could move the CLI's writes out of the sandbox
                            // both sides are rebuilt from.
                            let text = value.as_str().unwrap_or_default();
                            key.starts_with("AGENT_GUARD_")
                                && (!text.contains('/')
                                    || text.starts_with("/nonexistent/")
                                        && !text.split('/').any(|part| part == ".."))
                        } else {
                            !key.starts_with('/') && !key.split('/').any(|part| part == "..")
                        }
                }),
            };
            ensure(ok, invalid(&format!("invalid {field}")))?;
        }
        if selected.is_empty() || selected.iter().any(|s| s == name) {
            cases.push(case);
        }
    }
    for name in &selected {
        ensure(
            cases.iter().any(|case| case["name"] == name.as_str()),
            format!("unknown case: {name}"),
        )?;
    }
    ensure(!cases.is_empty(), "the corpus has no case")?;
    let run_case = |case: &Value, side: &Side| -> Result<Vec<Outcome>> {
        clear(&sandbox.base)?;
        sandbox.reset()?;
        let repo = Path::new(&sandbox.repo);
        if let Some(files) = case["files"].as_object() {
            for (path, content) in files {
                let path = repo.join(path);
                std::fs::create_dir_all(path.parent().ok_or("invalid file path")?)?;
                std::fs::write(path, content.as_str().unwrap_or_default())?;
            }
        }
        if case["stage"] == true {
            sandbox.git(&["add", "-A"])?;
        }
        let host = case["host"].as_str().unwrap_or("claude");
        let mut outcomes = Vec::new();
        for step in case["steps"].as_array().unwrap() {
            let args: Vec<String> = step["args"]
                .as_array()
                .unwrap()
                .iter()
                .map(|arg| arg.as_str().unwrap().to_owned())
                .collect();
            let mut env = sandbox.env();
            // No locale of the caller's reaches a hook: the option sets the only one.
            env.retain(|name, _| name != "LANG" && !name.starts_with("LC_"));
            if let Some(locale) = &locale {
                env.insert("LC_ALL".into(), locale.clone());
            }
            env.insert(
                "AGENT_GUARD_GITLEAKS_BIN_DIR".into(),
                bin.display().to_string(),
            );
            env.insert(
                "XDG_STATE_HOME".into(),
                sandbox.base.join("s").display().to_string(),
            );
            if let Some(extra) = case["env"].as_object() {
                for (name, value) in extra {
                    env.insert(name.clone(), value.as_str().unwrap_or_default().to_owned());
                }
            }
            let mut command = if args.len() == 1 && args[0].starts_with("hook-") {
                hook_command(&side.cli, manifest, host, &args[0], &mut env)?
            } else {
                env.insert("AGENT_GUARD_HOOK_HOST".into(), host.into());
                let mut command = vec![side.cli.clone()];
                command.extend(args);
                command
            };
            if let Some(shell) = &side.shell {
                command.insert(0, shell.clone());
            }
            let input = match step["stdin"].as_str() {
                Some(text) => text.as_bytes().to_vec(),
                None => serde_json::to_vec(&step["input"])?,
            };
            let before = snapshot(&sandbox)?;
            let (_, out) = invoke_isolated(&command, &input, &env, Some(repo), timeout)?;
            let state = transition(&before, &snapshot(&sandbox)?);
            // The scanner is shared by both sides and every case.
            ensure(
                scanner_directory(&bin)? == installed,
                "a build changed the scanner directory, which no hook writes to",
            )?;
            let own = |bytes: &[u8]| replace(bytes, side.root.as_bytes(), b"<cli-root>");
            outcomes.push(Outcome {
                // A signal is its negative number: never a status a program exits with.
                status: out
                    .status
                    .code()
                    .unwrap_or_else(|| -out.status.signal().unwrap_or(0)),
                stdout: own(&out.stdout),
                stderr: own(&out.stderr),
                state,
            });
        }
        Ok(outcomes)
    };

    let mut rows = Vec::new();
    let mut different = Vec::new();
    // A step that cannot run ends the comparison; the report then says it is
    // incomplete instead of leaving an earlier result in place.
    let mut aborted = Value::Null;
    for case in &cases {
        let name = case["name"].as_str().unwrap();
        let both = run_case(case, &sides[0])
            .and_then(|baseline| Ok((baseline, run_case(case, &sides[1])?)));
        let (baseline, candidate) = match both {
            Ok(both) => both,
            Err(error) => {
                eprintln!("ABORTED {name}");
                aborted = json!({"case": name, "error": error.to_string()});
                break;
            }
        };
        let mut steps = Vec::new();
        let mut equal = true;
        for (index, (a, b)) in baseline.iter().zip(&candidate).enumerate() {
            let decisions = [decision(a.status, &a.stdout), decision(b.status, &b.stdout)];
            let labels = |o: &Outcome| {
                let mut counts = BTreeMap::new();
                for (label, _, _, _) in &o.state {
                    *counts.entry(*label).or_insert(0) += 1;
                }
                json!(counts)
            };
            let same = a.status == b.status
                && a.stdout == b.stdout
                && a.stderr == b.stderr
                && a.state == b.state;
            equal &= same;
            if args.flag("--names") && a.state != b.state {
                // Names can hold a session identifier: standard error only,
                // and only when asked, for a synthetic corpus.
                for (side, own, other) in [("baseline", a, b), ("candidate", b, a)] {
                    for (label, name, _, _) in own.state.iter().filter(|c| !other.state.contains(c))
                    {
                        eprintln!("  only {side}: {label} {name}");
                    }
                }
            }
            steps.push(json!({
                "command": COMMANDS
                    .iter()
                    .find(|known| case["steps"][index]["args"][0] == **known)
                    .unwrap_or(&"other"),
                "equal": same,
                "status": [a.status, b.status],
                "decision": decisions,
                "stdout": compared(&a.stdout, &b.stdout),
                "stderr": compared(&a.stderr, &b.stderr),
                "state": {"equal": a.state == b.state, "changes": {"baseline": labels(a), "candidate": labels(b)}},
            }));
        }
        eprintln!("{} {name}", if equal { "same" } else { "DIFFERENT" });
        if !equal {
            different.push(name);
        }
        rows.push(json!({"name": name, "host": case["host"].as_str().unwrap_or("claude"), "equal": equal, "steps": steps}));
    }
    // Manifest commands a step ran were compared by running them; the rest
    // of each manifest, the other commands included, is compared as text.
    let mut commands_run = Vec::new();
    if manifest && aborted.is_null() {
        let mut ran: Vec<(String, String)> = Vec::new();
        for case in &cases {
            let host = case["host"].as_str().unwrap_or("claude");
            for step in case["steps"].as_array().unwrap() {
                let args = step["args"].as_array().unwrap();
                if let (1, Some(event)) = (args.len(), args[0].as_str().and_then(hook_event)) {
                    if !ran.iter().any(|(h, e)| h == host && e == event) {
                        ran.push((host.to_owned(), event.to_owned()));
                    }
                }
            }
        }
        for (host, name) in [
            ("claude", "manifest-dispatch-claude"),
            ("codex", "manifest-dispatch-codex"),
        ] {
            if dispatch(&sides[0].root, host, &ran)? != dispatch(&sides[1].root, host, &ran)? {
                eprintln!("DIFFERENT {name}");
                different.push(name);
            }
        }
        commands_run = ran
            .iter()
            .map(|(host, event)| format!("{host} {event}"))
            .collect();
        commands_run.sort();
    }
    let describe = |side: &Side| -> Result<Value> {
        Ok(json!({"sha256": hash(&side.cli)?, "shell": side.shell}))
    };
    let report = json!({
        "tool": "cli-differential",
        "platform": version(&["uname", "-a"])?,
        "entry": entry,
        "locale": locale,
        "baseline": describe(&sides[0])?,
        "candidate": describe(&sides[1])?,
        "scanner_version": scanner_version,
        "scanner_sha256": hash(bin.join("gitleaks"))?,
        "corpus_sha256": hash(&corpus_path)?,
        "compared": "exit status, decision, standard output and standard error byte for byte, audit events and the files each step left",
        "not_compared": UNSTABLE,
        "manifest_commands_run": commands_run,
        "case_count": rows.len(),
        "complete": aborted.is_null(),
        "aborted": aborted,
        "differences": different.len(),
        "different_cases": different,
    });
    // The report is stored first: a closed standard output must not lose it.
    let mut full = report.clone();
    full["cases"] = json!(rows);
    write_json(out_path, &full)?;
    {
        use std::io::Write;
        let mut text = serde_json::to_string_pretty(&report)?;
        text.push('\n');
        let _ = std::io::stdout().write_all(text.as_bytes());
    }
    ensure(
        report["complete"] == true,
        "the comparison did not finish; see aborted",
    )?;
    ensure(
        report["differences"] == 0,
        "the two builds differ; see different_cases",
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn names_lose_only_what_changes_between_runs() {
        for (path, stable) in [
            (
                "s/agent-guard/gitleaks-probe",
                "s/agent-guard/gitleaks-probe",
            ),
            (
                "s/agent-guard/gitleaks-clean/17e87020352c6b96dec6906e458c6db6",
                "s/agent-guard/gitleaks-clean/#",
            ),
            (
                "s/agent-guard/deny-path-regex-literal-3.13.9:16777230:1795711893.046232510:L::",
                "s/agent-guard/deny-path-regex-literal-#.#.#:#:#.#:L::",
            ),
            (
                "t/agent-guard-warnings-501/infrastructure-parity",
                "t/agent-guard-warnings-#/infrastructure-parity",
            ),
            ("t/feed/decade", "t/feed/decade"),
        ] {
            assert_eq!(stable_name(path), stable);
        }
    }
    #[test]
    fn decisions_are_fixed_words() {
        for (status, stdout, word) in [
            (2, "", "block"),
            (0, "", "allow"),
            (7, "partial", "exit-7"),
            (0, "plain text", "text"),
            (
                0,
                r#"{"decision":"block","hookSpecificOutput":{"additionalContext":"x"}}"#,
                "block+context",
            ),
            (
                0,
                r#"{"hookSpecificOutput":{"permissionDecision":"deny"}}"#,
                "permission-deny",
            ),
            (
                0,
                r#"{"hookSpecificOutput":{"permissionDecision":"a value"}}"#,
                "permission-other",
            ),
            (
                0,
                r#"{"hookSpecificOutput":{"updatedToolOutput":{"stdout":"x"}}}"#,
                "rewrite-output",
            ),
            (0, r#"{"systemMessage":"x"}"#, "message"),
            (0, "{}", "json"),
        ] {
            assert_eq!(decision(status, stdout.as_bytes()), word);
        }
    }
    #[test]
    fn a_step_is_what_it_changed_without_times_and_identities() {
        let files = |rows: &[(&str, &str)]| -> BTreeMap<String, Entry> {
            rows.iter()
                .map(|(path, text)| (path.to_string(), (0o600, text.as_bytes().to_vec())))
                .collect()
        };
        let event = |id: &str, time: u32, outcome: &str| {
            format!(
                r#"{{"schema":1,"run_id":"{id}","time":{time},"command":"hook-pre-tool","outcome":"{outcome}","duration_seconds":{}}}"#,
                time % 3
            )
        };
        let before = files(&[("s/agent-guard/gitleaks-probe", "old"), ("t/gone", "x")]);
        let step = |id: &str, time: u32, outcome: &str, marker: &str, notice: &str| {
            transition(
                &before,
                &files(&[
                    ("s/agent-guard/gitleaks-probe", "new"),
                    (
                        &format!("s/agent-guard/event-{time}-{id}"),
                        &event(id, time, outcome),
                    ),
                    ("t/agent-guard-warnings-501/infrastructure-s1", marker),
                    ("t/agent-guard-warnings-501/blocked-injection-1", notice),
                ]),
            )
        };
        let a = step(
            "1795713608-FzTsrM",
            1795713608,
            "blocked",
            "1795713608
",
            "notice text
",
        );
        assert_eq!(
            a,
            step(
                "1795713609-2dTrm2",
                1795713609,
                "blocked",
                "1795713609
",
                "notice text
"
            )
        );
        assert_ne!(
            a,
            step(
                "1795713608-FzTsrM",
                1795713608,
                "pass",
                "1795713608
",
                "notice text
"
            )
        );
        assert_ne!(
            a,
            step(
                "1795713608-FzTsrM",
                1795713608,
                "blocked",
                "1795713608
",
                "other text
"
            )
        );
        let names: Vec<_> = a
            .iter()
            .map(|(label, name, _, _)| (*label, name.as_str()))
            .collect();
        assert_eq!(
            names,
            [
                ("audit-event", "s/agent-guard/event"),
                ("cache", "s/agent-guard/gitleaks-probe"),
                ("removed", "t/gone"),
                (
                    "temporary-file",
                    "t/agent-guard-warnings-#/blocked-injection-1"
                ),
                (
                    "temporary-file",
                    "t/agent-guard-warnings-#/infrastructure-s1"
                ),
            ]
        );
    }
    #[test]
    fn what_is_compared_depends_on_where_a_file_is() {
        let entry = |mode: u32, text: &str| (mode, text.as_bytes().to_vec());
        // Content counts everywhere but in caches and where Git keeps times.
        for (path, compared) in [
            ("s/agent-guard/gitleaks-clean/17e87020352c6b96", false),
            ("s/agent-guard/deny-path-regex-literal-3.13.9:1:2", false),
            ("s/agent-guard/pending-notice", true),
            ("t/agent-guard-warnings-501/blocked-injection-1", true),
            ("home/left-behind", true),
            ("repo/notes.md", true),
            // The index arrives here as Git lists it, without file times.
            ("repo/.git/index", true),
            ("left-behind", true),
            ("repo/.git/logs/HEAD", false),
            ("repo/.git/objects/ab/cdef", false),
            ("repo/.git/HEAD", true),
            ("repo/.git/config", true),
            ("repo/.git/refs/heads/main", true),
        ] {
            assert_eq!(
                change(path, &entry(0o600, "one")) != change(path, &entry(0o600, "two")),
                compared,
                "{path}"
            );
            // Permission bits count everywhere, caches included.
            assert_ne!(
                change(path, &entry(0o600, "one")),
                change(path, &entry(0o644, "one")),
                "{path}"
            );
        }
        assert_eq!(
            change("t/left-empty/", &entry(0o700, "")).0,
            "temporary-directory"
        );
        assert_eq!(change("home/x", &entry(0o600, "")).0, "home-file");
    }
    #[test]
    fn the_reap_marker_loses_only_its_times() {
        let marker = |text: &str| {
            change(
                "s/agent-guard/rundir-reap",
                &(0o600, text.as_bytes().to_vec()),
            )
        };
        assert_eq!(
            marker("1795700000 /sandbox/t\n1795700001 /tmp\n"),
            marker("1795700042 /sandbox/t\n1795700043 /tmp\n")
        );
        assert_ne!(
            marker("1795700000 /sandbox/t\n"),
            marker("1795700000 /tmp\n")
        );
        assert_ne!(
            marker("1795700000 /sandbox/t\n"),
            marker("1795700000 /sandbox/t\n1795700000 /tmp\n")
        );
        assert_eq!(marker("1795700000 /sandbox/t\n").0, "state-file");
    }
    #[test]
    fn a_signal_is_not_an_exit_status() {
        assert_eq!(decision(-15, b""), "signal-15");
        assert_ne!(decision(-15, b""), decision(-9, b""));
        assert_eq!(decision(143, b""), "exit-143");
    }
}
