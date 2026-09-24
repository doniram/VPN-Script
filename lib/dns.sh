#!/usr/bin/env bash
# lib/dns.sh - Cloudflare DNS helpers (token supplied by the operator)

[[ -n "${__SVPS_DNS_LOADED:-}" ]] && return 0
__SVPS_DNS_LOADED=1

CF_API="https://api.cloudflare.com/client/v4"

_cf_curl() {
  local method="$1" path="$2" token="$3" data="${4:-}"
  if [[ -n "$data" ]]; then
    curl -fsSL -X "$method" "$CF_API$path" \
      -H "Authorization: Bearer $token" \
      -H "Content-Type: application/json" \
      --data "$data"
  else
    curl -fsSL -X "$method" "$CF_API$path" \
      -H "Authorization: Bearer $token" \
      -H "Content-Type: application/json"
  fi
}

# cf_zone_id <hostname> <token> -> prints zone id
cf_zone_id() {
  local host="$1" token="$2" labels i cand resp id
  IFS='.' read -r -a labels <<<"$host"
  for (( i=0; i<${#labels[@]}-1; i++ )); do
    cand="$(IFS='.'; echo "${labels[*]:i}")"
    resp="$(_cf_curl GET "/zones?name=${cand}&status=active" "$token" 2>/dev/null || true)"
    id="$(printf '%s' "$resp" | jq -r '.result[0].id // empty' 2>/dev/null || true)"
    if [[ -n "$id" ]]; then printf '%s' "$id"; return 0; fi
  done
  return 1
}

# cf_upsert_a <hostname> <ip> <token>
cf_upsert_a() {
  local host="$1" ip="$2" token="$3" zone resp recid
  zone="$(cf_zone_id "$host" "$token")" || { err "Zone Cloudflare untuk '$host' tidak ditemukan."; return 1; }
  resp="$(_cf_curl GET "/zones/${zone}/dns_records?type=A&name=${host}" "$token" 2>/dev/null || true)"
  recid="$(printf '%s' "$resp" | jq -r '.result[0].id // empty' 2>/dev/null || true)"
  if [[ -n "$recid" ]]; then
    _cf_curl PUT "/zones/${zone}/dns_records/${recid}" "$token" \
      "{\"type\":\"A\",\"name\":\"${host}\",\"content\":\"${ip}\",\"ttl\":120,\"proxied\":false}" >/dev/null \
      || { err "Gagal update record A."; return 1; }
    ok "DNS A diperbarui: ${host} -> ${ip}"
  else
    _cf_curl POST "/zones/${zone}/dns_records" "$token" \
      "{\"type\":\"A\",\"name\":\"${host}\",\"content\":\"${ip}\",\"ttl\":120,\"proxied\":false}" >/dev/null \
      || { err "Gagal membuat record A."; return 1; }
    ok "DNS A dibuat: ${host} -> ${ip}"
  fi
}
