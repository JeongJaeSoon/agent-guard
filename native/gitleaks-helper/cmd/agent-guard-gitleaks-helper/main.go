// Command agent-guard-gitleaks-helper keeps one gitleaks detector compiled in
// memory and answers `gitleaks stdin` requests from agent-guard-scan over a
// private Unix domain socket.
//
// It links the pinned gitleaks library with the regex engine of the public
// gitleaks release, so a warm answer is the answer the real gitleaks would
// give. It is only a scan engine: policy, redaction, exit-code policy and
// infrastructure-failure policy stay in the agent-guard CLI. Whenever the
// helper cannot reproduce the real gitleaks exactly it answers "fallback" and
// the client runs the real gitleaks instead.
//
// One helper serves one user, one helper binary and one config. It never
// writes scanned bytes to disk or logs, stops after an idle period, and stops
// when its resident memory passes a cap, so the next request starts a fresh
// one.
package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"runtime/debug"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/rs/zerolog"
	"github.com/spf13/viper"
	"github.com/zricethezav/gitleaks/v8/config"
	"github.com/zricethezav/gitleaks/v8/detect"
	"github.com/zricethezav/gitleaks/v8/logging"
	"github.com/zricethezav/gitleaks/v8/regexp"
	"github.com/zricethezav/gitleaks/v8/report"
	"github.com/zricethezav/gitleaks/v8/sources"
	"github.com/zricethezav/gitleaks/v8/version"

	"github.com/JeongJaeSoon/agent-guard/native/gitleaks-helper/internal/local"
	"github.com/JeongJaeSoon/agent-guard/native/gitleaks-helper/internal/wire"
)

const (
	// scanTimeout bounds one scan, like `gitleaks --timeout`. A scan that
	// does not finish in time is not an answer; the client runs the real
	// gitleaks. The client's own deadline is longer.
	scanTimeout = 2500 * time.Millisecond
	// ioTimeout bounds reading a request and writing an answer; it matches
	// the client's exchange deadline, which starts once its input is read.
	ioTimeout = 3 * time.Second
	// tick is how often an idle helper checks that it still owns its socket.
	tick = 15 * time.Second
	// largeInput is the size after which the helper returns freed memory to
	// the operating system right away instead of waiting for the next GC.
	largeInput = 256 << 10
	// maxConns bounds the connections read at once, so buffered requests
	// cannot exceed maxConns * wire.MaxPayload; further clients wait in the
	// listen backlog until their own deadline.
	maxConns = 4
)

// logEvents counts every log event the gitleaks library emits inside the
// helper. The real gitleaks would print such an event to stderr, which the
// helper cannot reproduce byte for byte, so a request during which the count
// changes is answered "fallback".
var logEvents atomic.Uint64

type countingWriter struct{}

func (countingWriter) Write(p []byte) (int, error) {
	logEvents.Add(1)
	return len(p), nil
}

type nopCloser struct{ *bytes.Buffer }

func (nopCloser) Close() error { return nil }

type server struct {
	paths       local.Paths
	cfg         config.Config
	configSHA   string
	engine      string
	idle        time.Duration
	maxRSS      uint64
	listener    *net.UnixListener
	socketIno   uint64
	lock        *os.File
	scanMu      sync.Mutex
	lastRequest atomic.Int64
	stopping    atomic.Bool
	stopOnce    sync.Once
	conns       chan struct{}
}

func main() {
	if len(os.Args) >= 2 && os.Args[1] == "version" {
		fmt.Printf("gitleaks %s; regex engine %s; protocol 1\n", version.Version, regexp.Version)
		return
	}
	if len(os.Args) < 2 || os.Args[1] != "serve" {
		fmt.Fprintln(os.Stderr, "usage: agent-guard-gitleaks-helper serve|version")
		os.Exit(2)
	}
	if err := serve(os.Args[2:]); err != nil {
		// The helper runs detached with /dev/null for stderr; the exit status
		// is for tests. Messages never include scanned content.
		fmt.Fprintln(os.Stderr, "agent-guard-gitleaks-helper:", err)
		os.Exit(1)
	}
}

