# Rancangan Database Fase 1 — Fondasi Supabase
**Radar Order Fiktif Malang Raya** · basis: `main` @ `ee2905c` (Fase 0 ter-merge) · SRS v0.1 · 24 Nov 2026

**Status: RANCANGAN DISETUJUI (24 Nov 2026) dengan semua default D1–D10. Implementasi bertahap; Tahap 1 = migrasi `0002`.**

Catatan implementasi Tahap 1: `verify_audit_chain()` dipindah dari `0008` ke `0002` karena pengujian audit log membutuhkannya sejak awal.

---

## 1. Hasil audit

| Item | Temuan |
|---|---|
| `main` | `ee2905c`, PR #1 (Fase 0) sudah ter-merge. Frontend belum memakai Supabase sama sekali. |
| Migration yang ada | Hanya `0001_enums.sql`: 4 enum (`app_role`, `report_status`, `evidence_type`, `sanction_type`). Belum ada tabel. Enum ini dipakai ulang, tidak diubah. |
| `supabase_schema.sql` | Deprecated. **Tidak dipakai** sebagai dasar. |
| Cakupan ERD SRS | 13 entitas (A.2). Semuanya ada di rancangan ini. Ada tambahan tabel pendukung (Bagian 3) yang diturunkan dari FR/BR yang tidak punya entitas di ERD. |
| Status transisi | SRS 4.2: *"Alur transisi status perlu diuji dan ditetapkan lebih rinci saat desain teknis."* Matriks transisi di Bagian 4 adalah **usulan** yang perlu Anda setujui. |
| Lingkungan uji | PostgreSQL 16.15 + `pgcrypto` tersedia di sandbox. **Tidak ada** pgTAP, PostGIS, dan Supabase asli. Konsekuensinya ada di Bagian 8. |

**Pertanyaan yang memengaruhi cara saya mengerjakan:** apakah project Supabase Anda sudah pernah menjalankan `supabase_schema.sql` lama dan berisi data? Jika ya, migrasi baru harus berhenti dengan pesan jelas (tidak menimpa), dan kita rencanakan pemindahan datanya. Jika belum, jalurnya bersih.

---

## 2. Prinsip rancangan

1. **Deny by default.** Setiap tabel `public` mengaktifkan RLS dan semua hak `anon`/`authenticated` dicabut lebih dulu, baru diberi hak minimal. Supabase memberi hak penuh ke tabel baru secara default, jadi pencabutan ini wajib dan akan diuji.
2. **Status tidak pernah diubah langsung dari klien.** Kolom `status` tidak punya hak UPDATE untuk API. Perubahan hanya lewat fungsi `SECURITY DEFINER` yang memeriksa peran, transisi sah, dan alasan, lalu menulis riwayat dan audit dalam satu transaksi.
3. **Tidak ada DELETE** untuk peran API di tabel mana pun (laporan, bukti, riwayat tidak boleh hilang: FR-41, FR-57, BR-06).
4. **Riwayat bersifat tambah-saja** (`report_histories`, `evidence_versions`, `audit_logs`, `forum_votes`) dan dilindungi trigger.
5. **Role dicek di database**, bukan di UI. Role tidak bisa diubah oleh pemiliknya (FR-25).
6. **Tidak ada secret di repo.** Pepper untuk fingerprint blacklist disimpan di Supabase Vault, bukan di file.

---

## 3. Daftar tabel dan relasi

Skema: tabel di `public`; fungsi bantu internal di skema `private` (tidak diekspos API).

