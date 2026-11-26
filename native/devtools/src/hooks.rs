use crate::common::*;
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

/// (case, hook event, hook subcommand, whether the hook scans its input).
/// Synthetic inputs only.
type Case = (&'static str, &'static str, &'static str, bool);
const CASES: &[Case] = &[
    ("pre-bash", "PreToolUse", "hook-pre-tool", true),
    ("pre-write", "PreToolUse", "hook-pre-tool", true),
    ("pre-read", "PreToolUse", "hook-pre-tool", false),
    ("post-bash", "PostToolUse", "hook-post-tool", true),
    ("user-prompt", "UserPromptSubmit", "hook-user-prompt", true),
];
// helper-off: no helper installed. first-call: a helper is installed and none
// runs. warm-helper: the helper answers. repeat-input: the same input again,
// where the clean-scan cache can hit. fallback: a helper is installed and the
// client hands every scan to the real gitleaks.
const ARMS: &[&str] = &[
    "helper-off",
    "first-call",
    "warm-helper",
    "repeat-input",
    "fallback",
];
const HELPER_FILES: [&str; 2] = ["agent-guard-gitleaks-helper", "agent-guard-scan"];

fn payload(case: &str, event: &str, repo: &str, session: &str, n: &str) -> Value {
    let mut value = json!({"hook_event_name": event, "session_id": session, "cwd": repo});
    match case {
        "pre-bash" => {
            value["tool_name"] = json!("Bash");
            value["tool_input"] = json!({"command": format!("ls -la src/dir-{n}")});
        }
        "pre-write" => {
            let content: Vec<_> = (0..40)
                .map(|i| format!("note line {i} for the build summary {n}"))
                .collect();
            value["tool_name"] = json!("Write");
            value["tool_input"] =
                json!({"file_path": format!("{repo}/notes-{n}.md"), "content": content.join("\n")});
        }
        "pre-read" => {
            value["tool_name"] = json!("Read");
            value["tool_input"] = json!({"file_path": format!("{repo}/src/lib.js")});
        }
        "post-bash" => {
            value["tool_name"] = json!("Bash");
            value["tool_input"] = json!({"command": "make test"});
            value["tool_response"] = json!({"stdout": format!("{}run {n}\n", "ordinary status: build passed\n".repeat(200)), "stderr": "", "interrupted": false});
        }
        _ => value["prompt"] = json!(format!("summarize the build log {n}")),
    }
    value
}

/// A Write whose content every scanner in use must refuse: built here, never
/// stored in the source tree.
fn control(repo: &str, session: &str) -> Value {
    let label = ["PRIVATE", "KEY"].join(" ");
    let body = "MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC7\n".repeat(4);
    json!({"hook_event_name": "PreToolUse", "session_id": session, "cwd": repo, "tool_name": "Write",
        "tool_input": {"file_path": format!("{repo}/deploy.txt"), "content": format!("-----BEGIN {label}-----\n{body}-----END {label}-----\n")}})
}

/// A clean Git repository and the directories every arm keeps apart. The base
/// is short and has no symbolic link: the helper's socket path is bounded and
/// the CLI refuses a state directory behind a link.
pub struct Sandbox {
    _dir: tempfile::TempDir,
    pub base: PathBuf,
    pub repo: String,
}
impl Sandbox {
    pub fn new() -> Result<Self> {
        let dir = tempfile::Builder::new()
            .prefix("agl")
            .tempdir_in(std::fs::canonicalize("/tmp")?)?;
        let base = dir.path().to_path_buf();
        remove_on_interrupt(base.clone())?;
        let repo = base.join("repo");
        std::fs::create_dir_all(repo.join("src"))?;
        for name in ["home", "t"] {
            std::fs::create_dir(base.join(name))?;
        }
        std::fs::write(repo.join("README.md"), "# demo\nplain text line\n")?;
        let lib: Vec<_> = (0..60)
            .map(|i| format!("export function f{i}(x) {{ return x + {i}; }}\n"))
            .collect();
        std::fs::write(repo.join("src/lib.js"), lib.concat())?;
        let repo = repo.display().to_string();
        let git = |args: &[&str]| -> Result<()> {
            let mut command = vec!["git".to_string(), "-C".into(), repo.clone()];
            command.extend(args.iter().map(|s| s.to_string()));
            invoke_isolated(&command, b"", &Self::plain_env(&base), None, 30.0).and_then(
                |(_, out)| {
                    ensure(
                        out.status.success(),
                        "could not build the synthetic repository",
                    )
                },
            )
        };
        git(&["init", "-q"])?;
        git(&["add", "."])?;
        git(&[
            "-c",
            "user.email=bench@example.invalid",
            "-c",
            "user.name=bench",
            "commit",
            "-qm",
            "init",
        ])?;
        Ok(Self {
            _dir: dir,
            base,
            repo,
        })
    }
    /// Nothing of the caller's session reaches a hook: only the search path,
    /// the locale and directories made here.
    fn plain_env(base: &Path) -> Env {
        let mut env = Env::new();
        for name in ["PATH", "LANG", "LC_ALL", "LC_CTYPE"] {
            if let Ok(value) = std::env::var(name) {
                env.insert(name.into(), value);
            }
        }
        for (name, value) in [
            ("HOME", base.join("home").display().to_string()),
            ("TMPDIR", base.join("t").display().to_string()),
            ("GIT_CONFIG_GLOBAL", "/dev/null".into()),
            ("GIT_CONFIG_SYSTEM", "/dev/null".into()),
            ("AGENT_GUARD_RELEASE_CHECK", "off".into()),
        ] {
            env.insert(name.into(), value);
        }
        env
    }
    pub fn env(&self) -> Env {
        Self::plain_env(&self.base)
    }
    /// A tool's version line, asked as the hooks would run the tool.
    pub fn version(&self, command: &[&str]) -> Result<String> {
        let command: Vec<String> = command.iter().map(|s| s.to_string()).collect();
        let (_, out) = invoke_isolated(
            &command,
            b"",
            &self.env(),
            Some(Path::new(&self.repo)),
            15.0,
        )?;
        ensure(
            out.status.success(),
            format!("command failed: {}", command[0]),
        )?;
        Ok(String::from_utf8(out.stdout)?.trim().to_owned())
    }
}

/// The command a host runs for one hook: the CLI itself, or the Claude plugin
/// manifest's command, which goes through the launcher.
pub fn hook_command(
    binary: &str,
    manifest: bool,
    event: &str,
    sub: &str,
    env: &mut Env,
) -> Result<Vec<String>> {
    if !manifest {
        env.insert("AGENT_GUARD_HOOK_HOST".into(), "claude".into());
        return Ok(vec![binary.into(), sub.into()]);
    }
    let root = Path::new(binary)
        .parent()
        .and_then(Path::parent)
        .ok_or("the binary has no plugin root")?;
    // The launcher runs bin/agent-guard of the root, whatever file was named.
    ensure(
        std::fs::canonicalize(root.join("bin/agent-guard"))
            .ok()
            .as_deref()
            == Some(Path::new(binary)),
        "a manifest command runs bin/agent-guard of its plugin root; --binary must be that file",
    )?;
    let hooks = read_json(root.join("hooks/hooks.json"))?;
    let command = hooks["hooks"][event][0]["hooks"][0]["command"]
        .as_str()
        .ok_or("the plugin manifest has no command for this event")?;
    env.insert("CLAUDE_PLUGIN_ROOT".into(), root.display().to_string());
    Ok(vec!["sh".into(), "-c".into(), command.into()])
}

fn helper_dir(state: &Path) -> PathBuf {
    state.join("agent-guard/gitleaks-helper")
}
fn helper_file(state: &Path, suffix: &str) -> bool {
    std::fs::read_dir(helper_dir(state)).is_ok_and(|entries| {
        entries
            .flatten()
            .any(|e| e.file_name().to_string_lossy().ends_with(suffix))
    })
}
fn wait_until(seconds: f64, done: impl Fn() -> bool) -> bool {
    let start = Instant::now();
    while !done() {
        if start.elapsed().as_secs_f64() > seconds {
            return false;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    true
}
/// A helper removes its socket and lock when it ends.
fn helper_gone(state: &Path) -> bool {
    !helper_file(state, ".sock") && !helper_file(state, ".lock")
}

/// The audit event files of a state directory.
fn event_files(state: &Path) -> BTreeSet<String> {
    std::fs::read_dir(state.join("agent-guard"))
        .map(|dir| {
            dir.flatten()
                .map(|e| e.file_name().to_string_lossy().to_string())
                .filter(|name| name.starts_with("event-"))
                .collect()
        })
        .unwrap_or_default()
}
/// The outcome the one event written since before records: pass, blocked,
/// masked, or degraded when the check could not run. Exit status 2 alone does
/// not tell a finding from a scanner that failed.
fn outcome(state: &Path, before: &BTreeSet<String>) -> Value {
    let after = event_files(state);
    let mut new = after.difference(before);
    let (Some(name), None) = (new.next(), new.next()) else {
        return Value::Null;
    };
    std::fs::read_to_string(state.join("agent-guard").join(name))
        .ok()
        .and_then(|text| {
            text.lines()
                .last()
                .and_then(|line| parse(line.as_bytes()).ok())
        })
        .map_or(Value::Null, |event| event["outcome"].clone())
}

/// The readiness-probe cache file: replaced whenever a hook ran `gitleaks version`.
fn probe_entry(state: &Path) -> Option<(u64, i64, i64)> {
    std::fs::metadata(state.join("agent-guard/gitleaks-probe"))
        .ok()
        .map(|meta| (meta.ino(), meta.ctime(), meta.ctime_nsec()))
}

/// The clean-scan cache entries of a state directory, by inode and change time.
fn cache_entries(state: &Path) -> BTreeMap<String, (u64, i64, i64)> {
    let mut entries = BTreeMap::new();
    if let Ok(dir) = std::fs::read_dir(state.join("agent-guard/gitleaks-clean")) {
        for entry in dir.flatten() {
            let name = entry.file_name().to_string_lossy().to_string();
            if name.starts_with("config-") || name.starts_with("tmp.") {
                continue;
            }
            if let Ok(meta) = entry.metadata() {
                entries.insert(name, (meta.ino(), meta.ctime(), meta.ctime_nsec()));
            }
        }
    }
    entries
}

struct Arm {
    name: &'static str,
    bin: PathBuf,
    state: PathBuf,
    unique: bool,
    helper: bool,
}
struct Run<'a> {
    sandbox: &'a Sandbox,
    binary: &'a str,
    manifest: bool,
    timeout: f64,
    trace: PathBuf,
    metrics: PathBuf,
    exe: String,
}
impl Run<'_> {
    /// One hook call. extra overrides the arm's environment.
    fn hook(
        &self,
        arm: &Arm,
        state: &Path,
        case: &Case,
        input: &Value,
        extra: &[(&str, &str)],
    ) -> Result<Value> {
        let mut env = self.sandbox.env();
        env.insert(
            "AGENT_GUARD_GITLEAKS_BIN_DIR".into(),
            arm.bin.display().to_string(),
        );
        env.insert("XDG_STATE_HOME".into(), state.display().to_string());
        if arm.helper {
            env.insert(
                "AGENT_GUARD_GITLEAKS_HELPER_TRACE".into(),
                self.trace.display().to_string(),
            );
            // A first-call helper ends by itself before the next sample; the
            // warm one outlives the gap between two of its samples.
            let idle = if arm.name == "first-call" { "1" } else { "120" };
            env.insert(
                "AGENT_GUARD_GITLEAKS_HELPER_IDLE_SECONDS".into(),
                idle.into(),
            );
        }
        for (name, value) in extra {
            env.insert((*name).into(), (*value).into());
        }
        let mut command = vec![
            self.exe.clone(),
            "resource-sample".into(),
            self.metrics.display().to_string(),
        ];
        command.extend(hook_command(
            self.binary,
            self.manifest,
            case.1,
            case.2,
            &mut env,
        )?);
        let _ = std::fs::remove_file(&self.trace);
        let before = cache_entries(state);
        let probe = probe_entry(state);
        let events = event_files(state);
        let (_, out) = invoke_isolated(
            &command,
            &serde_json::to_vec(input)?,
            &env,
            Some(Path::new(&self.sandbox.repo)),
            self.timeout,
        )?;
        let mut row = read_json(&self.metrics)?;
        let words: Vec<String> = std::fs::read_to_string(&self.trace)
            .unwrap_or_default()
            .lines()
            .map(str::to_owned)
            .collect();
        row["seconds"] = row["wall_seconds"].take();
        row.as_object_mut().unwrap().remove("wall_seconds");
        row["status"] = json!(out.status.code().unwrap_or(-1));
        row["stdout_bytes"] = json!(out.stdout.len());
        row["stderr_bytes"] = json!(out.stderr.len());
        row["client"] = json!(words);
        row["cache_changed"] = json!(before != cache_entries(state));
        row["outcome"] = outcome(state, &events);
        // A scanner the CLI does not cache a probe for (a script) leaves no
        // record either way.
        let probed = probe_entry(state);
        row["probe"] = json!(match (&probed, probed == probe) {
            (None, _) => "unknown",
            (_, true) => "cached",
            _ => "ran",
        });
        Ok(row)
    }
}

/// Which scanner ran. The client's trace says so where a client is selected.
/// Elsewhere the peak resident memory of the hook's children does: gitleaks
/// needs many times what the shell and its tools do. The caller passes no
/// threshold for a hook that also ran the readiness probe, which is gitleaks
/// too.
fn scanner(words: &[String], rss: f64, threshold: Option<f64>) -> &'static str {
    let helper = words.iter().filter(|w| *w == "helper").count();
    match (words.len(), helper, threshold) {
        (0, _, None) => "unknown",
        (0, _, Some(limit)) if rss < limit => "none",
        (0, _, Some(_)) => "gitleaks",
        (n, h, _) if n == h => "helper",
        (_, 0, _) => "gitleaks",
        _ => "mixed",
    }
}

