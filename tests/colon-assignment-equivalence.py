"""The colon assignment pattern takes one delimiter character (#585).

The pattern used to open with [ \t\r]+, which mawk and gawk retried from every
position of a long whitespace run, so a line of N spaces cost N^2. It now takes
a single whitespace character and find_assignment walks back over the run. This
compares the real find_assignment with the earlier [ \t\r]+ pattern and loop on
a seeded corpus, on every installed awk, so the start and length of every colon
assignment stay what they were.
"""

import os
from pathlib import Path
import random
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = Path(os.environ.get("AGENT_GUARD_UNIT_SOURCE", ROOT / "plugins/agent-guard/bin/agent-guard"))
WS = "[ \\t\\r]"


def program():
    lines = SOURCE.read_text().split("\n")
    lines = lines[lines.index("secretish_env_values() {"):]

    def first(prefix):
        return next(line.strip() for line in lines if line.strip().startswith(prefix))

    unquote = lambda text: text.replace("'\\''", "'")
    colon = first("colon_assignment = ")
    if colon.count("|" + WS + ")[") != 1:
        raise SystemExit("not ok - colon_assignment no longer opens with one whitespace character")
    reference = colon.replace("|" + WS + ")[", "|" + WS + "+)[").replace("colon_assignment", "reference_assignment", 1)
    start = next(i for i, line in enumerate(lines) if line.startswith("    function assignment_match("))
    end = next(i for i, line in enumerate(lines) if line.startswith("    function scan_line("))
    return "\n".join([
        "BEGIN {",
        *(unquote(first(p)) for p in ("core = ", "qualifier = ", "key = ")),
        'equals_assignment = "="',
        unquote(colon), unquote(reference),
        "}",
        unquote("\n".join(lines[start:end])),
        # find_assignment as it was before #585, with the [ \t\r]+ pattern.
        "function find_reference(low, before) {",
        "  ref_start = 0; ref_length = -1",
        "  if (!match(low, reference_assignment)) return",
        "  do { ref_start = RSTART; ref_length = RLENGTH; before = substr(low, 1, ref_start - 1) }",
        '  while (index(before, ":") > 0 && match(before, reference_assignment))',
        "}",
        "{",
        "  low = tolower($0)",
        '  find_assignment(low, ":")',
        "  find_reference(low)",
        "  if (assignment_start > 0) hits++",
        '  if (assignment_start > 0 && match(low, colon_assignment) && RSTART != assignment_start) walked++',
        "  if (assignment_start != ref_start || assignment_length != ref_length) {",
        "    if (!diffs++) printf \"line %d: %d,%d instead of %d,%d\\n\", NR, assignment_start, assignment_length, ref_start, ref_length",
        "  }",
        "}",
        'END { printf "%d %d %d\\n", hits, walked, diffs }',
    ]) + "\n"


def corpus(path):
    rnd = random.Random(585)
    q, bt = chr(39), chr(96)
    tokens = [" ", "   ", "\t", "\r", " \t\r ", ",", "{", "(", "[", "+", ":", ": ", "=", '"', q, bt,
              "a", "x", "-", "_", ".", "password", "API_KEY", "token", "secret_key", "db-pass", "Credential",
              "_pat", "_id", "_value", "error", "error:", "note: ", " password:", "\tsecret:", '"token":',
              q + "auth-token" + q + ":", bt + "user_pwd" + bt + " :"]
    with open(path, "w") as out:
        for _ in range(40000):
            out.write("".join(rnd.choice(tokens) for _ in range(rnd.randint(1, 24))) + "\n")


def main():
    required = os.environ.get("AGENT_GUARD_TEST_REQUIRE_AWKS", "").split()
    failed = 0
    with tempfile.TemporaryDirectory(prefix="agent-guard-colon-assignment-") as directory:
        script = Path(directory, "compare.awk")
        script.write_text(program())
        data = Path(directory, "corpus.txt")
        corpus(data)
        for variant in ("awk", "mawk", "gawk", "busybox"):
            executable = shutil.which(variant)
            if executable is None:
                mandatory = variant in required
                failed += mandatory
                print(f"{'not ok' if mandatory else 'ok'} - {variant} unavailable" + ("" if mandatory else " # SKIP"))
                continue
            command = [executable] + (["awk"] if variant == "busybox" else []) + ["-f", str(script), str(data)]
            run = subprocess.run(command, capture_output=True, text=True, env=dict(os.environ, LC_ALL="C"), timeout=120)
            report = run.stdout.strip().split("\n")
            try:
                hits, walked, diffs = map(int, report[-1].split())
            except ValueError:
                hits = walked = diffs = -1
            # walked counts lines where the walk back moved the start, so the
            # corpus is known to exercise it.
            if run.returncode == 0 and not run.stderr and diffs == 0 and hits > 1000 and walked > 100:
                print(f"ok - {variant} colon assignments match the [ \\t\\r]+ pattern ({hits} found, {walked} walked back)")
            else:
                failed += 1
                print(f"not ok - {variant} colon assignments differ: exit {run.returncode}, {' / '.join(report)} {run.stderr.strip()}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
