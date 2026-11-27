-- Tahap 4: pemeriksaan verifier, temuan, duplikasi, penarikan, keberatan, konflik kepentingan.
-- Memakai fixture Tahap 1-3 (t.ua.., t.mk, t.ev, t.obj, t.save/rid, t.mk_status).
-- HANYA UNTUK PENGUJIAN LOKAL.
select t.logout();

-- Fixture tambahan: verifier ke-2, moderator ke-2, pengguna C.
insert into auth.users (id, email, email_confirmed_at) values
  ('00000000-0000-0000-0000-0000000000b1', 'v2@example.test', now()),
  ('00000000-0000-0000-0000-0000000000b2', 'm2@example.test', now()),
  ('00000000-0000-0000-0000-0000000000b3', 'c@example.test', now())
on conflict (id) do nothing;
insert into public.user_roles (user_id, role, reason) values
  ('00000000-0000-0000-0000-0000000000b1', 'verifier', 'fixture uji'),
  ('00000000-0000-0000-0000-0000000000b2', 'moderator', 'fixture uji')
on conflict do nothing;
create or replace function t.v2() returns uuid language sql immutable as $$ select '00000000-0000-0000-0000-0000000000b1'::uuid $$;
create or replace function t.m2() returns uuid language sql immutable as $$ select '00000000-0000-0000-0000-0000000000b2'::uuid $$;
create or replace function t.uc() returns uuid language sql immutable as $$ select '00000000-0000-0000-0000-0000000000b3'::uuid $$;

-- Laporan Pending lengkap dengan EV-01 dan objek file di Storage.
create or replace function t.pend(p_name text, p_owner uuid) returns uuid language plpgsql security definer as $$
declare v uuid;
begin
  v := t.mk(p_name, p_owner);
  perform t.ev(v);
  perform t.obj(v::text || '/ev01.png', p_owner, 1000, 'image/png');
  perform private.transition_report(v, 'pending', 'fixture kirim', 'owner', 'submitted');
  return v;
end $$;

-- ===== 1. Struktur dan hak =====
select t.ok(not has_table_privilege('authenticated', 'public.verification_reviews', 'insert,delete,truncate')
        and not has_column_privilege('authenticated', 'public.verification_reviews', 'result', 'update')
        and not has_column_privilege('authenticated', 'public.verification_reviews', 'reviewed_at', 'update')
        and not has_column_privilege('authenticated', 'public.verification_reviews', 'verifier_id', 'update')
        and has_column_privilege('authenticated', 'public.verification_reviews', 'notes', 'update'),
        'reviews: API hanya boleh mengubah notes; tanpa insert/delete');
select t.ok(not has_table_privilege('authenticated', 'public.objections', 'insert,update,delete,truncate')
        and not has_table_privilege('authenticated', 'public.withdrawal_requests', 'insert,update,delete,truncate')
        and not has_table_privilege('authenticated', 'public.conflict_declarations', 'insert,update,delete,truncate')
        and not has_table_privilege('authenticated', 'public.verification_findings', 'delete,truncate')
        and not has_table_privilege('authenticated', 'public.duplicate_indications', 'delete,truncate'),
        'objections/withdrawals/conflicts hanya lewat RPC; temuan tanpa delete');
select t.ok(not has_table_privilege('anon', 'public.verification_reviews', 'select')
        and not has_table_privilege('anon', 'public.objections', 'select')
        and not has_table_privilege('anon', 'public.withdrawal_requests', 'select')
        and not has_table_privilege('anon', 'public.conflict_declarations', 'select')
        and not has_table_privilege('service_role', 'public.objections', 'insert,update,delete')
        and not has_table_privilege('service_role', 'public.verification_reviews', 'insert,update,delete'),
        'anon tidak punya akses; service_role tidak bisa menulis');
select t.ok(not has_function_privilege('anon', 'public.start_review(uuid)', 'execute')
        and not has_function_privilege('anon', 'public.decide_report(uuid,text,text,uuid)', 'execute')
        and not has_function_privilege('anon', 'public.file_objection(uuid,text)', 'execute')
        and has_function_privilege('authenticated', 'public.start_review(uuid)', 'execute')
        and not has_function_privilege('authenticated', 'private.lock_report_for_staff(uuid,public.app_role[])', 'execute'),
        'RPC petugas hanya authenticated; fungsi internal tertutup');

