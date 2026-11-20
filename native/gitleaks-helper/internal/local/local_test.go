package local

import (
	"os"
	"path/filepath"
	"testing"
)

func TestKey(t *testing.T) {
	a := Key(501, "1:2:3:4", "aa")
	if !ValidKey(a) || a == Key(502, "1:2:3:4", "aa") || a == Key(501, "1:2:3:5", "aa") || a == Key(501, "1:2:3:4", "ab") {
		t.Fatalf("key %q does not separate users, helpers and configs", a)
	}
	for _, bad := range []string{"", "../x", "ABCDEF0123456789abcd", "0123456789abcdef012", "0123456789abcdef0123/"} {
		if ValidKey(bad) {
			t.Errorf("accepted %q", bad)
		}
	}
}

func TestHelperDir(t *testing.T) {
	uid := os.Geteuid()
	root := t.TempDir()
	state := filepath.Join(root, "state")
	if err := os.Mkdir(state, 0o700); err != nil {
		t.Fatal(err)
	}
	dir, err := HelperDir(state, uid, true)
	if err != nil || dir != filepath.Join(state, SubDir) {
		t.Fatalf("HelperDir: %q %v", dir, err)
	}
	if _, err := HelperDir(state+"/", uid, false); err == nil {
		t.Error("unclean path accepted")
	}
	if _, err := HelperDir("relative", uid, false); err == nil {
		t.Error("relative path accepted")
	}
	if _, err := HelperDir(state, uid+1, false); err == nil {
		t.Error("another owner accepted")
	}
	if err := os.Chmod(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if _, err := HelperDir(state, uid, true); err == nil {
		t.Error("group-readable helper directory accepted")
	}
	link := filepath.Join(root, "link")
	if err := os.Symlink(state, link); err != nil {
		t.Fatal(err)
	}
	if _, err := HelperDir(link, uid, false); err == nil {
		t.Error("symlinked state directory accepted")
	}
	other := filepath.Join(root, "other")
	if err := os.Mkdir(other, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(state, filepath.Join(other, SubDir)); err != nil {
		t.Fatal(err)
	}
	if _, err := HelperDir(other, uid, true); err == nil {
		t.Error("symlinked helper directory accepted")
	}
}
