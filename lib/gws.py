#!/usr/bin/env python3
"""Engine for Global Persisted mode. Driven by bin/omarchy-gws-persist.

Who reads layout.json, and when:
  * the recorder (snapshot) reads and writes it, while persisted mode is on. That
    includes its reconcile looks: the close sweep, the 5-minute timer and the
    login look all run `snapshot` with a trigger name;
  * the login picker (relaunch --list / --dry-run / --apply) reads it;
  * the explicit commands (show, forget, launchers, resolve) may read it.
Nothing else does. place() never reads it: a window is placed only when the
login picker started it, from pending.json, which apply() writes. A window the
user opens by hand is never placed or launched from the recorded layout.
"""
import fcntl
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from contextlib import contextmanager

HOME = os.path.expanduser("~")
STATE = os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.join(HOME, ".local", "state"), "omarchy")
DIR = os.path.join(STATE, "global-workspaces")
LAYOUT = os.path.join(DIR, "layout.json")
LAYOUT_BAK = LAYOUT + ".bak"
BAK_SESSION = os.path.join(DIR, "layout.bak-session")
SESSION = os.path.join(DIR, "session-start")
PERSIST_FLAG = os.path.join(DIR, "persisted")
PENDING = os.path.join(DIR, "pending.json")
PENDING_LOCK = os.path.join(DIR, "pending.lock")
OVERRIDES = os.path.join(DIR, "launchers.json")
LEARNED = os.path.join(DIR, "launchers-learned.json")
BASES = os.path.join(STATE, "monitor-bases.json")
PLACE_LOG = os.path.join(DIR, "place.log")
MONITORS_LUA = os.environ.get("GWS_MONITORS_FILE") or os.path.join(HOME, ".config", "hypr", "monitors.lua")

STRIDE = 10
GRACE = 180          # s after session-start in which a class is never truncated
PENDING_TTL = 300    # s a picker launch stays eligible for placement
SNAP_LOG = os.path.join(DIR, "snapshot.log")
LOGIN_COUNT = os.path.join(DIR, "login-count")
LOG_MAX = 200_000    # bytes before a log rotates to .old
SIDE_EFFECT = re.compile(r"steam://|VBoxManage|virt-manager|win11")
FIELD_CODE = re.compile(r"%[fFuUdDnNickvm]")
URL_HOST = re.compile(r"https?://([^/\s\"'?#:]+)")
PWA_VIVALDI = re.compile(r"^vivaldi-(.+?)__.*$")
STEAM_CLASS = re.compile(r"^steam_app_(\d+)$")


def confirm_secs():
    """Seconds a window must stay gone, across two looks, before its record goes."""
    try:
        return float(os.environ.get("GWS_CONFIRM", "45"))
    except ValueError:
        return 45.0


def max_carry():
    """Logins a record may be offered without its app being open again."""
    try:
        return int(os.environ.get("GWS_MAX_CARRY", "1"))
    except ValueError:
        return 1


def login_number():
    try:
        return max(1, int(read_text(LOGIN_COUNT) or 1))
    except ValueError:
        return 1


def stagger():
    try:
        return float(os.environ.get("GWS_LAUNCH_STAGGER", "0.5"))
    except ValueError:
        return 0.5


def app_dirs():
    env = os.environ.get("GWS_APP_DIRS")
    if env is not None:
        return [d for d in env.split(":") if d]
    return [os.path.join(HOME, ".local", "share", "applications"), "/usr/share/applications"]


# ── small file helpers ───────────────────────────────────────────────────────

def read_text(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return None


def load_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def atomic_write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix="." + os.path.basename(path) + ".")
    with os.fdopen(fd, "w") as f:
        f.write(text)
        f.flush()
        os.fsync(f.fileno())
    os.rename(tmp, path)


def atomic_json(path, data):
    atomic_write(path, json.dumps(data, indent=2, sort_keys=True) + "\n")


