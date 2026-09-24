#!/usr/bin/env bash
# lib/license.sh - optional license / IP-registration gate
#
# Design goals:
#   * non-destructive: never deletes the installer, never stops services
#   * no hardcoded secrets/tokens (only reads a public manifest)
#   * offline tolerant: uses cached manifest + last known token
#   * grace period before enforcing
#
# Manifest (TSV), fetched from a URL such as raw.githubusercontent.com:
#   # scriptvps license manifest v1
#   <key_sha256>	<name>	<plan>	<expires>	<ip_sha256_csv>	<features_csv>
#
# Config keys (in /etc/scriptvps/config.conf):
#   license_mode = repo|off      (off => internal build, always allowed)
#   license_manifest_url = https://...
#   license_grace_days = 7
#   license_cache_hours = 24
#   license_ip_salt = scriptvps-v1

[[ -n "${__SVPS_LICENSE_LOADED:-}" ]] && return 0
__SVPS_LICENSE_LOADED=1

SVPS_LICENSE_KEY_FILE="$SVPS_ETC/license.key"
SVPS_LICENSE_TOKEN_FILE="$SVPS_ETC/.license"
SVPS_LICENSE_FIRST_RUN="$SVPS_ETC/first-run"
SVPS_LICENSE_CACHE="$SVPS_CACHE/licenses.tsv"

license_mode()      { config_get license_mode "off"; }
license_required()  { [[ "$(license_mode)" != "off" ]]; }
license_ip_salt()   { config_get license_ip_salt "scriptvps-v1"; }
license_grace_days(){ config_get license_grace_days "7"; }
license_cache_hours(){ config_get license_cache_hours "24"; }
license_manifest_url(){ config_get license_manifest_url ""; }

license_mark_first_run() {
  [[ -f "$SVPS_LICENSE_FIRST_RUN" ]] || date +%s >"$SVPS_LICENSE_FIRST_RUN"
  chmod 600 "$SVPS_LICENSE_FIRST_RUN" 2>/dev/null || true
}

license_read_key() {
  if [[ -n "${SVPS_LICENSE_KEY:-}" ]]; then printf '%s' "$SVPS_LICENSE_KEY"; return 0; fi
  [[ -r "$SVPS_LICENSE_KEY_FILE" ]] || return 1
  tr -d '[:space:]' <"$SVPS_LICENSE_KEY_FILE"
}

license_set_key() {
  init_dirs
  printf '%s\n' "$1" >"$SVPS_LICENSE_KEY_FILE"
  chmod 600 "$SVPS_LICENSE_KEY_FILE"
  rm -f "$SVPS_LICENSE_TOKEN_FILE"
}

license_hash() { printf '%s' "$1" | sha256sum | awk '{print $1}'; }
license_ip_hash() { printf '%s%s' "$(license_ip_salt)" "$1" | sha256sum | awk '{print $1}'; }

license_grace_ok() {
  license_mark_first_run
  local first grace
  first="$(cat "$SVPS_LICENSE_FIRST_RUN" 2>/dev/null || echo 0)"
  grace="$(license_grace_days)"
  (( $(date +%s) - first < grace * 86400 ))
}

license_grace_left() {
  license_mark_first_run
  local first grace
  first="$(cat "$SVPS_LICENSE_FIRST_RUN" 2>/dev/null || echo 0)"
  grace="$(license_grace_days)"
  local left=$(( (first + grace * 86400 - $(date +%s)) / 86400 ))
  (( left < 0 )) && left=0
  echo "$left"
}

# --- internal: look up the key in the manifest -----------------------------
# prints "<expires>\t<ip_csv>\t<features>" on match
_license_lookup() {
  local key_hash="$1" url body
  url="$(license_manifest_url)"
  [[ -n "$url" ]] || return 1
  body="$(fetch_cached "$url" "$SVPS_LICENSE_CACHE" "$(license_cache_hours)")" || return 1
  printf '%s\n' "$body" | awk -F'\t' -v k="$key_hash" '!/^#/ && NF && $1==k {print $4 "\t" $5 "\t" $6; exit}'
}

