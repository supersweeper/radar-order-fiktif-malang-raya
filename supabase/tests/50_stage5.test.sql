-- Tahap 5: forum keputusan, peserta, suara. Memakai fixture Tahap 1-4.
-- HANYA UNTUK PENGUJIAN LOKAL.
select t.logout();

-- (t.ready diperluas manual: tiap langkah satu transaksi, seperti panggilan API nyata)

-- ===== 1. Hak akses dan struktur =====
select t.ok(not has_table_privilege('authenticated', 'public.decision_forums', 'insert,update,delete,truncate')
        and not has_table_privilege('authenticated', 'public.forum_participants', 'insert,update,delete,truncate')
        and not has_table_privilege('authenticated', 'public.forum_votes', 'insert,update,delete,truncate')
        and has_table_privilege('authenticated', 'public.forum_votes', 'select'),
        'forum/peserta/suara: API hanya select; tulis lewat RPC');
select t.ok(not has_table_privilege('anon', 'public.decision_forums', 'select')
        and not has_table_privilege('anon', 'public.forum_votes', 'select')
        and not has_table_privilege('service_role', 'public.forum_votes', 'select,insert,update,delete')
        and not has_table_privilege('service_role', 'public.decision_forums', 'insert,update,delete'),
        'anon tanpa akses; service_role tidak membaca suara dan tidak menulis forum');
select t.ok(not has_function_privilege('anon', 'public.cast_vote(uuid,text,text)', 'execute')
        and not has_function_privilege('anon', 'public.open_forum(uuid,text,uuid)', 'execute')
        and not has_function_privilege('anon', 'public.resolve_tie(uuid,text,text)', 'execute')
        and has_function_privilege('authenticated', 'public.cast_vote(uuid,text,text)', 'execute')
        and not has_function_privilege('authenticated', 'private.forum_try_close(uuid)', 'execute')
        and (select count(*) from pg_proc where proname = 'decide_report' and pronamespace = 'public'::regnamespace) = 1,
        'RPC forum hanya authenticated; fungsi internal tertutup; decide_report tidak ambigu (satu versi)');

-- ===== 2. Constraint dan trigger (pemilik DB) =====
select t.pend('f_base', t.ua());
select t.login(t.uv());
select public.start_review(t.rid('f_base')) as rv_f_base \gset
select public.submit_review(:'rv_f_base'::uuid, 'recommend_verified', 'Rekomendasi uji');
select t.logout();
select t.pend('f_obj_other', t.ub());
insert into public.decision_forums (report_id, question, opened_by) values (t.rid('f_base'), 'Fixture?', t.um()) returning id as fb \gset
select t.save('fb', :'fb'::uuid);
select t.throws(format($q$insert into public.decision_forums (report_id, question, opened_by) values (%L, 'kedua', %L)$q$, t.rid('f_base'), t.um()), '23505', 'satu forum aktif per laporan');
select t.throws(format($q$insert into public.decision_forums (report_id, question, opened_by) values (%L, '  ', %L)$q$, t.rid('f_obj_other'), t.um()), '23514', 'pertanyaan forum wajib');
select t.throws(format($q$insert into public.decision_forums (report_id, question, opened_by, status) values (%L, 'x', %L, 'closed')$q$, t.rid('f_obj_other'), t.um()), '23514', 'forum baru tidak boleh langsung closed');
select t.throws(format($q$insert into public.decision_forums (report_id, objection_id, question, opened_by) values (%L, gen_random_uuid(), 'x', %L)$q$, t.rid('f_obj_other'), t.um()), 'keberatan tidak sesuai', 'objection_id yatim/tidak cocok ditolak');
select t.throws($q$insert into public.decision_forums (report_id, question, opened_by) values (gen_random_uuid(), 'x', t.um())$q$, 'foreign key', 'forum: FK ke laporan');
select t.throws(format($q$update public.decision_forums set status = 'closed', decision = 'approve', decided_at = now() where id = %L$q$, :'fb'), 'fungsi forum', 'status forum tidak bisa diubah langsung');
select t.throws(format($q$update public.decision_forums set question = 'ganti' where id = %L$q$, :'fb'), 'identitas', 'pertanyaan forum tidak bisa diganti');
select t.throws($q$delete from public.decision_forums$q$, 'permanen', 'forum tidak bisa dihapus');
select t.throws($q$truncate public.decision_forums$q$, 'cannot truncate', 'forum tidak bisa di-truncate (FK)');
select t.throws($q$truncate public.forum_votes$q$, 'TRUNCATE ditolak', 'suara tidak bisa di-truncate');
select t.throws($q$truncate public.forum_participants$q$, 'TRUNCATE ditolak', 'peserta tidak bisa di-truncate');