func flagValues(args []string) (map[string]string, error) {
	values := map[string]string{}
	for i := 0; i < len(args); i += 2 {
		name := args[i]
		if !strings.HasPrefix(name, "--") || i+1 >= len(args) {
			return nil, errors.New("bad arguments")
		}
		if _, dup := values[name]; dup {
			return nil, errors.New("duplicate argument")
		}
		values[name] = args[i+1]
	}
	return values, nil
}

func boundedInt(text string, lo, hi int) (int, error) {
	n, err := strconv.Atoi(text)
	if err != nil || n < lo || n > hi {
		return 0, errors.New("value out of range")
	}
	return n, nil
}

// linkedVersionMatches refuses a helper whose linked gitleaks module is not
// the version the build stamped, so a mis-built helper never claims a
// version it does not run.
func linkedVersionMatches() bool {
	info, ok := debug.ReadBuildInfo()
	if !ok {
		return false
	}
	for _, dep := range info.Deps {
		if dep.Path == "github.com/zricethezav/gitleaks/v8" {
			return dep.Replace == nil && dep.Version == "v"+version.Version
		}
	}
	return false
}

func serve(args []string) error {
	values, err := flagValues(args)
	if err != nil {
		return err
	}
	stateDir, key, configPath, configSHA := values["--state-dir"], values["--key"], values["--config"], values["--config-sha256"]
	idleSeconds, err := boundedInt(values["--idle-seconds"], 1, 86400)
	if err != nil {
		return err
	}
	maxRSSMiB, err := boundedInt(values["--max-rss-mib"], 96, 4096)
	if err != nil {
		return err
	}
	if len(values) != 6 || !local.ValidKey(key) || !filepath.IsAbs(configPath) || len(configSHA) != 64 {
		return errors.New("bad arguments")
	}
	if !linkedVersionMatches() {
		return errors.New("linked gitleaks version does not match the build")
	}
	info, _ := debug.ReadBuildInfo()
	engine := local.Engine(info)
	uid := os.Geteuid()
	dir, err := local.HelperDir(stateDir, uid, false)
	if err != nil {
		return err
	}
	self, err := os.Executable()
	if err != nil {
		return err
	}
	identity, err := local.Identity(self)
	if err != nil {
		return err
	}
	// The key names this binary and config; a mismatched spawn is refused.
	if local.Key(uid, identity, configSHA) != key {
		return errors.New("key does not match this helper and config")
	}
	s := &server{
		paths:     local.PathsFor(dir, key),
		configSHA: configSHA,
		engine:    engine,
		idle:      time.Duration(idleSeconds) * time.Second,
		maxRSS:    uint64(maxRSSMiB) << 20,
		conns:     make(chan struct{}, maxConns),
	}
	if s.lock, err = acquireLock(s.paths.Lock); err != nil {
		// Another helper holds this key; it serves the requests.
		return nil
	}
	// The soft limit makes the collector work harder long before the hard cap.
	debug.SetMemoryLimit(int64(s.maxRSS / 2))
	logging.Logger = zerolog.New(countingWriter{}).Level(zerolog.InfoLevel)

	if err := s.loadConfig(configPath); err != nil {
		if errors.Is(err, errUnsupportedConfig) {
			markUnsupported(s.paths.Unsupported)
		}
		s.release()
		return err
	}
	cleanStale(dir, key)
	if err := s.listen(); err != nil {
		s.release()
		return err
	}
	s.lastRequest.Store(time.Now().UnixNano())
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGTERM, syscall.SIGINT, syscall.SIGHUP)
	go func() {
		<-signals
		s.stop()
	}()
	s.acceptLoop()
	s.stop()
	return nil
}

var errUnsupportedConfig = errors.New("config is not served by the helper")

