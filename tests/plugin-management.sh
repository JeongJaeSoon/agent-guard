#!/usr/bin/env sh
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD="$ROOT/plugins/agent-guard/bin/agent-guard"
CLI_VERSION=$("$GUARD" version | awk 'NR == 1 { print $2 }')
[ -n "$CLI_VERSION" ] || { printf '%s\n' 'could not read CLI version' >&2; exit 2; }
CLI_TAG="v$CLI_VERSION"
OLD_VERSION=0.0.0
[ "$CLI_VERSION" = "$OLD_VERSION" ] && OLD_VERSION=0.0.1
OLD_TAG="v$OLD_VERSION"
NEWER_VERSION=$(printf '%s\n' "$CLI_VERSION" | awk -F. '{ printf "%s.%s.%s", $1, $2, $3 + 1 }')
NEWER_TAG="v$NEWER_VERSION"
export AG_PLUGIN_TEST_EXPECTED_VERSION="$CLI_VERSION"
export AG_PLUGIN_TEST_EXPECTED_TAG="$CLI_TAG"
export AG_PLUGIN_TEST_OLD_VERSION="$OLD_VERSION"
export AG_PLUGIN_TEST_OLD_TAG="$OLD_TAG"
CASE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-plugin-test.XXXXXX")

# Ends what a Codex stub left running: the stub by its recorded PID and, when
# the probe has a process group other than this suite's, that group. A PID is
# signalled only while its command line still names this run's private
# directory, so a PID the system has reused is never touched.
reap_trust_servers() {
  reap_own_group=$(ps -o pgid= -p "$$" 2>/dev/null | tr -d ' ')
  for reap_pidfile in "$CASE_ROOT"/*/server-pids; do
    [ -f "$reap_pidfile" ] || continue
    while IFS= read -r reap_pid; do
      case "$reap_pid" in ''|*[!0-9]*) continue ;; esac
      case "$(ps -o command= -p "$reap_pid" 2>/dev/null)" in
        *"$CASE_ROOT/"*) ;;
        *) continue ;;
      esac
      reap_group=$(ps -o pgid= -p "$reap_pid" 2>/dev/null | tr -d ' ')
      case "$reap_own_group:$reap_group" in
        :*|*:|*[!0-9:]*|"$reap_group:$reap_group") ;;
        *) kill -KILL -"$reap_group" 2>/dev/null ;;
      esac
      kill -KILL "$reap_pid" 2>/dev/null
    done <"$reap_pidfile"
  done
  return 0
}

trap 'reap_trust_servers; rm -rf "$CASE_ROOT"' EXIT INT TERM
REAL_JQ=$(command -v jq)
REAL_MKTEMP=$(command -v mktemp)
REAL_RM=$(command -v rm)
pass=0
fail=0

ok() { pass=$((pass + 1)); printf 'ok - %s\n' "$1"; }
not_ok() { fail=$((fail + 1)); printf 'not ok - %s\n' "$1"; }

new_case() {
  case_name=$1
  case_dir="$CASE_ROOT/$case_name"
  case_bin="$case_dir/bin"
  case_log="$case_dir/calls"
  case_managed="$case_dir/managed-settings-root"
  mkdir -p "$case_bin"
  mkdir -p "$case_managed"
  : >"$case_log"
  ln -s "$REAL_JQ" "$case_bin/jq"
  # The CLI under test is on PATH, as for a standalone install, so its retry
  # advice keeps the short name (tests/cli-guidance.sh covers plugin-only).
  ln -s "$GUARD" "$case_bin/agent-guard"
  export AG_PLUGIN_TEST_LOG="$case_log"
  export AG_PLUGIN_TEST_MARKETPLACE=absent
  export AG_PLUGIN_TEST_INSTALLED=0
  export AG_PLUGIN_TEST_FAIL=
  export AG_PLUGIN_TEST_SCHEMA=normal
  export AG_PLUGIN_TEST_MODE=1
  export AG_PLUGIN_TEST_CLAUDE_MANAGED_SETTINGS_ROOT="$case_managed"
  # run_guard keeps the real curl reachable; stay offline unless a case
  # installs mock_release_curl.
  export AGENT_GUARD_RELEASE_CHECK=off
  # Keep call logs exact; trust cases opt in through trust_case.
  export AGENT_GUARD_CODEX_TRUST_CHECK=off
  unset AG_PLUGIN_TEST_TRUST AG_PLUGIN_TEST_TRUST_REQUESTS AG_PLUGIN_TEST_TRUST_PIDFILE \
    AG_PLUGIN_TEST_TRUST_CHILD AG_PLUGIN_TEST_TRUST_GATE AG_PLUGIN_TEST_CODEX_TRUST_TIMEOUT \
    AGENT_GUARD_GITLEAKS_BIN
}

# Mock the GitHub releases/latest HEAD redirect. $1 is the tag the redirect
# points at (empty = curl failure).
mock_release_curl() {
  cat >"$case_bin/curl" <<'EOF'
#!/usr/bin/env sh
printf 'curl %s\n' "$*" >>"$AG_PLUGIN_TEST_LOG"
[ -n "${AG_PLUGIN_TEST_RELEASE_TAG:-}" ] || exit 1
printf '%s' "https://github.com/JeongJaeSoon/agent-guard/releases/tag/$AG_PLUGIN_TEST_RELEASE_TAG"
EOF
  chmod +x "$case_bin/curl"
  export AG_PLUGIN_TEST_RELEASE_TAG="$1"
  export AGENT_GUARD_RELEASE_CHECK=on
}

write_managed_base() {
  printf '%s\n' "$1" >"$case_managed/managed-settings.json"
}

write_managed_fragment() {
  mkdir -p "$case_managed/managed-settings.d"
  printf '%s\n' "$2" >"$case_managed/managed-settings.d/$1.json"
}

force_rundir_fallback() {
  case_tmp="$case_dir/tmp"
  mkdir -p "$case_tmp"
  cat >"$case_bin/mktemp" <<'EOF'
#!/usr/bin/env sh
printf '%s\n' "$*" >>"$AG_PLUGIN_TEST_MKTEMP_LOG"
case "$*" in
  *agent-guard-run.*) exit 1 ;;
esac
exec "$AG_PLUGIN_TEST_REAL_MKTEMP" "$@"
EOF
  chmod +x "$case_bin/mktemp"
  export AG_PLUGIN_TEST_REAL_MKTEMP="$REAL_MKTEMP"
  export AG_PLUGIN_TEST_MKTEMP_LOG="$case_dir/mktemp-calls"
}

capture_summary_on_cleanup() {
  cat >"$case_bin/rm" <<'EOF'
#!/usr/bin/env sh
if [ "${1:-}" = -f ] && [ "$#" -eq 2 ] && [ -f "$2" ]; then
  case "$2" in
    */agent-guard.*) cp "$2" "$AG_PLUGIN_TEST_SUMMARY_SNAPSHOT" ;;
  esac
fi
exec "$AG_PLUGIN_TEST_REAL_RM" "$@"
EOF
  chmod +x "$case_bin/rm"
  export AG_PLUGIN_TEST_REAL_RM="$REAL_RM"
  export AG_PLUGIN_TEST_SUMMARY_SNAPSHOT="$case_dir/summary-snapshot"
}

signal_during_managed_summary() {
  rm -f "$case_bin/jq"
  cat >"$case_bin/jq" <<'EOF'
#!/usr/bin/env sh
case "$*" in
  *managed-settings.json)
    kill "-$AG_PLUGIN_TEST_SUMMARY_SIGNAL" "$PPID"
    exit 1
    ;;
esac
exec "$AG_PLUGIN_TEST_REAL_JQ" "$@"
EOF
  chmod +x "$case_bin/jq"
  export AG_PLUGIN_TEST_REAL_JQ="$REAL_JQ"
}

add_host() {
  host=$1
  cp "$ROOT/tests/fixtures/mock-plugin-manager" "$case_bin/$host"
  chmod +x "$case_bin/$host"
}

run_guard() {
  PATH="$case_bin:/usr/bin:/bin" "$GUARD" "$@" >"$case_dir/out" 2>"$case_dir/err"
}

# Replaces the calling subshell with "$@" as the leader of a process group of
# its own, through the launchers the guard itself accepts.
exec_as_group_leader() {
  if command -v setsid >/dev/null 2>&1; then
    exec setsid "$@"
  fi
  exec perl -e 'setpgrp(0, 0); exec @ARGV; exit 126' "$@"
}

new_case plugin_help
if run_guard plugin --help \
   && grep -Fq 'agent-guard plugin status|install|update|uninstall' "$case_dir/err" \
   && [ ! -s "$case_log" ]; then
  ok 'plugin help exits successfully without calling a host manager'
else
  not_ok 'plugin help exits successfully without calling a host manager'
fi

new_case no_host
if run_guard plugin status; then
  not_ok 'plugin host auto-detection rejects no host'
