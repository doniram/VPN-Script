#!/usr/bin/env bash
# parts/menu.sh - attractive text menu (dashboard + per-service panels)
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
# shellcheck source=/dev/null
. "$SELF_DIR/../lib/quota.sh"
# shellcheck source=/dev/null
. "$SELF_DIR/../lib/ui.sh"
# shellcheck source=/dev/null
. "$SELF_DIR/../lib/accounts.sh"
# shellcheck source=/dev/null
. "$SELF_DIR/../lib/ports.sh"

CLI="$SVPS_DIR/scriptvps"
[[ -x "$CLI" ]] || CLI="scriptvps"

sys_online_count() {
  local svc name n=0
  for svc in $SPVS_ALL_SERVICES; do
    [[ -f "$(db_file "$svc")" ]] || continue
    while IFS=$'\t' read -r name _ _ _ _ _ _; do
      [[ -z "$name" ]] && continue
      [[ -n "$(acct_online_ip "$svc" "$name")" ]] && n=$((n+1))
    done < <(db_list "$svc")
  done
  echo "$n"
}

panel_header() {
  ui_banner
  local ip osv up load mem total online
  ip="$(public_ip 2>/dev/null || echo '?')"
  osv="${SVPS_OS_PRETTY:-$(. /etc/os-release 2>/dev/null; echo "$PRETTY_NAME")}"
  up="$(uptime -p 2>/dev/null | sed 's/^up //')"
  load="$(awk '{print $1" "$2" "$3}' /proc/loadavg 2>/dev/null)"
  mem="$(free -m 2>/dev/null | awk '/Mem:/{print $3" / "$2" MB"}')"
  total="$(acct_total)"
  online="$(sys_online_count)"
  ui_kv "Host" "$(hostname)   ${C_DIM}OS:${C_RESET} ${osv:-?}" 8
  ui_kv "IP" "$ip" 8
  ui_kv "Uptime" "${up:-?}   ${C_DIM}Load:${C_RESET} ${load:-?}" 8
  ui_kv "Memori" "${mem:-?}" 8
  ui_kv "Akun" "${C_BOLD}${total}${C_RESET} total · ${C_GREEN}${online}${C_RESET} online" 8
  echo
}

press_enter() { read -r -p "$(printf '%s  ↵ Enter...%s' "$C_DIM" "$C_RESET")" _ || true; }

service_panel() {
  local svc="$1" label="$2" proto="${3:-}"
  while true; do
    panel_header
    ui_title ">> PANEL $label${proto:+ ($proto)}"
    echo
    printf '   %s[1]%s List akun      %s[2]%s User online   %s[3]%s Tambah akun\n' "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET"
    printf '   %s[4]%s Trial akun     %s[5]%s Perpanjang    %s[6]%s Hapus akun\n' "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET"
    printf '   %s[7]%s Lihat link/QR  %s[0]%s Kembali\n' "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET"
    echo
    read -r -p "   Pilih: " c || true
    case "$c" in
      1) clear; ui_title "Daftar akun $label"; "$CLI" list "$svc"; press_enter ;;
      2) clear; ui_title "User online $label"; "$CLI" online; press_enter ;;
      3)
        read -r -p "Nama akun: " name || true
        read -r -p "Hari [30]: " days || true; days="${days:-30}"
        read -r -p "Limit IP [0]: " ipl || true; ipl="${ipl:-0}"
        read -r -p "Kuota GB [0]: " q || true; q="${q:-0}"
        if [[ -n "$name" ]]; then
          if [[ -n "$proto" ]]; then "$CLI" add "$svc" "$name" --days "$days" --iplimit "$ipl" --quota "$q" --protocol "$proto"; else "$CLI" add "$svc" "$name" --days "$days" --iplimit "$ipl" --quota "$q"; fi
        fi
        press_enter ;;
      4)
        read -r -p "Nama trial: " name || true
        if [[ -n "$name" ]]; then
          if [[ -n "$proto" ]]; then "$CLI" add "$svc" "$name" --days 1 --iplimit 1 --protocol "$proto"; else "$CLI" add "$svc" "$name" --days 1 --iplimit 1; fi
        fi
        press_enter ;;
      5)
        read -r -p "Nama akun: " name || true
        read -r -p "Hari [30]: " days || true; days="${days:-30}"
        [[ -n "$name" ]] && "$CLI" renew "$svc" "$name" --days "$days"
        press_enter ;;
      6)
        read -r -p "Nama akun: " name || true
        [[ -n "$name" ]] && "$CLI" del "$svc" "$name"
        press_enter ;;
      7) "$CLI" list "$svc" | sed -n '1,40p'; press_enter ;;
      0) return ;;
      *) ;;
    esac
  done
}

