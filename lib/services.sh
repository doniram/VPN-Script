#!/usr/bin/env bash
# lib/services.sh - service registry & dispatcher
#
# Maps a short service name to its module file and function prefix.
# Modules implement: <prefix>_install  <prefix>_uninstall
#                    <prefix>_add <name> ...   <prefix>_del <name>
#                    <prefix>_renew <name> <days>
#                    <prefix>_list  <prefix>_status

[[ -n "${__SVPS_SERVICES_LOADED:-}" ]] && return 0
__SVPS_SERVICES_LOADED=1

SPVS_ALL_SERVICES="ssh ovpn wg xray ss sstp l2tp pptp"

svps_service_module() {
  case "$1" in
    ssh)  echo ssh ;;
    ovpn) echo openvpn ;;
    wg)   echo wireguard ;;
    xray) echo xray ;;
    ss)   echo shadowsocks ;;
    sstp) echo sstp ;;
    l2tp) echo l2tp ;;
    pptp) echo pptp ;;
    *)    return 1 ;;
  esac
}

svps_service_prefix() {
  case "$1" in
    ssh)  echo ssh ;;
    ovpn) echo ovpn ;;
    wg)   echo wg ;;
    xray) echo xray ;;
    ss)   echo ss ;;
    sstp) echo sstp ;;
    l2tp) echo l2tp ;;
    pptp) echo pptp ;;
    *)    return 1 ;;
  esac
}

svps_service_label() {
  case "$1" in
    ssh)  echo "SSH" ;;
    ovpn) echo "OpenVPN" ;;
    wg)   echo "WireGuard" ;;
    xray) echo "Xray (VLESS/VMess/Trojan)" ;;
    ss)   echo "Shadowsocks" ;;
    sstp) echo "SSTP" ;;
    l2tp) echo "L2TP/IPsec" ;;
    pptp) echo "PPTP" ;;
    *)    echo "$1" ;;
  esac
}

svps_module_path() { echo "$SVPS_DIR/modules/$1.sh"; }

# svps_service_available <service> -> true if the module file exists
svps_service_available() {
  local m
  m="$(svps_service_module "$1" 2>/dev/null)" || return 1
  [[ -f "$(svps_module_path "$m")" ]]
}

# svps_load_service <service> -> sources the module
svps_load_service() {
  local svc="$1" mod
  mod="$(svps_service_module "$svc")" || die "Layanan tidak dikenal: $svc"
  local f; f="$(svps_module_path "$mod")"
  [[ -f "$f" ]] || die "Modul '$svc' belum tersedia di versi ini ($mod.sh)."
  # shellcheck disable=SC1090
  . "$f"
}

# svps_installed_services -> service names whose DB file exists and has entries
svps_installed_services() {
  local svc f
  for svc in $SPVS_ALL_SERVICES; do
    f="$(db_file "$svc")"
    [[ -f "$f" ]] && printf '%s ' "$svc"
  done
}
