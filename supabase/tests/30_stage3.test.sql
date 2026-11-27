-- Tahap 3: bukti, versi bukti, bucket privat, kebijakan Storage, RPC bukti, syarat EV-01.
-- Memakai fixture 10_stage1 (t.ua.. ) dan helper 20_stage2 (t.mk, t.save, t.rid, t.mk_status, t.ev).
-- HANYA UNTUK PENGUJIAN LOKAL.

select t.logout();
create or replace function t.obj(p_path text, p_owner uuid, p_size bigint default null, p_mime text default null) returns void
language sql security definer as $$
  insert into storage.objects (bucket_id, name, owner, metadata)
  values ('evidence', p_path, p_owner,
          case when p_size is null then null else jsonb_build_object('size', p_size, 'mimetype', p_mime) end)
  on conflict (bucket_id, name) do nothing
$$;
create or replace function t.sha(p text) returns text language sql immutable as $$ select repeat(p, 64) $$;

-- ===== 1. Bucket =====
select t.ok((select not public and file_size_limit = 5242880 and allowed_mime_types = array['image/jpeg','image/png','image/webp']
               from storage.buckets where id = 'evidence'), 'bucket evidence privat, 5 MB, hanya JPEG/PNG/WebP');
select t.ok((select count(*) from storage.buckets where id = 'evidence') = 1, 'bucket evidence ada tepat satu');

-- ===== 2. Constraint dan trigger (pemilik DB) =====
select t.mk('e_base', t.ua());
select t.ev(t.rid('e_base'));
select t.ok((select count(*) from public.evidences where report_id = t.rid('e_base') and evidence_type = 'EV-01') = 1, 'fixture EV-01 terpasang');
select t.throws($q$insert into public.evidences (report_id, evidence_type) values (t.rid('e_base'), 'EV-01')$q$, '23505', 'satu item per jenis bukti per laporan');
select t.throws($q$insert into public.evidences (report_id, evidence_type, declared_three_calls) values (t.rid('e_base'), 'EV-02', true)$q$, '23514', 'klaim tiga panggilan wajib disertai satu screenshot utuh (BR-66)');
select t.lives($q$insert into public.evidences (report_id, evidence_type, declared_three_calls, declared_single_screenshot) values (t.rid('e_base'), 'EV-02', true, true)$q$, 'tiga panggilan + satu screenshot utuh diterima');
select t.throws($q$insert into public.evidences (report_id, evidence_type) values (gen_random_uuid(), 'EV-03')$q$, 'bukti hanya dapat', 'evidences: laporan yatim ditolak (tak ada laporan = tak ada bukti)');
select t.throws($q$insert into public.evidences (report_id, evidence_type) values (t.rid('e_base'), 'EV-99')$q$, '22P02', 'enum jenis bukti menolak nilai salah');
select t.throws($q$update public.evidences set evidence_type = 'EV-04' where report_id = t.rid('e_base') and evidence_type = 'EV-02'$q$, 'tidak boleh diubah', 'jenis bukti tidak bisa diubah');
select t.throws($q$delete from public.evidences$q$, 'tidak boleh dihapus', 'evidences tidak bisa dihapus');
select t.throws($q$truncate public.evidences$q$, 'cannot truncate', 'evidences tidak bisa di-truncate (dijaga FK dan trigger)');
select t.throws($q$truncate public.evidence_versions$q$, 'TRUNCATE ditolak', 'evidence_versions tidak bisa di-truncate');