select t.throws(format($q$insert into public.forum_participants (forum_id, user_id, role_at_time, added_by) values (%L, %L, 'user', %L)$q$, :'fb', t.ub(), t.um()), '23514', 'peran peserta tidak boleh user biasa');
select t.lives(format($q$insert into public.forum_participants (forum_id, user_id, role_at_time, added_by) values (%L, %L, 'verifier', %L)$q$, :'fb', t.uv(), t.um()), 'peserta valid');
select t.throws(format($q$insert into public.forum_participants (forum_id, user_id, role_at_time, added_by) values (%L, %L, 'verifier', %L)$q$, :'fb', t.uv(), t.um()), '23505', 'peserta ganda ditolak');
select t.throws(format($q$update public.forum_participants set role_at_time = 'moderator' where forum_id = %L$q$, :'fb'), 'append-only', 'peserta append-only (UPDATE)');
select t.throws(format($q$delete from public.forum_participants where forum_id = %L$q$, :'fb'), 'append-only', 'peserta append-only (DELETE)');
select t.throws(format($q$insert into public.forum_votes (forum_id, voter_id, vote) values (%L, %L, 'approve')$q$, :'fb', t.v2()), 'bukan peserta', 'suara dari non-peserta ditolak');
select t.throws(format($q$insert into public.forum_votes (forum_id, voter_id, vote) values (%L, %L, 'mungkin')$q$, :'fb', t.uv()), '23514', 'nilai suara di luar daftar ditolak');
select t.lives(format($q$insert into public.forum_votes (forum_id, voter_id, vote, reason) values (%L, %L, 'approve', 'fixture')$q$, :'fb', t.uv()), 'suara peserta diterima');
select t.throws(format($q$insert into public.forum_votes (forum_id, voter_id, vote) values (%L, %L, 'reject')$q$, :'fb', t.uv()), '23505', 'suara ganda ditolak (satu suara per peserta)');
select t.throws($q$update public.forum_votes set vote = 'reject'$q$, 'final', 'suara tidak dapat diubah (UPDATE)');
select t.throws($q$delete from public.forum_votes$q$, 'final', 'suara tidak dapat dihapus (DELETE)');
select t.throws(format($q$insert into public.forum_votes (forum_id, voter_id, vote) values (gen_random_uuid(), %L, 'approve')$q$, t.uv()), 'tidak lagi', 'suara untuk forum yang tidak ada ditolak');
select t.throws(format($q$insert into public.decision_forums (report_id, objection_id, question, opened_by) values (%L, gen_random_uuid(), 'x', %L)$q$, t.rid('f_obj_other'), t.um()), 'keberatan tidak sesuai', 'objection yatim ditolak');
-- bersihkan forum fixture lewat jalur sah agar tidak mengganggu uji RPC
select private.forum_try_close(:'fb'::uuid);
select t.ok((select status = 'closed' and decision = 'approve' from public.decision_forums where id = :'fb'::uuid), 'fixture: forum satu peserta menutup otomatis (approve)');
select t.throws(format($q$update public.decision_forums set minutes = 'x' where id = %L$q$, :'fb'), 'sudah ditutup', 'forum closed tidak dapat diubah');
select t.throws(format($q$insert into public.forum_participants (forum_id, user_id, role_at_time, added_by) values (%L, %L, 'moderator', %L)$q$, :'fb', t.um(), t.um()), 'forum open', 'peserta tidak bisa ditambah setelah forum selesai');
select t.throws(format($q$insert into public.forum_votes (forum_id, voter_id, vote) values (%L, %L, 'approve')$q$, :'fb', t.uv()), 'tidak lagi menerima', 'suara tidak bisa ditambah setelah forum selesai');

