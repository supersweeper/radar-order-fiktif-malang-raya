# Analisis Gap & Rencana Implementasi SRS v0.1
**Radar Order Fiktif Malang Raya** · repo `supersweeper/radar-order-fiktif-malang-raya` (1 commit, `bf50372`) · 23 Nov 2026

**Status: tahap analisis selesai. Implementasi Fase 0 telah diterapkan pada branch feat/srs-fase-0 dan saat ini sedang dalam proses review melalui Pull Request #1. Implementasi mencakup perbaikan privasi dan keamanan, fondasi konfigurasi, serta penyesuaian dokumentasi.

---

## 1. Ringkasan

Repo saat ini adalah prototipe satu file (`index.html`, 2.368 baris) yang berjalan penuh di browser dengan LocalStorage. **Tidak ada kode Supabase sama sekali di frontend.** `supabase_schema.sql` hanya punya satu tabel dengan tiga status, tanpa user, bukti, riwayat, atau role, dan kolomnya tidak cocok dengan payload aplikasi. Hampir seluruh kebutuhan SRS (autentikasi, RBAC, siklus status, bukti privat, forum, sanksi, banding, blacklist, audit) belum ada.

Yang layak dipertahankan: UI responsif, peta Leaflet, filter wilayah/kecamatan, feed laporan, risk checker, template chat, direktori panti, tema gelap/terang.

**Tiga temuan paling mendesak (bertentangan langsung dengan SRS):**
1. Laporan baru langsung tampil di feed dan peta publik. Tidak ada filter status di `getFilteredReports()` maupun `renderMapMarkers()` (melanggar FR-02, BR-02).
2. Tombol "Valid (+1)" hanya dijaga LocalStorage dan dikirim ke Apps Script tanpa autentikasi, jadi mudah di-spam.
3. Jika pengguna tidak memberi GPS, koordinat diisi acak (jitter ±0,015° dari pusat wilayah) lalu ditampilkan di peta publik sebagai lokasi laporan. Ini menyesatkan.

---

## 2. Hasil audit repository

| Item | Kondisi terverifikasi |
|---|---|
| File | `index.html`, `supabase_schema.sql`, `README.md`, `.nojekyll`. **`PANDUAN_DEPLOY.md` disebut di README tetapi tidak ada.** Tidak ada `.env.example`, tes, CI, atau build step. |
| Stack | HTML + Tailwind CDN (tanpa versi), Lucide `@latest` (tanpa versi), Leaflet 1.9.4 (dengan SRI). Satu blok `<script>` ±1.550 baris. |
| Hosting | `.nojekyll` menandakan GitHub Pages (statis). Environment variable tidak tersedia tanpa build step. |
| Routing | Hash: `#/`, cek risiko, `#/lapor`, `#/peta`, `#/panti`, setelan. |
| Penyimpanan | LocalStorage: `rof_reports`, `rof_panti`, `rof_confirmed`, `rof_photos`, profil driver, tema, dll. |
| Integrasi lama | Google Apps Script. `GAS_WEBAPP_URL` kosong; URL diisi pengguna di Setelan dan disimpan di LocalStorage. Aksi: `lapor`, `validasi`, `tambah_panti`. GET sinkron laporan dan panti. POST `no-cors` tanpa autentikasi. |
| Payload laporan | `kota, kecamatan, aplikasi, jenis_modus, alamat_titik, latitude, longitude, nominal_kerugian, keterangan, akun_tersensor, driver_nama, driver_id` |
| Bukti | 2 foto wajib, dikompres ke JPEG base64 (maks 960 px), disimpan di LocalStorage dengan TTL 30 hari. **Tidak pernah diunggah ke server.** |
| Status | Teks bebas: `'Menunggu Validasi'`; baris dari Sheets default `'Terverifikasi'`. Tidak dipakai untuk menyaring tampilan. |
| ID laporan | `RPT-` + 4 digit acak (rawan tabrakan). |
| Privasi | Nama dan ID driver dikirim ke Sheets. Nama akun/WA disensor sebelum disimpan (bagus). Alamat titik antar tampil bebas di publik. |
| Direktori panti | Fitur terpisah (daftar, tambah, WhatsApp, Maps), disinkronkan lewat GAS. Tidak disebut di SRS. |

### Skema Supabase vs. aplikasi