| # | Tabel | Fungsi | Kolom kunci | Relasi |
|---|---|---|---|---|
| 1 | `profiles` | Profil publik-internal akun. Email **tidak** disalin; email tetap di `auth.users`. | `id` (=auth.users.id), `display_name`, `created_at` | 1:1 `auth.users` |
| 2 | `user_roles` | Peran petugas + riwayat penunjukan/pencabutan | `user_id`, `role`, `granted_by`, `granted_at`, `revoked_at`, `reason` | N:1 `profiles`. Maks. 1 peran aktif per user (indeks unik parsial). Tanpa baris = `user`. |
| 3 | `reports` | Laporan inti | `id`, `user_id`, `region`, `district`, `location_general`, `incident_type`, `story`, `incident_at`, **`lat`, `lng`**, `status`, `app_name`*, `service_category`*, `loss_amount`*, `submitted_at`, `verified_at`, `created_at` | N:1 `profiles` |
| 4 | `report_histories` | Riwayat status + tindakan penting | `report_id`, `actor_id`, `old_status`, `new_status`, `action`, `reason`, `created_at` | N:1 `reports` |
| 5 | `evidences` | Satu item bukti | `report_id`, `evidence_type`, `current_status`, `declared_three_calls`**, `declared_single_screenshot`** | N:1 `reports` |
| 6 | `evidence_versions` | Versi file bukti | `evidence_id`, `version_number`, `uploaded_by`, `private_file_path`, `mime_type`, `size_bytes`, `sha256`, `description`, `replace_reason`, `version_status`, `uploaded_at` | N:1 `evidences`. Satu versi `current` per bukti. |
| 7 | `verification_reviews` | Sesi pemeriksaan | `report_id`, `verifier_id`, `result`, `notes`, `started_at`, `reviewed_at` | N:1 `reports` |
| 8 | `verification_findings` | Temuan per bukti/aspek | `review_id`, `evidence_type`, `finding_type`, `description`, `assessment` | N:1 `verification_reviews` |
| 9 | `duplicate_indications`** | Indikasi duplikasi (FR-17, BR-08) | `report_id`, `duplicate_of_id`, `review_id`, `basis[]`, `notes` | 2 FK ke `reports` |
| 10 | `objections` | Keberatan atas laporan Verified | `report_id`, `user_id`, `reason`, `status`, `reviewer_id`, `review_notes`, `decided_by`, `decision_reason`, `decided_at` | N:1 `reports` |
| 11 | `withdrawal_requests`** | Permintaan penarikan saat Under Review (FR-44/45) | `report_id`, `requested_by`, `reason`, `status`, `decided_by`, `decision_reason`, `decided_at` | N:1 `reports`. Maks. 1 permintaan terbuka per laporan. |
| 12 | `conflict_declarations`** | Pengungkapan konflik kepentingan (FR-22, BR-10) | `report_id`, `staff_id`, `reason`, `declared_at` | N:1 `reports` |
| 13 | `decision_forums` | Forum keputusan | `report_id`, `objection_id?`, `question`, `status`, `decision`, `decided_by_tiebreak`, `minutes`, `opened_by`, `decided_at` | N:1 `reports` |
| 14 | `forum_participants`** | Peserta forum | `forum_id`, `user_id`, `role_at_time` | N:1 `decision_forums` |
| 15 | `forum_votes` | Suara | `forum_id`, `voter_id`, `vote`, `reason`, `voted_at` | **UNIQUE (`forum_id`,`voter_id`)** |
| 16 | `sanctions` | Sanksi | `user_id`, `moderator_id`, `sanction_type`, `reason`, `report_id?`, `starts_at`, `ends_at`, `status`, `proposed_by`, `approved_by`, `approved_at` | N:1 `profiles` |
| 17 | `appeals` | Banding | `sanction_id`, `user_id`, `admin_reviewer_id`, `verifier_reviewer_id`, `reason`, `status`, `decision_reason`, `created_at` | N:1 `sanctions` |
| 18 | `blacklist_entries` | Blacklist privat | `user_id`, `email_fingerprint`, `phone_fingerprint?`, `status`, `reason`, `created_at` | N:1 `profiles` |
| 19 | `audit_logs` | Log audit append-only berantai hash | `id`, `occurred_at`, `actor_id`, `actor_role`, `action`, `object_type`, `object_id`, `reason`, `old_data`, `new_data`, `prev_hash`, `row_hash` | – |

\* atribut aplikasi saat ini, dipertahankan opsional (keputusan K-03).
\*\* tabel/kolom di luar ERD SRS, diturunkan dari FR/BR (kolom "Dasar" di Bagian 3.1).

Selain tabel: **view `public_reports`**, **bucket Storage privat `evidence`**, dan fungsi bantu/RPC (Bagian 5).

### 3.1 Dasar tambahan di luar ERD

