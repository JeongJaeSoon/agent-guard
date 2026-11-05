use crate::common::*;
use serde_json::{json, Value};
use std::path::Path;

pub fn reference(source: &Path) -> Result<String> {
    let text = std::fs::read_to_string(source)?;
    let walk = text
        .split_once("JQ_SHAPE_SAFE_WALK='")
        .ok_or("jq walk missing")?
        .1
        .split_once("\n'")
        .ok_or("jq walk end missing")?
        .0;
    let function = text
        .split_once("redact_tool_response_json() {")
        .ok_or("redactor missing")?
        .1
        .split_once("\n}\n")
        .ok_or("redactor end missing")?
        .0;
    let program = function
        .split_once("\"$JQ_SHAPE_SAFE_WALK\"'")
        .ok_or("jq program missing")?
        .1
        .rsplit_once("' 2>/dev/null")
        .ok_or("jq program end missing")?
        .0;
    Ok(format!(
        "{walk}\n.secrets as $secrets | .response | {program}"
    ))
}
pub fn differential(args: &Args) -> Result<()> {
    let core = absolute(args.get("--core")?)?;
    let source = args.opt("--source", cli()?);
    let directory = tempfile::tempdir()?;
    let reference_path = directory.path().join("reference.jq");
    std::fs::write(&reference_path, reference(Path::new(&source))?)?;
    // Frozen inputs exported from Python Random(60261104). Keeping the corpus
    // avoids accidentally changing coverage when replacing the generator.
    let corpus = read_json(root()?.join("tests/fixtures/native-contracts.json"))?;
    let mut count = 0;
    for case in corpus.as_array().ok_or("invalid corpus")? {
        let payload =
            serde_json::to_vec(&json!({"protocol":1,"response":case[1],"secrets":case[2]}))?;
        let (_, old) = checked(
            &[
                "jq".into(),
                "-c".into(),
                "-f".into(),
                reference_path.display().to_string(),
            ],
            &payload,
            &Env::new(),
            None,
            15.0,
        )?;
        let (_, new) = checked(
            &[core.clone(), "redact-v1".into()],
            &payload,
            &Env::new(),
            None,
            15.0,
        )?;
        ensure(
            parse(&old)? == parse(&new)?,
            format!("differential mismatch: {}", case[0]),
        )?;
        count += 1;
    }
    let mut malformed: Vec<Vec<u8>> = [
        r#"{"protocol":1,"response":{"$serde_json::private::Number":"123"},"secrets":[]}"#,
        r#"{"protocol":1,"response":{"\u0024serde_json::private::Number":"123"},"secrets":[]}"#,
        "",
        " ",
        "{",
        "{}",
        r#"{"protocol":2,"response":"secret","secrets":[]}"#,
        r#"{"protocol":1,"response":"secret","secrets":null}"#,
        r#"{"protocol":1,"response":"secret","secrets":[]}{}"#,
    ]
    .iter()
    .map(|x| x.as_bytes().to_vec())
    .collect();
    malformed.push(format!("{}0{}", "[".repeat(1025), "]".repeat(1025)).into_bytes());
    let mut invalid_utf8 = b"{\"protocol\":1,\"response\":\"".to_vec();
    invalid_utf8.push(255);
    invalid_utf8.extend_from_slice(b"\",\"secrets\":[]}");
    malformed.push(invalid_utf8);
    for payload in malformed {
        let (_, out) = invoke(
            &[core.clone(), "redact-v1".into()],
            &payload,
            &Env::new(),
            None,
            15.0,
        )?;
        ensure(
            !out.status.success()
                && out.stdout.is_empty()
                && !out.stderr.windows(6).any(|s| s == b"secret"),
            "invalid input published output",
        )?;
        count += 1;
    }
    emit(&json!({"passed":count,"failed":0,"generated_seed":60261104}))
}

