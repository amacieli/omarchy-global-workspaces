#!/bin/bash
# Step 1: launcher resolution (window class -> the .desktop command).
set -euo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/helpers.sh"
source "$HERE/gws-fixtures.sh"
gws_env
trap 'rm -rf "$TMP"' EXIT
GW="$ROOT/bin/omarchy-gws-persist"

# check CLASS LAYER COMMAND   ("-" means no command)
check() {
  local out
  out=$("$GW" resolve "$1") || fail "resolve $1 exits 0"
  python3 -c '
import json, sys
cls, layer, cmd = sys.argv[1:4]
r = json.loads(sys.stdin.read())
got = "-" if r.get("command") is None else r["command"]
assert r["layer"] == layer and got == cmd, r
' "$1" "$2" "$3" <<<"$out" || fail "resolve $1 -> want $2 / $3" "$out"
  pass "resolve $1: $2"
}

check foot exact-class "foot"
check TUI.tile app-id "foot --app-id=TUI.tile --config=/x/foot-hermes.ini hermes --tui"
check Hermes name "foot --app-id=TUI.tile --config=/x/foot-hermes.ini hermes --tui"
check vivaldi-stable exact-class "vivaldi-stable"
check crx__ompifgpmddkgmclendfeacglnodjjndh exact-class 'omarchy-launch-webapp "https://teams.cloud.microsoft/?clientType=pwa"'
check vivaldi-teams.cloud.microsoft__-Default pwa-host 'omarchy-launch-webapp "https://teams.cloud.microsoft/?clientType=pwa"'
check vivaldi-app.plex.tv__desktop_-Default pwa-host 'omarchy-launch-webapp "https://app.plex.tv/desktop/"'
check steam_app_1113120 steam-game "steam steam://rungameid/1113120"
check steam_app_11131200 none -
check fieldy exact-class "fieldy --open"
check dupeclass ambiguous -
check hiddenapp none -
check nosuchapp none -
check "VirtualBox Machine" none -

# Overrides: a command maps the class; null hides it.
echo '{"VirtualBox Machine": "omarchy-launch-win11-vbox", "foot": null}' > "$DIR/launchers.json"
check "VirtualBox Machine" override "omarchy-launch-win11-vbox"
check foot hidden -
rm -f "$DIR/launchers.json"

# launchers table: live windows, with unresolved ones flagged
gws_clients "$(gws_client 0xa foot 13 false)" "$(gws_client 0xb hiddenapp 12 false)"
table=$("$GW" launchers)
grep -qP '^foot\texact-class\tFoot\tfoot$' <<<"$table" || fail "launchers lists foot" "$table"
grep -qP '^hiddenapp\tnone\thiddenapp\t-$' <<<"$table" || fail "launchers lists hiddenapp as none" "$table"
unres=$("$GW" launchers --unresolved)
grep -q hiddenapp <<<"$unres" && ! grep -q '^foot' <<<"$unres" || fail "--unresolved filters" "$unres"
pass "launchers table and --unresolved"

echo "ALL PASS: gws-launchers"
