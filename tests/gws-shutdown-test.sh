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

# f. backstop: no signal at all, but two apps vanish in one snapshot
snap_all_gone
[[ $(keys) == "foot vivaldi-stable" ]] || fail "mass close with no signal must keep the layout" "$(keys)"
pass "mass close with no shutdown signal keeps the layout"

echo "ALL PASS: gws-shutdown"