-- ===== 2. Constraint (pemilik DB) =====
select t.pend('p0', t.ua());
select t.pend('p0b', t.ub());
select t.mk('d0', t.ua());
select private.transition_report(t.rid('p0'), 'under_review', 'fixture', 'verifier', 'review_started');
insert into public.verification_reviews (report_id, verifier_id) values (t.rid('p0'), t.uv()) returning id as r0 \gset
select t.save('r0', :'r0'::uuid);
select t.throws(format($q$insert into public.verification_reviews (report_id, verifier_id) values (%L, %L)$q$, t.rid('p0'), t.v2()), '23505', 'hanya satu review in_progress per laporan');
select t.throws(format($q$insert into public.verification_reviews (report_id, verifier_id, result, reviewed_at) values (%L, %L, 'recommend_verified', now())$q$, t.rid('p0b'), t.uv()), 'in_progress', 'review baru tidak boleh langsung selesai');
select t.throws(format($q$insert into public.verification_reviews (report_id, verifier_id, result) values (%L, %L, 'ngawur')$q$, t.rid('p0b'), t.uv()), '23514', 'hasil review di luar daftar ditolak');
select t.throws($q$insert into public.verification_reviews (report_id, verifier_id) values (gen_random_uuid(), t.uv())$q$, 'foreign key', 'review: FK ke laporan');
select t.throws(format($q$update public.verification_reviews set result = 'recommend_verified', reviewed_at = now() where id = %L$q$, :'r0'), 'submit_review', 'hasil review tidak bisa diubah langsung (pemilik DB)');
select t.throws(format($q$update public.verification_reviews set verifier_id = %L where id = %L$q$, t.v2(), :'r0'), 'identitas', 'verifier_id review tidak bisa diganti');
select t.throws($q$delete from public.verification_reviews$q$, 'permanen', 'review tidak bisa dihapus');
select t.throws($q$truncate public.verification_reviews$q$, 'cannot truncate', 'review tidak bisa di-truncate');

select t.throws(format($q$insert into public.verification_findings (review_id, finding_type, description, assessment) values (%L, 'location', 'x', 'bebas')$q$, :'r0'), '23514', 'assessment di luar daftar ditolak');
select t.throws(format($q$insert into public.verification_findings (review_id, finding_type, description, assessment) values (%L, 'apa-saja', 'x', 'supports')$q$, :'r0'), '23514', 'finding_type di luar daftar ditolak');
select t.throws(format($q$insert into public.verification_findings (review_id, finding_type, description, assessment) values (%L, 'location', '  ', 'supports')$q$, :'r0'), '23514', 'deskripsi temuan wajib');
select t.throws($q$insert into public.verification_findings (review_id, finding_type, description, assessment) values (gen_random_uuid(), 'location', 'x', 'supports')$q$, 'in_progress', 'temuan tanpa review induk ditolak');
select t.lives(format($q$insert into public.verification_findings (review_id, evidence_type, finding_type, description, assessment) values (%L, 'EV-01', 'consistency', 'Tangkapan layar konsisten dengan kronologi', 'supports')$q$, :'r0'), 'temuan valid diterima');
select t.throws($q$delete from public.verification_findings$q$, 'permanen', 'temuan tidak bisa dihapus');

select t.throws(format($q$insert into public.duplicate_indications (report_id, duplicate_of_id, review_id, basis) values (%L, %L, %L, array['location'])$q$, t.rid('p0'), t.rid('p0b'), :'r0'), '23514', 'duplikasi dengan dasar lokasi saja ditolak (BR-08)');
select t.throws(format($q$insert into public.duplicate_indications (report_id, duplicate_of_id, review_id, basis) values (%L, %L, %L, array[]::text[])$q$, t.rid('p0'), t.rid('p0b'), :'r0'), '23514', 'dasar duplikasi kosong ditolak');
select t.throws(format($q$insert into public.duplicate_indications (report_id, duplicate_of_id, review_id, basis) values (%L, %L, %L, array['mood'])$q$, t.rid('p0'), t.rid('p0b'), :'r0'), '23514', 'dasar duplikasi di luar daftar ditolak');
select t.throws(format($q$insert into public.duplicate_indications (report_id, duplicate_of_id, review_id, basis) values (%L, %L, %L, array['time'])$q$, t.rid('p0'), t.rid('p0'), :'r0'), '23514', 'laporan tidak bisa duplikat dirinya');
select t.throws(format($q$insert into public.duplicate_indications (report_id, duplicate_of_id, review_id, basis) values (%L, %L, %L, array['time'])$q$, t.rid('p0'), t.rid('d0'), :'r0'), 'pembanding', 'pembanding berstatus draft ditolak');
select t.throws(format($q$insert into public.duplicate_indications (report_id, duplicate_of_id, review_id, basis) values (%L, %L, %L, array['time'])$q$, t.rid('p0b'), t.rid('p0'), :'r0'), 'diperiksa', 'duplikasi harus untuk laporan yang sedang diperiksa');
select t.lives(format($q$insert into public.duplicate_indications (report_id, duplicate_of_id, review_id, basis, notes) values (%L, %L, %L, array['location','time'], 'Lokasi dan jam sama')$q$, t.rid('p0'), t.rid('p0b'), :'r0'), 'duplikasi lokasi+waktu diterima');
select t.throws($q$delete from public.duplicate_indications$q$, 'permanen', 'duplikasi tidak bisa dihapus');