elif [ "$?" -eq 2 ] && grep -q 'exactly one' "$case_dir/err"; then
  ok 'plugin host auto-detection rejects no host'
else
  not_ok 'plugin host auto-detection rejects no host'
fi

new_case both_hosts
add_host claude
add_host codex
if run_guard plugin status; then
  not_ok 'plugin host auto-detection rejects two hosts'
elif [ "$?" -eq 2 ] && [ ! -s "$case_log" ]; then
  ok 'plugin host auto-detection rejects two hosts before manager calls'
else
  not_ok 'plugin host auto-detection rejects two hosts before manager calls'
fi

new_case claude_install
add_host claude
if run_guard plugin install \
   && grep -Fxq "claude plugin marketplace add JeongJaeSoon/agent-guard@$CLI_TAG --scope user" "$case_log" \
   && grep -Fxq 'claude plugin install agent-guard@agent-guard --scope user' "$case_log" \
   && ! grep -Eq '(^| )(sudo|-y)( |$)' "$case_log"; then
  ok 'Claude install auto-detects, registers the remote marketplace, and retains prompts'
else
  not_ok 'Claude install auto-detects, registers the remote marketplace, and retains prompts'
fi

new_case installed_noop
add_host claude
export AG_PLUGIN_TEST_MARKETPLACE=ok AG_PLUGIN_TEST_INSTALLED=1
if run_guard plugin install --host claude \
   && grep -q 'already installed' "$case_dir/out" \
   && ! grep -Eq 'marketplace add|plugin install|plugin update' "$case_log"; then
  ok 'install is idempotent and never updates an installed plugin'
else
  not_ok 'install is idempotent and never updates an installed plugin'
fi

new_case codex_installed_noop
add_host codex
export AG_PLUGIN_TEST_MARKETPLACE=ok AG_PLUGIN_TEST_INSTALLED=1
if run_guard plugin install --host codex \
   && grep -q 'already installed' "$case_dir/out" \
   && grep -Fxq "codex plugin marketplace add JeongJaeSoon/agent-guard@$CLI_TAG" "$case_log" \
   && ! grep -Eq 'plugin add agent-guard@agent-guard|marketplace (upgrade|remove)' "$case_log"; then
  ok 'Codex install uses the manager same-ref probe and remains idempotent'
else
  not_ok 'Codex install uses the manager same-ref probe and remains idempotent'
fi

for disabled_host in claude codex; do
  new_case "${disabled_host}_disabled_status"
  add_host "$disabled_host"
  export AG_PLUGIN_TEST_MARKETPLACE=ok AG_PLUGIN_TEST_INSTALLED=disabled
  if run_guard plugin status --host "$disabled_host" \
     && grep -q '^'"$disabled_host"': installed, disabled' "$case_dir/out"; then
    ok "$disabled_host status distinguishes an installed disabled plugin"
  else
    not_ok "$disabled_host status distinguishes an installed disabled plugin"
  fi

  new_case "${disabled_host}_disabled_install"
  add_host "$disabled_host"
  export AG_PLUGIN_TEST_MARKETPLACE=ok AG_PLUGIN_TEST_INSTALLED=disabled
  if run_guard plugin install --host "$disabled_host"; then
    not_ok "$disabled_host install rejects an installed disabled plugin"
  elif grep -q 'installed but disabled' "$case_dir/err" \
     && ! grep -Eq 'plugin (install|add) agent-guard@agent-guard' "$case_log"; then
    ok "$disabled_host install requires explicit host activation"
  else
    not_ok "$disabled_host install requires explicit host activation"
  fi

  new_case "${disabled_host}_disabled_update"
  add_host "$disabled_host"
  export AG_PLUGIN_TEST_MARKETPLACE=ok AG_PLUGIN_TEST_INSTALLED=disabled
  if run_guard plugin update --host "$disabled_host" \
     && grep -q 'installed but disabled; update will keep it disabled' "$case_dir/err"; then
    ok "$disabled_host update preserves installed status without implying activation"
  else
    not_ok "$disabled_host update preserves installed status without implying activation"
  fi
done

for failed_host in claude codex; do
  new_case "${failed_host}_marketplace_add_failure"
  add_host "$failed_host"
  export AG_PLUGIN_TEST_FAIL="$failed_host:plugin marketplace add"
  if run_guard plugin install --host "$failed_host"; then
    not_ok "$failed_host install reports marketplace registration failure"
  elif grep -q "pinned to $CLI_TAG" "$case_dir/err" \
     && grep -q "safe to retry 'agent-guard plugin install --host $failed_host'" "$case_dir/err" \
     && ! grep -Eq 'plugin (install|add) agent-guard@agent-guard' "$case_log"; then
    ok "$failed_host install stops before plugin installation when marketplace registration fails"
  else
    not_ok "$failed_host install reports marketplace registration failure"
  fi
done

for failed_host in claude codex; do
  new_case "${failed_host}_install_failure"
  add_host "$failed_host"
  case "$failed_host" in
    claude) export AG_PLUGIN_TEST_FAIL='claude:plugin install' ;;
    codex) export AG_PLUGIN_TEST_FAIL='codex:plugin add agent-guard@agent-guard' ;;
  esac
  if run_guard plugin install --host "$failed_host"; then
    not_ok "$failed_host install reports retained marketplace after plugin failure"
  elif grep -q "marketplace 'agent-guard' was added" "$case_dir/err" \
     && grep -q "safe to retry 'agent-guard plugin install --host $failed_host'" "$case_dir/err"; then
    ok "$failed_host install reports retained marketplace and safe retry"
  else
    not_ok "$failed_host install reports retained marketplace and safe retry"
  fi
done

new_case claude_malformed_state
add_host claude
export AG_PLUGIN_TEST_SCHEMA=malformed
if run_guard plugin install --host claude; then
  not_ok 'Claude install rejects malformed manager state before mutation'
elif grep -q 'could not report its state' "$case_dir/err" \
   && ! grep -Eq 'marketplace add|plugin install' "$case_log"; then
  ok 'Claude install rejects malformed manager state before mutation'
else
  not_ok 'Claude install rejects malformed manager state before mutation'
fi

new_case codex_schema_drift
add_host codex
export AG_PLUGIN_TEST_SCHEMA=drift
if run_guard plugin install --host codex; then
  not_ok 'Codex install rejects changed manager schema before mutation'
elif grep -q 'could not report its state' "$case_dir/err" \
   && ! grep -Eq 'marketplace add|plugin add agent-guard@agent-guard' "$case_log"; then
  ok 'Codex install rejects changed manager schema before mutation'
else
  not_ok 'Codex install rejects changed manager schema before mutation'
fi

new_case source_conflict
add_host codex
export AG_PLUGIN_TEST_MARKETPLACE=conflict
if run_guard plugin install --host codex; then
  not_ok 'install refuses a same-name marketplace from another source'
elif [ "$?" -eq 2 ] \
   && grep -q 'different source' "$case_dir/err" \
   && ! grep -Eq 'marketplace add|plugin add' "$case_log"; then
  ok 'install refuses a same-name marketplace from another source'
else
  not_ok 'install refuses a same-name marketplace from another source'
fi

for drift_host in claude codex; do
  for drift_marketplace in unpinned old; do
    new_case "${drift_host}_${drift_marketplace}_marketplace_status"
    add_host "$drift_host"
    export AG_PLUGIN_TEST_MARKETPLACE="$drift_marketplace" AG_PLUGIN_TEST_INSTALLED=old
    if run_guard plugin status --host "$drift_host" \
       && grep -q "version $OLD_VERSION, expected $CLI_VERSION" "$case_dir/out"; then
      case "$drift_host" in
        claude) grep -q "marketplace drift:.*expected $CLI_TAG" "$case_dir/out" ;;
        codex) grep -q 'marketplace configured, pin unverified by Codex' "$case_dir/out" ;;
      esac
      if [ "$?" -eq 0 ]; then
        ok "$drift_host status reports plugin and marketplace verification state"
      else
        not_ok "$drift_host status reports plugin and marketplace verification state"
      fi
    else
      not_ok "$drift_host status reports plugin and marketplace verification state"
    fi

    for drift_action in install update; do
      new_case "${drift_host}_${drift_marketplace}_${drift_action}"
      add_host "$drift_host"
      export AG_PLUGIN_TEST_MARKETPLACE="$drift_marketplace" AG_PLUGIN_TEST_INSTALLED=old
      if run_guard plugin "$drift_action" --host "$drift_host"; then
        not_ok "$drift_host $drift_action refuses a $drift_marketplace marketplace"
      elif [ "$?" -eq 2 ] \
         && grep -q 'marketplace removal also removes its installed plugin' "$case_dir/err" \
         && ! grep -Eq 'plugin (install|update|add) agent-guard@agent-guard|marketplace (update|upgrade|remove)' "$case_log"; then
        ok "$drift_host $drift_action refuses a $drift_marketplace marketplace with recovery guidance"
      else
        not_ok "$drift_host $drift_action refuses a $drift_marketplace marketplace"
      fi
    done
  done
