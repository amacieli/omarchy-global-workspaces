#!/bin/bash
# install.sh — omarchy-global-workspaces
#
# Installs global workspace switching onto a stock Omarchy setup.
# Safe to re-run: all steps are idempotent.
#
# What this installs:
#   System scripts (require sudo):
#     /usr/share/omarchy/bin/omarchy-hyprland-workspace-global-switch
#     /usr/share/omarchy/bin/omarchy-hyprland-workspace-global-move-window
#     /usr/share/omarchy/default/hypr/toggles/workspace-global.lua
#     /usr/share/omarchy/shell/plugins/bar/widgets/Workspaces.qml
#
#   User scripts (no sudo):
#     ~/.local/bin/omarchy-switch-to-aw
#     ~/.local/bin/omarchy-move-window-to-aw
#
#   User config patches (no sudo):
#     ~/.config/omarchy/extensions/omarchy-menu.jsonc  (merged)
#     ~/.config/hypr/bindings.lua                      (block appended if absent)
#
# After install, enable global mode via the Omarchy menu:
#   Trigger → Toggle → Workspace Mode → Global
# Or from a terminal:
#   omarchy-hyprland-toggle workspace-global on

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Colour helpers ─────────────────────────────────────────────────────────────
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*"; }
info()   { printf '  %s\n' "$*"; }

# ── Prereq check ───────────────────────────────────────────────────────────────
for cmd in hyprctl jq; do
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

# ── System files (sudo) ────────────────────────────────────────────────────────
yellow "Installing system files (sudo required)..."

# Back up Workspaces.qml if no backup exists yet.
WS_DEST="$OMARCHY_PATH/shell/plugins/bar/widgets/Workspaces.qml"
if [[ ! -f "${WS_DEST}.orig" ]]; then
  sudo cp "$WS_DEST" "${WS_DEST}.orig"
  info "Backed up original Workspaces.qml → Workspaces.qml.orig"
fi

sudo install -m 0644 "$REPO_DIR/shell/Workspaces.qml" \
  "$OMARCHY_PATH/shell/plugins/bar/widgets/Workspaces.qml"
green "  ✓ Workspaces.qml"

sudo install -m 0644 "$REPO_DIR/hypr/toggles/workspace-global.lua" \
  "$OMARCHY_PATH/default/hypr/toggles/workspace-global.lua"
green "  ✓ hypr/toggles/workspace-global.lua"

sudo install -m 0755 "$REPO_DIR/bin/omarchy-hyprland-workspace-global-switch" \
  "$OMARCHY_PATH/bin/omarchy-hyprland-workspace-global-switch"
green "  ✓ bin/omarchy-hyprland-workspace-global-switch"

sudo install -m 0755 "$REPO_DIR/bin/omarchy-hyprland-workspace-global-move-window" \
  "$OMARCHY_PATH/bin/omarchy-hyprland-workspace-global-move-window"
green "  ✓ bin/omarchy-hyprland-workspace-global-move-window"

sudo install -m 0755 "$REPO_DIR/bin/omarchy-monitor-base" \
  "$OMARCHY_PATH/bin/omarchy-monitor-base"
green "  ✓ bin/omarchy-monitor-base"

sudo install -m 0755 "$REPO_DIR/bin/omarchy-ensure-workspaces" \
  "$OMARCHY_PATH/bin/omarchy-ensure-workspaces"
green "  ✓ bin/omarchy-ensure-workspaces"

sudo install -m 0755 "$REPO_DIR/bin/omarchy-recover-stranded-windows" \
  "$OMARCHY_PATH/bin/omarchy-recover-stranded-windows"
green "  ✓ bin/omarchy-recover-stranded-windows"

# ── User scripts ───────────────────────────────────────────────────────────────
yellow "Installing user scripts..."

mkdir -p "$HOME/.local/bin"

install -m 0755 "$REPO_DIR/bin/omarchy-switch-to-aw" \
  "$HOME/.local/bin/omarchy-switch-to-aw"
green "  ✓ ~/.local/bin/omarchy-switch-to-aw"

install -m 0755 "$REPO_DIR/bin/omarchy-move-window-to-aw" \
  "$HOME/.local/bin/omarchy-move-window-to-aw"
green "  ✓ ~/.local/bin/omarchy-move-window-to-aw"

# Copy recovery/ensure scripts to user bin for direct access
install -m 0755 "$REPO_DIR/bin/omarchy-ensure-workspaces" \
  "$HOME/.local/bin/omarchy-ensure-workspaces"
green "  ✓ ~/.local/bin/omarchy-ensure-workspaces"

install -m 0755 "$REPO_DIR/bin/omarchy-recover-stranded-windows" \
  "$HOME/.local/bin/omarchy-recover-stranded-windows"
green "  ✓ ~/.local/bin/omarchy-recover-stranded-windows"

