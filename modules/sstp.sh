#!/usr/bin/env bash
# modules/sstp.sh - SSTP server (sstpd) with users via chap-secrets

[[ -n "${__SVPS_MOD_SSTP_LOADED:-}" ]] && return 0
__SVPS_MOD_SSTP_LOADED=1

# shellcheck source=/dev/null
. "$SVPS_DIR/lib/ppp.sh"

SSTP_PORT="${SSTP_PORT:-444}"
SSTP_LOCAL="192.168.20.1"
SSTP_SUBNET="192.168.20.0/24"
SSTP_VENV="/opt/sstpd/venv"
SSTP_CERT="$SVPS_ETC/sstp/sstpd.crt"
SSTP_KEY="$SVPS_ETC/sstp/sstpd.key"

sstp_port() { config_get sstp_port "$SSTP_PORT"; }

_sstp_write_cert() {
  mkdir -p "$(dirname "$SSTP_CERT")"; chmod 700 "$(dirname "$SSTP_CERT")"
  local domain; domain="$(config_get domain "")"
  local cn="${domain:-scriptvps.local}"
  if [[ "$domain" == *"sstp"* ]] && [[ -f "$SVPS_ETC/tls/fullchain.pem" ]]; then
    cp "$SVPS_ETC/tls/fullchain.pem" "$SSTP_CERT"
    cp "$SVPS_ETC/tls/privkey.pem" "$SSTP_KEY"
  else
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
      -keyout "$SSTP_KEY" -out "$SSTP_CERT" -subj "/CN=${cn}" >/dev/null 2>&1
  fi
  chmod 600 "$SSTP_CERT" "$SSTP_KEY"
}

_sstp_write_unit() {
  cat >/etc/systemd/system/sstpd.service <<EOF
[Unit]
Description=SSTP server (scriptvps)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${SSTP_VENV}/bin/sstpd -p $(sstp_port) -c ${SSTP_CERT} -k ${SSTP_KEY} \\
  --pppd /usr/sbin/pppd --pppd-config /etc/ppp/options.sstpd \\
  --local ${SSTP_LOCAL} --remote ${SSTP_SUBNET}
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload 2>/dev/null || true
}

sstp_install() {
  require_root
  info "Memasang modul SSTP"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq python3 python3-venv python3-pip ppp iptables openssl >/dev/null

  if [[ ! -x "$SSTP_VENV/bin/sstpd" ]]; then
    info "Memasang sstp-server ke venv ($SSTP_VENV)"
    python3 -m venv "$SSTP_VENV" >/dev/null 2>&1 || die "Gagal membuat venv."
    "$SSTP_VENV/bin/pip" install --quiet --upgrade pip >/dev/null 2>&1 || true
    "$SSTP_VENV/bin/pip" install --quiet "sstp-server==0.7.2" >/dev/null 2>&1 || die "Gagal memasang sstp-server."
  fi

  _sstp_write_cert

  cat >/etc/ppp/options.sstpd <<'EOF'
require-mschap-v2
ms-dns 1.1.1.1
ms-dns 8.8.8.8
proxyarp
lock
nobsdcomp
novj
novjccomp
nopcomp
noaccomp
auth
EOF

  _sstp_write_unit
  enable_ip_forward
  svps_nat_add_subnet "$SSTP_SUBNET"

  systemctl enable sstpd >/dev/null 2>&1 || true
  systemctl restart sstpd 2>/dev/null || warn "Tidak bisa start sstpd (mungkin tanpa systemd)."
  db_init sstp
  ok "Modul SSTP siap (port $(sstp_port))."
}

sstp_uninstall() {
  systemctl stop sstpd 2>/dev/null || true
  systemctl disable sstpd 2>/dev/null || true
  rm -f /etc/systemd/system/sstpd.service /etc/ppp/options.sstpd
  rm -rf "$SSTP_VENV" "$(dirname "$SSTP_CERT")"
  rm -f "$(db_file sstp)"
  svps_nat_remove_subnet "$SSTP_SUBNET"
  systemctl daemon-reload 2>/dev/null || true
  ok "Modul SSTP dihapus."
}

# sstp_add <name> <days> <iplimit> <quota> <meta>
sstp_add() {
  require_root
  local name="$1" days="$2" iplimit="${3:-0}" quota="${4:-0}" meta="${5:-}"
  [[ "$name" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] || die "Nama tidak valid."
  db_exists sstp "$name" && die "Akun SSTP '$name' sudah ada."

  local pass expires
  pass="$(openssl rand -base64 12 | tr -d '/+=' | cut -c1-12)"
  expires="$(date_add_days "$days")"
  ppp_user_add "$name" "$pass"
  db_add sstp "$name" "$expires" "$iplimit" "$quota" "default" "$meta" || true

  ok "Akun SSTP dibuat: $name"
  plain "  Server    : $(public_ip):$(sstp_port)"
  plain "  Username  : $name"
  plain "  Password  : $pass"
  plain "  Expires   : $expires"
}

sstp_del() {
  require_root
  local name="$1"
  ppp_user_del "$name" || true
  db_del sstp "$name" || true
  ok "Akun SSTP '$name' dihapus."
}

sstp_renew() {
  local name="$1" days="$2" expires
  db_exists sstp "$name" || die "Akun '$name' tidak ada."
  expires="$(date_add_days "$days")"
  db_update_expiry sstp "$name" "$expires"
  ok "Akun '$name' diperpanjang sampai $expires."
}

sstp_list() {
  local today; today="$(date +%s)"
  printf '%-18s %-12s %s\n' NAME EXPIRES STATUS
  while IFS=$'\t' read -r name _ expires _ _ _ _; do
    local status="active" t=0
    [[ -n "$expires" ]] && t="$(date -d "$expires" +%s 2>/dev/null || echo 0)"
    (( t < today )) && status="expired"
    printf '%-18s %-12s %s\n' "$name" "$expires" "$status"
  done < <(db_list sstp)
}

sstp_status() {
  local n; n="$(db_count sstp)"
  if systemctl is-active --quiet sstpd 2>/dev/null; then
    echo "sstp: active (${n} akun)"
  else
    echo "sstp: inactive (${n} akun)"
  fi
}

sstp_expire_cleanup() {
  local name
  while read -r name; do
    [[ -z "$name" ]] && continue
    warn "SSTP '$name' kedaluwarsa - dihapus."
    sstp_del "$name" >/dev/null 2>&1 || true
  done < <(db_expired sstp)
}
