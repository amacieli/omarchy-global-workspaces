#!/bin/bash
# Continuity pruning: a closed app is marked absent, dropped by a later look
# (close sweep, timer reconcile) and never during shutdown; carry-overs from
# earlier logins are offered a limited number of times; every decision is in
# snapshot.log; placement logs where a window ended up.
set -euo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/helpers.sh"
source "$HERE/gws-fixtures.sh"
gws_env
trap 'rm -rf "$TMP"' EXIT
GW="$ROOT/bin/omarchy-gws-persist"
LAYOUT="$DIR/layout.json"
gws_persist_on

keys() { python3 -c 'import json,sys; print(" ".join(sorted(json.load(open(sys.argv[1]))["entries"])))' "$LAYOUT"; }
rec() { printf '{"version":1,"entries":%s}\n' "$1" | gws_layout; }
ent() { printf '"%s":[{"monitor":"DP-1","slot":1,"floating":false,"seen":%s,"live_n":%s,"launcher":"x"}]' "$1" "$2" "$3"; }
field() { python3 -c 'import json,sys; w=json.load(open(sys.argv[1]))["entries"][sys.argv[2]][0]; print(w.get(sys.argv[3]))' "$LAYOUT" "$1" "$2"; }

echo 1000 > "$DIR/session-start"; echo 3 > "$DIR/login-count"
export GWS_CONFIRM=45

# a. closed this login: first look marks, second look (after CONFIRM) drops
rec "{$(ent foot 1500 3),$(ent vivaldi-stable 1500 3)}"
gws_clients "$(gws_client 0xb vivaldi-stable 11 false)"
rc=0; python3 "$ROOT/lib/gws.py" snapshot close || rc=$?
[[ $rc == 10 ]] || fail "marked records are pending: exit 10" "rc=$rc"
[[ $(keys) == "foot vivaldi-stable" && $(field foot absent_login) == 1000 ]] || fail "first look marks foot absent" "$(keys)"
python3 - "$LAYOUT" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["entries"]["foot"][0]["absent_since"] -= 60
json.dump(d, open(sys.argv[1], "w"))
PY
rc=0; python3 "$ROOT/lib/gws.py" snapshot timer || rc=$?
[[ $(keys) == "vivaldi-stable" && $rc == 0 ]] || fail "second look drops foot, nothing pending" "$(keys) rc=$rc"
pass "close marks, a later look past CONFIRM drops (exit code says pending/done)"

# b. a window that comes back clears the mark
rec "{$(ent foot 1500 3)}"
gws_clients
python3 "$ROOT/lib/gws.py" snapshot close || true
[[ $(field foot absent_since) != None ]] || fail "marked"
gws_clients "$(gws_client 0xa foot 11 false)"
python3 "$ROOT/lib/gws.py" snapshot open
[[ $(field foot absent_since) == None ]] || fail "reappearing window clears the mark"
pass "a returning window clears its absence mark"

# c. `reconcile` (the timer's command) prunes with no window event at all
rec "{$(ent foot 1500 3)}"
gws_clients
python3 "$ROOT/lib/gws.py" snapshot close || true
python3 - "$LAYOUT" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["entries"]["foot"][0]["absent_since"] -= 60
json.dump(d, open(sys.argv[1], "w"))
PY
"$GW" reconcile
[[ -z $(keys) ]] || fail "timer reconcile drops a confirmed-closed record" "$(keys)"
pass "reconcile (timer) drops without any window event"

# d. the close hook arranges the second look itself (sweep), no timer needed
GWS_CONFIRM=1 GWS_SWEEP_DELAY=1.5 GWS_DEBOUNCE=0
export GWS_CONFIRM GWS_SWEEP_DELAY GWS_DEBOUNCE
rec "{$(ent foot $(date +%s) 3)}"
gws_clients
"$GW" snapshot close
[[ -z $(keys) ]] || fail "close sweep drops the record after CONFIRM" "$(keys)"
pass "window.close sweep: marked, confirmed and dropped without the timer"
export GWS_CONFIRM=45

