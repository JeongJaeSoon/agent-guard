use crate::common::*;
use serde_json::{json, Value};
use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

fn files(root: &Path, path: &Path, out: &mut Vec<PathBuf>) -> Result<()> {
    for entry in std::fs::read_dir(path)? {
        let entry = entry?;
        let kind = entry.file_type()?;
        if kind.is_dir() {
            files(root, &entry.path(), out)?;
        } else if kind.is_file() {
            out.push(entry.path());
        } else if kind.is_symlink() {
            // Upstream includes a file-symlink fixture. Read its bytes only
            // when the resolved target remains a regular file in the corpus.
            let target = std::fs::canonicalize(entry.path())?;
            ensure(
                target.starts_with(root) && target.is_file(),
                "unsafe corpus symlink",
            )?;
            out.push(entry.path());
        } else {
            return Err("unexpected non-regular corpus entry".into());
        }
    }
    Ok(())
}

// Compare complete finding records after sorting only their order. No fields,
// secrets, line/column offsets, entropies or rule identities are discarded.
fn canonical(report: &Path) -> Result<Vec<String>> {
    let report = read_json(report)?;
    let rows = report.as_array().ok_or("scanner report is not an array")?;
    let mut rows = rows
        .iter()
        .map(serde_json::to_string)
        .collect::<std::result::Result<Vec<_>, _>>()?;
    rows.sort();
    Ok(rows)
}

pub fn differential(args: &Args) -> Result<()> {
    let source = PathBuf::from(absolute(args.get("--source")?)?);
    let out = PathBuf::from(args.get("--out")?);
    ensure(out.is_absolute(), "output directory must be absolute")?;
    std::fs::create_dir(&out)?; // Never overwrite a previous run.
    let config = root()?.join("plugins/agent-guard/config/gitleaks.toml");
    let mut scanners = vec![("public", absolute(args.get("--scanner")?)?)];
    if let Ok(control) = args.get("--control-scanner") {
        scanners.push(("control", absolute(control)?));
    }
    scanners.push(("candidate", absolute(args.get("--candidate-scanner")?)?));
    let mut corpus = Vec::new();
    files(&source, &source, &mut corpus)?;
    corpus.sort();
    let mut inputs: Vec<(String, Vec<u8>, Option<BTreeSet<String>>)> = corpus
        .iter()
        .map(|p| {
            Ok((
                p.strip_prefix(&source)?.display().to_string(),
                std::fs::read(p)?,
                None,
            ))
        })
        .collect::<Result<_>>()?;
    let token = format!("{}{}", "ghp_", "a".repeat(36));
    let expected = BTreeSet::from([token.clone()]);
    inputs.push((
        "independent-clean".into(),
        b"public build completed".to_vec(),
        Some(BTreeSet::new()),
    ));
    inputs.push((
        "independent-placeholder".into(),
        format!("{}{}", "ghp_", "x".repeat(36)).into_bytes(),
        Some(BTreeSet::new()),
    ));
    for (name, value) in [
        ("token", token.clone()),
        ("unicode", format!("한국어 😀\n{token}\n公開")),
        ("nul", format!("visible\0{token}\0tail")),
        ("crlf", format!("visible\r\n{token}\r\ntail")),
        ("quoted", format!("key=\"{token}\"")),
    ] {
        inputs.push((
            format!("independent-{name}"),
            value.into_bytes(),
            Some(expected.clone()),
        ));
    }
    // Differential probes for documented regex edge behavior, kept separate
    // from independently asserted valid-text detection expectations.
    for prefix in [vec![0xff], vec![0xc0, 0xaf], vec![0xe2, 0x82], vec![0x80]] {
        let mut input = prefix.clone();
        input.extend_from_slice(token.as_bytes());
        inputs.push((format!("invalid-utf8-before-{prefix:x?}"), input, None));
        let mut input = token.as_bytes().to_vec();
        input.extend(prefix.clone());
        inputs.push((format!("invalid-utf8-after-{prefix:x?}"), input, None));
    }
    let mut results = Vec::new();
    let mut failures = 0;
    for (index, (name, input, expected)) in inputs.into_iter().enumerate() {
        let case_dir = out.join(format!("case-{index:04}"));
        std::fs::create_dir(&case_dir)?;
        std::fs::write(case_dir.join("input.raw"), &input)?;
        let mut reference = None;
        let mut backend_rows = Vec::new();
        for (label, scanner) in &scanners {
            let report = case_dir.join(format!("{label}.json"));
            let command = vec![
                scanner.clone(),
                "stdin".into(),
                "--no-banner".into(),
                "--config".into(),
                config.display().to_string(),
                "--report-format".into(),
                "json".into(),
                "--report-path".into(),
                report.display().to_string(),
            ];
            let (_, output) = invoke(&command, &input, &Env::new(), Some(&out), 30.0)?;
            std::fs::write(case_dir.join(format!("{label}.stdout")), &output.stdout)?;
            std::fs::write(case_dir.join(format!("{label}.stderr")), &output.stderr)?;
            let status = output.status.code();
            let records = canonical(&report);
            let valid_status = matches!(status, Some(0 | 1));
            let independent = match (&records, &expected) {
                (Ok(records), Some(expected)) => {
                    let secrets = records
                        .iter()
                        .map(|r| {
                            serde_json::from_str::<Value>(r)
                                .map(|r| r["Secret"].as_str().unwrap_or("").to_owned())
                        })
                        .collect::<std::result::Result<BTreeSet<_>, _>>()?;
                    secrets == *expected && status == Some(i32::from(!expected.is_empty()))
                }
                (Ok(_), None) => true,
                _ => false,
            };
            let matches = if *label == "public" {
                reference = records.as_ref().ok().map(|r| (status, r.clone()));
                reference.is_some()
            } else {
                records
                    .as_ref()
                    .ok()
                    .is_some_and(|r| reference.as_ref() == Some(&(status, r.clone())))
            };
            let passed = valid_status && independent && matches;
            if !passed {
                failures += 1;
            }
            backend_rows.push(json!({"backend":label,"status":status,"matches_public":matches,
                "independent_expected":expected.is_some(),"independent_passed":independent,"passed":passed}));
        }
        results.push(json!({"name":name,"directory":format!("case-{index:04}"),"input_sha256":hash(case_dir.join("input.raw"))?,"backends":backend_rows}));
    }
    let mut hashes = json!({});
    for (label, scanner) in &scanners {
        hashes[label] = json!(hash(scanner)?);
    }
    let summary = json!({"cases":results.len(),"failures":failures,"config_sha256":hash(&config)?,"scanner_sha256":hashes,"results":results});
    write_json(out.join("summary.json"), &summary)?;
    emit(&summary)?;
    ensure(
        failures == 0,
        "scanner differential or independent expectation failed",
    )
}