done

new_case claude_managed_plugin_status
add_host claude
export AG_PLUGIN_TEST_MARKETPLACE=ok AG_PLUGIN_TEST_INSTALLED=managed_disabled
if run_guard plugin status --host claude \
   && grep -q "managed by Jamf/managed settings (plugin installed, disabled, version $CLI_VERSION)" "$case_dir/out"; then
  ok 'Claude status identifies a managed disabled plugin and its version'
else
  not_ok 'Claude status identifies a managed disabled plugin and its version'
fi

new_case claude_managed_marketplace_status
add_host claude
export AG_PLUGIN_TEST_MARKETPLACE=ok AG_PLUGIN_TEST_INSTALLED=0
write_managed_base "{\"extraKnownMarketplaces\":{\"agent-guard\":{\"source\":{\"source\":\"github\",\"repo\":\"JeongJaeSoon/agent-guard\",\"ref\":\"$CLI_TAG\"}}}}"
if run_guard plugin status --host claude \
   && grep -q 'managed by Jamf/managed settings (Agent Guard configured, plugin not installed)' "$case_dir/out"; then
  ok 'Claude status identifies a managed settings marketplace without a plugin'
else
  not_ok 'Claude status identifies a managed settings marketplace without a plugin'
fi

new_case claude_managed_fragment_status
add_host claude
export AG_PLUGIN_TEST_MARKETPLACE=ok AG_PLUGIN_TEST_INSTALLED=0
write_managed_fragment guard '{"enabledPlugins":{"agent-guard@agent-guard":false}}'
if run_guard plugin status --host claude \
   && grep -q 'managed by Jamf/managed settings (Agent Guard configured, plugin not installed)' "$case_dir/out"; then
  ok 'Claude status reads an Agent Guard declaration from managed-settings.d'
else
  not_ok 'Claude status reads an Agent Guard declaration from managed-settings.d'
fi

for managed_state in plugin base fragment; do
  for managed_action in install update uninstall; do
    new_case "claude_managed_${managed_state}_${managed_action}"
    add_host claude
    case "$managed_state" in
      plugin) export AG_PLUGIN_TEST_MARKETPLACE=ok AG_PLUGIN_TEST_INSTALLED=managed ;;
      base)
        export AG_PLUGIN_TEST_MARKETPLACE=ok AG_PLUGIN_TEST_INSTALLED=0
        write_managed_base '{"enabledPlugins":{"agent-guard@agent-guard":true}}'
        ;;
      fragment)
        export AG_PLUGIN_TEST_MARKETPLACE=ok AG_PLUGIN_TEST_INSTALLED=0
        write_managed_fragment guard '{"extraKnownMarketplaces":{"security":{"source":{"source":"github","repo":"JeongJaeSoon/agent-guard"}}}}'
        ;;
    esac
    if run_guard plugin "$managed_action" --host claude; then
      not_ok "Claude $managed_action refuses a managed $managed_state"
    elif [ "$?" -eq 2 ] \
       && grep -q 'ask the administrator to change the pinned marketplace ref' "$case_dir/err" \
       && ! grep -Eq 'marketplace (add|update)|plugin (install|update|uninstall)' "$case_log"; then
      ok "Claude $managed_action refuses a managed $managed_state before mutation"
    else
      not_ok "Claude $managed_action refuses a managed $managed_state before mutation"
    fi
  done
done

new_case claude_unrelated_managed_settings
add_host claude
export AG_PLUGIN_TEST_MARKETPLACE=ok AG_PLUGIN_TEST_INSTALLED=0
write_managed_base '{"extraKnownMarketplaces":{"other":{"source":{"source":"github","repo":"example/other"}}},"enabledPlugins":{"other@other":true}}'
write_managed_fragment other '{"permissions":{"deny":["Read(example)"]}}'
if run_guard plugin install --host claude \
   && grep -Fxq 'claude plugin install agent-guard@agent-guard --scope user' "$case_log"; then
  ok 'unrelated managed settings do not block self-managed installation'
else
  not_ok 'unrelated managed settings do not block self-managed installation'
fi

new_case claude_unarmed_test_root_override
add_host claude
export AG_PLUGIN_TEST_MODE=0
if run_guard plugin install --host claude; then
  not_ok 'a managed-settings test root requires explicit test mode'
elif [ "$?" -eq 2 ] \
   && grep -q 'could not be read or safely parsed' "$case_dir/err" \
   && ! grep -Eq 'marketplace (add|update)|plugin (install|update|uninstall)' "$case_log"; then
  ok 'a managed-settings test root is rejected outside explicit test mode'
else
  not_ok 'a managed-settings test root is rejected outside explicit test mode'
fi

new_case claude_empty_managed_settings
add_host claude
: >"$case_managed/managed-settings.json"
if run_guard plugin install --host claude \
   && grep -Fxq "claude plugin marketplace add JeongJaeSoon/agent-guard@$CLI_TAG --scope user" "$case_log" \
   && grep -Fxq 'claude plugin install agent-guard@agent-guard --scope user' "$case_log"; then
  ok 'an empty managed settings file is treated as an unrelated empty object'
else
  not_ok 'an empty managed settings file is treated as an unrelated empty object'
fi

new_case claude_summary_fallback_cleanup_success
add_host claude
force_rundir_fallback
: >"$case_managed/managed-settings.json"
if TMPDIR="$case_tmp" run_guard plugin status --host claude; then
  find "$case_tmp" -mindepth 1 -print -quit >"$case_dir/residue"
  if grep -Fq "$case_tmp/agent-guard.XXXXXX" "$case_dir/mktemp-calls" \
     && [ ! -s "$case_dir/residue" ]; then
    ok 'managed settings summary fallback is removed after success'
  else
    not_ok 'managed settings summary fallback is removed after success'
  fi
else
  not_ok 'managed settings summary fallback is removed after success'
fi

new_case claude_summary_fallback_cleanup_failure
add_host claude
force_rundir_fallback
write_managed_base '{not-json'
if TMPDIR="$case_tmp" run_guard plugin status --host claude; then
  not_ok 'managed settings summary fallback is removed after parse failure'
elif [ "$?" -eq 2 ]; then
  find "$case_tmp" -mindepth 1 -print -quit >"$case_dir/residue"
  if grep -Fq "$case_tmp/agent-guard.XXXXXX" "$case_dir/mktemp-calls" \
     && [ ! -s "$case_dir/residue" ]; then
    ok 'managed settings summary fallback is removed after parse failure'
  else
    not_ok 'managed settings summary fallback is removed after parse failure'
  fi
else
  not_ok 'managed settings summary fallback is removed after parse failure'
fi

new_case claude_summary_excludes_raw_managed_values
add_host claude
capture_summary_on_cleanup
write_managed_base '{"policyHelper":{"path":"/private/super-secret-helper"},"extraKnownMarketplaces":{"internal":{"source":{"source":"git","url":"https://token:super-secret@example.invalid/private.git","headers":{"Authorization":"Bearer super-secret"}}},"official":{"source":{"source":"github","repo":"JeongJaeSoon/agent-guard"}}},"enabledPlugins":{"agent-guard@agent-guard":true,"private@internal":true},"env":{"AGENT_GUARD_PRIVATE_VALUE":"super-secret-env"}}'
if run_guard plugin status --host claude; then
  not_ok 'managed settings summary excludes raw managed values'
elif [ "$?" -eq 2 ] \
   && [ -s "$AG_PLUGIN_TEST_SUMMARY_SNAPSHOT" ] \
   && grep -Fq '"repo":"agent-guard"' "$AG_PLUGIN_TEST_SUMMARY_SNAPSHOT" \
   && grep -Fq '"policyHelper":true' "$AG_PLUGIN_TEST_SUMMARY_SNAPSHOT" \
   && ! grep -Eq 'super-secret|Authorization|private@internal|AGENT_GUARD_PRIVATE_VALUE' \
        "$AG_PLUGIN_TEST_SUMMARY_SNAPSHOT"; then
  ok 'managed settings summary stores only non-sensitive ownership classifications'
else
  not_ok 'managed settings summary stores only non-sensitive ownership classifications'
fi

for summary_signal in HUP INT TERM; do
  new_case "claude_summary_cleanup_${summary_signal}"
  add_host claude
  force_rundir_fallback
  signal_during_managed_summary
  export AG_PLUGIN_TEST_SUMMARY_SIGNAL="$summary_signal"
  write_managed_base '{"enabledPlugins":{"agent-guard@agent-guard":true}}'
  if TMPDIR="$case_tmp" run_guard plugin install --host claude; then
    not_ok "managed settings summary fallback is removed after $summary_signal"
  else
    find "$case_tmp" -mindepth 1 -print -quit >"$case_dir/residue"
    if grep -Fq "$case_tmp/agent-guard.XXXXXX" "$case_dir/mktemp-calls" \
       && [ ! -s "$case_dir/residue" ] \
       && ! grep -Eq 'marketplace (add|update)|plugin (install|update|uninstall)' "$case_log"; then
      ok "managed settings summary fallback is removed after $summary_signal"
    else
      not_ok "managed settings summary fallback is removed after $summary_signal"
    fi
  fi
