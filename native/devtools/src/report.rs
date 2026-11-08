use crate::common::*;
use serde_json::{json, Value};
use std::path::PathBuf;

fn cpu(row: &Value, backend: &str) -> f64 {
    let usage = &row["resource_usage"][backend];
    median(
        usage["user_cpu_seconds"]["samples"]
            .as_array()
            .unwrap()
            .iter()
            .zip(usage["system_cpu_seconds"]["samples"].as_array().unwrap())
            .map(|(a, b)| number(a) + number(b))
            .collect(),
    )
}
fn delta(old: f64, new: f64) -> f64 {
    if old == 0.0 {
        0.0
    } else {
        100.0 * (new / old - 1.0)
    }
}
// CPython's integer-seeded MT19937 and 53-bit random(), used by choices().
// Retains the exact paired bootstrap draws instead of substituting a new RNG.
struct PythonRandom {
    state: [u32; 624],
    index: usize,
}
impl PythonRandom {
    fn new(seed: u32) -> Self {
        let mut r = Self {
            state: [0; 624],
            index: 624,
        };
        r.state[0] = 19650218;
        for i in 1..624 {
            r.state[i] = 1812433253u32
                .wrapping_mul(r.state[i - 1] ^ (r.state[i - 1] >> 30))
                .wrapping_add(i as u32);
        }
        let mut i = 1;
        for _ in 0..624 {
            r.state[i] = (r.state[i]
                ^ ((r.state[i - 1] ^ (r.state[i - 1] >> 30)).wrapping_mul(1664525)))
            .wrapping_add(seed);
            i += 1;
            if i >= 624 {
                r.state[0] = r.state[623];
                i = 1;
            }
        }
        for _ in 0..623 {
            r.state[i] = (r.state[i]
                ^ ((r.state[i - 1] ^ (r.state[i - 1] >> 30)).wrapping_mul(1566083941)))
            .wrapping_sub(i as u32);
            i += 1;
            if i >= 624 {
                r.state[0] = r.state[623];
                i = 1;
            }
        }
        r.state[0] = 0x80000000;
        r
    }
    fn word(&mut self) -> u32 {
        if self.index >= 624 {
            for i in 0..624 {
                let y = (self.state[i] & 0x80000000) | (self.state[(i + 1) % 624] & 0x7fffffff);
                self.state[i] = self.state[(i + 397) % 624]
                    ^ (y >> 1)
                    ^ if y & 1 != 0 { 0x9908b0df } else { 0 };
            }
            self.index = 0;
        }
        let mut y = self.state[self.index];
        self.index += 1;
        y ^= y >> 11;
        y ^= (y << 7) & 0x9d2c5680;
        y ^= (y << 15) & 0xefc60000;
        y ^= y >> 18;
        y
    }
    fn random(&mut self) -> f64 {
        let a = self.word() >> 5;
        let b = self.word() >> 6;
        ((a as u64) * 67108864 + b as u64) as f64 / 9007199254740992.0
    }
}
fn interval(row: &Value) -> [f64; 2] {
    let a = row["seconds"]["baseline"]["samples"].as_array().unwrap();
    let b = row["seconds"]["candidate"]["samples"].as_array().unwrap();
    assert_eq!(a.len(), b.len());
    let mut rng = PythonRandom::new(60261104);
    let mut samples = Vec::new();
    for _ in 0..2000 {
        let indices: Vec<_> = (0..a.len())
            .map(|_| (rng.random() * a.len() as f64) as usize)
            .collect();
        samples.push(delta(
            median(indices.iter().map(|i| number(&a[*i])).collect()),
            median(indices.iter().map(|i| number(&b[*i])).collect()),
        ));
    }
    samples.sort_by(f64::total_cmp);
    [samples[49], samples[1949]]
}
fn escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#x27;")
}
fn chart(title: &str, rows: &[(String, f64)], percent: bool) -> String {
    let height = 90 + rows.len() * 30;
    let max = rows
        .iter()
        .map(|(_, v)| *v)
        .fold(if percent { 120.0 } else { 1.0 }, f64::max)
        * 1.12;
    let mut svg=format!("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 1000 {height}\" role=\"img\" aria-label=\"{}\"><rect width=\"1000\" height=\"{height}\" fill=\"white\"/><style>text{{font:14px system-ui;fill:#182e40}}</style><text x=\"20\" y=\"25\">{}</text>",escape(title),escape(title));
    for (i, (name, value)) in rows.iter().enumerate() {
        let y = 55 + i * 30;
        let width = value / max * 620.0;
        svg.push_str(&format!("<text x=\"10\" y=\"{}\">{}</text><rect x=\"275\" y=\"{y}\" width=\"{width:.3}\" height=\"20\" fill=\"{}\"/><text x=\"{:.3}\" y=\"{}\">{value:.2}{}</text>",y+15,escape(name),if percent&&*value>100.0{"#c66c38"}else{"#00877d"},280.0+width,y+15,if percent{"%"}else{""}));
    }
    if percent {
        let x = 275.0 + 100.0 / max * 620.0;
        svg.push_str(&format!(
            "<path d=\"M{x:.3} 40V{}\" stroke=\"#26394a\" stroke-dasharray=\"5 4\"/>",
            height - 10
        ));
    }
    svg.push_str("</svg>");
    svg
}
pub fn run(args: &Args) -> Result<()> {
    let results = PathBuf::from(args.get("--results")?);
    let html = PathBuf::from(
        args.opt(
            "--html",
            root()?
                .join("docs/rust-performance.ko.html")
                .display()
                .to_string(),
        ),
    );
    let read = |name: &str| read_json(results.join(name));
    let claude = read("cli-claude.json")?;
    let codex = read("cli-codex.json")?;
    let kernel = read("kernel.json")?;
    let control = read("cli-shell-control.json")?;
    let supplemental = read("supplemental-verification.json")?;
    let followup = read("cli-clean-followup.json")?;
    let verification = read("verification.json")?;
    let differential = read("differential.json")?;
    let integration = read("integration.json")?;
    let legacy = read("integration-jq16.json")?;
    let ci = if results.join("ci.json").exists() {
        read("ci.json")?
    } else {
        json!({})
    };
    let ci_complete = [
        "CI",
        "Experimental native redactor",
        "Legacy jq and awk contracts",
    ]
    .iter()
    .all(|name| {
        ci["workflows"].as_array().is_some_and(|rows| {
            rows.iter()
                .any(|r| r["name"] == *name && r["conclusion"] == "success")
        })
    });
    if ci != json!({}) {
        ensure(
            ci["cli_sha256"] == verification["before_sha256"],
            "CI CLI hash mismatch",
        )?;
    }
    let mut paths: Vec<_> = std::fs::read_dir(&results)?
        .collect::<std::result::Result<Vec<_>, _>>()?
        .into_iter()
        .map(|e| e.path())
        .filter(|p| {
            p.file_name()
                .unwrap()
                .to_string_lossy()
                .starts_with("load-")
                && p.extension().is_some_and(|e| e == "json")
        })
        .collect();
    paths.sort();
    let loads: Vec<_> = paths.iter().map(read_json).collect::<Result<_>>()?;
    ensure(
        loads.len() == 12 && loads.iter().all(|r| r["verified"] == true),
        "load verification incomplete",
    )?;
    ensure(
        verification["stable"] == true
            && verification["results"]
                .as_array()
                .ok_or("missing verification results")?
                .iter()
                .all(|r| r["status"] == 0),
        "regression verification failed",
    )?;
    for report in [&differential, &integration, &legacy, &supplemental] {
        ensure(report["failed"] == 0, "correctness verification failed")?;
    }
    for report in [&claude, &codex, &control, &kernel, &followup] {
        ensure(
            report["cases"]
                .as_array()
                .ok_or("missing cases")?
                .iter()
                .all(|r| r["verified"] == true),
            "unverified measurement",
        )?;
    }
    for measured in [&claude, &codex, &control, &followup] {
        ensure(
            measured["binary_sha256"]["candidate"] == verification["after_sha256"]
                && measured["binary_sha256"]["baseline"] == claude["binary_sha256"]["baseline"]
                && measured["scanner_sha256"] == claude["scanner_sha256"]
                && measured["config_sha256"] == claude["config_sha256"],
            "measurement source/scanner hash mismatch",
        )?;
        if !measured["native_core_sha256"].is_null() {
            ensure(
                measured["native_core_sha256"] == kernel["native_sha256"],
                "core hash mismatch",
            )?;
        }
    }
    let rows = claude["cases"].as_array().ok_or("missing Claude cases")?;
    let hot = rows
        .iter()
        .find(|r| r["name"] == "many-replacement-leaves")
        .ok_or("missing hot workload")?;
    let hot_wall = delta(
        number(&hot["seconds"]["baseline"]["median"]),
        number(&hot["seconds"]["candidate"]["median"]),
    );
    let hot_cpu = delta(cpu(hot, "baseline"), cpu(hot, "candidate"));
    let hot_rss = delta(
        number(&hot["resource_usage"]["baseline"]["max_child_peak_rss_kib"]["median"]),
        number(&hot["resource_usage"]["candidate"]["max_child_peak_rss_kib"]["median"]),
    );
    let mut regressions = Vec::new();
    for (host, report) in [("Claude", &claude), ("Codex", &codex)] {
        for r in report["cases"].as_array().unwrap() {
            if delta(
                number(&r["seconds"]["baseline"]["median"]),
                number(&r["seconds"]["candidate"]["median"]),
            ) > 5.0
            {
                regressions.push(format!("{host}/{}", r["name"].as_str().unwrap()));
            }
        }
    }
    let metric_gate = (hot_wall <= -10.0 || hot_cpu <= -10.0) && regressions.is_empty();
    let adopt = metric_gate && ci_complete;
    let verdict = if adopt {
        "선택형 Rust 코어 채택 권장"
    } else if metric_gate {
        "Rust 성능 이득 확인 · CI 최종 확인 중"
    } else if hot_wall <= -10.0 || hot_cpu <= -10.0 {
        "Rust 코어의 국소 이득 확인 · 회귀 항목 확인 필요"
    } else {
        "Rust 채택 보류 · 목표 수준의 실익 미확인"
    };
    let mut load_summary = json!({});
    for workers in [1, 4] {
        load_summary[workers.to_string()] = json!({});
        for backend in ["shell", "rust"] {
            let selected: Vec<_> = loads
                .iter()
                .filter(|r| r["workers"] == workers && r["backend"] == backend)
                .collect();
            ensure(selected.len() == 3, "load repetitions missing")?;
            load_summary[workers.to_string()][backend] = json!({"requests_per_second":median(selected.iter().map(|r|number(&r["requests_per_second"])).collect()),"cpu_seconds_per_request":median(selected.iter().map(|r|(number(&r["user_cpu_seconds"])+number(&r["system_cpu_seconds"]))/number(&r["requests"])).collect()),"sampled_sum_rss_mib":median(selected.iter().map(|r|number(&r["sampled_process_rss_peak_kib"])/1024.0).collect())});
        }
    }
    let summary = json!({"verdict":verdict,"opt_in_gate_passed":adopt,"performance_gate_passed":metric_gate,"ci_complete":ci_complete,"hot_latency_change_percent":hot_wall,"hot_cpu_change_percent":hot_cpu,"hot_rss_change_percent":hot_rss,"hot_latency_bootstrap_95_percent_interval":interval(hot),"latency_regressions_over_5_percent":regressions,"load":load_summary});
    let mut document=String::from("<!doctype html><html lang=\"ko\"><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>agent-guard 성능 검증 · Rust 전환 결과</title><style>body{margin:0;background:#f2f5f6;color:#182e40;font:16px/1.7 system-ui,sans-serif}main{max-width:1160px;margin:auto;padding:36px 20px}section{background:white;border:1px solid #e1e8eb;border-radius:14px;padding:24px;margin:22px 0}.chart,.scroll{overflow-x:auto}svg{width:100%;min-width:700px;height:auto}table{border-collapse:collapse;width:100%;font-size:13px}td,th{padding:10px;border-bottom:1px solid #ddd;white-space:nowrap;text-align:left}pre{white-space:pre-wrap;overflow-wrap:anywhere}button{padding:10px 20px;margin:4px;border:0;border-radius:8px;cursor:pointer}button[aria-selected=true]{background:#007f75;color:white}@media print{[hidden]{display:block}button{display:none}}</style><main><h1>Rust 전환, 어디까지 좋아졌나</h1>");
    document.push_str(&format!("<p>{verdict}</p><section><h2>판정과 적용 범위</h2><p>다수 문자열 치환 지연 {hot_wall:+.1}%, CPU {hot_cpu:+.1}%, 개별 자식 peak RSS {hot_rss:+.1}%. 메모리 절감은 입증되지 않았습니다.</p><p>문자열 치환 코어만 Rust로 옮겼습니다. 탐지·정책·PII·호스트 처리는 셸입니다. 기본 실행은 셸/jq이며 Rust 부재·실패 시 기존 경로로 복귀합니다. 플랫폼별 사전 빌드 배포와 기본값 전환은 후속 과제입니다.</p><p>사전 기준: 목표 경로 지연 또는 CPU 10% 이상 개선, 일반 경로 지연 5% 초과 회귀는 추가 검증. 회귀 항목: {}.</p></section>",if regressions.is_empty(){"없음".into()}else{escape(&regressions.join(", "))}));
    let parent = html.parent().ok_or("invalid HTML path")?;
    std::fs::create_dir_all(parent.join("assets"))?;
    document.push_str("<section><h2>실제 CLI · 시나리오별 비교</h2><p>최적화된 셸=100%. 낮을수록 좋습니다. 매 호출 전체 기대값을 검사하며 CPU는 user+system 시간입니다. 정상 경로의 차이는 Rust 효과로 보지 않습니다.</p>");
    for (metric, label) in [
        ("latency", "지연"),
        ("cpu", "CPU 시간"),
        ("rss", "개별 peak RSS"),
    ] {
        document.push_str(&format!(
            "<button data-metric=\"{metric}\" aria-selected=\"{}\">{label}</button>",
            metric == "latency"
        ));
    }
    for metric in ["latency", "cpu", "rss"] {
        let data: Vec<_> = rows
            .iter()
            .map(|row| {
                let values: Vec<_> = ["baseline", "candidate"]
                    .iter()
                    .map(|b| match metric {
                        "latency" => number(&row["seconds"][b]["median"]),
                        "cpu" => cpu(row, b),
                        _ => number(&row["resource_usage"][b]["max_child_peak_rss_kib"]["median"]),
                    })
                    .collect();
                (
                    row["name"].as_str().unwrap().into(),
                    values[1] / values[0] * 100.0,
                )
            })
            .collect();
        let svg = chart(
            &format!("Rust / optimized shell (%) · {metric}"),
            &data,
            true,
        );
        std::fs::write(parent.join(format!("assets/rust-{metric}.svg")), &svg)?;
        document.push_str(&format!(
            "<div class=\"chart\" id=\"chart-{metric}\"{}>{svg}</div>",
            if metric == "latency" { "" } else { " hidden" }
        ));
    }
    document.push_str("</section>");
    let data: Vec<_> = kernel["cases"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| {
            (
                r["name"].as_str().unwrap().into(),
                number(&r["medians"]["shell-jq"]["wall_seconds"])
                    / number(&r["medians"]["rust"]["wall_seconds"]),
            )
        })
        .collect();
    let svg = chart(
        "One-shot redactor speedup (includes process startup)",
        &data,
        false,
    );
    std::fs::write(parent.join("assets/rust-kernel.svg"), &svg)?;
    document.push_str(&format!("<section><h2>코어 자체의 효과</h2><p>{}회 교대 측정. 프로세스 시작·JSON 입출력 포함, 스캐너·전체 파이프라인 제외. 이 배수를 CLI 배수로 읽으면 안 됩니다.</p><div class=\"chart\">{svg}</div></section>",kernel["runs"]));
    let mut data = Vec::new();
    for workers in [1, 4] {
        for backend in ["shell", "rust"] {
            data.push((
                format!("{workers} worker · {backend} · requests/s"),
                number(&load_summary[workers.to_string()][backend]["requests_per_second"]),
            ));
        }
    }
    let throughput = chart("Concurrent throughput (requests/s)", &data, false);
    data.clear();
    for workers in [1, 4] {
        for backend in ["shell", "rust"] {
            data.push((
                format!("{workers} worker · {backend} · MiB"),
                number(&load_summary[workers.to_string()][backend]["sampled_sum_rss_mib"]),
            ));
        }
    }
    let memory = chart("Sampled sum of process RSS (MiB)", &data, false);
    // An export is one XML document, even though the HTML shows two panels.
    let body = |svg: &str| {
        svg.split_once('>')
            .unwrap()
            .1
            .strip_suffix("</svg>")
            .unwrap()
            .to_owned()
    };
    let panel_height = 90 + data.len() * 30;
    let svg = format!(
        "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 1000 {}\" role=\"img\" aria-label=\"Concurrent throughput and sampled process RSS\"><g>{}</g><g transform=\"translate(0 {panel_height})\">{}</g></svg>",
        panel_height * 2,
        body(&throughput),
        body(&memory)
    );
    std::fs::write(parent.join("assets/rust-load.svg"), &svg)?;
    document.push_str(&format!("<section><h2>동시 부하와 프로세스 메모리</h2><p>보존된 초기 실험은 rootless Docker cgroup driver none으로 컨테이너별 제한이 적용되지 않았습니다. 현재 결과의 cgroup 격리 여부와 실제 CPU·메모리 한도는 아래 원시 환경 값으로 확인합니다. worker 1/4, 새 컨테이너에서 3회 교대 반복. 10 ms 표본 RSS 합은 드라이버·init 포함, 공유 페이지 중복·순간 peak 누락 가능성이 있습니다. 페이지 캐시·daemon·빌드는 제외합니다. cgroup peak를 컨테이너 메모리로 해석하지 않습니다.</p><div class=\"chart\">{svg}</div><pre>{}</pre></section>",escape(&serde_json::to_string_pretty(&json!({"summary":load_summary,"cgroups":loads.iter().map(|r|json!({"workers":r["workers"],"requests":r["requests"],"backend":r["backend"],"isolated":r["cgroup_isolated"],"limits":r["container_cgroup"]})).collect::<Vec<_>>()}))?)));
    document.push_str(&format!("<section><h2>정확성·실패 처리 검증</h2><p>불일치 0건. 차등 {}건, 실제 스캐너 호스트·복귀 {}건, jq 1.6 호스트·복귀 {}건, 단위 {}건, Rust 감사 로그 {}건.</p><pre>{}</pre><p>측정 코어 커밋에 대한 Linux/macOS CI 증거입니다. 이후 PR의 최신 커밋 검사는 별도로 확인합니다.</p><pre>{}</pre></section>",differential["passed"],integration["passed"],legacy["passed"],supplemental["unit_passed"],supplemental["native_audit_passed"],escape(&serde_json::to_string_pretty(&verification)?),escape(&serde_json::to_string_pretty(&ci)?)));
    document.push_str("<section><h2>Claude·Codex 원시 수치</h2><div class=\"scroll\"><table><tr><th>호스트 / 사례</th><th>지연 ms</th><th>변화</th><th>95% 기술 구간</th><th>CPU ms</th><th>개별 peak MiB</th></tr>");
    for (host, report) in [("Claude", &claude), ("Codex", &codex)] {
        for row in report["cases"].as_array().unwrap() {
            let old = number(&row["seconds"]["baseline"]["median"]);
            let new = number(&row["seconds"]["candidate"]["median"]);
            let ci = interval(row);
            document.push_str(&format!("<tr><td>{host} / {}</td><td>{:.1} → {:.1}</td><td>{:+.1}%</td><td>{:+.1} ~ {:+.1}%</td><td>{:.1} → {:.1}</td><td>{:.1} → {:.1}</td></tr>",escape(row["name"].as_str().unwrap()),old*1000.0,new*1000.0,delta(old,new),ci[0],ci[1],cpu(row,"baseline")*1000.0,cpu(row,"candidate")*1000.0,number(&row["resource_usage"]["baseline"]["max_child_peak_rss_kib"]["median"])/1024.0,number(&row["resource_usage"]["candidate"]["max_child_peak_rss_kib"]["median"])/1024.0));
        }
    }
    document.push_str("</table></div></section>");
    let clean = &followup["cases"][0];
    let clean_ci = interval(clean);
    let clean_change = delta(
        number(&clean["seconds"]["baseline"]["median"]),
        number(&clean["seconds"]["candidate"]["median"]),
    );
    document.push_str(&format!("<section><h2>기본 셸 경로의 비용과 측정 한계</h2><p>정상 입력 재측정 {}쌍: {clean_change:+.1}% (95% 기술 구간 {:+.1} ~ {:+.1}%). Rust를 호출하지 않는 정상 경로의 차이는 코어 효과가 아닙니다.</p><p>동일 반복 번호를 짝지은 bootstrap 2,000회, CPython Random(60261104)와 같은 추출. p95나 공유 머신의 장기 변동 보장이 아닙니다. 과거 Python 측정 코어 RSS에는 fork/exec 전 약 11 MiB 바닥값이 있어 메모리 절감 근거로 쓰지 않았습니다. 새 Rust smoke 수치는 이 과거 결과와 합치지 않습니다. 합성 출력, cold readiness cache, PII off 조건이며 실제 모델 응답·원격 PII·전체 저장소 스캔으로 일반화하지 않습니다.</p><details><summary>기본 셸 대조군</summary><pre>{}</pre></details><details><summary>프로세스 호출 시도 수</summary><pre>{}</pre></details></section>",followup["runs"],clean_ci[0],clean_ci[1],escape(&serde_json::to_string_pretty(&control)?),escape(&serde_json::to_string_pretty(&rows.iter().filter(|r|["small-clean","many-replacement-leaves","pre-bash-clean"].iter().any(|s|r["name"]==*s)).map(|r|json!({"name":r["name"],"process_profile":r["process_profile"]})).collect::<Vec<_>>())?)));
    document.push_str(&format!("<section><h2>빌드·도구·소스 해시</h2><pre>{}\n{}</pre><p><a href=\"../bench/results/rust-experiment/\">원시 결과</a> · <a href=\"../bench/native/README.md\">재현 방법</a></p></section><footer>독립 HTML. 외부 네트워크 요청 없음. SVG는 assets/에도 저장합니다.</footer></main><script>document.querySelectorAll('[data-metric]').forEach(b=>b.addEventListener('click',()=>{{document.querySelectorAll('[data-metric]').forEach(x=>x.setAttribute('aria-selected',x===b?'true':'false'));['latency','cpu','rss'].forEach(m=>document.getElementById('chart-'+m).hidden=m!==b.dataset.metric)}}));</script></html>",escape(&std::fs::read_to_string(results.join("image-id.txt"))?),escape(&std::fs::read_to_string(results.join("environment.txt"))?)));
    std::fs::write(html, document)?;
    write_json(results.join("assessment.json"), &summary)?;
    emit(&summary)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn historical_python_statistics() {
        let expected: Value = serde_json::from_str(include_str!(
            "../../../tests/fixtures/report-statistics.json"
        ))
        .unwrap();
        for case in expected.as_array().unwrap() {
            let text = match case["report"].as_str().unwrap() {
                "cli-claude.json" => {
                    include_str!("../../../bench/results/rust-experiment/cli-claude.json")
                }
                "cli-codex.json" => {
                    include_str!("../../../bench/results/rust-experiment/cli-codex.json")
                }
                "cli-clean-followup.json" => {
                    include_str!("../../../bench/results/rust-experiment/cli-clean-followup.json")
                }
                _ => panic!("unknown historical report"),
            };
            let report: Value = serde_json::from_str(text).unwrap();
            let row = report["cases"]
                .as_array()
                .unwrap()
                .iter()
                .find(|r| r["name"] == case["case"])
                .unwrap();
            assert_eq!(json!(interval(row)), case["interval"]);
            assert_eq!(cpu(row, "baseline"), number(&case["baseline_cpu"]));
            assert_eq!(cpu(row, "candidate"), number(&case["candidate_cpu"]));
        }
    }
    #[test]
    fn python_bootstrap_draws() {
        let mut rng = PythonRandom::new(60261104);
        // Python 3.12 random.Random(60261104).random(), exported before removal.
        let expected: Vec<f64> = serde_json::from_str(include_str!(
            "../../../tests/fixtures/python-bootstrap-draws.json"
        ))
        .unwrap();
        for expected in expected {
            assert_eq!(rng.random(), expected);
        }
        assert_eq!(median(vec![4.0, 1.0, 3.0, 2.0]), 2.5);
    }
}
