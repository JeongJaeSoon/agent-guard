// Command agent-guard-scan stands in for one gitleaks invocation of the
// agent-guard CLI:
//
//	agent-guard-scan --gitleaks BIN --gitleaks-version V --state-dir DIR -- ARGS...
//
// When ARGS is one of the `gitleaks stdin` shapes the CLI uses and a warm
// helper for the same user, helper binary, gitleaks version and config bytes
// answers completely, it reproduces that answer: exit code, stdout, stderr
// and report file. In every other case it runs BIN with ARGS and the same
// standard input, so the CLI sees the real gitleaks. It never exits 0 unless
// the helper finished the scan clean or the real gitleaks did.
//
// The client uses only the Go standard library and golang.org/x/sys, so it
// starts in about a millisecond; the helper pays gitleaks's start-up once.
package main

import (
	"bytes"
	"debug/buildinfo"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"syscall"
	"time"

	"golang.org/x/sys/unix"

	"github.com/JeongJaeSoon/agent-guard/native/gitleaks-helper/internal/local"
	"github.com/JeongJaeSoon/agent-guard/native/gitleaks-helper/internal/wire"
)

const (
	helperName = "agent-guard-gitleaks-helper"
	// pipeLimit is the largest piped input sent to the helper. The real
	// gitleaks splits stdin into chunks at each read() of a pipe, so beyond
	// one pipe buffer (64 KiB on Linux and macOS) its chunking depends on the
	// writer's timing; the helper only answers inputs a single read would see
	// whole. A regular file is read in fixed 100 KB chunks either way.
	pipeLimit = 64 << 10
	// exchangeTimeout bounds one request; the helper's own scan timeout is
	// shorter. Past it the client runs the real gitleaks.
	exchangeTimeout = 3 * time.Second
	// spawnBackoff keeps a failing environment (a sandbox without Unix
	// sockets) from starting a helper on every scan.
	spawnBackoff = 60 * time.Second
	defaultIdle  = 600
	defaultRSS   = 160
)

type options struct {
	gitleaks, version, stateDir string
	args                        []string
}

// scanArgs is a parsed `gitleaks stdin` invocation the helper can answer.
type scanArgs struct {
	config, logLevel, reportFormat, reportPath string
	exitCode                                   int
	redact                                     uint
	noColor                                    bool
}

func main() {
	opts, err := parseOptions(os.Args[1:])
	if err != nil {
		fmt.Fprintln(os.Stderr, "agent-guard-scan: usage: agent-guard-scan --gitleaks BIN --gitleaks-version V --state-dir DIR -- ARGS...")
		os.Exit(2)
	}
	os.Exit(run(opts))
}

func parseOptions(argv []string) (options, error) {
	var o options
	for i := 0; i < len(argv); i++ {
		if argv[i] == "--" {
			o.args = argv[i+1:]
			if o.gitleaks == "" || !filepath.IsAbs(o.gitleaks) {
				return o, errors.New("gitleaks path")
			}
			return o, nil
		}
		if i+1 >= len(argv) {
			return o, errors.New("missing value")
		}
		switch argv[i] {
		case "--gitleaks":
			o.gitleaks = argv[i+1]
		case "--gitleaks-version":
			o.version = argv[i+1]
		case "--state-dir":
			o.stateDir = argv[i+1]
		default:
			return o, errors.New("unknown option")
		}
		i++
	}
	return o, errors.New("missing --")
}

// parseScanArgs accepts the two shapes the CLI sends and nothing else:
//
//	stdin --redact --no-banner --no-color --log-level error --config C --exit-code 1
//	stdin --report-format json --report-path P --no-banner --config C
func parseScanArgs(args []string) (scanArgs, bool) {
	a := scanArgs{logLevel: "info", exitCode: 1}
	if len(args) == 0 || args[0] != "stdin" {
		return a, false
	}
	seen := map[string]bool{}
	noBanner := false
	for i := 1; i < len(args); i++ {
		name, value, hasValue := strings.Cut(args[i], "=")
		if seen[name] {
			return a, false
		}
		seen[name] = true
		takesValue := name == "--log-level" || name == "--config" || name == "--exit-code" ||
			name == "--report-format" || name == "--report-path"
		if takesValue && !hasValue {
			if i+1 >= len(args) {
				return a, false
			}
			i++
			value = args[i]
		}
		switch name {
		case "--redact":
			a.redact = 100
			if hasValue {
				if !plainNumber(value) {
					return a, false
				}
				n, err := strconv.ParseUint(value, 10, 32)
				if err != nil {
					return a, false
				}
				a.redact = uint(n)
			}
		case "--no-banner", "--no-color":
			if hasValue {
				return a, false
			}
			if name == "--no-banner" {
				noBanner = true
			} else {
				a.noColor = true
			}
		case "--log-level":
			a.logLevel = value
		case "--config":
			a.config = value
		case "--exit-code":
			if !plainNumber(value) {
				return a, false
			}
			n, err := strconv.Atoi(value)
			if err != nil {
				return a, false
			}
			a.exitCode = n
		case "--report-format":
			a.reportFormat = value
		case "--report-path":
			a.reportPath = value
		default:
			return a, false
		}
	}
	switch strings.ToLower(a.logLevel) {
	case "info", "warn", "err", "error":
	default:
		return a, false
	}
	if !noBanner || a.config == "" {
		return a, false
	}
	// A report needs both flags, as JSON, to a file (not "-" for stdout).
	if (a.reportFormat == "") != (a.reportPath == "") {
		return a, false
	}
	if a.reportPath != "" && (a.reportFormat != "json" || a.reportPath == "-") {
		return a, false
	}
	return a, true
}