@contextmanager
def locked(path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


# ── Hyprland ─────────────────────────────────────────────────────────────────

def hypr_json(what):
    r = subprocess.run(["hyprctl", what, "-j"], capture_output=True, text=True)
    if r.returncode != 0 or not r.stdout.strip():
        return None
    try:
        return json.loads(r.stdout)
    except ValueError:
        return None


def dispatch(expr):
    return subprocess.run(["hyprctl", "dispatch", expr], capture_output=True).returncode == 0


def lua_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def launch(command):
    # One argument, no shell: the command is a Lua string literal for Hyprland.
    return dispatch("hl.dsp.exec_cmd(%s)" % lua_str(command))


# ── layout.json: the only writer is save_layout ─────────────────────────────

def persisted():
    return os.path.exists(PERSIST_FLAG)


def load_layout():
    data = load_json(LAYOUT, None)
    entries = data.get("entries") if isinstance(data, dict) else None
    return dict(entries) if isinstance(entries, dict) else {}


def backup_once():
    """Copy layout.json to layout.json.bak before the first write of a login."""
    stamp = read_text(SESSION) or "no-session"
    if not os.path.exists(LAYOUT) or read_text(BAK_SESSION) == stamp:
        return
    shutil.copy2(LAYOUT, LAYOUT_BAK)
    atomic_write(BAK_SESSION, stamp + "\n")


def save_layout(entries):
    data = {"version": 1, "entries": entries}
    if load_json(LAYOUT, None) == data:
        return False          # identical content: do not even rewrite the file
    backup_once()
    atomic_json(LAYOUT, data)
    return True


# ── .desktop scan and window-class resolution ───────────────────────────────

def parse_desktop(path):
    keys, in_entry = {}, False
    with open(path, encoding="utf-8", errors="replace") as f:
        for raw in f:
            line = raw.strip()
            if line.startswith("["):
                in_entry = line == "[Desktop Entry]"
                continue
            if not in_entry or "=" not in line or line.startswith("#"):
                continue
            k, v = line.split("=", 1)
            keys.setdefault(k.strip(), v.strip())
    return keys


def clean_exec(value):
    value = value.replace("%%", "\0")
    value = FIELD_CODE.sub("", value)
    return value.replace("\0", "%").strip()


def scan_apps():
    """Application entries, user directories first. The first file of an id wins,
    even when it is hidden, so a user entry can shadow a system one."""
    apps, seen = [], set()
    for base in app_dirs():
        for root, dirs, files in os.walk(base):
            dirs.sort()
            for fn in sorted(files):
                if not fn.endswith(".desktop"):
                    continue
                app_id = fn[: -len(".desktop")]
                if app_id in seen:
                    continue
                try:
                    keys = parse_desktop(os.path.join(root, fn))
                except OSError:
                    continue
                seen.add(app_id)
                if keys.get("Type") != "Application" or keys.get("Hidden") == "true" or not keys.get("Exec"):
                    continue
                apps.append({
                    "id": app_id,
                    "name": keys.get("Name", app_id),
                    "exec": clean_exec(keys["Exec"]),
                    "wmclass": keys.get("StartupWMClass", ""),
                    "nodisplay": keys.get("NoDisplay") == "true",
                })
    return apps


def layers_for(cls):
    """Matching rules, strongest first. Each yields apps that match the class."""
    pwa = PWA_VIVALDI.match(cls)
    host = pwa.group(1) if pwa else None
    steam = STEAM_CLASS.match(cls)
    return [
        ("exact-class", lambda a: a["wmclass"] == cls),
        ("app-id", lambda a: re.search(r"--app-id[= ]" + re.escape(cls) + r"(?=\s|$)", a["exec"]) is not None),
        ("steam-game", lambda a: steam is not None and re.search(r"rungameid/" + steam.group(1) + r"(?!\d)", a["exec"]) is not None),
        ("name", lambda a: cls.lower() in (a["id"].lower(), a["name"].lower())),
        ("pwa-host", lambda a: host is not None and host in URL_HOST.findall(a["exec"])),
    ]


def load_ctx():
    overrides = load_json(OVERRIDES, {})
    learned = load_json(LEARNED, {})
    return {
        "overrides": overrides if isinstance(overrides, dict) else {},
        "learned": learned if isinstance(learned, dict) else {},
        "apps": scan_apps(),
    }


def resolve_class(cls, ctx):
    """Map a window class to the command that starts it. command None = not
    launchable: unresolved, ambiguous, or hidden by a null override."""
    if cls in ctx["overrides"]:
        value = ctx["overrides"][cls]
        if value is None:
            return {"layer": "hidden", "command": None, "name": cls}
        if isinstance(value, dict):          # {"command": ..., "name": ...}
            return {"layer": "override", "command": str(value.get("command") or "") or None,
                    "name": str(value.get("name") or cls)}
        return {"layer": "override", "command": str(value), "name": cls}

    known = ctx["learned"].get(cls)
    if isinstance(known, dict):
        app = next((a for a in ctx["apps"] if a["id"] == known.get("id")), None)
        if app:
            return {"layer": "learned", "command": app["exec"], "name": app["name"], "id": app["id"], "learn": False}

    for layer, match in layers_for(cls):
        cands = [a for a in ctx["apps"] if match(a)]
        if not cands:
            continue
        visible = [a for a in cands if not a["nodisplay"]]
        if visible:
            cands = visible          # NoDisplay twins of a visible entry do not count
        if len(cands) > 1:
            return {"layer": "ambiguous", "command": None, "name": cls,
                    "candidates": sorted(a["id"] for a in cands)}
        app = cands[0]
        return {"layer": layer, "command": app["exec"], "name": app["name"], "id": app["id"], "learn": True}
    return {"layer": "none", "command": None, "name": cls}


# ── shutdown guard and monitor order ────────────────────────────────────────

SHUTDOWN_JOB = re.compile(r"(reboot|poweroff|halt|kexec|shutdown)\.target")
# A transient unit from `systemd-run ... <systemctl> reboot` carries its command
# as the description: "[systemd-run] /usr/bin/systemctl reboot --no-wall".
SHUTDOWN_TIMER = re.compile(r"\[systemd-run\].*\bsystemctl\s+(?:--\S+\s+)*(reboot|poweroff|halt|kexec)\b")


def _systemctl(*args):
    try:
        return subprocess.run(["systemctl", *args], capture_output=True,
                              text=True, timeout=5).stdout
    except (OSError, subprocess.TimeoutExpired):
        return ""


def shutdown_reason():
    """Why the machine is considered to be going down, or None.

    Two signals, because the Omarchy menu's reboot (omarchy-system-reboot)
    queues the reboot behind a 2 s user timer and closes every window at once,
    so for the first seconds systemd has no reboot job yet:
      1. a reboot/poweroff/halt/kexec job queued in the system manager ("job");
      2. a pending user-manager transient unit whose command is a systemctl
         reboot/poweroff/halt/kexec ("timer")."""
    if os.environ.get("GWS_SHUTDOWN") is not None:
        return "env" if os.environ["GWS_SHUTDOWN"] == "1" else None
    if SHUTDOWN_JOB.search(_systemctl("list-jobs", "--no-legend")):
        return "job"
    if SHUTDOWN_TIMER.search(_systemctl(
            "--user", "list-units", "--all", "--no-legend", "--no-pager", "run-*")):
        return "timer"
    return None


def shutting_down():
    """True when the machine is going down or is about to. Windows close during
    shutdown; the recorder must not read that as the user closing the apps."""
    return shutdown_reason() is not None


MONITOR_POS = re.compile(r'output\s*=\s*"([^"]+)"[^}]*?position\s*=\s*"(-?\d+)x(-?\d+)"')


def monitor_order():
    """Monitor name -> x position, left to right. Source: the monitors setup file
    (hypr/monitors.lua); monitors it does not place come from the live layout."""
    xs = {}
    text = read_text(MONITORS_LUA) or ""
    text = "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("--"))
    for name, x, _y in MONITOR_POS.findall(text):
        xs[name] = int(x)
    for m in hypr_json("monitors") or []:
        xs.setdefault(m.get("name"), m.get("x", 0))
    return xs


# ── recorder ─────────────────────────────────────────────────────────────────

PENDING_EXIT = 10     # snapshot exit code: records are absent and awaiting confirmation


def _place(w):
    return "%s/%s" % (w.get("monitor"), w.get("slot"))


def cmd_snapshot(trigger="event"):
    """Record where the open windows are, and keep the record honest.

    This is both the event recorder (window open/close/move/focus hooks) and
    the periodic reconcile (timer, login, post-close sweep): same code, so every
    path prunes by the same rules.

    Continuity. A record is *live* when a window of its class is open now; it
    carries `live_n`, the login number it was last live in. A record that is
    not live now is handled by what it was:
      * live this login (live_n == this login): the app was open and is gone.
        It is marked `absent_since` the first time that is seen, and dropped by
        a later look at least CONFIRM seconds on, if the machine is not shutting
        down at that look. A reappearing window clears the mark. Nothing is
        marked or dropped while shutting_down(); marks from an earlier login
        are void (the session may have died, not the app).
      * not live this login: it is a carry-over from an earlier login, offered
        by the login checklist. It is kept for MAX_CARRY logins, then dropped.
    Returns PENDING_EXIT when marked records still await confirmation."""
    if not persisted():
        return 0
    clients, monitors = hypr_json("clients"), hypr_json("monitors")
    bases = load_json(BASES, None)
    if not isinstance(clients, list) or not isinstance(monitors, list) or not isinstance(bases, dict):
        slog("skip", trigger=trigger, reason="hyprctl or monitor bases unavailable")
        return 0
    owner = {int(b): n for n, b in bases.items()}

    entries = load_layout()
    ctx = load_ctx()
    stamp = read_text(SESSION)
    try:
        login = int(stamp) if stamp is not None else None
    except ValueError:
        login = None
    in_grace = login is not None and time.time() - login < GRACE
    now = int(time.time())
    n_login, carry, confirm = login_number(), max_carry(), confirm_secs()
    sd = shutdown_reason()
    events = []

    current, filtered = {}, {}
    for c in clients:
        cls, wsid = c.get("class") or "", c["workspace"]["id"]
        why = None
        if not c.get("mapped", True):
            why = "unmapped"
        elif c.get("hidden"):
            why = "hidden"
        elif cls and wsid <= 0:
            why = "special-workspace %s" % wsid
        elif cls and owner.get(((wsid - 1) // STRIDE) * STRIDE) is None:
            why = "no-monitor-base"
        if not cls:
            continue
        if why:
            filtered.setdefault(cls, set()).add(why)
            continue
        current.setdefault(cls, []).append({
            "monitor": owner[((wsid - 1) // STRIDE) * STRIDE],
            "slot": (wsid - 1) % STRIDE + 1,
            "floating": bool(c.get("floating")),
            "at": c.get("at"),
            "size": c.get("size"),
            "seen": now,
            "live_n": n_login,
        })

    pending = False
    held = False
    learned = dict(ctx["learned"])
    for cls in sorted(set(current) | set(entries)):
        res = resolve_class(cls, ctx)
        if res["command"] is None:
            if entries.pop(cls, None) is not None:
                events.append(("drop", {"class": cls, "reason": "unresolved launcher"}))
            continue
        if res.get("learn"):
            learned[cls] = {"id": res["id"]}

        old, wins = entries.get(cls, []), current.get(cls, [])
        for w in old:                       # records from before live_n existed
            if "live_n" not in w:
                w["live_n"] = n_login if login is not None and w.get("seen", 0) >= login else n_login - 1
        k = min(len(old), len(wins))
        new = []
        for i in range(k):                  # open windows: the record follows them
            was, w = old[i], dict(wins[i])
            if was.get("absent_since") is not None:
                events.append(("returned", {"class": cls, "idx": i}))
            if in_grace and was.get("live_n", 0) < n_login:
                # Just logged in: the window may have landed wrong. Keep the
                # recorded place; log the difference, it is what to look at.
                if (was.get("monitor"), was.get("slot")) != (w["monitor"], w["slot"]):
                    events.append(("grace-hold", {"class": cls, "idx": i,
                                                  "recorded": _place(was), "actual": _place(w)}))
                w.update({f: was[f] for f in ("monitor", "slot", "floating", "at", "size") if f in was})
            elif (was.get("monitor"), was.get("slot")) != (w["monitor"], w["slot"]):
                events.append(("moved", {"class": cls, "idx": i, "from": _place(was), "to": _place(w)}))
            new.append(w)
        for w in wins[k:]:                  # more windows than records
            new.append(dict(w))
            events.append(("added", {"class": cls, "place": _place(w)}))
        for i, w in enumerate(old[k:], start=k):   # records with no open window
            live_now = w.get("live_n", 0) >= n_login
            if live_now:
                if sd:
                    held = True
                    new.append(w)
                    continue
                if w.get("absent_since") is None or w.get("absent_login") != stamp:
                    w["absent_since"], w["absent_login"] = now, stamp
                    events.append(("absent", {"class": cls, "idx": i, "place": _place(w),
                                              "still-mapped-as": sorted(filtered.get(cls, []))}))
                gone = now - w["absent_since"]
                if gone >= confirm:
                    events.append(("prune", {"class": cls, "idx": i, "reason": "closed",
                                             "absent_for": gone}))
                    continue
                pending = True
                new.append(w)
            else:
                w.pop("absent_since", None)
                w.pop("absent_login", None)
                dormant = n_login - w.get("live_n", n_login)
                if dormant > carry:
                    events.append(("prune", {"class": cls, "idx": i, "reason": "carried",
                                             "logins_offered": dormant - 1,
                                             "last_seen": w.get("seen")}))
                    continue
                new.append(w)
        if not new:
            entries.pop(cls, None)
            continue
        for w in new:
            w["launcher"] = res["command"]
        entries[cls] = new

    if held:
        events.append(("hold", {"reason": "shutting down (%s): no record marked or dropped" % sd}))
    if learned != ctx["learned"]:
        atomic_json(LEARNED, learned)
    changed = save_layout(entries)

    for ev, fields in events:
        slog(ev, trigger=trigger, **fields)
    # Event-driven looks (open/move/focus) log only when they decided something;
    # the rare scheduled looks always log, so the log shows the timer is alive.
    if events or trigger in ("login", "sweep", "timer") or os.environ.get("GWS_LOG_ALL") == "1":
        slog("snapshot", trigger=trigger, clients=len(clients), classes_open=len(current),
             records=sum(len(v) for v in entries.values()), changed=changed,
             shutting_down=sd, pending=pending, login=n_login)
    return PENDING_EXIT if pending else 0


# ── placement: only for windows the login picker started ────────────────────

def append_log(path, line):
    try:
        if os.path.exists(path) and os.path.getsize(path) > LOG_MAX:
            os.replace(path, path + ".old")
        with open(path, "a") as f:
            f.write(line + "\n")
    except OSError:
        pass


def log_place(msg):
    append_log(PLACE_LOG, "%s %s" % (time.strftime("%F %T"), msg))


def slog(ev, **fields):
    """One JSON line in snapshot.log: what the recorder decided and why. Kept on
    purpose, for debugging; `omarchy-gws-persist log` reads it."""
    rec = {"t": time.strftime("%F %T"), "ev": ev}
    rec.update(fields)
    append_log(SNAP_LOG, json.dumps(rec, sort_keys=True))


def late_checks():
    raw = os.environ.get("GWS_PLACE_LATE", "5,15")
    out = []
    for part in raw.split(","):
        try:
            out.append(float(part))
        except ValueError:
            pass
    return sorted(t for t in out if t > 0)


def cmd_place(addr):
    if not addr or not persisted():
        return
    with locked(PENDING_LOCK):
        pend = load_json(PENDING, None)
        if not isinstance(pend, dict) or pend.get("expires", 0) < time.time():
            if os.path.exists(PENDING):
                os.remove(PENDING)
            return
        me = None
        for _ in range(5):             # the class can lag the open event
            clients = hypr_json("clients") or []
            me = next((c for c in clients if c.get("address") == addr), None)
            if me and me.get("class"):
                break
            time.sleep(0.15)
        if not me or not me.get("class"):
            return
        wins = list(pend.get("windows", []))
        idx = next((i for i, w in enumerate(wins) if w.get("class") == me["class"]), None)
        if idx is None:
            return                     # not started by the picker: leave it alone
        want = wins.pop(idx)
        if wins:
            atomic_json(PENDING, {"expires": pend["expires"], "windows": wins})
        else:
            os.remove(PENDING)

    bases = load_json(BASES, {})
    connected = {m.get("name") for m in (hypr_json("monitors") or [])}
    mon = want.get("monitor")
    if not isinstance(bases, dict) or mon not in connected or mon not in bases:
        return
    target = int(bases[mon]) + int(want["slot"])
    sel = 'window = "address:%s"' % addr
    log_place("%s %s: want %s slot %s (workspace %d), opened on workspace %s"
              % (addr, me["class"], mon, want["slot"], target, me["workspace"]["id"]))
    if me["workspace"]["id"] != target:
        dispatch('hl.dsp.window.move({ workspace = "%d", follow = false, %s })' % (target, sel))
    # Hyprland or the app can still shuffle a new window after it opens: look again
    # and put it back, so a late move cannot leave it on the wrong monitor.
    for _ in range(int(os.environ.get("GWS_PLACE_VERIFY", "3"))):
        time.sleep(float(os.environ.get("GWS_PLACE_VERIFY_DELAY", "1")))
        now = next((c for c in (hypr_json("clients") or []) if c.get("address") == addr), None)
        if not now:
            break
        if now["workspace"]["id"] != target:
            log_place("%s %s: found on workspace %s, moving to %d" % (addr, me["class"], now["workspace"]["id"], target))
            dispatch('hl.dsp.window.move({ workspace = "%d", follow = false, %s })' % (target, sel))
    if want.get("floating") and want.get("at") and want.get("size"):
        if not me.get("floating"):
            dispatch('hl.dsp.window.float({ action = "enable", %s })' % sel)
        dispatch('hl.dsp.window.resize({ x = %d, y = %d, exact = true, %s })'
                 % (want["size"][0], want["size"][1], sel))
        dispatch('hl.dsp.window.move({ x = %d, y = %d, exact = true, %s })'
                 % (want["at"][0], want["at"][1], sel))
    # Observation only (no re-placing): where did the window end up once the app
    # had time to move itself? This is what tells a late self-relocation from a
    # failed placement.
    waited = 0.0
    for t in late_checks():
        time.sleep(max(0.0, t - waited))
        waited = t
        now = next((c for c in (hypr_json("clients") or []) if c.get("address") == addr), None)
        if not now:
            log_place("%s %s: late check +%gs: window gone" % (addr, me["class"], t))
            break
        ws = now["workspace"]["id"]
        log_place("%s %s: late check +%gs: workspace %s, wanted %d (%s)"
                  % (addr, me["class"], t, ws, target, "ok" if ws == target else "DRIFT"))


# ── login picker: rows, dry run, apply ──────────────────────────────────────

def build_rows():
    """One row per recorded window. Row ids are class#index into the recorded
    list. The first N rows of a class are 'running' when N windows are open."""
    ctx = load_ctx()
    entries = load_layout()
    clients = hypr_json("clients") or []
    connected = {m.get("name") for m in (hypr_json("monitors") or [])}
    running = {}
    for c in clients:
        if c.get("class") and c.get("mapped", True) and not c.get("hidden"):
            running[c["class"]] = running.get(c["class"], 0) + 1

    rows = []
    for cls in sorted(entries):
        res = resolve_class(cls, ctx)
        if res["command"] is None:
            continue
        open_now = running.get(cls, 0)
        side = bool(SIDE_EFFECT.search(res["command"]))
        for i, e in enumerate(entries[cls]):
            state = "running" if i < open_now else "launch"
            label = "%s (%s, slot %s)" % (res["name"], e.get("monitor"), e.get("slot"))
            rows.append({
                "id": "%s#%d" % (cls, i),
                "class": cls,
                "index": i,
                "name": res["name"],
                "label": label,
                "monitor": e.get("monitor"),
                "slot": e.get("slot"),
                "floating": bool(e.get("floating")),
                "at": e.get("at"),
                "size": e.get("size"),
                "command": res["command"],
                "state": state,
                "side_effect": side,
                "default": state == "launch" and not side,
                "connected": e.get("monitor") in connected,
            })
    return rows


def cmd_relaunch_list():
    print(json.dumps({"rows": build_rows()}, indent=2))


def cmd_relaunch_dry_run():
    rows = build_rows()
    if not rows:
        print("no recorded windows with a launcher")
        return
    for r in rows:
        mark = "*" if r["default"] else " "
        extra = "" if r["connected"] else "  [monitor not connected]"
        print("%s %-26s %-8s %-14s %s%s" % (
            mark, r["id"], r["state"], "side-effect" if r["side_effect"] else "", r["label"], extra))
        print("    %s" % r["command"])
    launches = sum(1 for r in rows if r["default"])
    print("\nwith default selection: would launch %d, dismiss %d unticked" % (
        launches, sum(1 for r in rows if r["state"] == "launch" and not r["default"])))
    print("dry run: nothing launched, layout.json unchanged")


def cmd_apply(ids):
    rows = build_rows()
    want = set(ids)
    known = {r["id"]: r for r in rows}
    for i in sorted(want - set(known)):
        print("ignored: %s is not a recorded row" % i, file=sys.stderr)
    for i in sorted(want & {r["id"] for r in rows if r["state"] != "launch"}):
        print("ignored: %s is already running" % i, file=sys.stderr)

    launch_rows = [r for r in rows if r["state"] == "launch"]
    chosen = [r for r in launch_rows if r["id"] in want]
    dismissed = [r for r in launch_rows if r["id"] not in want]

    # Dismissal (decision 6): unticked rows lose their record.
    if dismissed:
        entries = load_layout()
        by_cls = {}
        for r in dismissed:
            by_cls.setdefault(r["class"], []).append(r["index"])
        for cls, idxs in by_cls.items():
            lst = entries.get(cls, [])
            for i in sorted(idxs, reverse=True):
                if i < len(lst):
                    del lst[i]
            if lst:
                entries[cls] = lst
            else:
                entries.pop(cls, None)
        save_layout(entries)

    if chosen:
        now = time.time()
        with locked(PENDING_LOCK):
            old = load_json(PENDING, None)
            kept = []
            if isinstance(old, dict) and old.get("expires", 0) >= now:
                kept = list(old.get("windows", []))
            new = [{"class": r["class"], "monitor": r["monitor"], "slot": r["slot"],
                    "floating": r["floating"], "at": r["at"], "size": r["size"]} for r in chosen]
            atomic_json(PENDING, {"expires": int(now) + PENDING_TTL, "windows": kept + new})
        for k, r in enumerate(chosen):
            if k:
                time.sleep(stagger())
            launch(r["command"])

    print("launched %d, dismissed %d" % (len(chosen), len(dismissed)))


def cmd_relaunch(args):
    if args == ["--list"]:
        cmd_relaunch_list()
    elif args == ["--dry-run"]:
        cmd_relaunch_dry_run()
    elif args[:1] == ["--apply"]:
        cmd_apply(args[1:])
    else:
        print("usage: relaunch --list | --dry-run | --apply ID...", file=sys.stderr)
        return 1
    return 0


# ── explicit commands ───────────────────────────────────────────────────────

def cmd_forget(cls):
    entries = {} if cls is None else load_layout()
    if cls is not None:
        entries.pop(cls, None)
    save_layout(entries)
    print("forgot " + (cls or "every recorded window"))


def cmd_launchers(unresolved_only):
    ctx = load_ctx()
    classes = sorted({c.get("class") for c in (hypr_json("clients") or []) if c.get("class")})
    for cls in classes:
        res = resolve_class(cls, ctx)
        if unresolved_only and res["command"] is not None:
            continue
        detail = res["command"] or (("candidates: " + ", ".join(res["candidates"])) if res.get("candidates") else "-")
        print("%s\t%s\t%s\t%s" % (cls, res["layer"], res.get("name", ""), detail))


def monitor_labels():
    """Connector -> 'Make Model (CONNECTOR)' for connected monitors; others show the connector."""
    out = {}
    for m in hypr_json("monitors") or []:
        name, make = m.get("name"), (m.get("make") or "").strip()
        model = " ".join(t for t in (m.get("model") or "").split() if not t.startswith("*"))
        word = make.split()[0] if make else ""
        if word and model.lower().startswith(word.lower()):
            model = model[len(word):].strip()
        text = " ".join(t for t in (word.title() if word.isupper() else word, model) if t)
        out[name] = "%s (%s)" % (text, name) if text else name
    return out


def format_table(rows):
    """rows: [(workspace, monitor_label, app)] -> (header, [label]), for `current`."""
    cells = [(str(w), str(m), str(a)) for w, m, a in rows]
    w1 = max([len("Workspace")] + [len(c[0]) for c in cells])
    w2 = max([len("Monitor")] + [len(c[1]) for c in cells])
    labels, seen = [], {}
    for a, b, c in cells:
        label = "%-*s  \u2502  %-*s  \u2502  %s" % (w1, a, w2, b, c)
        seen[label] = seen.get(label, 0) + 1
        if seen[label] > 1:
            label += " (%d)" % seen[label]
        labels.append(label)
    return "%-*s  \u2502  %-*s  \u2502  %s" % (w1, "Workspace", w2, "Monitor", "App"), labels


def picker_rows():
    """The launchable rows in checklist order: Workspace (AW slot) first, then
    monitor left to right by the monitors setup file."""
    rows = [r for r in build_rows() if r["state"] == "launch"]
    xs = monitor_order()
    far = 10 ** 9
    rows.sort(key=lambda r: (int(r["slot"] or 0), xs.get(r["monitor"], far), str(r["monitor"]), r["name"], r["index"]))
    return rows


def cmd_current():
    """Windows open right now as the plugin sees them: workspace slot, monitor, app."""
    clients, bases = hypr_json("clients") or [], load_json(BASES, {})
    owner = {int(b): n for n, b in bases.items()}
    xs, names, ctx = monitor_order(), monitor_labels(), load_ctx()
    far = 10 ** 9
    rows = []
    for c in clients:
        ws = c["workspace"]["id"]
        if not c.get("mapped", True) or c.get("hidden") or not c.get("class") or ws <= 0:
            continue
        mon = owner.get(((ws - 1) // STRIDE) * STRIDE, c.get("monitor"))
        res = resolve_class(c["class"], ctx)
        name = res["name"] if res.get("id") or res["layer"] == "override" else c["class"]
        rows.append(((ws - 1) % STRIDE + 1, xs.get(mon, far), names.get(mon, mon), name, ws))
    rows.sort(key=lambda r: r[:4])
    header, labels = format_table([(r[0], r[2], r[3]) for r in rows])
    print(header)
    for l in labels:
        print(l)


def cmd_picker_json():
    """The overlay checklist's rows as JSON: ids come straight from the rows, so no
    label has to be mapped back. Rows that are already open are not offered."""
    names = monitor_labels()
    print(json.dumps({"rows": [{
        "id": r["id"],
        "workspace": r["slot"],
        "monitor": names.get(r["monitor"], r["monitor"]),
        "connected": r["connected"],
        "app": r["name"],
        "sideEffect": r["side_effect"],
        "on": r["default"],
    } for r in picker_rows()]}))


def cmd_log(args):
    """Print the tail of snapshot.log (or place.log with --place), one event a line."""
    path = PLACE_LOG if "--place" in args else SNAP_LOG
    nums = [a for a in args if a.isdigit()]
    n = int(nums[0]) if nums else 40
    try:
        with open(path) as f:
            lines = f.read().splitlines()[-n:]
    except OSError:
        print("no log yet: %s" % path)
        return
    for line in lines:
        try:
            r = json.loads(line)
        except ValueError:
            print(line)
            continue
        t, ev = r.pop("t", ""), r.pop("ev", "")
        print("%s %-10s %s" % (t, ev, " ".join("%s=%s" % (k, r[k]) for k in sorted(r))))


def main(argv):
    cmd, args = (argv[0] if argv else ""), argv[1:]
    if cmd == "snapshot":
        return cmd_snapshot(args[0] if args else "event")
    elif cmd == "place":
        cmd_place(args[0] if args else "")
    elif cmd == "session-start":
        atomic_write(SESSION, str(int(time.time())) + "\n")
        atomic_write(LOGIN_COUNT, str(login_number() + 1) + "\n")
        slog("login", n=login_number())
    elif cmd == "show":
        print(json.dumps(load_json(LAYOUT, {}) or {}, indent=2, sort_keys=True))
    elif cmd == "forget":
        cmd_forget(args[0] if args else None)
    elif cmd == "launchers":
        cmd_launchers("--unresolved" in args)
    elif cmd == "resolve":
        print(json.dumps(resolve_class(args[0] if args else "", load_ctx()), indent=2))
    elif cmd == "relaunch":
        return cmd_relaunch(args)
    elif cmd == "current":
        cmd_current()
    elif cmd == "log":
        cmd_log(args)
    elif cmd == "picker-json":
        cmd_picker_json()
    else:
        print("usage: gws.py snapshot [TRIGGER]|log [N] [--place]|place ADDR|session-start|show|forget [CLASS]|launchers [--unresolved]|resolve CLASS|relaunch ...", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