port_menu() {
  while true; do
    panel_header
    ui_title ">> PENGATURAN PORT"
    "$CLI" port show
    echo
    printf '   %s[1]%s Ganti port SSH          %s[2]%s OpenVPN\n' "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET"
    printf '   %s[3]%s WireGuard               %s[4]%s Xray (vless-ws)\n' "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET"
    printf '   %s[5]%s Xray (vmess-ws)         %s[6]%s Xray (vless-grpc)\n' "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET"
    printf '   %s[7]%s Xray (vmess-grpc)       %s[8]%s Xray (trojan)\n' "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET"
    printf '   %s[9]%s SSTP                    %s[10]%s Shadowsocks (base)\n' "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET"
    printf '   %s[0]%s Kembali\n' "$C_CYAN" "$C_RESET"
    echo
    read -r -p "   Pilih: " c || true
    local val
    case "$c" in
      1) read -r -p "Port baru (SSH): " val; [[ -n "$val" ]] && "$CLI" port set ssh port "$val"; press_enter ;;
      2) read -r -p "Port baru (OpenVPN): " val; [[ -n "$val" ]] && "$CLI" port set ovpn port "$val"; press_enter ;;
      3) read -r -p "Port baru (WireGuard): " val; [[ -n "$val" ]] && "$CLI" port set wg port "$val"; press_enter ;;
      4) read -r -p "Port baru (vless-ws): " val; [[ -n "$val" ]] && "$CLI" port set xray vless-ws "$val"; press_enter ;;
      5) read -r -p "Port baru (vmess-ws): " val; [[ -n "$val" ]] && "$CLI" port set xray vmess-ws "$val"; press_enter ;;
      6) read -r -p "Port baru (vless-grpc): " val; [[ -n "$val" ]] && "$CLI" port set xray vless-grpc "$val"; press_enter ;;
      7) read -r -p "Port baru (vmess-grpc): " val; [[ -n "$val" ]] && "$CLI" port set xray vmess-grpc "$val"; press_enter ;;
      8) read -r -p "Port baru (trojan): " val; [[ -n "$val" ]] && "$CLI" port set xray trojan "$val"; press_enter ;;
      9) read -r -p "Port baru (SSTP): " val; [[ -n "$val" ]] && "$CLI" port set sstp port "$val"; press_enter ;;
      10) read -r -p "Base port (SS): " val; [[ -n "$val" ]] && "$CLI" port set ss base "$val"; press_enter ;;
      0) return ;;
      *) ;;
    esac
  done
}

