#!/usr/bin/env bash
# modules/shadowsocks.sh - Shadowsocks (shadowsocks-libev), one port per user

[[ -n "${__SVPS_MOD_SS_LOADED:-}" ]] && return 0
__SVPS_MOD_SS_LOADED=1

# shellcheck source=/dev/null
. "$SVPS_DIR/lib/quota.sh"

SS_CONF="/etc/shadowsocks-libev/server.json"
SS_INSTANCE="server"
SS_BASE_PORT="${SS_BASE_PORT:-8388}"
SS_METHOD="${SS_METHOD:-aes-256-gcm}"

ss_base_port() { config_get ss_base_port "$SS_BASE_PORT"; }
ss_method()    { config_get ss_method "$SS_METHOD"; }

ss_install() {
  require_root
  info "Memasang modul Shadowsocks"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq shadowsocks-libev jq >/dev/null
  mkdir -p /etc/shadowsocks-libev
  if [[ ! -f "$SS_CONF" ]]; then
    local method
    method="$(ss_method)"
    cat >"$SS_CONF" <<EOF
{
  "server": "0.0.0.0",
  "port_password": {},
  "method": "${method}",
  "mode": "tcp_and_udp",
  "timeout": 300
}
EOF
    chmod 600 "$SS_CONF"
  fi
  systemctl enable shadowsocks-libev-server@"$SS_INSTANCE" >/dev/null 2>&1 || true
  systemctl restart shadowsocks-libev-server@"$SS_INSTANCE" 2>/dev/null || warn "Tidak bisa start Shadowsocks (mungkin tanpa systemd)."
  db_init ss
  ok "Modul Shadowsocks siap (method: $(ss_method))."
}

ss_uninstall() {
  systemctl stop shadowsocks-libev-server@"$SS_INSTANCE" 2>/dev/null || true
  systemctl disable shadowsocks-libev-server@"$SS_INSTANCE" 2>/dev/null || true
  rm -f "$SS_CONF"
  rm -f "$(db_file ss)"
  ok "Modul Shadowsocks dihapus."
}

_ss_used_ports() {
  db_list ss | awk -F'\t' '{print $7}' | tr ';' '\n' | awk -F= '$1=="port"{print $2}'
}

_ss_next_port() {
  local base used n
  base="$(ss_base_port)"
  used="$(_ss_used_ports | tr '\n' ' ')"
  for (( n=base; n<base+500; n++ )); do
    [[ " $used " == *" $n "* ]] && continue
    if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${n}$"; then continue; fi
    printf '%s' "$n"; return 0
  done
  return 1
}

# ss_add <name> <days> <iplimit> <quota> <meta>
ss_add() {
  require_root
  local name="$1" days="$2" iplimit="${3:-0}" quota="${4:-0}" meta="${5:-}"
  [[ "$name" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] || die "Nama tidak valid."
  db_exists ss "$name" && die "Akun Shadowsocks '$name' sudah ada."
  [[ -f "$SS_CONF" ]] || die "Shadowsocks belum diinstall."

  local port pass expires tmp
  port="$(_ss_next_port)" || die "Port pool penuh."
  pass="$(openssl rand -base64 12 | tr -d '/+=' | cut -c1-12)"
  expires="$(date_add_days "$days")"

  tmp="$(mktemp)"
  jq --arg p "$port" --arg pw "$pass" '.port_password[$p] = $pw' "$SS_CONF" >"$tmp" || die "jq gagal."
  mv "$tmp" "$SS_CONF"
  systemctl restart shadowsocks-libev-server@"$SS_INSTANCE" 2>/dev/null || true
  db_add ss "$name" "$expires" "$iplimit" "$quota" "default" "port=${port};pass=${pass}" || true
  quota_register ss "$name" "$port" 2>/dev/null || true

  local method host link
  method="$(ss_method)"
  host="$(public_ip || echo '')"
  link="ss://$(printf '%s:%s' "$method" "$pass" | base64 | tr -d '\n')@${host}:${port}#${name}"

  ok "Akun Shadowsocks dibuat: $name (port $port)"
  plain "  Expires   : $expires"
  plain "  Link      : $link"
}

ss_del() {
  require_root
  local name="$1" port tmp
  [[ -f "$SS_CONF" ]] || die "Shadowsocks belum diinstall."
  quota_unregister ss "$name" 2>/dev/null || true
  port="$(printf '%s' "$(db_field ss "$name" 7)" | tr ';' '\n' | awk -F= '$1=="port"{print $2}')"
  if [[ -n "$port" ]]; then
    tmp="$(mktemp)"
    jq --arg p "$port" 'del(.port_password[$p])' "$SS_CONF" >"$tmp" && mv "$tmp" "$SS_CONF"
    systemctl restart shadowsocks-libev-server@"$SS_INSTANCE" 2>/dev/null || true
  fi
  db_del ss "$name" || true
  ok "Akun Shadowsocks '$name' dihapus."
}

ss_renew() {
  local name="$1" days="$2" expires
  db_exists ss "$name" || die "Akun '$name' tidak ada."
  expires="$(date_add_days "$days")"
  db_update_expiry ss "$name" "$expires"
  ok "Akun '$name' diperpanjang sampai $expires."
}

ss_list() {
  local today; today="$(date +%s)"
  printf '%-18s %-8s %-10s %-12s %s\n' NAME PORT METHOD EXPIRES STATUS
  while IFS=$'\t' read -r name _ expires _ _ _ meta; do
    local port status="active" t=0
    port="$(printf '%s' "$meta" | tr ';' '\n' | awk -F= '$1=="port"{print $2}')"
    [[ -n "$expires" ]] && t="$(date -d "$expires" +%s 2>/dev/null || echo 0)"
    (( t < today )) && status="expired"
    printf '%-18s %-8s %-10s %-12s %s\n' "$name" "${port:--}" "$(ss_method)" "$expires" "$status"
  done < <(db_list ss)
}

ss_status() {
  local n; n="$(db_count ss)"
  if systemctl is-active --quiet shadowsocks-libev-server@"$SS_INSTANCE" 2>/dev/null; then
    echo "ss: active (${n} akun)"
  else
    echo "ss: inactive (${n} akun)"
  fi
}

ss_expire_cleanup() {
  local name
  while read -r name; do
    [[ -z "$name" ]] && continue
    warn "Shadowsocks '$name' kedaluwarsa - dihapus."
    ss_del "$name" >/dev/null 2>&1 || true
  done < <(db_expired ss)
}
