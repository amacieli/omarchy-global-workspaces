#!/bin/bash
# Step 0: records are safe across modes (no prune, one backup per login, forget).
set -euo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/helpers.sh"
source "$HERE/gws-fixtures.sh"
gws_env
trap 'rm -rf "$TMP"' EXIT
GW="$ROOT/bin/omarchy-gws-persist"
GWS="$ROOT/bin/omarchy-global-workspaces"

LAYOUT="$DIR/layout.json"
ANCIENT='{"version":1,"entries":{"foot":[{"monitor":"DP-1","slot":3,"floating":false,"seen":1,"launcher":"foot"}]}}'

# a. no 30-day prune: a record last seen in 1970 survives a snapshot
gws_persist_on
echo "$ANCIENT" | gws_layout
gws_clients
"$GW" snapshot
python3 -c 'import json,sys; assert "foot" in json.load(open(sys.argv[1]))["entries"]' "$LAYOUT" \
  || fail "old record was pruned"
pass "records are not pruned by age"

# b. one backup per login, taken before the first write of that login
rm -f "$LAYOUT" "$LAYOUT.bak" "$DIR/layout.bak-session"
echo "$ANCIENT" | gws_layout
cp "$LAYOUT" "$TMP/L0"
echo 1000 > "$DIR/session-start"
gws_clients "$(gws_client 0xa foot 13 false)"
"$GW" snapshot
cmp -s "$LAYOUT.bak" "$TMP/L0" || fail "first write of login 1 backs up the prior layout"
gws_clients "$(gws_client 0xa foot 14 false)"
"$GW" snapshot
cmp -s "$LAYOUT.bak" "$TMP/L0" || fail "second write in login 1 keeps the first backup"
cp "$LAYOUT" "$TMP/L1"
echo 2000 > "$DIR/session-start"
gws_clients "$(gws_client 0xa foot 15 false)"
"$GW" snapshot
cmp -s "$LAYOUT.bak" "$TMP/L1" || fail "first write of login 2 backs up login 1's layout"
pass "one backup per login"

# c. toggling modes and a local-mode login never touch layout.json
cp "$LAYOUT" "$TMP/before"
"$GWS" on >/dev/null; "$GWS" persisted >/dev/null; "$GWS" off >/dev/null; "$GWS" on >/dev/null
cmp -s "$LAYOUT" "$TMP/before" || fail "mode switches changed layout.json"
rm -f "$DIR/persisted"
gws_clients "$(gws_client 0xa foot 20 false)" "$(gws_client 0xb vivaldi-stable 25 false)"
"$GW" snapshot
cmp -s "$LAYOUT" "$TMP/before" || fail "a non-persisted session changed layout.json"
gws_persist_on
pass "mode switches and local sessions leave layout.json alone"

# d. records whose launcher no longer resolves are dropped at snapshot
echo '{"version":1,"entries":{"nosuchapp":[{"monitor":"DP-1","slot":1,"floating":false,"seen":1}],"foot":[{"monitor":"DP-1","slot":3,"floating":false,"seen":1}]}}' | gws_layout
gws_clients
"$GW" snapshot
python3 -c 'import json,sys; e=json.load(open(sys.argv[1]))["entries"]; assert "nosuchapp" not in e and "foot" in e, e' "$LAYOUT" \
  || fail "unresolved record kept"
pass "unresolved records are dropped"

# e. forget: one class, then everything; both leave a backup
echo '{"version":1,"entries":{"foot":[{"monitor":"DP-1","slot":3,"floating":false,"seen":1}],"vivaldi-stable":[{"monitor":"DP-2","slot":2,"floating":false,"seen":1}]}}' | gws_layout
rm -f "$LAYOUT.bak" "$DIR/layout.bak-session"
"$GWS" forget foot >/dev/null
python3 -c 'import json,sys; e=json.load(open(sys.argv[1]))["entries"]; assert list(e)==["vivaldi-stable"], e' "$LAYOUT" \
  || fail "forget foot removed the wrong record"
"$GWS" forget >/dev/null
python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["entries"]=={}' "$LAYOUT" || fail "forget (all) left records"
[[ -f $LAYOUT.bak ]] || fail "forget made no backup"
pass "forget <class> and forget (all)"

echo "ALL PASS: gws-records"
