#!/usr/bin/env bash
# modules/ssh.sh - SSH tunnel users with expiry

[[ -n "${__SVPS_MOD_SSH_LOADED:-}" ]] && return 0
__SVPS_MOD_SSH_LOADED=1

# shellcheck source=/dev/null
. "$SVPS_DIR/lib/quota.sh"

SVPS_SSHD_DROPIN="/etc/ssh/sshd_config.d/99-scriptvps.conf"
SVPS_SSH_MARK="# managed by scriptvps"

ssh_install() {
  require_root
  info "Memasang modul SSH"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq openssh-server >/dev/null
  mkdir -p /etc/ssh/sshd_config.d
  if [[ ! -f "$SVPS_SSHD_DROPIN" ]]; then
    cat >"$SVPS_SSHD_DROPIN" <<EOF
$SVPS_SSH_MARK
# Tunneling-friendly defaults for VPN users.
AllowTcpForwarding yes
PermitTunnel yes
GatewayPorts no
X11Forwarding no
ClientAliveInterval 60
ClientAliveCountMax 3
EOF
    chmod 644 "$SVPS_SSHD_DROPIN"
  fi
  # Make sure the drop-in directory is included.
  if ! grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config 2>/dev/null; then
    printf '\n%s\nInclude /etc/ssh/sshd_config.d/*.conf\n' "$SVPS_SSH_MARK" >>/etc/ssh/sshd_config
  fi
  systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
  db_init ssh
  ok "Modul SSH siap."
}

ssh_uninstall() {
  local name
  while read -r name _; do
    [[ -z "$name" ]] && continue
    userdel -r "$name" 2>/dev/null || true
  done < <(db_list ssh)
  rm -f "$SVPS_SSHD_DROPIN"
  # remove only our include line
  if [[ -f /etc/ssh/sshd_config ]]; then
    sed -i "\|^$SVPS_SSH_MARK$|d; \|^Include /etc/ssh/sshd_config\.d/\*\.conf$|{/scriptvps/d}" /etc/ssh/sshd_config 2>/dev/null || true
  fi
  rm -f "$(db_file ssh)"
  systemctl reload ssh 2>/dev/null || true
  ok "Modul SSH dihapus."
}

_ssh_gen_pass() { openssl rand -base64 12 2>/dev/null | tr -d '/+=' | cut -c1-12; }

# ssh_add <name> <days> <iplimit> <quota> <meta>
ssh_add() {
  require_root
  local name="$1" days="$2" iplimit="${3:-0}" quota="${4:-0}" meta="${5:-}"
  [[ "$name" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] || die "Nama tidak valid (huruf kecil, angka, _ -)."
  if id "$name" >/dev/null 2>&1; then die "User '$name' sudah ada di sistem."; fi
  if db_exists ssh "$name"; then die "Akun SSH '$name' sudah ada di database."; fi

  local expires pass
  expires="$(date_add_days "$days")"
  pass="$(_ssh_gen_pass)"

  useradd -m -s /bin/bash -e "$expires" "$name" >/dev/null 2>&1 || die "Gagal membuat user."
  printf '%s:%s\n' "$name" "$pass" | chpasswd
  chage -E "$expires" "$name" 2>/dev/null || true
  db_add ssh "$name" "$expires" "$iplimit" "$quota" "default" "$meta" || true
  quota_register ssh "$name" "$(id -u "$name")" 2>/dev/null || true

  ok "Akun SSH dibuat: $name"
  plain "  Host      : $(public_ip)"
  plain "  Port      : ${SSH_PORT:-22}"
  plain "  Username  : $name"
  plain "  Password  : $pass"
  plain "  Expires   : $expires"
}

ssh_del() {
  require_root
  local name="$1"
  quota_unregister ssh "$name" 2>/dev/null || true
  userdel -r "$name" 2>/dev/null || warn "User sistem '$name' tidak ditemukan."
  db_del ssh "$name" || true
  ok "Akun SSH '$name' dihapus."
}

ssh_renew() {
  require_root
  local name="$1" days="$2" expires
  db_exists ssh "$name" || die "Akun SSH '$name' tidak ada."
  expires="$(date_add_days "$days")"
  chage -E "$expires" "$name" 2>/dev/null || true
  db_update_expiry ssh "$name" "$expires"
  ok "Akun SSH '$name' diperpanjang sampai $expires."
}

ssh_list() {
  local today; today="$(date +%s)"
  printf '%-18s %-12s %-12s %-8s %s\n' NAME CREATED EXPIRES IPLIMIT STATUS
  while IFS=$'\t' read -r name created expires iplimit _ _ _; do
    local status="active"
    if [[ -n "$expires" ]]; then
      local t; t="$(date -d "$expires" +%s 2>/dev/null || echo 0)"
      (( t < today )) && status="expired"
    fi
    printf '%-18s %-12s %-12s %-8s %s\n' "$name" "$created" "$expires" "${iplimit:-0}" "$status"
  done < <(db_list ssh)
}

ssh_status() {
  local n; n="$(db_count ssh)"
  if systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null; then
    echo "ssh: active (${n} akun)"
  else
    echo "ssh: inactive (${n} akun)"
  fi
}

ssh_expire_cleanup() {
  local name
  while read -r name; do
    [[ -z "$name" ]] && continue
    warn "SSH '$name' kedaluwarsa - menonaktifkan login."
    usermod -L "$name" 2>/dev/null || true
  done < <(db_expired ssh)
}
