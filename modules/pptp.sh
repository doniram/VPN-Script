#!/usr/bin/env bash
# modules/pptp.sh - PPTP server (pptpd), users via chap-secrets
# Note: pptpd package is only available on Ubuntu 22.04; PPTP is insecure/legacy.

[[ -n "${__SVPS_MOD_PPTP_LOADED:-}" ]] && return 0
__SVPS_MOD_PPTP_LOADED=1

# shellcheck source=/dev/null
. "$SVPS_DIR/lib/ppp.sh"

PPTP_LOCAL="192.168.0.1"
PPTP_RANGE="192.168.0.100-200"
PPTP_SUBNET="192.168.0.0/24"

pptp_install() {
  require_root
  info "Memasang modul PPTP"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  if ! apt-get install -y -qq pptpd ppp iptables >/dev/null 2>&1; then
    die "Paket 'pptpd' tidak tersedia di distro ini (PPTP hanya didukung di Ubuntu 22.04)."
  fi

  cat >/etc/pptpd.conf <<EOF
option /etc/ppp/pptpd-options
logwtmp
localip ${PPTP_LOCAL}
remoteip ${PPTP_RANGE}
EOF

  cat >/etc/ppp/pptpd-options <<'EOF'
name pptpd
refuse-pap
refuse-chap
refuse-mschap
require-mschap-v2
require-mppe-128
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

  enable_ip_forward
  svps_nat_add_subnet "$PPTP_SUBNET"
  systemctl enable pptpd >/dev/null 2>&1 || true
  systemctl restart pptpd 2>/dev/null || warn "Tidak bisa start pptpd (mungkin tanpa systemd)."
  db_init pptp
  ok "Modul PPTP siap."
}

pptp_uninstall() {
  systemctl stop pptpd 2>/dev/null || true
  systemctl disable pptpd 2>/dev/null || true
  rm -f /etc/pptpd.conf /etc/ppp/pptpd-options
  rm -f "$(db_file pptp)"
  svps_nat_remove_subnet "$PPTP_SUBNET"
  ok "Modul PPTP dihapus."
}

# pptp_add <name> <days> <iplimit> <quota> <meta>
pptp_add() {
  require_root
  local name="$1" days="$2" iplimit="${3:-0}" quota="${4:-0}" meta="${5:-}"
  [[ "$name" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] || die "Nama tidak valid."
  db_exists pptp "$name" && die "Akun PPTP '$name' sudah ada."

  local pass expires
  pass="$(openssl rand -base64 12 | tr -d '/+=' | cut -c1-12)"
  expires="$(date_add_days "$days")"
  ppp_user_add "$name" "$pass"
  db_add pptp "$name" "$expires" "$iplimit" "$quota" "default" "$meta" || true

  ok "Akun PPTP dibuat: $name"
  plain "  Server    : $(public_ip) (PPTP)"
  plain "  Username  : $name"
  plain "  Password  : $pass"
  plain "  Expires   : $expires"
}

pptp_del() {
  require_root
  local name="$1"
  ppp_user_del "$name" || true
  db_del pptp "$name" || true
  ok "Akun PPTP '$name' dihapus."
}

pptp_renew() {
  local name="$1" days="$2" expires
  db_exists pptp "$name" || die "Akun '$name' tidak ada."
  expires="$(date_add_days "$days")"
  db_update_expiry pptp "$name" "$expires"
  ok "Akun '$name' diperpanjang sampai $expires."
}

pptp_list() {
  local today; today="$(date +%s)"
  printf '%-18s %-12s %s\n' NAME EXPIRES STATUS
  while IFS=$'\t' read -r name _ expires _ _ _ _; do
    local status="active" t=0
    [[ -n "$expires" ]] && t="$(date -d "$expires" +%s 2>/dev/null || echo 0)"
    (( t < today )) && status="expired"
    printf '%-18s %-12s %s\n' "$name" "$expires" "$status"
  done < <(db_list pptp)
}

pptp_status() {
  local n; n="$(db_count pptp)"
  if systemctl is-active --quiet pptpd 2>/dev/null; then
    echo "pptp: active (${n} akun)"
  else
    echo "pptp: inactive (${n} akun)"
  fi
}

pptp_expire_cleanup() {
  local name
  while read -r name; do
    [[ -z "$name" ]] && continue
    warn "PPTP '$name' kedaluwarsa - dihapus."
    pptp_del "$name" >/dev/null 2>&1 || true
  done < <(db_expired pptp)
}
