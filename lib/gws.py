#!/usr/bin/env python3
"""Engine for Global Persisted mode. Driven by bin/omarchy-gws-persist.

Who reads layout.json, and when:
  * the recorder (snapshot) reads and writes it, while persisted mode is on;
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

STRIDE = 10
GRACE = 180          # s after session-start in which a class is never truncated
PENDING_TTL = 300    # s a picker launch stays eligible for placement
SIDE_EFFECT = re.compile(r"steam://|VBoxManage|virt-manager|win11")
FIELD_CODE = re.compile(r"%[fFuUdDnNickvm]")
URL_HOST = re.compile(r"https?://([^/\s\"'?#:]+)")
PWA_VIVALDI = re.compile(r"^vivaldi-(.+?)__.*$")
STEAM_CLASS = re.compile(r"^steam_app_(\d+)$")


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


# ── recorder ─────────────────────────────────────────────────────────────────

def cmd_snapshot():
    if not persisted():
        return
    clients, monitors = hypr_json("clients"), hypr_json("monitors")
    bases = load_json(BASES, None)
    if not isinstance(clients, list) or not isinstance(monitors, list) or not isinstance(bases, dict):
        return
    owner = {int(b): n for n, b in bases.items()}

    entries = load_layout()
    ctx = load_ctx()
    stamp = read_text(SESSION)
    try:
        in_grace = stamp is not None and time.time() - int(stamp) < GRACE
    except ValueError:
        in_grace = False
    now = int(time.time())

    current = {}
    for c in clients:
        if not c.get("mapped", True) or c.get("hidden"):
            continue
        cls, wsid = c.get("class") or "", c["workspace"]["id"]
        if not cls or wsid <= 0:
            continue
        name = owner.get(((wsid - 1) // STRIDE) * STRIDE)
        if name is None:
            continue
        current.setdefault(cls, []).append({
            "monitor": name,
            "slot": (wsid - 1) % STRIDE + 1,
            "floating": bool(c.get("floating")),
            "at": c.get("at"),
            "size": c.get("size"),
            "seen": now,
        })

    learned = dict(ctx["learned"])
    for cls in set(current) | set(entries):
        res = resolve_class(cls, ctx)
        if res["command"] is None:
            entries.pop(cls, None)        # unresolved classes are not recorded
            continue
        if res.get("learn"):
            learned[cls] = {"id": res["id"]}
        if cls in current:
            wins, old = current[cls], entries.get(cls, [])
            entries[cls] = wins + old[len(wins):] if in_grace and len(wins) < len(old) else wins
        for w in entries[cls]:
            w["launcher"] = res["command"]

    if learned != ctx["learned"]:
        atomic_json(LEARNED, learned)
    save_layout(entries)


# ── placement: only for windows the login picker started ────────────────────

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
    if me["workspace"]["id"] != target:
        dispatch('hl.dsp.window.move({ workspace = "%d", follow = false, %s })' % (target, sel))
    if want.get("floating") and want.get("at") and want.get("size"):
        if not me.get("floating"):
            dispatch('hl.dsp.window.float({ action = "enable", %s })' % sel)
        dispatch('hl.dsp.window.resize({ x = %d, y = %d, exact = true, %s })'
                 % (want["size"][0], want["size"][1], sel))
        dispatch('hl.dsp.window.move({ x = %d, y = %d, exact = true, %s })'
                 % (want["at"][0], want["at"][1], sel))


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


def picker_label(r):
    """One checklist line. The row id sits last in brackets; commas are replaced
    because gum splits its --selected list on them."""
    return ("%s - %s slot %s  [%s]" % (r["name"], r["monitor"], r["slot"], r["id"])).replace(",", ";")


def cmd_picker_options():
    """Lines of 'DEFAULT<TAB>LABEL' for the launchable rows (open rows are not offered)."""
    for r in build_rows():
        if r["state"] == "launch":
            print("%d\t%s" % (1 if r["default"] else 0, picker_label(r)))


def cmd_picker_ids():
    """Reads the ticked labels on stdin and prints their row ids."""
    for line in sys.stdin:
        m = re.search(r"\[([^\]]+)\]\s*$", line)
        if m:
            print(m.group(1))


def main(argv):
    cmd, args = (argv[0] if argv else ""), argv[1:]
    if cmd == "snapshot":
        cmd_snapshot()
    elif cmd == "place":
        cmd_place(args[0] if args else "")
    elif cmd == "session-start":
        atomic_write(SESSION, str(int(time.time())) + "\n")
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
    elif cmd == "picker-options":
        cmd_picker_options()
    elif cmd == "picker-ids":
        cmd_picker_ids()
    else:
        print("usage: gws.py snapshot|place ADDR|session-start|show|forget [CLASS]|launchers [--unresolved]|resolve CLASS|relaunch ...", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
