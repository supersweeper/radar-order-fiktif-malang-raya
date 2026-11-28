-- Tahap 7: view publik, pengerasan, invarian skema, skenario ujung-ke-ujung.
-- HANYA UNTUK PENGUJIAN LOKAL.
select t.logout();

-- ===== 1. View publik =====
select t.ok((select array_agg(column_name::text order by ordinal_position) from information_schema.columns
              where table_schema = 'public' and table_name = 'public_reports')
            = array['id','region','district','location_general','incident_type','app_name','service_category','lat','lng','incident_at','verified_at','story','loss_amount'],
            'view publik hanya memuat kolom aman (tanpa user_id/status/riwayat)');
select t.ok((select count(*) from pg_views where schemaname = 'public') = 1, 'satu-satunya view di public adalah public_reports');

-- fixture: satu laporan di setiap status; yang Verified berkoordinat presisi
select set_config('app.report_transition', 'on', false);
insert into public.reports (user_id, region, district, location_general, incident_type, story, incident_at, lat, lng, app_name, service_category, loss_amount, status, submitted_at, verified_at)
select t.ua(), 'Kota Batu', 'Batu', 'Sekitar alun-alun ' || s, 'Order fiktif', 'Cerita publik uji ' || s || ' yang cukup panjang untuk lolos batas.',
       now() - interval '1 day', -7.871234, 112.526789, 'Gojek', 'Food', 45000, s::public.report_status,
       case when s <> 'draft' then now() end, case when s = 'verified' then now() end
  from unnest(array['draft','pending','under_review','needs_revision','verified','rejected','cancelled']) s;
select set_config('app.report_transition', 'off', false);
select id as pv from public.reports where location_general = 'Sekitar alun-alun verified' \gset
select t.save('pv', :'pv'::uuid);

select t.anon();
select t.ok((select count(*) from public.public_reports where region = 'Kota Batu' and location_general like 'Sekitar alun-alun %') = 1, 'anon hanya melihat 1 dari 7 laporan uji (yang Verified)');
select t.ok((select location_general from public.public_reports where id = t.rid('pv')) = 'Sekitar alun-alun verified', 'laporan Verified tampil');
select t.ok((select lat = -7.871234 and lng = 112.526789 from public.public_reports where id = t.rid('pv')), 'koordinat tampil presisi penuh, tidak dibulatkan (K-04)');
select t.ok((select story like 'Cerita publik uji verified%' and loss_amount = 45000 from public.public_reports where id = t.rid('pv')), 'story dan loss_amount tampil (D3)');
select t.ok(t.count('select 1 from public.public_reports where location_general in (''Sekitar alun-alun draft'',''Sekitar alun-alun pending'',''Sekitar alun-alun under_review'',''Sekitar alun-alun needs_revision'',''Sekitar alun-alun rejected'',''Sekitar alun-alun cancelled'')') = 0,
            'draft, pending, under_review, needs_revision, rejected, cancelled tidak tampil');
select t.throws('select user_id from public.public_reports', '42703', 'kolom user_id tidak ada di view');
select t.throws('select status from public.public_reports', '42703', 'kolom status tidak ada di view');
select t.throws('select * from public.reports', '42501', 'anon tetap tidak bisa membaca tabel reports');
select t.throws('insert into public.public_reports (region) values (''x'')', '42501', 'anon tidak bisa menulis lewat view (INSERT)');
select t.throws('update public.public_reports set story = ''x''', '42501', 'anon tidak bisa menulis lewat view (UPDATE)');
select t.throws('delete from public.public_reports', '42501', 'anon tidak bisa menulis lewat view (DELETE)');
select t.login(t.ub());
select t.ok(t.count(format('select 1 from public.public_reports where id = %L', t.rid('pv'))) = 1, 'pengguna login biasa juga melihat laporan Verified lewat view');
select t.ok(t.count(format('select 1 from public.reports where id = %L', t.rid('pv'))) = 0, 'pengguna biasa tetap tidak membaca tabel reports orang lain');
select t.throws('update public.public_reports set story = ''x''', '42501', 'pengguna login tidak bisa menulis lewat view');
select t.login(t.uv());
select t.ok(t.count(format('select 1 from public.public_reports where id = %L', t.rid('pv'))) = 1, 'staf melihat laporan Verified lewat view');
select t.logout();