select (select id from public.evidences where report_id = t.rid('e_base') and evidence_type = 'EV-01') as ev1 \gset
select t.save('ev1', :'ev1'::uuid);
select t.throws(format($q$insert into public.evidence_versions (evidence_id, version_number, uploaded_by, private_file_path, mime_type, size_bytes, sha256) values (%L, 2, %L, %L, 'image/png', 10, %L)$q$, :'ev1', t.ua(), t.rid('e_base')::text || '/v2.png', t.sha('b')), '23514', 'versi >1 wajib beralasan');
select t.throws(format($q$insert into public.evidence_versions (evidence_id, version_number, uploaded_by, private_file_path, mime_type, size_bytes, sha256, replace_reason) values (%L, 3, %L, %L, 'image/png', 10, %L, 'x')$q$, :'ev1', t.ua(), t.rid('e_base')::text || '/v3.png', t.sha('b')), 'berurutan', 'nomor versi harus berurutan (tidak boleh loncat)');
select t.throws(format($q$insert into public.evidence_versions (evidence_id, version_number, uploaded_by, private_file_path, mime_type, size_bytes, sha256, replace_reason) values (%L, 2, %L, %L, 'image/png', 10, %L, 'x')$q$, :'ev1', t.ua(), t.rid('e_base')::text || '/v2.png', t.sha('b')), '23505', 'hanya satu versi current per bukti');
select t.throws(format($q$insert into public.evidence_versions (evidence_id, version_number, uploaded_by, private_file_path, mime_type, size_bytes, sha256) values (%L, 1, %L, %L, 'image/gif', 10, %L)$q$, :'ev1', t.ua(), t.rid('e_base')::text || '/g.gif', t.sha('b')), '23514', 'MIME di luar JPEG/PNG/WebP ditolak');
select t.throws(format($q$insert into public.evidence_versions (evidence_id, version_number, uploaded_by, private_file_path, mime_type, size_bytes, sha256, replace_reason) values (%L, 2, %L, %L, 'application/pdf', 10, %L, 'x')$q$, :'ev1', t.ua(), t.rid('e_base')::text || '/g.pdf', t.sha('b')), '23514', 'PDF ditolak');
select t.throws(format($q$insert into public.evidence_versions (evidence_id, version_number, uploaded_by, private_file_path, mime_type, size_bytes, sha256, replace_reason) values (%L, 2, %L, %L, 'image/png', 5242881, %L, 'x')$q$, :'ev1', t.ua(), t.rid('e_base')::text || '/big.png', t.sha('b')), '23514', 'ukuran > 5 MB ditolak');
select t.throws(format($q$insert into public.evidence_versions (evidence_id, version_number, uploaded_by, private_file_path, mime_type, size_bytes, sha256, replace_reason) values (%L, 2, %L, %L, 'image/png', 0, %L, 'x')$q$, :'ev1', t.ua(), t.rid('e_base')::text || '/z.png', t.sha('b')), '23514', 'ukuran 0 ditolak');
select t.throws(format($q$insert into public.evidence_versions (evidence_id, version_number, uploaded_by, private_file_path, mime_type, size_bytes, sha256, replace_reason) values (%L, 2, %L, %L, 'image/png', 10, 'XYZ', 'x')$q$, :'ev1', t.ua(), t.rid('e_base')::text || '/h.png', 'x'), '23514', 'sha256 tidak valid ditolak');
select t.throws(format($q$insert into public.evidence_versions (evidence_id, version_number, uploaded_by, private_file_path, mime_type, size_bytes, sha256, replace_reason) values (%L, 2, %L, '../etc/passwd', 'image/png', 10, %L, 'x')$q$, :'ev1', t.ua(), t.sha('b')), '23514', 'path traversal ditolak');
select t.throws(format($q$insert into public.evidence_versions (evidence_id, version_number, uploaded_by, private_file_path, mime_type, size_bytes, sha256, replace_reason) values (%L, 2, %L, %L, 'image/png', 10, %L, 'x')$q$, :'ev1', t.ua(), gen_random_uuid()::text || '/x.png', t.sha('b')), 'folder laporan', 'path di folder laporan lain ditolak');
select t.throws(format($q$insert into public.evidence_versions (evidence_id, version_number, uploaded_by, private_file_path, mime_type, size_bytes, sha256) values (%L, 1, %L, %L, 'image/png', 10, %L)$q$, gen_random_uuid(), t.ua(), t.rid('e_base')::text || '/q.png', t.sha('b')), 'versi bukti hanya', 'versi tanpa bukti induk ditolak');
select t.throws($q$update public.evidence_versions set sha256 = repeat('c', 64)$q$, 'append-only', 'versi bukti tidak bisa diedit');
select t.throws($q$update public.evidence_versions set version_status = 'superseded'$q$, 'append-only', 'superseded hanya lewat RPC (tanpa GUC ditolak)');
select t.throws($q$delete from public.evidence_versions$q$, 'append-only', 'versi bukti tidak bisa dihapus');
select t.ok((select count(*) from pg_indexes where indexname in ('evidence_versions_one_current','evidences_report_idx','evidence_versions_evidence_idx')) = 3, 'indeks Tahap 3 ada');

