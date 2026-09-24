#!/usr/bin/env bash
# modules/xray.sh - Xray (VLESS/VMess/Trojan over WS & gRPC) with TLS

[[ -n "${__SVPS_MOD_XRAY_LOADED:-}" ]] && return 0
__SVPS_MOD_XRAY_LOADED=1

XRAY_BIN="/usr/local/bin/xray"
XRAY_CFG_DIR="/usr/local/etc/xray"
XRAY_CFG="$XRAY_CFG_DIR/config.json"
XRAY_SERVICE="/etc/systemd/system/xray.service"
SVPS_TLS_DIR="$SVPS_ETC/tls"
SVPS_CERT="$SVPS_TLS_DIR/fullchain.pem"
SVPS_KEY="$SVPS_TLS_DIR/privkey.pem"

xray_domain()      { config_get domain ""; }
xray_cf_token()    { config_get cloudflare_token ""; }
xray_cf_account()  { config_get cloudflare_account_id ""; }
xray_acme_email()  { config_get acme_email ""; }
xray_port_vless_ws()   { config_get xray_port_vless_ws "443"; }
xray_port_vmess_ws()   { config_get xray_port_vmess_ws "8443"; }
xray_port_vless_grpc() { config_get xray_port_vless_grpc "2053"; }
xray_port_vmess_grpc() { config_get xray_port_vmess_grpc "2054"; }
xray_port_trojan()     { config_get xray_port_trojan "2087"; }
xray_version()     { config_get xray_version "latest"; }

_xray_asset() {
  case "$(server_arch)" in
    amd64) echo "Xray-linux-64.zip" ;;
    arm64) echo "Xray-linux-arm64-v8a.zip" ;;
    *) return 1 ;;
  esac
}

_xray_download() {
  require_cmd curl
  local arch_asset tag version url sha tmpdir
  arch_asset="$(_xray_asset)" || die "Arsitektur tidak didukung untuk Xray: $(server_arch)"
  version="$(xray_version)"
  if [[ "$version" == "latest" ]]; then
    tag="$(curl -fsSL --max-time 20 https://api.github.com/repos/XTLS/Xray-core/releases/latest \
      | jq -r '.tag_name // empty' 2>/dev/null || true)"
    [[ -n "$tag" ]] || die "Tidak bisa membaca versi Xray terbaru."
  else
    tag="$version"
  fi
  url="https://github.com/XTLS/Xray-core/releases/download/${tag}/${arch_asset}"

  # Try to obtain the official SHA256 from the release .dgst file.
  sha="$(curl -fsSL --max-time 20 "${url}.dgst" 2>/dev/null | grep -oE '[0-9a-f]{64}' | head -n1 || true)"

  tmpdir="$(mktemp -d)"
  info "Mengunduh Xray ${tag} (${arch_asset})"
  download_verified "$url" "$tmpdir/xray.zip" "$sha" || { rm -rf "$tmpdir"; return 1; }
  ( cd "$tmpdir" && unzip -oq xray.zip ) || die "Gagal mengekstrak Xray."
  install -m 0755 "$tmpdir/xray" "$XRAY_BIN"
  [[ -f "$tmpdir/geoip.dat" ]] && install -m 0644 "$tmpdir/geoip.dat" "$XRAY_CFG_DIR/geoip.dat"
  [[ -f "$tmpdir/geosite.dat" ]] && install -m 0644 "$tmpdir/geosite.dat" "$XRAY_CFG_DIR/geosite.dat"
  rm -rf "$tmpdir"
  config_set xray_version_installed "$tag"
  ok "Xray terpasang: $("$XRAY_BIN" version 2>/dev/null | head -n1)"
}

_xray_self_signed() {
  local cn="$1"
  mkdir -p "$SVPS_TLS_DIR"; chmod 700 "$SVPS_TLS_DIR"
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$SVPS_KEY" -out "$SVPS_CERT" -subj "/CN=${cn}" >/dev/null 2>&1
  chmod 600 "$SVPS_KEY" "$SVPS_CERT"
}

