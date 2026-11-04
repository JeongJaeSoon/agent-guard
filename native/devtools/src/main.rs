mod common;
mod contracts;
mod measure;
mod report;
mod verification;
use common::*;

fn main() {
    install_interrupt_cleanup();
    if let Err(error) = main_result() {
        eprintln!("agent-guard-devtools: {error}");
        std::process::exit(1);
    }
}

fn main_result() -> Result<()> {
    let args = Args::new()?;
    match args.command.as_str() {
        "native-redaction" => contracts::differential(&args),
        "native-integration" => contracts::integration(&args),
        "resource-sample" => measure::resource_sample(&args),
        "masking-latency" => measure::latency(&args),
        "kernel" => measure::kernel(&args),
        "load" => measure::load(&args),
        "watchdog-orphans" => verification::watchdog(&args),
        "verify" => verification::verify(&args),
        "measure-selected-bash" => verification::selected_bash(&args),
        "report" => report::run(&args),
        _ => Err("commands: native-redaction, native-integration, resource-sample, masking-latency, kernel, load, watchdog-orphans, verify, measure-selected-bash, report".into()),
    }
}
