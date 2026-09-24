#!/usr/bin/env bash
# tools/license-add.sh - admin helper: generate a license key + manifest row
set -euo pipefail

NAME=""
PLAN="pro"
EXPIRES=""
IPS=""
FEATURES="ssh,ovpn,wg,xray,panel"
FILE="licenses.tsv"
SALT="scriptvps-v1"

usage() {
  cat <<'EOF'
Pemakaian: license-add.sh --name "Customer" [opsi]

  --name <str>        nama pelanggan (wajib)
  --expires <date>    YYYY-MM-DD (kosong = tanpa kedaluwarsa)
  --ips "a,b,c"       daftar IP publik server pelanggan
  --plan <str>        default: pro
  --features "..."    default: ssh,ovpn,wg,xray,panel
  --file <path>       manifest tujuan (default: licenses.tsv)
  --salt <str>        salt hash IP (harus sama dengan config server)

Output: license key dicetak ke stdout; baris manifest ditambahkan ke --file.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) NAME="${2:?}"; shift 2 ;;
    --expires) EXPIRES="${2:?}"; shift 2 ;;
    --ips) IPS="${2:?}"; shift 2 ;;
    --plan) PLAN="${2:?}"; shift 2 ;;
    --features) FEATURES="${2:?}"; shift 2 ;;
    --file) FILE="${2:?}"; shift 2 ;;
    --salt) SALT="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Opsi tidak dikenal: $1" >&2; usage; exit 1 ;;
  esac
done

[[ -n "$NAME" ]] || { echo "--name wajib." >&2; exit 1; }
[[ -n "$EXPIRES" ]] || EXPIRES="-"

KEY="SVPS-$(openssl rand -hex 4 | tr 'a-f' 'A-F')-$(openssl rand -hex 4 | tr 'a-f' 'A-F')-$(openssl rand -hex 4 | tr 'a-f' 'A-F')"
KEY_HASH="$(printf '%s' "$KEY" | sha256sum | awk '{print $1}')"

ip_hashes=""
if [[ -n "$IPS" ]]; then
  IFS=',' read -r -a arr <<<"$IPS"
  for ip in "${arr[@]}"; do
    ip="$(echo "$ip" | xargs)"
    [[ -z "$ip" ]] && continue
    h="$(printf '%s%s' "$SALT" "$ip" | sha256sum | awk '{print $1}')"
    ip_hashes="${ip_hashes:+$ip_hashes,}$h"
  done
fi
[[ -z "$ip_hashes" ]] && ip_hashes="-"

if [[ ! -f "$FILE" ]]; then
  printf '# scriptvps license manifest v1\n' >"$FILE"
  printf '# key_sha256\tname\tplan\texpires\tip_sha256_csv\tfeatures_csv\n' >>"$FILE"
fi
printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$KEY_HASH" "$NAME" "$PLAN" "$EXPIRES" "$ip_hashes" "$FEATURES" >>"$FILE"

echo "$KEY"
echo "Manifest ditambahkan ke: $FILE" >&2
echo "IP hash: $ip_hashes" >&2
