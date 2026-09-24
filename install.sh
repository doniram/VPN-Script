#!/usr/bin/env bash
# install.sh - scriptvps installer (Ubuntu 22.04/24.04)
set -euo pipefail

ORIG_ARGS=("$@")

INSTALL_SELF="$(readlink -f "${BASH_SOURCE[0]}")"
INSTALL_DIR="$(cd "$(dirname "$INSTALL_SELF")" && pwd)"
# shellcheck source=/dev/null
. "$INSTALL_DIR/lib/common.sh"
# shellcheck source=/dev/null
. "$INSTALL_DIR/lib/net.sh"
# shellcheck source=/dev/null
. "$INSTALL_DIR/lib/verify.sh"
# shellcheck source=/dev/null
. "$INSTALL_DIR/lib/db.sh"
# shellcheck source=/dev/null
. "$INSTALL_DIR/lib/services.sh"
# shellcheck source=/dev/null
. "$INSTALL_DIR/lib/license.sh"
# shellcheck source=/dev/null
. "$INSTALL_DIR/lib/dns.sh"

# ---------------------------------------------------------------------------
SERVICES=""
DOMAIN=""
CF_TOKEN=""
CF_ACCOUNT=""
ACME_EMAIL=""
LICENSE_MODE=""
LICENSE_URL=""
LICENSE_GRACE=""
LICENSE_KEY=""
NON_INTERACTIVE=0
PROFILE=""

usage() {
  cat <<'EOF'
Pemakaian: install.sh [opsi]

  --profile minimal|full     minimal = ssh ovpn wg xray ; full = semua layanan
  --services "ssh ovpn ..."  pilih layanan secara eksplisit
  --domain <host>            domain untuk TLS (opsional)
  --cf-token <token>         Cloudflare API token (Zone.DNS Edit)
  --cf-account <id>          Cloudflare Account ID (opsional)
  --email <addr>             email untuk Let's Encrypt/acme.sh
  --license-mode off|repo    mode lisensi (default: off)
  --license-url <url>        URL manifest lisensi (mode repo)
  --license-grace <days>     masa tenggang (default: 7)
  --license-key <key>        license key
  -y, --non-interactive      jangan bertanya, pakai default
  --no-copy                  jangan salin ke /opt/scriptvps
  -h, --help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="${2:?}"; shift 2 ;;
    --services) SERVICES="${2:?}"; shift 2 ;;
    --domain) DOMAIN="${2:?}"; shift 2 ;;
    --cf-token) CF_TOKEN="${2:?}"; shift 2 ;;
    --cf-account) CF_ACCOUNT="${2:?}"; shift 2 ;;
    --email) ACME_EMAIL="${2:?}"; shift 2 ;;
    --license-mode) LICENSE_MODE="${2:?}"; shift 2 ;;
    --license-url) LICENSE_URL="${2:?}"; shift 2 ;;
    --license-grace) LICENSE_GRACE="${2:?}"; shift 2 ;;
    --license-key) LICENSE_KEY="${2:?}"; shift 2 ;;
    -y|--non-interactive) NON_INTERACTIVE=1; shift ;;
    --no-copy) SVPS_NO_COPY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Opsi tidak dikenal: $1" ;;
  esac
done

profile_services() {
  case "$1" in
    minimal) echo "ssh ovpn wg xray" ;;
    full) echo "$SPVS_ALL_SERVICES" ;;
    *) die "Profil tidak dikenal: $1 (minimal|full)" ;;
  esac
}