select t.throws(format($q$insert into public.objections (report_id, user_id, reason, status) values (%L, %L, 'x', 'accepted')$q$, t.rid('p0'), t.ub()), '23514', 'objection: status keputusan tanpa data keputusan ditolak');
select t.throws(format($q$insert into public.objections (report_id, user_id, reason) values (%L, %L, '  ')$q$, t.rid('p0'), t.ub()), '23514', 'alasan keberatan wajib');
select t.throws($q$insert into public.objections (report_id, user_id, reason) values (gen_random_uuid(), t.ub(), 'x')$q$, 'foreign key', 'objection: FK ke laporan');
select t.throws(format($q$insert into public.withdrawal_requests (report_id, requested_by, reason, status) values (%L, %L, 'x', 'approved')$q$, t.rid('p0'), t.ua()), '23514', 'withdrawal: status keputusan tanpa data keputusan ditolak');
select t.throws(format($q$insert into public.conflict_declarations (report_id, staff_id, reason) values (%L, %L, ' ')$q$, t.rid('p0'), t.uv()), '23514', 'alasan konflik wajib');
insert into public.conflict_declarations (report_id, staff_id, reason) values (t.rid('p0b'), t.uv(), 'fixture append-only');
select t.throws($q$update public.conflict_declarations set reason = 'x'$q$, 'append-only', 'conflict_declarations append-only (UPDATE)');
select t.throws($q$delete from public.conflict_declarations$q$, 'append-only', 'conflict_declarations append-only (DELETE)');
select t.throws($q$truncate public.objections$q$, 'cannot truncate', 'objections tidak bisa di-truncate (dijaga FK dan trigger)');

-- Tutup review p0 secara fixture agar alur RPC di bawah berjalan dari awal
select set_config('app.review_close', 'on', false);
update public.verification_reviews set result = 'abandoned', reviewed_at = now() where id = :'r0'::uuid;
select set_config('app.review_close', 'off', false);
select t.throws(format($q$insert into public.verification_findings (review_id, finding_type, description, assessment) values (%L, 'other', 'x', 'supports')$q$, :'r0'), 'in_progress', 'temuan tidak bisa ditulis ke review yang sudah selesai');
select t.throws(format($q$update public.verification_reviews set notes = 'x' where id = %L$q$, :'r0'), 'sudah selesai', 'review selesai tidak bisa diubah');

-- ===== 3. Alur verifikasi lewat RPC =====
select t.pend('flow', t.ua());
select t.obj(t.rid('flow')::text || '/ev01.png', t.ua(), 1000, 'image/png');
select t.login(t.ub());
select t.throws(format($q$select public.start_review(%L)$q$, t.rid('flow')), 'forbidden', 'pengguna biasa tidak bisa start_review');
select t.login(t.um());
select t.throws(format($q$select public.start_review(%L)$q$, t.rid('flow')), 'forbidden', 'moderator tidak bisa start_review');
select t.login(t.uad());
select t.throws(format($q$select public.start_review(%L)$q$, t.rid('flow')), 'forbidden', 'admin utama tidak otomatis verifier (D6)');
select t.anon();
select t.throws(format($q$select public.start_review(%L)$q$, t.rid('flow')), '42501', 'anon tidak bisa start_review');
select t.login(t.uv());
select t.throws(format($q$select public.start_review(%L)$q$, t.rid('d0')), 'report_not_found', 'draf tidak bisa diperiksa');
select t.ok(t.count(format('select 1 from storage.objects where name like %L', t.rid('flow')::text || '/%')) = 0, 'sebelum start_review verifier tidak bisa membuka file (D5)');
select public.start_review(t.rid('flow')) as rf \gset
select t.save('rf', :'rf'::uuid);
select t.ok((select status = 'under_review' from public.reports where id = t.rid('flow')), 'start_review: Pending -> Under Review');
select t.ok(t.count(format('select 1 from public.report_histories where report_id = %L and action = ''review_started'' and actor_role = ''verifier'' and actor_id = %L', t.rid('flow'), t.uv())) = 1, 'riwayat review_started tercatat');
select t.ok(t.count(format('select 1 from storage.objects where name like %L', t.rid('flow')::text || '/%')) = 1, 'setelah start_review verifier dapat membuka file bukti (D5)');
select t.throws(format($q$select public.start_review(%L)$q$, t.rid('flow')), 'review_in_progress', 'review kedua ditolak selama ada yang berjalan');
select t.throws(format($q$update public.verification_reviews set result = 'recommend_verified' where id = %L$q$, t.rid('rf')), '42501', 'verifier tidak bisa mengisi hasil langsung');
select t.ok(t.affected(format($q$update public.verification_reviews set notes = 'Catatan awal' where id = %L$q$, t.rid('rf'))) = 1, 'verifier dapat menulis catatan review sendiri');
select t.lives(format($q$insert into public.verification_findings (review_id, evidence_type, finding_type, description, assessment) values (%L, 'EV-01', 'consistency', 'Konsisten', 'supports')$q$, t.rid('rf')), 'verifier menulis temuan di review sendiri');
select t.lives(format($q$insert into public.duplicate_indications (report_id, duplicate_of_id, review_id, basis) values (%L, %L, %L, array['time','story'])$q$, t.rid('flow'), t.rid('p0b'), t.rid('rf')), 'verifier mencatat indikasi duplikasi');
select t.throws(format($q$insert into public.duplicate_indications (report_id, duplicate_of_id, review_id, basis) values (%L, %L, %L, array['location'])$q$, t.rid('flow'), t.rid('p0b'), t.rid('rf')), '23514', 'API: dasar lokasi saja ditolak');
select t.throws(format($q$delete from public.verification_findings where review_id = %L$q$, t.rid('rf')), '42501', 'verifier tidak bisa menghapus temuan');
select t.ok(t.affected(format($q$update public.verification_findings set description = 'Konsisten, diperbarui' where review_id = %L$q$, t.rid('rf'))) = 1, 'verifier dapat memperbarui temuan saat in_progress');

