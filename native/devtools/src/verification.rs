use crate::common::*;
use serde_json::json;
use std::{
    collections::BTreeSet,
    path::Path,
    time::{Duration, Instant},
};

pub fn watchdog(args: &Args) -> Result<()> {
    ensure(cfg!(target_os = "linux"), "watchdog-orphans requires Linux")?;
    let runs = args.positive("--runs", 10)?;
    #[cfg(target_os = "linux")]
    ensure(
        unsafe { libc::prctl(libc::PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) } == 0,
        "subreaper unavailable",
    )?;
    let env = base_env(&args.get("--scanner")?)?;
    let binaries = [
        ("baseline", absolute(args.get("--baseline")?)?),
        ("candidate", absolute(args.opt("--binary", cli()?))?),
    ];
    let mut report = json!({"method":"Linux subreaper; reap adopted descendants after each completed CLI check","runs":runs,"binary_sha256":{},"adopted_children":{}});
    for (name, binary) in binaries {
        report["binary_sha256"][name] = json!(hash(&binary)?);
        let mut samples = Vec::new();
        for _ in 0..runs {
            checked(&[binary.clone(), "check".into()], b"", &env, None, 10.0)?;
            let mut adopted = 0;
            let start = Instant::now();
            loop {
                let pid = unsafe { libc::waitpid(-1, std::ptr::null_mut(), libc::WNOHANG) };
                if pid < 0 {
                    ensure(
                        std::io::Error::last_os_error().raw_os_error() == Some(libc::ECHILD),
                        "waitpid failed",
                    )?;
                    break;
                }
                if pid > 0 {
                    adopted += 1;
                    continue;
                }
                ensure(
                    start.elapsed().as_secs_f64() < 3.0,
                    "adopted descendant did not terminate",
                )?;
                std::thread::sleep(Duration::from_millis(10));
            }
            samples.push(adopted);
        }
        report["adopted_children"][name] = json!(samples);
    }
    emit(&report)
}
pub fn verify(args: &Args) -> Result<()> {
    let out = std::path::PathBuf::from(args.get("--out")?);
    std::fs::create_dir_all(&out)?;
    let out = std::fs::canonicalize(out)?;
    let core = absolute(args.get("--native-core")?)?;
    let before = hash(cli()?)?;
    let shards: Vec<usize> = if let Some(index) = args.values.iter().rposition(|s| s == "--shards")
    {
        args.values[index + 1..]
            .iter()
            .take_while(|s| !s.starts_with("--"))
            .map(|s| s.parse())
            .collect::<std::result::Result<_, _>>()?
    } else {
        (1..=5).collect()
    };
    ensure(
        !shards.is_empty() && shards.iter().all(|s| (1..=5).contains(s)),
        "shards must be 1..5",
    )?;
    let mut jobs: Vec<_> = shards.iter().map(|s| (*s, false)).collect();
    jobs.push((4, true));
    let mut rows = Vec::new();
    for pair in jobs.chunks(2) {
        let result = std::thread::scope(|scope| {
            let handles:Vec<_>=pair.iter().map(|&(shard,native)| {let core=&core;let out=&out;scope.spawn(move || -> Result<_> {
                let label=format!("{}-{shard}",if native{"native"}else{"shell"});
                let env=Env::from([("AGENT_GUARD_TEST_SHARD".into(),shard.to_string()),("AGENT_GUARD_EXPERIMENTAL_REDACTOR".into(),"shell".into()),("AGENT_GUARD_RUST_CORE_BIN".into(),core.clone())]);
                let log_path=out.join(format!("{label}.log"));
                let command=vec!["sh".into(),"-c".into(),"log=$1; shift; exec \"$@\" >\"$log\" 2>&1".into(),"verify".into(),log_path.display().to_string(),"sh".into(),if native{"tests/native-suite.sh"}else{"tests/run.sh"}.into()];
                let (elapsed,result)=invoke(&command,b"",&env,Some(&root()?),3600.0)?;
                let log=std::fs::read(log_path)?;
                let text=String::from_utf8_lossy(&log);
                let summary:Vec<_>=text.lines().filter(|s|["passed:","failed:","not ok -"].iter().any(|prefix|s.starts_with(prefix))).collect();
                Ok(json!({"label":label,"status":result.status.code().unwrap_or(1),"seconds":elapsed,"summary":summary,"real_scanner_skipped":text.contains("skipped real-gitleaks")}))
            })}).collect();
            handles
                .into_iter()
                .map(|h| {
                    h.join()
                        .map_err(|_| "verification worker panic".into())
                        .and_then(|r| r)
                })
                .collect::<Result<Vec<_>>>()
        })?;
        rows.extend(result);
    }
    let after = hash(cli()?)?;
    let report = json!({"before_sha256":before,"after_sha256":after,"stable":before==after,"requested_shell_shards":shards,"results":rows});
    write_json(out.join("verification.json"), &report)?;
    emit(&report)?;
    ensure(
        before == after && rows.iter().all(|r| r["status"] == 0),
        "regression verification failed",
    )
}
pub fn selected_bash(_args: &Args) -> Result<()> {
    let root = root()?;
    let source = Path::new(&root).join("plugins/agent-guard/bin/agent-guard");
    let manifest = read_json(root.join("tests/selected-bash-locations.json"))?;
    let manifest = manifest.as_object().ok_or("invalid manifest")?;
    let source_text = std::fs::read_to_string(&source)?;
    let source_lines: Vec<_> = source_text.lines().collect();
    let dir = tempfile::tempdir()?;
    let functions = dir.path().join("functions");
    std::fs::create_dir(&functions)?;
    let mut command = vec![
        "sh".into(),
        root.join("tests/helpers/extract-functions.sh")
            .display()
            .to_string(),
        source.display().to_string(),
        functions.display().to_string(),
    ];
    command.extend(manifest.keys().cloned());
    checked(&command, b"", &Env::new(), None, 30.0)?;
    let mut locations = Vec::new();
    for (name, entry) in manifest {
        ensure(
            json!(hash(functions.join(format!("{name}.sh")))?) == entry["body_sha256"],
            format!("selected function changed; review denominator: {name}"),
        )?;
        let start = source_lines
            .iter()
            .position(|line| *line == format!("{name}() {{"))
            .ok_or("function not found")?
            + 1;
        let lines: Vec<_> = entry["relative_lines"]
            .as_array()
            .ok_or("invalid lines")?
            .iter()
            .map(|v| {
                let rel = v.as_u64().unwrap() as usize;
                (rel, start + rel - 1)
            })
            .collect();
        locations.push((name.clone(), lines));
    }
    let collect = |script: &Path| -> Result<(String, BTreeSet<(String, usize)>)> {
        let trace = dir.path().join("locations");
        let env = Env::from([
            ("AG_LOCATION_TRACE".into(), trace.display().to_string()),
            (
                "AGENT_GUARD_UNIT_SOURCE".into(),
                source.display().to_string(),
            ),
        ]);
        let driver="set -T\nexec 9>\"$AG_LOCATION_TRACE\"\ntrap 'printf \"%s:%s\\n\" \"${BASH_SOURCE[0]:-driver}\" \"$LINENO\" >&9' DEBUG\n. \"$0\"\n";
        let (_, output) = checked(
            &[
                "/bin/bash".into(),
                "-c".into(),
                driver.into(),
                script.display().to_string(),
            ],
            b"",
            &env,
            None,
            300.0,
        )?;
        let mut observed = BTreeSet::new();
        for event in std::fs::read_to_string(trace)?.lines() {
            if let Some((path, number)) = event.rsplit_once(':') {
                let name = Path::new(path)
                    .file_stem()
                    .unwrap_or_default()
                    .to_string_lossy()
                    .to_string();
                if let Ok(number) = number.parse::<usize>() {
                    if locations
                        .iter()
                        .any(|(n, lines)| *n == name && lines.iter().any(|(rel, _)| *rel == number))
                    {
                        observed.insert((name, number));
                    }
                }
            }
        }
        Ok((String::from_utf8(output)?, observed))
    };
    let mut observed = BTreeSet::new();
    let mut suites = Vec::new();
    for suite in [
        "unit-core.sh",
        "unit-framing.sh",
        "unit-deny-path.sh",
        "unit-probe.sh",
    ] {
        let path = root.join("tests").join(suite);
        let (output, events) = collect(&path)?;
        observed.extend(events);
        let counts: Vec<_> = output
            .lines()
            .filter(|s| s.starts_with("passed:") || s.starts_with("failed:"))
            .collect();
        suites.push(json!({"suite":suite,"counts":counts,"sha256":hash(path)?}));
    }
    let control = dir.path().join("definitions-only.sh");
    let mut definitions = String::new();
    for name in manifest.keys() {
        definitions.push_str(&format!(
            ". \"{}\"\n",
            functions.join(format!("{name}.sh")).display()
        ));
    }
    std::fs::write(&control, definitions)?;
    let (_, controls) = collect(&control)?;
    let rows:Vec<_>=locations.iter().map(|(name,lines)|json!({"function":name,"eligible_source_lines":lines.iter().map(|(_,src)|src).collect::<Vec<_>>(),"observed_source_lines":lines.iter().filter(|(rel,_)|observed.contains(&(name.clone(),*rel))).map(|(_,src)|src).collect::<Vec<_>>(),"missing_source_lines":lines.iter().filter(|(rel,_)|!observed.contains(&(name.clone(),*rel))).map(|(_,src)|src).collect::<Vec<_>>(),"definition_only_source_lines":lines.iter().filter(|(rel,_)|controls.contains(&(name.clone(),*rel))).map(|(_,src)|src).collect::<Vec<_>>()})).collect();
    emit(
        &json!({"source_sha256":hash(source)?,"bash":version(&["/bin/bash","--version"])?.lines().next().unwrap(),"denominator":locations.iter().map(|(_,lines)|lines.len()).sum::<usize>(),"observed":observed.len(),"definition_only_observed":controls.len(),"suites":suites,"functions":rows}),
    )?;
    ensure(
        controls.is_empty(),
        "definition-only control unexpectedly reached selected locations",
    )
}