pub fn integration(args: &Args) -> Result<()> {
    let core = absolute(args.get("--core")?)?;
    let mut env = base_env(&args.get("--scanner")?)?;
    let directory = tempfile::tempdir()?;
    let dir = directory.path();
    let marker = dir.join("used");
    let wrapper = dir.join("core");
    let failing = dir.join("failing");
    executable(
        &wrapper,
        "#!/bin/sh\nprintf x >> \"$NATIVE_MARKER\"\nexec \"$NATIVE_REAL_CORE\" \"$@\"\n",
    )?;
    executable(
        &failing,
        "#!/bin/sh\nprintf '{\"partial\":\"unmasked\"}'\nexit 2\n",
    )?;
    env.insert("NATIVE_MARKER".into(), marker.display().to_string());
    env.insert("NATIVE_REAL_CORE".into(), core.clone());
    let variants = [
        core,
        wrapper.display().to_string(),
        failing.display().to_string(),
        dir.join("missing").display().to_string(),
        "relative-path".into(),
    ];
    let values = [
        json!("API_KEY=perf-literal-tail"),
        json!({"stdout":"API_KEY=perf-literal-tail","clean":"visible","type":"text"}),
        json!({"stdout":"API_KEY=perf-literal-tail\0tail","clean":"visible"}),
        json!({"stdout":"API_KEY=perf-literal-tail","$serde_json::private::Number":"123"}),
        json!("ordinary build status"),
    ];
    let mut count = 0;
    for host in ["claude", "codex"] {
        env.insert("AGENT_GUARD_HOOK_HOST".into(), host.into());
        for (response_index, response) in values.iter().enumerate() {
            let payload = serde_json::to_vec(
                &json!({"tool_name":"Read","tool_input":{},"tool_response":response}),
            )?;
            env.insert("AGENT_GUARD_EXPERIMENTAL_REDACTOR".into(), "shell".into());
            eprintln!("integration start: host={host} fixture={response_index} variant=shell");
            let (old_elapsed, old) = invoke(
                &[cli()?, "hook-post-tool".into()],
                &payload,
                &env,
                None,
                30.0,
            )?;
            eprintln!("integration end: host={host} fixture={response_index} variant=shell seconds={old_elapsed:.3} status={}", old.status);
            ensure(
                old.status.success(),
                format!("host baseline failed: {host}, fixture={response_index}, status={}, stderr={:?}", old.status, String::from_utf8_lossy(&old.stderr)),
            )?;
            for (variant_index, binary) in variants.iter().enumerate() {
                eprintln!("integration start: host={host} fixture={response_index} variant={variant_index}");
                env.insert("AGENT_GUARD_EXPERIMENTAL_REDACTOR".into(), "rust".into());
                env.insert("AGENT_GUARD_RUST_CORE_BIN".into(), binary.clone());
                let (new_elapsed, new) = invoke(
                    &[cli()?, "hook-post-tool".into()],
                    &payload,
                    &env,
                    None,
                    30.0,
                )?;
                eprintln!("integration end: host={host} fixture={response_index} variant={variant_index} seconds={new_elapsed:.3} status={}", new.status);
                ensure(
                    new.status.success(),
                    format!("host candidate failed: {host}, fixture={response_index}, status={}, stderr={:?}", new.status, String::from_utf8_lossy(&new.stderr)),
                )?;
                // These are only the fixed synthetic fixtures above. Preserve
                // failure evidence instead of losing it with the temp directory.
                ensure(
                    old.stdout == new.stdout,
                    format!(
                        "host/fallback mismatch: {host}, {binary}, fixture={response_index}, baseline_seconds={old_elapsed}, candidate_seconds={new_elapsed}, baseline_stdout={:?}, candidate_stdout={:?}, baseline_stderr={:?}, candidate_stderr={:?}",
                        String::from_utf8_lossy(&old.stdout),
                        String::from_utf8_lossy(&new.stdout),
                        String::from_utf8_lossy(&old.stderr),
                        String::from_utf8_lossy(&new.stderr),
                    ),
                )?;
                count += 1;
            }
        }
    }
    ensure(
        std::fs::metadata(marker)?.len() > 0,
        "native helper was never used",
    )?;
    for (variant_index, binary) in variants.into_iter().enumerate() {
        eprintln!("redaction-plan start: variant={variant_index}");
        env.insert("AGENT_GUARD_RUST_CORE_BIN".into(), binary);
        checked(
            &[
                "sh".into(),
                root()?
                    .join("tests/redaction-plan.sh")
                    .display()
                    .to_string(),
            ],
            b"",
            &env,
            None,
            30.0,
        )?;
        eprintln!("redaction-plan end: variant={variant_index}");
        count += 8;
    }
    emit(&json!({"passed":count,"failed":0,"native_invocation_verified":true}))
}

