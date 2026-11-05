//! Experimental literal redactor. Detection and policy remain in the shell CLI.
use serde_json::Value;
use std::io::{self, Read, Write};

const MASK: &str = "[REDACTED]";
struct Spec {
    literal: String,
    replacement: String,
    contextual: bool,
    length: usize,
    order: usize,
}

fn protected(key: Option<&str>, text: &str) -> bool {
    matches!(key, Some("type" | "media_type" | "mimeType" | "encoding"))
        && matches!(
            text,
            "text"
                | "image"
                | "document"
                | "search_result"
                | "browser_state"
                | "tool_reference"
                | "tool_use"
                | "tool_result"
                | "thinking"
                | "redacted_thinking"
                | "base64"
                | "url"
                | "file"
                | "content"
                | "pdf"
                | "image/png"
                | "image/jpeg"
                | "image/gif"
                | "image/webp"
                | "application/pdf"
                | "text/plain"
        )
}

fn string_work(value: &Value) -> usize {
    match value {
        Value::String(s) => s.chars().count().saturating_add(1),
        Value::Array(a) => a.iter().map(string_work).fold(0, usize::saturating_add),
        Value::Object(o) => o.values().map(string_work).fold(0, usize::saturating_add),
        _ => 0,
    }
}

fn replace_context(text: &str, spec: &Spec) -> String {
    let mut parts = text.split(&spec.literal);
    let mut out = parts.next().unwrap_or_default().to_owned();
    for part in parts {
        // Match jq's split-segment semantics, including adjacent literals.
        let boundary =
            part.is_empty() || matches!(part.as_bytes()[0], b' ' | b'\t' | b'\n' | b',' | b';');
        out.push_str(if boundary {
            &spec.replacement
        } else {
            &spec.literal
        });
        out.push_str(part);
    }
    out
}

fn walk(value: &mut Value, key: Option<&str>, specs: &[Spec], whole: bool) {
    match value {
        Value::Object(o) => {
            for (k, v) in o.iter_mut() {
                walk(v, Some(k), specs, whole);
            }
        }
        Value::Array(a) => {
            for v in a {
                walk(v, None, specs, whole);
            }
        }
        Value::String(s) if !s.is_empty() && !protected(key, s) => {
            if whole {
                *s = MASK.to_owned();
                return;
            }
            for spec in specs {
                if !spec.literal.is_empty() && s.contains(&spec.literal) {
                    *s = if spec.contextual {
                        replace_context(s, spec)
                    } else {
                        s.replace(&spec.literal, &spec.replacement)
                    };
                }
            }
        }
        _ => {}
    }
}

fn redact(mut request: Value) -> Result<Value, ()> {
    if request.get("protocol").and_then(Value::as_u64) != Some(1)
        || request.get("response").is_none()
    {
        return Err(());
    }
    let inputs = request.get("secrets").and_then(Value::as_array).ok_or(())?;
    let mut specs = Vec::new();
    for (order, input) in inputs.iter().enumerate() {
        let (literal, replacement, contextual) = match input {
            Value::String(s) => (s.as_str(), MASK, false),
            Value::Object(o) => match (
                o.get("literal").and_then(Value::as_str),
                o.get("replacement").and_then(Value::as_str),
            ) {
                (Some(l), Some(r)) => (l, r, o.get("contextual") == Some(&Value::Bool(true))),
                _ => continue,
            },
            _ => continue,
        };
        specs.push(Spec {
            literal: literal.to_owned(),
            replacement: replacement.to_owned(),
            contextual,
            length: literal.chars().count(),
            order,
        });
    }
    let mut response = request["response"].take();
    let whole = specs.len() > 256 || specs.len().saturating_mul(string_work(&response)) > 8_000_000;
    // jq stable ascending sort followed by reverse also reverses equal-length ties.
    specs.sort_by_key(|s| {
        (
            std::cmp::Reverse(s.contextual),
            std::cmp::Reverse(s.length),
            std::cmp::Reverse(s.order),
        )
    });
    walk(&mut response, None, &specs, whole);
    Ok(response)
}