# license_status -> off|unconfigured|licensed|grace|expired|unregistered|nokey
license_status() {
  license_required || { echo "off"; return 0; }

  local key; key="$(license_read_key 2>/dev/null || true)"
  if [[ -z "$key" ]]; then
    if license_grace_ok; then echo "grace"; else echo "nokey"; fi
    return 0
  fi

  local key_hash ip ip_hash line exp ipcsv feats
  key_hash="$(license_hash "$key")"
  ip="$(public_ip || true)"
  ip_hash="$(license_ip_hash "$ip")"

  line="$(_license_lookup "$key_hash" || true)"
  if [[ -z "$line" ]]; then
    if license_grace_ok; then echo "grace"; else echo "unregistered"; fi
    return 0
  fi
  exp="$(printf '%s' "$line" | cut -f1)"
  ipcsv="$(printf '%s' "$line" | cut -f2)"
  feats="$(printf '%s' "$line" | cut -f3)"

  if date_is_future "$exp" 2>/dev/null || [[ -z "$exp" || "$exp" == "-" ]]; then
    if [[ -z "$ipcsv" || "$ipcsv" == "-" || ",$ipcsv," == *",$ip_hash,"* ]]; then
      # cache a token for offline use
      printf 'key_hash=%s\nexpires=%s\nfeatures=%s\nchecked=%s\n' \
        "$key_hash" "$exp" "$feats" "$(date +%s)" >"$SVPS_LICENSE_TOKEN_FILE" 2>/dev/null || true
      chmod 600 "$SVPS_LICENSE_TOKEN_FILE" 2>/dev/null || true
      echo "licensed"
      return 0
    fi
    # key valid but this IP not registered
    if license_grace_ok; then echo "grace"; else echo "ip_unregistered"; fi
    return 0
  fi

  echo "expired"
}

license_allowed() {
  case "$(license_status)" in
    off|licensed|grace) return 0 ;;
    *) return 1 ;;
  esac
}

# license_require - for write operations; prints a helpful message and fails
license_require() {
  local st; st="$(license_status)"
  case "$st" in
    off|licensed) return 0 ;;
    grace)
      warn "Belum terdaftar. Masa tenggang tersisa ${C_BOLD}$(license_grace_left) hari${C_RESET}."
      return 0 ;;
    *)
      err "Lisensi tidak valid ($st). Operasi dibatalkan."
      plain ""
      plain "${C_BOLD}Cara registrasi:${C_RESET}"
      plain "  1. Kirim license key (atau minta kunci) ke admin."
      plain "  2. Pasang dengan:  scriptvps license set <KEY>"
      plain "  3. Pastikan IP server sudah didaftarkan di manifest."
      plain ""
      return 1 ;;
  esac
}

license_warn() {
  local st; st="$(license_status)"
  case "$st" in
    grace) warn "Belum terdaftar; masa tenggang ${C_BOLD}$(license_grace_left) hari${C_RESET}." ;;
    licensed|off) : ;;
    *) warn "Lisensi tidak valid ($st) - operasi tulis akan diblokir." ;;
  esac
  return 0
}

license_info() {
  local key key_hash ip ip_hash
  key="$(license_read_key 2>/dev/null || true)"
  key_hash=""; [[ -n "$key" ]] && key_hash="$(license_hash "$key")"
  ip="$(public_ip || true)"
  ip_hash="$(license_ip_hash "$ip")"
  printf 'mode=%s\n' "$(license_mode)"
  printf 'status=%s\n' "$(license_status)"
  printf 'grace_left_days=%s\n' "$(license_grace_left)"
  printf 'key_present=%s\n' "$([[ -n "$key" ]] && echo yes || echo no)"
  printf 'key_hash=%s\n' "$key_hash"
  printf 'server_ip=%s\n' "$ip"
  printf 'ip_hash=%s\n' "$ip_hash"
  printf 'manifest_url=%s\n' "$(license_manifest_url)"
}