-- Bukti tidak bisa ditambah ke laporan non-draft
select t.mk_status('pending', t.ua()) as pend \gset
select t.throws(format($q$insert into public.evidences (report_id, evidence_type) values (%L, 'EV-03')$q$, :'pend'), 'draft atau needs_revision', 'tidak ada bukti baru pada laporan Pending (pemilik DB)');

-- ===== 3. Hak akses =====
select t.ok(not has_table_privilege('authenticated', 'public.evidences', 'insert,update,delete,truncate')
        and not has_table_privilege('authenticated', 'public.evidence_versions', 'insert,update,delete,truncate')
        and not has_table_privilege('anon', 'public.evidences', 'select')
        and not has_table_privilege('anon', 'public.evidence_versions', 'select')
        and not has_table_privilege('service_role', 'public.evidences', 'insert,update,delete')
        and not has_table_privilege('service_role', 'public.evidence_versions', 'insert,update,delete')
        and has_table_privilege('authenticated', 'public.evidences', 'select'),
        'bukti: API hanya select; anon tak ada akses; service_role tak bisa menulis');
select t.ok(has_function_privilege('authenticated', 'public.add_evidence(uuid,public.evidence_type,text,text,bigint,text,text,boolean,boolean)', 'execute')
        and has_function_privilege('authenticated', 'public.replace_evidence_version(uuid,text,text,bigint,text,text,text)', 'execute')
        and not has_function_privilege('anon', 'public.add_evidence(uuid,public.evidence_type,text,text,bigint,text,text,boolean,boolean)', 'execute')
        and not has_function_privilege('anon', 'public.replace_evidence_version(uuid,text,text,bigint,text,text,text)', 'execute')
        and not has_function_privilege('authenticated', 'private.evidence_register(uuid,uuid,text,text,bigint,text,text,text)', 'execute'),
        'RPC bukti hanya authenticated; fungsi internal tertutup');

-- ===== 4. Alur pemilik via API + Storage =====
select t.mk('s_a', t.ua());
select t.mk('s_b', t.ub());
select t.login(t.ua());
select t.lives(format($q$insert into storage.objects (bucket_id, name) values ('evidence', %L)$q$, t.rid('s_a')::text || '/ktp.png'), 'pemilik dapat mengunggah ke folder laporan drafnya');
select t.throws(format($q$insert into storage.objects (bucket_id, name) values ('evidence', %L)$q$, t.rid('s_b')::text || '/x.png'), '42501', 'tidak bisa mengunggah ke folder laporan orang lain');
select t.throws($q$insert into storage.objects (bucket_id, name) values ('evidence', 'bebas.png')$q$, '42501', 'unggahan di luar folder laporan ditolak');
select t.throws(format($q$insert into storage.objects (bucket_id, name) values ('evidence', %L)$q$, t.rid('s_a')::text || '/../x.png'), '42501', 'path traversal ditolak di kebijakan Storage');
select t.throws(format($q$insert into storage.objects (bucket_id, name) values ('other', %L)$q$, t.rid('s_a')::text || '/x.png'), '42501', 'bucket lain tidak tercakup kebijakan evidence');

select t.throws(format($q$select public.add_evidence(%L, 'EV-01', %L, 'image/png', 1000, %L)$q$, t.rid('s_a'), t.rid('s_a')::text || '/belum.png', t.sha('d')), 'file_not_uploaded', 'RPC menolak file yang belum ada di Storage');
select t.throws(format($q$select public.add_evidence(%L, 'EV-01', %L, 'image/png', 1000, %L)$q$, t.rid('s_a'), t.rid('s_b')::text || '/ktp.png', t.sha('d')), 'invalid_path', 'RPC menolak path di folder laporan lain');
select t.throws(format($q$select public.add_evidence(%L, 'EV-01', 'sembarang', 'image/png', 1000, %L)$q$, t.rid('s_a'), t.sha('d')), 'invalid_path', 'RPC menolak path tidak valid');