# Create/renew Let's Encrypt cert via acme.sh + Cloudflare DNS-01
xray_setup_tls() {
  local domain token account email
  domain="$(xray_domain)"; token="$(xray_cf_token)"; account="$(xray_cf_account)"; email="$(xray_acme_email)"

  mkdir -p "$SVPS_TLS_DIR"; chmod 700 "$SVPS_TLS_DIR"

  if [[ -z "$domain" ]]; then
    warn "Domain belum diatur; memakai sertifikat self-signed."
    _xray_self_signed "scriptvps.local"
    return 0
  fi

  if [[ -z "$token" ]]; then
    warn "Cloudflare token belum diatur; memakai self-signed untuk ${domain}."
    _xray_self_signed "$domain"
    return 0
  fi

  info "Menyiapkan DNS Cloudflare untuk ${domain}"
  local ip; ip="$(public_ip || true)"
  if [[ -n "$ip" ]]; then cf_upsert_a "$domain" "$ip" "$token" || warn "Lewati pembuatan record A."; fi

  if [[ ! -x "$HOME/.acme.sh/acme.sh" ]]; then
    info "Memasang acme.sh"
    curl -fsSL https://get.acme.sh | sh -s email="${email:-admin@${domain}}" >/dev/null 2>&1 \
      || die "Gagal memasang acme.sh."
  fi
  local acme="$HOME/.acme.sh/acme.sh"
  export CF_Token="$token"
  [[ -n "$account" ]] && export CF_Account_ID="$account"

  info "Menerbitkan sertifikat Let's Encrypt untuk ${domain}"
  if "$acme" --issue --dns dns_cf -d "$domain" --keylength ec-256 >/dev/null 2>&1; then
    "$acme" --install-cert -d "$domain" --ecc \
      --fullchain-file "$SVPS_CERT" \
      --key-file "$SVPS_KEY" \
      --reloadcmd "systemctl restart xray 2>/dev/null || true" >/dev/null 2>&1
    chmod 600 "$SVPS_KEY" "$SVPS_CERT"
    ok "Sertifikat Let's Encrypt siap untuk ${domain}."
  else
    warn "Penerbitan sertifikat gagal; memakai self-signed."
    _xray_self_signed "$domain"
  fi
}

_xray_write_config() {
  mkdir -p "$XRAY_CFG_DIR"
  local vw mw vg mg tp cert key
  vw="$(xray_port_vless_ws)"; mw="$(xray_port_vmess_ws)"
  vg="$(xray_port_vless_grpc)"; mg="$(xray_port_vmess_grpc)"
  tp="$(xray_port_trojan)"
  cert="$SVPS_CERT"; key="$SVPS_KEY"

cat >"$XRAY_CFG" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "vless-ws", "listen": "0.0.0.0", "port": ${vw}, "protocol": "vless",
      "settings": { "clients": [], "decryption": "none" },
      "streamSettings": {
        "network": "ws", "security": "tls",
        "tlsSettings": { "certificates": [ { "certificateFile": "${cert}", "keyFile": "${key}" } ] },
        "wsSettings": { "path": "/vless" }
      }
    },
    {
      "tag": "vmess-ws", "listen": "0.0.0.0", "port": ${mw}, "protocol": "vmess",
      "settings": { "clients": [] },
      "streamSettings": {
        "network": "ws", "security": "tls",
        "tlsSettings": { "certificates": [ { "certificateFile": "${cert}", "keyFile": "${key}" } ] },
        "wsSettings": { "path": "/vmess" }
      }
    },
    {
      "tag": "vless-grpc", "listen": "0.0.0.0", "port": ${vg}, "protocol": "vless",
      "settings": { "clients": [], "decryption": "none" },
      "streamSettings": {
        "network": "grpc", "security": "tls",
        "tlsSettings": { "certificates": [ { "certificateFile": "${cert}", "keyFile": "${key}" } ] },
        "grpcSettings": { "serviceName": "vless" }
      }
    },
    {
      "tag": "vmess-grpc", "listen": "0.0.0.0", "port": ${mg}, "protocol": "vmess",
      "settings": { "clients": [] },
      "streamSettings": {
        "network": "grpc", "security": "tls",
        "tlsSettings": { "certificates": [ { "certificateFile": "${cert}", "keyFile": "${key}" } ] },
        "grpcSettings": { "serviceName": "vmess" }
      }
    },
    {
      "tag": "trojan-tcp", "listen": "0.0.0.0", "port": ${tp}, "protocol": "trojan",
      "settings": { "clients": [] },
      "streamSettings": {
        "network": "tcp", "security": "tls",
        "tlsSettings": { "certificates": [ { "certificateFile": "${cert}", "keyFile": "${key}" } ] }
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "blocked" }
  ]
}
EOF
  chmod 600 "$XRAY_CFG"
  jq empty "$XRAY_CFG" 2>/dev/null || die "Config Xray tidak valid."
}

