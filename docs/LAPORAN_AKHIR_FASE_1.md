# Laporan akhir Fase 1: fondasi database Supabase

Status: semua 10 kriteria pengujian di `docs/RANCANGAN_DB_FASE_1.md` Bagian 8 lulus di lingkungan uji lokal. Ada hal yang tidak bisa diuji di sana; daftarnya ada di bawah dan langkah ujinya di `docs/UJI_ASAP_SUPABASE.md`. Fase 1 sebaiknya baru dianggap final setelah uji asap itu Anda jalankan.

## Yang dibangun (migrasi 0001-0008)
| Migrasi | Isi |
|---|---|
| 0001 | Enum (peran, status laporan, jenis bukti, jenis sanksi) |
| 0002 | Profil, peran petugas, audit log berantai hash (append-only), `admin_set_role`, `verify_audit_chain` |
| 0003 | Laporan, riwayat status, mesin transisi satu pintu, `submit_report`, `cancel_report` |
| 0004 | Bukti + versi, bucket privat `evidence`, kebijakan Storage, `add_evidence`, `replace_evidence_version`, EV-01 wajib |
| 0005 | Review verifier, temuan, duplikasi, keberatan, penarikan, konflik kepentingan, RPC petugas |
| 0006 | Forum keputusan, peserta, suara rahasia dan final, tie-break Admin Utama |
| 0007 | Sanksi, banding (verifier tidak terlibat), blacklist HMAC dengan pepper Vault, pembatasan akun nyata |
| 0008 | View publik `public_reports`, pengerasan hak `service_role`, indeks semua FK |

## Hasil pengujian lokal
- 794 pernyataan kumulatif lulus (Tahap 1: 89, Tahap 2: 102, Tahap 3: 88, Tahap 4: 170, Tahap 5: 119, Tahap 6: 176, Tahap 7: 50), ditambah uji guard skema lama, backfill profil, dan konkurensi audit (transaksi paralel via pgbench, rantai tetap utuh).
- Migrasi dijalankan dua kali pada setiap putaran (idempoten).
- Setiap tahap diuji dengan mutasi sengaja (menghapus/melonggarkan satu proteksi, mis. 9 mutasi pada Tahap 7); tes menangkap semuanya.
- Pemetaan ke kriteria: (1) struktur, RLS, hak anon: tahap 1-7 dan invarian Tahap 7; (2) relasi dan constraint: tiap tahap; (3) RLS per peran: tiap tahap, termasuk akun dibatasi sanksi dan email belum terverifikasi; (4) publik vs privat: Tahap 7; (5) status, riwayat, atomik: Tahap 2; (6) eskalasi peran: Tahap 1; (7) audit log dan deteksi perusakan: Tahap 1; (8) konflik, forum, tie-break: Tahap 4-5; (9) sanksi/banding/blacklist: Tahap 6; (10) kebijakan Storage: Tahap 3.

## Temuan selama Fase 1
- Tahap 7 menemukan `service_role` masih punya hak tulis langsung pada `profiles`, `reports`, `user_roles` (tertinggal dari tahap awal). Sudah dicabut di 0008.
- Tahap 7 menemukan kolom FK tanpa indeks. Sudah ditambahkan, dan ada tes yang menjaga agar FK baru wajib berindeks.
- Tahap 2 menemukan bahwa hapus laporan yang punya riwayat sudah ditahan relasi tabel, bukan hanya hak akses.

## Belum teruji / batasan yang harus Anda ketahui
1. **Supabase asli:** Auth (email konfirmasi, trigger pada `auth.users`), Storage API (batas ukuran/MIME bucket, signed URL 5 menit), PostgREST, peringatan linter, Vault: semuanya hanya ditiru atau tidak diuji. Lihat uji asap.
2. **Penegakan di Auth:** penangguhan/blokir belum mencegah login; Auth Hook pemblokiran pendaftaran email blacklist belum tersambung.
3. **Audit log:** rantai hash mendeteksi perusakan tetapi tidak mencegahnya oleh superuser (trigger bisa dimatikan); pemotongan di ujung rantai tidak terdeteksi tanpa menyimpan `head_hash` di luar database.
4. **Koordinat presisi publik** (keputusan Anda, K-04) dapat menunjuk rumah pribadi; ini risiko yang disadari.
5. **Frontend belum terhubung ke Supabase.** `index.html` masih memakai LocalStorage dan Google Apps Script (sesuai rencana: integrasi di fase berikutnya). Frontend juga masih mengirim `driver_nama`/`driver_id` ke GAS; disarankan dihentikan.
6. **Kebijakan retensi bukti** dan batas waktu (SRS Bab VIII) belum diputuskan; tidak ada pembersihan otomatis.
7. **Performa** pada data besar tidak diuji.
8. **View publik** berjalan dengan hak pemilik (melewati RLS) dengan sengaja; keamanannya bertumpu pada daftar kolom dan filter status, yang dijaga tes. Linter akan memberi peringatan untuk itu.
9. Banyak **asumsi** saya yang bukan dari SRS tercatat di lampiran `docs/RANCANGAN_DB_FASE_1.md`. Mohon ditinjau, terutama: tie-break oleh Admin Utama, satu item bukti per jenis, definisi konflik (pemilik laporan), penangguhan sanksi tanpa syarat banding.
10. Pertanyaan lama yang belum Anda jawab: apakah project Supabase Anda pernah menjalankan `supabase_schema.sql` lama yang berisi data? Migrasi 0002 akan berhenti bila menemukan tabel lama.

## Saran fase berikutnya
Integrasi frontend (Auth, formulir laporan, unggah bukti, daftar publik dari `public_reports`), Auth Hook blacklist dan penegakan sanksi, antarmuka petugas, kebijakan retensi, lalu migrasi data dari Google Sheets dan pemensiunan Google Apps Script.
