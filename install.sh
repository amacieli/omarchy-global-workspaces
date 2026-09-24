#!/bin/bash
# install.sh — omarchy-global-workspaces
#
# Installs the global workspace switching feature onto a stock Omarchy setup.
# This mirrors exactly what the PR (omacom/omarchy#12978) adds to the main
# Omarchy tree, for users who want to test it before the PR merges.
#
# Safe to re-run: all steps are idempotent.
#
# FILES INSTALLED:
#
#   hypr/toggles/workspace-global.lua
#     → $OMARCHY_PATH/default/hypr/toggles/workspace-global.lua
#       (enables omarchy-hyprland-toggle workspace-global on|off|toggle)
#
#   bin/omarchy-switch-to-aw
#     → ~/.local/bin/omarchy-switch-to-aw
#
#   bin/omarchy-move-window-to-aw
#     → ~/.local/bin/omarchy-move-window-to-aw
#
#   bin/omarchy-monitor-base
#     → ~/.local/bin/omarchy-monitor-base
#
#   bin/omarchy-hyprland-workspace-global-switch
#     → ~/.local/bin/omarchy-hyprland-workspace-global-switch
#
#   bin/omarchy-hyprland-workspace-global-move-window
#     → ~/.local/bin/omarchy-hyprland-workspace-global-move-window
#
#   bin/omarchy-ensure-workspaces
#     → ~/.local/bin/omarchy-ensure-workspaces
#
#   bin/omarchy-recover-stranded-windows
#     → ~/.local/bin/omarchy-recover-stranded-windows
#
#   shell/Workspaces.qml
#     → $OMARCHY_PATH/shell/plugins/bar/widgets/Workspaces.qml
#       (global-mode aware bar widget — backed up as Workspaces.qml.bak)
#
#   hypr/bindings-global-workspaces.lua (block appended to):
#     → ~/.config/hypr/bindings.lua
#       (SUPER+1-10 and SUPER+SHIFT+1-10 routed through omarchy-switch-to-aw
#        and omarchy-move-window-to-aw; skipped if block is already present)
#
# ENABLING GLOBAL MODE (after install):
#   omarchy-hyprland-toggle workspace-global on
#   # or: touch ~/.local/state/omarchy/toggles/hypr/workspace-global.lua
#   hyprctl reload
#
# DISABLING:
#   omarchy-hyprland-toggle workspace-global off
#   hyprctl reload

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Colour helpers ─────────────────────────────────────────────────────────────
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*"; }
info()   { printf '  %s\n' "$*"; }

# ── Prereqs ────────────────────────────────────────────────────────────────────
for cmd in hyprctl python3; do
  if ! command -v "$cmd" &>/dev/null; then
    red "ERROR: required command not found: $cmd"
    exit 1
  fi
done

OMARCHY_PATH="${OMARCHY_PATH:-/usr/share/omarchy}"
if [[ ! -d "$OMARCHY_PATH" ]]; then
  red "ERROR: Omarchy not found at $OMARCHY_PATH"
  red "Set OMARCHY_PATH if installed elsewhere."
  exit 1
fi

# ── Toggle file → Omarchy default tree ────────────────────────────────────────
yellow "Installing toggle module..."

TOGGLES_DIR="$OMARCHY_PATH/default/hypr/toggles"
if [[ -w "$TOGGLES_DIR" ]]; then
  install -m 0644 "$REPO_DIR/hypr/toggles/workspace-global.lua" \
    "$TOGGLES_DIR/workspace-global.lua"
  green "  ✓ $TOGGLES_DIR/workspace-global.lua"
else
  yellow "  ! $TOGGLES_DIR is not writable — trying sudo..."
  sudo install -m 0644 "$REPO_DIR/hypr/toggles/workspace-global.lua" \
    "$TOGGLES_DIR/workspace-global.lua"
  green "  ✓ $TOGGLES_DIR/workspace-global.lua (via sudo)"
fi

# ── User scripts → ~/.local/bin ───────────────────────────────────────────────
yellow "Installing helper scripts..."

mkdir -p "$HOME/.local/bin"

