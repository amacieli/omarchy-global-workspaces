#!/bin/bash
# install.sh — omarchy-global-workspaces
#
# Installs global workspace switching onto a stock Omarchy setup.
# Safe to re-run: all steps are idempotent.
#
# FIXES INCLUDED:
#   ✅ Issue #1: Workspace materialization (load order race)
#   ✅ Issue #2: Fallback dispatcher syntax (Hyprland 0.56.2+)
#   ✅ Issue #3: Out-of-helper desync (event hook)
#
# What this installs:
#   User scripts (no sudo):
#     ~/.local/bin/omarchy-switch-to-aw       (with Issue #2 fix)
#     ~/.local/bin/omarchy-move-window-to-aw  (with Issue #2 fix)
#
#   User config (no sudo):
#     ~/.config/hypr/toggles/workspace-global.lua  (with Issue #1 & #3 fixes)
#     ~/.config/hypr/bindings.lua                  (if needed)
#
# After install, enable global mode via the Omarchy menu:
#   Trigger → Toggle → Workspace Mode → Global
# Or from a terminal:
#   touch ~/.local/state/omarchy/toggles/hypr/workspace-global.lua
# Then:
#   hyprctl reload

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

# ── User config files ──────────────────────────────────────────────────────
yellow "Installing user configuration files..."

# Install workspace-global.lua to ~/.config/hypr/toggles/
# This file includes all 3 garethevs3 issue fixes:
#   Issue #1: Materialization function (correct load order)
#   Issue #3: Event hook (universal sync coverage)
HYPR_TOGGLES="$HOME/.config/hypr/toggles"
mkdir -p "$HYPR_TOGGLES"

install -m 0644 "$REPO_DIR/config/hypr/toggles/workspace-global.lua" \
  "$HYPR_TOGGLES/workspace-global.lua"
green "  ✓ ~/.config/hypr/toggles/workspace-global.lua (with Issue #1 & #3 fixes)"

# ── User scripts ───────────────────────────────────────────────────────────────
yellow "Installing user scripts..."

mkdir -p "$HOME/.local/bin"

install -m 0755 "$REPO_DIR/bin/omarchy-switch-to-aw" \
  "$HOME/.local/bin/omarchy-switch-to-aw"
green "  ✓ ~/.local/bin/omarchy-switch-to-aw"

install -m 0755 "$REPO_DIR/bin/omarchy-move-window-to-aw" \
  "$HOME/.local/bin/omarchy-move-window-to-aw"
green "  ✓ ~/.local/bin/omarchy-move-window-to-aw"

# ── Ensure ~/.local/bin on PATH ────────────────────────────────────────────────
for rcfile in "$HOME/.bashrc" "$HOME/.zshrc"; do
  if [[ -f "$rcfile" ]] && ! grep -q '\\.local/bin' "$rcfile"; then
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$rcfile"
    info "Added ~/.local/bin to PATH in $rcfile"
  fi
done
export PATH="$HOME/.local/bin:$PATH"

# ── Reload ─────────────────────────────────────────────────────────────────────
yellow "Finalizing..."
if hyprctl reload 2>/dev/null; then
  green "  ✓ hyprctl reload"
else
  yellow "  ! Could not reload — run manually: hyprctl reload"
fi

# ── Done ───────────────────────────────────────────────────────────────────────
echo ""
green "✅ Installation complete."
echo ""
info "ALL 3 GARETHEVS3 FIXES INCLUDED:"
info "  ✓ Issue #1: Workspace materialization (load order race)"
info "  ✓ Issue #2: Fallback dispatcher syntax (Hyprland 0.56.2+)"
info "  ✓ Issue #3: Out-of-helper desync (event hook)"
echo ""
info "To enable global workspace mode:"
info "  touch ~/.local/state/omarchy/toggles/hypr/workspace-global.lua"
info "  hyprctl reload"
echo ""
info "Then use:"
info "  SUPER+1..10        Switch to Workspace slot N (all monitors)"
info "  SUPER+SHIFT+1..10  Move focused window to slot N"
