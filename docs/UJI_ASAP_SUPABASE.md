# Uji asap di project Supabase asli (Fase 1)

Tes lokal memakai PostgreSQL biasa dengan tiruan Supabase. Langkah di bawah menguji hal yang **tidak** bisa diuji di sana. Lakukan di project **uji/staging** dulu, bukan produksi. Jangan menempelkan kunci `service_role` ke HTML/JS atau commit apa pun.

## A. Persiapan
1. Aktifkan **Storage** dan **Vault** di project. Di Auth, aktifkan **Confirm email**.
2. Jalankan `supabase/migrations/0001` sampai `0008` berurutan (SQL Editor atau `supabase db push`). Jalankan **sekali lagi** seluruhnya: harus tanpa error (idempoten). Bila berhenti dengan "Migrasi dihentikan" pada 0002, berarti tabel `reports` lama masih ada: ekspor datanya dan ganti namanya dulu.
3. Buat pepper blacklist: `select vault.create_secret('<string-acak-min-16-karakter>', 'blacklist_pepper');` Simpan nilainya di tempat aman (bukan di repo).
4. Daftarkan satu akun lewat Auth, konfirmasi emailnya, lalu jalankan `supabase/bootstrap_admin.example.sql` dengan UUID akun itu agar menjadi Admin Utama.
5. Settings → API → **Exposed schemas**: pastikan hanya `public` (skema `private` tidak boleh ada).

## B. Pemeriksaan (centang satu per satu)
| # | Langkah | Hasil yang diharapkan |
|---|---|---|
| 1 | Table Editor: lihat 19 tabel | Semua menunjukkan RLS aktif |
| 2 | Advisors / Linter | Hanya peringatan "security definer view" untuk `public_reports` (disengaja). Peringatan lain: catat dan kirim ke saya |
| 3 | `GET /rest/v1/public_reports` dengan anon key | 200, hanya laporan Verified, tanpa kolom `user_id`/`status` |
| 4 | `GET /rest/v1/reports`, `/profiles`, `/audit_logs`, `/blacklist_entries` dengan anon key | Ditolak (401/403, permission denied) |
| 5 | `POST /rest/v1/rpc/submit_report` dengan anon key | Ditolak |
| 6 | Login sebagai pengguna biasa (JWT). `POST /rest/v1/reports` tanpa `user_id` | 201, status `draft`, `user_id` = akun Anda |
| 7 | `PATCH /rest/v1/reports` mengisi `status` atau `user_id` | Ditolak |
| 8 | Upload `<id-laporan>/bukti.png` ke bucket `evidence` lewat Storage API; lalu `rpc/add_evidence` | Berhasil. Upload ke folder laporan orang lain: ditolak |
| 9 | Upload file GIF, lalu file > 5 MB | Keduanya ditolak oleh bucket |
| 10 | `rpc/submit_report` tanpa bukti EV-01, lalu dengan EV-01 | Pertama ditolak (`report_incomplete`), kedua menjadi `pending` |
| 11 | Buat signed URL bukti: sebagai pemilik, lalu sebagai pengguna lain/anon | Pemilik berhasil (kedaluwarsa dalam 5 menit sesuai pengaturan Anda), lainnya gagal |
| 12 | Daftar akun baru **tanpa** konfirmasi email, coba `POST /rest/v1/reports` | Ditolak |
| 13 | Jadikan akun lain verifier lewat `rpc/admin_set_role` (JWT Admin Utama), moderator lewat cara yang sama; jalankan `start_review` → `submit_review` → `decide_report` | Alur berjalan; verifier baru bisa membuka file bukti setelah `start_review` |
| 14 | Setelah Verified, `GET /rest/v1/public_reports` | Laporan tampil dengan koordinat presisi |
| 15 | `rpc/verify_audit_chain` dengan JWT Admin Utama | `ok = true` |
| 16 | Blokir permanen: moderator `propose_permanent_ban`, Admin Utama `approve_permanent_ban`. Lalu hapus pepper dan ulangi pada usulan lain | Dengan pepper: berhasil dan ada entri blacklist. Tanpa pepper: ditolak `pepper_missing` |

Catatan: Auth Hook untuk menolak pendaftaran email yang diblacklist **belum** tersambung (butuh pengujian di Supabase asli), dan penangguhan/blokir belum mencegah login. Keduanya masuk fase integrasi Auth.
