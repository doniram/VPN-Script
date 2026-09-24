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

# ---------------------------------------------------------------------------
# NAT management (shared by PPP-based services: SSTP/L2TP/PPTP)
# ---------------------------------------------------------------------------
SVPS_NAT_SUBNETS="$SVPS_ETC/nat.subnets"
SVPS_NAT_SCRIPT="$SVPS_ETC/nat-apply.sh"
SVPS_NAT_UNIT="/etc/systemd/system/scriptvps-nat.service"

svps_nat_apply() {
  [[ -f "$SVPS_NAT_SUBNETS" ]] || return 0
  local s
  while read -r s; do
    [[ -z "$s" ]] && continue
    enable_nat "$s"
  done <"$SVPS_NAT_SUBNETS"
}

# enable_nat <subnet>
enable_nat() {
  local subnet="$1" iface
  iface="$(default_iface)"
  has_cmd iptables || return 0
  if ! iptables -w -t nat -C POSTROUTING -s "$subnet" -o "$iface" -j MASQUERADE 2>/dev/null; then
    if ! iptables -w -t nat -A POSTROUTING -s "$subnet" -o "$iface" -j MASQUERADE 2>/dev/null; then
      warn "Tidak bisa menerapkan NAT untuk ${subnet} (perlu root/kernel netfilter)."
      return 0
    fi
  fi
  iptables -w -C FORWARD -s "$subnet" -j ACCEPT 2>/dev/null || \
    iptables -w -A FORWARD -s "$subnet" -j ACCEPT 2>/dev/null || true
  iptables -w -C FORWARD -d "$subnet" -j ACCEPT 2>/dev/null || \
    iptables -w -A FORWARD -d "$subnet" -j ACCEPT 2>/dev/null || true
}

svps_nat_setup() {
  init_dirs
  cat >"$SVPS_NAT_SCRIPT" <<'EOF'
#!/usr/bin/env bash
subnets="/etc/scriptvps/nat.subnets"
[[ -f "$subnets" ]] || exit 0
iface="$(ip -4 route show default | awk '{print $5; exit}')"
while read -r s; do
  [[ -z "$s" ]] && continue
  iptables -w -t nat -C POSTROUTING -s "$s" -o "$iface" -j MASQUERADE 2>/dev/null || \
    iptables -w -t nat -A POSTROUTING -s "$s" -o "$iface" -j MASQUERADE 2>/dev/null || true
  iptables -w -C FORWARD -s "$s" -j ACCEPT 2>/dev/null || iptables -w -A FORWARD -s "$s" -j ACCEPT 2>/dev/null || true
  iptables -w -C FORWARD -d "$s" -j ACCEPT 2>/dev/null || iptables -w -A FORWARD -d "$s" -j ACCEPT 2>/dev/null || true
done <"$subnets"
EOF
  chmod 700 "$SVPS_NAT_SCRIPT"
  cat >"$SVPS_NAT_UNIT" <<'EOF'
[Unit]
Description=scriptvps NAT rules
After=network-online.target
Wants=network-online.target
Before=xl2tpd.service sstpd.service pptpd.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/etc/scriptvps/nat-apply.sh

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload 2>/dev/null || true
  systemctl enable scriptvps-nat.service >/dev/null 2>&1 || true
}

svps_nat_add_subnet() {
  init_dirs
  grep -qxF "$1" "$SVPS_NAT_SUBNETS" 2>/dev/null || printf '%s\n' "$1" >>"$SVPS_NAT_SUBNETS"
  svps_nat_setup
  svps_nat_apply
}

svps_nat_remove_subnet() {
  [[ -f "$SVPS_NAT_SUBNETS" ]] || return 0
  local tmp; tmp="$(mktemp)"
  grep -vxF "$1" "$SVPS_NAT_SUBNETS" >"$tmp" || true
  mv "$tmp" "$SVPS_NAT_SUBNETS"
}