# Ensure ~/.local/bin is on PATH (add to .bashrc/.zshrc if missing).
for rcfile in "$HOME/.bashrc" "$HOME/.zshrc"; do
  if [[ -f "$rcfile" ]] && ! grep -q '\.local/bin' "$rcfile"; then
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$rcfile"
    info "Added ~/.local/bin to PATH in $rcfile"
  fi
done
export PATH="$HOME/.local/bin:$PATH"

# ── Omarchy menu extension ─────────────────────────────────────────────────────
yellow "Installing Omarchy menu extension..."

MENU_DEST="$HOME/.config/omarchy/extensions/omarchy-menu.jsonc"
MENU_SRC="$REPO_DIR/config/omarchy/extensions/omarchy-menu.jsonc"

mkdir -p "$(dirname "$MENU_DEST")"

if [[ ! -f "$MENU_DEST" ]]; then
  # No existing extension file — install directly.
  cp "$MENU_SRC" "$MENU_DEST"
  green "  ✓ ~/.config/omarchy/extensions/omarchy-menu.jsonc (created)"
else
  # File exists — check whether our keys are already present.
  if grep -q "workspace-mode" "$MENU_DEST"; then
    info "Menu extension already contains workspace-mode entries — skipping."
  else
    # Merge: strip the closing } from the existing file and append our entries.
    # Both files are JSONC objects; we merge at the top-level key level.
    TMP=$(mktemp)
    # Remove trailing whitespace/newline and final closing brace from existing.
    sed '$ s/[[:space:]]*}[[:space:]]*$/,/' "$MENU_DEST" > "$TMP"
    # Append our entries (strip opening { and keep everything else).
    sed '1 s/^[[:space:]]*{//' "$MENU_SRC" >> "$TMP"
    mv "$TMP" "$MENU_DEST"
    green "  ✓ ~/.config/omarchy/extensions/omarchy-menu.jsonc (merged)"
  fi
fi

# ── Hyprland user bindings ─────────────────────────────────────────────────────
yellow "Patching Hyprland user bindings..."

BINDINGS="$HOME/.config/hypr/bindings.lua"
BINDINGS_BLOCK="$REPO_DIR/hypr/bindings-global-workspaces.lua"

if [[ ! -f "$BINDINGS" ]]; then
  # Create a minimal bindings file with just our block.
  cp "$BINDINGS_BLOCK" "$BINDINGS"
  green "  ✓ ~/.config/hypr/bindings.lua (created)"
else
  if grep -q "omarchy-switch-to-aw\|omarchy-global-workspaces" "$BINDINGS"; then
    info "Bindings already contain global workspace entries — skipping."
  else
    printf '\n' >> "$BINDINGS"
    cat "$BINDINGS_BLOCK" >> "$BINDINGS"
    green "  ✓ ~/.config/hypr/bindings.lua (block appended)"
  fi
fi

# ── Seed monitor base map ──────────────────────────────────────────────────────
yellow "Seeding stable monitor base map..."
if command -v omarchy-monitor-base &>/dev/null || [[ -x "$OMARCHY_PATH/bin/omarchy-monitor-base" ]]; then
  # Use the just-installed system copy if not yet on PATH.
  MONITOR_BASE_BIN="${OMARCHY_PATH}/bin/omarchy-monitor-base"
  if "$MONITOR_BASE_BIN" sync 2>/dev/null; then
    green "  ✓ monitor-bases.json seeded"
    info "    $(cat "$HOME/.local/state/omarchy/monitor-bases.json" 2>/dev/null || echo '(not yet created)')"
  else
    yellow "  ! Could not seed monitor bases — run: omarchy-monitor-base sync"
  fi
else
  yellow "  ! omarchy-monitor-base not found — run after install: omarchy-monitor-base sync"
fi

# ── Reload ─────────────────────────────────────────────────────────────────────
yellow "Reloading Hyprland config..."
if hyprctl reload 2>/dev/null; then
  green "  ✓ hyprctl reload"
else
  yellow "  ! Could not reload Hyprland automatically — run: hyprctl reload"
fi

yellow "Restarting Omarchy shell..."
if command -v omarchy-restart-shell &>/dev/null; then
  omarchy-restart-shell 2>/dev/null || true
  green "  ✓ omarchy-restart-shell"
else
  yellow "  ! omarchy-restart-shell not found — restart the shell manually."
fi

# ── Done ───────────────────────────────────────────────────────────────────────
echo ""
green "Installation complete."
info "To enable global workspace mode:"
info "  Omarchy menu → Trigger → Toggle → Workspace Mode → Global"
info "  or: omarchy-hyprland-toggle workspace-global on"
info ""
info "Hotkeys:"
info "  SUPER+1..5         Switch to Apparent Workspace N (all monitors)"
info "  SUPER+SHIFT+1..5   Move focused window to AW N (silently)"
