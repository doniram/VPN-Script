#!/usr/bin/env bash
# modules/l2tp.sh - L2TP/IPsec (xl2tpd + strongswan), users via chap-secrets

[[ -n "${__SVPS_MOD_L2TP_LOADED:-}" ]] && return 0
__SVPS_MOD_L2TP_LOADED=1

# shellcheck source=/dev/null
. "$SVPS_DIR/lib/ppp.sh"

L2TP_RANGE="192.168.42.10-192.168.42.250"
L2TP_LOCAL="192.168.42.1"
L2TP_SUBNET="192.168.42.0/24"

l2tp_psk() { config_get l2tp_psk ""; }

_l2tp_write_unit() {
  cat >/etc/systemd/system/xl2tpd.service <<'EOF'
[Unit]
Description=Level 2 Tunnel Protocol Daemon (xl2tpd)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/sbin/xl2tpd -D
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload 2>/dev/null || true
}

l2tp_install() {
  require_root
  info "Memasang modul L2TP/IPsec"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq xl2tpd strongswan ppp iptables >/dev/null

  local psk; psk="$(l2tp_psk)"
  if [[ -z "$psk" ]]; then
    psk="$(openssl rand -hex 16)"
    config_set l2tp_psk "$psk"
  fi

  cat >/etc/xl2tpd/xl2tpd.conf <<EOF
[global]
port = 1701
access control = no
ipsec saref = yes

[lns default]
ip range = ${L2TP_RANGE}
local ip = ${L2TP_LOCAL}
require chap = yes
refuse pap = yes
require authentication = yes
name = l2tpd
ppp debug = no
pppoptfile = /etc/ppp/options.xl2tpd
length bit = yes
EOF

  cat >/etc/ppp/options.xl2tpd <<EOF
require-mschap-v2
ms-dns 1.1.1.1
ms-dns 8.8.8.8
asyncmap 0
auth
crtscts
lock
hide-password
modem
name l2tpd
proxyarp
lcp-echo-interval 30
lcp-echo-failure 4
EOF

  local pub; pub="$(public_ip || echo '%defaultroute')"
  cat >/etc/ipsec.conf <<EOF
config setup
  uniqueids=no
  charondebug="ike 1, knl 1, cfg 0"

conn L2TP-PSK
  authby=secret
  pfs=no
  auto=add
  keyingtries=3
  rekey=no
  ikelifetime=8h
  keylife=1h
  type=transport
  left=%defaultroute
  leftid=${pub}
  leftprotoport=17/1701
  right=%any
  rightprotoport=17/%any
EOF

  cat >/etc/ipsec.secrets <<EOF
: PSK "${psk}"
EOF
  chmod 600 /etc/ipsec.secrets

  _l2tp_write_unit
  enable_ip_forward
  svps_nat_add_subnet "$L2TP_SUBNET"

  systemctl enable strongswan-starter >/dev/null 2>&1 || true
  systemctl restart strongswan-starter 2>/dev/null || warn "Tidak bisa start strongswan."
  systemctl enable xl2tpd >/dev/null 2>&1 || true
  systemctl restart xl2tpd 2>/dev/null || warn "Tidak bisa start xl2tpd (mungkin tanpa kernel L2TP)."
  db_init l2tp
  ok "Modul L2TP/IPsec siap (PSK: ${psk})."
}

l2tp_uninstall() {
  systemctl stop xl2tpd 2>/dev/null || true
  systemctl disable xl2tpd 2>/dev/null || true
  systemctl stop strongswan-starter 2>/dev/null || true
  rm -f /etc/ipsec.conf /etc/ipsec.secrets
  rm -f "$(db_file l2tp)"
  svps_nat_remove_subnet "$L2TP_SUBNET"
  ok "Modul L2TP/IPsec dihapus."
}

# l2tp_add <name> <days> <iplimit> <quota> <meta>
l2tp_add() {
  require_root
  local name="$1" days="$2" iplimit="${3:-0}" quota="${4:-0}" meta="${5:-}"
  [[ "$name" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] || die "Nama tidak valid."
  db_exists l2tp "$name" && die "Akun L2TP '$name' sudah ada."

  local pass expires
  pass="$(openssl rand -base64 12 | tr -d '/+=' | cut -c1-12)"
  expires="$(date_add_days "$days")"
  ppp_user_add "$name" "$pass"
  db_add l2tp "$name" "$expires" "$iplimit" "$quota" "default" "$meta" || true

  ok "Akun L2TP dibuat: $name"
  plain "  Server    : $(public_ip) (L2TP/IPsec)"
  plain "  PSK       : $(l2tp_psk)"
  plain "  Username  : $name"
  plain "  Password  : $pass"
  plain "  Expires   : $expires"
}

l2tp_del() {
  require_root
  local name="$1"
  ppp_user_del "$name" || true
  db_del l2tp "$name" || true
  ok "Akun L2TP '$name' dihapus."
}

l2tp_renew() {
  local name="$1" days="$2" expires
  db_exists l2tp "$name" || die "Akun '$name' tidak ada."
  expires="$(date_add_days "$days")"
  db_update_expiry l2tp "$name" "$expires"
  ok "Akun '$name' diperpanjang sampai $expires."
}

l2tp_list() {
  local today; today="$(date +%s)"
  printf '%-18s %-12s %s\n' NAME EXPIRES STATUS
  while IFS=$'\t' read -r name _ expires _ _ _ _; do
    local status="active" t=0
    [[ -n "$expires" ]] && t="$(date -d "$expires" +%s 2>/dev/null || echo 0)"
    (( t < today )) && status="expired"
    printf '%-18s %-12s %s\n' "$name" "$expires" "$status"
  done < <(db_list l2tp)
}

l2tp_status() {
  local n; n="$(db_count l2tp)"
  if systemctl is-active --quiet xl2tpd 2>/dev/null; then
    echo "l2tp: active (${n} akun)"
  else
    echo "l2tp: inactive (${n} akun)"
  fi
}

l2tp_expire_cleanup() {
  local name
  while read -r name; do
    [[ -z "$name" ]] && continue
    warn "L2TP '$name' kedaluwarsa - dihapus."
    l2tp_del "$name" >/dev/null 2>&1 || true
  done < <(db_expired l2tp)
}
