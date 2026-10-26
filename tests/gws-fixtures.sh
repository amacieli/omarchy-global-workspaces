#!/bin/bash
# Shared fixtures for the Global Persisted tests. Source it; do not run it.

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  echo "source tests/gws-fixtures.sh from a test; do not run it directly" >&2
  exit 1
fi

# make_apps DIR: .desktop files that stand in for the menu's app entries.
make_apps() {
  local d=$1
  mkdir -p "$d"
  cat > "$d/MSteamsPWA.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=MS Teams PWA
Exec=omarchy-launch-webapp "https://teams.cloud.microsoft/?clientType=pwa"
StartupWMClass=crx__ompifgpmddkgmclendfeacglnodjjndh
EOF
  cat > "$d/msedge-ompifgpmddkgmclendfeacglnodjjndh-Profile_1.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Microsoft Teams (PWA)
Exec=omarchy-launch-webapp "https://teams.cloud.microsoft/?clientType=pwa"
NoDisplay=true
StartupWMClass=crx__ompifgpmddkgmclendfeacglnodjjndh
EOF
  cat > "$d/Hermes.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Hermes
Exec=foot --app-id=TUI.tile --config=/x/foot-hermes.ini hermes --tui
EOF
  cat > "$d/foot.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Foot
Exec=foot
StartupWMClass=foot
EOF
  cat > "$d/IXION.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=IXION
Exec=steam steam://rungameid/1113120
EOF
  cat > "$d/PLEX.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=PLEX
Exec=omarchy-launch-webapp "https://app.plex.tv/desktop/"
EOF
  cat > "$d/Vivaldi.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Vivaldi
Exec=vivaldi-stable
StartupWMClass=vivaldi-stable
EOF
  cat > "$d/Win11.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Windows 11
Exec=omarchy-launch-win11-vbox
EOF
  cat > "$d/Fieldy.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Fieldy
Exec=fieldy --open %U
StartupWMClass=fieldy
EOF
  cat > "$d/DupeA.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Dupe A
Exec=dupe-a
StartupWMClass=dupeclass
EOF
  cat > "$d/DupeB.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Dupe B
Exec=dupe-b
StartupWMClass=dupeclass
EOF
  cat > "$d/Hidden.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Hidden
Exec=hidden
StartupWMClass=hiddenapp
Hidden=true
EOF
}

# gws_env: fresh HOME, state, app directory and a stub hyprctl (no compositor).
# Sets TMP, STATE, DIR and LOG; exports the environment the engine reads.
# Callers: trap 'rm -rf "$TMP"' EXIT
gws_env() {
  TMP=$(mktemp -d)
  export HOME="$TMP/home" XDG_STATE_HOME="$TMP/state"
  export GWS_DEBOUNCE=0 GWS_PLACE_DELAY=0 GWS_LAUNCH_STAGGER=0 GWS_NO_RELOAD=1
  export GWS_APP_DIRS="$TMP/apps"
  STATE="$XDG_STATE_HOME/omarchy"
  DIR="$STATE/global-workspaces"
  LOG="$TMP/hyprctl.log"
  mkdir -p "$HOME" "$DIR" "$TMP/bin"
  echo '{ "HDMI-A-1": 0, "DP-1": 10, "DP-2": 20 }' > "$STATE/monitor-bases.json"
  echo '[]' > "$TMP/clients.json"
  cat > "$TMP/bin/hyprctl" <<STUB
#!/bin/bash
if [[ "\$1" == clients ]]; then cat "$TMP/clients.json"; exit 0; fi
if [[ "\$1" == monitors ]]; then echo '[{"name":"HDMI-A-1","id":0},{"name":"DP-1","id":1},{"name":"DP-2","id":2}]'; exit 0; fi
echo "\$*" >> "$LOG"
STUB
  chmod +x "$TMP/bin/hyprctl"
  export PATH="$TMP/bin:$PATH"
  make_apps "$TMP/apps"
}

# gws_client ADDRESS CLASS WORKSPACE FLOATING -> one hyprctl client object
gws_client() {
  printf '{"address":"%s","class":"%s","mapped":true,"hidden":false,"floating":%s,"workspace":{"id":%s},"at":[100,200],"size":[800,600]}' \
    "$1" "$2" "$4" "$3"
}

# gws_clients OBJ... -> the window list the stub hyprctl reports
gws_clients() {
  local out="" c
  for c in "$@"; do out+="${out:+,}$c"; done
  echo "[$out]" > "$TMP/clients.json"
}

# gws_layout < JSON -> writes layout.json
gws_layout() { cat > "$DIR/layout.json"; }

gws_persist_on() { : > "$DIR/persisted"; }

# gws_count PATTERN: how many logged hyprctl calls match (0 if none)
gws_count() { grep -c -- "$1" "$LOG" 2>/dev/null || true; }