-- ===== 3. Membuka forum dan peserta (RPC) =====
select t.pend('f1', t.ua());
select t.login(t.uv());
select public.start_review(t.rid('f1')) as rv_f1 \gset
select public.submit_review(:'rv_f1'::uuid, 'recommend_verified', 'Rekomendasi uji');
select t.logout();
select t.pend('f2', t.ua());
select t.login(t.uv());
select public.start_review(t.rid('f2')) as rv_f2 \gset
select public.submit_review(:'rv_f2'::uuid, 'recommend_verified', 'Rekomendasi uji');
select t.logout();
select t.mk('f_draft', t.ua());
select t.login(t.ub());
select t.throws(format($q$select public.open_forum(%L, 'x')$q$, t.rid('f1')), 'forbidden', 'pengguna biasa tidak bisa membuka forum');
select t.login(t.uv());
select t.throws(format($q$select public.open_forum(%L, 'x')$q$, t.rid('f1')), 'forbidden', 'verifier tidak bisa membuka forum');
select t.anon();
select t.throws(format($q$select public.open_forum(%L, 'x')$q$, t.rid('f1')), '42501', 'anon tidak bisa membuka forum');
select t.login(t.um());
select t.throws(format($q$select public.open_forum(%L, 'x')$q$, t.rid('f_draft')), 'report_not_found', 'forum tidak bisa dibuka untuk draf');
select t.throws(format($q$select public.open_forum(%L, '  ')$q$, t.rid('f1')), 'reason_required', 'pertanyaan forum wajib');
select t.throws(format($q$select public.open_forum(%L, 'x', %L)$q$, t.rid('f1'), gen_random_uuid()), 'keberatan tidak sesuai', 'keberatan tidak dikenal ditolak');
select public.open_forum(t.rid('f1'), 'Apakah laporan ini layak Verified?') as o1 \gset
select t.save('o1', :'o1'::uuid);
select t.throws(format($q$select public.open_forum(%L, 'lagi')$q$, t.rid('f1')), '23505', 'forum aktif kedua untuk laporan sama ditolak');
select t.login(t.uad());
select public.open_forum(t.rid('f2'), 'Forum oleh admin utama') as o2 \gset
select t.save('o2', :'o2'::uuid);
select t.lives('select 1', 'admin utama dapat membuka forum');

-- peserta
select t.login(t.ub());
select t.throws(format($q$select public.add_forum_participant(%L, %L)$q$, t.rid('o1'), t.uv()), 'forbidden', 'pengguna biasa tidak bisa menambah peserta');
select t.login(t.uv());
select t.throws(format($q$select public.add_forum_participant(%L, %L)$q$, t.rid('o1'), t.v2()), 'forbidden', 'verifier tidak bisa menambah peserta');
select t.login(t.um());
select t.throws(format($q$select public.add_forum_participant(%L, %L)$q$, t.rid('o1'), t.ub()), 'not_staff', 'peserta harus petugas aktif');
select t.throws(format($q$select public.add_forum_participant(%L, %L)$q$, gen_random_uuid(), t.uv()), 'forum_not_found', 'forum tidak ada');
select t.lives(format($q$select public.add_forum_participant(%L, %L)$q$, t.rid('o1'), t.uv()), 'moderator menambah verifier sebagai peserta');
select t.lives(format($q$select public.add_forum_participant(%L, %L)$q$, t.rid('o1'), t.v2()), 'moderator menambah verifier ke-2');
select t.lives(format($q$select public.add_forum_participant(%L, %L)$q$, t.rid('o1'), t.m2()), 'moderator menambah moderator lain');
select t.throws(format($q$select public.add_forum_participant(%L, %L)$q$, t.rid('o1'), t.uv()), '23505', 'peserta ganda ditolak');
select t.ok((select role_at_time = 'moderator' from public.forum_participants where forum_id = t.rid('o1') and user_id = t.m2()), 'peran saat itu tercatat');
-- forum untuk f2: hanya uv dan m2 (v2 bukan peserta)
select t.lives(format($q$select public.add_forum_participant(%L, %L)$q$, t.rid('o2'), t.uv()), 'peserta forum f2: uv');
select t.lives(format($q$select public.add_forum_participant(%L, %L)$q$, t.rid('o2'), t.m2()), 'peserta forum f2: m2');
-- laporan milik petugas: pemiliknya tidak boleh jadi peserta
select t.pend('f_self', t.uv());
select public.open_forum(t.rid('f_self'), 'Forum atas laporan petugas') as o3 \gset
select t.throws(format($q$select public.add_forum_participant(%L, %L)$q$, :'o3', t.uv()), 'conflict_of_interest', 'pemilik laporan (petugas) tidak boleh jadi peserta');
select t.lives(format($q$select public.add_forum_participant(%L, %L)$q$, :'o3', t.v2()), 'petugas lain boleh');

