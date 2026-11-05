use crate::{
    common::*,
    contracts::{fixtures, reference, Fixture},
};
use serde_json::{json, Value};
use std::os::unix::process::ExitStatusExt;
use std::{
    path::{Path, PathBuf},
    process::Command,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    time::{Duration, Instant},
};

pub fn usage(who: i32) -> Result<Value> {
    let mut u = std::mem::MaybeUninit::<libc::rusage>::zeroed();
    ensure(
        unsafe { libc::getrusage(who, u.as_mut_ptr()) } == 0,
        "getrusage failed",
    )?;
    let u = unsafe { u.assume_init() };
    let seconds = |t: libc::timeval| t.tv_sec as f64 + t.tv_usec as f64 / 1e6;
    let rss = u.ru_maxrss as f64
        / if cfg!(target_os = "macos") {
            1024.0
        } else {
            1.0
        };
    Ok(
        json!({"user_cpu_seconds":seconds(u.ru_utime),"system_cpu_seconds":seconds(u.ru_stime),"max_child_peak_rss_kib":rss,"voluntary_context_switches":u.ru_nvcsw,"involuntary_context_switches":u.ru_nivcsw}),
    )
}
pub fn resource_sample(args: &Args) -> Result<()> {
    ensure(
        args.values.len() >= 2,
        "resource-sample destination command [args...]",
    )?;
    let start = Instant::now();
    let status = Command::new(&args.values[1])
        .args(&args.values[2..])
        .status()?;
    let mut row = usage(libc::RUSAGE_CHILDREN)?;
    row["wall_seconds"] = json!(start.elapsed().as_secs_f64());
    write_json(&args.values[0], &row)?;
    std::process::exit(
        status
            .code()
            .unwrap_or_else(|| 128 + status.signal().unwrap_or(1)),
    );
}
pub fn sampled(
    command: &[String],
    payload: &[u8],
    env: &Env,
    cwd: Option<&Path>,
    timeout: f64,
    metrics_path: &Path,
) -> Result<(Value, Vec<u8>)> {
    let mut wrapped = vec![
        std::env::current_exe()?.display().to_string(),
        "resource-sample".into(),
        metrics_path.display().to_string(),
    ];
    wrapped.extend_from_slice(command);
    let (_, output) = checked(&wrapped, payload, env, cwd, timeout)?;
    Ok((read_json(metrics_path)?, output))
}
fn valid_output(f: &Fixture, host: &str, output: &[u8]) -> Result<bool> {
    if f.route == "exec" {
        return Ok(
            output == format!("{}\n", f.expected.as_str().ok_or("expected string")?).as_bytes()
        );
    }
    if f.route == "pre" || f.route == "prompt" {
        return Ok(output == f.expected.as_str().ok_or("expected string")?.as_bytes());
    }
    if f.value == f.expected {
        return Ok(output.is_empty());
    }
    let envelope = parse(output)?;
    if host == "codex" {
        let context = envelope["hookSpecificOutput"]["additionalContext"]
            .as_str()
            .ok_or("missing sanitized context")?;
        Ok(envelope["decision"] == "block"
            && context
                .strip_prefix("Agent Guard sanitized tool output:\n")
                .map(|s| parse(s.as_bytes()).map(|v| v == f.expected))
                .transpose()?
                .unwrap_or(false))
    } else {
        Ok(envelope["hookSpecificOutput"]["updatedToolOutput"] == f.expected)
    }
}
pub fn latency(args: &Args) -> Result<()> {
    let runs = args.positive("--runs", 5)?;
    let timeout: f64 = args.opt("--timeout", "30").parse()?;
    ensure(
        timeout.is_finite() && timeout > 0.0,
        "timeout must be positive",
    )?;
    let host = args.opt("--host", "claude");
    ensure(["claude", "codex"].contains(&host.as_str()), "invalid host")?;
    let scanner = args.opt(
        "--scanner",
        version(&["sh", "-c", "command -v gitleaks"]).unwrap_or_default(),
    );
    let mut env = base_env(&scanner)?;
    let candidate_scanner = absolute(args.opt("--candidate-scanner", &scanner))?;
    let scanner = absolute(&scanner)?;
    let audit_state = args.opt("--audit-state", "off");
    ensure(
        ["off", "cold", "warm"].contains(&audit_state.as_str()),
        "invalid audit state",
    )?;
    env.insert("AGENT_GUARD_HOOK_HOST".into(), host.clone());
    let mut binaries = Vec::new();
    if let Ok(b) = args.get("--baseline") {
        binaries.push(("baseline", absolute(b)?));
    }
    binaries.push(("candidate", absolute(args.opt("--binary", cli()?))?));
    let core = args.get("--native-core").ok().map(absolute).transpose()?;
    let prepare = args.get("--prepare-core").ok().map(absolute).transpose()?;
    ensure(
        prepare.is_none() || args.flag("--fused-output"),
        "prepare requires fused-output",
    )?;
    ensure(
        !args.flag("--packaged-native") || core.is_some(),
        "packaged measurement requires --native-core for artifact identity",
    )?;
    let mut hashes = json!({});
    for (label, path) in &binaries {
        hashes[label] = json!(hash(path)?);
    }
    let mut report = json!({"platform":version(&["uname","-a"])?,"runs":runs,"host":host,"native_core_sha256":core.as_ref().map(hash).transpose()?,"scanner_version":version(&[&scanner,"version"])?,"binary_sha256":hashes,"scanner_sha256":hash(&scanner)?,"config_sha256":hash(&env["AGENT_GUARD_GITLEAKS_CONFIG"])?,"jq_version":version(&["jq","--version"])?,"driver":"agent-guard-devtools (Rust)","logical_cpu_count":unsafe { libc::sysconf(libc::_SC_NPROCESSORS_ONLN) },"readiness_cache":"disabled with audit logging","cases":[],"resources":if args.flag("--resources") {Some("CPU includes waited-for descendants; RSS is the maximum individual child peak, not simultaneous tree memory")} else {None}});
    let directory = tempfile::tempdir()?;
    report["fused_output"] = json!(args.flag("--fused-output"));
    report["prepare_core_sha256"] = json!(prepare.as_ref().map(hash).transpose()?);
    report["audit_state"] = json!(audit_state);
    report["readiness_cache"] = json!(match audit_state.as_str() {
        "warm" => "logging enabled; isolated state primed once before each case/backend",
        "cold" => "logging enabled; fresh isolated state for every invocation",
        _ => "logging disabled; readiness probe on every invocation",
    });
    report["candidate_scanner_sha256"] = json!(hash(&candidate_scanner)?);
    report["candidate_scanner_version"] = json!(version(&[&candidate_scanner, "version"])?);
    report["baseline_native_dispatch"] = json!(if args.flag("--baseline-packaged-native") {
        "packaged-checksum"
    } else {
        "shell"
    });
    report["native_dispatch"] = json!(if args.flag("--packaged-native") {
        "packaged-checksum"
    } else {
        "explicit-override"
    });
    let mut cases = fixtures(args.flag("--include-boundaries"));
    let selected = args.all("--case");
    for name in &selected {
        ensure(
            cases.iter().any(|f| &f.name == name),
            format!("unknown fixture: {name}"),
        )?;
    }
    if !selected.is_empty() {
        cases.retain(|f| selected.contains(&f.name));
    }
    for f in cases {
        let payload = serde_json::to_vec(&if f.route == "hook" {
            json!({"tool_name":"mcp__latency__read","tool_response":f.value})
        } else {
            f.value.clone()
        })?;
        let source = directory.path().join("synthetic-output");
        if f.route == "exec" {
            std::fs::write(&source, f.value.as_str().ok_or("exec string required")?)?;
        }
        let mut samples = json!({});
        let mut resources = json!({});
        let mut processes = json!({});
        let mut process_traces = json!({});
        for (label, _) in &binaries {
            samples[label] = json!([]);
            resources[label] = json!([]);
        }
        for sample in 0..runs + usize::from(args.flag("--trace-processes")) {
            let tracing = sample == runs;
            let order: Vec<_> = if sample % 2 == 0 {
                binaries.iter().collect()
            } else {
                binaries.iter().rev().collect()
            };
            for (label, binary) in order {
                let mut command = vec![binary.clone()];
                if f.route == "exec" {
                    command.extend([
                        "exec".into(),
                        "--".into(),
                        "cat".into(),
                        source.display().to_string(),
                    ]);
                } else {
                    command.push(
                        match f.route {
                            "hook" => "hook-post-tool",
                            "pre" => "hook-pre-tool",
                            _ => "hook-user-prompt",
                        }
                        .into(),
                    );
                }
                env.insert("AGENT_GUARD_EXPERIMENTAL_REDACTOR".into(), "shell".into());
                env.insert("AGENT_GUARD_RUST_CORE_BIN".into(), String::new());
                env.insert(
                    "AGENT_GUARD_EXPERIMENTAL_OUTPUT_PREPARE_BIN".into(),
                    String::new(),
                );
                env.insert(
                    "AGENT_GUARD_EXPERIMENTAL_OUTPUT_PIPELINE".into(),
                    String::new(),
                );
                env.insert(
                    "AGENT_GUARD_GITLEAKS_BIN".into(),
                    if *label == "candidate" {
                        candidate_scanner.clone()
                    } else {
                        scanner.clone()
                    },
                );
                env.insert(
                    "AGENT_GUARD_LOG_MODE".into(),
                    if audit_state == "off" { "off" } else { "on" }.into(),
                );
                let state = directory.path().join(format!(
                    "state-{}-{label}-{}",
                    f.name,
                    if audit_state == "warm" {
                        "warm".into()
                    } else {
                        sample.to_string()
                    }
                ));
                env.insert("XDG_STATE_HOME".into(), state.display().to_string());
                if *label == "baseline" && args.flag("--baseline-packaged-native") {
                    env.insert("AGENT_GUARD_EXPERIMENTAL_REDACTOR".into(), "rust".into());
                }
                if *label == "candidate" {
                    if args.flag("--fused-output") {
                        env.insert(
                            "AGENT_GUARD_EXPERIMENTAL_OUTPUT_PIPELINE".into(),
                            "fused".into(),
                        );
                        env.insert(
                            "AGENT_GUARD_EXPERIMENTAL_OUTPUT_PREPARE_BIN".into(),
                            prepare.clone().unwrap_or_default(),
                        );
                    }
                    if let Some(core) = &core {
                        env.insert("AGENT_GUARD_EXPERIMENTAL_REDACTOR".into(), "rust".into());
                        env.insert(
                            "AGENT_GUARD_RUST_CORE_BIN".into(),
                            if args.flag("--packaged-native") {
                                String::new()
                            } else {
                                core.clone()
                            },
                        );
                    }
                }
                let trace = directory.path().join("processes.trace");
                if audit_state == "warm" && sample == 0 {
                    let prime = br#"{"tool_name":"Read","tool_response":"public status"}"#;
                    let (_, output) = checked(
                        &[binary.clone(), "hook-post-tool".into()],
                        prime,
                        &env,
                        Some(directory.path()),
                        timeout,
                    )?;
                    ensure(
                        output.is_empty(),
                        "warmup output did not match independent clean expectation",
                    )?;
                    ensure(
                        state.join("agent-guard/gitleaks-probe").is_file(),
                        "readiness cache was not primed",
                    )?;
                }
                let input = if f.route == "exec" {
                    b""
                } else {
                    payload.as_slice()
                };
                let (elapsed, output) = if tracing {
                    ensure(
                        cfg!(target_os = "linux"),
                        "process tracing requires Linux and strace",
                    )?;
                    let mut wrapped = vec![
                        "strace".into(),
                        "-f".into(),
                        "-qq".into(),
                        "-e".into(),
                        "trace=process".into(),
                        "-o".into(),
                        trace.display().to_string(),
                    ];
                    wrapped.extend(command);
                    checked(&wrapped, input, &env, Some(directory.path()), timeout)?
                } else if args.flag("--resources") {
                    let (mut row, bytes) = sampled(
                        &command,
                        input,
                        &env,
                        Some(directory.path()),
                        timeout,
                        &directory.path().join("resources.json"),
                    )?;
                    let elapsed = number(&row["wall_seconds"]);
                    row.as_object_mut().unwrap().remove("wall_seconds");
                    resources[label].as_array_mut().unwrap().push(row);
                    (elapsed, bytes)
                } else {
                    checked(&command, input, &env, Some(directory.path()), timeout)?
                };
                ensure(
                    valid_output(&f, &host, &output)?,
                    format!("{label}: incorrect masking output for {}", f.name),
                )?;
                if tracing {
                    let text = std::fs::read_to_string(&trace)?;
                    let creation = |line: &str| {
                        ["clone(", "clone3(", "fork(", "vfork("]
                            .iter()
                            .any(|s| line.contains(s))
                    };
                    processes[label] = json!({"execve_calls":text.matches("execve(").count()+text.matches("execveat(").count(),"process_creation_calls":text.lines().filter(|s|creation(s)&&!s.contains("CLONE_THREAD")).count(),"thread_creation_calls":text.lines().filter(|s|(s.contains("clone(")||s.contains("clone3("))&&s.contains("CLONE_THREAD")).count()});
                    processes[label]["scanner_version_execs"] = json!(text
                        .lines()
                        .filter(|s| s
                            .split_once("execve(\"")
                            .and_then(|(_, rest)| rest.split_once('"'))
                            .is_some_and(|(executable, _)| executable.ends_with("/gitleaks"))
                            && s.contains("\"version\""))
                        .count());
                    process_traces[label] = json!(text);
                } else {
                    samples[label].as_array_mut().unwrap().push(json!(elapsed));
                    eprintln!("{label} {} {elapsed:.3}s", f.name);
                }
            }
        }
        let mut row = json!({"name":f.name,"route":f.route,"input_bytes":if f.route=="exec" {f.value.as_str().unwrap().len()} else {payload.len()},"verified":true,"seconds":{}});
        for (label, _) in &binaries {
            let times: Vec<_> = samples[label]
                .as_array()
                .unwrap()
                .iter()
                .map(number)
                .collect();
            row["seconds"][label] = json!({"median":median(times.clone()),"max":times.iter().copied().fold(0.0,f64::max),"samples":times});
        }
        if binaries.len() == 2 {
            row["speedup"] = json!(
                number(&row["seconds"]["baseline"]["median"])
                    / number(&row["seconds"]["candidate"]["median"])
            );
        }
        if args.flag("--resources") {
            row["resource_usage"] = json!({});
            for (label, _) in &binaries {
                row["resource_usage"][label] = json!({});
                let values = resources[label].as_array().unwrap();
                for key in values[0].as_object().unwrap().keys() {
                    let numbers: Vec<_> = values.iter().map(|v| number(&v[key])).collect();
                    row["resource_usage"][label][key] = json!({"median":median(numbers.clone()),"max":numbers.iter().copied().fold(0.0,f64::max),"samples":numbers});
                }
            }
        }
        if args.flag("--trace-processes") {
            row["process_profile"] = processes;
            row["process_trace"] = process_traces;
        }
        report["cases"].as_array_mut().unwrap().push(row);
    }
    emit(&report)
}

