# scriptvps

Auto-installer & manajer server SSH/VPN untuk **Ubuntu 22.04 / 24.04**, ditulis dengan **Bash modular** dan dilengkapi **panel web Go** (fase berikutnya).

Tool ini dibuat bersih: **kode terbuka, tanpa obfuscation, tanpa kredensial hardcoded, tanpa telemetri**, dan setiap perubahan bisa di-`uninstall`.

---

## Fitur

| Layanan | Status |
|---|---|
| SSH (user + masa aktif) | ✅ Fase 1 |
| OpenVPN (CA per-server + client `.ovpn`) | ✅ Fase 1 |
| WireGuard (peer + QR) | ✅ Fase 1 |
| Xray — VLESS/VMess/Trojan (WS + gRPC) + TLS | ✅ Fase 1 |
| Domain + Let's Encrypt (Cloudflare DNS-01) | ✅ Fase 1 |
| Lisensi / register IP + grace period | ✅ Fase 1 |
| Shadowsocks / SSR | 🚧 Fase 2 |
| SSTP / L2TP / PPTP | 🚧 Fase 2 |
| Limit bandwidth / kuota per-user | 🚧 Fase 2 |
| Panel web (Go, subdomain + TLS) | 🚧 Fase 3 |

---

## Persyaratan

- Ubuntu 22.04 atau 24.04 (fresh install disarankan)
- Akses root
- Domain + Cloudflare API token **opsional** (tanpa itu, Xray memakai self-signed)

## Instalasi

```bash
git clone <repo-url> /opt/scriptvps
cd /opt/scriptvps
sudo ./install.sh
```

Atau non-interaktif:

```bash
sudo ./install.sh --profile minimal \
  --domain vpn.example.com \
  --cf-token "$CF_TOKEN" --email admin@example.com \
  -y
```

Installer menyalin proyek ke `/opt/scriptvps`, memasang layanan, membuat symlink `scriptvps`, dan mengaktifkan timer harian untuk auto-expire.

## Penggunaan CLI

```bash
scriptvps menu                                  # menu teks interaktif
scriptvps status [--json]                       # ringkasan server & layanan
scriptvps list xray [--json]                    # daftar akun
scriptvps add ssh budi --days 30 --iplimit 2    # tambah akun
scriptvps add xray tono --days 30 --protocol vless --transport ws
scriptvps renew wg tono --days 30
scriptvps del ovpn tono
scriptvps check                                 # bersihkan akun kedaluwarsa
scriptvps license status|info|set <KEY>|mode off|repo|url <URL>
```

Semua perintah `list`/`status` mendukung `--json` untuk dikonsumsi panel web.

## TLS + Cloudflare

Saat instalasi, isi:

- **Domain** (mis. `vpn.example.com`)
- **Cloudflare API token** dengan izin `Zone.DNS Edit`
- **Email** untuk Let's Encrypt

Installer akan membuat/memperbarui record `A` via Cloudflare API, lalu menerbitkan sertifikat Let's Encrypt dengan `acme.sh` (DNS-01). Tanpa domain/token, Xray memakai sertifikat self-signed.

## Lisensi / register IP

Mode `repo` (opsional) memvalidasi server terhadap manifest publik:

1. Admin membuat kunci + baris manifest:

   ```bash
   ./tools/license-add.sh --name "Customer A" --expires 2027-01-01 \
     --ips "203.0.113.10" --file licenses.tsv
   ```

   Kunci asli diberikan ke pelanggan; manifest hanya menyimpan **hash**.

2. Manifest di-commit ke repo GitHub (mis. `scriptvps-license/licenses.tsv`).
3. Di server pelanggan:

   ```bash
   scriptvps license set SVPS-XXXX-XXXX-XXXX
   # atau saat install: --license-mode repo --license-url <raw-url> --license-key <key>
   ```

Ada **grace period** (default 7 hari) sebelum operasi tulis diblokir. Gate ini **non-destruktif**: layanan yang sudah berjalan tidak pernah dimatikan, dan tidak ada file yang dihapus.

Verifikasi manual:

```bash
./tools/license-check.sh --key SVPS-... --url <raw-url> --ip 203.0.113.10
```

## Uninstall

```bash
sudo ./uninstall.sh           # hapus layanan, simpan state
sudo ./uninstall.sh --purge   # hapus layanan + /etc/scriptvps
```

## Struktur proyek

```
install.sh uninstall.sh scriptvps
lib/        common net verify db services license dns
modules/    ssh openvpn wireguard xray
parts/      menu.sh
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

- Tidak ada token/secret yang ditanam di repo (`.gitignore` menutup `license.key`, `secrets/`, dll.).
- Unduhan Xray diverifikasi lewat SHA256 dari release resmi.
- Cloudflare token disimpan `chmod 600` di `/etc/scriptvps/config.conf`.
- Lisensi memakai hash, bukan rahasia, dan hanya membaca manifest publik.
- Tidak ada pengiriman data pengguna ke pihak ketiga.

## Lisensi

MIT (akan ditambahkan). Gunakan hanya pada server yang Anda miliki/kelola.
