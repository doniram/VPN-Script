#!/usr/bin/env bash
# panel/install-panel.sh - install the scriptvps web panel (Go)
set -euo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
PANEL_DIR="$(cd "$(dirname "$SELF")" && pwd)"
ROOT="$(cd "$PANEL_DIR/.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/lib/common.sh"

PANEL_USER="admin"
PANEL_PASS=""
PANEL_DOMAIN=""
NO_NGINX=0

usage() {
  cat <<'EOF'
Pemakaian: install-panel.sh [opsi]
  --user <name>       username admin panel (default: admin)
  --password <pass>   password admin (default: di-generate)
  --domain <host>     domain panel untuk Nginx + TLS (opsional)
  --no-nginx          jangan konfigurasi Nginx
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) PANEL_USER="${2:?}"; shift 2 ;;
    --password) PANEL_PASS="${2:?}"; shift 2 ;;
    --domain) PANEL_DOMAIN="${2:?}"; shift 2 ;;
    --no-nginx) NO_NGINX=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Opsi tidak dikenal: $1" ;;
  esac
done

require_root

BIN="$PANEL_DIR/bin/scriptvps-panel"
if [[ ! -x "$BIN" ]]; then
  info "Binary panel belum ada; membangun..."
  bash "$PANEL_DIR/build.sh"
fi
[[ -x "$BIN" ]] || die "Binary panel tidak ditemukan setelah build."

# 1. Install binary
install -d -m 0755 /opt/scriptvps-panel
install -m 0755 "$BIN" /opt/scriptvps-panel/scriptvps-panel
ok "Binary dipasang di /opt/scriptvps-panel/scriptvps-panel"

# 2. System user
if ! id -u scriptvps >/dev/null 2>&1; then
  useradd --system --no-create-home --shell /usr/sbin/nologin scriptvps
  ok "User sistem 'scriptvps' dibuat."
fi

# 3. Panel credentials
init_dirs
if [[ -z "$PANEL_PASS" ]]; then
  PANEL_PASS="$(openssl rand -base64 12 | tr -d '/+=' | cut -c1-16)"
  GENERATED=1
else
  GENERATED=0
fi
HASH="$(/opt/scriptvps-panel/scriptvps-panel hashpw "$PANEL_PASS")"
cat >"$SVPS_ETC/panel.conf" <<EOF
username=$PANEL_USER
password_hash=$HASH
EOF
chmod 600 "$SVPS_ETC/panel.conf"
ok "Kredensial panel disimpan di $SVPS_ETC/panel.conf"

# 4. sudoers drop-in
install -m 0440 "$PANEL_DIR/sudoers/scriptvps-panel" /etc/sudoers.d/scriptvps-panel
if command -v visudo >/dev/null 2>&1; then
  visudo -cf /etc/sudoers.d/scriptvps-panel >/dev/null || die "sudoers tidak valid."
fi
ok "Sudoers drop-in terpasang."

# 5. systemd service
install -m 0644 "$PANEL_DIR/systemd/scriptvps-panel.service" /etc/systemd/system/scriptvps-panel.service
systemctl daemon-reload 2>/dev/null || true
systemctl enable scriptvps-panel >/dev/null 2>&1 || true
systemctl restart scriptvps-panel 2>/dev/null || warn "Tidak bisa start panel (mungkin tanpa systemd)."
ok "Service panel diaktifkan."

# 6. Optional Nginx
if (( ! NO_NGINX )) && [[ -n "$PANEL_DOMAIN" ]] && has_cmd nginx; then
  if [[ -f "$SVPS_ETC/tls/fullchain.pem" ]]; then
    sed "s/panel.example.com/${PANEL_DOMAIN}/g" "$PANEL_DIR/nginx/panel.conf" \
      >/etc/nginx/sites-available/scriptvps-panel
    ln -sf /etc/nginx/sites-available/scriptvps-panel /etc/nginx/sites-enabled/scriptvps-panel
    if nginx -t >/dev/null 2>&1; then
      systemctl reload nginx 2>/dev/null || true
      ok "Nginx dikonfigurasi untuk ${PANEL_DOMAIN}."
    else
      warn "Konfigurasi Nginx tidak valid; periksa /etc/nginx/sites-available/scriptvps-panel."
    fi
  else
    warn "Sertifikat TLS belum ada di $SVPS_ETC/tls; Nginx dilewati."
  fi
fi

# 7. Summary
plain ""
plain "${C_GREEN}${C_BOLD}Panel scriptvps siap.${C_RESET}"
plain "  URL lokal : http://127.0.0.1:8080"
[[ -n "$PANEL_DOMAIN" ]] && plain "  URL       : https://${PANEL_DOMAIN}"
plain "  Username  : ${PANEL_USER}"
if (( GENERATED )); then
  plain "  Password  : ${PANEL_PASS}   ${C_YELLOW}(simpan & ganti!)${C_RESET}"
fi
plain ""
plain "Cek status: systemctl status scriptvps-panel"
