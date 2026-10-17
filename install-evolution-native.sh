#!/bin/bash
# install-evolution-native.sh — pasang Evolution API v2.3.7 (WhatsApp gateway) LANGSUNG di host
# (bukan via Docker), dituning khusus untuk B860H (RAM 1GB total).
#
# KENAPA NATIVE, BUKAN DOCKER:
# Docker daemon + containerd sendiri makan ~60-100MB RAM idle di board RAM-kecil begini,
# sebelum satu container pun jalan. Evolution API sendiri menyediakan jalur instalasi native
# resmi (`local_install.sh` di repo upstream, pakai nvm+npm+prisma langsung) — jadi ini BUKAN
# cara tidak didukung, cuma kita ganti nvm→NodeSource (lebih cocok untuk service systemd)
# dan kita jalankan Postgres native juga (bukan container terpisah) untuk hemat satu layer
# overlay-fs + network namespace per container.
#
# KENAPA REDIS DIMATIKAN:
# Evolution API v2 punya built-in fallback: CACHE_LOCAL_ENABLED (node-cache di memory proses
# sendiri) sebagai pengganti CACHE_REDIS_ENABLED. Verified langsung dari .env.example resmi
# tag 2.3.7 — bukan asumsi. Redis sendiri (daemon + container-nya) gampang makan 20-50MB lebih
# yang tidak worth it untuk single-instance WA gateway di board ini.
#
# GUARDRAIL UTAMA (ini intinya, bukan cuma "install lalu doa"):
# 1. Pre-flight RAM check — batal kalau free memory sudah terlalu tipis, BUKAN lanjut dan
#    berharap aman.
# 2. cgroup MemoryMax per service (evolution-api DAN postgres) — kalau salah satu meledak
#    pemakaian RAM-nya, kernel akan OOM-kill proses DI DALAM cgroup itu sendiri dulu, bukan
#    proses sistem lain. Isolasi ini bukan asumsi, itu cara kerja cgroup v2 memory controller.
# 3. OOMScoreAdjust sangat negatif untuk service kritikal (ssh, b860h-ap, b860h-ap-dhcp,
#    NetworkManager) — defense-in-depth KEDUA, untuk skenario OOM system-wide (bukan cuma
#    cgroup-local) yang melebihi guardrail #2.
# Tujuannya satu: kalaupun WA gateway ini crash karena kehabisan RAM, jalur manajemen
# SSH/AP STB TIDAK BOLEH ikut kena. Itu prioritas yang tidak bisa dikompromikan di board ini.
#
# YANG SENGAJA TIDAK DIKERJAKAN SCRIPT INI (baca README.md modul ini untuk alasan lengkap):
# - OmniRoute (AI model router) dan Hermes Agent TIDAK dipasang di unit ini. Diukur dari data
#   publik, OmniRoute sendiri idle ~541MB RAM — lebih besar dari sisa RAM bebas di board ini
#   SEBELUM stack WA gateway ini pun ditambahkan. Lihat README.md untuk rekomendasi lokasi.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Jalankan sebagai root (sudo)."; exit 1; }
[ "$(uname -m)" = "aarch64" ] || { echo "Script ini diverifikasi untuk aarch64 (Amlogic S905X). Arsitektur terdeteksi: $(uname -m) — batal."; exit 1; }

APP_DIR=/opt/evolution-api
APP_USER=evolution
APP_TAG=2.3.7
DB_NAME=evolution_api
DB_USER=evolution
REPO_URL=https://github.com/EvolutionAPI/evolution-api
MIN_FREE_MB=${MIN_FREE_MB:-250}      # ambang aman pre-flight, bisa dioverride: MIN_FREE_MB=200 ./install...
NODE_HEAP_MB=224                      # --max-old-space-size, di bawah MemoryMax unit (384M) biar ada ruang non-heap
NODE_MEMORY_MAX=384M                  # cgroup hard cap proses evolution-api
PG_MEMORY_MAX=180M                    # cgroup hard cap proses postgres

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

echo "== 0/7: Pre-flight check =="
FREE_MB=$(free -m | awk '/^Mem:/{print $7}')   # kolom "available", bukan "free" mentah
echo "RAM available saat ini: ${FREE_MB}MB (ambang aman: ${MIN_FREE_MB}MB)"
if [ "$FREE_MB" -lt "$MIN_FREE_MB" ] && [ "$FORCE" -ne 1 ]; then
  echo "BATAL — RAM available di bawah ambang aman. Opsi:" >&2
  echo "  1. Bebaskan RAM dulu (cek 'systemctl list-units --type=service' untuk kandidat non-esensial)." >&2
  echo "  2. Pastikan zram aktif (lihat langkah 1 di bawah, jalankan ulang script untuk cek)." >&2
  echo "  3. Kalau tetap mau lanjut dengan sadar risikonya: jalankan ulang dengan '--force'." >&2
  exit 1
fi

echo
echo "== 1/7: Verifikasi zram aktif (buffer kompresi, BUKAN swap ke SD card) =="
if systemctl is-active --quiet armbian-zram-config 2>/dev/null; then
  echo "  -> armbian-zram-config aktif."
