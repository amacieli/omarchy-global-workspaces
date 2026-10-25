#!/bin/bash
# Tests for bin/omarchy-global-workspaces: installs/removes the toggle file.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

require_command python3

STATE=$(mktemp -d)
trap 'rm -rf "$STATE"' EXIT
export XDG_STATE_HOME="$STATE" GWS_NO_RELOAD=1
FLAG="$STATE/omarchy/toggles/hypr/workspace-global.lua"
CLI="$ROOT/bin/omarchy-global-workspaces"

[[ $("$CLI" status) == off ]] || fail "status is off before install"
pass "status is off initially"

[[ $("$CLI" on) == on ]] || fail "on prints 'on'"
[[ -f $FLAG ]] || fail "on installs the toggle file"
[[ $("$CLI" status) == on ]] || fail "status is on after install"
pass "on installs the toggle file"

grep -q '@PLUGIN_DIR@' "$FLAG" && grep -q "^local PLUGIN_DIR = \"@PLUGIN_DIR@\"" "$FLAG" &&
  fail "installed file has the plugin path substituted"
grep -qF "local PLUGIN_DIR = \"$ROOT\"" "$FLAG" || fail "installed file points at this checkout" "$(grep -n 'PLUGIN_DIR =' "$FLAG")"
pass "installed file points at this checkout"

[[ $("$CLI" toggle) == off && ! -f $FLAG ]] || fail "toggle turns it off"
[[ $("$CLI" toggle) == on && -f $FLAG ]] || fail "toggle turns it on"
pass "toggle flips the state"

[[ $("$CLI" off) == off && ! -f $FLAG ]] || fail "off removes the toggle file"
"$CLI" off >/dev/null || fail "off is idempotent"
pass "off removes the toggle file (idempotent)"

status=0
"$CLI" bogus 2>/dev/null || status=$?
(( status == 1 )) || fail "unknown command exits 1" "got $status"
pass "unknown command exits 1"

# Symlinked invocation (e.g. from ~/.local/bin) still finds the plugin root.
ln -s "$CLI" "$STATE/gws"
"$STATE/gws" on >/dev/null
grep -qF "local PLUGIN_DIR = \"$ROOT\"" "$FLAG" || fail "symlinked invocation resolves the plugin root"
pass "symlinked invocation resolves the plugin root"
