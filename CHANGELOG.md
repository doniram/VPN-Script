# Changelog

## 0.4.0 - UI, daftar user & pengaturan port
- Terminal UI baru: banner, dashboard, kotak berwarna, tabel rapi (`lib/ui.sh`).
- Menu teks gaya repo pertama: panel per layanan + sistem + ganti port.
- Daftar user kaya: `users`, `online`, `list all` (sisa hari, kuota, status, IP online).
- Deteksi online: SSH (who), WireGuard (handshake), OpenVPN (status log), Shadowsocks (koneksi port).
- Pengaturan port: `scriptvps port show|set` untuk SSH/OpenVPN/WG/Xray/SS/SSTP (+ 13 key).
- Panel web didesain ulang: sidebar, kartu statistik, tabel, modal tambah akun, halaman Port & Sistem.

## 0.3.0 - Fase 3 (panel web)
- Panel web Go (single binary, frontend ter-embed): dashboard, kelola akun per layanan,
  lisensi, kuota, limit-speed, banner.
- Auth bcrypt + session cookie (HttpOnly/SameSite=Strict), proteksi CSRF, rate-limit login.
- Integrasi aman via `/etc/sudoers.d/scriptvps-panel` (non-root, tanpa shell).
- Systemd unit + contoh Nginx/TLS, `install-panel.sh`, `build.sh`.

## 0.2.0 - Fase 2
- Modul Shadowsocks (shadowsocks-libev, satu port per user).
- Modul SSTP (`sstpd`, venv), L2TP/IPsec (xl2tpd + strongswan), PPTP (pptpd).
- Manajemen user PPP via `/etc/ppp/chap-secrets` + NAT otomatis.
- Limit bandwidth (tc/HTB), banner SSH.
- Kuota per-akun (iptables) + auto-disable, terintegrasi `scriptvps check`.

## 0.1.0 - Fase 1
- Fondasi `lib/`, CLI `scriptvps` (`--json`), menu teks.
- Modul SSH, OpenVPN (CA per-server), WireGuard, Xray (VLESS/VMess/Trojan; WS+gRPC).
- TLS acme.sh + Cloudflare DNS-01 (fallback self-signed).
- Lisensi/register IP (manifest hash) dengan grace period, non-destruktif.
- Installer, uninstaller, systemd timer auto-expire, tools lisensi, tests.
