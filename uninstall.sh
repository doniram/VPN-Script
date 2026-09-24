#!/usr/bin/env bash
# uninstall.sh - remove scriptvps services and state
set -euo pipefail

UN_SELF="$(readlink -f "${BASH_SOURCE[0]}")"
UN_DIR="$(cd "$(dirname "$UN_SELF")" && pwd)"
# shellcheck source=/dev/null
. "$UN_DIR/lib/common.sh"
# shellcheck source=/dev/null
. "$UN_DIR/lib/net.sh"
# shellcheck source=/dev/null
. "$UN_DIR/lib/db.sh"
# shellcheck source=/dev/null
. "$UN_DIR/lib/services.sh"

PURGE=0
[[ "${1:-}" == "--purge" ]] && PURGE=1

require_root
warn "Ini akan menghapus layanan yang dipasang oleh scriptvps."
(( PURGE )) && warn "Mode --purge: state di $SVPS_ETC juga akan dihapus."
confirm "Lanjutkan?" || { plain "Dibatalkan."; exit 0; }

for svc in $SPVS_ALL_SERVICES; do
  f="$(db_file "$svc")"
  [[ -f "$f" ]] || continue
  svps_service_available "$svc" || continue
  svps_load_service "$svc" 2>/dev/null || continue
  prefix="$(svps_service_prefix "$svc")"
  fn="${prefix}_uninstall"
  if declare -F "$fn" >/dev/null 2>&1; then
    "$fn" || warn "Uninstall '$svc' gagal sebagian."
  fi
done

systemctl disable --now scriptvps-check.timer >/dev/null 2>&1 || true
rm -f /etc/systemd/system/scriptvps-check.service /etc/systemd/system/scriptvps-check.timer
systemctl daemon-reload 2>/dev/null || true
rm -f /usr/local/bin/scriptvps

if (( PURGE )); then
  rm -rf "$SVPS_ETC"
  ok "State $SVPS_ETC dihapus."
fi
ok "Uninstall selesai."