elif systemctl list-unit-files armbian-zram-config.service >/dev/null 2>&1; then
  echo "  -> armbian-zram-config terpasang tapi tidak aktif, mengaktifkan..."
  systemctl enable --now armbian-zram-config
else
  echo "  !! armbian-zram-config tidak ditemukan. Tanpa zram, saat RAM mepet kernel langsung" >&2
  echo "     OOM-kill (tidak ada buffer kompresi) alih-alih melambat dulu. Guardrail cgroup di" >&2
  echo "     bawah tetap melindungi ssh/AP, tapi WA gateway sendiri akan lebih sering crash." >&2
  [ "$FORCE" -eq 1 ] || { echo "     Jalankan ulang dengan --force kalau tetap mau lanjut." >&2; exit 1; }
fi
free -m

echo
echo "== 2/7: Node.js 20.x LTS (NodeSource, arm64) =="
if command -v node >/dev/null && [[ "$(node -v)" == v20.* ]]; then
  echo "  -> Node $(node -v) sudah terpasang."
else
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y nodejs
fi
node -v
npm -v

echo
echo "== 3/7: PostgreSQL native (bukan container) + tuning RAM minimal =="
if ! command -v psql >/dev/null; then
  apt-get update
  apt-get install -y postgresql
fi
systemctl enable --now postgresql

PG_VERSION=$(ls /etc/postgresql/ 2>/dev/null | sort -V | tail -1)
[ -n "$PG_VERSION" ] || { echo "Tidak ketemu /etc/postgresql/<versi>/ — install Postgres gagal?"; exit 1; }
PG_CONF_DIR="/etc/postgresql/${PG_VERSION}/main"
PG_CONFD="${PG_CONF_DIR}/conf.d"
mkdir -p "$PG_CONFD"
grep -q "^include_dir" "${PG_CONF_DIR}/postgresql.conf" 2>/dev/null || \
  echo "include_dir = 'conf.d'" >> "${PG_CONF_DIR}/postgresql.conf"

cat > "${PG_CONFD}/10-b860h-tuning.conf" <<'EOF'
# Tuning RAM minimal untuk single-tenant WA gateway di board 1GB RAM.
# TIDAK menyentuh fsync/synchronous_commit — keamanan data tetap diutamakan,
# yang dikecilkan cuma alokasi memory statis.
shared_buffers = 32MB
work_mem = 4MB
maintenance_work_mem = 32MB
effective_cache_size = 128MB
max_connections = 20
wal_buffers = 4MB
EOF
systemctl restart postgresql

# Buat role + db kalau belum ada (idempotent)
DB_PASS_FILE="${APP_DIR}/.db_password"
if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" | grep -q 1; then
  mkdir -p "$APP_DIR"
  DB_PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)
  sudo -u postgres psql -c "CREATE ROLE ${DB_USER} LOGIN PASSWORD '${DB_PASS}';"
  sudo -u postgres psql -c "CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};"
  echo "$DB_PASS" > "$DB_PASS_FILE"
  chmod 600 "$DB_PASS_FILE"
  echo "  -> Role & database '${DB_NAME}' dibuat, password tersimpan di ${DB_PASS_FILE} (chmod 600)."
else
  DB_PASS=$(cat "$DB_PASS_FILE" 2>/dev/null || echo "CEK_MANUAL_${DB_PASS_FILE}")
  echo "  -> Role '${DB_USER}' sudah ada, pakai password dari ${DB_PASS_FILE}."
fi

# Guardrail cgroup untuk Postgres (versi-agnostik: cari nama unit instance aktual)
PG_UNIT=$(systemctl list-units --type=service --all 2>/dev/null | grep -o "postgresql@${PG_VERSION}-main\.service" | head -1)
PG_UNIT="${PG_UNIT:-postgresql.service}"
mkdir -p "/etc/systemd/system/${PG_UNIT}.d"
cat > "/etc/systemd/system/${PG_UNIT}.d/10-memory-guardrail.conf" <<EOF
[Service]
MemoryMax=${PG_MEMORY_MAX}
OOMScoreAdjust=300
EOF

echo
echo "== 4/7: User sistem dedicated 'evolution' (no-login) =="
id -u "$APP_USER" >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin "$APP_USER"

echo
echo "== 5/7: Ambil source resmi tag ${APP_TAG} & build =="
if [ ! -d "${APP_DIR}/.git" ]; then
  rm -rf "$APP_DIR"
  GIT_LFS_SKIP_SMUDGE=1 git clone --branch "$APP_TAG" --depth 1 "$REPO_URL" "$APP_DIR"
else
  echo "  -> ${APP_DIR} sudah ada repo git, skip clone (jalankan ulang manual kalau mau update tag)."
fi
cd "$APP_DIR"

AUTH_KEY=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)
cat > "${APP_DIR}/.env" <<EOF
SERVER_NAME=evolution
SERVER_TYPE=http
SERVER_PORT=8080
SERVER_URL=http://127.0.0.1:8080

