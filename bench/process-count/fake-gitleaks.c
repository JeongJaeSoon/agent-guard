/*
 * Process-free stand-in for gitleaks, used only by bench/process-count/run.sh
 * and tests/gitleaks-clean-cache.sh.
 *
 * It implements the same contract as tests/fixtures/mock-gitleaks (stdin, dir
 * and version modes; AGENT_GUARD_TEST_SECRET or "PRIVATE KEY" is a finding)
 * but as a native executable, so that:
 *   - it spawns no child process of its own (the shell mock runs sh and cat),
 *     which keeps the per-event counts about agent-guard itself, and
 *   - agent-guard's gitleaks probe cache treats it like a real release binary
 *     (the cache refuses #! scripts), so steady-state hooks are measured.
 * Test-only knobs, all unset by the bench: FAKE_GITLEAKS_CALLS names a file
 * that gets one line (the mode) per invocation; FAKE_GITLEAKS_STDIN_EXIT forces
 * the stdin exit status ("kill" ends it with SIGKILL, as a host timeout does);
 * FAKE_GITLEAKS_STDIN_NOISE prints an error line and exits 0;
 * FAKE_GITLEAKS_STDIN_APPEND names a file that each stdin scan appends a line
 * to (a config edited while the scan runs); FAKE_GITLEAKS_STDIN_RELINK_TARGET
 * and FAKE_GITLEAKS_STDIN_RELINK_LINK point that link at that target during
 * each stdin scan (a symlinked config retargeted while the scan runs).
 * It is not a scanner and must never be installed as one.
 */
#define _XOPEN_SOURCE 700
#include <ftw.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>

static int found;

static int has_secret(const char *buf, size_t len) {
  static const char *needles[] = {"AGENT_GUARD_TEST_SECRET", "PRIVATE KEY"};
  for (size_t n = 0; n < 2; n++) {
    size_t nl = strlen(needles[n]);
    for (size_t i = 0; i + nl <= len; i++)
      if (memcmp(buf + i, needles[n], nl) == 0) return 1;
  }
  return 0;
}

static char *slurp(FILE *f, size_t *len) {
  size_t cap = 65536, used = 0, got;
  char *buf = malloc(cap);
  if (!buf) exit(2);
  while ((got = fread(buf + used, 1, cap - used, f)) > 0) {
    used += got;
    if (used == cap) {
      cap *= 2;
      buf = realloc(buf, cap);
      if (!buf) exit(2);
    }
  }
  *len = used;
  return buf;
}

static int scan_file(const char *path) {
  FILE *f = fopen(path, "rb");
  size_t len;
  char *buf;
  int hit;
  if (!f) return 0;
  buf = slurp(f, &len);
  fclose(f);
  hit = has_secret(buf, len);
  free(buf);
  return hit;
}

static int walk(const char *path, const struct stat *sb, int type, struct FTW *ftw) {
  (void)sb;
  (void)ftw;
  if (type == FTW_F && scan_file(path)) {
    found = 1;
    return 1;
  }
  return 0;
}

int main(int argc, char **argv) {
  const char *mode = argc > 1 ? argv[1] : "";
  const char *calls = getenv("FAKE_GITLEAKS_CALLS");
  if (calls && *calls) {
    FILE *c = fopen(calls, "a");
    if (c) {
      fprintf(c, "%s\n", mode);
      fclose(c);
    }
  }
  if (strcmp(mode, "version") == 0) {
    puts("8.30.1-mock");
    return 0;
  }
  if (strcmp(mode, "stdin") == 0) {
    const char *report = NULL;
    size_t len;
    char *buf;
    for (int i = 2; i < argc; i++) {
      if (strcmp(argv[i], "--report-path") == 0 && i + 1 < argc) report = argv[++i];
      else if (strncmp(argv[i], "--report-path=", 14) == 0) report = argv[i] + 14;
    }
    buf = slurp(stdin, &len);
    found = has_secret(buf, len);
    {
      const char *forced = getenv("FAKE_GITLEAKS_STDIN_EXIT");
      const char *append = getenv("FAKE_GITLEAKS_STDIN_APPEND");
      const char *rl_target = getenv("FAKE_GITLEAKS_STDIN_RELINK_TARGET");
      const char *rl_link = getenv("FAKE_GITLEAKS_STDIN_RELINK_LINK");
      if (rl_target && *rl_target && rl_link && *rl_link) {
        unlink(rl_link);
        if (symlink(rl_target, rl_link) != 0) return 2;
      }
      if (append && *append) {
        FILE *a = fopen(append, "a");
        if (a) {
          fputs("# edited during the scan\n", a);
          fclose(a);
        }
      }
      if (forced && strcmp(forced, "kill") == 0) raise(SIGKILL);
      if (forced && *forced) return atoi(forced);
      if (getenv("FAKE_GITLEAKS_STDIN_NOISE")) {
        puts("error: simulated scanner error");
        return 0;
      }
    }
    if (report && *report) {
      FILE *r = fopen(report, "w");
      if (r) {
        fputs(found ? "[{\"Secret\":\"AGENT_GUARD_TEST_SECRET\"}]\n" : "[]\n", r);
        fclose(r);
      }
    }
    if (found) puts("Finding: REDACTED");
    return found;
  }
  if (strcmp(mode, "dir") == 0) {
    for (int i = 2; i < argc && !found; i++) {
      struct stat st;
      if (argv[i][0] == '-' || stat(argv[i], &st) != 0) continue;
      if (S_ISREG(st.st_mode)) found = scan_file(argv[i]);
      else if (S_ISDIR(st.st_mode)) nftw(argv[i], walk, 16, FTW_PHYS);
    }
    if (found) puts("Finding: REDACTED");
    return found;
  }
  return 0;
}
