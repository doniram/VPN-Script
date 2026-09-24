#!/usr/bin/env bash
# lib/net.sh - network detection helpers

[[ -n "${__SVPS_NET_LOADED:-}" ]] && return 0
__SVPS_NET_LOADED=1

# public_ip -> prints the server's public IPv4 (or empty on failure)
public_ip() {
  local ip url
  for url in "https://ipinfo.io/ip" "https://ifconfig.me" "https://api.ipify.org"; do
    ip="$(curl -fsSL --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]')" || true
    if [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
      printf '%s' "$ip"; return 0
    fi
  done
  return 1
}

# default_iface -> outbound interface name
default_iface() {
  ip -4 route show default 2>/dev/null | awk '{print $5; exit}'
}

# server_arch -> amd64 | arm64 | armv7 | ...
server_arch() {
  case "$(uname -m)" in
    x86_64|amd64)   echo amd64 ;;
    aarch64|arm64)  echo arm64 ;;
    armv7l)         echo armv7 ;;
    *)              uname -m ;;
  esac
}

# port_in_use <port> [proto=tcp]
port_in_use() {
  local port="$1" proto="${2:-tcp}"
  if [[ "$proto" == "udp" ]]; then
    ss -lun 2>/dev/null | awk 'NR>1{print $5}' | grep -qE "[:.]${port}$"
  else
    ss -ltn 2>/dev/null | awk 'NR>1{print $4}' | grep -qE "[:.]${port}$"
  fi
}

# port_free <port> [proto]
port_free() { ! port_in_use "$1" "${2:-tcp}"; }

# machine_id -> stable server identifier
machine_id() {
  if [[ -r /etc/machine-id ]]; then
    tr -d '[:space:]' </etc/machine-id
  elif [[ -r /var/lib/dbus/machine-id ]]; then
    tr -d '[:space:]' </var/lib/dbus/machine-id
  else
    hostname
  fi
}

# enable_ip_forward - persist IPv4 forwarding
enable_ip_forward() {
  printf 'net.ipv4.ip_forward=1\n' >/etc/sysctl.d/99-scriptvps.conf
  sysctl --system >/dev/null 2>&1 || true
}
