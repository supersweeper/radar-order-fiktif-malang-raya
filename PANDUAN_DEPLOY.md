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

## Status saat ini (Fase 0)
Frontend belum terhubung ke Supabase. Mode lokal (LocalStorage) dan Google Apps Script masih berjalan, dengan perubahan:
- Hanya laporan berstatus **Terverifikasi** yang tampil di feed, statistik, dan peta.
- Laporan tanpa GPS/pin tidak muncul di peta (koordinat tidak lagi diacak).
- Tombol "Valid (+1)" anonim dihapus.
- Baris Google Sheets tanpa kolom `Status` kini dianggap *belum terverifikasi*. **Isi kolom `Status` = `Terverifikasi` pada baris yang sudah Anda periksa**, atau laporan lama tidak akan tampil.

## Kapan Google Apps Script boleh dimatikan
Setelah: (1) data Sheets termigrasi ke Supabase dan divalidasi, (2) pelaporan dan bukti berjalan di Supabase (Fase 2-3), (3) tidak ada klien yang masih memakai `gasUrl`.
