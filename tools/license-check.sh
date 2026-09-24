#!/usr/bin/env bash
# tools/license-check.sh - verify a license key against a manifest
set -euo pipefail

KEY=""
URL=""
FILE=""
IP=""
SALT="scriptvps-v1"

usage() {
  cat <<'EOF'
Pemakaian: license-check.sh --key <KEY> (--url <URL> | --file <path>) [--ip <ip>] [--salt <s>]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --key) KEY="${2:?}"; shift 2 ;;
    --url) URL="${2:?}"; shift 2 ;;
    --file) FILE="${2:?}"; shift 2 ;;
    --ip) IP="${2:?}"; shift 2 ;;
    --salt) SALT="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Opsi tidak dikenal: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$KEY" ]] || { echo "--key wajib." >&2; exit 1; }
[[ -n "$URL" || -n "$FILE" ]] || { echo "--url atau --file wajib." >&2; exit 1; }
[[ -n "$IP" ]] || IP="$(curl -fsSL --max-time 5 https://ipinfo.io/ip 2>/dev/null || echo '')"

KEY_HASH="$(printf '%s' "$KEY" | sha256sum | awk '{print $1}')"
IP_HASH="$(printf '%s%s' "$SALT" "$IP" | sha256sum | awk '{print $1}')"

if [[ -n "$URL" ]]; then
  BODY="$(curl -fsSL --max-time 15 "$URL" 2>/dev/null || true)"
else
  BODY="$(cat "$FILE" 2>/dev/null || true)"
fi

LINE="$(printf '%s\n' "$BODY" | awk -F'\t' -v k="$KEY_HASH" '!/^#/ && $1==k {print; exit}')"
if [[ -z "$LINE" ]]; then
  echo "status=not_found"; exit 1
fi

EXP="$(printf '%s' "$LINE" | cut -f4)"
IPCSV="$(printf '%s' "$LINE" | cut -f5)"
FEATS="$(printf '%s' "$LINE" | cut -f6)"

if [[ -n "$EXP" && "$EXP" != "-" ]]; then
  if [[ "$(date -d "$EXP" +%s 2>/dev/null || echo 0)" -lt "$(date +%s)" ]]; then
    echo "status=expired expires=$EXP"; exit 1
  fi
fi
if [[ -n "$IPCSV" && "$IPCSV" != "-" ]]; then
  if [[ ",$IPCSV," != *",$IP_HASH,"* ]]; then
    echo "status=ip_unregistered ip=$IP"; exit 1
  fi
fi
echo "status=licensed expires=$EXP features=$FEATS"
