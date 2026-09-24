#!/usr/bin/env bash
# parts/menu.sh - interactive text menu (calls the scriptvps CLI)
set -euo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
SELF_DIR="$(cd "$(dirname "$SELF")" && pwd)"
# shellcheck source=/dev/null
. "$SELF_DIR/../lib/common.sh"
# shellcheck source=/dev/null
. "$SELF_DIR/../lib/net.sh"
# shellcheck source=/dev/null
. "$SELF_DIR/../lib/verify.sh"
# shellcheck source=/dev/null
. "$SELF_DIR/../lib/db.sh"
# shellcheck source=/dev/null
. "$SELF_DIR/../lib/services.sh"
# shellcheck source=/dev/null
. "$SELF_DIR/../lib/license.sh"
# shellcheck source=/dev/null
. "$SELF_DIR/../lib/dns.sh"

CLI="$SVPS_DIR/scriptvps"
[[ -x "$CLI" ]] || CLI="scriptvps"

print_header() {
  clear 2>/dev/null || true
  plain "${C_CYAN}${C_BOLD}"
  cat <<'BANNER'
   ____            _       __     ______  ____
  / __/ ___ ______(_)___ _/ /_   / __/ / / __/
 _\ \/ -_) __/ __/ / _ \/ __/  / _// /_/ _ \
/___/\__/_/  \__/_/\___/\__/  /_/  \___/___/
BANNER
  plain "${C_RESET}"
  plain " Host: ${C_BOLD}$(hostname)${C_RESET}   IP: $(public_ip || echo '?')"
  plain " Versi: $(svps_version)   Lisensi: $(license_status)"
  plain ""
}

service_menu() {
  local svc="$1" label="$2"
  while true; do
    print_header
    plain "${C_BOLD}>> $label${C_RESET}"
    plain "  1) Daftar akun"
    plain "  2) Tambah akun"
    plain "  3) Hapus akun"
    plain "  4) Perpanjang akun"
    plain "  0) Kembali"
    read -r -p "Pilih: " c || true
    case "$c" in
      1) "$CLI" list "$svc"; read -r -p "Enter..." _ || true ;;
      2)
        read -r -p "Nama: " name || true
        read -r -p "Hari [30]: " days || true; days="${days:-30}"
        if [[ -n "$name" ]]; then "$CLI" add "$svc" "$name" --days "$days" || true; fi
        read -r -p "Enter..." _ || true ;;
      3)
        read -r -p "Nama: " name || true
        if [[ -n "$name" ]]; then "$CLI" del "$svc" "$name" || true; fi
        read -r -p "Enter..." _ || true ;;
      4)
        read -r -p "Nama: " name || true
        read -r -p "Hari [30]: " days || true; days="${days:-30}"
        if [[ -n "$name" ]]; then "$CLI" renew "$svc" "$name" --days "$days" || true; fi
        read -r -p "Enter..." _ || true ;;
      0) return ;;
      *) ;;
    esac
  done
}

while true; do
  print_header
  plain "${C_BOLD}Menu Utama${C_RESET}"
  plain "  1) SSH             5) Shadowsocks"
  plain "  2) OpenVPN         6) SSTP"
  plain "  3) WireGuard       7) L2TP"
  plain "  4) Xray            8) PPTP"
  plain "  9) Status server   10) Bersihkan kedaluwarsa"
  plain "  11) Info lisensi   12) Update script"
  plain "  0) Keluar"
  read -r -p "Pilih: " c || true
  case "$c" in
    1) service_menu ssh  "SSH" ;;
    2) service_menu ovpn "OpenVPN" ;;
    3) service_menu wg   "WireGuard" ;;
    4) service_menu xray "Xray" ;;
    5) service_menu ss   "Shadowsocks" ;;
    6) service_menu sstp "SSTP" ;;
    7) service_menu l2tp "L2TP" ;;
    8) service_menu pptp "PPTP" ;;
    9) "$CLI" status; read -r -p "Enter..." _ || true ;;
    10) "$CLI" check; read -r -p "Enter..." _ || true ;;
    11) license_info; read -r -p "Enter..." _ || true ;;
    12)
      if [[ -d "$SVPS_DIR/.git" ]]; then ( cd "$SVPS_DIR" && git pull --ff-only ) || true; else warn "Bukan repo git."; fi
      read -r -p "Enter..." _ || true ;;
    0) exit 0 ;;
    *) ;;
  esac
done
