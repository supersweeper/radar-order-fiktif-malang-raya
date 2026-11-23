# Radar Order Fiktif Malang Raya

Paket awal website komunitas untuk Kota Malang, Kabupaten Malang, dan Kota Batu.

## Isi paket
- `index.html`: tampilan responsif yang bisa dibuka di HP/desktop.
- `supabase_schema.sql`: rancangan database bersama untuk laporan lintas perangkat.
- `PANDUAN_DEPLOY.md`: langkah publikasi dan konfigurasi.
- `config.js` / `.env.example`: konfigurasi publik (tanpa secret).
- `supabase/migrations/`: migrasi database bertahap sesuai SRS.
- `docs/ANALISIS_GAP_SRS_v0.1.md`: gap analysis dan rencana implementasi SRS.

## Catatan penting
Versi `index.html` saat ini berjalan dalam **mode demo lokal**: laporan disimpan di browser/perangkat yang mengirimkannya. Laporan belum otomatis terlihat oleh driver lain. Agar semua driver dapat melihat dan mengirim laporan yang sama, buat project Supabase, jalankan SQL, lalu hubungkan aplikasi dengan kredensial publik Supabase. Jangan pernah memasukkan `service_role` key ke website.

Laporan publik sengaja tidak meminta nama atau nomor telepon orang yang dilaporkan. Semua laporan baru berstatus menunggu verifikasi. Jangan unggah data pribadi, foto wajah, atau tuduhan yang tidak didukung fakta.