select_services_interactive() {
  local all=(ssh ovpn wg xray ss sstp l2tp pptp)
  plain "Pilih layanan yang dipasang (pisahkan dengan koma, contoh: 1,2,3):"
  local i=1
  for s in "${all[@]}"; do
    printf '  %d) %-6s %s\n' "$i" "$s" "$(svps_service_label "$s")"
    i=$((i+1))
  done
  read -r -p "Pilihan [1,2,3,4]: " ans || true
  [[ -z "$ans" ]] && ans="1,2,3,4"
  local out="" n
  for n in ${ans//,/ }; do
    [[ "$n" =~ ^[0-9]+$ ]] || continue
    (( n >= 1 && n <= ${#all[@]} )) && out="$out ${all[$((n-1))]}"
  done
  echo "$out"
}

# ---------------------------------------------------------------------------
# Copy to /opt/scriptvps and re-exec
if [[ "$INSTALL_DIR" != "$SVPS_ROOT" && "${SVPS_NO_COPY:-0}" != "1" ]]; then
  info "Menyalin proyek ke $SVPS_ROOT"
  mkdir -p "$SVPS_ROOT"
  cp -a "$INSTALL_DIR/." "$SVPS_ROOT/"
  chmod +x "$SVPS_ROOT/install.sh" "$SVPS_ROOT/scriptvps" 2>/dev/null || true
  chmod +x "$SVPS_ROOT"/modules/*.sh "$SVPS_ROOT"/parts/*.sh "$SVPS_ROOT"/tools/*.sh 2>/dev/null || true
  exec "$SVPS_ROOT/install.sh" "${ORIG_ARGS[@]}"
fi

require_root
ensure_supported_os
init_dirs

# ---------------------------------------------------------------------------
# Configuration
if [[ -z "$SERVICES" ]]; then
  if [[ -n "$PROFILE" ]]; then
    SERVICES="$(profile_services "$PROFILE")"
  elif (( NON_INTERACTIVE )); then
    SERVICES="ssh ovpn wg xray"
  else
    SERVICES="$(select_services_interactive)"
  fi
fi
SERVICES="$(echo "$SERVICES" | xargs)"   # trim
[[ -z "$SERVICES" ]] && die "Tidak ada layanan dipilih."

if (( ! NON_INTERACTIVE )); then
  [[ -z "$DOMAIN" ]] && DOMAIN="$(prompt_default "Domain untuk TLS (kosongkan = self-signed)" "")"
  if [[ -n "$DOMAIN" && -z "$CF_TOKEN" ]]; then
    CF_TOKEN="$(prompt_default "Cloudflare API token (kosongkan = self-signed)" "")"
    [[ -n "$CF_TOKEN" ]] && CF_ACCOUNT="$(prompt_default "Cloudflare Account ID (opsional)" "")"
    ACME_EMAIL="$(prompt_default "Email untuk Let's Encrypt" "admin@${DOMAIN}")"
  fi
  if [[ -z "$LICENSE_MODE" ]]; then
    if confirm "Aktifkan lisensi/registrasi?"; then LICENSE_MODE="repo"; else LICENSE_MODE="off"; fi
  fi
fi

[[ -z "$LICENSE_MODE" ]] && LICENSE_MODE="off"
config_set install_date "$(date +%F)"
config_set oscodename "${SVPS_OS_CODENAME:-}"
[[ -n "$DOMAIN" ]] && config_set domain "$DOMAIN"
[[ -n "$CF_TOKEN" ]] && config_set cloudflare_token "$CF_TOKEN"
[[ -n "$CF_ACCOUNT" ]] && config_set cloudflare_account_id "$CF_ACCOUNT"
[[ -n "$ACME_EMAIL" ]] && config_set acme_email "$ACME_EMAIL"
config_set license_mode "$LICENSE_MODE"
[[ -n "$LICENSE_URL" ]] && config_set license_manifest_url "$LICENSE_URL"
[[ -n "$LICENSE_GRACE" ]] && config_set license_grace_days "$LICENSE_GRACE"
[[ -n "$LICENSE_KEY" ]] && license_set_key "$LICENSE_KEY"

license_mark_first_run

# ---------------------------------------------------------------------------
# Install services
for svc in $SERVICES; do
  if ! svps_service_available "$svc"; then
    warn "Modul '$svc' belum tersedia; dilewati."
    continue
  fi
  svps_load_service "$svc"
  prefix="$(svps_service_prefix "$svc")"
  fn="${prefix}_install"
  declare -F "$fn" >/dev/null 2>&1 || { warn "Modul '$svc' belum tersedia; dilewati."; continue; }
  ( "$fn" ) || warn "Instalasi modul '$svc' gagal sebagian."
done

# ---------------------------------------------------------------------------
# CLI symlink + systemd timer
ln -sf "$SVPS_ROOT/scriptvps" /usr/local/bin/scriptvps
chmod +x "$SVPS_ROOT/scriptvps"
info "Memasang systemd timer (auto-expire harian)"
install -m 0644 "$SVPS_ROOT/systemd/scriptvps-check.service" /etc/systemd/system/ 2>/dev/null || true
install -m 0644 "$SVPS_ROOT/systemd/scriptvps-check.timer" /etc/systemd/system/ 2>/dev/null || true
systemctl daemon-reload 2>/dev/null || true
systemctl enable --now scriptvps-check.timer >/dev/null 2>&1 || warn "Timer tidak aktif (mungkin tanpa systemd)."

# ---------------------------------------------------------------------------
clear 2>/dev/null || true
plain "${C_GREEN}${C_BOLD}Instalasi scriptvps selesai.${C_RESET}"
plain ""
plain "  Versi       : $(svps_version)"
plain "  Layanan     : $SERVICES"
plain "  Domain      : ${DOMAIN:-<self-signed>}"
plain "  Lisensi     : $LICENSE_MODE"
plain "  CLI         : scriptvps (menu / status / add / list ...)"
plain ""
plain "Langkah berikutnya:"
plain "  scriptvps status"
plain "  scriptvps add ssh user1 --days 30"
plain "  scriptvps menu"