_xray_write_service() {
  cat >"$XRAY_SERVICE" <<EOF
[Unit]
Description=Xray Service (scriptvps)
After=network.target nss-lookup.target

[Service]
User=root
ExecStart=${XRAY_BIN} run -config ${XRAY_CFG}
Restart=on-failure
RestartSec=3
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload 2>/dev/null || true
}

xray_install() {
  require_root
  info "Memasang modul Xray"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq curl unzip jq openssl >/dev/null

  mkdir -p "$XRAY_CFG_DIR"
  _xray_download
  xray_setup_tls
  _xray_write_config
  _xray_write_service
  systemctl enable xray >/dev/null 2>&1 || true
  systemctl restart xray 2>/dev/null || warn "Tidak bisa start Xray (mungkin tidak ada systemd)."
  db_init xray
  ok "Modul Xray siap."
}

xray_uninstall() {
  systemctl stop xray 2>/dev/null || true
  systemctl disable xray 2>/dev/null || true
  rm -f "$XRAY_SERVICE" "$XRAY_CFG"
  rm -f "$XRAY_BIN"
  rm -f "$(db_file xray)"
  systemctl daemon-reload 2>/dev/null || true
  ok "Modul Xray dihapus."
}

# xray_add <name> <days> <iplimit> <quota> <meta>
xray_add() {
  require_root
  local name="$1" days="$2" iplimit="${3:-0}" quota="${4:-0}" meta="${5:-}"
  local proto="${XRAY_PROTOCOL:-vless}" transport="${XRAY_TRANSPORT:-}"
  [[ "$name" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] || die "Nama tidak valid."
  db_exists xray "$name" && die "Akun Xray '$name' sudah ada."
  [[ -f "$XRAY_CFG" ]] || die "Xray belum diinstall."

  # resolve & validate protocol/transport
  case "$proto" in
    vless|vmess)
      [[ -z "$transport" ]] && transport="ws"
      case "$transport" in ws|grpc) : ;; *) die "Transport tidak didukung untuk $proto: $transport (ws|grpc)" ;; esac ;;
    trojan)
      [[ -z "$transport" ]] && transport="tcp"
      [[ "$transport" == "tcp" ]] || die "Transport tidak didukung untuk trojan: $transport (tcp)" ;;
    *) die "Protokol tidak didukung: $proto (vless|vmess|trojan)" ;;
  esac

  local id expires
  expires="$(date_add_days "$days")"
  case "$proto" in
    vless|vmess) id="$("$XRAY_BIN" uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)" ;;
    trojan)      id="$(openssl rand -hex 16)" ;;
  esac

  local tmp; tmp="$(mktemp)"
  if [[ "$proto" == "trojan" ]]; then
    jq --arg id "$id" --arg email "$name" \
      '(.inbounds[] | select(.tag=="trojan-tcp") | .settings.clients) += [{"password":$id,"email":$email}]' \
      "$XRAY_CFG" >"$tmp" || die "jq gagal."
  else
    jq --arg id "$id" --arg email "$name" --arg proto "$proto" \
      '(.inbounds[] | select(.protocol==$proto) | .settings.clients) += [{"id":$id,"email":$email} + (if $proto=="vmess" then {"alterId":0} else {} end)]' \
      "$XRAY_CFG" >"$tmp" || die "jq gagal."
  fi
  mv "$tmp" "$XRAY_CFG"
  systemctl restart xray 2>/dev/null || true
  db_add xray "$name" "$expires" "$iplimit" "$quota" "default" "proto=${proto};transport=${transport};id=${id}" || true

  ok "Akun Xray dibuat: $name (${proto}/${transport})"
  plain "  Expires   : $expires"
  plain "  Link      : $(xray_build_link "$name")"
}

