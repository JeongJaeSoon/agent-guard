package wire

import (
	"bytes"
	"testing"
)

func TestRoundTrip(t *testing.T) {
	var buf bytes.Buffer
	req := Request{GitleaksVersion: "8.30.1", ConfigSHA256: "x", ExitCode: 1, LogLevel: "error"}
	if err := WriteRequest(&buf, req, []byte("payload")); err != nil {
		t.Fatal(err)
	}
	got, payload, err := ReadRequest(&buf)
	if err != nil || string(payload) != "payload" || got.GitleaksVersion != "8.30.1" || got.PayloadLen != 7 {
		t.Fatalf("got %+v %q %v", got, payload, err)
	}
	buf.Reset()
	if err := WriteResponse(&buf, Response{Status: StatusOK, ExitCode: 1}, []byte("o"), []byte("e"), []byte("[]")); err != nil {
		t.Fatal(err)
	}
	resp, out, errOut, report, err := ReadResponse(&buf)
	if err != nil || resp.ExitCode != 1 || string(out) != "o" || string(errOut) != "e" || string(report) != "[]" {
		t.Fatalf("got %+v %q %q %q %v", resp, out, errOut, report, err)
	}
}

// Every proper prefix of a complete answer must be an error, never an answer.
func TestTruncatedResponseIsAnError(t *testing.T) {
	var buf bytes.Buffer
	if err := WriteResponse(&buf, Response{Status: StatusOK}, nil, []byte("log"), []byte("[]\n")); err != nil {
		t.Fatal(err)
	}
	full := buf.Bytes()
	for n := 0; n < len(full); n++ {
		if _, _, _, _, err := ReadResponse(bytes.NewReader(full[:n])); err == nil {
			t.Fatalf("prefix of %d bytes was accepted", n)
		}
	}
}

func TestRejectsBadFrames(t *testing.T) {
	cases := map[string][]byte{
		"magic":   append([]byte("XXXX\x01"), 0, 0, 0, 2, '{', '}'),
		"zero":    append(Magic[:], 0, 0, 0, 0),
		"huge":    append(Magic[:], 0xff, 0xff, 0xff, 0xff),
		"status":  frame(`{"status":"clean"}`),
		"blob":    frame(`{"status":"ok","stdout_len":-1}`),
		"bigblob": frame(`{"status":"ok","report_len":99999999999}`),
	}
	for name, data := range cases {
		if _, _, _, _, err := ReadResponse(bytes.NewReader(data)); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
	if _, _, err := ReadRequest(bytes.NewReader(frame(`{"payload_len":2097152}`))); err == nil {
		t.Error("oversized payload accepted")
	}
	if err := WriteRequest(&bytes.Buffer{}, Request{}, make([]byte, MaxPayload+1)); err == nil {
		t.Error("oversized payload sent")
	}
}

func frame(header string) []byte {
	out := append([]byte{}, Magic[:]...)
	n := len(header)
	out = append(out, byte(n>>24), byte(n>>16), byte(n>>8), byte(n))
	return append(out, header...)
}