/// Whether a sample shows the scanner its arm names. A hook that scans must
/// show one: the client's words where a client is selected, gitleaks by
/// memory elsewhere. Only a hook without a scan and a verified cache hit may
/// show none. unverified accepts unknown too: a test double's memory tells
/// nothing, and the report then says so.
fn evidence(
    arm: &str,
    helper: bool,
    scans: bool,
    hit: bool,
    words: &[String],
    ran: &str,
    unverified: bool,
) -> bool {
    let all = |word: &str| !words.is_empty() && words.iter().all(|w| w == word);
    let ran_is = |scanner: &str| ran == scanner || unverified && ran == "unknown";
    if !scans || hit {
        return words.is_empty() && ran_is("none");
    }
    match (arm, helper) {
        ("first-call", _) => {
            words.len() > 1 && words[0] == "spawned" && words[1..].iter().all(|w| w == "real:cold")
        }
        ("fallback", _) => all("real:socket-path"),
        (_, true) => all("helper"),
        _ => words.is_empty() && ran_is("gitleaks"),
    }
}

fn copy_executable(from: &Path, to: &Path) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::copy(from, to)?;
    std::fs::set_permissions(to, std::fs::Permissions::from_mode(0o755))?;
    Ok(())
}

pub fn latency(args: &Args) -> Result<()> {
    let runs = args.positive("--runs", 30)?;
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
    let out_path = PathBuf::from(args.get("--out")?);
    let binary = absolute(match args.get("--binary") {
        Ok(binary) => binary,
        Err(_) => cli()?,
    })?;
    let scanner_path = absolute(args.opt(
        "--scanner",
        version(&["sh", "-c", "command -v gitleaks"]).unwrap_or_default(),
    ))?;
    let helper = args.get("--helper").ok().map(absolute).transpose()?;
    let cases: Vec<_> = {
        let selected = args.all("--case");
        for name in &selected {
            ensure(
                CASES.iter().any(|c| c.0 == name),
                format!("unknown case: {name}"),
            )?;
        }
        CASES
            .iter()
            .filter(|c| selected.is_empty() || selected.iter().any(|s| s == c.0))
            .collect()
    };
    let arm_names: Vec<&str> = {
        let selected = args.all("--arm");
        for name in &selected {
            ensure(
                ARMS.contains(&name.as_str()),
                format!("unknown arm: {name}"),
            )?;
            ensure(
                helper.is_some() || ["helper-off", "repeat-input"].contains(&name.as_str()),
                format!("arm {name} requires --helper"),
            )?;
        }
        ARMS.iter()
            .copied()
            .filter(|a| {
                if selected.is_empty() {
                    helper.is_some() || ["helper-off", "repeat-input"].contains(a)
                } else {
                    selected.iter().any(|s| s == a)
                }
            })
            .collect()
    };

    // Made before anything is measured: a run must not end without its samples.
    if let Some(parent) = out_path.parent().filter(|p| !p.as_os_str().is_empty()) {
        std::fs::create_dir_all(parent)?;
    }
    let sandbox = Sandbox::new()?;
    let base = &sandbox.base;
    eprintln!("sandbox {}", base.display());
    // Two private gitleaks directories: one with the scanner alone, one laid
    // out as setup --install-gitleaks-helper leaves it.
    let off_bin = base.join("off");
    let helper_bin = base.join("on");
    std::fs::create_dir(&off_bin)?;
    copy_executable(Path::new(&scanner_path), &off_bin.join("gitleaks"))?;
    let mut helper_sums = Value::Null;
    if let Some(helper) = &helper {
        let installed = helper_bin.join("gitleaks-helper");
        std::fs::create_dir_all(&installed)?;
        copy_executable(Path::new(&scanner_path), &helper_bin.join("gitleaks"))?;
        let mut sums = String::new();
        helper_sums = json!({});
        for name in HELPER_FILES {
            copy_executable(&Path::new(helper).join(name), &installed.join(name))?;
            let sum = hash(installed.join(name))?;
            sums.push_str(&format!("{sum}  {name}\n"));
            helper_sums[name] = json!(sum);
        }
        std::fs::write(installed.join("SHA256SUMS"), sums)?;
    }
    let with_helper = helper.is_some();
    let warm_state = base.join("w");
    let arms: Vec<Arm> = arm_names
        .iter()
        .map(|&name| {
            let (bin, state, unique, helper) = match name {
                "helper-off" => (&off_bin, base.join("o"), true, false),
                "first-call" => (&helper_bin, base.join("f"), true, true),
                "warm-helper" => (&helper_bin, warm_state.clone(), true, true),
                "repeat-input" if with_helper => (&helper_bin, warm_state.clone(), false, true),
                "repeat-input" => (&off_bin, base.join("o"), false, false),
                // Long enough that the helper's socket path is over its limit.
                _ => (
                    &helper_bin,
                    base.join(format!("fallback-{}", "x".repeat(72))),
                    true,
                    true,
                ),
            };
            Arm {
                name,
                bin: bin.clone(),
                state,
                unique,
                helper,
            }
        })
        .collect();
    let run = Run {
        sandbox: &sandbox,
        binary: &binary,
        manifest: entry == "manifest",
        timeout,
        trace: base.join("trace"),
        metrics: base.join("metrics.json"),
        exe: std::env::current_exe()?.display().to_string(),
    };
    // A first-call sample needs its own state: the client starts at most one
    // helper a minute for one state directory.
    let state_of = |arm: &Arm, case: &str| {
        if arm.name == "first-call" {
            arm.state.join(case)
        } else {
            arm.state.clone()
        }
    };
    let session = |arm: &Arm| format!("latency-{}", arm.name);
    let input =
        |arm: &Arm, case: &Case, n: &str| payload(case.0, case.1, &sandbox.repo, &session(arm), n);
    let off = [("AGENT_GUARD_GITLEAKS_HELPER", "off")];

    // Peak memory that separates a hook that ran gitleaks from one that did
    // not, measured here on this machine: a scan by the scanner itself against
    // a hook that scans nothing.
    let idle_state = base.join("i");
    let idle = || {
        run.hook(
            &Arm {
                name: "calibration",
                bin: off_bin.clone(),
                state: idle_state.clone(),
                unique: true,
                helper: false,
            },
            &idle_state,
            &CASES[2],
            &payload(
                "pre-read",
                "PreToolUse",
                &sandbox.repo,
                "latency-calibration",
                "0",
            ),
            &[],
        )
    };
    // The first call runs the readiness probe; the second finds it cached.
    idle()?;
    let idle = idle()?;
    ensure(
        idle["status"] == 0 && idle["probe"] != "ran",
        "the calibration hook failed or ran the readiness probe twice",
    )?;
    let config = Path::new(&binary)
        .parent()
        .and_then(Path::parent)
        .ok_or("the binary has no plugin root")?
        .join("config/gitleaks.toml");
    // The copy the hooks run, in their environment and directory.
    let staged_scanner = off_bin.join("gitleaks").display().to_string();
    let mut scan = vec![
        run.exe.clone(),
        "resource-sample".into(),
        run.metrics.display().to_string(),
        staged_scanner.clone(),
    ];
    scan.extend(
        [
            "stdin",
            "--redact",
            "--no-banner",
            "--no-color",
            "--log-level",
            "error",
            "--config",
        ]
        .map(String::from),
    );
    scan.push(config.display().to_string());
    let (_, out) = invoke_isolated(
        &scan,
        b"ls -la src\n",
        &sandbox.env(),
        Some(Path::new(&sandbox.repo)),
        timeout,
    )?;
    ensure(
        out.status.success(),
        "the scanner could not scan a clean line",
    )?;
    let scan_rss = number(&read_json(&run.metrics)?["max_child_peak_rss_kib"]);
    let idle_rss = number(&idle["max_child_peak_rss_kib"]);
    let threshold = (scan_rss >= 4.0 * idle_rss).then(|| (scan_rss * idle_rss).sqrt());
    let unverified = args.flag("--unverified");
    ensure(
        threshold.is_some() || unverified,
        "this scanner's peak memory cannot be told from a hook without a scan, so no sample could show that it scanned; pass --unverified to time a test double",
    )?;
    // One hook, and a helper it started is up before the next call, so that
    // start-up stays out of the next sample. A first-call helper is watched
    // while the hook runs: it can be gone again before a slow hook ends.
    let hook = |arm: &Arm,
                state: &Path,
                case: &Case,
                input: &Value,
                extra: &[(&str, &str)]|
     -> Result<Value> {
        let seen = AtomicBool::new(false);
        let done = AtomicBool::new(false);
        let row = std::thread::scope(|scope| {
            if arm.name == "first-call" {
                scope.spawn(|| {
                    while !done.load(Ordering::Relaxed) {
                        if helper_file(state, ".sock") {
                            seen.store(true, Ordering::Relaxed);
                        }
                        std::thread::sleep(Duration::from_millis(10));
                    }
                });
            }
            let row = run.hook(arm, state, case, input, extra);
            done.store(true, Ordering::Relaxed);
            row
        })?;
        if row["client"]
            .as_array()
            .unwrap()
            .contains(&json!("spawned"))
            && !seen.load(Ordering::Relaxed)
        {
            ensure(
                wait_until(30.0, || helper_file(state, ".sock")),
                format!("{}: the helper did not start", arm.name),
            )?;
        }
        Ok(row)
    };

    // Warm every cell: the readiness probe, the deny-pattern cache, and the
    // helper where the arm has one.
    let mut problems: Vec<String> = Vec::new();
    // Cells whose repeated input left a clean-scan cache entry.
    let mut stored: Vec<(&str, &str)> = Vec::new();
    for arm in &arms {
        for case in &cases {
            let state = state_of(arm, case.0);
            for k in 0..2 {
                let n = if arm.unique {
                    format!("prime-{}-{k}", arm.name)
                } else {
                    "fixed".into()
                };
                let extra: &[(&str, &str)] = if arm.name == "first-call" { &off } else { &[] };
                let row = hook(arm, &state, case, &input(arm, case, &n), extra)?;
                if !arm.unique && row["cache_changed"] == true {
                    stored.push((arm.name, case.0));
                }
            }
        }
    }
    let mut controls = Vec::new();
    let mut seen = Vec::new();
    for arm in &arms {
        let state = state_of(arm, "control");
        if seen.contains(&state) {
            continue;
        }
        seen.push(state.clone());
        let row = hook(
            arm,
            &state,
            &CASES[1],
            &control(&sandbox.repo, &session(arm)),
            &[],
        )?;
        if row["status"] != 2 || row["outcome"] != "blocked" {
            problems.push(format!(
                "control: {} did not report the private key block as a finding",
                arm.name
            ));
        }
        if arm.helper && row["client"].as_array().unwrap().is_empty() {
            problems.push(format!(
                "control: {} scanned without the scan client; the helper files may not be the ones this CLI pins",
                arm.name
            ));
        }
        controls.push(json!({"arm": arm.name, "status": row["status"], "outcome": row["outcome"], "client": row["client"]}));
    }

    let load = || {
        let mut values = [0f64; 3];
        unsafe { libc::getloadavg(values.as_mut_ptr(), 3) };
        json!(values)
    };
    let load_start = load();
    let cells: Vec<(&Arm, &Case)> = arms
        .iter()
        .flat_map(|arm| cases.iter().map(move |case| (arm, *case)))
        .collect();
    let mut samples = Vec::new();
    for sample in 0..runs {
        let order: Vec<_> = if sample % 2 == 0 {
            cells.iter().collect()
        } else {
            cells.iter().rev().collect()
        };
        for (arm, case) in order {
            let state = state_of(arm, case.0);
            let n = if arm.unique {
                format!("{}-{sample}", arm.name)
            } else {
                "fixed".into()
            };
            if arm.name == "first-call" {
                ensure(
                    wait_until(30.0, || helper_gone(&state)),
                    "a first-call helper did not end",
                )?;
                if let Ok(dir) = std::fs::read_dir(helper_dir(&state)) {
                    for entry in dir.flatten() {
                        if entry.file_name().to_string_lossy().ends_with(".spawn") {
                            std::fs::remove_file(entry.path())?;
                        }
                    }
                }
            }
            let mut row = hook(arm, &state, case, &input(arm, case, &n), &[])?;
            let words: Vec<String> = row["client"]
                .as_array()
                .unwrap()
                .iter()
                .map(|w| w.as_str().unwrap().to_owned())
                .collect();
            let rss = number(&row["max_child_peak_rss_kib"]);
            let changed = row["cache_changed"] == true;
            let limit = threshold.filter(|_| row["probe"] == "cached");
            let mut ran = scanner(&words, rss, limit);
            if ran == "unknown" && changed {
                // Only a clean scan stores an entry.
                ran = "gitleaks";
            }
            row.as_object_mut().unwrap().remove("cache_changed");
            // A hit is a repeated input that started no scanner and left the
            // cache as it was, after an earlier call with that input stored it.
            if changed && !arm.unique {
                stored.push((arm.name, case.0));
            }
            row["cache"] = json!(if changed {
                "stored"
            } else if ran == "none" && stored.contains(&(arm.name, case.0)) {
                "hit"
            } else {
                "none"
            });
            row["scanner"] = json!(ran);
            let label = format!("{}/{} sample {sample}", arm.name, case.0);
            if row["status"] != 0 || row["outcome"] != "pass" {
                problems.push(format!(
                    "{label}: exit status {}, audit outcome {}",
                    row["status"], row["outcome"]
                ));
            }
            let hit = row["cache"] == "hit";
            // A sample that also ran the readiness probe is another path:
            // kept, and left out of its cell's summary.
            let aggregated = row["probe"] != "ran";
            row["aggregated"] = json!(aggregated);
            let expected =
                !aggregated || evidence(arm.name, arm.helper, case.3, hit, &words, ran, unverified);
            if !expected {
                problems.push(format!(
                    "{label}: scanner {ran} and scan client words {words:?} are not what this arm measures"
                ));
            }
            if arm.helper && words.is_empty() && ran == "gitleaks" {
                problems.push(format!("{label}: gitleaks ran without the scan client"));
            }
            if let (Some(limit), false) = (limit, words.is_empty()) {
                if (ran == "helper") != (rss < limit) {
                    problems.push(format!(
                        "{label}: peak memory {rss} KiB disagrees with the scan client's {words:?}"
                    ));
                }
            }
            row["case"] = json!(case.0);
            row["event"] = json!(case.1);
            row["arm"] = json!(arm.name);
            row["sample"] = json!(sample);
            eprintln!(
                "{} {} {:.3}s {ran}",
                arm.name,
                case.0,
                number(&row["seconds"])
            );
            samples.push(row);
        }
    }
    let load_end = load();
    // Helpers end by themselves; the warm one as soon as its socket is gone.
    if let Ok(dir) = std::fs::read_dir(helper_dir(&warm_state)) {
        for entry in dir.flatten() {
            if entry.file_name().to_string_lossy().ends_with(".sock") {
                std::fs::remove_file(entry.path())?;
            }
        }
    }
    for arm in &arms {
        for name in cases.iter().map(|case| case.0).chain(["control"]) {
            let state = state_of(arm, name);
            if arm.helper && !wait_until(40.0, || !helper_file(&state, ".lock")) {
                problems.push(format!("{}: a helper is still running", arm.name));
            }
        }
    }

    let mut summary = Vec::new();
    for (arm, case) in &cells {
        let all: Vec<_> = samples
            .iter()
            .filter(|s| s["arm"] == arm.name && s["case"] == case.0)
            .collect();
        let rows: Vec<_> = all.iter().filter(|s| s["aggregated"] == true).collect();
        if rows.is_empty() {
            problems.push(format!(
                "{}/{}: every sample ran the readiness probe",
                arm.name, case.0
            ));
            continue;
        }
        let mut times: Vec<f64> = rows
            .iter()
            .map(|s| number(&s["seconds"]) * 1000.0)
            .collect();
        times.sort_by(f64::total_cmp);
        let count = |key: &str| {
            let mut counts = BTreeMap::new();
            for row in &rows {
                *counts
                    .entry(row[key].as_str().unwrap().to_owned())
                    .or_insert(0) += 1;
            }
            json!(counts)
        };
        let tenth = |v: f64| (v * 10.0).round() / 10.0;
        let p95 = times[((0.95 * times.len() as f64).ceil() as usize).max(1) - 1];
        summary.push(
            json!({"case": case.0, "event": case.1, "arm": arm.name, "n": times.len(),
            "median_ms": tenth(median(times.clone())), "p95_ms": tenth(p95),
            "min_ms": tenth(times[0]), "max_ms": tenth(times[times.len() - 1]),
            "scanner": count("scanner"), "cache": count("cache"), "probe_runs_left_out": all.len() - rows.len()}),
        );
    }
    let mut report = json!({
        "tool": "hook-latency",
        "platform": version(&["uname", "-a"])?,
        "logical_cpu_count": unsafe { libc::sysconf(libc::_SC_NPROCESSORS_ONLN) },
        "load_average": {"start": load_start, "end": load_end},
        "entry": entry,
        "binary_sha256": hash(&binary)?,
        "scanner_version": sandbox.version(&[&staged_scanner, "version"])?,
        "scanner_sha256": hash(&scanner_path)?,
        "helper_sha256": helper_sums,
        "jq_version": sandbox.version(&["jq", "--version"])?,
        "runs": runs,
        "arms": arm_names,
        "verified": !unverified,
        "scanner_evidence": match threshold {
            Some(limit) => json!({"source": "scan client trace; peak child memory where no client is selected", "threshold_kib": limit, "scan_kib": scan_rss, "no_scan_kib": idle_rss}),
            None => json!({"source": "scan client trace only: this scanner's peak memory is too close to a hook without a scan", "scan_kib": scan_rss, "no_scan_kib": idle_rss}),
        },
        "controls": controls,
        "problems": problems,
        "cells": summary,
    });
    emit(&report)?;
    report["samples"] = json!(samples);
    write_json(&out_path, &report)?;
    ensure(
        report["problems"].as_array().unwrap().is_empty(),
        "a sample did not measure what its arm names; see problems",
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    fn words(list: &[&str]) -> Vec<String> {
        list.iter().map(|w| w.to_string()).collect()
    }
    #[test]
    fn a_sample_needs_the_scanner_its_arm_names() {
        // (arm, helper, scans, cache hit, client words, scanner, accepted)
        type Row = (
            &'static str,
            bool,
            bool,
            bool,
            &'static [&'static str],
            &'static str,
            bool,
        );
        let rows: &[Row] = &[
            (
                "warm-helper",
                true,
                true,
                false,
                &["helper"],
                "helper",
                true,
            ),
            ("warm-helper", true, true, false, &[], "none", false),
            ("warm-helper", true, true, false, &[], "unknown", false),
            (
                "warm-helper",
                true,
                true,
                false,
                &["real:engine"],
                "gitleaks",
                false,
            ),
            ("warm-helper", true, false, false, &[], "none", true),
            (
                "warm-helper",
                true,
                false,
                false,
                &["helper"],
                "helper",
                false,
            ),
            (
                "first-call",
                true,
                true,
                false,
                &["spawned", "real:cold"],
                "gitleaks",
                true,
            ),
            (
                "first-call",
                true,
                true,
                false,
                &["real:cold"],
                "gitleaks",
                false,
            ),
            ("first-call", true, true, false, &[], "gitleaks", false),
            (
                "fallback",
                true,
                true,
                false,
                &["real:socket-path"],
                "gitleaks",
                true,
            ),
            ("fallback", true, true, false, &["helper"], "helper", false),
            ("fallback", true, true, false, &[], "none", false),
            ("repeat-input", true, true, true, &[], "none", true),
            (
                "repeat-input",
                true,
                true,
                true,
                &["helper"],
                "helper",
                false,
            ),
            (
                "repeat-input",
                true,
                true,
                false,
                &["helper"],
                "helper",
                true,
            ),
            ("repeat-input", false, true, true, &[], "none", true),
            ("helper-off", false, true, false, &[], "gitleaks", true),
            ("helper-off", false, true, false, &[], "unknown", false),
            ("helper-off", false, true, false, &[], "none", false),
            (
                "helper-off",
                false,
                true,
                false,
                &["helper"],
                "helper",
                false,
            ),
            ("helper-off", false, false, false, &[], "none", true),
            ("helper-off", false, false, false, &[], "gitleaks", false),
        ];
        for (arm, helper, scans, hit, list, ran, accepted) in rows {
            assert_eq!(
                evidence(arm, *helper, *scans, *hit, &words(list), ran, false),
                *accepted,
                "{arm} helper={helper} scans={scans} hit={hit} {list:?} {ran}"
            );
        }
        // A test double: unknown stands for the scanner, a wrong client word does not.
        assert!(evidence(
            "helper-off",
            false,
            true,
            false,
            &[],
            "unknown",
            true
        ));
        assert!(evidence(
            "helper-off",
            false,
            false,
            false,
            &[],
            "unknown",
            true
        ));
        assert!(!evidence(
            "warm-helper",
            true,
            true,
            false,
            &[],
            "unknown",
            true
        ));
    }
}