for script in \
  omarchy-switch-to-aw \
  omarchy-move-window-to-aw \
  omarchy-monitor-base \
  omarchy-hyprland-workspace-global-switch \
  omarchy-hyprland-workspace-global-move-window \
  omarchy-ensure-workspaces \
  omarchy-recover-stranded-windows
do
  install -m 0755 "$REPO_DIR/bin/$script" "$HOME/.local/bin/$script"
  green "  ✓ ~/.local/bin/$script"
done

# ── Bar widget → Omarchy shell tree ───────────────────────────────────────────
yellow "Installing bar widget (Workspaces.qml)..."

WIDGET_DIR="$OMARCHY_PATH/shell/plugins/bar/widgets"
WIDGET_FILE="$WIDGET_DIR/Workspaces.qml"

if [[ -f "$WIDGET_FILE" ]]; then
  # Back up the original before overwriting
  if [[ -w "$WIDGET_DIR" ]]; then
    cp "$WIDGET_FILE" "${WIDGET_FILE}.bak"
    install -m 0644 "$REPO_DIR/shell/Workspaces.qml" "$WIDGET_FILE"
  else
    sudo cp "$WIDGET_FILE" "${WIDGET_FILE}.bak"
    sudo install -m 0644 "$REPO_DIR/shell/Workspaces.qml" "$WIDGET_FILE"
  fi
  green "  ✓ $WIDGET_FILE (original backed up as Workspaces.qml.bak)"
else
  yellow "  ! $WIDGET_FILE not found — skipping bar widget install"
  yellow "    (Omarchy path may differ; copy shell/Workspaces.qml manually)"
fi

# ── Keybindings → ~/.config/hypr/bindings.lua ─────────────────────────────────
# Without these bindings, SUPER+N calls Hyprland's raw workspace dispatcher,
# bypassing omarchy-switch-to-aw and breaking global mode silently.
# The block is appended only once — idempotent via sentinel comment.
yellow "Installing keybindings..."

BINDINGS_FILE="$HOME/.config/hypr/bindings.lua"
BINDINGS_SENTINEL="-- ── Global workspace switching"
BINDINGS_BLOCK="$REPO_DIR/hypr/bindings-global-workspaces.lua"

if [[ ! -f "$BINDINGS_FILE" ]]; then
  yellow "  ! ~/.config/hypr/bindings.lua not found — skipping auto-install"
  yellow "    Add the keybindings manually by appending:"
  yellow "    $BINDINGS_BLOCK"
elif grep -qF -- "$BINDINGS_SENTINEL" "$BINDINGS_FILE"; then
  green "  ✓ ~/.config/hypr/bindings.lua (keybindings already present — skipped)"
else
  cat "$BINDINGS_BLOCK" >> "$BINDINGS_FILE"
  green "  ✓ ~/.config/hypr/bindings.lua (keybinding block appended)"
fi

# ── Ensure ~/.local/bin on PATH ────────────────────────────────────────────────
for rcfile in "$HOME/.bashrc" "$HOME/.zshrc"; do
  if [[ -f "$rcfile" ]] && ! grep -q '\.local/bin' "$rcfile"; then
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$rcfile"
    info "Added ~/.local/bin to PATH in $rcfile"
  fi
done
export PATH="$HOME/.local/bin:$PATH"

# ── Initialise monitor bases ──────────────────────────────────────────────────
yellow "Initialising monitor workspace bases..."
if [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
  if omarchy-monitor-base sync 2>/dev/null; then
    green "  ✓ Monitor bases initialised"
  else
    yellow "  ! Could not initialise bases now — will run automatically on next Hyprland reload"
  fi
else
  info "Not inside a Hyprland session — bases will be initialised on first reload"
fi

# ── Done ───────────────────────────────────────────────────────────────────────
echo ""
green "✅ Installation complete."
echo ""
info "To enable global workspace mode:"
info "  omarchy-hyprland-toggle workspace-global on"
info "  hyprctl reload"
echo ""
info "To disable:"
info "  omarchy-hyprland-toggle workspace-global off"
info "  hyprctl reload"
echo ""
info "To restore the original bar widget:"
info "  sudo cp ${WIDGET_FILE}.bak $WIDGET_FILE"