// Reject pathological nesting before recursive deserialization. The shell caller
// retains its jq path for unsupported input, including serde_json's reserved key.
fn supported_input(input: &[u8]) -> Result<(), ()> {
    let mut depth = 0usize;
    let mut i = 0;
    while i < input.len() {
        match input[i] {
            b'{' | b'[' => {
                depth += 1;
                if depth > 1024 {
                    return Err(());
                }
            }
            b'}' | b']' => depth = depth.saturating_sub(1),
            b'"' => {
                let start = i;
                i += 1;
                while i < input.len() && input[i] != b'"' {
                    if input[i] == b'\\' {
                        i += 1;
                    }
                    i += 1;
                }
                if i >= input.len() {
                    return Err(());
                }
                let mut next = i + 1;
                while next < input.len() && input[next].is_ascii_whitespace() {
                    next += 1;
                }
                if input.get(next) == Some(&b':') {
                    let key: String = serde_json::from_slice(&input[start..=i]).map_err(|_| ())?;
                    if key == "$serde_json::private::Number" {
                        return Err(());
                    }
                }
            }
            _ => {}
        }
        i += 1;
    }
    Ok(())
}

// Experimental transport only: the shell still owns all detector and policy
// decisions. Match jq's value traversal, join, and RS/US escaping byte for byte.
fn prepare_leaves(value: &Value, leaves: &mut Vec<String>) {
    match value {
        Value::String(s) => leaves.push(s.clone()),
        Value::Array(a) => {
            for v in a {
                prepare_leaves(v, leaves);
            }
        }
        Value::Object(o) => {
            for v in o.values() {
                prepare_leaves(v, leaves);
            }
        }
        _ => {}
    }
}

fn prepare(value: &Value, plain_path: &str, frame_path: &str) -> Result<(), ()> {
    let mut leaves = Vec::new();
    prepare_leaves(value, &mut leaves);
    let plain = leaves.join("\n");
    let mut framed = Vec::new();
    for leaf in leaves {
        for byte in leaf.bytes() {
            if byte == 30 || byte == 31 {
                framed.push(31);
            }
            framed.push(byte);
        }
        framed.extend_from_slice(b"\x1e\n");
    }
    // Destinations belong to the caller's private staging directory. Publish
    // the completion record only after both complete writes succeed. A caller
    // must overwrite both stages on failure; never consume a successful prefix.
    for (path, bytes) in [(plain_path, plain.as_bytes()), (frame_path, &framed)] {
        std::fs::OpenOptions::new()
            .write(true)
            .truncate(true)
            .open(path)
            .map_err(|_| ())?
            .write_all(bytes)
            .map_err(|_| ())?;
    }
    io::stdout()
        .lock()
        .write_all(b"prepared-v1\n")
        .map_err(|_| ())
}

fn run() -> Result<(), ()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args == ["--version"] {
        println!("agent-guard-redact 0.1.0 protocol=1");
        return Ok(());
    }
    let preparing = args.len() == 3 && args[0] == "prepare-v1";
    if args != ["redact-v1"] && !preparing {
        return Err(());
    }
    let mut input = Vec::new();
    io::stdin().read_to_end(&mut input).map_err(|_| ())?;
    supported_input(&input)?;
    let mut parser = serde_json::Deserializer::from_slice(&input);
    parser.disable_recursion_limit();
    let mut values = parser.into_iter::<Value>();
    let request = values.next().ok_or(())?.map_err(|_| ())?;
    if values.next().is_some() {
        return Err(());
    }
    if preparing {
        return prepare(&request, &args[1], &args[2]);
    }
    let output = redact(request)?;
    // Serialize completely before publishing. Errors never include input data.
    let mut bytes = serde_json::to_vec(&output).map_err(|_| ())?;
    bytes.push(b'\n');
    io::stdout().lock().write_all(&bytes).map_err(|_| ())
}

fn main() {
    if run().is_err() {
        eprintln!("agent-guard-redact: invalid request or processing failure");
        std::process::exit(1);
    }
}
