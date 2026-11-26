mod common;
mod contracts;
mod hooks;
mod measure;
mod scanner;
mod verification;
use common::*;

fn main() {
    install_interrupt_cleanup();
    if let Err(error) = main_result() {
        eprintln!("agent-guard-devtools: {error}");
        std::process::exit(1);
    }
}

const COMMANDS: &[Subcommand] = &[
    Subcommand {
        name: "native-redaction",
        options: Some(&["--core", "--source"]),
        flags: &[],
        run: contracts::differential,
    },
    Subcommand {
        name: "native-integration",
        options: Some(&["--core", "--scanner"]),
        flags: &[],
        run: contracts::integration,
    },
    Subcommand {
        name: "scanner-differential",
        options: Some(&[
            "--scanner",
            "--candidate-scanner",
            "--control-scanner",
            "--source",
            "--out",
        ]),
        flags: &[],
        run: scanner::differential,
    },
    // The destination and child argv are positional and must pass through.
    Subcommand {
        name: "resource-sample",
        options: None,
        flags: &[],
        run: measure::resource_sample,
    },
    Subcommand {
        name: "masking-latency",
        options: Some(&[
            "--binary",
            "--baseline",
            "--native-core",
            "--host",
            "--scanner",
            "--candidate-scanner",
            "--audit-state",
            "--runs",
            "--timeout",
            "--case",
        ]),
        flags: &[
            "--resources",
            "--include-boundaries",
            "--trace-processes",
            "--packaged-native",
            "--baseline-packaged-native",
        ],
        run: measure::latency,
    },
    Subcommand {
        name: "hook-latency",
        options: Some(&[
            "--binary",
            "--scanner",
            "--helper",
            "--entry",
            "--runs",
            "--timeout",
            "--case",
            "--arm",
            "--out",
        ]),
        flags: &[],
        run: hooks::latency,
    },
    Subcommand {
        name: "kernel",
        options: Some(&["--core", "--runs"]),
        flags: &[],
        run: measure::kernel,
    },
    Subcommand {
        name: "load",
        options: Some(&["--binary", "--core", "--scanner", "--workers", "--requests"]),
        flags: &["--packaged-native"],
        run: measure::load,
    },
    Subcommand {
        name: "verify",
        options: Some(&["--out", "--native-core", "--shards"]),
        flags: &[],
        run: verification::verify,
    },
    Subcommand {
        name: "refresh-selected-bash",
        options: Some(&[]),
        flags: &[],
        run: verification::refresh_selected_bash,
    },
    Subcommand {
        name: "measure-selected-bash",
        options: Some(&[]),
        flags: &[],
        run: verification::selected_bash,
    },
];

fn main_result() -> Result<()> {
    let (command, args) = Args::new(COMMANDS)?;
    (command.run)(&args)
}