select t.throws(format($q$select public.submit_report(%L)$q$, t.rid('s_a')), 'report_incomplete', 'kirim tanpa bukti ditolak');
select t.ok(true, 'placeholder');
select t.lives(format($q$select public.add_evidence(%L, 'EV-01', %L, 'image/png', 1000, %L, 'Screenshot utama', false, false)$q$, t.rid('s_a'), t.rid('s_a')::text || '/ktp.png', t.sha('d')), 'pemilik mendaftarkan EV-01 dari file yang sudah diunggah');
select (select id from public.evidences where report_id = t.rid('s_a') and evidence_type = 'EV-01') as eva \gset
select t.save('ev_s_a', :'eva'::uuid);
select t.ok(t.count(format('select 1 from public.evidences e join public.evidence_versions v on v.evidence_id = e.id where e.report_id = %L and e.evidence_type = ''EV-01'' and v.version_number = 1 and v.version_status = ''current'' and v.uploaded_by = %L and v.sha256 = %L', t.rid('s_a'), t.ua(), t.sha('d'))) = 1,
            'versi 1 current tercatat lengkap (pengunggah, sha256)');
select t.throws(format($q$select public.add_evidence(%L, 'EV-01', %L, 'image/png', 1000, %L)$q$, t.rid('s_a'), t.rid('s_a')::text || '/ktp.png', t.sha('d')), '23505', 'EV-01 ganda ditolak (gunakan ganti versi)');

-- file diunggah pihak lain / ukuran tidak cocok
select t.logout();
select t.obj(t.rid('s_a')::text || '/orang-lain.png', t.ub(), 500, 'image/png');
select t.obj(t.rid('s_a')::text || '/ukuran.png', t.ua(), 500, 'image/png');
select t.login(t.ua());
select t.throws(format($q$select public.add_evidence(%L, 'EV-02', %L, 'image/png', 500, %L)$q$, t.rid('s_a'), t.rid('s_a')::text || '/orang-lain.png', t.sha('e')), 'forbidden', 'file yang diunggah orang lain tidak bisa didaftarkan');
select t.throws(format($q$select public.add_evidence(%L, 'EV-02', %L, 'image/png', 9999, %L)$q$, t.rid('s_a'), t.rid('s_a')::text || '/ukuran.png', t.sha('e')), 'metadata_mismatch', 'ukuran yang diklaim harus sama dengan file di Storage');
select t.throws(format($q$select public.add_evidence(%L, 'EV-02', %L, 'image/webp', 500, %L)$q$, t.rid('s_a'), t.rid('s_a')::text || '/ukuran.png', t.sha('e')), 'metadata_mismatch', 'tipe yang diklaim harus sama dengan file di Storage');
select t.throws(format($q$select public.add_evidence(%L, 'EV-02', %L, 'image/png', 500, 'bukan-hash')$q$, t.rid('s_a'), t.rid('s_a')::text || '/ukuran.png'), '23514', 'sha256 tidak valid ditolak di RPC');
select t.throws(format($q$select public.add_evidence(%L, 'EV-02', %L, 'image/png', 500, %L, null, true, false)$q$, t.rid('s_a'), t.rid('s_a')::text || '/ukuran.png', t.sha('e')), '23514', 'RPC: tiga panggilan tanpa satu screenshot utuh ditolak');
select t.lives(format($q$select public.add_evidence(%L, 'EV-02', %L, 'image/png', 500, %L, null, true, true)$q$, t.rid('s_a'), t.rid('s_a')::text || '/ukuran.png', t.sha('e')), 'EV-02 dengan pernyataan tiga panggilan + satu screenshot diterima');

-- Pengguna lain
select t.login(t.ub());
select t.throws(format($q$select public.add_evidence(%L, 'EV-03', %L, 'image/png', 1, %L)$q$, t.rid('s_a'), t.rid('s_a')::text || '/x.png', t.sha('f')), 'report_not_found', 'user B tidak bisa menambah bukti ke laporan user A');
select t.ok(t.count('select 1 from public.evidences') = 0 and t.count('select 1 from public.evidence_versions') = 0, 'user B tidak melihat metadata bukti user A');
select t.ok(t.count('select 1 from storage.objects') = 0, 'user B tidak melihat file bukti user A');
select t.throws(format($q$select public.replace_evidence_version(%L, %L, 'image/png', 1, %L, 'iseng')$q$, t.rid('ev1'), t.rid('s_a')::text || '/x.png', t.sha('f')), 'evidence_not_found', 'user B tidak bisa mengganti versi bukti user A');
select t.anon();
select t.throws('select 1 from public.evidences', '42501', 'anon ditolak membaca evidences');
select t.throws('select 1 from public.evidence_versions', '42501', 'anon ditolak membaca evidence_versions');
select t.ok(t.count('select 1 from storage.objects') = 0, 'anon tidak melihat file di bucket evidence');
select t.throws(format($q$insert into storage.objects (bucket_id, name) values ('evidence', %L)$q$, t.rid('s_a')::text || '/anon.png'), '42501', 'anon tidak bisa mengunggah');
select t.throws(format($q$select public.add_evidence(%L, 'EV-03', 'x', 'image/png', 1, %L)$q$, t.rid('s_a'), t.sha('f')), '42501', 'anon tidak bisa memanggil add_evidence');

