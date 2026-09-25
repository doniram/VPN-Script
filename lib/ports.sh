#!/usr/bin/env bash
# lib/ports.sh - view & change service ports

[[ -n "${__SVPS_PORTS_LOADED:-}" ]] && return 0
__SVPS_PORTS_LOADED=1

# shellcheck source=/dev/null
. "$SVPS_DIR/lib/ui.sh"

# port_get <service> <key> -> current value
port_get() {
  local svc="$1" key="${2:-}"
  case "$svc" in
    ssh)   config_get ssh_port "22" ;;
    ovpn)  if [[ "$key" == "proto" ]]; then config_get ovpn_proto "udp"; else config_get ovpn_port "1194"; fi ;;
    wg)    config_get wg_port "51820" ;;
    ss)    config_get ss_base_port "8388" ;;
    sstp)  config_get sstp_port "444" ;;
    l2tp)  echo "1701" ;;
    pptp)  echo "1723" ;;
    xray)
      case "$key" in
        vless-ws)   config_get xray_port_vless_ws "443" ;;
        vmess-ws)   config_get xray_port_vmess_ws "8443" ;;
        vless-grpc) config_get xray_port_vless_grpc "2053" ;;
        vmess-grpc) config_get xray_port_vmess_grpc "2054" ;;
        trojan)     config_get xray_port_trojan "2087" ;;
        *) : ;;
      esac ;;
  esac
}

port_show() {
  local hdr rows=() svc
  hdr=$'LAYANAN\tKEY\tPORT'
  local -a kvs=(
    "ssh|port"
    "ovpn|port" "ovpn|proto"
    "wg|port"
    "xray|vless-ws" "xray|vmess-ws" "xray|vless-grpc" "xray|vmess-grpc" "xray|trojan"
    "ss|base"
    "sstp|port"
    "l2tp|port"
    "pptp|port"
  )
  local item s k v
  for item in "${kvs[@]}"; do
    s="${item%%|*}"; k="${item##*|}"
    v="$(port_get "$s" "$k")"
    rows+=("$(printf '%s\t%s\t%s' "$s" "$k" "$v")")
  done
  ui_table "$hdr" "${rows[@]}"
}

port_show_json() {
  local -a kvs=(
    "ssh|port" "ovpn|port" "ovpn|proto" "wg|port"
    "xray|vless-ws" "xray|vmess-ws" "xray|vless-grpc" "xray|vmess-grpc" "xray|trojan"
    "ss|base" "sstp|port" "l2tp|port" "pptp|port"
  )
  local first=1 item s k v
  printf '['
  for item in "${kvs[@]}"; do
    s="${item%%|*}"; k="${item##*|}"
    v="$(port_get "$s" "$k")"
    (( first )) || printf ','; first=0
    printf '{"service":"%s","key":"%s","value":"%s"}' "$(json_escape "$s")" "$(json_escape "$k")" "$(json_escape "$v")"
  done
  printf ']\n'
}

# port_set <service> <key> <value>
port_set() {
  local svc="$1" key="$2" val="$3"
  if ! [[ "$val" =~ ^[0-9]+$ ]] || (( val < 1 || val > 65535 )); then ui_err "Port tidak valid: $val"; return 1; fi

  case "$svc" in
    ssh)
      config_set ssh_port "$val"
      local dropin="/etc/ssh/sshd_config.d/99-scriptvps.conf"
      mkdir -p /etc/ssh/sshd_config.d
      [[ -f "$dropin" ]] || printf '# managed by scriptvps\n' >"$dropin"
      if grep -q '^Port ' "$dropin"; then sed -i "s/^Port .*/Port ${val}/" "$dropin"; else printf 'Port %s\n' "$val" >>"$dropin"; fi
      systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
      ui_ok "Port SSH diubah ke ${val}." ;;
    ovpn)
      if [[ "$key" == "proto" ]]; then
        [[ "$val" == "tcp" || "$val" == "udp" ]] || { ui_err "proto harus tcp/udp"; return 1; }
        config_set ovpn_proto "$val"
      else
        config_set ovpn_port "$val"
      fi
      local conf="/etc/openvpn/server/server.conf"
      if [[ -f "$conf" ]]; then
        sed -i "s/^port .*/port $(port_get ovpn port)/" "$conf"
        sed -i "s/^proto .*/proto $(port_get ovpn proto)/" "$conf"
      fi
      systemctl restart openvpn-server@server 2>/dev/null || true
      ui_ok "OpenVPN: port=$(port_get ovpn port) proto=$(port_get ovpn proto)." ;;
    wg)
      config_set wg_port "$val"
      local conf="/etc/wireguard/${WG_IFACE:-wg0}.conf"
      if [[ -f "$conf" ]]; then sed -i "s/^ListenPort = .*/ListenPort = ${val}/" "$conf"; fi
      systemctl restart wg-quick@"${WG_IFACE:-wg0}" 2>/dev/null || true
      ui_ok "Port WireGuard diubah ke ${val}." ;;
    ss)
      config_set ss_base_port "$val"
      ui_ok "Base port Shadowsocks diubah ke ${val} (berlaku untuk akun baru)." ;;
    sstp)
      config_set sstp_port "$val"
      local unit="/etc/systemd/system/sstpd.service"
      if [[ -f "$unit" ]]; then
        sed -i "s/-p [0-9]\+/-p ${val}/" "$unit"
        systemctl daemon-reload 2>/dev/null || true
      fi
      systemctl restart sstpd 2>/dev/null || true
      ui_ok "Port SSTP diubah ke ${val}." ;;
    xray)
      local tag="" ckey=""
      case "$key" in
        vless-ws)   tag="vless-ws";   ckey="xray_port_vless_ws" ;;
        vmess-ws)   tag="vmess-ws";   ckey="xray_port_vmess_ws" ;;
        vless-grpc) tag="vless-grpc"; ckey="xray_port_vless_grpc" ;;
        vmess-grpc) tag="vmess-grpc"; ckey="xray_port_vmess_grpc" ;;
        trojan)     tag="trojan-tcp"; ckey="xray_port_trojan" ;;
        *) ui_err "Key Xray tidak dikenal: $key"; return 1 ;;
      esac
      config_set "$ckey" "$val"
      local cfg="/usr/local/etc/xray/config.json"
      if [[ -f "$cfg" ]] && command -v jq >/dev/null 2>&1; then
        local tmp; tmp="$(mktemp)"
        jq --arg tag "$tag" --argjson port "$val" '(.inbounds[] | select(.tag==$tag).port) = $port' "$cfg" >"$tmp" && mv "$tmp" "$cfg"
      fi
      systemctl restart xray 2>/dev/null || true
      ui_ok "Port Xray ${tag} diubah ke ${val}." ;;
    l2tp|pptp)
      ui_warn "Port ${svc} bersifat tetap (${svc}: $(port_get "$svc" port))." ;;
    *)
      ui_err "Layanan tidak dikenal: $svc"; return 1 ;;
  esac
}