| Aspek | `supabase_schema.sql` | Aplikasi |
|---|---|---|
| Kolom | `region, district, location_general, incident_type, story, incident_at` | `city, kecamatan, location, service, modus, app, loss, lat, lng, confirmations, risk` |
| Status | `pending / verified / rejected` | Teks bebas Indonesia |
| Panjang cerita | 20–700 | maxlength 600 |
| Insert | Policy mengizinkan **anon** insert | SRS: wajib login + email terverifikasi |
| Hilang | `user_id`, koordinat, aplikasi, bukti, riwayat, role, audit | – |

---

## 3. Matriks kesenjangan (SRS vs. kondisi saat ini)

Legenda: ✅ ada · 🟡 sebagian · ❌ belum ada · ⚠️ ada tetapi bertentangan dengan SRS

| Kelompok SRS | Kebutuhan | Kondisi | Catatan |
|---|---|---|---|
| **Akses publik** | FR-01, FR-02, BR-02 | ⚠️ | Peta/feed publik ada, tapi menampilkan semua laporan termasuk yang belum diverifikasi. |
| **Auth** | FR-03–06, FR-27, BR-03, BR-04 | ❌ | Tidak ada login. Hanya "profil driver" di LocalStorage. |
| **Peran** | FR-25, Bab III | ❌ | Tidak ada user/role. |
| **Pelaporan** | FR-07–09 | 🟡 | Form ada. Kurang: waktu kejadian, kaitan ke akun, status `Pending` baku. Ada field di luar SRS (nominal, akun tersensor, kategori modus) yang perlu diputuskan. |
| **Status & riwayat** | FR-08, 18, 39–46, 58, BR-57–59 | ❌ | Tidak ada siklus status, transisi, riwayat, pembatalan, atau penarikan. |
| **Bukti** | FR-10–13, 47–57, BR-05–07, 60–66 | ❌ | Ada 2 foto generik lokal. Belum ada 6 kategori EV, multi-bukti, versi, akses privat, validasi "satu screenshot utuh" untuk EV-04. |
| **Verifikasi** | FR-14–17, 56, BR-08, 61 | ❌ | Tidak ada antarmuka verifier, temuan, atau penanda duplikasi. |
| **Perbaikan** | FR-16, 19 | ❌ | – |
| **Keberatan** | FR-20 | ❌ | – |
| **Forum & voting** | FR-21–24, BR-09, 10 | ❌ | – |
| **Sanksi & banding** | FR-29–33, BR-11, 12 | ❌ | – |
| **Blacklist & blokir permanen** | FR-34–38, BR-13–15 | ❌ | – |
| **Privasi publik** | FR-28 | 🟡 | Akun disensor; alamat titik antar masih bebas tampil; koordinat jitter menyesatkan. |
| **Audit** | 5.5 | ❌ | – |
| **Keamanan** | 5.1 | ⚠️ | Endpoint GAS tanpa auth; validasi spoofable; CDN tanpa versi (Tailwind, Lucide); `escapeHtml` dipakai konsisten (bagus). |
| **Keandalan upload** | 5.3 | ❌ | Tidak ada upload ke server, jadi belum ada penanganan gagal. |
| **Kinerja** | 5.6 | ❌ | Semua data dimuat sekaligus dari GAS. Perlu paginasi. |
| **Non-SRS, dipertahankan** | – | ✅ | Risk checker, template chat, direktori panti, tema, onboarding. |

---

## 4. Rencana implementasi bertahap

Urutan mengikuti ketergantungan: fondasi data/keamanan → alur inti pelapor → petugas → tata kelola. SRS Bab VII sendiri menunda forum/sanksi/blacklist sampai aturan operasional dikunci.

### Fase 0 — Fondasi (prasyarat semua fase)
- Putuskan pendekatan konfigurasi (lihat K-01) dan struktur kode (pecah `index.html` menjadi modul).
- Buat `.env.example`/`config.js` contoh, `PANDUAN_DEPLOY.md` (yang hilang), dan hardening CDN (pin versi Tailwind/Lucide).
- Migrasi SQL **berurutan dan terversi** (`supabase/migrations/`), bukan menimpa `supabase_schema.sql`. Rekonsiliasi dengan ERD Lampiran A.
- **Perbaikan cepat sebelum Supabase siap:** sembunyikan laporan non-verified dari feed/peta, hapus koordinat acak (tampilkan hanya jika GPS/pin valid, atau area kecamatan), hentikan "Valid (+1)" anonim.

