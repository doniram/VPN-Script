# Changelog

## 0.1.0 - Fase 1
- Fondasi: `lib/` (common, net, verify, db, services, license, dns), CLI `scriptvps`.
- Modul: SSH, OpenVPN (CA per-server), WireGuard, Xray (VLESS/VMess/Trojan; WS + gRPC).
- TLS via acme.sh + Cloudflare DNS-01; fallback self-signed.
- Lisensi/register IP berbasis manifest (hash) dengan grace period, non-destruktif.
- Installer `install.sh`, uninstaller, menu teks, systemd timer auto-expire.
- Pengujian: shellcheck + docker smoke (Ubuntu 22.04/24.04).