// loadConfig parses the config exactly as `gitleaks --config PATH` does, and
// only accepts it when the bytes it parsed are the bytes the client hashed.
func (s *server) loadConfig(path string) error {
	before, err := local.FileSHA256(path)
	if err != nil || before != s.configSHA {
		return errors.New("config changed before load")
	}
	events := logEvents.Load()
	v := viper.New()
	v.SetConfigType("toml")
	v.SetConfigFile(path)
	if err := v.ReadInConfig(); err != nil {
		return errUnsupportedConfig
	}
	var vc config.ViperConfig
	if err := v.Unmarshal(&vc); err != nil {
		return errUnsupportedConfig
	}
	// An extended file is read from disk; the key would not cover it.
	if vc.Extend.Path != "" {
		return errUnsupportedConfig
	}
	cfg, err := vc.Translate()
	if err != nil {
		return errUnsupportedConfig
	}
	// gitleaks prints config warnings on every run; the helper cannot.
	if logEvents.Load() != events {
		return errUnsupportedConfig
	}
	after, err := local.FileSHA256(path)
	if err != nil || after != s.configSHA {
		return errors.New("config changed during load")
	}
	s.cfg = cfg
	return nil
}

func markUnsupported(path string) {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|syscall.O_NOFOLLOW, 0o600)
	if err == nil {
		_ = f.Close()
	}
}

// acquireLock takes the exclusive lock of one key. The lock file can be
// unlinked by its holder, so after locking, the descriptor must still be the
// file at the path; otherwise another process may hold the path's lock.
func acquireLock(path string) (*os.File, error) {
	f, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE|syscall.O_NOFOLLOW, 0o600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		_ = f.Close()
		return nil, err
	}
	held, err1 := f.Stat()
	named, err2 := os.Lstat(path)
	if err1 != nil || err2 != nil || !os.SameFile(held, named) {
		_ = f.Close()
		return nil, errors.New("lock file replaced")
	}
	return f, nil
}

// cleanStale removes the files of other keys whose helper is gone: a live
// helper always holds its key's lock, so if this process can take it, nothing
// serves that key. The listing is bounded so a crowded directory cannot stall
// startup.
func cleanStale(dir, own string) {
	d, err := os.Open(dir)
	if err != nil {
		return
	}
	names, _ := d.Readdirnames(256)
	_ = d.Close()
	seen := map[string]bool{}
	for _, name := range names {
		key, _, ok := strings.Cut(name, ".")
		if !ok || key == own || seen[key] || !local.ValidKey(key) {
			continue
		}
		seen[key] = true
		paths := local.PathsFor(dir, key)
		// A fresh spawn marker means a helper for that key may be starting;
		// taking its lock now would make that helper give up.
		if info, err := os.Lstat(paths.Spawn); err == nil && time.Since(info.ModTime()) < time.Minute {
			continue
		}
		lock, err := acquireLock(paths.Lock)
		if err != nil {
			continue
		}
		// An .unsupported marker is kept: it names a config that is never
		// served, and removing it would start a helper for it again.
		_ = os.Remove(paths.Socket)
		_ = os.Remove(paths.Spawn)
		_ = os.Remove(paths.Lock)
		_ = lock.Close()
	}
}

func (s *server) listen() error {
	// The lock is held, so a socket file here is a dead helper's.
	if err := os.Remove(s.paths.Socket); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	old := syscall.Umask(0o177)
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: s.paths.Socket, Net: "unix"})
	syscall.Umask(old)
	if err != nil {
		return err
	}
	listener.SetUnlinkOnClose(false)
	info, err := os.Lstat(s.paths.Socket)
	if err != nil || info.Mode()&os.ModeSocket == 0 || info.Mode().Perm() != 0o600 {
		_ = listener.Close()
		return errors.New("socket is not private")
	}
	s.socketIno = info.Sys().(*syscall.Stat_t).Ino
	s.listener = listener
	return nil
}

// ownsSocket reports whether the socket path is still the one this helper
// bound; a helper whose socket was removed or replaced has no clients.
func (s *server) ownsSocket() bool {
	info, err := os.Lstat(s.paths.Socket)
	if err != nil {
		return false
	}
	st, ok := info.Sys().(*syscall.Stat_t)
	return ok && st.Ino == s.socketIno
}

