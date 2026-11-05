use serde::Deserialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::io::{Read, Write};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::sync::atomic::{AtomicI32, Ordering};
use std::time::{Duration, Instant};
static GROUPS: [AtomicI32; 128] = [const { AtomicI32::new(0) }; 128];
extern "C" fn interrupted(signal: i32) {
    for slot in &GROUPS {
        let pid = slot.load(Ordering::Relaxed);
        if pid > 0 {
            unsafe {
                libc::kill(-pid, libc::SIGKILL);
            }
        }
    }
    unsafe {
        libc::_exit(128 + signal);
    }
}
pub fn install_interrupt_cleanup() {
    unsafe {
        libc::signal(libc::SIGINT, interrupted as libc::sighandler_t);
        libc::signal(libc::SIGTERM, interrupted as libc::sighandler_t);
    }
}
struct GroupGuard {
    slot: usize,
    armed: bool,
}
impl Drop for GroupGuard {
    fn drop(&mut self) {
        let pid = GROUPS[self.slot].swap(0, Ordering::Relaxed);
        if self.armed && pid > 0 {
            unsafe {
                libc::kill(-pid, libc::SIGKILL);
            }
        }
    }
}
pub type Result<T> = std::result::Result<T, Box<dyn std::error::Error + Send + Sync>>;
pub type Env = BTreeMap<String, String>;
pub struct Args {
    pub command: String,
    pub values: Vec<String>,
}
impl Args {
    pub fn new() -> Result<Self> {
        let mut values: Vec<_> = std::env::args().skip(1).collect();
        if values.is_empty() {
            return Err("a command is required".into());
        }
        let command = values.remove(0);
        let commands = "native-redaction, native-integration, scanner-differential, resource-sample, masking-latency, kernel, load, watchdog-orphans, verify, measure-selected-bash, report";
        if ["--help", "-h", "help"].contains(&command.as_str()) {
            println!("Usage: agent-guard-devtools <command> [options]\nCommands: {commands}");
            std::process::exit(0);
        }
        if command == "resource-sample" {
            // The destination and child argv are positional and must pass through.
            if values.len() == 1 && ["--help", "-h"].contains(&values[0].as_str()) {
                println!(
                    "Usage: agent-guard-devtools resource-sample destination command [args...]"
                );
                std::process::exit(0);
            }
            return Ok(Self { command, values });
        }
        let options: &[&str] = match command.as_str() {
            "native-redaction" => &["--core", "--source"],
            "output-prepare" => &["--core"],
            "native-integration" => &["--core", "--scanner"],
            "scanner-differential" => &[
                "--scanner",
                "--candidate-scanner",
                "--control-scanner",
                "--source",
                "--out",
            ],
            "masking-latency" => &[
                "--binary",
                "--baseline",
                "--native-core",
                "--prepare-core",
                "--host",
                "--scanner",
                "--candidate-scanner",
                "--audit-state",
                "--runs",
                "--timeout",
                "--case",
            ],
            "kernel" => &["--core", "--runs"],
            "load" => &[
                "--binary",
                "--core",
                "--prepare-core",
                "--scanner",
                "--workers",
                "--requests",
            ],
            "watchdog-orphans" => &["--binary", "--baseline", "--scanner", "--runs"],
            "verify" => &["--out", "--native-core", "--shards"],
            "report" => &["--results", "--html"],
            "measure-selected-bash" => &[],
            _ => return Err(format!("unknown command; choose: {commands}").into()),
        };
        let flags: &[&str] = if command == "masking-latency" {
            &[
                "--resources",
                "--include-boundaries",
                "--trace-processes",
                "--packaged-native",
                "--baseline-packaged-native",
                "--fused-output",
            ]
        } else if command == "load" {
            &["--packaged-native", "--fused-output"]
        } else {
            &[]
        };
        if values
            .iter()
            .any(|v| ["--help", "-h"].contains(&v.as_str()))
        {
            println!(
                "Usage: agent-guard-devtools {command} [options]\nValue options: {}\nFlags: {}",
                options.join(", "),
                flags.join(", ")
            );
            std::process::exit(0);
        }
        values = values
            .into_iter()
            .flat_map(|v| {
                if v.starts_with("--") {
                    if let Some((key, value)) = v.split_once('=') {
                        return vec![key.to_owned(), value.to_owned()];
                    }
                }
                vec![v]
            })
            .collect();
        let mut index = 0;
        while index < values.len() {
            let name = values[index].as_str();
            if flags.contains(&name) {
                index += 1;
                continue;
            }
            ensure(options.contains(&name), format!("unknown option: {name}"))?;
            let start = index + 1;
            index = start;
            if name == "--shards" {
                while index < values.len() && !values[index].starts_with("--") {
                    index += 1;
                }
            } else if index < values.len() && !values[index].starts_with("--") {
                index += 1;
            }
            ensure(index > start, format!("option requires a value: {name}"))?;
        }
        Ok(Self { command, values })
    }
    pub fn all(&self, name: &str) -> Vec<String> {
        self.values
            .windows(2)
            .filter(|w| w[0] == name)
            .map(|w| w[1].clone())
            .collect()
    }
    pub fn get(&self, name: &str) -> Result<String> {
        self.all(name)
            .into_iter()
            .last()
            .ok_or_else(|| format!("required option: {name}").into())
    }
    pub fn opt(&self, name: &str, default: impl AsRef<str>) -> String {
        self.get(name)
            .unwrap_or_else(|_| default.as_ref().to_owned())
    }
    pub fn flag(&self, name: &str) -> bool {
        self.values.iter().any(|v| v == name)
    }
    pub fn positive(&self, name: &str, default: usize) -> Result<usize> {
        let n = self.opt(name, default.to_string()).parse()?;
        ensure(n > 0, "count must be positive")?;
        Ok(n)
    }
}
pub fn root() -> Result<PathBuf> {
    // Runtime location is independent of the machine that built the executable.
    let mut path = std::env::current_dir()?;
    loop {
        if path.join("plugins/agent-guard/bin/agent-guard").is_file() {
            return Ok(path);
        }
        if !path.pop() {
            return Err("run from inside the agent-guard repository".into());
        }
    }
}
pub fn cli() -> Result<String> {
    Ok(root()?
        .join("plugins/agent-guard/bin/agent-guard")
        .display()
        .to_string())
}
pub fn absolute(path: impl AsRef<Path>) -> Result<String> {
    Ok(std::fs::canonicalize(path)?.display().to_string())
}
pub fn hash(path: impl AsRef<Path>) -> Result<String> {
    Ok(format!("{:x}", Sha256::digest(std::fs::read(path)?)))
}
pub fn parse(bytes: &[u8]) -> Result<Value> {
    let mut de = serde_json::Deserializer::from_slice(bytes);
    de.disable_recursion_limit();
    let value = serde_json::Value::deserialize(&mut de)?;
    de.end()?;
    Ok(value)
}
pub fn read_json(path: impl AsRef<Path>) -> Result<Value> {
    parse(&std::fs::read(path)?)
}
pub fn write_json(path: impl AsRef<Path>, v: &Value) -> Result<()> {
    std::fs::write(path, serde_json::to_vec_pretty(v)?)?;
    Ok(())
}
pub fn emit(v: &Value) -> Result<()> {
    println!("{}", serde_json::to_string_pretty(v)?);
    Ok(())
}
pub fn ensure(ok: bool, msg: impl AsRef<str>) -> Result<()> {
    if ok {
        Ok(())
    } else {
        Err(msg.as_ref().to_owned().into())
    }
}
pub fn number(v: &Value) -> f64 {
    v.as_f64().expect("numeric measurement")
}
pub fn median(mut v: Vec<f64>) -> f64 {
    assert!(!v.is_empty());
    assert!(v.iter().all(|x| x.is_finite()));
    v.sort_by(f64::total_cmp);
    let n = v.len();
    if n % 2 == 1 {
        v[n / 2]
    } else {
        (v[n / 2 - 1] + v[n / 2]) / 2.0
    }
}
pub fn metrics(rows: &[Value]) -> Value {
    let mut out = json!({});
    for key in rows[0].as_object().unwrap().keys() {
        out[key] = json!(median(rows.iter().map(|r| number(&r[key])).collect()));
    }
    out
}
pub fn base_env(scanner: &str) -> Result<Env> {
    Ok(Env::from([
        ("AGENT_GUARD_LOG_MODE".into(), "off".into()),
        ("AGENT_GUARD_RELEASE_CHECK".into(), "off".into()),
        ("AGENT_GUARD_GITLEAKS_BIN".into(), absolute(scanner)?),
        (
            "AGENT_GUARD_GITLEAKS_CONFIG".into(),
            root()?
                .join("plugins/agent-guard/config/gitleaks.toml")
                .display()
                .to_string(),
        ),
        ("AGENT_GUARD_PII_HOOK_MODE".into(), "off".into()),
        ("AGENT_GUARD_OUTPUT_REDACT".into(), "mask".into()),
    ]))
}
pub fn invoke(
    command: &[String],
    input: &[u8],
    env: &Env,
    cwd: Option<&Path>,
    timeout: f64,
) -> Result<(f64, Output)> {
    ensure(
        !command.is_empty() && timeout.is_finite() && timeout > 0.0,
        "invalid command/timeout",
    )?;
    let start = Instant::now();
    let mut builder = Command::new(&command[0]);
    builder
        .args(&command[1..])
        .envs(env)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if let Some(cwd) = cwd {
        builder.current_dir(cwd);
    }
    // Each invocation owns a process group. A timeout reaps that tree.
    unsafe {
        builder.pre_exec(|| {
            if libc::setsid() == -1 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let mut child = builder.spawn()?;
    let pid = child.id();
    let slot = GROUPS
        .iter()
        .position(|slot| {
            slot.compare_exchange(0, pid as i32, Ordering::Relaxed, Ordering::Relaxed)
                .is_ok()
        })
        .ok_or("too many concurrent invocations")?;
    let mut guard = GroupGuard { slot, armed: true };
    let (stop, timer) = std::sync::mpsc::channel();
    let watchdog = std::thread::spawn(move || {
        if timer
            .recv_timeout(Duration::from_secs_f64(timeout))
            .is_err()
        {
            unsafe {
                libc::kill(-(pid as i32), libc::SIGKILL);
            }
            true
        } else {
            false
        }
    });
    let mut stdin = child.stdin.take().unwrap();
    let mut stdout = child.stdout.take().unwrap();
    let mut stderr = child.stderr.take().unwrap();
    let bytes = input.to_vec();
    let writer = std::thread::spawn(move || stdin.write_all(&bytes));
    let out_reader = std::thread::spawn(move || {
        let mut b = Vec::new();
        stdout.read_to_end(&mut b).map(|_| b)
    });
    let err_reader = std::thread::spawn(move || {
        let mut b = Vec::new();
        stderr.read_to_end(&mut b).map(|_| b)
    });
    let status = child.wait()?;
    let _ = writer.join();
    let stdout = out_reader.join().map_err(|_| "stdout reader panicked")??;
    let stderr = err_reader.join().map_err(|_| "stderr reader panicked")??;
    let _ = stop.send(());
    let timed_out = watchdog.join().map_err(|_| "watchdog panicked")?;
    ensure(!timed_out, "measurement timed out")?;
    guard.armed = false;
    Ok((
        start.elapsed().as_secs_f64(),
        Output {
            status,
            stdout,
            stderr,
        },
    ))
}
pub fn checked(
    command: &[String],
    input: &[u8],
    env: &Env,
    cwd: Option<&Path>,
    timeout: f64,
) -> Result<(f64, Vec<u8>)> {
    let (elapsed, out) = invoke(command, input, env, cwd, timeout)?;
    ensure(
        out.status.success(),
        format!("command failed: {} ({})", command[0], out.status),
    )?;
    Ok((elapsed, out.stdout))
}
pub fn version(command: &[&str]) -> Result<String> {
    let (_, bytes) = checked(
        &command.iter().map(|s| s.to_string()).collect::<Vec<_>>(),
        b"",
        &Env::new(),
        None,
        15.0,
    )?;
    Ok(String::from_utf8(bytes)?.trim().to_owned())
}
pub fn executable(path: &Path, text: &str) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::write(path, text)?;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn deadline_covers_inherited_output_pipes() {
        let start = Instant::now();
        let result = invoke(
            &["sh".into(), "-c".into(), "sleep 10 & exit 0".into()],
            b"",
            &Env::new(),
            None,
            0.05,
        );
        assert!(result.is_err());
        assert!(start.elapsed().as_secs_f64() < 2.0);
    }
}