done

new_case claude_marketplace_override_unrelated
add_host claude
write_managed_base '{"extraKnownMarketplaces":{"agent-guard":{"source":{"source":"github","repo":"JeongJaeSoon/agent-guard"}}}}'
write_managed_fragment override '{"extraKnownMarketplaces":{"agent-guard":{"source":{"repo":"example/other"}}}}'
if run_guard plugin status --host claude \
   && grep -q '^claude: not installed (marketplace missing)$' "$case_dir/out"; then
  ok 'a later drop-in marketplace override determines the final managed state'
else
  not_ok 'a later drop-in marketplace override determines the final managed state'
fi

new_case claude_marketplace_override_managed
add_host claude
write_managed_base '{"extraKnownMarketplaces":{"security":{"source":{"source":"github","repo":"example/other"}}}}'
write_managed_fragment override '{"extraKnownMarketplaces":{"security":{"source":{"repo":"JeongJaeSoon/agent-guard"}}}}'
if run_guard plugin status --host claude \
   && grep -q 'managed by Jamf/managed settings (Agent Guard configured, plugin not installed)' "$case_dir/out"; then
  ok 'a later drop-in can make the final merged marketplace managed'
else
  not_ok 'a later drop-in can make the final merged marketplace managed'
fi

for policy_helper_action in status install; do
  new_case "claude_policy_helper_${policy_helper_action}"
  add_host claude
  write_managed_base '{"policyHelper":{"path":"/usr/local/bin/claude-policy","timeoutMs":5000},"extraKnownMarketplaces":{"agent-guard":{"source":{"source":"github","repo":"JeongJaeSoon/agent-guard"}}}}'
  if run_guard plugin "$policy_helper_action" --host claude; then
    not_ok "Claude $policy_helper_action rejects dynamic managed settings ownership"
  elif [ "$?" -eq 2 ] \
     && grep -q 'policyHelper replaces file-based managed settings' "$case_dir/err" \
     && ! grep -Eq 'marketplace (add|update)|plugin (install|update|uninstall)' "$case_log"; then
    ok "Claude $policy_helper_action fails closed when policyHelper replaces file settings"
  else
    not_ok "Claude $policy_helper_action fails closed when policyHelper replaces file settings"
  fi
done

new_case claude_malformed_managed_settings
add_host claude
export AG_PLUGIN_TEST_MARKETPLACE=ok AG_PLUGIN_TEST_INSTALLED=0
write_managed_base '{not-json'
if run_guard plugin status --host claude; then
  not_ok 'malformed managed settings make status fail closed'
elif [ "$?" -eq 2 ] \
   && grep -q 'could not be read or safely parsed' "$case_dir/err" \
   && ! grep -Eq 'marketplace (add|update)|plugin (install|update|uninstall)' "$case_log"; then
  ok 'malformed managed settings make status fail closed before mutation'
else
  not_ok 'malformed managed settings make status fail closed before mutation'
fi

new_case claude_unreadable_managed_fragment
add_host claude
export AG_PLUGIN_TEST_MARKETPLACE=ok AG_PLUGIN_TEST_INSTALLED=0
mkdir -p "$case_managed/managed-settings.d/unreadable.json"
if run_guard plugin install --host claude; then
  not_ok 'unreadable or non-regular managed fragments block mutation'
elif [ "$?" -eq 2 ] \
   && grep -q 'could not be read or safely parsed' "$case_dir/err" \
   && ! grep -Eq 'marketplace (add|update)|plugin (install|update|uninstall)' "$case_log"; then
  ok 'unreadable or non-regular managed fragments block before mutation'
else
  not_ok 'unreadable or non-regular managed fragments block before mutation'
fi

for invalid_trailing_action in status install; do
  new_case "claude_managed_base_trailing_malformed_${invalid_trailing_action}"
  add_host claude
  export AG_PLUGIN_TEST_MARKETPLACE=ok AG_PLUGIN_TEST_INSTALLED=0
  write_managed_base '{"enabledPlugins":{"agent-guard@agent-guard":true}}'
  write_managed_fragment trailing '{not-json'
  if run_guard plugin "$invalid_trailing_action" --host claude; then
    not_ok "Claude $invalid_trailing_action validates fragments after a managed base match"
  elif [ "$?" -eq 2 ] \
     && grep -q 'could not be read or safely parsed' "$case_dir/err" \
     && ! grep -Eq 'marketplace (add|update)|plugin (install|update|uninstall)' "$case_log"; then
    ok "Claude $invalid_trailing_action fails closed on a malformed trailing managed fragment"
  else
    not_ok "Claude $invalid_trailing_action fails closed on a malformed trailing managed fragment"
  fi
done

new_case claude_update
add_host claude
export AG_PLUGIN_TEST_MARKETPLACE=ok AG_PLUGIN_TEST_INSTALLED=project_old
if run_guard plugin update --host claude --scope project \
   && tail -n 2 "$case_log" | sed 's/^claude //' >"$case_dir/tail" \
   && printf '%s\n' 'plugin marketplace update agent-guard' \
      'plugin update agent-guard@agent-guard --scope project' >"$case_dir/expected" \
   && cmp -s "$case_dir/expected" "$case_dir/tail"; then
  ok 'Claude update refreshes the marketplace before the scoped plugin'
else
  not_ok 'Claude update refreshes the marketplace before the scoped plugin'
fi

new_case claude_project_status_absent
add_host claude
export AG_PLUGIN_TEST_MARKETPLACE=ok AG_PLUGIN_TEST_INSTALLED=old
if run_guard plugin status --host claude --scope project \
   && grep -q '^claude: not installed' "$case_dir/out"; then
  ok 'Claude status reports the requested project scope absent when only user scope is installed'
else
  not_ok 'Claude status reports the requested project scope absent when only user scope is installed'
fi

new_case claude_project_install
add_host claude
export AG_PLUGIN_TEST_MARKETPLACE=ok AG_PLUGIN_TEST_INSTALLED=1
if run_guard plugin install --host claude --scope project \
   && grep -Fxq 'claude plugin install agent-guard@agent-guard --scope project' "$case_log" \
   && ! grep -q 'already installed' "$case_dir/out"; then
  ok 'a user-scoped Claude install does not suppress project-scoped installation'
else
  not_ok 'a user-scoped Claude install does not suppress project-scoped installation'
fi

new_case claude_project_update_absent
add_host claude
export AG_PLUGIN_TEST_MARKETPLACE=ok AG_PLUGIN_TEST_INSTALLED=1
if run_guard plugin update --host claude --scope project; then
  not_ok 'Claude project update rejects a user-only installation'
elif grep -q 'plugin is not installed' "$case_dir/err" \
   && ! grep -Eq 'marketplace update|plugin update' "$case_log"; then
  ok 'Claude project update reports absent when only user scope is installed'
else
  not_ok 'Claude project update reports absent when only user scope is installed'
fi

new_case claude_project_uninstall_absent
add_host claude
export AG_PLUGIN_TEST_MARKETPLACE=ok AG_PLUGIN_TEST_INSTALLED=1
if run_guard plugin uninstall --host claude --scope project \
   && grep -q 'not installed' "$case_dir/out" \
   && ! grep -q 'plugin uninstall' "$case_log"; then
  ok 'Claude project uninstall is a no-op when only user scope is installed'
else
  not_ok 'Claude project uninstall is a no-op when only user scope is installed'
fi

new_case codex_update
add_host codex
export AG_PLUGIN_TEST_MARKETPLACE=ok AG_PLUGIN_TEST_INSTALLED=old
if run_guard plugin update --host codex \
   && tail -n 2 "$case_log" | sed 's/^codex //' >"$case_dir/tail" \
   && printf '%s\n' "plugin marketplace add JeongJaeSoon/agent-guard@$CLI_TAG" \
      'plugin marketplace upgrade agent-guard' >"$case_dir/expected" \
   && cmp -s "$case_dir/expected" "$case_dir/tail"; then
  ok 'Codex update delegates to marketplace upgrade'
else
  not_ok 'Codex update delegates to marketplace upgrade'
fi