-- Verifier lain / peran lain
select t.login(t.v2());
select t.ok(t.count(format('select 1 from public.verification_reviews where id = %L', t.rid('rf'))) = 0, 'verifier lain tidak melihat review milik verifier ini');
select t.ok(t.count(format('select 1 from public.verification_findings where review_id = %L', t.rid('rf'))) = 0, 'verifier lain tidak melihat temuan');
select t.ok(t.count(format('select 1 from storage.objects where name like %L', t.rid('flow')::text || '/%')) = 0, 'verifier lain (belum start_review) tidak bisa membuka file');
select t.throws(format($q$insert into public.verification_findings (review_id, finding_type, description, assessment) values (%L, 'other', 'x', 'supports')$q$, t.rid('rf')), 'in_progress', 'verifier lain tidak bisa menulis temuan di review orang (ditolak sebelum RLS)');
select t.ok(t.affected(format($q$update public.verification_reviews set notes = 'dibajak' where id = %L$q$, t.rid('rf'))) = 0, 'verifier lain tidak bisa mengubah catatan');
select t.throws(format($q$select public.submit_review(%L, 'recommend_verified', 'x')$q$, t.rid('rf')), 'review_not_found', 'verifier lain tidak bisa mengirim rekomendasi');
select t.throws(format($q$select public.return_for_revision(%L, 'x')$q$, t.rid('flow')), 'review_not_found', 'verifier tanpa review tidak bisa mengembalikan laporan');
select t.login(t.um());
select t.ok(t.count(format('select 1 from public.verification_reviews where id = %L', t.rid('rf'))) = 1
        and t.count(format('select 1 from public.verification_findings where review_id = %L', t.rid('rf'))) = 1, 'moderator melihat review dan temuan');
select t.throws(format($q$insert into public.verification_findings (review_id, finding_type, description, assessment) values (%L, 'other', 'x', 'supports')$q$, t.rid('rf')), '42501', 'moderator tidak bisa menulis temuan');
select t.throws(format($q$select public.decide_report(%L, 'verified', 'tanpa rekomendasi')$q$, t.rid('flow')), 'recommendation_required', 'moderator tidak bisa memutuskan sebelum ada rekomendasi verifier (D1)');
select t.login(t.ua());
select t.ok(t.count(format('select 1 from public.verification_reviews where report_id = %L', t.rid('flow'))) = 0, 'pelapor tidak melihat review atas laporannya');

-- Rekomendasi
select t.login(t.uv());
select t.throws(format($q$select public.submit_review(%L, 'verified', 'x')$q$, t.rid('rf')), 'invalid_result', 'hasil rekomendasi harus recommend_*');
select t.throws(format($q$select public.submit_review(%L, 'recommend_verified', '  ')$q$, t.rid('rf')), 'reason_required', 'rekomendasi wajib bercatatan');
select t.lives(format($q$select public.submit_review(%L, 'recommend_verified', 'Bukti konsisten dan lengkap')$q$, t.rid('rf')), 'verifier mengirim rekomendasi');
select t.ok((select result = 'recommend_verified' and reviewed_at is not null from public.verification_reviews where id = t.rid('rf')), 'review tercatat selesai');
select t.ok((select status = 'under_review' from public.reports where id = t.rid('flow')), 'rekomendasi tidak mengubah status laporan');
select t.throws(format($q$select public.submit_review(%L, 'recommend_rejected', 'ganti')$q$, t.rid('rf')), 'review_closed', 'rekomendasi tidak bisa diubah');
select t.ok(t.affected(format($q$update public.verification_reviews set notes = 'ubah' where id = %L$q$, t.rid('rf'))) = 0, 'catatan review selesai terkunci (RLS)');
select t.throws(format($q$insert into public.verification_findings (review_id, finding_type, description, assessment) values (%L, 'other', 'x', 'supports')$q$, t.rid('rf')), 'in_progress', 'temuan baru ditolak setelah rekomendasi');
select t.throws(format($q$select public.start_review(%L)$q$, t.rid('flow')), 'review_already_completed', 'review ulang pada siklus yang sudah selesai ditolak (verifier yang sama)');
select t.login(t.v2());
select t.throws(format($q$select public.start_review(%L)$q$, t.rid('flow')), 'review_already_completed', 'verifier lain tidak bisa membuka review baru pada siklus yang sudah selesai');