| Tambahan | Dasar di SRS |
|---|---|
| `lat`, `lng` di `reports` | FR-01 peta publik; keputusan K-04 (koordinat presisi). `numeric(9,6)`, rentang -90..90 / -180..180, **keduanya terisi atau keduanya kosong**. |
| `duplicate_indications` | FR-17, BR-08. Constraint: `basis` tidak boleh hanya `{location}`. |
| `withdrawal_requests` | FR-44, FR-45, BR-58. |
| `conflict_declarations` | FR-22, BR-10. |
| `forum_participants` | FR-21, FR-23; dibutuhkan untuk menghitung peserta yang berhak memilih. |
| `declared_three_calls` / `declared_single_screenshot` | BR-66/FR-52. DB tidak bisa memeriksa isi gambar; constraint hanya memastikan pelapor menyatakan "satu screenshot utuh" bila mengklaim tiga panggilan, dan verifier menilainya di temuan. |
| `reports.user_id` tetap ada, `profiles.account_status` **tidak** disimpan | Status akun diturunkan dari sanksi aktif lewat fungsi, supaya tidak bisa selisih dengan tabel `sanctions`. Ini satu-satunya penyimpangan dari ERD. |

### 3.2 Constraint dan indeks penting
- `report_status`/`evidence_type`/`sanction_type`/`app_role`: enum dari `0001`.
- `reports.story`: 20–700 karakter (mengikuti skema lama; formulir saat ini 600).
- `reports.incident_at` tidak boleh di masa depan.
- `evidence_versions`: UNIQUE (`evidence_id`,`version_number`); UNIQUE parsial satu `current` per `evidence_id`; `replace_reason` wajib untuk versi > 1.
- `report_histories`: alasan wajib untuk transisi yang menurut SRS wajib beralasan (cancel, needs_revision, reject, keputusan penarikan: BR-59, FR-58).
- `sanctions`: `permanent_ban` berstatus `active` hanya jika `approved_by` terisi dan `approved_by <> proposed_by` (BR-13).
- `forum_votes`: UNIQUE (`forum_id`,`voter_id`); trigger menolak suara dari non-peserta, peserta yang punya `conflict_declarations` untuk laporan itu, atau forum yang sudah ditutup.
- `appeals`: trigger menolak `verifier_reviewer_id` yang ikut dalam keputusan sanksi awal (definisi "terlibat" ada di keputusan D7).
- Indeks: `reports(user_id)`, `reports(status, submitted_at)`, parsial `reports(verified_at desc, id) WHERE status='verified'`, parsial `reports(lat,lng) WHERE status='verified' AND lat IS NOT NULL`, `report_histories(report_id, created_at)`, `evidences(report_id)`, `user_roles(user_id) WHERE revoked_at IS NULL`, FK lain.

---

## 4. Alur status (USULAN, perlu persetujuan)

| Dari → Ke | Pelaku | Syarat |
|---|---|---|
| (baru) → `draft` | Pemilik | Email terverifikasi, akun tidak dibatasi |
| `draft` → `pending` | Pemilik | Wajib ada EV-01 versi current (lihat D2) |
| `draft` → `cancelled` | Pemilik | Alasan wajib *(asumsi, tidak diatur eksplisit di SRS)* |
| `pending` → `cancelled` | Pemilik | **Alasan wajib** (FR-39/40, BR-59) |
| `pending` → `under_review` | Verifier | Tidak punya konflik kepentingan atas laporan itu; membuat baris `verification_reviews` (FR-42) |
| `under_review` → `needs_revision` | Verifier | Alasan wajib (FR-16, FR-58) |
| `needs_revision` → `pending` | Pemilik | Kirim ulang (FR-19); EV-01 masih ada |
| `under_review` → `verified` / `rejected` | Moderator | Alasan wajib; ada rekomendasi verifier; tanpa konflik; opsional merujuk `forum_id` (lihat D1) |
| `under_review` → `cancelled` | Moderator | Hanya setelah menyetujui `withdrawal_request` (FR-45) |
| `verified` → `under_review` | Moderator | Menerima keberatan untuk diperiksa ulang (FR-20) |
| `verified` → `rejected` | Moderator | Hasil keberatan, alasan wajib |
| `rejected`, `cancelled` | – | Terminal |

Transisi lain **ditolak** oleh fungsi dan trigger. Setiap transisi menulis `report_histories` + `audit_logs` dalam transaksi yang sama (FR-18).

---