pub fn kernel(args: &Args) -> Result<()> {
    let runs = args.positive("--runs", 15)?;
    let core = absolute(args.get("--core")?)?;
    let directory = tempfile::tempdir()?;
    let path = directory.path().join("reference.jq");
    std::fs::write(&path, reference(Path::new(&cli()?))?)?;
    let mut leaves: Vec<_> = (0..100)
        .map(|i| json!(format!("API_KEY=perf-{i:03}")))
        .collect();
    leaves.extend(vec![json!("status"); 4000]);
    let cases = [
        ("small", json!("API_KEY=secret"), json!(["secret"])),
        (
            "long",
            json!(format!("{}secret", "a".repeat(260000))),
            json!(["secret"]),
        ),
        (
            "many-leaves",
            json!(leaves),
            json!((0..100).map(|i| format!("perf-{i:03}")).collect::<Vec<_>>()),
        ),
        (
            "unicode",
            json!(vec!["é中😀 secret".repeat(100); 100]),
            json!(["secret", "😀"]),
        ),
        (
            "budget-fallback",
            json!(vec!["visible"; 1000]),
            json!(vec!["missing"; 257]),
        ),
    ];
    let commands = [
        (
            "shell-jq",
            vec![
                "jq".into(),
                "-c".into(),
                "-f".into(),
                path.display().to_string(),
            ],
        ),
        ("rust", vec![core.clone(), "redact-v1".into()]),
    ];
    let mut report = json!({"runs":runs,"native_sha256":hash(core)?,"jq_version":version(&["jq","--version"])?,"scope":"one process, stdin JSON, includes startup; no scanner or shell pipeline","cases":[]});
    for (name, response, secrets) in cases {
        let payload =
            serde_json::to_vec(&json!({"protocol":1,"response":response,"secrets":secrets}))?;
        let (_, output) = checked(&commands[0].1, &payload, &Env::new(), None, 30.0)?;
        let expected = parse(&output)?;
        for (_, command) in &commands {
            let (_, bytes) = checked(command, &payload, &Env::new(), None, 30.0)?;
            ensure(parse(&bytes)? == expected, "kernel warmup mismatch")?;
        }
        let mut samples = json!({"shell-jq":[],"rust":[]});
        for repeat in 0..runs {
            for index in if repeat % 2 == 0 { [0, 1] } else { [1, 0] } {
                let (label, command) = &commands[index];
                let (row, output) = sampled(
                    command,
                    &payload,
                    &Env::new(),
                    None,
                    30.0,
                    &directory.path().join("metrics.json"),
                )?;
                ensure(
                    parse(&output)? == expected,
                    format!("kernel mismatch: {name}/{label}"),
                )?;
                samples[label].as_array_mut().unwrap().push(row);
            }
        }
        let medians = json!({"shell-jq":metrics(samples["shell-jq"].as_array().unwrap()),"rust":metrics(samples["rust"].as_array().unwrap())});
        report["cases"]
            .as_array_mut()
            .unwrap()
            .push(json!({"name":name,"verified":true,"samples":samples,"medians":medians}));
    }
    emit(&report)
}

