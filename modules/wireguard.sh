#!/usr/bin/env bash
# modules/wireguard.sh - WireGuard peers with expiry

[[ -n "${__SVPS_MOD_WG_LOADED:-}" ]] && return 0
__SVPS_MOD_WG_LOADED=1

WG_IFACE="${WG_IFACE:-wg0}"
WG_DIR="/etc/wireguard"
WG_CONF="$WG_DIR/${WG_IFACE}.conf"
WG_SUBNET="${WG_SUBNET:-10.66.66.0/24}"
WG_SERVER_IP="${WG_SERVER_IP:-10.66.66.1}"
WG_PORT="${WG_PORT:-51820}"
WG_DNS="${WG_DNS:-1.1.1.1}"

wg_install() {
  require_root
  info "Memasang modul WireGuard"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq wireguard wireguard-tools qrencode >/dev/null
  enable_ip_forward
  mkdir -p "$WG_DIR"; chmod 700 "$WG_DIR"

  if [[ ! -f "$WG_CONF" ]]; then
    local priv pub iface
    priv="$(wg genkey)"
    pub="$(printf '%s' "$priv" | wg pubkey)"
    iface="$(default_iface)"
    cat >"$WG_CONF" <<EOF
# managed by scriptvps
[Interface]
Address = ${WG_SERVER_IP}/24
ListenPort = ${WG_PORT}
PrivateKey = ${priv}
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o ${iface} -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o ${iface} -j MASQUERADE
EOF
    chmod 600 "$WG_CONF"
    config_set wg_server_public_key "$pub"
    config_set wg_port "$WG_PORT"
  fi
  systemctl enable wg-quick@"$WG_IFACE" >/dev/null 2>&1 || true
  systemctl restart wg-quick@"$WG_IFACE" 2>/dev/null || warn "Tidak bisa start wg-quick (mungkin tidak ada systemd)."
  db_init wg
  ok "Modul WireGuard siap (port ${WG_PORT})."
}

wg_uninstall() {
  systemctl stop wg-quick@"$WG_IFACE" 2>/dev/null || true
  systemctl disable wg-quick@"$WG_IFACE" 2>/dev/null || true
  rm -f "$WG_CONF"
  rm -f "$(db_file wg)"
  ok "Modul WireGuard dihapus."
}

_wg_next_ip() {
  local used ip n
  used="$(db_list wg | awk -F'\t' '{print $7}' | grep -oE '[0-9]+$' | sort -n | tr '\n' ' ')"
  for n in $(seq 2 254); do
    ip="${WG_SERVER_IP%.*}.${n}"
    [[ " $used " == *" $n "* ]] && continue
    printf '%s' "$ip"; return 0
  done
  return 1
}

_wg_server_pub() {
  if [[ -f "$WG_CONF" ]]; then
    awk -F'= ' '/PrivateKey/{print $2}' "$WG_CONF" | head -n1 | wg pubkey
  fi
}

# wg_add <name> <days> <iplimit> <quota> <meta>
wg_add() {
  require_root
  local name="$1" days="$2" iplimit="${3:-0}" quota="${4:-0}" meta="${5:-}"
  [[ "$name" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] || die "Nama tidak valid."
  db_exists wg "$name" && die "Peer '$name' sudah ada."
  [[ -f "$WG_CONF" ]] || die "WireGuard belum diinstall."

  local ip expires priv pub psk pubkey
  ip="$(_wg_next_ip)" || die "IP pool penuh."
  expires="$(date_add_days "$days")"
  priv="$(wg genkey)"
  pub="$(printf '%s' "$priv" | wg pubkey)"
  psk="$(wg genpsk)"
  pubkey="$(_wg_server_pub)"

  cat >>"$WG_CONF" <<EOF

[Peer]
# name: ${name}
PublicKey = ${pub}
PresharedKey = ${psk}
AllowedIPs = ${ip}/32
EOF
  wg syncconf "$WG_IFACE" <(wg-quick strip "$WG_IFACE") 2>/dev/null || systemctl restart wg-quick@"$WG_IFACE" 2>/dev/null || true
  db_add wg "$name" "$expires" "$iplimit" "$quota" "default" "$ip" || true

  local srv_ip endpoint out
  srv_ip="$(public_ip)"
  endpoint="${srv_ip}:${WG_PORT}"
  out="$SVPS_CLIENTS/${name}-wg.conf"
  cat >"$out" <<EOF
[Interface]
PrivateKey = ${priv}
Address = ${ip}/32
DNS = ${WG_DNS}

[Peer]
PublicKey = ${pubkey}
PresharedKey = ${psk}
Endpoint = ${endpoint}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
  chmod 600 "$out"

  ok "Peer WireGuard dibuat: $name (IP $ip)"
  plain "  Config    : $out"
  plain "  Expires   : $expires"
  if has_cmd qrencode; then
    plain "  QR (scan):"
    qrencode -t ANSIUTF8 <"$out"
  fi
}

wg_del() {
  require_root
  local name="$1"
  [[ -f "$WG_CONF" ]] || die "WireGuard belum diinstall."
  db_exists wg "$name" || warn "Peer '$name' tidak ada di database."

  local tmp; tmp="$(mktemp)"
  awk -v n="$name" '
    function flush() { if (buf != "" && !del) printf "%s", buf; buf=""; del=0 }
    /^\[Peer\]/ { flush(); buf=$0 "\n"; next }
    /^# name: / { if ($0 == "# name: " n) del=1 }
    { buf = buf $0 "\n" }
    END { flush() }
  ' "$WG_CONF" >"$tmp"
  mv "$tmp" "$WG_CONF"
  wg syncconf "$WG_IFACE" <(wg-quick strip "$WG_IFACE") 2>/dev/null || true
  db_del wg "$name" || true
  rm -f "$SVPS_CLIENTS/${name}-wg.conf"
  ok "Peer WireGuard '$name' dihapus."
}

wg_renew() {
  local name="$1" days="$2" expires
  db_exists wg "$name" || die "Peer '$name' tidak ada."
  expires="$(date_add_days "$days")"
  db_update_expiry wg "$name" "$expires"
  ok "Peer WireGuard '$name' diperpanjang sampai $expires."
}

wg_list() {
  local today; today="$(date +%s)"
  printf '%-18s %-16s %-12s %-8s %s\n' NAME ADDRESS EXPIRES IPLIMIT STATUS
  while IFS=$'\t' read -r name _ expires iplimit _ _ meta; do
    local status="active" t=0
    [[ -n "$expires" ]] && t="$(date -d "$expires" +%s 2>/dev/null || echo 0)"
    (( t < today )) && status="expired"
    printf '%-18s %-16s %-12s %-8s %s\n' "$name" "$meta" "$expires" "${iplimit:-0}" "$status"
  done < <(db_list wg)
}

wg_status() {
  local n; n="$(db_count wg)"
  if wg show "$WG_IFACE" >/dev/null 2>&1; then
    echo "wg: active (${n} peer)"
  else
    echo "wg: inactive (${n} peer)"
  fi
}

wg_expire_cleanup() {
  local name
  while read -r name; do
    [[ -z "$name" ]] && continue
    warn "WireGuard '$name' kedaluwarsa - dihapus."
    wg_del "$name" >/dev/null 2>&1 || true
  done < <(db_expired wg)
}