## 5. Fungsi (RPC) yang membungkus aksi berstatus

Semua `SECURITY DEFINER`, `search_path=''`, `EXECUTE` dicabut dari `PUBLIC`/`anon` lalu diberikan hanya ke `authenticated`. Setiap fungsi memeriksa ulang `auth.uid()`, peran, dan kondisi data; tidak ada yang mempercayai argumen.

`submit_report`, `cancel_report`, `start_review`, `return_for_revision`, `decide_report`, `request_withdrawal`, `decide_withdrawal`, `file_objection`, `decide_objection`, `replace_evidence_version`, `declare_conflict`, `open_forum`, `add_forum_participant`, `cast_vote`, `close_forum`, `impose_sanction`, `propose_permanent_ban`, `approve_permanent_ban`, `suspend_sanction`, `file_appeal`, `assign_appeal_reviewer`, `decide_appeal`, `admin_set_role`, `admin_revoke_role`, `is_email_blacklisted`.

Fungsi bantu di `private`: `current_app_role()`, `has_role()`, `email_verified()`, `is_restricted()`, `has_conflict()`, `can_view_evidence()`, `email_fingerprint()`, `write_audit()`.

---

## 6. Matriks akses RLS

Legenda: **S** select · **I** insert · **U** update (kolom terbatas) · **RPC** hanya lewat fungsi · **–** tidak ada akses. **DELETE: tidak ada untuk semua peran, di semua tabel.** "Email OK" = email terverifikasi dan akun tidak dibatasi sanksi.

| Tabel / objek | Publik (anon) | User pemilik | User lain (login) | Verifier | Moderator | Admin Utama |
|---|---|---|---|---|---|---|
| `public_reports` (view, hanya Verified, kolom aman) | **S** | S | S | S | S | S |
| `profiles` | – | S/U sendiri (`display_name`) | – | S (id, nama) | S (id, nama) | S |
| `user_roles` | – | S sendiri | – | S sendiri | S (daftar petugas) | S; tulis **RPC** |
| `reports` | – | S semua statusnya; I sebagai `draft` (Email OK); U kolom isi saat `draft`/`needs_revision`; status **RPC** | – | S non-draft | S non-draft | S non-draft |
| `report_histories` | – | S laporan sendiri | – | S non-draft | S non-draft | S non-draft |
| `evidences` / `evidence_versions` (metadata) | – | S; I saat `draft`/`needs_revision`; ganti versi **RPC** | – | S non-draft | S non-draft | S non-draft |
| **File bukti (Storage `evidence`)** | – | S/upload milik sendiri | – | S **setelah** `start_review` pada laporan itu (D5) | S non-draft | S non-draft |
| `verification_reviews` / `_findings` | – | – | – | I/S/U milik sendiri (selama `in_progress`) | S | S |
| `duplicate_indications` | – | – | – | I/S/U milik sendiri | S | S |
| `objections` | – | I (laporan Verified, Email OK), S milik sendiri | idem (siapa pun yang login, D-minor) | S; U catatan pemeriksaan | S; keputusan **RPC** | S |
| `withdrawal_requests` | – | I (saat `under_review`), S sendiri | – | – | S; keputusan **RPC** | S |
| `conflict_declarations` | – | – | – | I/S atas dirinya | I/S atas dirinya + S semua | I/S atas dirinya + S semua |
| `decision_forums` | – | – | – | S jika peserta | I/S (RPC buka & tutup) | I/S |
| `forum_participants` | – | – | – | S forum yang diikuti | S; tambah **RPC** | S; tambah **RPC** |
| `forum_votes` | – | – | – | I suara sendiri; S sendiri sebelum tutup, semua peserta setelah tutup | idem | idem; tie-break **RPC** |
| `sanctions` | – | S sendiri | – | S bila ditugaskan pada bandingnya | S; I non-permanen & usul permanen **RPC** | S; persetujuan/penangguhan **RPC** |
| `appeals` | – | I (sanksi sendiri), S sendiri | – | S/U rekomendasi bila ditugaskan | S | S; tugaskan & putuskan **RPC** |
| `blacklist_entries` | – | – | – | – | – (usul lewat sanksi) | S; tulis **RPC** |
| `audit_logs` | – | – | – | – | – | **S**; tulis hanya oleh fungsi/trigger; UPDATE/DELETE/TRUNCATE diblokir |