for update_host in claude codex; do
  new_case "${update_host}_update_partial_failure"
  add_host "$update_host"
  export AG_PLUGIN_TEST_MARKETPLACE=ok AG_PLUGIN_TEST_INSTALLED=old
  case "$update_host" in
    claude) export AG_PLUGIN_TEST_FAIL='claude:plugin update' ;;
    codex) export AG_PLUGIN_TEST_FAIL='codex:plugin marketplace upgrade' ;;
  esac
  if run_guard plugin update --host "$update_host"; then
    not_ok "$update_host update reports a partial manager failure"
  elif grep -q "marketplace remains pinned to $CLI_TAG" "$case_dir/err" \
     && grep -q "safe to retry 'agent-guard plugin update --host $update_host'" "$case_dir/err"; then
    ok "$update_host update reports retained pin and a safe retry"
  else
    not_ok "$update_host update reports a partial manager failure"
  fi
done

new_case codex_scope
add_host codex
if run_guard plugin install --host codex --scope project; then
  not_ok 'Codex rejects non-user plugin scope'
elif [ "$?" -eq 2 ] && [ ! -s "$case_log" ]; then
  ok 'Codex rejects non-user plugin scope before manager calls'
else
  not_ok 'Codex rejects non-user plugin scope before manager calls'
fi

new_case all_partial
add_host claude
add_host codex
export AG_PLUGIN_TEST_FAIL='claude:plugin install'
if run_guard plugin install --host all; then
  not_ok 'all-host install reports a partial failure'
elif grep -Fxq 'codex plugin add agent-guard@agent-guard' "$case_log"; then
  ok 'all-host install continues to Codex after a Claude failure and exits nonzero'
else
  not_ok 'all-host install continues to Codex after a Claude failure and exits nonzero'
fi

new_case uninstall_noop
add_host codex
if run_guard plugin uninstall --host codex \
   && grep -q 'not installed' "$case_dir/out" \
   && ! grep -q 'plugin remove' "$case_log"; then
  ok 'uninstall is idempotent when the plugin is absent'
else
  not_ok 'uninstall is idempotent when the plugin is absent'
fi

# --- release staleness: status and the update no-op only print, never mutate ---

new_case status_newer_release
add_host claude
mock_release_curl "$NEWER_TAG"
export AG_PLUGIN_TEST_MARKETPLACE=ok AG_PLUGIN_TEST_INSTALLED=1
if run_guard plugin status --host claude \
   && grep -Fxq "claude: installed, enabled (version $CLI_VERSION, marketplace configured at $CLI_TAG)" "$case_dir/out" \
   && grep -Fxq "claude: latest release $NEWER_TAG; this CLI is $CLI_VERSION" "$case_dir/out"; then
  ok 'status reports a newer release behind the pinned marketplace'
else
  not_ok 'status reports a newer release behind the pinned marketplace'
fi

new_case status_current_release
add_host codex
mock_release_curl "$CLI_TAG"
export AG_PLUGIN_TEST_MARKETPLACE=ok AG_PLUGIN_TEST_INSTALLED=1
if run_guard plugin status --host codex \
   && grep -Fxq "codex: latest release $CLI_TAG" "$case_dir/out" \
   && ! grep -q 'this CLI is' "$case_dir/out"; then
  ok 'status reports the latest release without a staleness claim when it matches the CLI'
else
  not_ok 'status reports the latest release without a staleness claim when it matches the CLI'
fi

new_case status_older_release
add_host claude
mock_release_curl "$OLD_TAG"
export AG_PLUGIN_TEST_MARKETPLACE=ok AG_PLUGIN_TEST_INSTALLED=1
if run_guard plugin status --host claude \
   && grep -Fxq "claude: latest release $OLD_TAG" "$case_dir/out" \
   && ! grep -q 'this CLI is' "$case_dir/out"; then
  ok 'status prints an older published release verbatim for a build ahead of it'
else
  not_ok 'status prints an older published release verbatim for a build ahead of it'
fi

new_case status_release_unknown
add_host claude
mock_release_curl ''
export AG_PLUGIN_TEST_MARKETPLACE=ok AG_PLUGIN_TEST_INSTALLED=1
if run_guard plugin status --host claude \
   && grep -Fxq 'claude: latest release unknown' "$case_dir/out" \
   && ! grep -q 'releases/tag' "$case_dir/out" "$case_dir/err"; then
  ok 'status reports an unknown latest release when the lookup fails'
else
  not_ok 'status reports an unknown latest release when the lookup fails'
fi

new_case status_release_check_off
add_host claude
mock_release_curl "$NEWER_TAG"
export AGENT_GUARD_RELEASE_CHECK=off
export AG_PLUGIN_TEST_MARKETPLACE=ok AG_PLUGIN_TEST_INSTALLED=1
if run_guard plugin status --host claude \
   && grep -Fxq 'claude: latest release unknown' "$case_dir/out" \
   && ! grep -q '^curl ' "$case_log"; then
  ok 'status skips the release lookup when AGENT_GUARD_RELEASE_CHECK=off'
else
  not_ok 'status skips the release lookup when AGENT_GUARD_RELEASE_CHECK=off'
fi

new_case status_all_hosts_single_lookup
add_host claude
add_host codex
mock_release_curl "$NEWER_TAG"
export AG_PLUGIN_TEST_MARKETPLACE=ok AG_PLUGIN_TEST_INSTALLED=1
if run_guard plugin status --host all \
   && grep -Fxq "claude: latest release $NEWER_TAG; this CLI is $CLI_VERSION" "$case_dir/out" \
   && grep -Fxq "codex: latest release $NEWER_TAG; this CLI is $CLI_VERSION" "$case_dir/out" \
   && [ "$(grep -c '^curl ' "$case_log")" -eq 1 ]; then
  ok 'all-host status reports both hosts from a single release lookup'
else
  not_ok 'all-host status reports both hosts from a single release lookup'
fi

new_case status_release_missing_marketplace
add_host claude
mock_release_curl "$NEWER_TAG"
if run_guard plugin status --host claude \
   && ! grep -q 'latest release' "$case_dir/out" \
   && ! grep -q '^curl ' "$case_log"; then
  ok 'status does not look up releases without an agent-guard marketplace'
else
  not_ok 'status does not look up releases without an agent-guard marketplace'
fi

new_case update_noop_newer_project
add_host claude
mock_release_curl "$NEWER_TAG"
export AG_PLUGIN_TEST_MARKETPLACE=ok AG_PLUGIN_TEST_INSTALLED=project
if run_guard plugin update --host claude --scope project \
   && grep -q 'already matches this CLI' "$case_dir/out" \
   && grep -Fxq "agent-guard: this CLI is $CLI_VERSION and can only pin the marketplace to $CLI_TAG; to move to $NEWER_TAG, run:" "$case_dir/err" \
   && grep -Fxq '  claude plugin marketplace remove agent-guard --scope project' "$case_dir/err" \
   && grep -Fxq "  claude plugin marketplace add JeongJaeSoon/agent-guard@$NEWER_TAG --scope project" "$case_dir/err" \
   && grep -Fxq '  claude plugin install agent-guard@agent-guard --scope project' "$case_dir/err" \
   && grep -q 'marketplace removal also removes its installed plugin; restart the host afterwards' "$case_dir/err" \
   && ! grep -Eq 'marketplace remove|marketplace update|plugin install|plugin update' "$case_log"; then
  ok 'update no-op prints the Claude forward commands for the scope without mutating'
else
  not_ok 'update no-op prints the Claude forward commands for the scope without mutating'
fi

new_case update_noop_newer_codex
add_host codex
mock_release_curl "$NEWER_TAG"
export AG_PLUGIN_TEST_MARKETPLACE=ok AG_PLUGIN_TEST_INSTALLED=1
if run_guard plugin update --host codex \
   && grep -q 'already matches this CLI' "$case_dir/out" \
   && grep -Fxq '  codex plugin marketplace remove agent-guard' "$case_dir/err" \
   && grep -Fxq "  codex plugin marketplace add JeongJaeSoon/agent-guard@$NEWER_TAG" "$case_dir/err" \
   && grep -Fxq '  codex plugin add agent-guard@agent-guard' "$case_dir/err" \
   && ! grep -q -- '--scope' "$case_dir/err" \
   && ! grep -Eq 'marketplace remove|marketplace upgrade|plugin add agent-guard' "$case_log"; then
  ok 'update no-op prints the Codex forward commands without mutating'
else
  not_ok 'update no-op prints the Codex forward commands without mutating'
fi

new_case update_noop_release_unknown
add_host claude
mock_release_curl ''
export AG_PLUGIN_TEST_MARKETPLACE=ok AG_PLUGIN_TEST_INSTALLED=1
if run_guard plugin update --host claude \
   && grep -q 'already matches this CLI' "$case_dir/out" \
   && grep -Fxq '  claude plugin marketplace add JeongJaeSoon/agent-guard@v<X.Y.Z> --scope user' "$case_dir/err" \
   && grep -Fq 'https://github.com/JeongJaeSoon/agent-guard/releases' "$case_dir/err" \
   && ! grep -Eq 'marketplace remove|plugin install' "$case_log"; then
  ok 'update no-op prints a placeholder forward block when the release lookup fails'
else
  not_ok 'update no-op prints a placeholder forward block when the release lookup fails'
fi

