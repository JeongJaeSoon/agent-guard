#!/usr/bin/env sh
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD="$ROOT/plugins/agent-guard/bin/agent-guard"
CASE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-plugin-test.XXXXXX")
trap 'rm -rf "$CASE_ROOT"' EXIT INT TERM
REAL_JQ=$(command -v jq)
pass=0
fail=0

ok() { pass=$((pass + 1)); printf 'ok - %s\n' "$1"; }
not_ok() { fail=$((fail + 1)); printf 'not ok - %s\n' "$1"; }

new_case() {
  case_name=$1
  case_dir="$CASE_ROOT/$case_name"
  case_bin="$case_dir/bin"
  case_log="$case_dir/calls"
  mkdir -p "$case_bin"
  : >"$case_log"
  ln -s "$REAL_JQ" "$case_bin/jq"
  export AG_PLUGIN_TEST_LOG="$case_log"
  export AG_PLUGIN_TEST_MARKETPLACE=absent
  export AG_PLUGIN_TEST_INSTALLED=0
  export AG_PLUGIN_TEST_FAIL=
  export AG_PLUGIN_TEST_SCHEMA=normal
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
export AG_PLUGIN_TEST_MARKETPLACE=managed AG_PLUGIN_TEST_INSTALLED=0
if run_guard plugin status --host claude \
   && grep -q 'managed by Jamf/managed settings (marketplace configured, plugin not installed)' "$case_dir/out"; then
  ok 'Claude status identifies a managed marketplace without a plugin'
else
  not_ok 'Claude status identifies a managed marketplace without a plugin'
fi

for managed_state in plugin marketplace; do
  for managed_action in install update uninstall; do
    new_case "claude_managed_${managed_state}_${managed_action}"
    add_host claude
    case "$managed_state" in
      plugin) export AG_PLUGIN_TEST_MARKETPLACE=ok AG_PLUGIN_TEST_INSTALLED=managed ;;
      marketplace) export AG_PLUGIN_TEST_MARKETPLACE=managed AG_PLUGIN_TEST_INSTALLED=0 ;;
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