-- Keputusan moderator
select t.login(t.uv());
select t.throws(format($q$select public.decide_report(%L, 'verified', 'x')$q$, t.rid('flow')), 'forbidden', 'verifier tidak bisa memutuskan (D1)');
select t.login(t.uad());
select t.throws(format($q$select public.decide_report(%L, 'verified', 'x')$q$, t.rid('flow')), 'forbidden', 'admin utama tidak otomatis moderator (D6)');
select t.login(t.ub());
select t.throws(format($q$select public.decide_report(%L, 'verified', 'x')$q$, t.rid('flow')), 'forbidden', 'pengguna biasa tidak bisa memutuskan');
select t.login(t.um());
select t.throws(format($q$select public.decide_report(%L, 'verified', null)$q$, t.rid('flow')), 'reason_required', 'keputusan wajib beralasan');
select t.throws(format($q$select public.decide_report(%L, 'cancelled', 'x')$q$, t.rid('flow')), 'invalid_result', 'keputusan hanya verified/rejected');
select t.lives(format($q$select public.decide_report(%L, 'verified', 'Sesuai rekomendasi verifier')$q$, t.rid('flow')), 'moderator memutuskan Verified');
select t.ok((select status = 'verified' and verified_at is not null from public.reports where id = t.rid('flow')), 'status Verified, verified_at terisi');
select t.ok(t.count(format('select 1 from public.report_histories where report_id = %L and action = ''decided_verified'' and actor_role = ''moderator'' and reason = ''Sesuai rekomendasi verifier''', t.rid('flow'))) = 1, 'riwayat keputusan tercatat');
select t.throws(format($q$select public.decide_report(%L, 'rejected', 'ganti')$q$, t.rid('flow')), 'invalid_transition', 'keputusan tidak bisa diulang pada laporan Verified');

-- ===== 4. Rekomendasi tolak, konflik, kembalikan untuk revisi =====
select t.pend('rej', t.ua());
select t.login(t.uv());
select public.start_review(t.rid('rej')) as rr \gset
select public.submit_review(:'rr'::uuid, 'recommend_rejected', 'Bukti tidak mendukung');
select t.login(t.um());
select t.lives(format($q$select public.decide_report(%L, 'rejected', 'Bukti tidak mendukung klaim')$q$, t.rid('rej')), 'moderator menolak laporan');
select t.ok((select status = 'rejected' from public.reports where id = t.rid('rej')), 'status Rejected (terminal)');
select t.throws(format($q$select public.start_review(%L)$q$, t.rid('rej')), 'forbidden', 'moderator tetap tidak bisa start_review');

-- konflik: laporan milik petugas sendiri
select t.pend('selfv', t.uv());
select t.login(t.uv());
select t.throws(format($q$select public.start_review(%L)$q$, t.rid('selfv')), 'conflict_of_interest', 'verifier tidak bisa memeriksa laporannya sendiri');
select t.login(t.v2());
select t.lives(format($q$select public.start_review(%L)$q$, t.rid('selfv')), 'verifier lain boleh memeriksa laporan milik verifier');

