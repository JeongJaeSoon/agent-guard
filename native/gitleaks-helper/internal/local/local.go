// Package local holds what the scan client and the helper must agree on: the
// private directory, the per-user, per-config, per-helper key, and peer
// credential checks on the Unix domain socket.
package local

import (
	"crypto/sha256"
	"debug/buildinfo"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
)

// SubDir is created inside the state directory the CLI already validated.
const SubDir = "gitleaks-helper"

// MaxSocketPath is the shortest sun_path limit of the supported systems
// (104 bytes with its NUL on macOS). Longer paths disable the helper.
const MaxSocketPath = 103

// PrivateDir reports whether path is a real directory (not a symlink) owned
// by uid with mode exactly 0700.
func PrivateDir(path string, uid int) error {
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		return errors.New("not a plain directory")
	}
	st, ok := info.Sys().(*syscall.Stat_t)
	if !ok || int(st.Uid) != uid {
		return errors.New("not owned by this user")
	}
	if info.Mode().Perm() != 0o700 {
		return errors.New("mode is not 0700")
	}
	return nil
}

// HelperDir validates stateDir and returns its private helper subdirectory,
// creating it when create is set. An existing entry is never chmodded: an
// unexpected one disables the helper.
func HelperDir(stateDir string, uid int, create bool) (string, error) {
	if !filepath.IsAbs(stateDir) || filepath.Clean(stateDir) != stateDir {
		return "", errors.New("state directory is not a clean absolute path")
	}
	if err := PrivateDir(stateDir, uid); err != nil {
		return "", err
	}
	dir := filepath.Join(stateDir, SubDir)
	if create {
		if err := os.Mkdir(dir, 0o700); err != nil && !errors.Is(err, os.ErrExist) {
			return "", err
		}
	}
	if err := PrivateDir(dir, uid); err != nil {
		return "", err
	}
	return dir, nil
}

// FileSHA256 hashes a file's current bytes, following symlinks as gitleaks
// does when it reads --config.
func FileSHA256(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// Identity is a file's device, inode, size and modification time in
// nanoseconds. Replacing or rewriting the helper binary changes it.
func Identity(path string) (string, error) {
	info, err := os.Stat(path)
	if err != nil {
		return "", err
	}
	if !info.Mode().IsRegular() {
		return "", errors.New("not a regular file")
	}
	st, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return "", errors.New("no stat")
	}
	return fmt.Sprintf("%d:%d:%d:%d", uint64(st.Dev), uint64(st.Ino), info.Size(), info.ModTime().UnixNano()), nil
}

// Key names one helper: the same user, the same helper binary and the same
// config bytes share one process; anything else gets its own.
func Key(uid int, helperIdentity, configSHA256 string) string {
	sum := sha256.Sum256([]byte(fmt.Sprintf("agent-guard gitleaks helper 1\x00%d\x00%s\x00%s", uid, helperIdentity, configSHA256)))
	return hex.EncodeToString(sum[:10])
}

// ValidKey accepts exactly what Key produces.
func ValidKey(key string) bool {
	if len(key) != 20 {
		return false
	}
	for _, c := range key {
		if (c < '0' || c > '9') && (c < 'a' || c > 'f') {
			return false
		}
	}
	return true
}

// Paths are the files one helper key owns inside the helper directory.
type Paths struct {
	Socket, Lock, Spawn, Unsupported string
}

func PathsFor(dir, key string) Paths {
	base := filepath.Join(dir, key)
	return Paths{Socket: base + ".sock", Lock: base + ".lock", Spawn: base + ".spawn", Unsupported: base + ".unsupported"}
}

// PeerUID returns the effective uid of the process on the other end of a
// connected Unix domain socket, as the kernel recorded it.
func PeerUID(conn *net.UnixConn) (int, error) {
	raw, err := conn.SyscallConn()
	if err != nil {
		return -1, err
	}
	uid := -1
	var credErr error
	if err := raw.Control(func(fd uintptr) { uid, credErr = peerUID(int(fd)) }); err != nil {
		return -1, err
	}
	if credErr != nil {
		return -1, credErr
	}
	return uid, nil
}

// SameUser fails unless the peer is this process's effective user.
func SameUser(conn *net.UnixConn) error {
	uid, err := PeerUID(conn)
	if err != nil {
		return err
	}
	if uid != os.Geteuid() {
		return errors.New("peer is another user")
	}
	return nil
}

// engineExcluded are modules a gitleaks build and the helper may differ in
// without running a different detector: the command-line framework only the
// gitleaks CLI links, the gitleaks module itself (version-checked separately;
// the official binary is built inside it), and the helper's own module.
var engineExcluded = map[string]bool{
	"github.com/spf13/cobra":                                     true,
	"github.com/zricethezav/gitleaks/v8":                         true,
	"github.com/JeongJaeSoon/agent-guard/native/gitleaks-helper": true,
}

// Engine describes what a Go build of gitleaks runs: its toolchain, its
// -tags setting (gore2regex selects go-re2 over Go's regexp) and every
// linked module version except engineExcluded. Two builds with the same
// Engine and gitleaks version run the same detector code.
func Engine(info *buildinfo.BuildInfo) string {
	if info == nil {
		return ""
	}
	tags := ""
	for _, setting := range info.Settings {
		if setting.Key == "-tags" {
			tags = setting.Value
		}
	}
	var deps []string
	for _, dep := range info.Deps {
		if engineExcluded[dep.Path] {
			continue
		}
		version := dep.Version + " " + dep.Sum
		if dep.Replace != nil {
			version = "replaced"
		}
		deps = append(deps, dep.Path+"@"+version)
	}
	sort.Strings(deps)
	return info.GoVersion + " tags=" + tags + " " + strings.Join(deps, " ")
}

// LinkedVersion is the version of module path linked into a build, without
// the leading "v", or "" when it is not linked or is replaced.
func LinkedVersion(info *buildinfo.BuildInfo, path string) string {
	if info == nil {
		return ""
	}
	for _, dep := range info.Deps {
		if dep.Path == path && dep.Replace == nil {
			return strings.TrimPrefix(dep.Version, "v")
		}
	}
	return ""
}

// FileEngine reads Engine from an executable's embedded build information.
func FileEngine(path string) (string, error) {
	info, err := buildinfo.ReadFile(path)
	if err != nil {
		return "", err
	}
	return Engine(info), nil
}