// plainNumber accepts decimal digits without a sign or a leading zero. The
// real gitleaks parses numeric flags in base 0 (010 is 8), so any other
// spelling goes to it.
func plainNumber(v string) bool {
	if v == "" || len(v) > 9 || (len(v) > 1 && v[0] == '0') {
		return false
	}
	for _, r := range v {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}

type client struct {
	opts  options
	scan  scanArgs
	trace string
	// input state, once standard input has been read
	read    bool
	regular bool
	offset  int64
	data    []byte
}

func run(opts options) int {
	c := &client{opts: opts}
	if t := os.Getenv("AGENT_GUARD_GITLEAKS_HELPER_TRACE"); filepath.IsAbs(t) {
		c.trace = t
	}
	scan, ok := parseScanArgs(opts.args)
	if !ok {
		return c.real("arguments")
	}
	c.scan = scan
	// gitleaks stdin loads ./.gitleaksignore; its fingerprints are not part
	// of the helper's key. Any entry there, even a broken one, goes real.
	if _, err := os.Lstat(".gitleaksignore"); !errors.Is(err, os.ErrNotExist) {
		return c.real("gitleaksignore")
	}
	if opts.version == "" || opts.stateDir == "" {
		return c.real("disabled")
	}
	uid := os.Geteuid()
	dir, err := local.HelperDir(opts.stateDir, uid, true)
	if err != nil {
		return c.real("state-dir")
	}
	self, err := os.Executable()
	if err != nil {
		return c.real("helper-missing")
	}
	helper := filepath.Join(filepath.Dir(self), helperName)
	identity, err := local.Identity(helper)
	if err != nil {
		return c.real("helper-missing")
	}
	configSHA, err := local.FileSHA256(scan.config)
	if err != nil {
		return c.real("config")
	}
	// The same version string can come from a build with Go's regexp
	// instead of the release's go-re2; the helper checks the engine too.
	engine, err := local.FileEngine(opts.gitleaks)
	if err != nil {
		return c.real("engine")
	}
	// The helper refuses another gitleaks version or engine anyway; check it
	// here first so such a setup neither starts nor keeps a helper running.
	helperInfo, err := buildinfo.ReadFile(helper)
	if err != nil {
		return c.real("helper-missing")
	}
	if local.LinkedVersion(helperInfo, "github.com/zricethezav/gitleaks/v8") != opts.version {
		return c.real("version")
	}
	if local.Engine(helperInfo) != engine {
		return c.real("engine")
	}
	key := local.Key(uid, identity, configSHA)
	paths := local.PathsFor(dir, key)
	if len(paths.Socket) > local.MaxSocketPath {
		return c.real("socket-path")
	}
	if _, err := os.Lstat(paths.Unsupported); err == nil {
		return c.real("unsupported-config")
	}
	conn, err := net.DialTimeout("unix", paths.Socket, time.Second)
	if err != nil {
		if errors.Is(err, syscall.ENOENT) || errors.Is(err, syscall.ECONNREFUSED) {
			c.spawn(helper, opts.stateDir, key, scan.config, configSHA, paths.Spawn)
			return c.real("cold")
		}
		return c.real("connect")
	}
	uconn := conn.(*net.UnixConn)
	defer uconn.Close()
	if err := local.SameUser(uconn); err != nil {
		return c.real("peer")
	}
	// gitleaks checks the report path is writable before it scans; open it
	// read-write as its os.Create does, so a write-only file is refused alike
	// (a FIFO opens but cannot be truncated, which also falls back). Open it
	// once and keep the handle: the CLI's report file is a private mktemp
	// file (it can live in a shared TMPDIR), so it is never removed or
	// recreated here. Writing through the same handle keeps its mode and
	// leaves no moment where another user could claim the name.
	var report *os.File
	if scan.reportPath != "" {
		f, err := os.OpenFile(scan.reportPath, os.O_RDWR|os.O_CREATE, 0o666)
		if err != nil {
			return c.real("report-path")
		}
		report = f
		defer report.Close()
	}
	if reason := c.readInput(); reason != "" {
		return c.real(reason)
	}
	_ = uconn.SetDeadline(time.Now().Add(exchangeTimeout))
	zone, offset := time.Now().Zone()
	req := wire.Request{
		GitleaksVersion: opts.version,
		Engine:          engine,
		ConfigSHA256:    configSHA,
		ConfigPath:      scan.config,
		ExitCode:        scan.exitCode,
		Redact:          scan.redact,
		// gitleaks's console writer also drops colour when NO_COLOR is set.
		NoColor:      scan.noColor || os.Getenv("NO_COLOR") != "",
		TimeZone:     zone,
		TimeOffset:   offset,
		LogLevel:     scan.logLevel,
		ReportFormat: scan.reportFormat,
	}
	if err := wire.WriteRequest(uconn, req, c.data); err != nil {
		return c.real("send")
	}
	resp, stdout, stderr, reportBytes, err := wire.ReadResponse(uconn)
	if err != nil {
		return c.real("answer")
	}
	if resp.Status != wire.StatusOK {
		return c.real("helper-" + safeReason(resp.Reason))
	}
	if resp.ExitCode != 0 && resp.ExitCode != scan.exitCode {
		return c.real("answer")
	}
	if report != nil {
		if len(reportBytes) == 0 || !writeReport(report, reportBytes) {
			// The real gitleaks truncates and rewrites the same path.
			return c.real("report-write")
		}
	}
	if _, err := os.Stdout.Write(stdout); err != nil {
		return 2
	}
	if _, err := os.Stderr.Write(stderr); err != nil {
		return 2
	}
	c.note("helper")
	return resp.ExitCode
}

// readInput reads standard input for the helper, or says why it must not.
func (c *client) readInput() string {
	info, err := os.Stdin.Stat()
	if err != nil {
		return "stdin"
	}
	c.regular = info.Mode().IsRegular()
	if c.regular {
		if c.offset, err = os.Stdin.Seek(0, io.SeekCurrent); err != nil {
			c.regular = false
		} else if info.Size()-c.offset > wire.MaxPayload {
			return "large"
		}
	}
	limit := int64(pipeLimit)
	if c.regular {
		limit = wire.MaxPayload
	} else if waiting, err := local.PipeWaiting(int(os.Stdin.Fd())); err == nil && int64(waiting) >= limit {
		// A pipe that already holds as much as the helper can take is a
		// large input: hand it to the real gitleaks before reading a byte,
		// so it is not copied once more through a replay.
		return "large"
	}
	c.read = true
	if c.regular {
		c.data, err = io.ReadAll(io.LimitReader(os.Stdin, limit+1))
		if err != nil {
			return "stdin"
		}
		if int64(len(c.data)) > limit {
			return "large"
		}
		return ""
	}
	// The real gitleaks makes one chunk of each read() of a pipe. Answer
	// only input that one read returned whole, so the helper's single chunk
	// is the chunk the real gitleaks would have read; anything that arrives
	// in pieces is replayed to the real gitleaks.
	buf := make([]byte, limit+1)
	n, err := os.Stdin.Read(buf)
	c.data = buf[:n]
	if err != nil && err != io.EOF {
		return "stdin"
	}
	if int64(n) > limit {
		return "large"
	}
	if err == io.EOF || n == 0 {
		return ""
	}
	var probe [1]byte
	more, err := os.Stdin.Read(probe[:])
	if more > 0 {
		c.data = append(c.data, probe[:more]...)
		return "pipe-chunks"
	}
	if err != io.EOF {
		return "stdin"
	}
	return ""
}

// writeReport replaces the report file's content through the handle opened
// before the scan, as gitleaks's own truncate-and-write does.
func writeReport(f *os.File, data []byte) bool {
	if err := f.Truncate(0); err != nil {
		return false
	}
	_, err := f.WriteAt(data, 0)
	return err == nil
}

func safeReason(reason string) string {
	for _, r := range reason {
		if (r < 'a' || r > 'z') && r != '-' {
			return "other"
		}
	}
	if reason == "" || len(reason) > 32 {
		return "other"
	}
	return reason
}

// note appends one fixed word to the test trace file. Never input or paths.
func (c *client) note(word string) {
	if c.trace == "" {
		return
	}
	f, err := os.OpenFile(c.trace, os.O_WRONLY|os.O_APPEND|os.O_CREATE|syscall.O_NOFOLLOW, 0o600)
	if err != nil {
		return
	}
	_, _ = f.WriteString(word + "\n")
	_ = f.Close()
}

// real runs the real gitleaks with the original arguments and standard
// input. Before anything was read it replaces this process; afterwards a
// regular file is rewound, and a pipe is replayed through a child.
func (c *client) real(reason string) int {
	c.note("real:" + reason)
	argv := append([]string{c.opts.gitleaks}, c.opts.args...)
	if !c.read || c.regular {
		if c.read {
			if _, err := os.Stdin.Seek(c.offset, io.SeekStart); err != nil {
				return c.replay(argv)
			}
		}
		err := syscall.Exec(c.opts.gitleaks, argv, os.Environ())
		fmt.Fprintf(os.Stderr, "agent-guard-scan: cannot run gitleaks: %v\n", err)
		return 2
	}
	return c.replay(argv)
}

// replay runs gitleaks as a child, feeding it the bytes already read and
// then the rest of standard input, and returns its status as a shell would.
func (c *client) replay(argv []string) int {
	cmd := exec.Command(c.opts.gitleaks)
	cmd.Args = argv
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	// Feed a pipe in large writes, so gitleaks reads chunks as large as the
	// pipe allows, as it does from a producer writing directly.
	reader, writer, err := os.Pipe()
	if err != nil {
		fmt.Fprintf(os.Stderr, "agent-guard-scan: cannot run gitleaks: %v\n", err)
		return 2
	}
	cmd.Stdin = reader
	if err := cmd.Start(); err != nil {
		_ = reader.Close()
		_ = writer.Close()
		fmt.Fprintf(os.Stderr, "agent-guard-scan: cannot run gitleaks: %v\n", err)
		return 2
	}
	_ = reader.Close()
	// A failed read of standard input must not reach gitleaks as an end of
	// file: it would scan a prefix and could exit 0.
	input := &recordingReader{r: io.MultiReader(bytes.NewReader(c.data), os.Stdin)}
	copied := make(chan struct{})
	go func() {
		defer close(copied)
		buf := make([]byte, 1<<20)
		_, _ = io.CopyBuffer(writer, input, buf)
		_ = writer.Close()
	}()
	err = cmd.Wait()
	if err == nil {
		// gitleaks exits 0 after reading to the end of file, which arrives
		// only once the copy is done, or after it chose to stop reading (a
		// binary first chunk), as it would without the client. A read error
		// the copy met is not an end of file: report it.
		select {
		case <-copied:
			if input.failed() {
				fmt.Fprintln(os.Stderr, "agent-guard-scan: could not read standard input")
				return 2
			}
		case <-time.After(200 * time.Millisecond):
			if input.failed() {
				fmt.Fprintln(os.Stderr, "agent-guard-scan: could not read standard input")
				return 2
			}
		}
		return 0
	}
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		if status, ok := exitErr.Sys().(syscall.WaitStatus); ok && status.Signaled() {
			return 128 + int(status.Signal())
		}
		if code := exitErr.ExitCode(); code > 0 {
			return code
		}
		return 2
	}
	fmt.Fprintf(os.Stderr, "agent-guard-scan: cannot run gitleaks: %v\n", err)
	return 2
}