-- Pemilik: tidak bisa mengubah/menghapus file lewat API
select t.login(t.ua());
select t.ok(t.count(format('select 1 from storage.objects where name like %L', t.rid('s_a')::text || '/%')) >= 1, 'pemilik melihat file buktinya');
select t.ok(t.affected(format($q$update storage.objects set name = 'x/y.png' where name = %L$q$, t.rid('s_a')::text || '/ktp.png')) = 0, 'pemilik tidak bisa mengubah objek Storage');
select t.ok(t.affected(format($q$delete from storage.objects where name = %L$q$, t.rid('s_a')::text || '/ktp.png')) = 0, 'pemilik tidak bisa menghapus objek Storage');
select t.throws(format($q$insert into public.evidences (report_id, evidence_type) values (%L, 'EV-04')$q$, t.rid('s_a')), '42501', 'pemilik tidak bisa menyisipkan evidences langsung (hanya RPC)');
select t.throws($q$update public.evidence_versions set description = 'x'$q$, '42501', 'pemilik tidak bisa mengedit versi langsung');

-- ===== 5. Kirim laporan dengan EV-01, lalu terkunci =====
select t.lives(format($q$select public.submit_report(%L)$q$, t.rid('s_a')), 'dengan EV-01 laporan dapat dikirim');
select t.throws(format($q$insert into storage.objects (bucket_id, name) values ('evidence', %L)$q$, t.rid('s_a')::text || '/terlambat.png'), '42501', 'unggahan baru ditolak setelah laporan Pending');
select t.throws(format($q$select public.add_evidence(%L, 'EV-04', %L, 'image/png', 500, %L)$q$, t.rid('s_a'), t.rid('s_a')::text || '/ukuran.png', t.sha('e')), 'report_locked', 'tambah bukti ditolak saat Pending');
select t.throws(format($q$select public.replace_evidence_version(%L, %L, 'image/png', 500, %L, 'alasan')$q$, t.rid('ev_s_a'), t.rid('s_a')::text || '/ukuran.png', t.sha('e')), 'report_locked', 'ganti versi ditolak saat Pending');
select t.ok(t.count(format('select 1 from storage.objects where name = %L', t.rid('s_a')::text || '/ktp.png')) = 1, 'pemilik tetap bisa membuka file saat Pending');

-- ===== 6. Visibilitas petugas (D5) =====
select t.logout();
select t.mk('s_draft', t.ua());
select t.obj(t.rid('s_draft')::text || '/d.png', t.ua(), 100, 'image/png');
select t.login(t.uv());
select t.ok(t.count(format('select 1 from public.evidences where report_id = %L', t.rid('s_a'))) = 2, 'verifier melihat metadata bukti laporan non-draft');
select t.ok(t.count(format('select 1 from storage.objects where name like %L', t.rid('s_a')::text || '/%')) = 0, 'verifier BELUM bisa membuka file (D5: menunggu start_review di Tahap 4)');
select t.login(t.um());
select t.ok(t.count(format('select 1 from storage.objects where name like %L', t.rid('s_a')::text || '/%')) >= 1, 'moderator melihat file bukti laporan non-draft');
select t.ok(t.count(format('select 1 from storage.objects where name like %L', t.rid('s_draft')::text || '/%')) = 0
        and t.count(format('select 1 from public.evidences where report_id = %L', t.rid('s_draft'))) = 0, 'moderator tidak melihat bukti laporan draft');
select t.login(t.uad());
select t.ok(t.count(format('select 1 from storage.objects where name like %L', t.rid('s_a')::text || '/%')) >= 1, 'admin utama melihat file bukti laporan non-draft');
select t.ok(t.count(format('select 1 from storage.objects where name like %L', t.rid('s_draft')::text || '/%')) = 0, 'admin utama tidak melihat bukti laporan draft');
select t.throws(format($q$select public.add_evidence(%L, 'EV-05', %L, 'image/png', 1, %L)$q$, t.rid('s_a'), t.rid('s_a')::text || '/x.png', t.sha('f')), 'report_not_found', 'petugas tidak bisa menambah bukti atas nama pelapor');
select t.throws(format($q$insert into storage.objects (bucket_id, name) values ('evidence', %L)$q$, t.rid('s_a')::text || '/petugas.png'), '42501', 'petugas tidak bisa mengunggah ke laporan orang lain');
select t.logout();

