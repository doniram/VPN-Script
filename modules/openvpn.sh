#!/usr/bin/env bash
# modules/openvpn.sh - OpenVPN server with its OWN CA (per server) + clients

[[ -n "${__SVPS_MOD_OVPN_LOADED:-}" ]] && return 0
__SVPS_MOD_OVPN_LOADED=1

OVPN_DIR="/etc/openvpn"
OVPN_SERVER_DIR="$OVPN_DIR/server"
OVPN_PKI="$OVPN_DIR/easy-rsa"
OVPN_INSTANCE="server"
OVPN_PORT="${OVPN_PORT:-1194}"
OVPN_PROTO="${OVPN_PROTO:-udp}"

ovpn_port()  { config_get ovpn_port "${OVPN_PORT:-1194}"; }
ovpn_proto() { config_get ovpn_proto "${OVPN_PROTO:-udp}"; }
OVPN_SUBNET="${OVPN_SUBNET:-10.8.0.0}"
OVPN_MASK="${OVPN_MASK:-255.255.255.0}"
EASYRSA_BIN="/usr/share/easy-rsa/easyrsa"
SVPS_OVPN_UP="$SVPS_ETC/ovpn-up.sh"
SVPS_OVPN_DOWN="$SVPS_ETC/ovpn-down.sh"

_ovpn_easyrsa() {
  ( cd "$OVPN_PKI" && EASYRSA_BATCH=1 EASYRSA_PKI="$OVPN_PKI/pki" \
      EASYRSA_REQ_CN="${EASYRSA_REQ_CN:-scriptvps}" "$EASYRSA_BIN" "$@" )
}

_ovpn_write_hooks() {
  cat >"$SVPS_OVPN_UP" <<'EOF'
#!/usr/bin/env bash
# add NAT for the OpenVPN tunnel interface
IFACE="$(ip -4 route show default | awk '{print $5; exit}')"
iptables -t nat -C POSTROUTING -s 10.8.0.0/24 -o "$IFACE" -j MASQUERADE 2>/dev/null || \
  iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o "$IFACE" -j MASQUERADE
iptables -C FORWARD -i "$dev" -j ACCEPT 2>/dev/null || iptables -A FORWARD -i "$dev" -j ACCEPT
EOF
  cat >"$SVPS_OVPN_DOWN" <<'EOF'
#!/usr/bin/env bash
IFACE="$(ip -4 route show default | awk '{print $5; exit}')"
iptables -t nat -D POSTROUTING -s 10.8.0.0/24 -o "$IFACE" -j MASQUERADE 2>/dev/null || true
iptables -D FORWARD -i "$dev" -j ACCEPT 2>/dev/null || true
EOF
  chmod 700 "$SVPS_OVPN_UP" "$SVPS_OVPN_DOWN"
}

_ovpn_server_conf() {
  cat >"$OVPN_SERVER_DIR/${OVPN_INSTANCE}.conf" <<EOF
# managed by scriptvps
port $(ovpn_port)
proto $(ovpn_proto)
dev tun
ca ${OVPN_PKI}/pki/ca.crt
cert ${OVPN_PKI}/pki/issued/server.crt
key ${OVPN_PKI}/pki/private/server.key
dh ${OVPN_PKI}/pki/dh.pem
tls-auth ${OVPN_PKI}/pki/ta.key 0
crl-verify ${OVPN_PKI}/pki/crl.pem
server ${OVPN_SUBNET} ${OVPN_MASK}
ifconfig-pool-persist ipp.txt
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 1.1.1.1"
push "dhcp-option DNS 8.8.8.8"
keepalive 10 120
cipher AES-256-GCM
auth SHA256
user nobody
group nogroup
persist-key
persist-tun
status openvpn-status.log
verb 3
script-security 2
up "${SVPS_OVPN_UP}"
down "${SVPS_OVPN_DOWN}"
EOF
  chmod 600 "$OVPN_SERVER_DIR/${OVPN_INSTANCE}.conf"
}

ovpn_install() {
  require_root
  info "Memasang modul OpenVPN"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq openvpn easy-rsa openssl >/dev/null

  mkdir -p "$OVPN_SERVER_DIR"
  if [[ ! -x "$EASYRSA_BIN" ]]; then
    die "easy-rsa tidak ditemukan di $EASYRSA_BIN"
  fi

  if [[ ! -f "$OVPN_PKI/pki/ca.crt" ]]; then
    info "Membuat CA & PKI (sekali saja)"
    mkdir -p "$OVPN_PKI"
    _ovpn_easyrsa init-pki >/dev/null 2>&1 || true
    _ovpn_easyrsa build-ca nopass >/dev/null 2>&1 || die "Gagal build-ca"
    _ovpn_easyrsa gen-req server nopass >/dev/null 2>&1 || die "Gagal gen-req server"
    _ovpn_easyrsa sign-req server server >/dev/null 2>&1 || die "Gagal sign server"
    _ovpn_easyrsa gen-dh >/dev/null 2>&1 || die "Gagal gen-dh"
    _ovpn_easyrsa gen-crl >/dev/null 2>&1 || true
    if ! openvpn --genkey secret "$OVPN_PKI/pki/ta.key" 2>/dev/null; then
      openvpn --genkey --secret "$OVPN_PKI/pki/ta.key" 2>/dev/null || die "Gagal buat ta.key"
    fi
    chmod 600 "$OVPN_PKI/pki/ta.key"
  fi

  _ovpn_write_hooks
  _ovpn_server_conf
  enable_ip_forward

  systemctl enable openvpn-server@"$OVPN_INSTANCE" >/dev/null 2>&1 || true
  systemctl restart openvpn-server@"$OVPN_INSTANCE" 2>/dev/null || warn "Tidak bisa start OpenVPN (mungkin tidak ada systemd)."
  db_init ovpn
  ok "Modul OpenVPN siap ($(ovpn_proto)/$(ovpn_port))."
}