-- pernyataan konflik
select t.pend('cf', t.ua());
select t.login(t.ub());
select t.throws(format($q$select public.declare_conflict(%L, 'x')$q$, t.rid('cf')), 'forbidden', 'pengguna biasa tidak bisa menyatakan konflik');
select t.login(t.uv());
select t.throws(format($q$select public.declare_conflict(%L, 'x')$q$, t.rid('d0')), 'report_not_found', 'konflik tidak bisa dinyatakan pada draf');
select t.throws(format($q$select public.declare_conflict(%L, '  ')$q$, t.rid('cf')), 'reason_required', 'alasan konflik wajib');
select public.start_review(t.rid('cf')) as rcf \gset
select t.ok(t.count(format('select 1 from storage.objects where name like %L', t.rid('cf')::text || '/%')) = 1, 'verifier melihat file sebelum menyatakan konflik');
select t.lives(format($q$select public.declare_conflict(%L, 'Kenal dengan pelapor')$q$, t.rid('cf')), 'verifier menyatakan konflik');
select t.throws(format($q$select public.declare_conflict(%L, 'lagi')$q$, t.rid('cf')), '23505', 'pernyataan konflik ganda ditolak');
select t.ok(t.count(format('select 1 from storage.objects where name like %L', t.rid('cf')::text || '/%')) = 0, 'setelah konflik verifier kehilangan akses file');
select t.throws(format($q$select public.submit_review(%L, 'recommend_verified', 'x')$q$, :'rcf'), 'conflict_of_interest', 'verifier berkonflik tidak bisa merekomendasikan');
select t.ok(t.affected(format($q$update public.verification_reviews set notes = 'x' where id = %L$q$, :'rcf')) = 0, 'verifier berkonflik tidak bisa menulis catatan');
select t.throws(format($q$insert into public.verification_findings (review_id, finding_type, description, assessment) values (%L, 'other', 'x', 'supports')$q$, :'rcf'), '42501', 'verifier berkonflik tidak bisa menulis temuan');
select t.throws(format($q$select public.return_for_revision(%L, 'x')$q$, t.rid('cf')), 'conflict_of_interest', 'verifier berkonflik tidak bisa mengembalikan laporan');
select t.ok(t.count(format('select 1 from public.conflict_declarations where report_id = %L', t.rid('cf'))) = 1, 'verifier melihat pernyataan konfliknya');
select t.login(t.v2());
select t.ok(t.count(format('select 1 from public.conflict_declarations where report_id = %L', t.rid('cf'))) = 0, 'verifier lain tidak melihat pernyataan konflik orang');
select t.lives(format($q$select public.start_review(%L)$q$, t.rid('cf')), 'verifier lain mengambil alih; review verifier berkonflik dilepas');
select t.logout();
select t.ok((select result = 'abandoned' from public.verification_reviews where id = :'rcf'::uuid), 'review lama berstatus abandoned');
select t.login(t.um());
select t.ok(t.count(format('select 1 from public.conflict_declarations where report_id = %L', t.rid('cf'))) = 1, 'moderator melihat semua pernyataan konflik');
select t.lives(format($q$select public.declare_conflict(%L, 'Pelapor adalah kerabat')$q$, t.rid('cf')), 'moderator menyatakan konflik');
select t.ok(t.count(format('select 1 from storage.objects where name like %L', t.rid('cf')::text || '/%')) = 0, 'moderator berkonflik tidak bisa membuka file');
select t.login(t.v2());
select t.lives(format($q$select public.submit_review((select id from public.verification_reviews where report_id = %L and result = 'in_progress'), 'recommend_verified', 'Lengkap')$q$, t.rid('cf')), 'verifier pengganti mengirim rekomendasi');
select t.login(t.um());
select t.throws(format($q$select public.decide_report(%L, 'verified', 'x')$q$, t.rid('cf')), 'conflict_of_interest', 'moderator berkonflik tidak bisa memutuskan');
select t.login(t.m2());
select t.lives(format($q$select public.decide_report(%L, 'verified', 'Keputusan moderator lain')$q$, t.rid('cf')), 'moderator lain memutuskan');
select t.login(t.uad());
select t.ok(t.count('select 1 from public.conflict_declarations') >= 2, 'admin utama melihat pernyataan konflik');

-- kembalikan untuk revisi
select t.pend('rev4', t.ua());
select t.login(t.uv());
select public.start_review(t.rid('rev4')) as rrev \gset
select t.throws(format($q$select public.return_for_revision(%L, null)$q$, t.rid('rev4')), 'reason_required', 'pengembalian wajib beralasan');
select t.lives(format($q$select public.return_for_revision(%L, 'Foto kurang jelas, mohon unggah ulang')$q$, t.rid('rev4')), 'verifier mengembalikan untuk revisi');
select t.ok((select status = 'needs_revision' from public.reports where id = t.rid('rev4')), 'status Needs Revision');
select t.ok((select result = 'needs_revision' and reviewed_at is not null from public.verification_reviews where id = :'rrev'::uuid), 'review ditutup dengan hasil needs_revision');
select t.login(t.ua());
select t.lives(format($q$select public.submit_report(%L)$q$, t.rid('rev4')), 'pelapor dapat kirim ulang setelah revisi');
select t.login(t.v2());
select t.lives(format($q$select public.start_review(%L)$q$, t.rid('rev4')), 'siklus baru: review baru dapat dimulai');