-- ===== 7. Needs Revision: ganti versi =====
select t.mk_status('needs_revision', t.ua()) as nr3 \gset
select t.save('nr3', :'nr3'::uuid);
select t.ev(:'nr3'::uuid);
select (select id from public.evidences where report_id = :'nr3'::uuid) as nrev \gset
select t.save('nrev', :'nrev'::uuid);
select t.obj(:'nr3' || '/v2.png', t.ua(), 700, 'image/webp');
select t.login(t.ua());
select t.throws(format($q$select public.replace_evidence_version(%L, %L, 'image/webp', 700, %L, null)$q$, t.rid('nrev'), :'nr3' || '/v2.png', t.sha('9')), 'reason_required', 'ganti versi wajib beralasan');
select t.throws(format($q$select public.replace_evidence_version(%L, %L, 'image/webp', 700, %L, '   ')$q$, t.rid('nrev'), :'nr3' || '/v2.png', t.sha('9')), 'reason_required', 'alasan kosong ditolak');
select t.throws(format($q$select public.replace_evidence_version(%L, %L, 'image/webp', 700, %L, 'Foto lebih jelas')$q$, t.rid('nrev'), :'nr3' || '/belum-ada.png', t.sha('9')), 'file_not_uploaded', 'ganti versi butuh file yang sudah diunggah');
select t.lives(format($q$select public.replace_evidence_version(%L, %L, 'image/webp', 700, %L, 'Foto lebih jelas')$q$, t.rid('nrev'), :'nr3' || '/v2.png', t.sha('9')), 'pemilik mengganti versi bukti saat Needs Revision');
select t.ok(t.count(format('select 1 from public.evidence_versions where evidence_id = %L', t.rid('nrev'))) = 2
        and t.count(format('select 1 from public.evidence_versions where evidence_id = %L and version_status = ''current'' and version_number = 2 and replace_reason = ''Foto lebih jelas''', t.rid('nrev'))) = 1
        and t.count(format('select 1 from public.evidence_versions where evidence_id = %L and version_status = ''superseded'' and version_number = 1', t.rid('nrev'))) = 1,
        'versi 2 current, versi 1 superseded tetap tersimpan, alasan tercatat');
select t.ok(t.count(format('select 1 from storage.objects where name = %L', :'nr3' || '/ev01.png')) = 0, 'catatan: file versi 1 hanya ada bila diunggah (fixture langsung tidak punya objek)');
select t.lives(format($q$select public.submit_report(%L)$q$, :'nr3'), 'kirim ulang setelah ganti bukti berhasil (EV-01 current ada)');
select t.logout();
select t.ok((select count(*) from public.audit_logs where action = 'evidence.replaced' and object_id = t.rid('nrev')::text
              and reason = 'Foto lebih jelas' and (new_data ->> 'version_number')::int = 2 and (old_data ->> 'version_number')::int = 1) = 1,
            'audit evidence.replaced: versi lama/baru dan alasan');
select t.ok((select count(*) from public.audit_logs where action = 'evidence.added') >= 1, 'audit evidence.added tercatat untuk bukti yang didaftarkan lewat RPC');
select t.ok((select count(*) from public.audit_logs where action = 'evidence.added' and new_data ->> 'sha256' = t.sha('d') and new_data ->> 'evidence_type' = 'EV-01') = 1,
            'audit evidence.added memuat jenis dan sha256');

-- ===== 8. EV-01 wajib juga saat kirim ulang =====
select t.mk_status('needs_revision', t.ub()) as nr4 \gset
select t.login(t.ub());
select t.throws(format($q$select public.submit_report(%L)$q$, :'nr4'), 'evidence:EV-01', 'kirim ulang tanpa EV-01 ditolak (pesan menyebut evidence:EV-01)');

-- Rantai audit utuh
select t.login(t.uad());
select t.ok((select ok from public.verify_audit_chain()), 'rantai audit utuh setelah uji Tahap 3');
select t.logout();
select t.summary();