-- ===== 4. Visibilitas forum =====
select t.login(t.ub());
select t.ok(t.count('select 1 from public.decision_forums') = 0 and t.count('select 1 from public.forum_participants') = 0, 'pengguna biasa tidak melihat forum');
select t.anon();
select t.throws('select 1 from public.decision_forums', '42501', 'anon ditolak membaca forum');
select t.login(t.ua());
select t.ok(t.count('select 1 from public.decision_forums') = 0, 'pelapor tidak melihat forum atas laporannya');
select t.login(t.v2());
select t.ok(t.count(format('select 1 from public.decision_forums where id = %L', t.rid('o1'))) = 1
        and t.count(format('select 1 from public.decision_forums where id = %L', t.rid('o2'))) = 0, 'verifier hanya melihat forum yang diikutinya');
select t.ok(t.count(format('select 1 from public.forum_participants where forum_id = %L', t.rid('o2'))) = 0, 'verifier non-peserta tidak melihat daftar peserta forum lain');
select t.login(t.um());
select t.ok(t.count('select 1 from public.decision_forums') >= 3, 'moderator melihat semua forum');

-- ===== 5. Pemungutan suara =====
select t.login(t.ub());
select t.throws(format($q$select public.cast_vote(%L, 'approve')$q$, t.rid('o1')), 'forbidden', 'pengguna biasa tidak bisa memilih');
select t.anon();
select t.throws(format($q$select public.cast_vote(%L, 'approve')$q$, t.rid('o1')), '42501', 'anon tidak bisa memilih');
select t.login(t.uad());
select t.throws(format($q$select public.cast_vote(%L, 'approve')$q$, t.rid('o1')), 'forum_not_found', 'non-peserta (admin utama) tidak bisa memilih');
select t.login(t.v2());
select t.throws(format($q$select public.cast_vote(%L, 'approve')$q$, t.rid('o2')), 'forum_not_found', 'verifier bukan peserta forum lain tidak bisa memilih');
select t.login(t.uv());
select t.throws(format($q$select public.cast_vote(%L, 'mungkin')$q$, t.rid('o1')), 'invalid_vote', 'nilai suara harus valid');
select t.throws(format($q$insert into public.forum_votes (forum_id, voter_id, vote) values (%L, %L, 'approve')$q$, t.rid('o1'), t.uv()), '42501', 'suara tidak bisa disisipkan langsung lewat API');
select t.ok(public.cast_vote(t.rid('o1'), 'approve', 'Bukti memadai') = 'open', 'suara pertama: forum tetap open');
select t.throws(format($q$select public.cast_vote(%L, 'reject')$q$, t.rid('o1')), '23505', 'suara kedua dari peserta sama ditolak (final)');
select t.throws(format($q$update public.forum_votes set vote = 'reject' where forum_id = %L$q$, t.rid('o1')), '42501', 'peserta tidak bisa mengubah suara');
select t.throws(format($q$delete from public.forum_votes where forum_id = %L$q$, t.rid('o1')), '42501', 'peserta tidak bisa menghapus suara');
select t.ok(t.count(format('select 1 from public.forum_votes where forum_id = %L', t.rid('o1'))) = 1, 'peserta melihat suaranya sendiri');
select t.login(t.v2());
select t.ok(t.count(format('select 1 from public.forum_votes where forum_id = %L', t.rid('o1'))) = 0, 'sesama peserta TIDAK melihat suara orang lain sebelum forum selesai');
select t.login(t.um());
select t.ok(t.count(format('select 1 from public.forum_votes where forum_id = %L', t.rid('o1'))) = 0, 'moderator TIDAK melihat suara sebelum forum selesai');
select t.login(t.uad());
select t.ok(t.count(format('select 1 from public.forum_votes where forum_id = %L', t.rid('o1'))) = 0, 'admin utama TIDAK melihat suara sebelum forum selesai');
select t.logout();
select t.ok((select count(*) from public.audit_logs where action = 'forum.voted' and object_id = t.rid('o1')::text
              and not (new_data ? 'vote') and not (new_data ? 'reason') and new_data ->> 'voter_id' = t.uv()::text) = 1,
            'audit suara tidak membocorkan pilihan (kerahasiaan terhadap admin)');