new_case update_noop_current_release
add_host claude
mock_release_curl "$CLI_TAG"
export AG_PLUGIN_TEST_MARKETPLACE=ok AG_PLUGIN_TEST_INSTALLED=1
if run_guard plugin update --host claude \
   && grep -q 'already matches this CLI' "$case_dir/out" \
   && grep -Fxq "agent-guard: $CLI_TAG matches the latest release $CLI_TAG" "$case_dir/err" \
   && ! grep -q 'marketplace remove' "$case_dir/err" \
   && ! grep -Eq 'marketplace remove|plugin install' "$case_log"; then
  ok 'update no-op reports the pinned release as latest'
else
  not_ok 'update no-op reports the pinned release as latest'
fi

new_case update_noop_older_release
add_host claude
mock_release_curl "$OLD_TAG"
export AG_PLUGIN_TEST_MARKETPLACE=ok AG_PLUGIN_TEST_INSTALLED=1
if run_guard plugin update --host claude \
   && grep -q 'already matches this CLI' "$case_dir/out" \
   && grep -Fxq "agent-guard: latest release is $OLD_TAG" "$case_dir/err" \
   && ! grep -Eq 'matches the latest|marketplace remove' "$case_dir/err" \
   && ! grep -Eq 'marketplace remove|plugin install' "$case_log"; then
  ok 'update no-op prints an older published release verbatim without a forward block'
else
  not_ok 'update no-op prints an older published release verbatim without a forward block'
fi

# --- Codex hook trust (app-server hooks/list) --------------------------------

trust_case() {
  new_case "$1"
  add_host codex
  export AGENT_GUARD_CODEX_TRUST_CHECK=on AG_PLUGIN_TEST_TRUST="$2"
  export AG_PLUGIN_TEST_TRUST_REQUESTS="$case_dir/requests"
  export AG_PLUGIN_TEST_TRUST_PIDFILE="$case_dir/server-pids"
  export AGENT_GUARD_GITLEAKS_BIN="$ROOT/tests/fixtures/mock-gitleaks"
  : >"$case_dir/requests"
}

run_doctor_here() {
  (cd "$case_dir" && run_guard doctor)
}

case_cwd() { (cd "$case_dir" && pwd -P); }

no_server_left() {
  [ -s "$case_dir/server-pids" ] || return 1
  while IFS= read -r server_pid; do
    kill -0 "$server_pid" 2>/dev/null && return 1
  done <"$case_dir/server-pids"
  return 0
}

trust_line() { grep 'codex hook trust:' "$case_dir/err"; }

new_case doctor_trust_baseline
export AGENT_GUARD_GITLEAKS_BIN="$ROOT/tests/fixtures/mock-gitleaks"
if run_doctor_here && ! grep -q 'codex hook trust' "$case_dir/err"; then
  ok 'doctor baseline passes and runs no Codex trust check without codex on PATH'
else
  not_ok 'doctor baseline passes and runs no Codex trust check without codex on PATH'
  sed 's/^/  stderr: /' "$case_dir/err"
fi

trust_case doctor_trust_ok trusted
if run_doctor_here \
   && trust_line | grep -Fq "codex hook trust: ok (agent-guard hooks are trusted and enabled for $(case_cwd);" \
   && grep -Fq 'host hook protection: unverified' "$case_dir/err" \
   && sed -n 1p "$case_dir/requests" | grep -Fq '"method":"initialize"' \
   && sed -n 2p "$case_dir/requests" | grep -Fq '"method":"initialized"' \
   && sed -n 3p "$case_dir/requests" | jq -e --arg cwd "$(case_cwd)" '.method == "hooks/list" and .params.cwds == [$cwd]' >/dev/null \
   && grep -Fxq 'codex app-server' "$case_log" \
   && no_server_left; then
  ok 'doctor reports trusted agent-guard Codex hooks for the current directory and keeps dispatch unverified'
else
  not_ok 'doctor reports trusted agent-guard Codex hooks for the current directory and keeps dispatch unverified'
  sed 's/^/  stderr: /' "$case_dir/err"
  sed 's/^/  request: /' "$case_dir/requests"
fi

trust_case doctor_trust_managed managed
if run_doctor_here && trust_line | grep -Fq 'codex hook trust: ok'; then
  ok 'doctor treats managed agent-guard Codex hooks as trusted'
else
  not_ok 'doctor treats managed agent-guard Codex hooks as trusted'
fi

for trust_mode in modified untrusted mixed; do
  trust_case "doctor_trust_$trust_mode" "$trust_mode"
  case "$trust_mode" in
    mixed) want='(postToolUse, stop)' ;;
    *) want='(preToolUse, postToolUse, sessionStart, userPromptSubmit, stop)' ;;
  esac
  run_doctor_here
  status=$?
  if [ "$status" -eq 1 ] \
     && trust_line | grep -Fq "codex hook trust: needs review for $(case_cwd) $want; Codex skips these agent-guard hooks until they are trusted again" \
     && grep -Fq "choose 'Review hooks' at 'Hooks need review'" "$case_dir/err" \
     && grep -Fq 'Source is agent-guard@agent-guard' "$case_dir/err" \
     && grep -Fq 'restart Codex sessions that were already running' "$case_dir/err" \
     && grep -Fq 'agent-guard: release:' "$case_dir/err"; then
    ok "doctor fails and gives re-trust steps for $trust_mode agent-guard Codex hooks"
  else
    not_ok "doctor fails and gives re-trust steps for $trust_mode agent-guard Codex hooks (status $status)"
    sed 's/^/  stderr: /' "$case_dir/err"
  fi
done

trust_case doctor_trust_disabled disabled
run_doctor_here
status=$?
if [ "$status" -eq 1 ] \
   && trust_line | grep -Fq "codex hook trust: disabled for $(case_cwd) (preToolUse);" \
   && ! grep -q 'needs review' "$case_dir/err"; then
  ok 'doctor fails when Codex has an agent-guard hook turned off'
else
  not_ok "doctor fails when Codex has an agent-guard hook turned off (status $status)"
  sed 's/^/  stderr: /' "$case_dir/err"
fi

trust_case doctor_trust_none none
if run_doctor_here \
   && trust_line | grep -Fq "codex hook trust: Codex loads no agent-guard hooks for $(case_cwd) (plugin not installed or not enabled for Codex)"; then
  ok 'doctor reports no loaded agent-guard Codex hooks without failing and ignores a modified non-agent-guard hook'
else
  not_ok 'doctor reports no loaded agent-guard Codex hooks without failing and ignores a modified non-agent-guard hook'
  sed 's/^/  stderr: /' "$case_dir/err"
fi

for trust_mode in missing duplicate unknown badtype errors errors-none malformed corrupt-tail init-error silent; do
  trust_case "doctor_trust_$trust_mode" "$trust_mode"
  case "$trust_mode" in
    missing|duplicate) want='expected agent-guard hooks are missing or duplicated' ;;
    unknown) want='unknown hook trust status' ;;
    badtype) want='unexpected agent-guard hook entry' ;;
    errors|errors-none) want='Codex reported hook configuration errors' ;;
    malformed|corrupt-tail) want='unreadable Codex reply' ;;
    init-error|silent) want='Codex app-server did not initialize' ;;
  esac
  # No reply these servers send completes, so the query lasts its whole limit.
  case "$trust_mode" in
    malformed|silent) export AG_PLUGIN_TEST_CODEX_TRUST_TIMEOUT=3 ;;
  esac
  run_doctor_here
  status=$?
  if [ "$status" -eq 0 ] \
     && trust_line | grep -Fxq "agent-guard: codex hook trust: unverified ($want)" \
     && ! grep -q 'codex hook trust: ok' "$case_dir/err"; then
    ok "doctor reports $trust_mode Codex replies as unverified, never ok, without changing its exit status"
  else
    not_ok "doctor reports $trust_mode Codex replies as unverified, never ok, without changing its exit status (status $status)"
    sed 's/^/  stderr: /' "$case_dir/err"
  fi
done

trust_case doctor_trust_errors_modified errors-modified
run_doctor_here
status=$?
if [ "$status" -eq 1 ] && trust_line | grep -Fq 'codex hook trust: needs review for'; then
  ok 'doctor still fails on agent-guard Codex hooks that need review when Codex also reports hook errors'
else
  not_ok "doctor still fails on agent-guard Codex hooks that need review when Codex also reports hook errors (status $status)"
  sed 's/^/  stderr: /' "$case_dir/err"
fi

# The launcher can be interrupted before it calls setsid, so no probe group
# exists yet; exit cleanup must still end the probe instead of waiting on it.
trust_case doctor_trust_signal_before_group trusted
printf '%s\n' '#!/bin/sh' \
  'case "$*" in *agent-guard-codex-trust*) printf "%s\n" "$$" >"$AG_TEST_LAUNCHER_PID"; exec sleep 30 ;; esac' \
  "exec perl -MPOSIX -e 'POSIX::setsid() >= 0 or exit 125; exec @ARGV; exit 126' \"\$@\"" \
  >"$case_bin/setsid"