pub fn load(args: &Args) -> Result<()> {
    ensure(
        cfg!(target_os = "linux"),
        "load RSS sampling requires Linux /proc",
    )?;
    let workers = args.positive("--workers", 4)?;
    let requests = args.positive("--requests", 12)?;
    let binary = absolute(args.get("--binary")?)?;
    let core = args.get("--core").ok().map(absolute).transpose()?;
    let prepare = args.get("--prepare-core").ok().map(absolute).transpose()?;
    ensure(
        prepare.is_none() || args.flag("--fused-output"),
        "prepare requires fused-output",
    )?;
    ensure(
        !args.flag("--packaged-native") || core.is_some(),
        "packaged load requires --core for artifact identity",
    )?;
    let mut env = base_env(&args.get("--scanner")?)?;
    env.insert(
        "AGENT_GUARD_EXPERIMENTAL_OUTPUT_PIPELINE".into(),
        if args.flag("--fused-output") {
            "fused"
        } else {
            ""
        }
        .into(),
    );
    env.insert(
        "AGENT_GUARD_EXPERIMENTAL_OUTPUT_PREPARE_BIN".into(),
        prepare.clone().unwrap_or_default(),
    );
    env.insert("AGENT_GUARD_HOOK_HOST".into(), "claude".into());
    env.insert(
        "AGENT_GUARD_EXPERIMENTAL_REDACTOR".into(),
        if core.is_some() { "rust" } else { "shell" }.into(),
    );
    if let Some(core) = &core {
        env.insert(
            "AGENT_GUARD_RUST_CORE_BIN".into(),
            if args.flag("--packaged-native") {
                String::new()
            } else {
                core.clone()
            },
        );
    }
    let fixture = fixtures(false)
        .into_iter()
        .find(|f| f.name == "many-replacement-leaves")
        .unwrap();
    let payload = serde_json::to_vec(
        &json!({"tool_name":"mcp__latency__read","tool_response":fixture.value}),
    )?;
    let stop = Arc::new(AtomicBool::new(false));
    let sampler_stop = stop.clone();
    let sampler = std::thread::spawn(move || {
        let page_kib = unsafe { libc::sysconf(libc::_SC_PAGESIZE) } as f64 / 1024.0;
        let mut samples = Vec::new();
        while !sampler_stop.load(Ordering::Relaxed) {
            let mut total = 0.0;
            if let Ok(entries) = std::fs::read_dir("/proc") {
                for entry in entries.flatten() {
                    if entry
                        .file_name()
                        .to_string_lossy()
                        .chars()
                        .all(|c| c.is_ascii_digit())
                    {
                        if let Ok(text) = std::fs::read_to_string(entry.path().join("statm")) {
                            if let Some(Ok(rss)) =
                                text.split_whitespace().nth(1).map(str::parse::<f64>)
                            {
                                total += rss * page_kib;
                            }
                        }
                    }
                }
            }
            samples.push(total);
            std::thread::sleep(Duration::from_millis(10));
        }
        samples
    });
    let start = Instant::now();
    let next = std::sync::atomic::AtomicUsize::new(0);
    let results = std::thread::scope(|scope| {
        let mut jobs = Vec::new();
        for _ in 0..workers.min(requests) {
            let next = &next;
            let env = &env;
            let payload = &payload;
            let binary = &binary;
            let fixture = &fixture;
            jobs.push(scope.spawn(move || -> Result<Vec<(usize, f64)>> {
                let mut times = Vec::new();
                loop {
                    let index = next.fetch_add(1, Ordering::Relaxed);
                    if index >= requests {
                        break;
                    }
                    let (elapsed, output) = checked(
                        &[binary.clone(), "hook-post-tool".into()],
                        payload,
                        env,
                        None,
                        60.0,
                    )?;
                    ensure(
                        parse(&output)?["hookSpecificOutput"]["updatedToolOutput"]
                            == fixture.expected,
                        "load output mismatch",
                    )?;
                    times.push((index, elapsed));
                }
                Ok(times)
            }));
        }
        jobs.into_iter()
            .map(|j| {
                j.join()
                    .map_err(|_| "load worker panic".into())
                    .and_then(|x| x)
            })
            .collect::<Result<Vec<_>>>()
    });
    let elapsed = start.elapsed().as_secs_f64();
    stop.store(true, Ordering::Relaxed);
    let rss = sampler.join().map_err(|_| "sampler panic")?;
    let mut indexed: Vec<_> = results?.into_iter().flatten().collect();
    indexed.sort_by_key(|(index, _)| *index);
    let samples: Vec<_> = indexed.into_iter().map(|(_, elapsed)| elapsed).collect();
    let u = usage(libc::RUSAGE_CHILDREN)?;
    let driver = usage(libc::RUSAGE_SELF)?;
    let mut cgroup = json!({});
    for key in ["memory.peak", "memory.max", "cpu.max", "memory.events"] {
        cgroup[key] = json!(
            std::fs::read_to_string(PathBuf::from("/sys/fs/cgroup").join(key))
                .ok()
                .map(|s| s.trim().to_owned())
        );
    }
    emit(
        &json!({"fused_output":args.flag("--fused-output"),"prepare_core_sha256":prepare.as_ref().map(hash).transpose()?,"backend":if core.is_some(){"rust"}else{"shell"},"workers":workers,"requests":requests,"verified":true,"elapsed_seconds":elapsed,"requests_per_second":requests as f64/elapsed,"latency_samples":samples,"median_seconds":median(samples.clone()),"max_seconds":samples.iter().copied().fold(0.0,f64::max),"user_cpu_seconds":u["user_cpu_seconds"],"system_cpu_seconds":u["system_cpu_seconds"],"max_child_peak_rss_kib":u["max_child_peak_rss_kib"],"container_cgroup":cgroup,"sampled_process_rss_peak_kib":rss.iter().copied().fold(0.0,f64::max),"rss_sample_count":rss.len(),"rss_sample_interval_seconds":0.01,"driver_cpu_seconds":number(&driver["user_cpu_seconds"])+number(&driver["system_cpu_seconds"]),"cgroup_isolated":std::env::var("AGENT_GUARD_BENCH_CGROUP_ISOLATED").as_deref()==Ok("1"),"memory_scope":"10 ms sampled sum of RSS in the private container PID namespace, including driver/init; shared pages may be counted multiple times; excludes page cache, daemon and build; sampling may miss short peaks; cgroup counters are not container-specific unless cgroup_isolated is true; ru_maxrss is max individual child peak"}),
    )
}