ovpn_uninstall() {
  systemctl stop openvpn-server@"$OVPN_INSTANCE" 2>/dev/null || true
  systemctl disable openvpn-server@"$OVPN_INSTANCE" 2>/dev/null || true
  rm -f "$OVPN_SERVER_DIR/${OVPN_INSTANCE}.conf"
  rm -f "$SVPS_OVPN_UP" "$SVPS_OVPN_DOWN"
  rm -rf "$OVPN_PKI"
  rm -f "$(db_file ovpn)"
  ok "Modul OpenVPN dihapus."
}

# ovpn_add <name> <days> <iplimit> <quota> <meta>
ovpn_add() {
  require_root
  local name="$1" days="$2" iplimit="${3:-0}" quota="${4:-0}" meta="${5:-}"
  [[ "$name" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] || die "Nama tidak valid."
  db_exists ovpn "$name" && die "Client OpenVPN '$name' sudah ada."
  [[ -f "$OVPN_PKI/pki/ca.crt" ]] || die "OpenVPN belum diinstall."

  local expires
  expires="$(date_add_days "$days")"

  _ovpn_easyrsa gen-req "$name" nopass >/dev/null 2>&1 || die "Gagal gen-req client"
  _ovpn_easyrsa sign-req client "$name" >/dev/null 2>&1 || die "Gagal sign client"
  [[ -f "$OVPN_PKI/pki/crl.pem" ]] || _ovpn_easyrsa gen-crl >/dev/null 2>&1 || true

  local out="$SVPS_CLIENTS/${name}.ovpn"
  _ovpn_build_inline "$name" "$out"
  db_add ovpn "$name" "$expires" "$iplimit" "$quota" "default" "$meta" || true

  ok "Client OpenVPN dibuat: $name"
  plain "  Config    : $out"
  plain "  Server    : $(public_ip):$(ovpn_port)/$(ovpn_proto)"
  plain "  Expires   : $expires"
}

_ovpn_build_inline() {
  local name="$1" out="$2"
  {
    printf 'client\n'
    printf 'dev tun\n'
    printf 'proto %s\n' "$(ovpn_proto)"
    printf 'remote %s %s\n' "$(public_ip)" "$(ovpn_port)"
    printf 'resolv-retry infinite\nnobind\npersist-key\npersist-tun\n'
    printf 'remote-cert-tls server\ncipher AES-256-GCM\nauth SHA256\nkey-direction 1\nverb 3\n'
    printf '<ca>\n';     cat "$OVPN_PKI/pki/ca.crt"
    printf '</ca>\n<cert>\n'; cat "$OVPN_PKI/pki/issued/${name}.crt"
    printf '</cert>\n<key>\n'; cat "$OVPN_PKI/pki/private/${name}.key"
    printf '</key>\n<tls-auth>\n'; cat "$OVPN_PKI/pki/ta.key"
    printf '</tls-auth>\n'
  } >"$out"
  chmod 600 "$out"
}

ovpn_del() {
  require_root
  local name="$1"
  if [[ -f "$OVPN_PKI/pki/issued/${name}.crt" ]]; then
    _ovpn_easyrsa revoke "$name" >/dev/null 2>&1 || warn "Revoke gagal (mungkin sudah dicabut)."
    _ovpn_easyrsa gen-crl >/dev/null 2>&1 || true
  fi
  rm -f "$OVPN_PKI/pki/issued/${name}.crt" \
        "$OVPN_PKI/pki/private/${name}.key" \
        "$OVPN_PKI/pki/reqs/${name}.req" \
        "$SVPS_CLIENTS/${name}.ovpn"
  db_del ovpn "$name" || true
  ok "Client OpenVPN '$name' dihapus."
}

ovpn_renew() {
  local name="$1" days="$2" expires
  db_exists ovpn "$name" || die "Client '$name' tidak ada."
  expires="$(date_add_days "$days")"
  db_update_expiry ovpn "$name" "$expires"
  ok "Client '$name' diperpanjang sampai $expires (sertifikat tetap valid)."
}

ovpn_list() {
  local today; today="$(date +%s)"
  printf '%-18s %-12s %-12s %s\n' NAME CREATED EXPIRES STATUS
  while IFS=$'\t' read -r name created expires _ _ _ _; do
    local status="active" t=0
    [[ -n "$expires" ]] && t="$(date -d "$expires" +%s 2>/dev/null || echo 0)"
    (( t < today )) && status="expired"
    printf '%-18s %-12s %-12s %s\n' "$name" "$created" "$expires" "$status"
  done < <(db_list ovpn)
}

ovpn_status() {
  local n; n="$(db_count ovpn)"
  if systemctl is-active --quiet openvpn-server@"$OVPN_INSTANCE" 2>/dev/null; then
    echo "ovpn: active (${n} client)"
  else
    echo "ovpn: inactive (${n} client)"
  fi
}

ovpn_expire_cleanup() {
  local name
  while read -r name; do
    [[ -z "$name" ]] && continue
    warn "OpenVPN '$name' kedaluwarsa - mencabut sertifikat."
    ovpn_del "$name" >/dev/null 2>&1 || true
  done < <(db_expired ovpn)
}
