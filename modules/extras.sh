#!/usr/bin/env bash
# modules/extras.sh - bandwidth limiting (tc) and SSH login banner

[[ -n "${__SVPS_MOD_EXTRAS_LOADED:-}" ]] && return 0
__SVPS_MOD_EXTRAS_LOADED=1

LIMIT_SCRIPT="$SVPS_ETC/limit-speed-apply.sh"
LIMIT_UNIT="/etc/systemd/system/scriptvps-limit-speed.service"
BANNER_FILE="/etc/issue.net"
SSHD_DROPIN="/etc/ssh/sshd_config.d/99-scriptvps.conf"

# ---------------------------------------------------------------------------
# Bandwidth limit (HTB on the default interface)
# ---------------------------------------------------------------------------
_limit_write_script() {
  cat >"$LIMIT_SCRIPT" <<'EOF'
#!/usr/bin/env bash
kbps="$(grep -E '^limit_speed_kbps=' /etc/scriptvps/config.conf 2>/dev/null | tail -n1 | cut -d= -f2-)"
iface="$(ip -4 route show default | awk '{print $5; exit}')"
[[ -n "$iface" ]] || exit 0
tc qdisc del dev "$iface" root 2>/dev/null || true
[[ -z "$kbps" || "$kbps" == "0" ]] && exit 0
tc qdisc add dev "$iface" root handle 1: htb default 1 2>/dev/null || exit 0
tc class add dev "$iface" parent 1: classid 1:1 htb rate "${kbps}kbit" ceil "${kbps}kbit" 2>/dev/null || true
EOF
  chmod 700 "$LIMIT_SCRIPT"
  cat >"$LIMIT_UNIT" <<'EOF'
[Unit]
Description=scriptvps bandwidth limit
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/etc/scriptvps/limit-speed-apply.sh

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload 2>/dev/null || true
}

svps_limit_speed_set() {
  require_root
  local kbps="$1"
  [[ "$kbps" =~ ^[0-9]+$ ]] || die "Gunakan: scriptvps limit-speed <kbps|off>"
  config_set limit_speed_kbps "$kbps"
  _limit_write_script
  systemctl enable scriptvps-limit-speed.service >/dev/null 2>&1 || true
  bash "$LIMIT_SCRIPT"
  ok "Batas bandwidth diatur: ${kbps} kbit/s."
}

svps_limit_speed_off() {
  require_root
  config_set limit_speed_kbps "0"
  _limit_write_script
  bash "$LIMIT_SCRIPT"
  systemctl disable scriptvps-limit-speed.service >/dev/null 2>&1 || true
  ok "Batas bandwidth dimatikan."
}

svps_limit_speed_status() {
  local kbps; kbps="$(config_get limit_speed_kbps 0)"
  if [[ -z "$kbps" || "$kbps" == "0" ]]; then
    echo "limit-speed: off"
  else
    echo "limit-speed: ${kbps} kbit/s"
  fi
}

# ---------------------------------------------------------------------------
# SSH banner
# ---------------------------------------------------------------------------
svps_banner_set() {
  require_root
  local text="$1"
  [[ -z "$text" ]] && die "Gunakan: scriptvps banner <teks>"
  printf '%s\n' "$text" >"$BANNER_FILE"
  mkdir -p /etc/ssh/sshd_config.d
  if [[ -f "$SSHD_DROPIN" ]]; then
    grep -q '^Banner ' "$SSHD_DROPIN" || printf 'Banner %s\n' "$BANNER_FILE" >>"$SSHD_DROPIN"
  else
    printf '# managed by scriptvps\nBanner %s\n' "$BANNER_FILE" >"$SSHD_DROPIN"
  fi
  systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
  ok "Banner SSH diatur."
}

svps_banner_off() {
  require_root
  if [[ -f "$SSHD_DROPIN" ]]; then
    local tmp; tmp="$(mktemp)"
    grep -v '^Banner ' "$SSHD_DROPIN" >"$tmp" || true
    mv "$tmp" "$SSHD_DROPIN"
  fi
  systemctl reload ssh 2>/dev/null || true
  ok "Banner SSH dimatikan."
}