select t.login(t.m2());
select t.ok(public.cast_vote(t.rid('o1'), 'reject', 'Kurang bukti') = 'open', 'suara kedua: masih open (menunggu verifier ke-2)');
select t.throws(format($q$select public.close_forum(%L)$q$, t.rid('o1')), 'votes_pending', 'close_forum ditolak selama masih ada peserta berhak yang belum memilih');
select t.login(t.ub());
select t.throws(format($q$select public.close_forum(%L)$q$, t.rid('o1')), 'forbidden', 'pengguna biasa tidak bisa close_forum');
select t.login(t.uv());
select t.throws(format($q$select public.close_forum(%L)$q$, t.rid('o1')), 'forbidden', 'verifier tidak bisa close_forum');
select t.login(t.v2());
select t.ok(public.cast_vote(t.rid('o1'), 'approve') = 'closed', 'suara terakhir menutup forum otomatis (D8)');
select t.logout();
select t.ok((select status = 'closed' and decision = 'approve' and decided_at is not null and not decided_by_tiebreak from public.decision_forums where id = t.rid('o1')),
            'forum closed: keputusan approve (2 lawan 1), bukan tie-break');
select t.ok((select count(*) from public.audit_logs where action = 'forum.closed' and object_id = t.rid('o1')::text
              and (new_data ->> 'approve')::int = 2 and (new_data ->> 'reject')::int = 1 and new_data ->> 'decision' = 'approve') = 1,
            'audit penutupan forum memuat hasil hitung');
-- setelah selesai suara terlihat
select t.login(t.uv());
select t.ok(t.count(format('select 1 from public.forum_votes where forum_id = %L', t.rid('o1'))) = 3, 'peserta melihat semua suara setelah forum selesai');
select t.login(t.um());
select t.ok(t.count(format('select 1 from public.forum_votes where forum_id = %L', t.rid('o1'))) = 3, 'moderator (bukan peserta) melihat semua suara setelah selesai');
select t.login(t.uad());
select t.ok(t.count(format('select 1 from public.forum_votes where forum_id = %L', t.rid('o1'))) = 3, 'admin utama melihat semua suara setelah selesai');
select t.login(t.ub());
select t.ok(t.count('select 1 from public.forum_votes') = 0, 'pengguna biasa tidak pernah melihat suara');
select t.login(t.v2());
select t.throws(format($q$select public.cast_vote(%L, 'reject')$q$, t.rid('o1')), 'forum_closed', 'suara ditolak setelah forum selesai');
select t.login(t.um());
select t.throws(format($q$select public.add_forum_participant(%L, %L)$q$, t.rid('o1'), t.uv()), 'saat forum open', 'peserta tidak bisa ditambah setelah forum selesai');

-- ===== 6. Rujukan forum pada keputusan laporan =====
select t.throws(format($q$select public.decide_report(%L, 'verified', 'x', %L)$q$, t.rid('f1'), gen_random_uuid()), 'forum_not_found', 'forum tidak dikenal ditolak');
select t.throws(format($q$select public.decide_report(%L, 'verified', 'x', %L)$q$, t.rid('f1'), t.rid('o2')), 'forum_not_found', 'forum milik laporan lain ditolak');
select t.throws(format($q$select public.decide_report(%L, 'rejected', 'x', %L)$q$, t.rid('f1'), t.rid('o1')), 'forum_decision_mismatch', 'keputusan yang berlawanan dengan hasil forum ditolak');
select t.lives(format($q$select public.decide_report(%L, 'verified', 'Sesuai hasil forum', %L)$q$, t.rid('f1'), t.rid('o1')), 'keputusan merujuk forum yang sudah selesai');
select t.ok((select status = 'verified' from public.reports where id = t.rid('f1')), 'laporan menjadi Verified');
select t.logout();
select t.ok((select count(*) from public.audit_logs where action = 'report.forum_referenced' and object_id = t.rid('f1')::text and new_data ->> 'forum_id' = t.rid('o1')::text) = 1, 'rujukan forum tercatat di audit');
select t.login(t.um());
select t.throws(format($q$select public.decide_report(%L, 'verified', 'x', %L)$q$, t.rid('f2'), t.rid('o2')), 'forum_not_closed', 'forum yang belum selesai tidak dapat dirujuk');

