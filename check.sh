#!/bin/bash
# check.sh — verifikasi evolution-api.service jalan sehat DAN tidak mengganggu
# service kritikal (ssh/AP). Jalankan setelah install, dan sesudah reboot.
set -uo pipefail

PASS=0
FAIL=0
ok()   { echo "  [OK]   $1"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

echo "== 1/5: Status service =="
for UNIT in postgresql evolution-api ssh b860h-ap b860h-ap-dhcp NetworkManager; do
  if systemctl list-unit-files "${UNIT}.service" >/dev/null 2>&1; then
    if systemctl is-active --quiet "$UNIT"; then ok "$UNIT aktif"; else bad "$UNIT TIDAK aktif"; fi
  else
    echo "  [SKIP] $UNIT.service tidak ada di unit ini"
  fi
done

echo
echo "== 2/5: Guardrail cgroup (MemoryMax harus terpasang, bukan 'infinity') =="
EVO_MAX=$(systemctl show evolution-api -p MemoryMax --value 2>/dev/null)
EVO_CUR=$(systemctl show evolution-api -p MemoryCurrent --value 2>/dev/null)
if [ -n "$EVO_MAX" ] && [ "$EVO_MAX" != "infinity" ] && [ "$EVO_MAX" != "0" ]; then
  ok "evolution-api MemoryMax=${EVO_MAX} bytes (pemakaian saat ini: ${EVO_CUR} bytes)"
else
  bad "evolution-api tidak punya MemoryMax cgroup cap — risiko OOM lintas-service terbuka lagi"
fi

echo
echo "== 3/5: Isolasi OOM service kritikal (OOMScoreAdjust harus sangat negatif) =="
for UNIT in ssh b860h-ap b860h-ap-dhcp NetworkManager; do
  systemctl list-unit-files "${UNIT}.service" >/dev/null 2>&1 || continue
  ADJ=$(systemctl show "$UNIT" -p OOMScoreAdjust --value 2>/dev/null)
  if [ -n "$ADJ" ] && [ "$ADJ" -lt -500 ] 2>/dev/null; then
    ok "$UNIT OOMScoreAdjust=${ADJ} (terlindungi)"
  else
    bad "$UNIT OOMScoreAdjust=${ADJ:-default}, belum terlindungi — jalankan ulang bagian 7/7 installer"
  fi
done

echo
echo "== 4/5: RAM keseluruhan board =="
free -m
AVAIL=$(free -m | awk '/^Mem:/{print $7}')
if [ "$AVAIL" -ge 100 ]; then ok "RAM available ${AVAIL}MB (masih ada headroom)"; else bad "RAM available cuma ${AVAIL}MB — mepet"; fi
if systemctl is-active --quiet armbian-zram-config 2>/dev/null; then
  ok "zram aktif (buffer kompresi, bukan swap SD card)"
else
  bad "zram TIDAK aktif — cek lagi, ini harus nyala sebelum stack ini dianggap aman jangka panjang"
fi

echo
echo "== 5/5: Liveness API (loopback, pakai apikey dari .env) =="
if [ -f /opt/evolution-api/.env ]; then
  APIKEY=$(grep -E '^AUTHENTICATION_API_KEY=' /opt/evolution-api/.env | cut -d= -f2-)
  RESP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 -H "apikey: ${APIKEY}" http://127.0.0.1:8080/ 2>/dev/null || echo "000")
  if [ "$RESP" = "200" ]; then
    ok "API merespons di 127.0.0.1:8080 (HTTP $RESP)"
  else
    bad "API tidak merespons normal di 127.0.0.1:8080 (HTTP $RESP) — cek: journalctl -u evolution-api -n 50"
  fi
else
  bad "/opt/evolution-api/.env tidak ditemukan — instalasi belum jalan?"
fi

echo
echo "=== Ringkasan: ${PASS} OK, ${FAIL} FAIL ==="
[ "$FAIL" -eq 0 ]