**Yang tidak pernah terlihat oleh publik:** `user_id` pelapor, bukti mentah, riwayat, temuan, forum, sanksi, blacklist, audit. View `public_reports` hanya memuat: `id`, `region`, `district`, `location_general`, `incident_type`, `app_name`, `service_category`, **`lat`, `lng` presisi**, `incident_at`, `verified_at`, dan (lihat D3) `story`, `loss_amount`.

---

## 7. Risiko dan mitigasi

| # | Risiko | Mitigasi |
|---|---|---|
| R1 | **Hak default Supabase** memberi `anon`/`authenticated` akses ke tabel baru | Migrasi mencabut semua hak lalu memberi minimal. Uji otomatis: semua tabel `public` ber-RLS, `anon` tidak punya hak apa pun selain `SELECT` pada `public_reports`. |
| R2 | Eskalasi role / manipulasi status dari klien | Tidak ada hak INSERT/UPDATE pada `user_roles` dan kolom `status`; hanya RPC. Uji: user mencoba `UPDATE reports SET status='verified'` dan `INSERT user_roles` → harus gagal. |
| R3 | Fungsi `SECURITY DEFINER` disalahgunakan | `search_path=''`, `EXECUTE` dicabut dari `PUBLIC`, validasi ulang `auth.uid()`; uji pemanggilan oleh peran yang tidak berhak. |
| R4 | Rekursi/performa RLS | Fungsi bantu `STABLE` dengan `(select auth.uid())`, indeks pada FK dan `user_roles`. |
| R5 | `public_reports` adalah view definer (melewati RLS tabel dasar) | Dibatasi `WHERE status='verified'` dan daftar kolom eksplisit; uji bahwa laporan non-Verified dan kolom privat tidak pernah muncul. Supabase linter akan memberi peringatan untuk view ini; itu disengaja dan didokumentasikan. |
| R6 | **Audit log immutable (K-05)** | Pencegahan: tak ada hak tulis API; trigger menolak UPDATE/DELETE/TRUNCATE. Deteksi: **rantai hash** (`prev_hash`→`row_hash`) + fungsi `verify_audit_chain()`. **Batas jujur:** pemilik database/superuser masih bisa menonaktifkan trigger; rantai hash hanya *mendeteksi*. Disarankan ekspor hash terakhir berkala ke tempat di luar database. |
| R7 | Penulisan audit berantai menyerialkan insert | Advisory lock; volume aksi petugas rendah, dapat diterima. |
| R8 | Pepper fingerprint blacklist | Disimpan di Supabase Vault; **tidak ada di repo**. Fungsi gagal tertutup jika pepper tidak ada. Tanpa pepper, fingerprint hanya bisa diuji di lokal dengan nilai uji. |
| R9 | Pemblokiran pendaftaran ulang butuh hook di Auth | Fase 1 menyediakan `is_email_blacklisted()`. Penyambungan ke Auth Hook (before-user-created) dilakukan saat integrasi Auth dan perlu diuji di Supabase asli. |
| R10 | **Koordinat presisi publik (K-04)** dapat menunjuk rumah warga | Keputusan Anda dipatuhi. DB hanya mengekspos koordinat laporan Verified; jalur koreksi lewat keberatan (`objections`). Risiko residual tetap ada dan sebaiknya masuk kebijakan moderasi. |
| R11 | Migrasi menabrak tabel lama di project Anda | Pra-pemeriksaan: jika `public.reports` lama ada dengan bentuk berbeda, migrasi **berhenti** dengan pesan, tidak `DROP`. Semua DDL idempoten (`IF NOT EXISTS`). |
| R12 | Enum tidak bisa dihapus nilainya | Nilai enum mengikuti SRS; penambahan nilai aman, penghapusan tidak. |
| R13 | Nilai default batas file/panjang teks belum diputuskan SRS | Dipasang sebagai konfigurasi yang mudah diubah (D9). |

---

## 8. Kriteria pengujian dan batasannya

Tes ditulis sebagai SQL biasa di `supabase/tests/` dan dijalankan dengan `psql` terhadap PostgreSQL 16 lokal. Karena tidak ada Supabase asli, ada **stub** `auth.users`, `auth.uid()`, `auth.jwt()`, peran `anon/authenticated/service_role`, dan `storage.objects` (hanya di berkas tes, tidak pernah ikut migrasi).

