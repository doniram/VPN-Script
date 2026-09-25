# scriptvps

Auto-installer & manajer server SSH/VPN untuk **Ubuntu 22.04 / 24.04**, ditulis dengan **Bash modular** plus **panel web Go** (single-binary).

Kode terbuka, tanpa obfuscation, **tanpa kredensial hardcoded**, tanpa telemetri, dan setiap perubahan bisa di-`uninstall`.

---

## Fitur

| Layanan | Modul |
|---|---|
| SSH (user + masa aktif) | ✅ |
| OpenVPN (CA per-server + client `.ovpn`) | ✅ |
| WireGuard (peer + QR) | ✅ |
| Xray — VLESS/VMess/Trojan (WS + gRPC) + TLS | ✅ |
| Shadowsocks (shadowsocks-libev, satu port per user) | ✅ |
| SSTP (`sstpd`) | ✅ |
| L2TP/IPsec (xl2tpd + strongswan) | ✅ |
| PPTP (pptpd; Ubuntu 22.04) | ✅ |

**Operasional:** domain + Let's Encrypt (Cloudflare DNS-01) · lisensi/register IP + grace · limit bandwidth (tc) · banner SSH · kuota per-akun (SSH per-uid, SS per-port) dengan auto-disable · auto-expire harian (systemd timer) · backup lokal.

**Panel web (Go):** dashboard status, kelola akun tiap layanan, lihat link/QR, lisensi, kuota, limit-speed, banner. Diakses via Nginx + TLS.

---

## Persyaratan

- Ubuntu 22.04 / 24.04 (fresh disarankan), akses root
- Domain + Cloudflare API token **opsional** (tanpa itu, TLS self-signed)
- Untuk panel: Docker/Go saat build (opsional, hanya sekali)

## Instalasi inti

```bash
git clone <repo-url> /opt/scriptvps && cd /opt/scriptvps
sudo ./install.sh                 # interaktif
# non-interaktif:
sudo ./install.sh --services "ssh ovpn wg xray ss sstp l2tp" \
     --domain vpn.example.com --cf-token "$CF_TOKEN" --email admin@example.com -y
```

## CLI

```bash
scriptvps menu
scriptvps status [--json]
scriptvps list <service|all> [--json]
scriptvps users [--json]             # daftar akun lengkap: sisa hari, kuota, online, IP
scriptvps online [--json]            # user yang sedang online
scriptvps port show | port set <service> <key> <value>
scriptvps add <service> <name> --days 30 [--iplimit N] [--quota GB]
scriptvps add xray tono --days 30 --protocol vless --transport grpc
scriptvps renew <service> <name> --days 30
scriptvps del <service> <name>
scriptvps check                      # expire + sample/enforce kuota
scriptvps quota report
scriptvps limit-speed 5000 | off | status
scriptvps banner "Selamat datang" | off
scriptvps license status|info|set <KEY>|mode <repo|off>|url <URL>
```

Service: `ssh | ovpn | wg | xray | ss | sstp | l2tp | pptp`

## Kuota

Isi `--quota GB` saat menambah akun. Akuntansi memakai chain iptables `SVPS_Q_OUT/IN`:
SSH dihitung per-uid (`--uid-owner`), Shadowsocks per-port. `scriptvps check` (dijalankan timer harian) mengambil sampel lalu menonaktifkan akun yang melewati kuota.

## Limit bandwidth & banner

```bash
scriptvps limit-speed 5000     # cap 5 Mbit/s (HTB)
scriptvps limit-speed off
scriptvps banner "Akses hanya untuk pengguna terdaftar"
```

## Panel web

```bash
bash panel/build.sh                 # build binary (Docker atau Go lokal)
sudo bash panel/install-panel.sh --user admin --domain panel.example.com
```

- Backend Go, frontend ter-`embed` (tanpa runtime Node/PHP).
- Berjalan sebagai user sistem **non-root** `scriptvps`, memanggil CLI lewat
  `/etc/sudoers.d/scriptvps-panel` (hanya subcommand yang diizinkan, tanpa shell).
- Auth: bcrypt + session cookie `HttpOnly`/`SameSite=Strict`, proteksi CSRF,
  rate-limit login.
- Bind `127.0.0.1:8080`, diproksikan Nginx + TLS (sertifikat dari acme.sh).

Kredensial admin disimpan di `/etc/scriptvps/panel.conf` (chmod 600).

## Lisensi / register IP

```bash
# admin (repo lisensi terpisah):
./tools/license-add.sh --name "Customer A" --expires 2027-01-01 --ips "203.0.113.10"
```

Server memvalidasi terhadap manifest publik (hash, bukan rahasia) dengan **grace
period** (default 7 hari). Non-destruktif: layanan yang berjalan tidak pernah dimatikan.

## Uninstall

```bash
sudo ./uninstall.sh            # hapus layanan, simpan state
sudo ./uninstall.sh --purge    # hapus semua state /etc/scriptvps
```

## Struktur proyek

```
install.sh uninstall.sh scriptvps
lib/        common net verify db services license dns ppp quota
modules/    ssh openvpn wireguard xray shadowsocks sstp l2tp pptp extras
parts/      menu.sh
panel/      main.go auth.go exec.go web/ systemd/ nginx/ sudoers/ install-panel.sh build.sh
systemd/    scriptvps-check.service|.timer
tools/      license-add.sh license-check.sh
tests/      shellcheck.sh docker-smoke.sh
```

## Pengujian

```bash
bash tests/shellcheck.sh
bash tests/docker-smoke.sh ubuntu:22.04
bash tests/docker-smoke.sh ubuntu:24.04
```

## Keamanan

- Tanpa token/secret ter-commit (`.gitignore` menutup `license.key`, `*.pem`, `panel/bin/`, dll).
- Unduhan Xray diverifikasi SHA256 dari rilis resmi.
- Sudoers panel minimal; argumen dibangun sebagai arg-array (tanpa shell).
- Lisensi memakai hash; hanya membaca manifest.

## Lisensi

MIT. Gunakan hanya pada server yang Anda miliki/kelola.