### Fase 1 — Auth, role, publik aman
- Supabase Auth email + password, verifikasi email, login/logout (FR-03–06, FR-27).
- Tabel `profiles` + `user_roles`; pengguna tidak bisa mengubah role sendiri (RLS + trigger). Fungsi helper `has_role()` (security definer).
- Tampilan publik hanya membaca **view** laporan `Verified` dengan kolom terbatas (FR-01, 02, 28).
- Gate di UI **dan** di RLS: kirim laporan hanya untuk email terverifikasi.

### Fase 2 — Pelaporan, status, riwayat
- Tabel `reports` (status enum 7 nilai), `report_histories`, trigger/fungsi transisi status yang menolak transisi tidak sah, riwayat otomatis (status lama/baru, aktor, waktu, alasan).
- Draft, kirim (Pending), batalkan saat Pending dengan alasan wajib, permintaan penarikan saat Under Review, revisi → kirim ulang.
- Riwayat laporan milik sendiri (FR-26).

### Fase 3 — Bukti privat
- Bucket Storage privat; tabel `evidences` (EV-01–06) dan `evidence_versions`; penggantian wajib alasan, versi lama tersimpan.
- Validasi tipe/ukuran, penanganan gagal unggah (laporan tidak boleh tampak lengkap jika upload gagal), signed URL berumur pendek untuk pelapor dan petugas.
- Aturan EV-01 sebagai bukti utama, EV-04 satu screenshot utuh, GetContact opsional. Panduan penyamaran data di form.

### Fase 4 — Verifier dan moderator
- Antrean verifier, pemeriksaan (`verification_reviews`, `verification_findings`), penanda duplikasi (bukan berdasar lokasi saja), minta revisi, rekomendasi.
- Under Review otomatis saat verifier mulai memeriksa; keputusan akhir oleh moderator dengan alasan.
- Keberatan atas Verified (`objections`), diperiksa verifier, diputuskan moderator.
- Disclaimer "Verified = peninjauan komunitas, bukan putusan hukum" di UI publik.

### Fase 5 — Forum, sanksi, banding, blacklist, audit (setelah aturan operasional dikunci)
- `decision_forums`, `forum_votes` (satu suara per peserta, konflik kepentingan dikecualikan, mayoritas, Admin Utama memutus seri).
- `sanctions` 4 tingkat, `appeals` (peninjau tidak terlibat di keputusan awal; sanksi tetap berlaku kecuali ditangguhkan Admin Utama), `blacklist_entries` (hash email, akses paling ketat), persetujuan blokir permanen.
- Audit log append-only (sesuai K-05). Operasi berhak istimewa lewat Edge Function.

### Fase 6 — Migrasi GAS dan penutupan
- Ekspor data Sheets (laporan, panti), petakan ke skema baru, tandai semua sebagai belum terverifikasi sampai diperiksa.
- Jalankan paralel; **GAS baru boleh dinonaktifkan** setelah: (a) data termigrasi dan divalidasi, (b) Fase 2–3 live, (c) tidak ada klien yang masih memakai `gasUrl`. Hapus UI "URL database" dan `downloadStandaloneHtml()`.
- Direktori panti: pindah ke tabel `shelters` (Fase 1 atau 6, lihat K-06).

### Pengujian (di setiap fase)
Tes RLS per role (anon, user, verifier, moderator, admin), tes transisi status (sah/tidak sah), tes akses Storage, tes kegagalan upload, skenario konflik kepentingan dan suara seri.

---

## 5. Asumsi yang dipakai bila tidak ada jawaban

- Menggunakan hanya URL + anon/publishable key di frontend; tidak ada `service_role` di repo.
- Laporan lama di LocalStorage dan Sheets dianggap **belum terverifikasi**.
- Bahasa UI tetap Indonesia santai seperti sekarang.
- Field di luar SRS (nominal kerugian, kategori modus, tingkat risiko, akun tersensor) **dipertahankan sebagai atribut opsional**, bukan dihapus, sampai Anda memutuskan.

---

## 6. Keputusan yang perlu dikonfirmasi