# xray_build_link <name>
xray_build_link() {
  local name="$1" meta proto transport id domain
  meta="$(db_field xray "$name" 7)"
  proto="$(printf '%s' "$meta" | tr ';' '\n' | awk -F= '$1=="proto"{print $2}')"
  transport="$(printf '%s' "$meta" | tr ';' '\n' | awk -F= '$1=="transport"{print $2}')"
  id="$(printf '%s' "$meta" | tr ';' '\n' | awk -F= '$1=="id"{print $2}')"
  domain="$(xray_domain)"; [[ -z "$domain" ]] && domain="$(public_ip)"

  case "$proto:$transport" in
    vless:ws)
      printf 'vless://%s@%s:%s?type=ws&security=tls&path=%%2Fvless&host=%s&sni=%s#%s' \
        "$id" "$domain" "$(xray_port_vless_ws)" "$domain" "$domain" "$name" ;;
    vless:grpc)
      printf 'vless://%s@%s:%s?type=grpc&security=tls&serviceName=vless&sni=%s#%s' \
        "$id" "$domain" "$(xray_port_vless_grpc)" "$domain" "$name" ;;
    vmess:ws)
      printf 'vmess://%s' "$(jq -nc --arg ps "$name" --arg add "$domain" --arg port "$(xray_port_vmess_ws)" \
        --arg id "$id" '{v:"2",ps:$ps,add:$add,port:$port,id:$id,aid:"0",net:"ws",type:"none",host:$add,path:"/vmess",tls:"tls"} | @base64')" ;;
    vmess:grpc)
      printf 'vmess://%s' "$(jq -nc --arg ps "$name" --arg add "$domain" --arg port "$(xray_port_vmess_grpc)" \
        --arg id "$id" '{v:"2",ps:$ps,add:$add,port:$port,id:$id,aid:"0",net:"grpc",type:"none",host:$add,path:"vmess",tls:"tls"} | @base64')" ;;
    trojan:*)
      printf 'trojan://%s@%s:%s?security=tls&type=tcp&sni=%s#%s' \
        "$id" "$domain" "$(xray_port_trojan)" "$domain" "$name" ;;
    *) echo "(unknown)" ;;
  esac
}

xray_del() {
  require_root
  local name="$1" tmp
  [[ -f "$XRAY_CFG" ]] || die "Xray belum diinstall."
  tmp="$(mktemp)"
  jq --arg email "$name" '(.inbounds[] | select(.settings.clients) | .settings.clients) |= map(select(.email != $email))' \
    "$XRAY_CFG" >"$tmp" || die "jq gagal."
  mv "$tmp" "$XRAY_CFG"
  systemctl restart xray 2>/dev/null || true
  db_del xray "$name" || true
  ok "Akun Xray '$name' dihapus."
}

xray_renew() {
  local name="$1" days="$2" expires
  db_exists xray "$name" || die "Akun '$name' tidak ada."
  expires="$(date_add_days "$days")"
  db_update_expiry xray "$name" "$expires"
  ok "Akun '$name' diperpanjang sampai $expires."
}

xray_list() {
  local today; today="$(date +%s)"
  printf '%-18s %-10s %-8s %-12s %s\n' NAME PROTO TRANS EXPIRES STATUS
  while IFS=$'\t' read -r name _ expires _ _ _ meta; do
    local proto transport status="active" t=0
    proto="$(printf '%s' "$meta" | tr ';' '\n' | awk -F= '$1=="proto"{print $2}')"
    transport="$(printf '%s' "$meta" | tr ';' '\n' | awk -F= '$1=="transport"{print $2}')"
    [[ -n "$expires" ]] && t="$(date -d "$expires" +%s 2>/dev/null || echo 0)"
    (( t < today )) && status="expired"
    printf '%-18s %-10s %-8s %-12s %s\n' "$name" "${proto:--}" "${transport:--}" "$expires" "$status"
  done < <(db_list xray)
}

xray_status() {
  local n; n="$(db_count xray)"
  if systemctl is-active --quiet xray 2>/dev/null; then
    echo "xray: active (${n} akun)"
  else
    echo "xray: inactive (${n} akun)"
  fi
}

xray_expire_cleanup() {
  local name
  while read -r name; do
    [[ -z "$name" ]] && continue
    warn "Xray '$name' kedaluwarsa - dihapus."
    xray_del "$name" >/dev/null 2>&1 || true
  done < <(db_expired xray)
}
