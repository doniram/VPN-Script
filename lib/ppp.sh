#!/usr/bin/env bash
# lib/ppp.sh - shared PPP (chap-secrets) user management for SSTP/L2TP/PPTP
#
# Note: SSTP, L2TP and PPTP all authenticate through /etc/ppp/chap-secrets.
# Passwords are shared for a given username across these services.

[[ -n "${__SVPS_PPP_LOADED:-}" ]] && return 0
__SVPS_PPP_LOADED=1

PPP_CHAP_SECRETS="/etc/ppp/chap-secrets"

ppp_ensure() {
  mkdir -p /etc/ppp
  if [[ ! -f "$PPP_CHAP_SECRETS" ]]; then
    {
      printf '# Secrets for authentication using CHAP\n'
      printf '# client\tserver\tsecret\tIP addresses\n'
    } >"$PPP_CHAP_SECRETS"
  fi
  chmod 600 "$PPP_CHAP_SECRETS"
}

ppp_user_exists() {
  ppp_ensure
  awk -v n="$1" '$1==n {f=1} END {exit !f}' "$PPP_CHAP_SECRETS"
}

ppp_user_add() {
  local name="$1" pass="$2"
  ppp_ensure
  ppp_user_del "$name" || true
  printf '%s\t*\t%s\t*\n' "$name" "$pass" >>"$PPP_CHAP_SECRETS"
  chmod 600 "$PPP_CHAP_SECRETS"
}

ppp_user_del() {
  ppp_ensure
  local tmp; tmp="$(mktemp)"
  awk -v n="$1" '!/^#/ && $1==n {next} {print}' "$PPP_CHAP_SECRETS" >"$tmp"
  mv "$tmp" "$PPP_CHAP_SECRETS"
  chmod 600 "$PPP_CHAP_SECRETS"
}
