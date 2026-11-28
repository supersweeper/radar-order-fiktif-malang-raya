# Panduan Deploy

## Hosting saat ini
Situs statis (GitHub Pages, ada `.nojekyll`). Tidak ada build step.

1. Repo → Settings → Pages → Deploy from branch → `main` / root.
2. Buka `https://<user>.github.io/radar-order-fiktif-malang-raya/`.

## Konfigurasi
Edit `config.js` (publik):

```js
window.APP_CONFIG = { SUPABASE_URL: "https://xxxx.supabase.co", SUPABASE_ANON_KEY: "<anon/publishable key>" };
```

- Hanya URL dan **anon/publishable key**. Keduanya memang publik; keamanan data dijaga RLS.
- **Jangan** memasukkan `service_role` key ke `config.js`, `index.html`, atau repo. Kunci itu hanya untuk Supabase Edge Function.
- `.env.example` mendokumentasikan nama variabel untuk migrasi ke build step di masa depan.

## Database (Supabase)
Jalankan file di `supabase/migrations/` **berurutan** lewat SQL Editor atau `supabase db push`.
`supabase_schema.sql` lama sudah *deprecated*; jangan dijalankan untuk proyek baru.

Status: `0001` (enum), `0002` (profil, peran, audit log), `0003` (laporan, riwayat, transisi status), `0004` (bukti, versi bukti, bucket privat `evidence`; butuh Storage aktif), `0005` (pemeriksaan verifier, duplikasi, penarikan, keberatan, konflik kepentingan), `0006` (forum keputusan, peserta, suara), `0007` (sanksi, banding, blacklist privat, pembatasan akun), `0008` (view publik `public_reports`, pengerasan hak, indeks). Uji asap di Supabase asli: `docs/UJI_ASAP_SUPABASE.md`. Laporan akhir: `docs/LAPORAN_AKHIR_FASE_1.md` (lihat `docs/RANCANGAN_DB_FASE_1.md`).

**Pepper blacklist (WAJIB sebelum blokir permanen dipakai).** Fingerprint email di `blacklist_entries` dibuat dengan HMAC-SHA256 memakai rahasia `blacklist_pepper` dari Supabase Vault. Aktifkan Vault, lalu buat rahasia acak panjang (min. 16 karakter) di SQL Editor, **jangan** menyimpannya di repo: `select vault.create_secret('<string-acak-panjang>', 'blacklist_pepper');`. Tanpa pepper, `approve_permanent_ban` gagal tertutup (tidak ada yang berubah). Mengganti pepper membuat fingerprint lama tidak cocok lagi; catat dan simpan pepper dengan aman.

**Jika proyek Anda pernah menjalankan `supabase_schema.sql` lama:** `0002` akan berhenti dengan pesan jelas bila menemukan tabel `public.reports` lama, tanpa mengubah data apa pun. Ekspor datanya lalu ganti nama tabel lama sebelum melanjutkan.

**Admin Utama pertama:** daftarkan akun biasa, verifikasi emailnya, lalu jalankan `supabase/bootstrap_admin.example.sql` (dengan UUID akun itu) sekali di SQL Editor. Penunjukan peran berikutnya lewat `public.admin_set_role()`.

**Rahasia:** `service_role` key tidak boleh ada di repo atau frontend. Rantai hash audit (`public.verify_audit_chain()`) hanya *mendeteksi* perubahan; simpan `head_hash`-nya secara berkala di tempat di luar database.

### Menjalankan pengujian database (lokal)
```bash
bash supabase/tests/run.sh
```
Membuat klaster PostgreSQL sementara (butuh `initdb`, `pg_ctl`, `psql`, `pgbench`), memasang stub Supabase, menjalankan migrasi dua kali, semua tes, uji guard skema lama, dan uji konkurensi audit. **Tidak menyentuh project Supabase Anda.** Pengujian ini tidak menggantikan uji asap di Supabase asli (Auth, Storage, PostgREST).

## Status saat ini (Fase 0)
Frontend belum terhubung ke Supabase. Mode lokal (LocalStorage) dan Google Apps Script masih berjalan, dengan perubahan:
- Hanya laporan berstatus **Terverifikasi** yang tampil di feed, statistik, dan peta.
- Laporan tanpa GPS/pin tidak muncul di peta (koordinat tidak lagi diacak).
- Tombol "Valid (+1)" anonim dihapus.
- Baris Google Sheets tanpa kolom `Status` kini dianggap *belum terverifikasi*. **Isi kolom `Status` = `Terverifikasi` pada baris yang sudah Anda periksa**, atau laporan lama tidak akan tampil.

## Kapan Google Apps Script boleh dimatikan
Setelah: (1) data Sheets termigrasi ke Supabase dan divalidasi, (2) pelaporan dan bukti berjalan di Supabase (Fase 2-3), (3) tidak ada klien yang masih memakai `gasUrl`.