func envInt(name string, def, lo, hi int) int {
	n, err := strconv.Atoi(os.Getenv(name))
	if err != nil || n < lo || n > hi {
		return def
	}
	return n
}

// spawn starts one detached helper unless one was started recently. The
// helper takes the key's lock itself; a racing duplicate exits at once.
func (c *client) spawn(helper, stateDir, key, configPath, configSHA, marker string) {
	if info, err := os.Lstat(marker); err == nil && time.Since(info.ModTime()) < spawnBackoff && info.ModTime().Before(time.Now().Add(time.Second)) {
		return
	}
	// A helper holding the key's lock is starting or serving; a second one
	// would only exit at once and linger as a zombie of this process.
	if held, err := os.OpenFile(filepath.Join(filepath.Dir(marker), strings.TrimSuffix(filepath.Base(marker), ".spawn")+".lock"), os.O_RDONLY|syscall.O_NOFOLLOW, 0); err == nil {
		locked := syscall.Flock(int(held.Fd()), syscall.LOCK_EX|syscall.LOCK_NB) != nil
		_ = held.Close()
		if locked {
			return
		}
	}
	f, err := os.OpenFile(marker, os.O_WRONLY|os.O_CREATE|syscall.O_NOFOLLOW, 0o600)
	if err != nil {
		return
	}
	_ = f.Close()
	now := time.Now()
	if os.Chtimes(marker, now, now) != nil {
		return
	}
	absConfig, err := filepath.Abs(configPath)
	if err != nil {
		return
	}
	devnull, err := os.OpenFile(os.DevNull, os.O_RDWR, 0)
	if err != nil {
		return
	}
	defer devnull.Close()
	idle := envInt("AGENT_GUARD_GITLEAKS_HELPER_IDLE_SECONDS", defaultIdle, 1, 86400)
	maxRSS := envInt("AGENT_GUARD_GITLEAKS_HELPER_MAX_RSS_MIB", defaultRSS, 96, 4096)
	// The hook may hold the host's stdout and stderr on other descriptors
	// without close-on-exec (the CLI saves them on 8 and 9). The helper
	// outlives the hook and must not keep them open, or the host would wait
	// for its end of file. Mark every inherited descriptor above 2
	// close-on-exec for the spawn only, then restore it for the gitleaks this
	// process execs next.
	restore, ok := closeInheritedOnExec()
	defer restore()
	if !ok {
		c.note("no-spawn")
		return
	}
	proc, err := os.StartProcess(helper, []string{helper, "serve",
		"--state-dir", stateDir, "--key", key, "--config", absConfig, "--config-sha256", configSHA,
		"--idle-seconds", strconv.Itoa(idle), "--max-rss-mib", strconv.Itoa(maxRSS)},
		&os.ProcAttr{
			Dir: "/",
			// The helper outlives this hook: it gets no environment, so no
			// session's variables stay resident in it.
			Env:   []string{},
			Files: []*os.File{devnull, devnull, devnull},
			Sys:   &syscall.SysProcAttr{Setsid: true},
		})
	if err != nil {
		return
	}
	c.note("spawned")
	_ = proc.Release()
}