**Akan diuji (harus lulus semua sebelum Fase 1 saya nyatakan selesai):**
1. **Struktur:** migrasi berurutan berjalan di DB kosong; **dijalankan dua kali** tanpa error (idempoten); semua tabel ber-RLS; tak ada hak `anon`.
2. **Relasi & constraint:** FK menolak yatim; enum menolak nilai salah; `lat/lng` keduanya-atau-tidak-sama-sekali; satu versi `current` per bukti; alasan wajib; suara ganda ditolak; blokir permanen tanpa persetujuan ditolak; `basis` duplikasi hanya `location` ditolak.
3. **RLS per peran** (anon, user pemilik, user lain, user email belum terverifikasi, user dibatasi sanksi, verifier, moderator, admin): setiap sel di matriks Bagian 6, positif **dan** negatif.
4. **Publik vs privat:** `anon` hanya melihat Verified di `public_reports` dengan koordinat identik dengan yang disimpan; tidak ada `user_id`; Cancelled/Pending/Rejected/Draft tidak muncul.
5. **Status:** semua transisi sah berhasil; semua transisi tidak sah ditolak; update langsung kolom `status` oleh user/verifier ditolak; alasan wajib ditegakkan; riwayat dan audit tercatat atomik; transaksi gagal tidak meninggalkan riwayat.
6. **Eskalasi:** user tidak bisa memberi dirinya peran; hanya `admin_utama` yang bisa `admin_set_role`; pencabutan peran tercatat.
7. **Audit log:** UPDATE/DELETE/TRUNCATE ditolak; INSERT langsung dari `authenticated` ditolak; `verify_audit_chain()` lulus pada rantai utuh dan **gagal** setelah satu baris sengaja dirusak (dengan trigger dimatikan oleh superuser di tes).
8. **Konflik kepentingan & forum:** petugas ber-konflik tidak bisa `start_review`/`decide_report`/memberi suara; mayoritas; suara seri hanya diputus Admin Utama; tidak ada penutupan ganda.
9. **Sanksi/banding/blacklist:** usulan permanen oleh moderator + persetujuan admin; verifier yang terlibat tidak bisa ditugaskan pada banding; banding dikabulkan memperbarui sanksi dan blacklist.
10. **Storage (kebijakan):** pemilik dan petugas berwenang bisa baca; user lain/anon tidak; user tidak bisa menimpa atau menghapus objek versi lama.

**Tidak dapat diuji di sandbox (akan saya laporkan sebagai belum teruji):**
- Perilaku Supabase Auth nyata (kirim email, `email_confirmed_at`, Auth Hook pemblokiran blacklist).
- Supabase Storage API nyata: batas ukuran/MIME bucket, signed URL. Hanya logika kebijakannya yang diuji lewat tabel tiruan.
- PostgREST (kolom yang diekspos, pesan error) dan peringatan Supabase linter.
- Vault untuk pepper (diuji dengan nilai uji lokal).
- Performa pada data besar.

Anda akan perlu menjalankan satu putaran uji asap di project Supabase Anda setelah migrasi; saya siapkan daftar langkahnya.

---

## 9. Rencana implementasi bertahap (branch `feat/srs-fase-1-database`)

| Tahap | Migrasi | Isi | Uji |
|---|---|---|---|
| 1 | `0002` | Skema `private`, `profiles`, `user_roles`, `audit_logs` (+rantai hash), `admin_set_role`, pencabutan hak default | struktur, eskalasi, audit |
| 2 | `0003` | `reports`, `report_histories`, mesin transisi, RPC pelapor | status, RLS laporan |
| 3 | `0004` | `evidences`, `evidence_versions`, bucket + kebijakan Storage, `replace_evidence_version` | bukti, versi, storage |
| 4 | `0005` | `verification_*`, `duplicate_indications`, `objections`, `withdrawal_requests`, `conflict_declarations` | alur petugas |
| 5 | `0006` | `decision_forums`, `forum_participants`, `forum_votes` | voting, seri, konflik |
| 6 | `0007` | `sanctions`, `appeals`, `blacklist_entries` | sanksi/banding |
| 7 | `0008` | `public_reports`, indeks akhir, `verify_audit_chain()` | publik vs privat, regresi penuh |