-- ===== 5. Penarikan =====
select t.pend('wd', t.ua());
select t.login(t.ua());
select t.throws(format($q$select public.request_withdrawal(%L, 'batal')$q$, t.rid('wd')), 'invalid_transition', 'penarikan hanya saat Under Review (Pending ditolak)');
select t.login(t.uv());
select public.start_review(t.rid('wd'));
select t.login(t.ub());
select t.throws(format($q$select public.request_withdrawal(%L, 'batal')$q$, t.rid('wd')), 'report_not_found', 'bukan pemilik tidak bisa menarik');
select t.login(t.ua());
select t.throws(format($q$select public.request_withdrawal(%L, '  ')$q$, t.rid('wd')), 'reason_required', 'penarikan wajib beralasan');
select public.request_withdrawal(t.rid('wd'), 'Laporan dibuat keliru') as wid \gset
select t.save('wid', :'wid'::uuid);
select t.throws(format($q$select public.request_withdrawal(%L, 'lagi')$q$, t.rid('wd')), '23505', 'hanya satu permintaan terbuka per laporan');
select t.ok(t.count(format('select 1 from public.withdrawal_requests where id = %L', t.rid('wid'))) = 1, 'pelapor melihat permintaannya');
select t.login(t.ub());
select t.ok(t.count('select 1 from public.withdrawal_requests') = 0, 'pengguna lain tidak melihat permintaan penarikan');
select t.login(t.uv());
select t.ok(t.count('select 1 from public.withdrawal_requests') = 0, 'verifier tidak melihat permintaan penarikan');
select t.throws(format($q$select public.decide_withdrawal(%L, true, 'x')$q$, t.rid('wid')), 'forbidden', 'verifier tidak bisa memutuskan penarikan');
select t.login(t.ua());
select t.throws(format($q$select public.decide_withdrawal(%L, true, 'sendiri')$q$, t.rid('wid')), 'forbidden', 'pelapor tidak bisa menyetujui penarikannya sendiri');
select t.login(t.um());
select t.ok(t.count(format('select 1 from public.withdrawal_requests where id = %L', t.rid('wid'))) = 1, 'moderator melihat permintaan penarikan');
select t.throws(format($q$select public.decide_withdrawal(%L, false, null)$q$, t.rid('wid')), 'reason_required', 'keputusan penarikan wajib beralasan');
select t.lives(format($q$select public.decide_withdrawal(%L, false, 'Pemeriksaan tetap dilanjutkan')$q$, t.rid('wid')), 'moderator menolak penarikan');
select t.ok((select status = 'under_review' from public.reports where id = t.rid('wd')), 'penolakan penarikan tidak mengubah status laporan');
select t.throws(format($q$select public.decide_withdrawal(%L, true, 'ulang')$q$, t.rid('wid')), 'already_decided', 'keputusan penarikan tidak bisa diulang');
select t.login(t.ua());
select public.request_withdrawal(t.rid('wd'), 'Mohon ditarik, saya yakin keliru') as wid2 \gset
select t.login(t.um());
select t.lives(format($q$select public.decide_withdrawal(%L, true, 'Penarikan disetujui')$q$, :'wid2'), 'moderator menyetujui penarikan');
select t.ok((select status = 'cancelled' from public.reports where id = t.rid('wd')), 'laporan menjadi Cancelled');
select t.ok(t.count(format('select 1 from public.report_histories where report_id = %L and action = ''withdrawn'' and actor_role = ''moderator''', t.rid('wd'))) = 1, 'riwayat withdrawn tercatat');

-- ===== 6. Keberatan atas laporan Verified =====
select t.login(t.ub());
select t.throws(format($q$select public.file_objection(%L, 'tidak setuju')$q$, t.rid('p0b')), 'report_not_found', 'keberatan hanya untuk laporan Verified');
select t.throws(format($q$select public.file_objection(%L, '  ')$q$, t.rid('flow')), 'reason_required', 'alasan keberatan wajib');
select public.file_objection(t.rid('flow'), 'Lokasi sebenarnya bukan di sana') as ob1 \gset
select t.save('ob1', :'ob1'::uuid);
select t.throws(format($q$select public.file_objection(%L, 'dobel')$q$, t.rid('flow')), '23505', 'satu keberatan terbuka per pengguna per laporan');
select t.ok(t.count('select 1 from public.objections') = 1, 'pengguna melihat hanya keberatannya sendiri');
select t.login(t.uc());
select t.lives(format($q$select public.file_objection(%L, 'Saya juga keberatan: kejadian itu tidak benar')$q$, t.rid('flow')), 'pengguna lain dapat mengajukan keberatan sendiri');
select t.ok(t.count('select 1 from public.objections') = 1, 'pengguna C hanya melihat keberatannya');
select t.login(t.uu());
select t.throws(format($q$select public.file_objection(%L, 'x')$q$, t.rid('flow')), 'email_not_verified', 'email belum terverifikasi tidak bisa berkeberatan');
select t.anon();
select t.throws(format($q$select public.file_objection(%L, 'x')$q$, t.rid('flow')), '42501', 'anon tidak bisa berkeberatan');
select t.throws('select 1 from public.objections', '42501', 'anon tidak bisa membaca objections');
select t.login(t.ua());
select t.ok(t.count('select 1 from public.objections') = 0, 'pelapor tidak melihat keberatan pihak lain atas laporannya');
select t.login(t.uv());
select t.ok(t.count('select 1 from public.objections') = 2, 'verifier melihat daftar keberatan');
select t.ok((select status = 'verified' from public.reports where id = t.rid('flow')), 'D4: laporan tetap Verified selama keberatan diperiksa');
select t.throws(format($q$select public.decide_objection(%L, 'reopen', 'x')$q$, t.rid('ob1')), 'forbidden', 'verifier tidak bisa memutuskan keberatan');
select t.throws(format($q$select public.add_objection_notes(%L, '  ')$q$, t.rid('ob1')), 'reason_required', 'catatan pemeriksaan keberatan wajib');
select t.lives(format($q$select public.add_objection_notes(%L, 'Koordinat tampak sesuai dengan bukti')$q$, t.rid('ob1')), 'verifier mencatat pemeriksaan keberatan');
select t.ok((select status = 'under_review' and reviewer_id = t.uv() from public.objections where id = t.rid('ob1')), 'keberatan under_review dengan reviewer tercatat');
select t.login(t.v2());
select t.throws(format($q$select public.add_objection_notes(%L, 'ambil alih')$q$, t.rid('ob1')), 'objection_assigned', 'keberatan yang sudah ditangani verifier lain tidak bisa diambil');
select t.login(t.ub());
select t.throws(format($q$select public.add_objection_notes(%L, 'x')$q$, t.rid('ob1')), 'forbidden', 'pengguna biasa tidak bisa memberi catatan pemeriksaan');
select t.throws(format($q$select public.decide_objection(%L, 'reopen', 'x')$q$, t.rid('ob1')), 'forbidden', 'pelapor keberatan tidak bisa memutuskan sendiri');
select t.login(t.um());
select t.throws(format($q$select public.decide_objection(%L, 'ngawur', 'x')$q$, t.rid('ob1')), 'invalid_result', 'hasil keputusan keberatan harus valid');
select t.throws(format($q$select public.decide_objection(%L, 'reopen', null)$q$, t.rid('ob1')), 'reason_required', 'keputusan keberatan wajib beralasan');
select t.lives(format($q$select public.decide_objection(%L, 'reject_objection', 'Keberatan tidak didukung bukti')$q$, t.rid('ob1')), 'moderator menolak keberatan');
select t.ok((select status = 'verified' from public.reports where id = t.rid('flow')), 'penolakan keberatan: laporan tetap Verified');
select t.throws(format($q$select public.decide_objection(%L, 'reopen', 'ulang')$q$, t.rid('ob1')), 'already_decided', 'keberatan yang diputuskan tidak bisa diputuskan lagi');
select t.login(t.ub());
select t.lives(format($q$select public.file_objection(%L, 'Ada bukti baru yang belum dipertimbangkan')$q$, t.rid('flow')), 'setelah ditolak, keberatan baru dapat diajukan');
select t.login(t.um());
select (select id from public.objections where report_id = t.rid('flow') and status = 'open' and user_id = t.ub()) as ob3 \gset
select t.lives(format($q$select public.decide_objection(%L, 'reopen', 'Bukti baru cukup untuk periksa ulang')$q$, :'ob3'), 'moderator menerima keberatan: periksa ulang');
select t.ok((select status = 'under_review' from public.reports where id = t.rid('flow')), 'Verified -> Under Review');
select t.ok(t.count(format('select 1 from public.report_histories where report_id = %L and action = ''objection_accepted'' and old_status = ''verified''', t.rid('flow'))) = 1, 'riwayat objection_accepted');
select t.throws(format($q$select public.decide_report(%L, 'verified', 'cepat')$q$, t.rid('flow')), 'recommendation_required', 'siklus baru: rekomendasi lama tidak berlaku');
select t.login(t.v2());
select public.start_review(t.rid('flow')) as rn \gset
select t.lives(format($q$select public.submit_review(%L, 'recommend_rejected', 'Lokasi tidak sesuai bukti baru')$q$, :'rn'), 'verifier memberi rekomendasi baru');
select t.login(t.um());
select t.lives(format($q$select public.decide_report(%L, 'rejected', 'Hasil pemeriksaan ulang')$q$, t.rid('flow')), 'moderator memutuskan setelah pemeriksaan ulang');
select t.ok((select status = 'rejected' from public.reports where id = t.rid('flow')), 'hasil akhir Rejected');