sys_panel() {
  while true; do
    panel_header
    ui_title ">> SISTEM"
    echo
    printf '   %s[1]%s Info sistem     %s[2]%s RAM           %s[3]%s Speedtest\n' "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET"
    printf '   %s[4]%s Restart semua   %s[5]%s Limit BW      %s[6]%s Banner SSH\n' "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET"
    printf '   %s[7]%s Laporan kuota   %s[8]%s Bersihkan     %s[9]%s Restart layanan\n' "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET"
    printf '   %s[0]%s Kembali\n' "$C_CYAN" "$C_RESET"
    echo
    read -r -p "   Pilih: " c || true
    case "$c" in
      1) clear
         ui_title "INFO SISTEM"
         ui_kv "Host" "$(hostname)" 12
         ui_kv "OS" "$(. /etc/os-release 2>/dev/null; echo "$PRETTY_NAME")" 12
         ui_kv "Kernel" "$(uname -r)" 12
         ui_kv "IP" "$(public_ip 2>/dev/null)" 12
         ui_kv "Uptime" "$(uptime -p 2>/dev/null)" 12
         ui_kv "Load" "$(awk '{print $1" "$2" "$3}' /proc/loadavg)" 12
         ui_kv "Disk" "$(df -h / | awk 'NR==2{print $3"/"$2" ("$5")"}')" 12
         press_enter ;;
      2) clear; ui_title "PEMAKAIAN RAM"; free -h; press_enter ;;
      3) clear; ui_title "SPEEDTEST"
         if command -v speedtest >/dev/null 2>&1; then speedtest; elif command -v speedtest-cli >/dev/null 2>&1; then speedtest-cli; else ui_warn "speedtest tidak terpasang (apt install speedtest-cli)."; fi
         press_enter ;;
      4) for s in ssh ovpn wg xray ss sstp l2tp pptp; do systemctl restart "$s" 2>/dev/null || true; done; ui_ok "Perintah restart dijalankan."; press_enter ;;
      5) read -r -p "kbps (atau 'off'): " v; "$CLI" limit-speed "$v"; press_enter ;;
      6) read -r -p "Banner (kosong = off): " v; "$CLI" banner "$v"; press_enter ;;
      7) clear; "$CLI" quota report; press_enter ;;
      8) "$CLI" check; press_enter ;;
      9) clear
         local svc
         for svc in $SPVS_ALL_SERVICES; do
           [[ -f "$(db_file "$svc")" ]] || continue
           case "$svc" in
             ssh) systemctl restart ssh 2>/dev/null || true ;;
             ovpn) systemctl restart openvpn-server@server 2>/dev/null || true ;;
             wg) systemctl restart wg-quick@wg0 2>/dev/null || true ;;
             *) systemctl restart "$svc" 2>/dev/null || true ;;
           esac
           ui_ok "restart $svc"
         done
         press_enter ;;
      0) return ;;
      *) ;;
    esac
  done
}

while true; do
  panel_header
  printf '   %s╭─ %sMENU UTAMA%s\n' "$C_BLUE" "$C_BOLD$C_CYAN" "$C_RESET"
  printf '   %s│%s  %s[1]%s SSH & OpenVPN    %s[2]%s WireGuard      %s[3]%s Xray/Trojan\n' "$C_BLUE" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET"
  printf '   %s│%s  %s[4]%s Shadowsocks      %s[5]%s SSTP           %s[6]%s L2TP\n' "$C_BLUE" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET"
  printf '   %s│%s  %s[7]%s PPTP             %s[8]%s VMess          %s[9]%s VLESS\n' "$C_BLUE" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET"
  printf '   %s│%s  %s[10]%s Semua akun      %s[11]%s Online         %s[12]%s Ganti Port\n' "$C_BLUE" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET"
  printf '   %s│%s  %s[13]%s Sistem          %s[14]%s Lisensi        %s[0]%s Keluar\n' "$C_BLUE" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET"
  printf '   %s╰────────────────────────────────────────────────────────────%s\n' "$C_BLUE" "$C_RESET"
  echo
  read -r -p "   Pilih: " c || true
  case "$c" in
    1) service_panel ssh "SSH" ;;
    2) service_panel wg "WireGuard" ;;
    3)
      clear; ui_title ">> XRAY"
      printf '   %s[1]%s VLESS   %s[2]%s VMess   %s[3]%s Trojan   %s[0]%s Kembali\n' "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET"
      read -r -p "   Pilih: " x || true
      case "$x" in
        1) service_panel xray "Xray" "vless" ;;
        2) service_panel xray "Xray" "vmess" ;;
        3) service_panel xray "Xray" "trojan" ;;
        *) ;;
      esac ;;
    4) service_panel ss "Shadowsocks" ;;
    5) service_panel sstp "SSTP" ;;
    6) service_panel l2tp "L2TP" ;;
    7) service_panel pptp "PPTP" ;;
    8) service_panel xray "Xray" "vmess" ;;
    9) service_panel xray "Xray" "vless" ;;
    10) clear; ui_title "SEMUA AKUN"; "$CLI" users; press_enter ;;
    11) clear; ui_title "USER ONLINE"; "$CLI" online; press_enter ;;
    12) port_menu ;;
    13) sys_panel ;;
    14) clear; license_info; press_enter ;;
    0) clear; exit 0 ;;
    *) ;;
  esac
done