| ID | Pertanyaan | Rekomendasi |
|---|---|---|
| K-01 | Hosting statis GitHub Pages tidak punya env var. Pakai build step (Vite) atau `config.js` publik? | Vite + `.env`, deploy ke GitHub Pages lewat Actions. Alternatif: `config.js` apa adanya (kunci anon memang publik). |
| K-02 | Boleh memecah `index.html` menjadi modul? | Ya, bertahap; UI dan perilaku dijaga sama. |
| K-03 | Nasib field non-SRS: nominal kerugian, kategori modus, risk checker, tombol "Valid (+1)". | Pertahankan nominal/kategori; ganti "Valid (+1)" dengan konfirmasi terautentikasi satu-akun-satu-suara atau hapus, karena SRS tidak mengaturnya. |
| K-04 | Lokasi publik: kecamatan saja, titik presisi, atau titik dibulatkan? | **DIPUTUSKAN (pemilik proyek, 23 Nov 2026):** koordinat GPS/pin kejadian ditampilkan ke publik secara presisi, tanpa pembulatan, generalisasi, atau penyembunyian, karena fungsi utama aplikasi adalah memberi tahu driver titik order fiktif. Berlaku untuk laporan Verified yang memiliki koordinat asli. Laporan tanpa GPS/pin tidak ditampilkan di peta dan tidak diberi koordinat pengganti. Data pribadi lain (nama akun/WA, bukti mentah) tetap dibatasi sesuai FR-28 dan BR-05. |
| K-05 | Audit log harus immutable? Mekanismenya? | Tabel append-only (tanpa UPDATE/DELETE, trigger penolak) di Fase 5. |
| K-06 | Direktori panti tetap di aplikasi? Siapa yang boleh menambah? | Tetap; tulis hanya oleh moderator/admin. |
| K-07 | Batas ukuran dan format bukti, retensi (sekarang 30 hari lokal), batas waktu pemeriksaan/banding, kuorum forum, kriteria terukur Verified/Rejected. | Semua masih "perlu diputuskan" di SRS Bab VIII. Usulan awal: JPEG/PNG/WebP, 5 MB, retensi diputuskan sebelum Fase 3 live. |
| K-08 | Siapa Admin Utama pertama dan cara penunjukan role petugas. | Seed lewat SQL oleh pemilik proyek; selanjutnya lewat Edge Function khusus Admin Utama. |
| K-09 | Email blacklist disimpan sebagai hash. Perlu normalisasi (huruf kecil, alias `+`)? | Ya. |

---

## 7. Catatan tentang bahan masukan

- File master prompt **terpotong** di tengah kalimat pada bagian G ("…kecuali Admin Utama secara khusus mem…"). Saya memakai SRS FR-33 / B.3 untuk bagian itu. Bagian setelahnya (jika ada, mis. blacklist, aturan kerja, format keluaran) tidak terbaca. Mohon kirim ulang bila ada.
- Dua gambar ERD (A.1 dan A.2) sudah saya baca langsung dari dokumen. Kolom `reports` di ERD (`region, district, location_general, incident_type, story, incident_at, status`) sama dengan `supabase_schema.sql`, bukan dengan payload aplikasi.

## 8. Celah pada ERD SRS yang perlu ditambal saat membuat skema

ERD masih konseptual (SRS A.4), jadi berikut hal yang tidak tercakup tetapi dibutuhkan oleh kebutuhan fungsional. Ini bukan kebutuhan baru, hanya tabel/kolom pendukung agar FR/BR bisa dipenuhi:

| Celah di ERD | Kebutuhan terkait | Usulan |
|---|---|---|
| `role` sebagai kolom di `USERS` | FR-25, larangan user mengubah role sendiri | Tabel `user_roles` terpisah; RLS tanpa akses tulis untuk user. |
| Tidak ada koordinat dan aplikasi di `REPORTS` | Peta (FR-01), fitur peta yang ada | Tambah `lat/lng` (opsional), `app`. |
| Tidak ada entitas permintaan penarikan | FR-44, 45 | Tabel `withdrawal_requests` (alasan, keputusan moderator, waktu). |
| `OBJECTIONS` tanpa pemeriksa dan keputusan | FR-20, keberatan diperiksa verifier, diputuskan moderator | Tambah `reviewer_id`, `decision`, `decided_by`, `decision_reason`. |
| `DECISION_FORUMS` tanpa peserta dan konflik kepentingan | FR-21, 22, BR-10 | Tabel `forum_participants` (`conflict_declared`, alasan). |
| `FORUM_VOTES` tanpa batas suara ganda | Bagian F prompt | `UNIQUE (forum_id, voter_id)`. |
| Tidak ada tabel audit umum | 5.5 | `audit_logs` append-only. |
| `EVIDENCES.evidence_type` bebas | BR-62 | Enum EV-01…EV-06; aturan EV-04 satu screenshot. |
| `BLACKLIST_ENTRIES` menyimpan `user_id` | BR-14, FR-34 | Akses hanya petugas; hash email ternormalisasi. |
| Tidak ada tabel panti | Fitur yang ada | `shelters` (K-06). |