// closeInheritedOnExec sets close-on-exec on every open descriptor above 2
// that lacks it and returns a function that clears it again. It reports false
// when it could not list or mark every descriptor; the caller then starts no
// helper, because a helper holding a hook's pipe would make the host wait.
func closeInheritedOnExec() (func(), bool) {
	var marked []int
	restore := func() {
		for _, fd := range marked {
			if flags, err := unix.FcntlInt(uintptr(fd), unix.F_GETFD, 0); err == nil {
				_, _ = unix.FcntlInt(uintptr(fd), unix.F_SETFD, flags&^unix.FD_CLOEXEC)
			}
		}
	}
	var fds []int
	if dir, err := os.Open("/dev/fd"); err == nil {
		names, err := dir.Readdirnames(-1)
		own := int(dir.Fd())
		_ = dir.Close()
		if err != nil {
			return restore, false
		}
		for _, name := range names {
			if fd, err := strconv.Atoi(name); err == nil && fd > 2 && fd != own {
				fds = append(fds, fd)
			}
		}
	} else {
		// No /dev/fd (Linux without /proc): try every possible descriptor.
		var limit unix.Rlimit
		if unix.Getrlimit(unix.RLIMIT_NOFILE, &limit) != nil || limit.Cur > 1<<16 {
			return restore, false
		}
		for fd := 3; fd < int(limit.Cur); fd++ {
			fds = append(fds, fd)
		}
	}
	for _, fd := range fds {
		flags, err := unix.FcntlInt(uintptr(fd), unix.F_GETFD, 0)
		if err == unix.EBADF {
			continue
		}
		if err != nil {
			return restore, false
		}
		if flags&unix.FD_CLOEXEC != 0 {
			continue
		}
		if _, err := unix.FcntlInt(uintptr(fd), unix.F_SETFD, flags|unix.FD_CLOEXEC); err != nil {
			return restore, false
		}
		marked = append(marked, fd)
	}
	return restore, true
}

// recordingReader records whether a read failed other than at end of file.
type recordingReader struct {
	r   io.Reader
	bad atomic.Bool
}

func (r *recordingReader) Read(p []byte) (int, error) {
	n, err := r.r.Read(p)
	if err != nil && err != io.EOF {
		r.bad.Store(true)
	}
	return n, err
}

func (r *recordingReader) failed() bool { return r.bad.Load() }