Satu commit per tahap. Pull Request dibuka setelah semua tahap lulus; **tidak saya merge**.

**Kendala PR:** akun GitHub belum terhubung ke sesi ini, jadi saya belum bisa push atau membuka PR. Jika tetap begitu, saya serahkan patch per tahap dan teks PR siap tempel, seperti pada Fase 0.

---

## 10. Keputusan yang perlu Anda setujui

Setiap butir punya **default yang akan saya pakai** bila Anda cukup menjawab "setuju". Semua ini adalah ruang yang SRS biarkan terbuka (Bab VIII atau 4.2), bukan aturan baru yang saya tambahkan.

| ID | Pertanyaan | Default |
|---|---|---|
| D1 | Siapa yang menetapkan `Verified`/`Rejected`? | **Moderator**, berdasarkan rekomendasi verifier (selaras dengan alur keberatan). Verifier hanya bisa `needs_revision`. |
| D2 | Apakah EV-01 wajib ada saat `draft → pending`? | **Ya.** (BR-63, FR-48; SRS 5.3: laporan tak boleh tampak lengkap tanpa bukti utama.) |
| D3 | Kolom publik di `public_reports` | Semua yang tertulis di Bagian 6 **termasuk `story` dan `loss_amount`** (sama dengan tampilan aplikasi sekarang). Risiko: kronologi bisa memuat data pribadi; mitigasinya panduan di formulir. |
| D4 | Saat keberatan diperiksa, apakah laporan tetap tampil publik? | **Tetap tampil** sampai moderator mengubah status. |
| D5 | Kapan verifier boleh membuka file bukti? | **Setelah** `start_review` pada laporan itu (hak akses paling sempit). |
| D6 | Model peran | **Satu peran aktif per orang.** Admin Utama tidak otomatis boleh memverifikasi/memoderasi; hak diberikan per aksi sesuai SRS Bab III. Admin Utama pertama dibuat lewat SQL oleh pemilik proyek. |
| D7 | "Verifier yang tidak terlibat" pada banding | Bukan: moderator/pengusul/penyetuju sanksi, peserta forum yang memutus sanksi itu, dan verifier yang memeriksa laporan dasar sanksi. |
| D8 | Penutupan forum tanpa kuorum | Forum dapat ditutup setelah **semua peserta berhak** memberi suara atau abstain; suara tidak bisa diubah setelah dikirim. |
| D9 | Batas teknis (dapat dikonfigurasi) | `story` 20–700 karakter; bukti **JPEG/PNG/WebP, maks. 5 MB**; signed URL **5 menit**. |
| D10 | Akses `blacklist_entries` | **Hanya Admin Utama** (BR-14 "petugas berwenang" tidak merinci). |

---

## 11. Di luar cakupan Fase 1
Integrasi frontend ke Supabase, UI login/laporan, Edge Function (penetapan `banned_until`, penerbitan signed URL, pembersihan retensi), migrasi data Google Sheets, direktori panti, kebijakan retensi bukti (SRS Bab VIII, belum diputuskan).


---

## Lampiran: asumsi implementasi Tahap 2-4 (bukan dari SRS; mohon dikoreksi bila keliru)

- Satu item bukti per jenis per laporan (`evidences_one_per_type`); mengganti file = versi baru. Kolom `current_status` tidak disimpan (turunan dari versi).
- Bukti ditulis hanya lewat RPC `add_evidence` / `replace_evidence_version`, yang mencocokkan file di Storage (ada, diunggah pemanggil, ukuran/tipe sama).
- Pelapor yang juga petugas dianggap berkonflik atas laporannya sendiri (`private.has_conflict`).
- Rekomendasi verifier wajib bercatatan. Keputusan moderator hanya sah bila ada rekomendasi yang dibuat setelah laporan terakhir masuk Under Review (per siklus). Moderator boleh memutuskan berbeda dari rekomendasi, dengan alasan wajib.
- Setelah rekomendasi selesai pada satu siklus, review baru tidak dibuka lagi pada siklus itu. Bila verifier menyatakan konflik, review-nya dilepas (`abandoned`) dan verifier lain dapat mengambil alih.
- Daftar nilai `finding_type` (evidence_quality, consistency, location, timeline, other), `assessment` (supports, inconclusive, contradicts), dan `basis` duplikasi (location, time, story, evidence) adalah usulan; dasar `location` saja ditolak (BR-08).
- Keberatan: siapa pun yang login dengan email terverifikasi dapat mengajukan atas laporan Verified (satu terbuka per pengguna per laporan). Verifier mencatat pemeriksaan; moderator memutuskan: `reject_objection`, `reopen` (Verified -> Under Review) atau `reject_report` (Verified -> Rejected).
- Pelapor tidak melihat keberatan pihak lain atas laporannya.

