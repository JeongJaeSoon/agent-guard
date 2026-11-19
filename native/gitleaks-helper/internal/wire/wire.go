// Package wire is the framing shared by the scan client and the warm gitleaks
// helper. It uses only the standard library so the client stays small and
// starts in about a millisecond.
//
// A frame is the 5-byte magic, a 4-byte big-endian header length, a JSON
// header, and then the raw byte blobs the header announces. Every length is
// bounded before anything is allocated, and a frame that ends early is an
// error: a truncated answer can never be read as a clean scan.
package wire

import (
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
)

// Magic identifies protocol version 1. A helper and client built from
// different protocol revisions refuse each other's frames.
var Magic = [5]byte{'A', 'G', 'G', 'L', 1}

const (
	// MaxHeader bounds the JSON header of either direction.
	MaxHeader = 64 << 10
	// MaxPayload bounds the bytes a client may ask the helper to scan. Larger
	// inputs go to the real gitleaks, which has no such limit.
	MaxPayload = 1 << 20
	// MaxBlob bounds each blob of an answer (stdout, stderr, report).
	MaxBlob = 16 << 20
)

// Request asks the helper to run the equivalent of
// `gitleaks stdin` over Payload with these options.
type Request struct {
	GitleaksVersion string `json:"gitleaks_version"`
	// Engine is local.Engine of the real gitleaks binary: its build tags
	// and regex-engine module versions.
	Engine       string `json:"engine"`
	ConfigSHA256 string `json:"config_sha256"`
	ConfigPath   string `json:"config_path"`
	ExitCode     int    `json:"exit_code"`
	Redact       uint   `json:"redact"`
	NoColor      bool   `json:"no_color"`
	LogLevel     string `json:"log_level"`
	// TimeZone and TimeOffset are the client's local zone, so the summary
	// lines carry the clock time the real gitleaks would print.
	TimeZone   string `json:"time_zone"`
	TimeOffset int    `json:"time_offset"`
	// ReportFormat is "" (no report) or "json".
	ReportFormat string `json:"report_format"`
	PayloadLen   int64  `json:"payload_len"`
}

// Response statuses. Anything but StatusOK makes the client run the real
// gitleaks; the helper never answers "clean" for a scan it did not finish.
const (
	StatusOK       = "ok"
	StatusFallback = "fallback"
)

// Response is the helper's answer. ExitCode, Stdout, Stderr and Report are
// what the real gitleaks would have produced for the same request.
type Response struct {
	Status    string `json:"status"`
	Reason    string `json:"reason,omitempty"`
	ExitCode  int    `json:"exit_code"`
	StdoutLen int64  `json:"stdout_len"`
	StderrLen int64  `json:"stderr_len"`
	ReportLen int64  `json:"report_len"`
}

func writeHeader(w io.Writer, v any) error {
	header, err := json.Marshal(v)
	if err != nil {
		return err
	}
	if len(header) > MaxHeader {
		return errors.New("header too large")
	}
	var prefix [9]byte
	copy(prefix[:5], Magic[:])
	binary.BigEndian.PutUint32(prefix[5:], uint32(len(header)))
	if _, err := w.Write(prefix[:]); err != nil {
		return err
	}
	_, err = w.Write(header)
	return err
}

func readHeader(r io.Reader, v any) error {
	var prefix [9]byte
	if _, err := io.ReadFull(r, prefix[:]); err != nil {
		return err
	}
	if [5]byte(prefix[:5]) != Magic {
		return errors.New("bad magic")
	}
	n := binary.BigEndian.Uint32(prefix[5:])
	if n == 0 || n > MaxHeader {
		return errors.New("bad header length")
	}
	header := make([]byte, n)
	if _, err := io.ReadFull(r, header); err != nil {
		return err
	}
	return json.Unmarshal(header, v)
}

// WriteRequest sends a request header followed by exactly len(payload) bytes.
func WriteRequest(w io.Writer, req Request, payload []byte) error {
	req.PayloadLen = int64(len(payload))
	if req.PayloadLen > MaxPayload {
		return errors.New("payload too large")
	}
	if err := writeHeader(w, req); err != nil {
		return err
	}
	_, err := w.Write(payload)
	return err
}

// ReadRequest reads one request and its complete payload.
func ReadRequest(r io.Reader) (Request, []byte, error) {
	var req Request
	if err := readHeader(r, &req); err != nil {
		return req, nil, err
	}
	if req.PayloadLen < 0 || req.PayloadLen > MaxPayload {
		return req, nil, errors.New("bad payload length")
	}
	payload := make([]byte, req.PayloadLen)
	if _, err := io.ReadFull(r, payload); err != nil {
		return req, nil, err
	}
	return req, payload, nil
}

// WriteResponse sends an answer and its blobs.
func WriteResponse(w io.Writer, resp Response, stdout, stderr, report []byte) error {
	resp.StdoutLen = int64(len(stdout))
	resp.StderrLen = int64(len(stderr))
	resp.ReportLen = int64(len(report))
	if err := writeHeader(w, resp); err != nil {
		return err
	}
	for _, blob := range [][]byte{stdout, stderr, report} {
		if _, err := w.Write(blob); err != nil {
			return err
		}
	}
	return nil
}

// ReadResponse reads one complete answer. A short read, an oversized blob or
// an unknown status is an error.
func ReadResponse(r io.Reader) (Response, []byte, []byte, []byte, error) {
	var resp Response
	if err := readHeader(r, &resp); err != nil {
		return resp, nil, nil, nil, err
	}
	switch resp.Status {
	case StatusOK, StatusFallback:
	default:
		return resp, nil, nil, nil, fmt.Errorf("unknown status")
	}
	blobs := make([][]byte, 3)
	for i, n := range []int64{resp.StdoutLen, resp.StderrLen, resp.ReportLen} {
		if n < 0 || n > MaxBlob {
			return resp, nil, nil, nil, errors.New("bad blob length")
		}
		blobs[i] = make([]byte, n)
		if _, err := io.ReadFull(r, blobs[i]); err != nil {
			return resp, nil, nil, nil, err
		}
	}
	return resp, blobs[0], blobs[1], blobs[2], nil
}