-- ===== 7. Seri dan tie-break =====
select t.pend('f3', t.ua());
select t.login(t.uv());
select public.start_review(t.rid('f3')) as rv_f3 \gset
select public.submit_review(:'rv_f3'::uuid, 'recommend_verified', 'Rekomendasi uji');
select t.logout();
select t.login(t.um());
select public.open_forum(t.rid('f3'), 'Forum seri') as o4 \gset
select t.save('o4', :'o4'::uuid);
select public.add_forum_participant(:'o4'::uuid, t.uv());
select public.add_forum_participant(:'o4'::uuid, t.v2());
select t.login(t.uv());
select public.cast_vote(t.rid('o4'), 'approve');
select t.login(t.v2());
select t.ok(public.cast_vote(t.rid('o4'), 'reject') = 'tied', 'suara seri: forum berstatus tied');
select t.logout();
select t.ok((select status = 'tied' and decision is null and decided_at is null from public.decision_forums where id = t.rid('o4')), 'tied: belum ada keputusan');
select t.login(t.uv());
select t.ok(t.count(format('select 1 from public.forum_votes where forum_id = %L', t.rid('o4'))) = 2, 'suara terbuka bagi peserta setelah voting selesai (tied)');
select t.throws(format($q$select public.cast_vote(%L, 'approve')$q$, t.rid('o4')), 'forum_closed', 'tidak ada suara lagi saat tied');
select t.login(t.um());
select t.throws(format($q$select public.resolve_tie(%L, 'approve', 'x')$q$, t.rid('o4')), 'forbidden', 'moderator tidak bisa tie-break (hanya admin utama)');
select t.throws(format($q$select public.decide_report(%L, 'verified', 'x', %L)$q$, t.rid('f3'), t.rid('o4')), 'forum_not_closed', 'forum tied belum dapat dirujuk');
select t.login(t.uv());
select t.throws(format($q$select public.resolve_tie(%L, 'approve', 'x')$q$, t.rid('o4')), 'forbidden', 'verifier tidak bisa tie-break');
select t.login(t.uad());
select t.throws(format($q$select public.resolve_tie(%L, 'seri', 'x')$q$, t.rid('o4')), 'invalid_vote', 'hasil tie-break harus approve/reject');
select t.throws(format($q$select public.resolve_tie(%L, 'reject', '  ')$q$, t.rid('o4')), 'reason_required', 'tie-break wajib berisi risalah');
select t.throws(format($q$select public.resolve_tie(%L, 'reject', 'x')$q$, t.rid('o1')), 'not_tied', 'forum closed bukan seri');
select t.lives(format($q$select public.resolve_tie(%L, 'reject', 'Risalah: Admin Utama memutus seri menolak')$q$, t.rid('o4')), 'admin utama memutus seri');
select t.ok((select status = 'closed' and decision = 'reject' and decided_by_tiebreak and minutes like 'Risalah%' from public.decision_forums where id = t.rid('o4')), 'forum closed dengan penanda tie-break dan risalah');
select t.throws(format($q$select public.resolve_tie(%L, 'approve', 'ulang')$q$, t.rid('o4')), 'not_tied', 'tie-break tidak bisa diulang');
select t.logout();
select t.ok((select count(*) from public.audit_logs where action in ('forum.tied') and object_id = t.rid('o4')::text) = 1
        and (select count(*) from public.audit_logs where action = 'forum.tiebreak' and object_id = t.rid('o4')::text and reason like 'Risalah%') = 1, 'audit tied dan tie-break');