#[derive(Clone)]
pub struct Fixture {
    pub name: String,
    pub route: &'static str,
    pub value: Value,
    pub expected: Value,
}
pub fn fixtures(boundaries: bool) -> Vec<Fixture> {
    let suffix = " API_KEY=perf-literal-tail";
    let texts = [
        ("small-clean", "ordinary status: build passed".into()),
        ("long-line", format!("{}{suffix}", "a".repeat(260000))),
        (
            "long-multiline",
            format!("{}\n{suffix}", "a".repeat(260000)),
        ),
        (
            "escaped-control",
            format!("{}\u{1e}{}{suffix}", "a".repeat(130000), "b".repeat(130000)),
        ),
        (
            "many-lines",
            format!("{}{suffix}", "ordinary status: build passed\n".repeat(8000)),
        ),
    ];
    let mut out = Vec::new();
    let mut add = |name: &str, route, value: Value, expected: Value| {
        out.push(Fixture {
            name: name.into(),
            route,
            value,
            expected,
        })
    };
    for (name, value) in &texts {
        add(
            name,
            "hook",
            json!(value),
            json!(value.replace("perf-literal-tail", "[REDACTED]")),
        );
    }
    let mut leaves: Vec<_> = (0..100)
        .map(|i| json!(format!("API_KEY=perf-literal-{i:03}")))
        .collect();
    leaves.extend(vec![json!("status"); 4000]);
    let mut expected = vec![json!("API_KEY=[REDACTED]"); 100];
    expected.extend(vec![json!("status"); 4000]);
    add(
        "many-replacement-leaves",
        "hook",
        json!(leaves),
        json!(expected),
    );
    add(
        "dense-controls",
        "hook",
        json!(format!("{}{suffix}", "a\u{1f}".repeat(40000))),
        json!("[REDACTED]"),
    );
    add(
        "exec-multiline",
        "exec",
        json!(texts[2].1),
        json!(texts[2].1.replace("perf-literal-tail", "[REDACTED]")),
    );
    add("exec-clean", "exec", json!(texts[0].1), json!(texts[0].1));
    add(
        "exec-long-quoted-secret",
        "exec",
        json!(format!(
            " API_KEY='{}\n{}'",
            "a".repeat(30000),
            "b".repeat(30000)
        )),
        json!(" API_KEY='[REDACTED]'"),
    );
    for (name, value) in [
        ("placeholder-control", "API_KEY=example_token"),
        (
            "metadata-control",
            "password_policy=strict token_name=counter",
        ),
        (
            "prose-control",
            "error: password: authentication is disabled",
        ),
    ] {
        add(name, "hook", json!(value), json!(value));
    }
    for size in [1048576, 8388608] {
        add(
            &format!("exec-over-cap-{size}"),
            "exec",
            json!("a".repeat(size)),
            json!("[REDACTED]"),
        );
    }
    if boundaries {
        for (name, tool, input) in [
            ("pre-read-clean", "Read", json!({"file_path":"README.md"})),
            (
                "pre-read-placeholder",
                "Read",
                json!({"file_path":".env.example"}),
            ),
            (
                "pre-bash-clean",
                "Bash",
                json!({"command":"printf 'build passed'"}),
            ),
            ("pre-git-status", "Bash", json!({"command":"git status"})),
            ("pre-unknown-tool", "future_tool", json!({})),
        ] {
            add(
                name,
                "pre",
                json!({"tool_name":tool,"tool_input":input}),
                json!(""),
            );
        }
        add(
            "prompt-clean",
            "prompt",
            json!({"prompt":"Explain the build output"}),
            json!(""),
        );
    }
    out
}

