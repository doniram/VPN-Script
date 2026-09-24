#!/usr/bin/env bash
# lib/common.sh - shared helpers for scriptvps
# Sourced by CLI, installer and modules.

# shellcheck disable=SC2034  # several constants below are used by other sourced files
[[ -n "${__SVPS_COMMON_LOADED:-}" ]] && return 0
__SVPS_COMMON_LOADED=1

# ---------------------------------------------------------------------------
# Paths & defaults (all overridable via environment for testing)
# ---------------------------------------------------------------------------
SVPS_ETC="${SVPS_ETC:-/etc/scriptvps}"
SVPS_DB="${SVPS_DB:-$SVPS_ETC/db}"
SVPS_CACHE="${SVPS_CACHE:-$SVPS_ETC/.cache}"
SVPS_CLIENTS="${SVPS_CLIENTS:-$SVPS_ETC/clients}"
SVPS_LOG="${SVPS_LOG:-/var/log/scriptvps.log}"
SVPS_ROOT="${SVPS_ROOT:-/opt/scriptvps}"
SVPS_CONFIG="$SVPS_ETC/config.conf"

# Resolve the directory this project lives in (works via symlink).
svps_self_dir() {
  local src="${BASH_SOURCE[0]}"
  local resolved
  resolved="$(readlink -f "$src" 2>/dev/null || echo "$src")"
  (cd "$(dirname "$resolved")/.." && pwd)
}
SVPS_DIR="${SVPS_DIR:-$(svps_self_dir)}"

# ---------------------------------------------------------------------------
# Colors & logging
# ---------------------------------------------------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  # shellcheck disable=SC2034
  C_RESET=$'\033[0m'; C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'
  C_YELLOW=$'\033[1;33m'; C_BLUE=$'\033[1;34m'; C_CYAN=$'\033[1;36m'; C_BOLD=$'\033[1m'
else
  # shellcheck disable=SC2034
  C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""; C_BOLD=""
fi

_logfile() {
  [[ -n "${SVPS_NO_LOGFILE:-}" ]] && return 0
  local dir; dir="$(dirname "$SVPS_LOG")"
  [[ -d "$dir" ]] || mkdir -p "$dir" 2>/dev/null || return 0
  printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$SVPS_LOG" 2>/dev/null || true
}

info() { printf '%s[INFO]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; _logfile "[INFO] $*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; _logfile "[ OK ] $*"; }
warn() { printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; _logfile "[WARN] $*"; }
err()  { printf '%s[FAIL]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; _logfile "[FAIL] $*"; }
die()  { err "$*"; exit 1; }
plain(){ printf '%s\n' "$*"; }

# ---------------------------------------------------------------------------
# Command helpers
# ---------------------------------------------------------------------------
has_cmd() { command -v "$1" >/dev/null 2>&1; }
require_cmd() { has_cmd "$1" || die "Perintah '$1' tidak ditemukan."; }
require_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Jalankan sebagai root (sudo)."; }

# run <description> -- <cmd...>
run() {
  local desc="$1"; shift
  [[ "${1:-}" == "--" ]] && shift
  info "$desc"
  "$@" || die "Gagal: $desc"
}

# ---------------------------------------------------------------------------
# OS detection
# ---------------------------------------------------------------------------
detect_os() {
  SVPS_OS_ID=""; SVPS_OS_VERSION=""; SVPS_OS_CODENAME=""; SVPS_OS_PRETTY=""
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    SVPS_OS_ID="${ID:-}"
    SVPS_OS_VERSION="${VERSION_ID:-}"
    # shellcheck disable=SC2034
    SVPS_OS_CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
    SVPS_OS_PRETTY="${PRETTY_NAME:-}"
  fi
}

ensure_supported_os() {
  detect_os
  if [[ "$SVPS_OS_ID" != "ubuntu" ]]; then
    warn "OS terdeteksi: ${SVPS_OS_PRETTY:-unknown}. Tool ini diuji untuk Ubuntu 22.04/24.04."
    return 0
  fi
  case "$SVPS_OS_VERSION" in
    22.04|24.04) ok "OS didukung: ${SVPS_OS_PRETTY}" ;;
    *) warn "Ubuntu ${SVPS_OS_VERSION} belum diuji resmi (disarankan 22.04/24.04)." ;;
  esac
}

# ---------------------------------------------------------------------------
# Prompt helpers
# ---------------------------------------------------------------------------
confirm() {
  local prompt="${1:-Lanjutkan?}" ans
  read -r -p "$prompt [y/N] " ans || true
  [[ "$ans" =~ ^[Yy]$ ]]
}

prompt_default() {
  local prompt="$1" def="${2:-}" ans
  read -r -p "$prompt [$def] " ans || true
  printf '%s' "${ans:-$def}"
}

# ---------------------------------------------------------------------------
# Filesystem / state
# ---------------------------------------------------------------------------
init_dirs() {
  mkdir -p "$SVPS_ETC" "$SVPS_DB" "$SVPS_CACHE" "$SVPS_CLIENTS"
  chmod 700 "$SVPS_ETC" 2>/dev/null || true
  chmod 700 "$SVPS_CLIENTS" 2>/dev/null || true
}

svps_version() {
  local f="$SVPS_DIR/VERSION"
  if [[ -r "$f" ]]; then cat "$f"; else printf '0.1.0'; fi
}

# ---------------------------------------------------------------------------
# JSON helpers (manual, no jq required)
# ---------------------------------------------------------------------------
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

# ---------------------------------------------------------------------------
# key=value config at $SVPS_CONFIG
# ---------------------------------------------------------------------------
config_get() {
  local key="$1" def="${2:-}" f="$SVPS_CONFIG" v
  [[ -r "$f" ]] || { printf '%s' "$def"; return 0; }
  v="$(grep -E "^${key}=" "$f" 2>/dev/null | tail -n1 | cut -d= -f2-)" || true
  if [[ -n "$v" ]]; then printf '%s' "$v"; else printf '%s' "$def"; fi
}

config_set() {
  local key="$1" val="$2" f="$SVPS_CONFIG" tmp
  init_dirs
  if [[ -f "$f" ]] && grep -qE "^${key}=" "$f"; then
    tmp="$(mktemp)"
    awk -v k="$key" -v v="$val" 'BEGIN{FS=OFS="="} $1==k{print k"="v; next} {print}' "$f" >"$tmp"
    mv "$tmp" "$f"
  elif grep -qE "^${key}=" "$f" 2>/dev/null; then
    : # unreachable, kept for clarity
  else
    printf '%s=%s\n' "$key" "$val" >>"$f"
  fi
  chmod 600 "$f" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Date helpers
# ---------------------------------------------------------------------------
date_add_days() { # <days> -> YYYY-MM-DD
  date -d "+${1} days" +%F 2>/dev/null || date -v "+${1}d" +%F 2>/dev/null
}
date_is_future() { # <YYYY-MM-DD> -> true if in the future
  local t; t="$(date -d "$1" +%s 2>/dev/null)" || return 1
  [[ "$t" -gt "$(date +%s)" ]]
}
