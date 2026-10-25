#!/bin/bash
# Shared helpers for the plugin's shell tests. Source it; do not run it.

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  echo "source tests/helpers.sh from a test; do not run it directly" >&2
  exit 1
fi

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export ROOT

pass() { printf 'ok - %s\n' "$1"; }

fail() {
  local description="$1" detail="${2:-}"
  [[ -n $detail ]] && printf '%s\n' "$detail" >&2
  printf 'not ok - %s\n' "$description" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null || fail "required command is available: $1"
}