-- semua abstain = seri 0-0; satu setuju + satu abstain = approve
select t.pend('f4', t.ua());
select t.login(t.uv());
select public.start_review(t.rid('f4')) as rv_f4 \gset
select public.submit_review(:'rv_f4'::uuid, 'recommend_verified', 'Rekomendasi uji');
select t.logout();
select t.login(t.um());
select public.open_forum(t.rid('f4'), 'Forum abstain') as o5 \gset
select t.save('o5', :'o5'::uuid);
select public.add_forum_participant(:'o5'::uuid, t.uv());
select public.add_forum_participant(:'o5'::uuid, t.v2());
select t.login(t.uv());
select public.cast_vote(t.rid('o5'), 'abstain');
select t.login(t.v2());
select t.ok(public.cast_vote(t.rid('o5'), 'abstain') = 'tied', 'semua abstain (0-0) dianggap seri');
select t.pend('f5', t.ua());
select t.login(t.uv());
select public.start_review(t.rid('f5')) as rv_f5 \gset
select public.submit_review(:'rv_f5'::uuid, 'recommend_verified', 'Rekomendasi uji');
select t.logout();
select t.login(t.um());
select public.open_forum(t.rid('f5'), 'Forum mayoritas dengan abstain') as o6 \gset
select t.save('o6', :'o6'::uuid);
select public.add_forum_participant(:'o6'::uuid, t.uv());
select public.add_forum_participant(:'o6'::uuid, t.v2());
select t.login(t.uv());
select public.cast_vote(t.rid('o6'), 'approve');
select t.login(t.v2());
select t.ok(public.cast_vote(t.rid('o6'), 'abstain') = 'closed', 'satu setuju + satu abstain: closed approve');
select t.ok((select decision = 'approve' from public.decision_forums where id = t.rid('o6')), 'hasil: approve');

-- ===== 8. Konflik mengubah daftar peserta berhak =====
select t.pend('f6', t.ua());
select t.login(t.uv());
select public.start_review(t.rid('f6')) as rv_f6 \gset
select public.submit_review(:'rv_f6'::uuid, 'recommend_verified', 'Rekomendasi uji');
select t.logout();
select t.login(t.um());
select public.open_forum(t.rid('f6'), 'Forum konflik') as o7 \gset
select t.save('o7', :'o7'::uuid);
select public.add_forum_participant(:'o7'::uuid, t.uv());
select public.add_forum_participant(:'o7'::uuid, t.v2());
select public.add_forum_participant(:'o7'::uuid, t.m2());
select t.throws(format($q$select public.close_forum(%L)$q$, t.rid('o7')), 'votes_pending', 'tanpa suara forum tidak bisa ditutup');
select t.login(t.uv());
select public.cast_vote(t.rid('o7'), 'approve');
select t.login(t.m2());
select public.cast_vote(t.rid('o7'), 'approve');
select t.ok((select status = 'open' from public.decision_forums where id = t.rid('o7')), 'v2 belum memilih: forum masih open');
select t.login(t.v2());
select public.declare_conflict(t.rid('f6'), 'Kenal pelapor');
select t.throws(format($q$select public.cast_vote(%L, 'approve')$q$, t.rid('o7')), 'conflict_of_interest', 'peserta yang berkonflik tidak bisa memilih');
select t.ok((select status = 'open' from public.decision_forums where id = t.rid('o7')), 'forum belum otomatis tertutup oleh pernyataan konflik');
select t.login(t.um());
select t.ok(public.close_forum(t.rid('o7')) = 'closed', 'close_forum menutup bila semua peserta berhak sudah memilih');
select t.ok((select decision = 'approve' from public.decision_forums where id = t.rid('o7')), 'suara peserta berkonflik tidak dihitung; hasil approve (2-0)');
select t.ok(public.close_forum(t.rid('o7')) = 'closed', 'close_forum idempoten pada forum selesai');

-- ===== 9. Audit dan rantai =====
select t.logout();
select t.ok((select count(*) from public.audit_logs where action = 'forum.opened') >= 5
        and (select count(*) from public.audit_logs where action = 'forum.participant_added') >= 8
        and (select count(*) from public.audit_logs where action = 'forum.voted') >= 8,
        'pembukaan forum, penambahan peserta, dan suara tercatat di audit');
select t.login(t.uad());
select t.ok((select ok from public.verify_audit_chain()), 'rantai audit utuh setelah uji Tahap 5');
select t.logout();
select t.summary();