pub fn output_prepare(args: &Args) -> Result<()> {
    let core = absolute(args.get("--core")?)?;
    let directory = tempfile::tempdir()?;
    let plain = directory.path().join("plain");
    let framed = directory.path().join("framed");
    let command = vec![
        core,
        "prepare-v1".into(),
        plain.display().to_string(),
        framed.display().to_string(),
    ];
    let corpus = read_json(root()?.join("tests/fixtures/native-contracts.json"))?;
    let mut cases: Vec<Vec<u8>> = corpus
        .as_array()
        .ok_or("invalid corpus")?
        .iter()
        .map(|c| serde_json::to_vec(&c[1]))
        .collect::<std::result::Result<_, _>>()?;
    cases.extend([
        br#"{"first":"a","second":"b","first":"c"}"#.to_vec(),
        br#"{"number":123456789012345678901234567890,"float":1e400,"text":"visible"}"#.to_vec(),
        r#"["","\u0000","\u001e\u001f","日本語\n한국어"]"#.as_bytes().to_vec(),
    ]);
    let mut count = 0;
    for payload in cases {
        std::fs::write(&plain, b"stale")?;
        std::fs::write(&framed, b"stale")?;
        let (_, ack) = checked(&command, &payload, &Env::new(), None, 15.0)?;
        ensure(ack == b"prepared-v1\n", "missing preparation completion")?;
        for (path, filter) in [
            (&plain, "if type == \"string\" then . else [.. | strings] | join(\"\\n\") end"),
            (&framed, ".. | strings | (split(\"\\u001f\") | join(\"\\u001f\\u001f\")) | (split(\"\\u001e\") | join(\"\\u001f\\u001e\")) | . + \"\\u001e\\n\""),
        ] {
            let (_, expected) = checked(&["jq".into(), "-rj".into(), filter.into()], &payload, &Env::new(), None, 15.0)?;
            ensure(std::fs::read(path)? == expected, format!("prepare mismatch case {count}, {}", path.display()))?;
        }
        count += 1;
    }
    // Independent expected bytes: keys and scalars are excluded, empty leaves
    // remain in join order, and separator bytes inside leaves cannot collide.
    checked(
        &command,
        br#"{"key":["a","",30,"b\u001e\u001f"],"z":null}"#,
        &Env::new(),
        None,
        15.0,
    )?;
    ensure(
        std::fs::read(&plain)? == b"a\n\nb\x1e\x1f",
        "independent plain expectation",
    )?;
    ensure(
        std::fs::read(&framed)? == b"a\x1e\n\x1e\nb\x1f\x1e\x1f\x1f\x1e\n",
        "independent frame expectation",
    )?;
    let mut invalid = vec![
        b"".to_vec(),
        b"{\"secret\":".to_vec(),
        b"{}{}".to_vec(),
        vec![255],
        br#"{"$serde_json::private::Number":"secret"}"#.to_vec(),
    ];
    invalid.push(format!("{}0{}", "[".repeat(1025), "]".repeat(1025)).into_bytes());
    for payload in invalid {
        std::fs::write(&plain, b"stale")?;
        std::fs::write(&framed, b"stale")?;
        let (_, output) = invoke(&command, &payload, &Env::new(), None, 15.0)?;
        ensure(
            !output.status.success() && output.stdout.is_empty(),
            "invalid preparation accepted",
        )?;
        ensure(
            std::fs::read(&plain)? == b"stale" && std::fs::read(&framed)? == b"stale",
            "parse failure published partial files",
        )?;
        count += 1;
    }
    std::fs::remove_file(&framed)?;
    let (_, output) = invoke(&command, br#""secret""#, &Env::new(), None, 15.0)?;
    ensure(
        !output.status.success() && output.stdout.is_empty(),
        "write failure published completion",
    )?;
    emit(
        &json!({"passed":count + 2,"failed":0,"independent_bytes":true,"partial_write_rejected":true}),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use sha2::{Digest, Sha256};
    fn sorted(value: &Value) -> Value {
        match value {
            Value::Object(object) => {
                let mut keys: Vec<_> = object.keys().collect();
                keys.sort();
                let mut result = serde_json::Map::new();
                for key in keys {
                    result.insert(key.clone(), sorted(&object[key]));
                }
                Value::Object(result)
            }
            Value::Array(array) => Value::Array(array.iter().map(sorted).collect()),
            _ => value.clone(),
        }
    }
    #[test]
    fn python_fixture_equivalence() {
        let expected: Value = serde_json::from_str(include_str!(
            "../../../tests/fixtures/masking-fixture-hashes.json"
        ))
        .unwrap();
        let actual: Vec<_> = fixtures(true).iter().map(|f| {
            let digest = |v: &Value| format!("{:x}", Sha256::digest(serde_json::to_vec(&sorted(v)).unwrap()));
            json!({"name":f.name,"route":f.route,"value_sha256":digest(&f.value),"expected_sha256":digest(&f.expected)})
        }).collect();
        assert_eq!(json!(actual), expected);
    }
}
