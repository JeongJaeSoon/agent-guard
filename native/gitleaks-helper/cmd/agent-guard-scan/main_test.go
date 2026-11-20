package main

import (
	"strings"
	"testing"
)

func TestParseScanArgs(t *testing.T) {
	accepted := []string{
		"stdin --redact --no-banner --no-color --log-level error --config C --exit-code 1",
		"stdin --report-format json --report-path /p --no-banner --config C",
		"stdin --no-banner --config=C --redact=50 --log-level=warn",
	}
	for _, line := range accepted {
		if _, ok := parseScanArgs(strings.Fields(line)); !ok {
			t.Errorf("rejected %q", line)
		}
	}
	rejected := []string{
		"",
		"dir . --no-banner --config C",
		"stdin --redact --no-color --log-level error --config C", // banner
		"stdin --no-banner",                                                  // no config
		"stdin --no-banner --config C --config D",                            // duplicate
		"stdin --no-banner --config C --log-level debug",                     // debug logs
		"stdin --no-banner --config C --report-format sarif --report-path p", // format
		"stdin --no-banner --config C --report-path p",                       // inferred format
		"stdin --no-banner --config C --report-format json --report-path -",  // stdout report
		"stdin --no-banner --config C --report-format json",                  // no path
		"stdin --no-banner --config C --baseline-path b",                     // unknown flag
		"stdin --no-banner --config C --max-decode-depth 0",
		"stdin --no-banner --config C --exit-code x",
		"stdin --no-banner --config C --exit-code",
		"stdin --no-banner=false --config C",
		"stdin --no-banner --config C --exit-code 010",
		"stdin --no-banner --config C --exit-code +1",
		"stdin --no-banner --config C --exit-code -1",
		"stdin --no-banner --config C --redact=010",
		"stdin --no-banner --config C extra",
	}
	for _, line := range rejected {
		if _, ok := parseScanArgs(strings.Fields(line)); ok {
			t.Errorf("accepted %q", line)
		}
	}
	a, _ := parseScanArgs(strings.Fields("stdin --redact --no-banner --no-color --log-level error --config C --exit-code 7"))
	if a.redact != 100 || !a.noColor || a.exitCode != 7 || a.config != "C" || a.logLevel != "error" {
		t.Errorf("parsed %+v", a)
	}
}

func TestParseOptions(t *testing.T) {
	if _, err := parseOptions([]string{"--gitleaks", "rel", "--"}); err == nil {
		t.Error("relative gitleaks accepted")
	}
	if _, err := parseOptions([]string{"--gitleaks", "/g", "--bogus", "x", "--"}); err == nil {
		t.Error("unknown option accepted")
	}
	o, err := parseOptions([]string{"--gitleaks", "/g", "--gitleaks-version", "8.30.1", "--state-dir", "/s", "--", "stdin", "--x"})
	if err != nil || o.gitleaks != "/g" || len(o.args) != 2 {
		t.Errorf("parsed %+v %v", o, err)
	}
}