func (s *server) acceptLoop() {
	for !s.stopping.Load() {
		_ = s.listener.SetDeadline(time.Now().Add(min(tick, s.idle)))
		conn, err := s.listener.AcceptUnix()
		if err != nil {
			var netErr net.Error
			if errors.As(err, &netErr) && netErr.Timeout() {
				idleFor := time.Since(time.Unix(0, s.lastRequest.Load()))
				if idleFor >= s.idle || !s.ownsSocket() {
					return
				}
				continue
			}
			if s.stopping.Load() {
				return
			}
			continue
		}
		s.conns <- struct{}{}
		go func() {
			defer func() { <-s.conns }()
			s.handle(conn)
		}()
	}
}

func (s *server) stop() {
	s.stopOnce.Do(func() {
		s.stopping.Store(true)
		if s.listener != nil {
			_ = s.listener.Close()
		}
		// Hold the scan lock so an answer in flight completes first.
		s.scanMu.Lock()
		if s.listener != nil && s.ownsSocket() {
			_ = os.Remove(s.paths.Socket)
		}
		_ = os.Remove(s.paths.Spawn)
		s.release()
		os.Exit(0)
	})
}

// release removes the lock file while it is still held (acquireLock detects
// the race) and then drops the lock.
func (s *server) release() {
	if s.lock != nil {
		_ = os.Remove(s.paths.Lock)
		_ = s.lock.Close()
		s.lock = nil
	}
}

func (s *server) handle(conn *net.UnixConn) {
	defer conn.Close()
	if err := local.SameUser(conn); err != nil {
		return
	}
	_ = conn.SetDeadline(time.Now().Add(ioTimeout))
	req, payload, err := wire.ReadRequest(conn)
	if err != nil {
		return
	}
	s.scanMu.Lock()
	if s.stopping.Load() {
		s.scanMu.Unlock()
		return
	}
	resp, stdout, stderr, reportBytes := s.scan(req, payload)
	// Only an answer keeps the helper alive; a client the helper keeps
	// refusing must not hold it resident.
	// The request buffer is the helper's own copy of the scanned bytes;
	// overwrite it now. Copies inside gitleaks are strings the collector
	// frees but cannot overwrite (see docs/gitleaks-helper.md).
	clear(payload)
	if resp.Status == wire.StatusOK {
		s.lastRequest.Store(time.Now().UnixNano())
	}
	if len(payload) > largeInput {
		debug.FreeOSMemory()
	}
	overCap := peakRSS() > s.maxRSS
	s.scanMu.Unlock()
	_ = conn.SetDeadline(time.Now().Add(ioTimeout))
	_ = wire.WriteResponse(conn, resp, stdout, stderr, reportBytes)
	// The report of an unredacted scan holds the secrets it found.
	clear(reportBytes)
	if overCap {
		go s.stop()
	}
}

func fallback(reason string) (wire.Response, []byte, []byte, []byte) {
	return wire.Response{Status: wire.StatusFallback, Reason: reason}, nil, nil, nil
}