### Asumsi Tahap 5 (forum keputusan)

- Satu forum aktif (open/tied) per laporan. Moderator atau Admin Utama membuka forum dan menambah peserta (petugas aktif, tanpa konflik atas laporan itu).
- Suara disimpan final. Pilihan suara tersembunyi dari semua orang selain pemiliknya sampai forum tidak lagi open, termasuk dari Admin Utama, `service_role`, dan log audit (audit suara hanya mencatat siapa yang memilih, bukan pilihannya).
- Forum menutup otomatis setelah semua peserta berhak (tanpa konflik) memilih atau abstain. Peserta yang menyatakan konflik sesudah ditambahkan tidak dihitung; moderator/admin dapat menutup dengan `close_forum` bila semua peserta berhak sudah memilih.
- Suara seri (termasuk 0-0 karena semua abstain) membuat forum berstatus `tied`; hanya Admin Utama yang memutus lewat `resolve_tie` dengan risalah wajib. Siapa pemutus seri adalah asumsi saya (matriks akses tidak eksplisit).
- Hasil forum bersifat rujukan: `decide_report(..., p_forum_id)` menolak keputusan yang berlawanan dengan hasil forum, tetapi forum tidak wajib.

### Asumsi Tahap 6 (sanksi, banding, blacklist)

- Moderator menjatuhkan `warning`, `feature_restriction`, `temporary_suspension` (langsung aktif); `permanent_ban` hanya diusulkan moderator dan disetujui Admin Utama (BR-13; juga dijaga constraint tabel). Admin Utama tidak otomatis moderator (D6), jadi tidak dapat mengusulkan.
- Petugas aktif tidak dapat disanksi lewat fungsi ini (cabut peran lebih dulu). Menyanksi diri sendiri ditolak.
- Akun dianggap dibatasi (`private.account_restricted`) bila ada sanksi `active` bertipe pembatasan fitur, penangguhan sementara, atau blokir permanen yang sudah mulai dan belum lewat `ends_at`. `warning` tidak membatasi. Kedaluwarsa diturunkan dari `ends_at`, tidak disimpan. Pembatasan memblokir: membuat/mengirim laporan, menambah bukti, mengunggah file, mengajukan keberatan. Pengguna yang dibatasi tetap boleh mengajukan banding. Penegakan login (penangguhan/blokir di Auth, `banned_until`) belum ada di Fase 1.
- Banding: pemilik sanksi aktif/ditangguhkan mengajukan; Admin Utama menugaskan satu verifier yang tidak terlibat (D7); verifier merekomendasikan `grant`/`deny` dengan catatan; Admin Utama memutus (rekomendasi wajib ada). Sanksi tetap berlaku selama banding sampai Admin Utama menangguhkannya (FR-33). Dikabulkan: sanksi `lifted` dan entri blacklist `lifted`. Ditolak: sanksi yang ditangguhkan kembali `active`. Penangguhan tidak mensyaratkan adanya banding (asumsi).
- Blacklist: hanya Admin Utama yang dapat membaca (D10), bahkan `service_role` tidak punya akses tabel. Hanya fingerprint HMAC email (huruf kecil, `+alias` dibuang; titik pada Gmail tidak dinormalisasi) yang disimpan, tanpa email polos, juga tidak di audit. `public.is_email_blacklisted(email)` hanya dapat dipanggil `service_role` dan `supabase_auth_admin` (mencegah enumerasi). Penyambungan ke Auth Hook (before-user-created) belum dilakukan dan harus diuji di Supabase asli (R9).
- Kolom `phone_fingerprint` dari ERD awal tidak dibuat karena aplikasi tidak mengumpulkan nomor telepon.