DATABASE_PROVIDER=postgresql
DATABASE_CONNECTION_URI=postgresql://${DB_USER}:${DB_PASS}@127.0.0.1:5432/${DB_NAME}?schema=evolution_api
DATABASE_CONNECTION_CLIENT_NAME=evolution_exchange
DATABASE_SAVE_DATA_INSTANCE=true
DATABASE_SAVE_DATA_NEW_MESSAGE=true
DATABASE_SAVE_MESSAGE_UPDATE=true
DATABASE_SAVE_DATA_CONTACTS=true
DATABASE_SAVE_DATA_CHATS=true
DATABASE_SAVE_DATA_LABELS=true
DATABASE_SAVE_DATA_HISTORIC=true
DATABASE_SAVE_IS_ON_WHATSAPP=true
DATABASE_SAVE_IS_ON_WHATSAPP_DAYS=7
DATABASE_DELETE_MESSAGE=true

# Redis dimatikan, pakai in-process cache (hemat 1 service + RAM-nya) — lihat README.md
CACHE_REDIS_ENABLED=false
CACHE_LOCAL_ENABLED=true

# Dimatikan sengaja: tidak kirim telemetry keluar dari box management ini
TELEMETRY_ENABLED=false

AUTHENTICATION_API_KEY=${AUTH_KEY}
AUTHENTICATION_EXPOSE_IN_FETCH_INSTANCES=true
LANGUAGE=en
EOF
chmod 600 "${APP_DIR}/.env"

# TIDAK perlu export manual DATABASE_URL/DATABASE_PROVIDER — Prisma CLI dan runWithProvider.js
# (lihat package.json) sama-sama otomatis baca file .env di cwd ini lewat dotenv. Variabel yang
# benar-benar dipakai datasource Prisma adalah DATABASE_CONNECTION_URI (dicek langsung dari
# prisma/postgresql-schema.prisma resmi tag 2.3.7), sudah ada di .env yang baru kita tulis.
npm ci --silent
npm run db:generate
npm run db:deploy
# Build (tsc --noEmit && tsup) adalah proses SEKALI PAKAI saat install, beban RAM-nya lepas
# begitu selesai — beri heap lebih lega khusus untuk langkah ini saja (tidak memengaruhi cap
# runtime di systemd unit, yang tetap ${NODE_HEAP_MB}MB). Kalau board tetap OOM di langkah ini
# (lihat README.md bagian "yang belum diverifikasi"), build-kan di mesin lain dengan arsitektur
# sama (aarch64) lalu salin folder dist/ + node_modules/ ke board ini.
NODE_OPTIONS=--max-old-space-size=512 npm run build

chown -R "${APP_USER}:${APP_USER}" "$APP_DIR"

echo
echo "== 6/7: systemd unit evolution-api.service (dengan guardrail cgroup) =="
cat > /etc/systemd/system/evolution-api.service <<EOF
[Unit]
Description=Evolution API (WhatsApp gateway) - tuned untuk B860H 1GB RAM
After=network.target postgresql.service
Requires=postgresql.service

[Service]
Type=simple
User=${APP_USER}
WorkingDirectory=${APP_DIR}
EnvironmentFile=${APP_DIR}/.env
Environment=NODE_OPTIONS=--max-old-space-size=${NODE_HEAP_MB}
ExecStart=/usr/bin/node ${APP_DIR}/dist/main.js
Restart=on-failure
RestartSec=10
StartLimitIntervalSec=300
StartLimitBurst=5

# --- Guardrail inti: hard cap cgroup, isolasi dari service lain ---
MemoryMax=${NODE_MEMORY_MAX}
MemoryHigh=320M
OOMScoreAdjust=500

# Hardening tambahan (tidak butuh akses selain port 8080 + DB + filesystem sendiri)
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=${APP_DIR}

[Install]
WantedBy=multi-user.target
EOF

echo
echo "== 7/7: Proteksi OOM untuk service kritikal (ssh, AP, dnsmasq, NetworkManager) =="
for UNIT in ssh b860h-ap b860h-ap-dhcp NetworkManager; do
  if systemctl list-unit-files "${UNIT}.service" >/dev/null 2>&1; then
    mkdir -p "/etc/systemd/system/${UNIT}.service.d"
    cat > "/etc/systemd/system/${UNIT}.service.d/10-oom-protect.conf" <<'EOF'
[Service]
OOMScoreAdjust=-900
EOF
    echo "  -> ${UNIT}: OOMScoreAdjust=-900 (sangat dilindungi dari OOM killer global)."
  else
    echo "  -> ${UNIT}.service tidak ditemukan di unit ini, skip (cek nama unit AP Anda kalau beda)."
  fi
done

systemctl daemon-reload
systemctl enable --now evolution-api.service

echo
echo "=== SELESAI ==="
echo "API key (simpan baik-baik, dipakai di header 'apikey'): ${AUTH_KEY}"
echo "Juga tersimpan di: ${APP_DIR}/.env (chmod 600, root-only)"
echo
echo "Jalankan ./check.sh untuk verifikasi lengkap (service, cgroup memory, isolasi OOM)."