-- status berubah => hilang/muncul di view
select private.transition_report(t.rid('pv'), 'under_review', 'Keberatan diterima', 'moderator', 'objection_accepted');
select t.anon();
select t.ok(t.count(format('select 1 from public.public_reports where id = %L', t.rid('pv'))) = 0, 'Verified -> Under Review: laporan hilang dari view publik');
select t.logout();
select private.transition_report(t.rid('pv'), 'verified', 'Diputuskan ulang', 'moderator', 'decided_verified');
select t.anon();
select t.ok(t.count(format('select 1 from public.public_reports where id = %L', t.rid('pv'))) = 1, 'kembali Verified: laporan muncul lagi');
select t.logout();
select private.transition_report(t.rid('pv'), 'rejected', 'Hasil keberatan', 'moderator', 'objection_rejected_report');
select t.anon();
select t.ok(t.count(format('select 1 from public.public_reports where id = %L', t.rid('pv'))) = 0, 'Verified -> Rejected: laporan hilang dari view publik');
select t.logout();
select t.ok((select count(*) from pg_indexes where indexname in ('reports_verified_feed_idx', 'reports_verified_coords_idx')) = 2, 'indeks umpan dan koordinat laporan Verified ada');

-- ===== 2. Pengerasan dan invarian skema =====
select t.ok((select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind = 'r') = 19, 'tepat 19 tabel di public (sesuai rancangan)');
select t.ok((select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity) = 0, 'semua tabel public memakai RLS');
select t.ok((select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind = 'r' and not exists (select 1 from pg_index i where i.indrelid = c.oid and i.indisprimary)) = 0, 'semua tabel punya primary key');
select t.ok((select count(*) from information_schema.role_table_grants where table_schema = 'public' and grantee = 'anon' and table_name <> 'public_reports') = 0
        and (select array_agg(privilege_type::text) from information_schema.role_table_grants where table_schema = 'public' and grantee = 'anon' and table_name = 'public_reports') = array['SELECT'],
        'anon: tidak ada hak pada tabel apa pun; hanya SELECT pada public_reports');
select t.ok((select count(*) from information_schema.role_table_grants where table_schema = 'public' and grantee = 'authenticated' and privilege_type in ('INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER')) = 0, 'authenticated: tidak ada hak tulis tingkat tabel (hanya kolom tertentu / RPC)');
select t.ok((select count(*) from information_schema.role_table_grants where table_schema = 'public' and grantee = 'service_role' and privilege_type in ('INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER')) = 0, 'service_role: tidak ada hak tulis langsung pada tabel mana pun');
select t.ok((select count(*) from pg_policies where schemaname = 'public' and tablename = 'audit_logs') = 1
        and not has_table_privilege('authenticated', 'public.audit_logs', 'insert,update,delete,truncate')
        and not has_table_privilege('service_role', 'public.audit_logs', 'insert,update,delete,truncate')
        and not has_table_privilege('anon', 'public.audit_logs', 'select'),
        'audit_logs: satu kebijakan baca (admin utama), tanpa hak tulis siapa pun, anon tanpa akses');