chmod +x "$case_bin/setsid"
export AG_TEST_LAUNCHER_PID="$case_dir/launcher-pid"
(cd "$case_dir" && PATH="$case_bin:/usr/bin:/bin" exec "$GUARD" doctor >"$case_dir/out" 2>"$case_dir/err") &
guard_pid=$!
tries=0
while [ ! -s "$AG_TEST_LAUNCHER_PID" ] && [ "$tries" -lt 100 ]; do
  sleep 0.1; tries=$((tries + 1))
done
kill -TERM "$guard_pid" 2>/dev/null
tries=0
while kill -0 "$guard_pid" 2>/dev/null && [ "$tries" -lt 50 ]; do
  sleep 0.1; tries=$((tries + 1))
done
guard_done=1
if kill -0 "$guard_pid" 2>/dev/null; then
  guard_done=0
  kill -KILL "$guard_pid" 2>/dev/null
fi
wait "$guard_pid" 2>/dev/null
status=$?
launcher_pid=$(cat "$AG_TEST_LAUNCHER_PID" 2>/dev/null)
launcher_gone=0
if [ -n "$launcher_pid" ]; then
  if kill -0 "$launcher_pid" 2>/dev/null; then
    kill -KILL "$launcher_pid" 2>/dev/null
  else
    launcher_gone=1
  fi
fi
if [ "$guard_done" -eq 1 ] && [ "$status" -eq 143 ] && [ "$launcher_gone" -eq 1 ]; then
  ok 'doctor interrupted before the Codex probe group exists exits promptly and ends the probe'
else
  not_ok "doctor interrupted before the Codex probe group exists exits promptly and ends the probe (done $guard_done, status $status, launcher_gone $launcher_gone)"
fi
unset AG_TEST_LAUNCHER_PID

trust_case doctor_trust_init_error_order init-error
run_doctor_here
if ! grep -Fq 'hooks/list' "$case_dir/requests" && grep -Fq '"method":"initialize"' "$case_dir/requests"; then
  ok 'doctor sends hooks/list only after a successful initialize reply'
else
  not_ok 'doctor sends hooks/list only after a successful initialize reply'
  sed 's/^/  request: /' "$case_dir/requests"
fi

trust_case doctor_trust_off modified
export AGENT_GUARD_CODEX_TRUST_CHECK=off
if run_doctor_here \
   && trust_line | grep -Fxq 'agent-guard: codex hook trust: unverified (check skipped by AGENT_GUARD_CODEX_TRUST_CHECK=off)' \
   && ! grep -Fq 'app-server' "$case_log"; then
  ok 'AGENT_GUARD_CODEX_TRUST_CHECK=off skips the Codex query and reports unverified'
else
  not_ok 'AGENT_GUARD_CODEX_TRUST_CHECK=off skips the Codex query and reports unverified'
  sed 's/^/  stderr: /' "$case_dir/err"
fi

trust_case doctor_trust_keeps_failure modified
export AGENT_GUARD_GITLEAKS_BIN="$case_dir/no-gitleaks"
run_doctor_here
status=$?
if [ "$status" -eq 1 ] && trust_line | grep -Fq 'needs review'; then
  ok 'doctor keeps a dependency failure status when Codex hooks also need review'
else
  not_ok "doctor keeps a dependency failure status when Codex hooks also need review (status $status)"
fi

for trust_mode in hang linger spawn; do
  trust_case "doctor_trust_$trust_mode" "$trust_mode"
  # The client's deadline is a whole second, so a limit of 1 leaves a server
  # that does answer anywhere from a full second to none. Only hang has to run
  # into the limit; linger still ends at limit + 3 (watchdog), inside the bound.
  case "$trust_mode" in
    hang) trust_limit=1 ;;
    linger) trust_limit=2 ;;
    *) trust_limit=3 ;;
  esac
  export AG_PLUGIN_TEST_CODEX_TRUST_TIMEOUT=$trust_limit AG_PLUGIN_TEST_TRUST_CHILD="$case_dir/child-pid"
  case "$trust_mode" in
    hang) want='agent-guard: codex hook trust: unverified (Codex app-server did not initialize)' ;;
    *) want="agent-guard: codex hook trust: ok (agent-guard hooks are trusted and enabled for $(case_cwd); configuration snapshot, not observed dispatch)" ;;
  esac
  started=$(date +%s)
  run_doctor_here
  elapsed=$(( $(date +%s) - started ))
  child_gone=1
  if [ "$trust_mode" = spawn ]; then
    child_gone=0
    [ -s "$case_dir/child-pid" ] && ! kill -0 "$(cat "$case_dir/child-pid")" 2>/dev/null && child_gone=1
  fi
  if [ "$elapsed" -le 8 ] \
     && trust_line | grep -Fxq "$want" \
     && no_server_left && [ "$child_gone" -eq 1 ]; then
    ok "doctor bounds a $trust_mode Codex app-server and leaves no probe process behind"
  else
    not_ok "doctor bounds a $trust_mode Codex app-server and leaves no probe process behind (elapsed ${elapsed}s, child_gone $child_gone)"
    sed 's/^/  stderr: /' "$case_dir/err"
  fi
  reap_trust_servers
done

# SIGKILL of the guard's whole process group runs no exit cleanup and takes
# the guard's watchdog with it, as when a runner ends a timed-out job. The
# probe has a session of its own, so it has to end itself. In hang_term the
# watchdog had already sent TERM to the probe group when it was killed.
for killed_case in hang linger hang_term spawn; do
  trust_mode=${killed_case%_term}
  trust_case "doctor_trust_${killed_case}_guard_killed" "$trust_mode"
  export AG_PLUGIN_TEST_TRUST_CHILD="$case_dir/child-pid"
  # As in the loop above, hang never answers and linger has to answer before
  # the limit. spawn answers only once the guard is gone, and then has to end
  # long before its limit: the server exits by itself, so the deadline must
  # not be what ends the helper it leaves behind.
  case "$trust_mode" in
    hang) export AG_PLUGIN_TEST_CODEX_TRUST_TIMEOUT=1 ;;
    linger) export AG_PLUGIN_TEST_CODEX_TRUST_TIMEOUT=2 ;;
    spawn) export AG_PLUGIN_TEST_CODEX_TRUST_TIMEOUT=30 AG_PLUGIN_TEST_TRUST_GATE="$case_dir/gate" ;;
  esac
  # SIGKILL skips the guard's exit trap, so its run directory has to be where
  # this suite removes it.
  (cd "$case_dir" && PATH="$case_bin:/usr/bin:/bin" && TMPDIR=$case_dir && export PATH TMPDIR \
    && exec_as_group_leader "$GUARD" doctor >"$case_dir/out" 2>"$case_dir/err") &
  guard_pid=$!
  # linger blocks only after it has read hooks/list.
  tries=0
  until [ -s "$case_dir/server-pids" ] \
      && { [ "$trust_mode" != linger ] || grep -Fq '"method":"hooks/list"' "$case_dir/requests"; }; do
    [ "$tries" -lt 100 ] || break
    sleep 0.1; tries=$((tries + 1))
  done
  probe_group=$(sed -n 2p "$case_dir/server-pids")
  # Without a guard that leads its own group and a probe in another one, the
  # kill below would not be the case under test.
  staged=0
  case "$probe_group" in
    ''|*[!0-9]*|"$guard_pid") ;;
    *) [ "$tries" -lt 100 ] && kill -0 -"$guard_pid" 2>/dev/null && kill -0 -"$probe_group" 2>/dev/null && staged=1 ;;
  esac
  if [ "$staged" -eq 1 ]; then
    kill -KILL -"$guard_pid" 2>/dev/null
  else
    kill -KILL "$guard_pid" 2>/dev/null
  fi
  # The server is released before the killed guard is reaped: the probe must
  # not take a PID that still exists for a guard that will clean up.
  case "$staged:$killed_case" in
    1:hang_term) kill -TERM -"$probe_group" 2>/dev/null ;;
    1:spawn) : >"$case_dir/gate" ;;
  esac
  wait "$guard_pid" 2>/dev/null
  status=$?
  # A killed process stays visible to kill -0 until its new parent reaps it,
  # so the group can be empty a moment before its last PID is gone.
  left=1
  tries=0
  while [ "$staged" -eq 1 ] && [ "$tries" -lt 100 ]; do
    if ! kill -0 -"$probe_group" 2>/dev/null && no_server_left \
       && { [ "$trust_mode" != spawn ] \
            || { [ -s "$case_dir/child-pid" ] && ! kill -0 "$(cat "$case_dir/child-pid")" 2>/dev/null; }; }; then
      left=0
      break
    fi
    sleep 0.1; tries=$((tries + 1))
  done
  if [ "$staged" -eq 1 ] && [ "$status" -eq 137 ] && [ "$left" -eq 0 ]; then
    ok "a $killed_case Codex app-server ends with its probe group after the guard's process group is killed"
  else
    not_ok "a $killed_case Codex app-server ends with its probe group after the guard's process group is killed (staged $staged, guard status $status, waited $tries)"
    # Staging saw this group seconds ago; end it here even where ps is denied.
    [ "$staged" -eq 0 ] || kill -KILL -"$probe_group" 2>/dev/null
  fi
  reap_trust_servers
