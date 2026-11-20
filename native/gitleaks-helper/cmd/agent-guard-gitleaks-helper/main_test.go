package main

import (
	"testing"

	"github.com/zricethezav/gitleaks/v8/version"

	"github.com/JeongJaeSoon/agent-guard/native/gitleaks-helper/internal/wire"
)

// The client checks version and engine before it connects, so these
// branches only run for a client of another build; they must refuse.
func TestScanRefusesMismatches(t *testing.T) {
	s := &server{configSHA: "config", engine: "engine"}
	good := wire.Request{GitleaksVersion: version.Version, Engine: "engine", ConfigSHA256: "config", LogLevel: "error", ExitCode: 1}
	cases := map[string]func(*wire.Request){
		"version":       func(r *wire.Request) { r.GitleaksVersion = "0.0.0" },
		"engine":        func(r *wire.Request) { r.Engine = "other" },
		"config":        func(r *wire.Request) { r.ConfigSHA256 = "other" },
		"report-format": func(r *wire.Request) { r.ReportFormat = "sarif" },
		"payload":       func(r *wire.Request) { r.PayloadLen = 5 },
		"log-level":     func(r *wire.Request) { r.LogLevel = "debug" },
	}
	for reason, change := range cases {
		req := good
		change(&req)
		resp, stdout, stderr, report := s.scan(req, nil)
		if resp.Status != wire.StatusFallback || resp.Reason != reason || stdout != nil || stderr != nil || report != nil {
			t.Errorf("%s: got %+v", reason, resp)
		}
	}
}
