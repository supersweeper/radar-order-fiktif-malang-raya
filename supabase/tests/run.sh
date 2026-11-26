#!/usr/bin/env bash
# Menjalankan seluruh pengujian database pada klaster PostgreSQL SEMENTARA (bukan Supabase asli).
# Langkah: stub -> migrasi (dua kali, uji idempoten) -> tes *.test.sql -> guard skema lama -> uji konkurensi audit.
# Butuh binary PostgreSQL 14+ (initdb, pg_ctl, psql, pgbench). Tidak menyentuh database lain.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIG="$HERE/../migrations"
PGBIN="${PGBIN:-$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1)}"
PORT="${PGPORT_TEST:-54329}"
DIR="$(mktemp -d /var/tmp/rof_pg.XXXXXX)"
PSQL=("$PGBIN/psql" -h "$DIR" -p "$PORT" -U postgres -X -q -v ON_ERROR_STOP=1)

as_pg() { if [ "$(id -u)" = 0 ]; then su postgres -c "$*"; else bash -c "$*"; fi; }

cleanup() {
  as_pg "$PGBIN/pg_ctl -D $DIR/data -m immediate stop" >/dev/null 2>&1 || true
  rm -rf "$DIR"
}
trap cleanup EXIT

chmod 755 "$DIR"; [ "$(id -u)" = 0 ] && chown postgres "$DIR"
as_pg "$PGBIN/initdb -D $DIR/data -U postgres -A trust >/dev/null"
as_pg "$PGBIN/pg_ctl -D $DIR/data -o '-p $PORT -k $DIR -c listen_addresses=' -l $DIR/log -w start >/dev/null"

newdb() {
  "$PGBIN/createdb" -h "$DIR" -p "$PORT" -U postgres "$1"
  "${PSQL[@]}" -d "$1" -f "$HERE/00_stubs.sql" -f "$HERE/01_helpers.sql"
}
apply_migrations() { for f in "$MIG"/*.sql; do PGOPTIONS="-c client_min_messages=warning" "${PSQL[@]}" -d "$1" -1 -f "$f"; done; }

echo "== 1. Migrasi pada DB kosong (putaran 1)"
newdb rof_test
apply_migrations rof_test
echo "== 2. Migrasi diulang (idempoten, putaran 2)"
apply_migrations rof_test

echo "== 3. Tes"
for t in "$HERE"/[1-9]*.test.sql; do
  echo "-- $(basename "$t")"
  set +e
  "${PSQL[@]}" -d rof_test -f "$t" >"$DIR/out.txt" 2>&1
  rc=$?
  set -e
  grep -E 'PASS|FAIL|RINGKASAN|ERROR' "$DIR/out.txt" || true
  [ "$rc" = 0 ] || { echo "!! $(basename "$t") GAGAL (kode $rc)"; exit 1; }
done

echo "== 4. Guard: skema lama terdeteksi, migrasi harus berhenti tanpa merusak data"
newdb rof_guard
"${PSQL[@]}" -d rof_guard -c "create table public.reports(id uuid primary key, story text); insert into public.reports values (gen_random_uuid(),'data lama');"
"${PSQL[@]}" -d rof_guard -1 -f "$MIG/0001_enums.sql"
if "${PSQL[@]}" -d rof_guard -1 -f "$MIG/0002_foundation.sql" 2>"$DIR/guard.err"; then
  echo "!! migrasi TIDAK berhenti pada skema lama"; exit 1
fi
grep -q "Migrasi dihentikan" "$DIR/guard.err" || { echo "!! pesan guard tidak ditemukan"; cat "$DIR/guard.err"; exit 1; }
[ "$("${PSQL[@]}" -d rof_guard -Atc "select count(*) from public.reports")" = 1 ] || { echo "!! data lama berubah"; exit 1; }
[ "$("${PSQL[@]}" -d rof_guard -Atc "select to_regclass('public.profiles') is null")" = t ] || { echo "!! migrasi parsial tertinggal"; exit 1; }
echo "PASS  guard skema lama: migrasi berhenti, data lama utuh, tidak ada sisa parsial"

echo "== 4b. Backfill: akun yang sudah ada sebelum migrasi mendapat profil"
newdb rof_backfill
"${PSQL[@]}" -d rof_backfill -c "insert into auth.users(id,email) values ('00000000-0000-0000-0000-0000000000f1','lama@example.test');"
apply_migrations rof_backfill
[ "$("${PSQL[@]}" -d rof_backfill -Atc "select count(*) from public.profiles where id='00000000-0000-0000-0000-0000000000f1'")" = 1 ] || { echo "!! backfill profil gagal"; exit 1; }
echo "PASS  backfill profil untuk akun lama"

echo "== 5. Konkurensi audit: 8 klien x 60 transaksi, lalu rantai harus utuh"
cat > "$DIR/audit.pgb" <<'SQL'
select private.write_audit('bench.event', 'bench', '1', null, null, null);
SQL
"$PGBIN/pgbench" -h "$DIR" -p "$PORT" -U postgres -n -c 8 -j 4 -t 60 -f "$DIR/audit.pgb" rof_test >/dev/null
RES="$("${PSQL[@]}" -d rof_test -Atc "select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-0000000000a5',false) is not null; select ok||'/'||checked from (select * from public.verify_audit_chain()) v" 2>&1 | tail -1)"
echo "verify_audit_chain (sebagai admin uji): $RES"
case "$RES" in true/*) echo "PASS  rantai audit utuh setelah penulisan konkuren";; *) echo "!! rantai audit rusak/tidak terbaca"; exit 1;; esac

echo "== SELESAI: semua tahap lulus"
