from pathlib import Path

root = Path(__file__).resolve().parents[2]
path = root/'plugins/agent-guard/bin/agent-guard'
source = path.read_text()

def function(name, next_marker):
    start = source.index(name+'() (')
    end = source.index(next_marker, start)
    return source[start:end]

detector = function('detect_output_secret_records', '\n# Bound secret records')
start = detector.index('  detector_input=$(mktemp_file)')
end = detector.index('  detector_fail()', start)
detector = detector[:start] + '''  detector_dir=$(umask 077; mktemp -d "${AGENT_GUARD_RUNDIR:-${TMPDIR:-/tmp}}/detector.XXXXXX") || exit 1
  umask 077
  detector_input=$detector_dir/input
  detector_strings=$detector_dir/strings
  detector_records=$detector_dir/records
  detector_work_a=$detector_dir/work-a
  detector_work_b=$detector_dir/work-b
  detector_cleanup() {
    rm -rf "$detector_dir"
  }
  trap 'detector_cleanup' 0
  trap 'exit 130' INT
  trap 'exit 143' TERM
''' + detector[end:]
detector = detector.replace('detector_report=$(mktemp_file) || detector_fail', 'detector_report=$detector_dir/report')
detector = detector.replace('>"$detector_work_a" 2>/dev/null || detector_fail\n      cat "$detector_work_a" >>"$detector_records" || detector_fail\n      rm -f "$detector_report"\n      detector_report=', '>>"$detector_records" 2>/dev/null || detector_fail')
detector = detector.replace('>"$detector_work_b" 2>/dev/null || detector_fail\n    cat "$detector_work_b" >>"$detector_records" || detector_fail', '>>"$detector_records" 2>/dev/null || detector_fail')
# Keep the original grep patterns, order, and error statuses. Both produce
# ASCII token lines, so one JSON encoding step suffices after both succeed.
detector = detector.replace('''  jq -Rc 'select(length > 0)' <"$detector_work_a" \\
    >"$detector_work_b" 2>/dev/null || detector_fail
  cat "$detector_work_b" >>"$detector_records" || detector_fail

''', '')
detector = detector.replace('''<"$detector_strings" >"$detector_work_a" 2>/dev/null
  detector_status=$?
  case "$detector_status" in 0|1) ;; *) detector_fail ;; esac
  awk''', '''<"$detector_strings" >"$detector_work_b" 2>/dev/null
  detector_status=$?
  case "$detector_status" in 0|1) ;; *) detector_fail ;; esac
  awk''')
detector = detector.replace('''<"$detector_work_a" >"$detector_work_b" 2>/dev/null || detector_fail
  jq -Rc 'select(length > 0)' <"$detector_work_b" \\
    >"$detector_work_a" 2>/dev/null || detector_fail
  cat "$detector_work_a" >>"$detector_records" || detector_fail''', '''<"$detector_work_b" >>"$detector_work_a" 2>/dev/null || detector_fail
  jq -Rc 'select(length > 0)' <"$detector_work_a" \\
    >>"$detector_records" 2>/dev/null || detector_fail''')
detector = detector.replace('  detector_cleanup\n  exit "$detector_status"', '  exit "$detector_status"')
detector = detector.replace('detect_output_secret_records()', 'detect_output_secret_records_fused()', 1)

bundle = function('bundle_secret_records', '\ndetect_output_secret_bundle()')
start = bundle.index('  bundle_input=')
end = bundle.index("    || ! LC_ALL=C awk '")
bundle = bundle[:start] + '''  bundle_records=$(mktemp_file) || exit 1
  trap 'rm -f "$bundle_records"' 0
  if ! LC_ALL=C awk '\n''' + bundle[end+len("    || ! LC_ALL=C awk '\n"):]
bundle = bundle.replace('<"$bundle_input" >"$bundle_records"', '>"$bundle_records"')
bundle = bundle.replace('<"$bundle_records" >"$bundle_output" 2>/dev/null', '<"$bundle_records" 2>/dev/null')
bundle = bundle.replace('    rm -f "$bundle_input" "$bundle_records" "$bundle_output"\n', '')
bundle = bundle[:bundle.index('  cat "$bundle_output"')] + '  exit 0\n)\n'
bundle = bundle.replace('bundle_secret_records()', 'bundle_secret_records_fused()', 1)

output = '''detect_output_secret_bundle_fused() (
  bundle_raw=$(mktemp_file) || exit 1
  trap 'rm -f "$bundle_raw"' 0
  detect_output_secret_records "$1" >"$bundle_raw" || exit 1
  bundle_secret_records <"$bundle_raw"
)
'''
for name in ['detect_output_secret_records', 'bundle_secret_records', 'detect_output_secret_bundle']:
    needle=name+'() (\n'
    source=source.replace(needle, needle+'''  if [ "${AGENT_GUARD_EXPERIMENTAL_OUTPUT_PIPELINE:-}" = fused ]; then
    '''+name+'''_fused "$@"
    exit $?
  fi
''',1)
marker='cmd=${1:-}\naudit_begin "$cmd"'
assert marker in source
source=source.replace(marker, '# Isolated output-pipeline experiment; default dispatch remains unchanged.\n'+detector+'\n'+bundle+'\n'+output+'\n'+marker)
path.write_text(source)