select t.ok((select count(*) from pg_proc p where p.pronamespace = 'public'::regnamespace and has_function_privilege('anon', p.oid, 'execute')) = 0, 'anon tidak dapat mengeksekusi fungsi public mana pun');
select t.ok((select array_agg(p.proname::text order by p.proname) from pg_proc p where p.pronamespace = 'public'::regnamespace and has_function_privilege('authenticated', p.oid, 'execute'))
            = array['add_evidence','add_forum_participant','add_objection_notes','admin_revoke_role','admin_set_role','approve_permanent_ban','assign_appeal_reviewer','cancel_report','cast_vote','close_forum','decide_appeal','decide_objection','decide_report','decide_withdrawal','declare_conflict','file_appeal','file_objection','impose_sanction','open_forum','propose_permanent_ban','recommend_appeal','reject_permanent_ban','replace_evidence_version','request_withdrawal','resolve_tie','return_for_revision','start_review','submit_report','submit_review','suspend_sanction','verify_audit_chain'],
            'daftar RPC yang dapat dipanggil authenticated sama persis dengan rancangan (tidak ada fungsi bocor)');
select t.ok((select array_agg(p.proname::text order by p.proname) from pg_proc p where p.pronamespace = 'private'::regnamespace and has_function_privilege('authenticated', p.oid, 'execute'))
            = array['account_restricted','can_see_forum','can_see_forum_votes','can_upload_evidence','can_view_evidence','current_app_role','email_verified','evidence_path_report','has_conflict','has_role','is_assigned_verifier','is_forum_participant','is_staff'],
            'fungsi private yang terbuka hanya pembantu kebijakan RLS (daftar eksak)');
select t.ok((select count(*) from pg_proc p where p.pronamespace = 'public'::regnamespace and has_function_privilege('service_role', p.oid, 'execute') and p.proname not in ('is_email_blacklisted')
              and has_function_privilege('anon', p.oid, 'execute')) = 0, 'service_role tidak mewarisi akses anon yang tidak semestinya');
select t.ok((select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname in ('public','private') and not coalesce(p.proconfig::text, '') like '%search_path%') = 0, 'semua fungsi public/private mengunci search_path');
select t.ok((select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname in ('public','private') and p.prosecdef and not coalesce(p.proconfig::text, '') like '%search_path%') = 0, 'semua fungsi SECURITY DEFINER mengunci search_path');
select t.ok((select count(*) from pg_constraint c join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
              where c.contype = 'f' and c.connamespace = 'public'::regnamespace
                and not exists (select 1 from pg_index i where i.indrelid = c.conrelid and i.indkey[0] = c.conkey[1])) = 0, 'setiap kolom FK punya indeks');
select t.ok((select count(*) from pg_policies where schemaname = 'storage' and policyname like 'evidence_objects_%') = 2
        and (select count(*) from pg_policies where schemaname = 'storage' and cmd in ('UPDATE','DELETE','ALL')) = 0, 'Storage: hanya kebijakan INSERT/SELECT bucket evidence; tidak ada UPDATE/DELETE');
select t.ok(not has_schema_privilege('anon', 'private', 'usage'), 'anon tidak punya akses ke skema private');
select t.ok((select count(*) from pg_trigger tg join pg_class c on c.oid = tg.tgrelid where c.relname = 'audit_logs' and not tg.tgisinternal) >= 3, 'trigger pelindung audit_logs masih terpasang');

