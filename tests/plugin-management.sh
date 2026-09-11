#!/usr/bin/env sh
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD="$ROOT/plugins/agent-guard/bin/agent-guard"
CASE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-plugin-test.XXXXXX")
trap 'rm -rf "$CASE_ROOT"' EXIT INT TERM
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
  export AG_PLUGIN_TEST_LOG="$case_log"
  export AG_PLUGIN_TEST_MARKETPLACE=absent
  export AG_PLUGIN_TEST_INSTALLED=0
  export AG_PLUGIN_TEST_FAIL=
  export AG_PLUGIN_TEST_SCHEMA=normal
  export AG_PLUGIN_TEST_MODE=1
  export AG_PLUGIN_TEST_CLAUDE_MANAGED_SETTINGS_ROOT="$case_managed"
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

add_host() {
  host=$1
  cp "$ROOT/tests/fixtures/mock-plugin-manager" "$case_bin/$host"
  chmod +x "$case_bin/$host"
}

run_guard() {
  PATH="$case_bin:/usr/bin:/bin" "$GUARD" "$@" >"$case_dir/out" 2>"$case_dir/err"
}

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
   && grep -Fxq 'claude plugin marketplace add JeongJaeSoon/agent-guard --scope user' "$case_log" \
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

new_case claude_managed_plugin_status
add_host claude
export AG_PLUGIN_TEST_MARKETPLACE=ok AG_PLUGIN_TEST_INSTALLED=managed_disabled
if run_guard plugin status --host claude \
   && grep -q 'managed by Jamf/managed settings (plugin installed, disabled, version 3.4.0)' "$case_dir/out"; then
  ok 'Claude status identifies a managed disabled plugin and its version'
else
  not_ok 'Claude status identifies a managed disabled plugin and its version'
fi

new_case claude_managed_marketplace_status
add_host claude
export AG_PLUGIN_TEST_MARKETPLACE=ok AG_PLUGIN_TEST_INSTALLED=0
write_managed_base '{"extraKnownMarketplaces":{"agent-guard":{"source":{"source":"github","repo":"JeongJaeSoon/agent-guard","ref":"v3.4.0"}}}}'
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
   && grep -Fxq 'claude plugin marketplace add JeongJaeSoon/agent-guard --scope user' "$case_log" \
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
export AG_PLUGIN_TEST_MARKETPLACE=ok AG_PLUGIN_TEST_INSTALLED=project
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
export AG_PLUGIN_TEST_MARKETPLACE=ok AG_PLUGIN_TEST_INSTALLED=1
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
export AG_PLUGIN_TEST_MARKETPLACE=ok AG_PLUGIN_TEST_INSTALLED=1
if run_guard plugin update --host codex \
   && grep -Fxq 'codex plugin marketplace upgrade agent-guard' "$case_log"; then
  ok 'Codex update delegates to marketplace upgrade'
else
  not_ok 'Codex update delegates to marketplace upgrade'
fi

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

printf 'plugin management: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
