/*
 * Process-free stand-in for gitleaks, used only by bench/process-count/run.sh.
 *
 * It implements the same contract as tests/fixtures/mock-gitleaks (stdin, dir
 * and version modes; AGENT_GUARD_TEST_SECRET or "PRIVATE KEY" is a finding)
 * but as a native executable, so that:
 *   - it spawns no child process of its own (the shell mock runs sh and cat),
 *     which keeps the per-event counts about agent-guard itself, and
 *   - agent-guard's gitleaks probe cache treats it like a real release binary
 *     (the cache refuses #! scripts), so steady-state hooks are measured.
 * It is not a scanner and must never be installed as one.
 */
#define _XOPEN_SOURCE 700
#include <ftw.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
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