-- ===== 3. Skenario ujung-ke-ujung =====
-- pelapor c9 -> bukti -> kirim -> verifier v4 -> moderator m2 -> publik -> keberatan ub -> periksa ulang -> publik
select t.login(t.c(9));
insert into public.reports (region, district, location_general, incident_type, story, incident_at, lat, lng, app_name, service_category, loss_amount)
values ('Kota Malang', 'Lowokwaru', 'Dekat kampus', 'Order fiktif', 'Pesanan ke alamat yang tidak ada, pelanggan tidak bisa dihubungi sama sekali.', now() - interval '3 hours', -7.952100, 112.614500, 'Grab', 'Food', 32000)
returning id as e2e \gset
select t.save('e2e', :'e2e'::uuid);
select t.lives(format($q$insert into storage.objects (bucket_id, name) values ('evidence', %L)$q$, :'e2e' || '/bukti-utama.png'), 'E2E: pelapor mengunggah bukti utama');
select public.add_evidence(t.rid('e2e'), 'EV-01', :'e2e' || '/bukti-utama.png', 'image/png', 1000, repeat('c', 64), 'Tangkapan layar pesanan');
select public.submit_report(t.rid('e2e'));
select t.anon();
select t.ok(t.count(format('select 1 from public.public_reports where id = %L', t.rid('e2e'))) = 0, 'E2E: laporan Pending belum tampil publik');
select t.login(t.v4());
select public.start_review(t.rid('e2e')) as e2e_rv \gset
select t.ok(t.count(format('select 1 from storage.objects where name = %L', :'e2e' || '/bukti-utama.png')) = 1, 'E2E: verifier dapat membuka bukti setelah start_review');
insert into public.verification_findings (review_id, evidence_type, finding_type, description, assessment) values (:'e2e_rv'::uuid, 'EV-01', 'consistency', 'Konsisten dengan kronologi', 'supports');
select public.submit_review(:'e2e_rv'::uuid, 'recommend_verified', 'Bukti memadai');
select t.login(t.m2());
select public.decide_report(t.rid('e2e'), 'verified', 'Sesuai rekomendasi verifier');
select t.anon();
select t.ok((select lat = -7.952100 and lng = 112.614500 and region = 'Kota Malang' from public.public_reports where id = t.rid('e2e')), 'E2E: laporan Verified tampil publik dengan koordinat presisi');
select t.ok((select count(*) from public.public_reports where id = t.rid('e2e')) = 1, 'E2E: tepat satu baris');
select t.login(t.ub());
select public.file_objection(t.rid('e2e'), 'Kejadian itu sebenarnya terjadi di tempat lain') as e2e_ob \gset
select t.login(t.v4());
select public.add_objection_notes(:'e2e_ob'::uuid, 'Perlu pemeriksaan ulang lokasi');
select t.login(t.m2());
select t.anon();
select t.ok(t.count(format('select 1 from public.public_reports where id = %L', t.rid('e2e'))) = 1, 'E2E (D4): selama keberatan diperiksa laporan tetap tampil');
select t.login(t.m2());
select public.decide_objection(:'e2e_ob'::uuid, 'reopen', 'Perlu diperiksa ulang');
select t.anon();
select t.ok(t.count(format('select 1 from public.public_reports where id = %L', t.rid('e2e'))) = 0, 'E2E: setelah keberatan diterima laporan tidak tampil lagi');
select t.login(t.v4());
select public.start_review(t.rid('e2e')) as e2e_rv2 \gset
select public.submit_review(:'e2e_rv2'::uuid, 'recommend_verified', 'Lokasi terbukti sesuai pada pemeriksaan ulang');
select t.login(t.m2());
select public.decide_report(t.rid('e2e'), 'verified', 'Hasil pemeriksaan ulang');
select t.anon();
select t.ok(t.count(format('select 1 from public.public_reports where id = %L', t.rid('e2e'))) = 1, 'E2E: laporan tampil kembali setelah diputuskan ulang');
select t.logout();
select t.ok((select string_agg(action, ',' order by id) from public.report_histories where report_id = t.rid('e2e'))
            = 'created,submitted,review_started,decided_verified,objection_accepted,decided_verified', 'E2E: riwayat status lengkap dan berurutan');
select t.ok((select count(*) from public.audit_logs where object_id = t.rid('e2e')::text and action like 'report.%') >= 6, 'E2E: setiap transisi tercatat di audit');
select t.login(t.c(9));
select t.ok(t.count(format('select 1 from public.reports where id = %L and user_id = %L', t.rid('e2e'), t.c(9))) = 1, 'E2E: pelapor tetap melihat laporannya sendiri');
select t.login(t.uad());
select t.ok((select ok from public.verify_audit_chain()), 'rantai audit utuh setelah seluruh skenario');
select t.logout();
select t.summary();