# e. carry-overs: offered once, then gone; legacy records migrate
echo 3 > "$DIR/login-count"
rec "{$(ent foot 500 2),$(ent vivaldi-stable 500 1)}"          # live in login 2 (offered now) and login 1 (offered before)
gws_clients
python3 "$ROOT/lib/gws.py" snapshot login
[[ $(keys) == "foot" ]] || fail "carried past MAX_CARRY is dropped, one offer is kept" "$(keys)"
echo 4 > "$DIR/login-count"
python3 "$ROOT/lib/gws.py" snapshot login
[[ -z $(keys) ]] || fail "offered once, not relaunched: gone at the next login" "$(keys)"
pass "carry-over records are offered once, then dropped"

rec '{"foot":[{"monitor":"DP-1","slot":1,"floating":false,"seen":500,"launcher":"x"}]}'   # legacy: no live_n
echo 1000 > "$DIR/session-start"; echo 5 > "$DIR/login-count"
python3 "$ROOT/lib/gws.py" snapshot login
[[ $(keys) == "foot" && $(field foot live_n) == 4 ]] || fail "legacy record gets one offer" "$(keys) $(field foot live_n)"
echo 6 > "$DIR/login-count"
python3 "$ROOT/lib/gws.py" snapshot login
[[ -z $(keys) ]] || fail "legacy record is gone the login after" "$(keys)"
pass "legacy records without live_n migrate and age out"

# f. session-start counts logins
rm -f "$DIR/login-count"
"$GW" session-start
"$GW" session-start
[[ $(cat "$DIR/login-count") == 3 ]] || fail "each session-start bumps the login count" "$(cat "$DIR/login-count")"
pass "session-start counts logins"

# g. snapshot.log explains the decisions, and `log` prints them
rec "{$(ent foot 1500 3)}"; echo 3 > "$DIR/login-count"; echo 1000 > "$DIR/session-start"
gws_clients
python3 "$ROOT/lib/gws.py" snapshot close || true
grep -q '"ev": "absent".*"class": "foot"\|"class": "foot".*"ev": "absent"' "$DIR/snapshot.log" || fail "snapshot.log records the absence" "$(cat "$DIR/snapshot.log")"
out=$("$GW" log 5)
grep -q "absent" <<<"$out" && grep -q "trigger=close" <<<"$out" || fail "log prints events with their trigger" "$out"
rec "{$(ent foot 1500 3)}"
gws_clients "$(gws_client 0xa foot 21 false)"           # moved from DP-1 slot 1 to DP-2 slot 1
python3 "$ROOT/lib/gws.py" snapshot move
grep -q '"ev": "moved"' "$DIR/snapshot.log" || fail "a changed place is logged" "$(tail -3 "$DIR/snapshot.log")"
pass "snapshot.log holds absent/moved decisions; log command prints them"

# h. shutdown: recorded as a hold, nothing marked
rec "{$(ent foot 1500 3)}"
gws_clients
GWS_SHUTDOWN=1 python3 "$ROOT/lib/gws.py" snapshot close
[[ $(field foot absent_since) == None ]] || fail "no mark while shutting down"
grep -q '"ev": "hold"' "$DIR/snapshot.log" || fail "the hold is logged"
pass "shutting down: no mark, hold logged"

# i. placement: the late check logs where the window ended up
NOW=$(date +%s)
echo "{\"expires\": $((NOW+300)), \"windows\": [{\"class\":\"foot\",\"monitor\":\"DP-1\",\"slot\":1,\"floating\":false,\"at\":null,\"size\":null}]}" > "$DIR/pending.json"
gws_clients "$(gws_client 0xf foot 1 false)"
GWS_PLACE_LATE=0.2,0.4 "$GW" place 0xf
grep -q "late check +0.4s: workspace 1, wanted 11 (DRIFT)" "$DIR/place.log" || fail "late check logs drift" "$(cat "$DIR/place.log")"
pass "place logs a late check: wanted vs actual workspace"

echo "ALL PASS: gws-continuity"