-- reject_report langsung dari Verified
select t.logout();
select t.pend('vr', t.ua());
select private.transition_report(t.rid('vr'), 'under_review', 'f', 'verifier', 'review_started');
select private.transition_report(t.rid('vr'), 'verified', 'f', 'moderator', 'decided_verified');
select t.login(t.uc());
select public.file_objection(t.rid('vr'), 'Laporan ini palsu') as ob4 \gset
select t.login(t.m2());
select t.lives(format($q$select public.decide_objection(%L, 'reject_report', 'Terbukti tidak benar')$q$, :'ob4'), 'moderator langsung menolak laporan Verified (hasil keberatan)');
select t.ok((select status = 'rejected' from public.reports where id = t.rid('vr')), 'Verified -> Rejected');

-- ===== 7. Audit =====
select t.logout();
select t.ok((select count(*) from public.audit_logs where action = 'review.started') >= 4
        and (select count(*) from public.audit_logs where action = 'review.submitted') >= 3
        and (select count(*) from public.audit_logs where action = 'conflict.declared') >= 2
        and (select count(*) from public.audit_logs where action = 'withdrawal.requested') >= 2
        and (select count(*) from public.audit_logs where action = 'withdrawal.decided') >= 2
        and (select count(*) from public.audit_logs where action = 'objection.filed') >= 4
        and (select count(*) from public.audit_logs where action = 'objection.decided') >= 3
        and (select count(*) from public.audit_logs where action = 'objection.reviewed') >= 1
        and (select count(*) from public.audit_logs where action like 'verification_findings.%') >= 2
        and (select count(*) from public.audit_logs where action = 'report.decided_verified') >= 2,
        'aksi petugas tercatat di audit (review, konflik, penarikan, keberatan, temuan, keputusan)');
select t.ok((select count(*) from public.audit_logs where action = 'report.decided_rejected' and actor_role = 'moderator' and reason = 'Bukti tidak mendukung klaim') = 1, 'audit keputusan: peran dan alasan');
select t.login(t.uad());
select t.ok((select ok from public.verify_audit_chain()), 'rantai audit utuh setelah uji Tahap 4');
select t.logout();
select t.summary();