// scan reproduces `gitleaks stdin` (cmd/stdin.go and cmd/root.go of the
// pinned version) for the options the client forwards.
func (s *server) scan(req wire.Request, payload []byte) (wire.Response, []byte, []byte, []byte) {
	switch {
	case req.GitleaksVersion != version.Version:
		return fallback("version")
	case req.Engine != s.engine:
		return fallback("engine")
	case req.ConfigSHA256 != s.configSHA:
		return fallback("config")
	case req.ReportFormat != "" && req.ReportFormat != "json":
		return fallback("report-format")
	case int64(len(payload)) != req.PayloadLen:
		return fallback("payload")
	}
	level, ok := logLevel(req.LogLevel)
	if !ok {
		return fallback("log-level")
	}
	start := time.Now()
	ctx, cancel := context.WithTimeout(context.Background(), scanTimeout)
	defer cancel()

	cfg := s.cfg
	cfg.Path = req.ConfigPath
	detector := detect.NewDetectorContext(ctx, cfg)
	detector.MaxDecodeDepth = 5
	detector.MaxArchiveDepth = 0
	detector.NoColor = req.NoColor
	detector.Config.Path = req.ConfigPath
	detector.Redact = req.Redact

	events := logEvents.Load()
	findings, err := detector.DetectSource(ctx, &sources.File{
		Content:         bytes.NewReader(payload),
		MaxArchiveDepth: detector.MaxArchiveDepth,
	})
	if err != nil || ctx.Err() != nil {
		return fallback("scan")
	}
	if logEvents.Load() != events {
		return fallback("log")
	}

	var stderr bytes.Buffer
	if level <= zerolog.WarnLevel {
		zone := time.FixedZone(req.TimeZone, req.TimeOffset)
		summary(&stderr, req.NoColor, zone, level, detector.TotalBytes.Load(), len(findings), time.Since(start))
	}
	var reportBytes []byte
	if req.ReportFormat == "json" {
		var out bytes.Buffer
		if err := (&report.JsonReporter{}).Write(nopCloser{&out}, findings); err != nil {
			return fallback("report")
		}
		reportBytes = out.Bytes()
		// The client refuses larger blobs; let the real gitleaks answer.
		if len(reportBytes) > wire.MaxBlob {
			clear(reportBytes)
			return fallback("report-size")
		}
	}
	exit := 0
	if len(findings) != 0 {
		exit = req.ExitCode
	}
	return wire.Response{Status: wire.StatusOK, ExitCode: exit}, nil, stderr.Bytes(), reportBytes
}

func logLevel(name string) (zerolog.Level, bool) {
	switch strings.ToLower(name) {
	case "info":
		return zerolog.InfoLevel, true
	case "warn":
		return zerolog.WarnLevel, true
	case "err", "error":
		return zerolog.ErrorLevel, true
	}
	return zerolog.NoLevel, false
}

// summary writes the lines findingSummaryAndExit logs, through the same
// console writer gitleaks configures. Timestamps and the duration differ
// between any two real runs too.
func summary(w io.Writer, noColor bool, zone *time.Location, level zerolog.Level, totalBytes uint64, count int, elapsed time.Duration) {
	logger := zerolog.New(zerolog.ConsoleWriter{Out: w, NoColor: noColor, TimeLocation: zone}).Level(level).With().Timestamp().Logger()
	logger.Info().Msgf("scanned ~%d bytes (%s) in %s", totalBytes, bytesConvert(totalBytes), formatDuration(elapsed))
	if count != 0 {
		logger.Warn().Msgf("leaks found: %d", count)
	} else {
		logger.Info().Msg("no leaks found")
	}
}

// bytesConvert and formatDuration are copied from gitleaks v8.30.1
// cmd/root.go (MIT License) so the summary reads the same.
func bytesConvert(bytes uint64) string {
	const (
		kilobyte = 1000.0
		megabyte = kilobyte * 1000
		gigabyte = megabyte * 1000
	)
	unit := ""
	value := float32(bytes)
	switch {
	case bytes >= gigabyte:
		unit = "GB"
		value = value / gigabyte
	case bytes >= megabyte:
		unit = "MB"
		value = value / megabyte
	case bytes >= kilobyte:
		unit = "KB"
		value = value / kilobyte
	case bytes >= 1:
		unit = "bytes"
	case bytes == 0:
		return "0"
	}
	stringValue := strings.TrimSuffix(fmt.Sprintf("%.2f", value), ".00")
	return fmt.Sprintf("%s %s", stringValue, unit)
}

func formatDuration(d time.Duration) string {
	scale := 100 * time.Second
	for scale > d {
		scale = scale / 10
	}
	return d.Round(scale / 100).String()
}

// peakRSS is the process's peak resident set size in bytes. The cap is
// checked against the peak, the same way on Linux and macOS, so a request
// that briefly needed more memory than the cap ends this helper even after
// the memory was returned.
func peakRSS() uint64 {
	var usage syscall.Rusage
	if syscall.Getrusage(syscall.RUSAGE_SELF, &usage) != nil {
		return ^uint64(0)
	}
	if runtime.GOOS == "darwin" {
		return uint64(usage.Maxrss)
	}
	return uint64(usage.Maxrss) << 10
}
