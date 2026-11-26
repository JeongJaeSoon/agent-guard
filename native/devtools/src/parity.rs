use crate::common::*;
use crate::hooks::{hook_command, key_block, Sandbox};
use serde_json::{json, Map, Value};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::path::Path;

// What two runs of one build may differ in, and what is therefore left out of
// the comparison. Everything else is compared byte for byte.
const UNSTABLE: &[&str] = &[
    "audit events: run_id, time and duration_seconds",
    "names of state and temporary files: every run of digits and every run of 8 or more hexadecimal characters (times, process and file identities, hashes), and the random suffix of an audit event file",
    "content of the CLI's cache files in the state directory (times and file identities)",
    "each side's own plugin root in output, read as one placeholder",
];

struct Side {
    cli: String,
    root: String,
    shell: Option<String>,
}
struct Outcome {
    status: i32,
    stdout: Vec<u8>,
    stderr: Vec<u8>,
    state: Vec<(String, Vec<u8>)>,
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

/// Every file under the state and temporary directories.
fn tree(base: &Path) -> Result<BTreeMap<String, Vec<u8>>> {
    fn walk(dir: &Path, prefix: &str, out: &mut BTreeMap<String, Vec<u8>>) -> Result<()> {
        let Ok(entries) = std::fs::read_dir(dir) else {
            return Ok(());
        };
        for entry in entries {
            let entry = entry?;
            let name = format!("{prefix}/{}", entry.file_name().to_string_lossy());
            let kind = entry.file_type()?;
            if kind.is_dir() {
                walk(&entry.path(), &name, out)?;
            } else if kind.is_file() {
                // A file a finished hook removed between the listing and the
                // read is no longer state.
                if let Ok(bytes) = std::fs::read(entry.path()) {
                    out.insert(name, bytes);
                }
            } else {
                out.insert(name, b"not a regular file".to_vec());
            }
        }
        Ok(())
    }
    let mut out = BTreeMap::new();
    for name in ["s", "t"] {
        walk(&base.join(name), name, &mut out)?;
    }
    Ok(out)
}

/// What one step changed: audit events without their unstable fields, cache
/// files by name only, and everything else (notices, markers) with content.
fn transition(
    before: &BTreeMap<String, Vec<u8>>,
    after: &BTreeMap<String, Vec<u8>>,
) -> Vec<(String, Vec<u8>)> {
    let mut out = Vec::new();
    for (path, bytes) in after {
        if before.get(path) == Some(bytes) {
            continue;
        }
        let (dir, name) = path.rsplit_once('/').unwrap_or(("", path));
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
            out.push((format!("{dir}/event"), events.join("\n").into_bytes()));
        } else if path.starts_with("s/") {
            out.push((stable_name(path), Vec::new()));
        } else {
            out.push((stable_name(path), bytes.clone()));
        }
    }
    for path in before.keys().filter(|path| !after.contains_key(*path)) {
        out.push((format!("removed {}", stable_name(path)), Vec::new()));
    }
    out.sort();
    out
}

/// A fixed word for what the host is told: never a value from the output.
fn decision(status: i32, stdout: &[u8]) -> String {
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

pub fn differential(args: &Args) -> Result<()> {
    let out_path = std::path::PathBuf::from(args.get("--out")?);
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
    let corpus_path = args.opt(
        "--corpus",
        root()?
            .join("tests/fixtures/cli-differential.json")
            .display()
            .to_string(),
    );
    let corpus = read_json(&corpus_path)?;
    let selected = args.all("--case");

    let sandbox = Sandbox::new()?;
    // Outside the directories a reset rebuilds, so both sides run one file.
    let bin = sandbox.base.join("bin");
    std::fs::create_dir(&bin)?;
    std::fs::copy(&scanner, bin.join("gitleaks"))?;
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
                            key.starts_with("AGENT_GUARD_")
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
            let before = tree(&sandbox.base)?;
            let (_, out) = invoke_isolated(&command, &input, &env, Some(repo), timeout)?;
            let state = transition(&before, &tree(&sandbox.base)?);
            let own = |bytes: &[u8]| replace(bytes, side.root.as_bytes(), b"<cli-root>");
            outcomes.push(Outcome {
                status: out.status.code().unwrap_or(-1),
                stdout: own(&out.stdout),
                stderr: own(&out.stderr),
                state,
            });
        }
        Ok(outcomes)
    };

    let mut rows = Vec::new();
    let mut different = Vec::new();
    for case in &cases {
        let name = case["name"].as_str().unwrap();
        let baseline = run_case(case, &sides[0])?;
        let candidate = run_case(case, &sides[1])?;
        let mut steps = Vec::new();
        let mut equal = true;
        for (index, (a, b)) in baseline.iter().zip(&candidate).enumerate() {
            let decisions = [decision(a.status, &a.stdout), decision(b.status, &b.stdout)];
            let names = |o: &Outcome| o.state.iter().map(|(n, _)| n.clone()).collect::<Vec<_>>();
            let same = a.status == b.status
                && a.stdout == b.stdout
                && a.stderr == b.stderr
                && a.state == b.state;
            equal &= same;
            steps.push(json!({
                "command": case["steps"][index]["args"][0],
                "equal": same,
                "status": [a.status, b.status],
                "decision": decisions,
                "stdout": compared(&a.stdout, &b.stdout),
                "stderr": compared(&a.stderr, &b.stderr),
                "state": {"equal": a.state == b.state, "baseline": names(a), "candidate": names(b)},
            }));
        }
        eprintln!("{} {name}", if equal { "same" } else { "DIFFERENT" });
        if !equal {
            different.push(name);
        }
        rows.push(json!({"name": name, "host": case["host"].as_str().unwrap_or("claude"), "equal": equal, "steps": steps}));
    }
    let describe = |side: &Side| -> Result<Value> {
        Ok(json!({"sha256": hash(&side.cli)?, "shell": side.shell}))
    };
    let mut report = json!({
        "tool": "cli-differential",
        "platform": version(&["uname", "-a"])?,
        "entry": entry,
        "baseline": describe(&sides[0])?,
        "candidate": describe(&sides[1])?,
        "scanner_version": version(&[&scanner, "version"])?,
        "scanner_sha256": hash(&scanner)?,
        "corpus_sha256": hash(&corpus_path)?,
        "compared": "exit status, decision, standard output and standard error byte for byte, audit events and the files each step left",
        "not_compared": UNSTABLE,
        "case_count": rows.len(),
        "differences": different.len(),
        "different_cases": different,
    });
    emit(&report)?;
    report["cases"] = json!(rows);
    write_json(&out_path, &report)?;
    ensure(
        report["differences"] == 0,
        "the two builds differ; see different_cases",
    )
}
