#!/bin/bash
# The recorder must not read a reboot's window closes as the user quitting apps.
# `omarchy reboot` queues the reboot behind a 2 s user timer and closes every
# window at once, so systemd has no reboot job yet when the snapshot runs.
# Also: a mass close that nothing announces keeps the layout.
set -euo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/helpers.sh"
source "$HERE/gws-fixtures.sh"
gws_env
trap 'rm -rf "$TMP"' EXIT
GW="$ROOT/bin/omarchy-gws-persist"
LAYOUT="$DIR/layout.json"
gws_persist_on
unset GWS_SHUTDOWN                    # exercise the real detection, not the override

# systemctl stand-in: `list-jobs` and `--user list-units` print the fixture files.
STUB="$TMP/stub"; mkdir -p "$STUB"
cat > "$STUB/systemctl" <<EOF
#!/bin/bash
if [[ \$1 == --user ]]; then cat "$TMP/user-units" 2>/dev/null; else cat "$TMP/jobs" 2>/dev/null; fi
exit 0
EOF
chmod +x "$STUB/systemctl"
export PATH="$STUB:$PATH"
: > "$TMP/jobs"; : > "$TMP/user-units"

keys() { python3 -c 'import json,sys; print(" ".join(sorted(json.load(open(sys.argv[1]))["entries"])))' "$LAYOUT"; }
rec() { printf '{"version":1,"entries":%s}\n' "$1" | gws_layout; }
ent() { printf '"%s":[{"monitor":"DP-1","slot":1,"floating":false,"seen":1500,"launcher":"x"}]' "$1"; }
TWO="{$(ent foot),$(ent vivaldi-stable)}"
ONE_LEFT="{$(ent foot),$(ent vivaldi-stable)}"
echo 1000 > "$DIR/session-start"

snap_with_vivaldi_left() {            # foot is gone, vivaldi still open
  rec "$ONE_LEFT"
  gws_clients "$(gws_client 0xb vivaldi-stable 11 false)"
  "$GW" snapshot
}
snap_all_gone() { rec "$TWO"; gws_clients; "$GW" snapshot; }

# a. control: no signal, one app closed -> dropped (normal behaviour kept)
snap_with_vivaldi_left
[[ $(keys) == "vivaldi-stable" ]] || fail "one app closed with no shutdown must be dropped" "$(keys)"
pass "no shutdown signal: a single closed app is still dropped"

# b. the case that wiped the layout: reboot timer pending, every window closed
echo '  run-r1a2b3c.timer loaded active waiting [systemd-run] systemctl reboot --no-wall' > "$TMP/user-units"
snap_all_gone
[[ $(keys) == "foot vivaldi-stable" ]] || fail "pending reboot timer: layout must survive" "$(keys)"
pass "pending reboot timer (omarchy reboot): layout survives"

# c. same with a full path and poweroff
echo '  run-r9.timer loaded active waiting [systemd-run] /usr/bin/systemctl poweroff --no-wall' > "$TMP/user-units"
snap_all_gone
[[ $(keys) == "foot vivaldi-stable" ]] || fail "pending poweroff timer: layout must survive" "$(keys)"
pass "pending poweroff timer: layout survives"

# d. an unrelated systemd-run unit is not a shutdown
echo '  run-r7.timer loaded active waiting [systemd-run] /usr/bin/notify-send hello' > "$TMP/user-units"
snap_with_vivaldi_left
[[ $(keys) == "vivaldi-stable" ]] || fail "unrelated transient unit is not a shutdown" "$(keys)"
pass "unrelated systemd-run unit is ignored"
: > "$TMP/user-units"

# e. reboot already queued in the system manager
echo '1234 reboot.target start waiting' > "$TMP/jobs"
snap_all_gone
[[ $(keys) == "foot vivaldi-stable" ]] || fail "queued reboot.target job: layout must survive" "$(keys)"
pass "queued reboot.target job: layout survives"
: > "$TMP/jobs"

# f. no signal at all, two apps vanish in one snapshot. The mass-close veto is
# gone: the records are marked absent, and survive until a later look, at least
# GWS_CONFIRM seconds on, still finds them gone with no shutdown signal.
export GWS_CONFIRM=45
snap_all_gone
[[ $(keys) == "foot vivaldi-stable" ]] || fail "first look only marks: records stay" "$(keys)"
grep -q absent_since "$LAYOUT" || fail "first look marks the records absent"
pass "mass close with no signal: first look marks, keeps the layout"

# g. a session that dies right after a mass close never reaches the second look
# (marks from an earlier login are void), so the next login still has the layout.
echo 2000 > "$DIR/session-start"
gws_clients
"$GW" snapshot
[[ $(keys) == "foot vivaldi-stable" ]] || fail "marks from an earlier login must not prune" "$(keys)"
pass "absence marked in an earlier login is void"

# h. confirmed later, no signal: dropped
echo 1000 > "$DIR/session-start"
snap_all_gone
python3 - "$LAYOUT" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); 
for ws in d["entries"].values():
    for w in ws: w["absent_since"] -= 100
json.dump(d, open(sys.argv[1], "w"))
PY
"$GW" snapshot
[[ -z $(keys) ]] || fail "absent past the confirm time with no shutdown: dropped" "$(keys)"
pass "absent past the confirm time, no shutdown: dropped"

# i. same confirmed state but a shutdown is announced: nothing dropped
snap_all_gone
python3 - "$LAYOUT" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for ws in d["entries"].values():
    for w in ws: w["absent_since"] = 1; w["absent_login"] = "1000"
json.dump(d, open(sys.argv[1], "w"))
PY
echo '  run-r1.timer loaded active waiting [systemd-run] systemctl reboot --no-wall' > "$TMP/user-units"
"$GW" snapshot
[[ $(keys) == "foot vivaldi-stable" ]] || fail "confirmed absence is not acted on during shutdown" "$(keys)"
pass "shutdown announced: confirmed absences are still not dropped"

echo "ALL PASS: gws-shutdown"