done

trust_case plugin_status_trust modified
export AG_PLUGIN_TEST_MARKETPLACE=ok AG_PLUGIN_TEST_INSTALLED=1
if run_guard plugin status --host codex \
   && grep -Fq 'codex: installed, enabled' "$case_dir/out" \
   && trust_line | grep -Fq 'codex hook trust: needs review'; then
  ok 'plugin status keeps its exit status and warns about Codex hooks that need review'
else
  not_ok 'plugin status keeps its exit status and warns about Codex hooks that need review'
  sed 's/^/  stderr: /' "$case_dir/err"
fi

trust_case plugin_status_trust_disabled_plugin modified
export AG_PLUGIN_TEST_MARKETPLACE=ok AG_PLUGIN_TEST_INSTALLED=disabled
if run_guard plugin status --host codex \
   && ! grep -Fq 'app-server' "$case_log" && ! trust_line >/dev/null; then
  ok 'plugin status skips the Codex trust query for a disabled plugin'
else
  not_ok 'plugin status skips the Codex trust query for a disabled plugin'
fi

trust_case plugin_status_trust_none none
export AG_PLUGIN_TEST_MARKETPLACE=ok AG_PLUGIN_TEST_INSTALLED=1
if run_guard plugin status --host codex \
   && trust_line | grep -Fq 'codex hook trust: unverified (Codex lists no agent-guard hooks for'; then
  ok 'plugin status treats an installed plugin with no listed hooks as unverified'
else
  not_ok 'plugin status treats an installed plugin with no listed hooks as unverified'
  sed 's/^/  stderr: /' "$case_dir/err"
fi

trust_case plugin_install_trust untrusted
if run_guard plugin install --host codex \
   && grep -Fxq 'codex plugin add agent-guard@agent-guard' "$case_log" \
   && grep -Fxq 'codex app-server' "$case_log" \
   && [ "$(grep -n -Fx 'codex app-server' "$case_log" | cut -d: -f1)" -gt "$(grep -n -Fx 'codex plugin add agent-guard@agent-guard' "$case_log" | cut -d: -f1)" ] \
   && trust_line | grep -Fq 'needs review'; then
  ok 'plugin install checks Codex hook trust after installing and keeps its exit status'
else
  not_ok 'plugin install checks Codex hook trust after installing and keeps its exit status'
  sed 's/^/  stderr: /' "$case_dir/err"
fi

trust_case plugin_install_noop_trust modified
export AG_PLUGIN_TEST_MARKETPLACE=ok AG_PLUGIN_TEST_INSTALLED=1
if run_guard plugin install --host codex \
   && grep -q 'already installed and enabled' "$case_dir/out" \
   && trust_line | grep -Fq 'needs review'; then
  ok 'plugin install no-op still reports Codex hooks that need review'
else
  not_ok 'plugin install no-op still reports Codex hooks that need review'
fi

trust_case plugin_update_noop_trust modified
export AG_PLUGIN_TEST_MARKETPLACE=ok AG_PLUGIN_TEST_INSTALLED=1
if run_guard plugin update --host codex \
   && grep -q 'already matches this CLI' "$case_dir/out" \
   && trust_line | grep -Fq 'needs review'; then
  ok 'plugin update no-op still reports Codex hooks that need review'
else
  not_ok 'plugin update no-op still reports Codex hooks that need review'
  sed 's/^/  stderr: /' "$case_dir/err"
fi

trust_case plugin_update_trust modified
export AG_PLUGIN_TEST_MARKETPLACE=ok AG_PLUGIN_TEST_INSTALLED=old
if run_guard plugin update --host codex \
   && [ "$(grep -n -Fx 'codex app-server' "$case_log" | cut -d: -f1)" -gt "$(grep -n -F 'codex plugin marketplace upgrade' "$case_log" | cut -d: -f1)" ] \
   && trust_line | grep -Fq 'needs review'; then
  ok 'plugin update checks Codex hook trust after the upgrade and keeps its exit status'
else
  not_ok 'plugin update checks Codex hook trust after the upgrade and keeps its exit status'
  sed 's/^/  stderr: /' "$case_dir/err"
fi

trust_case plugin_update_failed_trust modified
export AG_PLUGIN_TEST_MARKETPLACE=ok AG_PLUGIN_TEST_INSTALLED=old
export AG_PLUGIN_TEST_FAIL='codex:plugin marketplace upgrade'
if ! run_guard plugin update --host codex && ! grep -Fq 'app-server' "$case_log"; then
  ok 'a failed plugin update reports the failure without a Codex trust query'
else
  not_ok 'a failed plugin update reports the failure without a Codex trust query'
fi

# The expected event set must track the Codex manifest the plugin ships.
expected_events=$(sed -n "s/^CODEX_TRUST_EVENTS='\(.*\)'\$/\1/p" "$GUARD" | jq -c 'sort')
manifest_events=$(jq -c '[.hooks | keys[] | (.[0:1] | ascii_downcase) + .[1:]] | sort' "$ROOT/plugins/agent-guard/hooks.json" 2>/dev/null)
if [ -n "$expected_events" ] && [ "$expected_events" = "$manifest_events" ]; then
  ok 'the expected Codex trust events match the shipped Codex hooks manifest'
else
  not_ok "the expected Codex trust events match the shipped Codex hooks manifest ($expected_events vs $manifest_events)"
fi

# --- status --check: exit 1 only on version or marketplace-pin drift ---

for check_host in claude codex; do
  new_case "${check_host}_check_no_drift"
  add_host "$check_host"
  export AG_PLUGIN_TEST_MARKETPLACE=ok AG_PLUGIN_TEST_INSTALLED=1
  if run_guard plugin status --check --host "$check_host"; then
    ok "$check_host status --check exits 0 without drift"
  else
    not_ok "$check_host status --check exits 0 without drift"
  fi

  new_case "${check_host}_check_drift"
  add_host "$check_host"
  export AG_PLUGIN_TEST_MARKETPLACE=ok AG_PLUGIN_TEST_INSTALLED=old
  if run_guard plugin status --check --host "$check_host"; then
    not_ok "$check_host status --check exits 1 on version drift"
  elif [ "$?" -eq 1 ] && grep -q "expected $CLI_VERSION" "$case_dir/out"; then
    ok "$check_host status --check exits 1 on version drift"
  else
    not_ok "$check_host status --check exits 1 on version drift"
  fi

  new_case "${check_host}_drift_without_check"
  add_host "$check_host"
  export AG_PLUGIN_TEST_MARKETPLACE=ok AG_PLUGIN_TEST_INSTALLED=old
  if run_guard plugin status --host "$check_host" \
     && grep -q "expected $CLI_VERSION" "$case_dir/out"; then
    ok "$check_host status without --check keeps exit 0 on drift"
  else
    not_ok "$check_host status without --check keeps exit 0 on drift"
  fi
done

new_case claude_check_marketplace_drift
add_host claude
export AG_PLUGIN_TEST_MARKETPLACE=old AG_PLUGIN_TEST_INSTALLED=1
if run_guard plugin status --check --host claude; then
  not_ok 'Claude status --check exits 1 on marketplace pin drift'
elif [ "$?" -eq 1 ] && grep -q 'marketplace drift:' "$case_dir/out"; then
  ok 'Claude status --check exits 1 on marketplace pin drift'
else
  not_ok 'Claude status --check exits 1 on marketplace pin drift'
fi

for check_action in install update uninstall; do
  new_case "check_rejected_for_$check_action"
  add_host claude
  if run_guard plugin "$check_action" --check --host claude; then
    not_ok "$check_action rejects --check"
  elif [ "$?" -eq 2 ] && [ ! -s "$case_log" ]; then
    ok "$check_action rejects --check before calling a host manager"
  else
    not_ok "$check_action rejects --check"
  fi
done

new_case check_all_mixed_drift
add_host claude
add_host codex
export AG_PLUGIN_TEST_MARKETPLACE=ok AG_PLUGIN_TEST_INSTALLED=old
if run_guard plugin status --check --host all; then
  not_ok 'status --check --host all exits 1 when hosts drift'
elif [ "$?" -eq 1 ] && [ "$(grep -c "expected $CLI_VERSION" "$case_dir/out")" -ge 2 ]; then
  ok 'status --check --host all reports every host and exits 1 on drift'
else
  not_ok 'status --check --host all exits 1 when hosts drift'
fi

printf 'plugin management: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
