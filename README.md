# B860H WhatsApp Gateway (Evolution API, native, tuned untuk 1GB RAM)

Installer WhatsApp gateway (Evolution API) khusus untuk STB **ZTE B860H v1 (Amlogic S905X,
RAM 1GB)** yang sudah di-hardening lewat
[`b860h-stb-hardening-kit`](https://github.com/Ogydump-mile/b860h-stb-hardening-kit) — repo
itu prasyarat, bukan bagian dari repo ini. Pisah sengaja: hardening kit tetap fokus murni ke
Wi-Fi internal + AP manajemen offline + footprint sistem; repo ini khusus WhatsApp gateway,
supaya dua hal ini bisa berubah/di-versioning independen satu sama lain.

Ini jawaban atas tantangan "bisa gak WA gateway jalan di STB RAM 1GB": **bisa, dan ini cara
kerjanya** — dengan catatan jujur soal apa yang masuk ke sini dan apa yang sengaja tidak.

## Prasyarat

- STB sudah menjalani `01-wifi-driver-dtb` + `02-ap-setup` + `03-hardening` dari
  [`b860h-stb-hardening-kit`](https://github.com/Ogydump-mile/b860h-stb-hardening-kit)
  (khususnya zram harus aktif — dicek ulang di installer ini, tapi asalnya dari sana).
- Akses root (SSH) ke STB, koneksi internet sementara (npm install + apt).

## Ringkasan keputusan

| Pertanyaan | Keputusan | Alasan |
|---|---|---|
| Docker atau native? | **Native** (bukan container) | Docker daemon+containerd sendiri ~60-100MB RAM idle sebelum satu container pun jalan. Upstream Evolution API punya jalur native resmi (`local_install.sh`) — bukan hack. |
| Redis? | **Dimatikan**, pakai `CACHE_LOCAL_ENABLED=true` | Fallback in-process ini resmi ada di kode (`src/cache/` punya Redis + Node-cache). Verified langsung dari `.env.example` tag `2.3.7`, bukan tebakan. |
| Database? | Postgres **native**, tuning RAM minimal | Prisma schema Evolution API cuma punya `postgresql-schema.prisma` dan `mysql-schema.prisma` — tidak ada opsi SQLite. Postgres tidak bisa dihindari, tapi bisa ditekan ke ~32MB `shared_buffers`. |
| OmniRoute & Hermes Agent? | **Tidak di unit ini** | Lihat bagian di bawah — ini bukan soal males, ini aritmatika RAM. |

## Kenapa OmniRoute dan Hermes Agent tidak ikut dipasang di sini

Diukur dari data publik yang bisa diverifikasi (bukan asumsi):

| Komponen | Stack | RAM idle terukur/diperkirakan |
|---|---|---|
| **OmniRoute** (`diegosouzapw/omniroute`) | Node.js + Next.js 16 + SQLite | **~541MB** idle, diukur langsung oleh reviewer pihak ketiga ([pinggy.io](https://pinggy.io/blog/omniroute_ai_gateway_security/)) |
| **Hermes Agent** (`nousresearch/hermes-agent`) | Docker Compose + Traefik (reverse proxy publik + Let's Encrypt) | Tidak ada angka minimum resmi, tapi arsitekturnya **mengasumsikan domain publik + port 80/443 terbuka ke internet** ([docs.vultr.com](https://docs.vultr.com/how-to-deploy-hermes-agent-open-source-self-hosted-ai-agent)) |
| **Evolution API** (modul ini) | Native Node + Postgres tuned | Target realistis ~150-250MB idle single-instance (lihat perhitungan di bawah) |

Board ini **total 1GB RAM**, dan dari audit
[`03-hardening/README.md`](https://github.com/Ogydump-mile/b860h-stb-hardening-kit/blob/main/03-hardening/README.md)
di repo hardening kit, baseline OS (SSH, AP hostapd/dnsmasq, NetworkManager, journald, dll —
bahkan setelah di-trim) sudah memakai ~784MB, menyisakan kira-kira 200-300MB bebas.
**OmniRoute sendirian (541MB) sudah lebih besar dari total RAM bebas itu** — sebelum WhatsApp
gateway atau Hermes ditambahkan sama sekali. Ini bukan masalah tuning, ini kapasitas fisik
yang tidak ada.

Hermes Agent punya masalah berbeda, bukan cuma RAM: desainnya **menaruh reverse proxy publik
dengan TLS otomatis** di depan agent-nya. STB ini dirancang sebagai AP manajemen **offline/
internal-only** (lihat README [`b860h-stb-hardening-kit`](https://github.com/Ogydump-mile/b860h-stb-hardening-kit) —
`wlandrct` terpisah total dari jalur internet).
Memasang ingress publik di box yang sama berarti mengubah total model ancamannya — itu
keputusan arsitektur network tersendiri, bukan sesuatu yang harus (atau sebaiknya) disisipkan
diam-diam lewat instalasi WA gateway.

**Rekomendasi:** jalankan OmniRoute dan Hermes Agent di host terpisah (VPS kecil 2GB+ pun
cukup untuk keduanya). STB ini bisa tetap jadi *client* yang memanggil OmniRoute/Hermes lewat
API dari jaringan manajemennya — itu cuma trafik keluar biasa, tidak butuh resource lokal
berarti di STB.

## Perhitungan RAM Evolution API di board ini

| Item | Estimasi RAM | Catatan |
|---|---|---|
| Node.js app (single WA instance, Baileys) | ~120-200MB | Naik kalau banyak instance/trafik tinggi — modul ini diasumsikan **1 instance** |
| Postgres (tuned: `shared_buffers=32MB`) | ~40-70MB | Jauh di bawah default `max_connections=1000` di `docker-compose.yaml` resmi (kita override ke 20) |
| Redis | **0MB** (dimatikan) | Fallback `CACHE_LOCAL_ENABLED` |
| **Total idle realistis** | **~160-270MB** | |
| **Hard cap cgroup (worst case)** | 384MB (app) + 180MB (postgres) = 564MB | Ini BUKAN target normal — ini jaring pengaman kalau ada bug/lonjakan |

Idle realistis (~200MB) kemungkinan **pas** di sisa RAM bebas (~200-300MB). Ini tetap tipis,
bukan lega — makanya guardrail di bawah bukan opsional.

## Guardrail — ini bagian yang sebenarnya menjawab tantangannya

Tuning RAM saja tidak menjamin apa-apa kalau ada lonjakan (banyak chat masuk sekaligus, memory
leak, dll). Yang membuat ini aman untuk dipasang di box yang sama dengan jalur SSH/AP kritikal
adalah **isolasi kegagalan**, bukan janji "tidak akan pernah penuh":

1. **Pre-flight check** (`install-evolution-native.sh`) — instalasi **menolak jalan** kalau RAM
   available sudah di bawah ambang aman (default 250MB), bukan lanjut dan berharap aman.
2. **cgroup `MemoryMax` per service** — `evolution-api.service` dan `postgresql` masing-masing
   punya hard cap. Kalau salah satu melebihi cap-nya, kernel OOM-kill proses **di dalam cgroup
   itu sendiri**, bukan proses lain di sistem. Ini mekanisme cgroup v2, bukan harapan.
3. **`OOMScoreAdjust=-900` untuk `ssh`, `b860h-ap`, `b860h-ap-dhcp`, `NetworkManager`** —
   defense-in-depth kedua untuk skenario OOM system-wide yang menembus guardrail #2.
4. **zram wajib aktif** — dicek tiap instalasi. Ini compressed RAM swap (bukan swap ke SD
   card seperti yang pernah diselidiki di
   [`03-hardening/README.md`](https://github.com/Ogydump-mile/b860h-stb-hardening-kit/blob/main/03-hardening/README.md)
   di repo hardening kit), jadi ada ruang "melambat dulu" sebelum harus OOM-kill.

Konsekuensinya jujur: kalau WA gateway ini kena lonjakan parah, **dia yang crash dan restart
sendiri** (`Restart=on-failure` di systemd unit) — bukan SSH/AP yang ikut turun. Itu prioritas
yang benar untuk box yang fungsi utamanya jalur akses darurat.

## Pakai

```bash
git clone https://github.com/Ogydump-mile/b860h-whatsapp-gateway.git
scp -r b860h-whatsapp-gateway root@<ip-stb>:/root/
ssh root@<ip-stb>
cd /root/b860h-whatsapp-gateway
sudo ./install-evolution-native.sh
sudo ./check.sh
```

Kalau pre-flight RAM check menolak (`BATAL — RAM available di bawah ambang aman`), **jangan**
langsung pakai `--force` — cek dulu kenapa RAM sudah mepet sebelum menambah beban baru
(`free -m`, `systemctl list-units --type=service` cari kandidat yang bisa dimatikan).

API key dicetak di akhir instalasi dan tersimpan di `/opt/evolution-api/.env` (root-only,
`chmod 600`). Dipakai di header `apikey` untuk semua request ke API.

## Yang belum diverifikasi di hardware asli

Saya tidak punya akses SSH langsung ke STB ini dari sesi ini — jadi angka RAM idle Evolution
API di atas adalah **estimasi berdasarkan arsitektur stack**, bukan hasil pengukuran langsung
di board ini. Setelah jalan beberapa hari, cek realita sebenarnya:

```bash
systemctl show evolution-api -p MemoryCurrent --value   # bandingkan dengan estimasi 120-200MB
journalctl -u evolution-api --since "7 days ago" | grep -i "oom\|killed\|restart" # cek seberapa sering guardrail kepakai
```

Kalau `MemoryCurrent` konsisten jauh dari estimasi, atau unit sering restart karena hit
`MemoryMax`, itu sinyal nyata untuk menurunkan jumlah instance WA atau mempertimbangkan
pindah ke host lain — bukan menaikkan `MemoryMax` begitu saja (itu cuma memindah risiko ke
RAM board, bukan menghilangkannya).

**Update, terverifikasi langsung di hardware: langkah build saat instalasi memang OOM di
percobaan pertama.** Bukan `tsc` (typecheck lolos tanpa masalah), tapi `esbuild` yang
dipanggil `tsup` — kernel log mengonfirmasi `esbuild` kena OOM-kill dengan RSS **~470MB**
sendirian, di board 784MB RAM. `NODE_OPTIONS=--max-old-space-size` yang dipasang sebelumnya
ternyata tidak melindungi langkah ini: esbuild adalah binary Go, proses terpisah di luar V8
heap Node, jadi flag itu cuma membatasi proses `tsc`/`tsup` sendiri, bukan `esbuild`.

Mitigasi sekarang sudah masuk ke `install-evolution-native.sh` (bagian `5/7`) secara otomatis:
Postgres dimatikan sejenak selama build (build sama sekali tidak menyentuh DB), dan sebuah
swapfile **sementara** (1.5GB, di `/var/tmp`, dihapus lagi lewat `trap` begitu build selesai
atau gagal) dipasang khusus untuk langkah ini saja — kalau ruang disk tidak cukup, script
lanjut tanpa swapfile dan cuma mencetak peringatan. Ini satu-satunya titik di seluruh proyek
yang menyentuh swap disk; di luar langkah build, zram tetap satu-satunya swap yang aktif,
sesuai alasan di [`b860h-stb-hardening-kit`](https://github.com/Ogydump-mile/b860h-stb-hardening-kit)
untuk menghindari swap disk permanen (wear pada eMMC/SD).

Kalau board tetap OOM di langkah ini walau swapfile sudah aktif (board dengan RAM lebih kecil
dari 784MB, atau tidak ada ruang disk cukup untuk swapfile): build di mesin lain berarsitektur
sama (aarch64) — misalnya Raspberry Pi atau VM aarch64 mana saja dengan RAM lebih besar — lalu
`rsync` folder `dist/` dan `node_modules/` hasilnya ke `/opt/evolution-api/` di STB. Runtime
(`node dist/main.js`) jauh lebih ringan daripada proses build-nya.

## Keamanan jaringan (relevan untuk profil FortiGate Anda)

`SERVER_URL` diset ke `http://127.0.0.1:8080` — API hanya dengar di loopback secara desain
aplikasi. Kalau perlu diakses dari subnet `wlandrct` (bukan cuma dari STB sendiri), jangan
expose ke `0.0.0.0` tanpa firewall rule. Contoh pembatasan dengan `nftables` (sesuaikan subnet
AP Anda, cek dengan `ip addr show wlandrct`):

```bash
nft add rule inet filter input iifname "wlandrct" tcp dport 8080 accept
nft add rule inet filter input iifname "wlan0" tcp dport 8080 drop   # blok dari jalur internet dongle
```

Ini contoh minimal — integrasikan ke firewall policy yang sudah Anda kelola, jangan dianggap
pengganti review firewall penuh.
