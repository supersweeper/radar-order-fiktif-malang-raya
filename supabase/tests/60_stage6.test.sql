-- Tahap 6: sanksi, banding, blacklist, pembatasan akun, fingerprint. Memakai fixture Tahap 1-5.
-- HANYA UNTUK PENGUJIAN LOKAL.
select t.logout();

insert into auth.users (id, email, email_confirmed_at)
select ('00000000-0000-0000-0000-0000000000c' || n)::uuid, 'c' || n || '@example.test', now() from generate_series(1, 9) n
on conflict (id) do nothing;
insert into auth.users (id, email, email_confirmed_at) values ('00000000-0000-0000-0000-0000000000b4', 'v4@example.test', now()) on conflict (id) do nothing;
insert into public.user_roles (user_id, role, reason) values ('00000000-0000-0000-0000-0000000000b4', 'verifier', 'fixture uji') on conflict do nothing;
create or replace function t.c(n int) returns uuid language sql immutable as $$ select ('00000000-0000-0000-0000-0000000000c' || n)::uuid $$;
create or replace function t.v4() returns uuid language sql immutable as $$ select '00000000-0000-0000-0000-0000000000b4'::uuid $$;

-- ===== 1. Hak akses =====
select t.ok(not has_table_privilege('authenticated', 'public.sanctions', 'insert,update,delete,truncate')
        and not has_table_privilege('authenticated', 'public.appeals', 'insert,update,delete,truncate')
        and not has_table_privilege('authenticated', 'public.blacklist_entries', 'insert,update,delete,truncate')
        and not has_table_privilege('anon', 'public.sanctions', 'select')
        and not has_table_privilege('anon', 'public.appeals', 'select')
        and not has_table_privilege('anon', 'public.blacklist_entries', 'select')
        and not has_table_privilege('service_role', 'public.sanctions', 'insert,update,delete')
        and not has_table_privilege('service_role', 'public.appeals', 'insert,update,delete')
        and not has_table_privilege('service_role', 'public.blacklist_entries', 'select,insert,update,delete'),
        'sanksi/banding/blacklist: API hanya select; blacklist tidak terbaca service_role; anon tanpa akses');
select t.ok(not has_function_privilege('authenticated', 'public.is_email_blacklisted(text)', 'execute')
        and not has_function_privilege('anon', 'public.is_email_blacklisted(text)', 'execute')
        and has_function_privilege('service_role', 'public.is_email_blacklisted(text)', 'execute')
        and has_function_privilege('supabase_auth_admin', 'public.is_email_blacklisted(text)', 'execute')
        and not has_function_privilege('anon', 'public.impose_sanction(uuid,public.sanction_type,text,timestamptz,uuid,uuid)', 'execute')
        and has_function_privilege('authenticated', 'public.decide_appeal(uuid,boolean,text)', 'execute')
        and not has_function_privilege('authenticated', 'private.email_fingerprint(text)', 'execute')
        and not has_function_privilege('authenticated', 'private.blacklist_pepper()', 'execute'),
        'is_email_blacklisted hanya service_role/auth admin; fingerprint dan pepper tertutup');

-- ===== 2. HMAC, normalisasi, fingerprint =====
select t.ok(encode(private.hmac_sha256('Jefe'::bytea, 'what do ya want for nothing?'::bytea), 'hex')
            = '5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843', 'HMAC-SHA256 cocok vektor RFC 4231 (kasus 2)');
select t.ok(encode(private.hmac_sha256(decode(repeat('aa', 131), 'hex'), 'Test Using Larger Than Block-Size Key - Hash Key First'::bytea), 'hex')
            = '60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54', 'HMAC-SHA256 kunci > 64 byte cocok vektor RFC 4231 (kasus 6)');
select t.ok(private.normalize_email('  A.B+promo@Example.TEST ') = 'a.b@example.test', 'normalisasi: huruf kecil, spasi, +alias dibuang');
select t.throws($q$select private.normalize_email('bukan-email')$q$, 'invalid_email', 'email tidak valid ditolak');
select t.throws($q$select private.normalize_email(null)$q$, 'invalid_email', 'email null ditolak');
select t.ok(private.email_fingerprint('X@Example.test') = private.email_fingerprint('x+iklan@example.test'), 'fingerprint sama untuk varian huruf/+alias');
select t.ok(private.email_fingerprint('x@example.test') <> private.email_fingerprint('y@example.test'), 'fingerprint berbeda untuk email berbeda');
select t.ok(private.email_fingerprint('x@example.test') ~ '^[0-9a-f]{64}$', 'fingerprint heksadesimal 64 karakter');
create temp table t_pepper as select decrypted_secret from vault.decrypted_secrets where name = 'blacklist_pepper';
select private.email_fingerprint('x@example.test') as fp_a \gset
update vault.decrypted_secrets set decrypted_secret = 'pepper-lain-yang-juga-cukup-panjang-99' where name = 'blacklist_pepper';
select t.ok(private.email_fingerprint('x@example.test') <> :'fp_a', 'pepper berbeda menghasilkan fingerprint berbeda (tanpa pepper tidak bisa direproduksi)');
delete from vault.decrypted_secrets where name = 'blacklist_pepper';
select t.throws($q$select private.email_fingerprint('x@example.test')$q$, 'pepper_missing', 'tanpa pepper fungsi gagal tertutup');
insert into vault.decrypted_secrets (name, decrypted_secret) values ('blacklist_pepper', 'pendek');
select t.throws($q$select private.email_fingerprint('x@example.test')$q$, 'pepper_missing', 'pepper terlalu pendek ditolak');
delete from vault.decrypted_secrets where name = 'blacklist_pepper';
insert into vault.decrypted_secrets (name, decrypted_secret) select 'blacklist_pepper', decrypted_secret from t_pepper;
select t.ok(private.email_fingerprint('x@example.test') = :'fp_a', 'pepper dipulihkan: fingerprint kembali sama');

-- ===== 3. Constraint dan trigger (pemilik DB) =====
select t.throws(format($q$insert into public.sanctions (user_id, moderator_id, sanction_type, reason, proposed_by) values (%L, %L, 'warning', 'x', %L)$q$, t.um(), t.um(), t.um()), '23514', 'tidak bisa menyanksi diri sendiri');
select t.throws(format($q$insert into public.sanctions (user_id, moderator_id, sanction_type, reason, proposed_by) values (%L, %L, 'warning', 'x', %L)$q$, t.c(8), t.um(), t.m2()), '23514', 'pengusul harus sama dengan moderator');
select t.throws(format($q$insert into public.sanctions (user_id, moderator_id, sanction_type, reason, proposed_by) values (%L, %L, 'warning', '  ', %L)$q$, t.c(8), t.um(), t.um()), '23514', 'alasan sanksi wajib');
select t.throws(format($q$insert into public.sanctions (user_id, moderator_id, sanction_type, reason, proposed_by) values (%L, %L, 'feature_restriction', 'x', %L)$q$, t.c(8), t.um(), t.um()), '23514', 'pembatasan fitur wajib punya ends_at');
select t.throws(format($q$insert into public.sanctions (user_id, moderator_id, sanction_type, reason, proposed_by, ends_at) values (%L, %L, 'temporary_suspension', 'x', %L, now() - interval '1 day')$q$, t.c(8), t.um(), t.um()), '23514', 'ends_at harus setelah starts_at');
select t.throws(format($q$insert into public.sanctions (user_id, moderator_id, sanction_type, reason, proposed_by, ends_at) values (%L, %L, 'warning', 'x', %L, now() + interval '1 day')$q$, t.c(8), t.um(), t.um()), '23514', 'warning tidak punya ends_at');
select t.throws(format($q$insert into public.sanctions (user_id, moderator_id, sanction_type, reason, proposed_by, status) values (%L, %L, 'permanent_ban', 'x', %L, 'active')$q$, t.c(8), t.um(), t.um()), 'status awal', 'blokir permanen tidak bisa langsung active');
select t.throws(format($q$insert into public.sanctions (user_id, moderator_id, sanction_type, reason, proposed_by, status) values (%L, %L, 'warning', 'x', %L, 'proposed')$q$, t.c(8), t.um(), t.um()), 'status awal', 'sanksi non-permanen tidak bisa berstatus proposed');
select t.throws($q$insert into public.sanctions (user_id, moderator_id, sanction_type, reason, proposed_by) values (gen_random_uuid(), t.um(), 'warning', 'x', t.um())$q$, 'foreign key', 'sanksi: FK ke pengguna');
select t.throws(format($q$insert into public.sanctions (user_id, moderator_id, sanction_type, reason, proposed_by, approved_by, approved_at) values (%L, %L, 'warning', 'x', %L, %L, now())$q$, t.c(8), t.um(), t.um(), t.uad()), '23514', 'sanksi non-permanen tidak butuh/tidak boleh ada persetujuan');
select t.pend('s_basis_draft', t.ua());
select t.mk('s_draftrep', t.ua());
select t.throws(format($q$insert into public.sanctions (user_id, moderator_id, sanction_type, reason, proposed_by, report_id) values (%L, %L, 'warning', 'x', %L, %L)$q$, t.c(8), t.um(), t.um(), t.rid('s_draftrep')), 'laporan dasar', 'laporan dasar tidak boleh draf');
select t.throws(format($q$insert into public.sanctions (user_id, moderator_id, sanction_type, reason, proposed_by, forum_id) values (%L, %L, 'warning', 'x', %L, %L)$q$, t.c(8), t.um(), t.um(), t.rid('o2')), 'forum dasar', 'forum dasar harus sudah selesai dan sesuai laporan');
select t.lives(format($q$insert into public.sanctions (user_id, moderator_id, sanction_type, reason, proposed_by) values (%L, %L, 'warning', 'Fixture konstrain', %L)$q$, t.c(8), t.um(), t.um()), 'sanksi warning valid');
select t.throws($q$update public.sanctions set status = 'lifted' where reason = 'Fixture konstrain'$q$, 'fungsi sanksi', 'status sanksi tidak bisa diubah langsung');
select t.throws($q$update public.sanctions set reason = 'ganti' where reason = 'Fixture konstrain'$q$, 'tidak boleh diubah', 'isi sanksi tidak bisa diubah');
select t.throws($q$delete from public.sanctions$q$, 'permanen', 'sanksi tidak bisa dihapus');
select t.throws($q$truncate public.sanctions$q$, 'cannot truncate', 'sanksi tidak bisa di-truncate (FK)');
select t.throws($q$truncate public.blacklist_entries$q$, 'TRUNCATE ditolak', 'blacklist tidak bisa di-truncate');
select t.throws($q$truncate public.appeals$q$, 'TRUNCATE ditolak', 'banding tidak bisa di-truncate');
select t.throws(format($q$insert into public.blacklist_entries (user_id, sanction_id, email_fingerprint, reason, created_by) values (%L, (select id from public.sanctions limit 1), 'bukan-hash', 'x', %L)$q$, t.c(8), t.uad()), '23514', 'fingerprint harus 64 heksadesimal (email polos ditolak)');

select t.throws($q$update public.sanctions set status = 'lifted' where reason = 'Fixture konstrain'$q$, 'fungsi sanksi', 'status sanksi tidak bisa diubah langsung');
select t.throws($q$update public.sanctions set reason = 'ganti' where reason = 'Fixture konstrain'$q$, 'tidak boleh diubah', 'isi sanksi tidak bisa diubah');
select t.throws($q$delete from public.sanctions$q$, 'permanen', 'sanksi tidak bisa dihapus');

-- ===== 4. Menjatuhkan sanksi (RPC) dan efeknya pada akun =====
select t.mk('c1_draft', t.c(1));
select t.login(t.c(1));
select t.lives($q$insert into public.reports (region) values ('Kota Malang')$q$, 'sebelum sanksi: pengguna dapat membuat laporan');
select t.login(t.ub());
select t.throws(format($q$select public.impose_sanction(%L, 'warning', 'x')$q$, t.c(1)), 'forbidden', 'pengguna biasa tidak bisa menjatuhkan sanksi');
select t.login(t.uv());
select t.throws(format($q$select public.impose_sanction(%L, 'warning', 'x')$q$, t.c(1)), 'forbidden', 'verifier tidak bisa menjatuhkan sanksi');
select t.login(t.uad());
select t.throws(format($q$select public.impose_sanction(%L, 'warning', 'x')$q$, t.c(1)), 'forbidden', 'admin utama tidak otomatis moderator (D6)');
select t.anon();
select t.throws(format($q$select public.impose_sanction(%L, 'warning', 'x')$q$, t.c(1)), '42501', 'anon tidak bisa menjatuhkan sanksi');
select t.login(t.um());
select t.throws(format($q$select public.impose_sanction(%L, 'permanent_ban', 'x')$q$, t.c(1)), 'use_propose_permanent_ban', 'blokir permanen tidak bisa dijatuhkan langsung');
select t.throws(format($q$select public.impose_sanction(%L, 'warning', 'x')$q$, t.um()), 'cannot_sanction_self', 'moderator tidak bisa menyanksi dirinya');
select t.throws(format($q$select public.impose_sanction(%L, 'warning', 'x')$q$, t.uv()), 'target_is_staff', 'petugas aktif tidak bisa disanksi lewat fungsi ini');
select t.throws(format($q$select public.impose_sanction(%L, 'warning', 'x')$q$, gen_random_uuid()), 'user_not_found', 'pengguna tidak dikenal');
select t.throws(format($q$select public.impose_sanction(%L, 'warning', '  ')$q$, t.c(1)), 'reason_required', 'alasan sanksi wajib');
select t.throws(format($q$select public.impose_sanction(%L, 'feature_restriction', 'x')$q$, t.c(1)), '23514', 'pembatasan fitur tanpa ends_at ditolak');
select t.throws(format($q$select public.impose_sanction(%L, 'temporary_suspension', 'x', now() - interval '1 hour')$q$, t.c(1)), '23514', 'ends_at di masa lalu ditolak');
select t.throws(format($q$select public.impose_sanction(%L, 'warning', 'x', now() + interval '1 day')$q$, t.c(1)), '23514', 'warning dengan ends_at ditolak');
select t.throws(format($q$select public.impose_sanction(%L, 'warning', 'x', null, %L)$q$, t.c(1), t.rid('s_draftrep')), 'laporan dasar', 'laporan dasar draf ditolak');
select public.impose_sanction(t.c(1), 'warning', 'Peringatan pertama') as sw \gset
select t.save('sw', :'sw'::uuid);
select t.logout();
select t.ok(not private.account_restricted(t.c(1)), 'warning tidak membatasi akun');
select t.login(t.c(1));
select t.lives($q$insert into public.reports (region) values ('Kota Malang')$q$, 'dengan warning pengguna masih dapat membuat laporan');
select t.login(t.um());
select public.impose_sanction(t.c(1), 'feature_restriction', 'Pembatasan 7 hari', now() + interval '7 days') as sf \gset
select t.save('sf', :'sf'::uuid);
select t.logout();
select t.ok(private.account_restricted(t.c(1)), 'pembatasan fitur aktif: akun dibatasi');
select t.login(t.c(1));
select t.throws($q$insert into public.reports (region) values ('Kota Malang')$q$, '42501', 'akun dibatasi tidak bisa membuat laporan (RLS)');
select t.throws(format($q$select public.submit_report(%L)$q$, t.rid('c1_draft')), 'account_restricted', 'akun dibatasi tidak bisa mengirim laporan');
select t.throws(format($q$select public.add_evidence(%L, 'EV-01', %L, 'image/png', 10, %L)$q$, t.rid('c1_draft'), t.rid('c1_draft')::text || '/x.png', repeat('a', 64)), 'account_restricted', 'akun dibatasi tidak bisa menambah bukti');
select t.throws(format($q$insert into storage.objects (bucket_id, name) values ('evidence', %L)$q$, t.rid('c1_draft')::text || '/y.png'), '42501', 'akun dibatasi tidak bisa mengunggah file');
select t.throws(format($q$select public.file_objection(%L, 'x')$q$, t.rid('flow')), 'account_restricted', 'akun dibatasi tidak bisa mengajukan keberatan');
select t.ok(t.count(format('select 1 from public.sanctions where id in (%L, %L)', t.rid('sw'), t.rid('sf'))) = 2, 'pengguna melihat sanksinya sendiri');
select t.login(t.c(2));
select t.ok(t.count('select 1 from public.sanctions') = 0, 'pengguna lain tidak melihat sanksi orang');
select t.logout();

-- kedaluwarsa dan belum mulai tidak membatasi
insert into public.sanctions (user_id, moderator_id, sanction_type, reason, proposed_by, starts_at, ends_at) values
  (t.c(2), t.um(), 'temporary_suspension', 'Fixture kedaluwarsa', t.um(), now() - interval '2 days', now() - interval '1 day'),
  (t.c(3), t.um(), 'temporary_suspension', 'Fixture belum mulai', t.um(), now() + interval '1 day', now() + interval '2 days');
select t.ok(not private.account_restricted(t.c(2)), 'sanksi kedaluwarsa tidak membatasi (diturunkan dari ends_at)');
select t.ok(not private.account_restricted(t.c(3)), 'sanksi yang belum mulai tidak membatasi');

-- penangguhan oleh Admin Utama
select t.login(t.um());
select t.throws(format($q$select public.suspend_sanction(%L, 'x')$q$, t.rid('sf')), 'forbidden', 'moderator tidak bisa menangguhkan sanksi');
select t.login(t.uad());
select t.throws(format($q$select public.suspend_sanction(%L, '  ')$q$, t.rid('sf')), 'reason_required', 'penangguhan wajib beralasan');
select t.throws(format($q$select public.suspend_sanction(%L, 'x')$q$, gen_random_uuid()), 'sanction_not_found', 'sanksi tidak ada');
select t.lives(format($q$select public.suspend_sanction(%L, 'Menunggu hasil banding')$q$, t.rid('sf')), 'admin utama menangguhkan sanksi');
select t.logout();
select t.ok(not private.account_restricted(t.c(1)), 'sanksi ditangguhkan: akun tidak lagi dibatasi');
select t.login(t.uad());
select t.throws(format($q$select public.suspend_sanction(%L, 'lagi')$q$, t.rid('sf')), 'invalid_state', 'hanya sanksi aktif yang dapat ditangguhkan');
select t.logout();

-- ===== 5. Blokir permanen: usul moderator, persetujuan admin, blacklist =====
select t.login(t.uad());
select t.throws(format($q$select public.propose_permanent_ban(%L, 'x')$q$, t.c(4)), 'forbidden', 'admin utama tidak bisa mengusulkan blokir permanen');
select t.login(t.uv());
select t.throws(format($q$select public.propose_permanent_ban(%L, 'x')$q$, t.c(4)), 'forbidden', 'verifier tidak bisa mengusulkan blokir permanen');
select t.login(t.um());
select t.throws(format($q$select public.propose_permanent_ban(%L, '  ')$q$, t.c(4)), 'reason_required', 'usulan blokir wajib beralasan');
select public.propose_permanent_ban(t.c(4), 'Penipuan berulang dengan bukti palsu') as pb \gset
select t.save('pb', :'pb'::uuid);
select t.throws(format($q$select public.approve_permanent_ban(%L)$q$, :'pb'), 'forbidden', 'moderator tidak bisa menyetujui blokir permanen (BR-13)');
select t.logout();
select t.ok(not private.account_restricted(t.c(4)), 'usulan blokir belum berlaku sebelum disetujui');
select t.ok((select count(*) from public.blacklist_entries where user_id = t.c(4)) = 0, 'usulan belum membuat entri blacklist');
select t.login(t.c(4));
select t.ok(t.count('select 1 from public.sanctions') = 0, 'pengguna tidak melihat usulan blokir permanen atas dirinya');
select t.login(t.uad());
select t.throws(format($q$select public.approve_permanent_ban(%L)$q$, t.rid('sw')), 'not_proposed', 'hanya usulan permanen yang dapat disetujui');
select t.throws(format($q$select public.approve_permanent_ban(%L)$q$, gen_random_uuid()), 'sanction_not_found', 'usulan tidak ada');
select t.logout();
delete from vault.decrypted_secrets where name = 'blacklist_pepper';
select t.login(t.uad());
select t.throws(format($q$select public.approve_permanent_ban(%L)$q$, :'pb'), 'pepper_missing', 'tanpa pepper persetujuan blokir gagal tertutup');
select t.logout();
select t.ok((select status = 'proposed' and approved_by is null from public.sanctions where id = :'pb'::uuid), 'kegagalan pepper membatalkan seluruh persetujuan (status tetap proposed)');
insert into vault.decrypted_secrets (name, decrypted_secret) select 'blacklist_pepper', decrypted_secret from t_pepper;
select t.login(t.uad());
select t.lives(format($q$select public.approve_permanent_ban(%L)$q$, :'pb'), 'admin utama menyetujui blokir permanen');
select t.throws(format($q$select public.approve_permanent_ban(%L)$q$, :'pb'), 'not_proposed', 'persetujuan tidak bisa diulang');
select t.ok(t.count(format('select 1 from public.blacklist_entries where user_id = %L and status = ''active''', t.c(4))) = 1, 'admin melihat entri blacklist aktif');
select t.logout();
select t.ok(private.account_restricted(t.c(4)), 'blokir permanen aktif: akun dibatasi');
select t.ok((select status = 'active' and approved_by = t.uad() and approved_by <> proposed_by and approved_at is not null from public.sanctions where id = :'pb'::uuid), 'pemberi persetujuan berbeda dari pengusul');
select t.ok((select email_fingerprint = private.email_fingerprint('c4@example.test') from public.blacklist_entries where user_id = t.c(4)), 'blacklist menyimpan fingerprint ternormalisasi');
select t.ok((select count(*) from public.blacklist_entries where to_jsonb(blacklist_entries)::text like '%c4@example%') = 0, 'blacklist tidak menyimpan email polos');
select t.ok((select count(*) from public.audit_logs where coalesce(new_data::text, '') || coalesce(old_data::text, '') || coalesce(reason, '') like '%@example.test%') = 0, 'audit tidak memuat email polos');
select t.throws($q$delete from public.blacklist_entries$q$, 'permanen', 'blacklist tidak bisa dihapus');
select t.throws($q$update public.blacklist_entries set reason = 'ubah'$q$, 'dicabut', 'blacklist tidak bisa diubah kecuali dicabut lewat banding');

-- constraint BR-13 di tingkat tabel
select set_config('app.sanction_change', 'on', false);
insert into public.sanctions (user_id, moderator_id, sanction_type, reason, proposed_by, status) values (t.c(5), t.um(), 'permanent_ban', 'Usul uji BR-13', t.um(), 'proposed') returning id as pb5 \gset
select t.throws(format($q$update public.sanctions set status = 'active', approved_by = %L, approved_at = now() where id = %L$q$, t.um(), :'pb5'), '23514', 'BR-13: persetujuan oleh pengusul sendiri ditolak constraint');
select t.throws(format($q$update public.sanctions set status = 'active' where id = %L$q$, :'pb5'), '23514', 'BR-13: aktif tanpa persetujuan ditolak constraint');
select t.throws(format($q$update public.sanctions set status = 'lifted', status_note = 'x', status_by = %L, status_at = now() where id = %L$q$, t.uad(), :'pb5'), 'transisi status sanksi tidak sah', 'proposed -> lifted tidak sah');
select set_config('app.sanction_change', 'off', false);

-- penolakan usulan
select t.login(t.um());
select public.propose_permanent_ban(t.c(6), 'Usul yang akan ditolak') as pb6 \gset
select t.save('pb6', :'pb6'::uuid);
select t.login(t.uv());
select t.throws(format($q$select public.reject_permanent_ban(%L, 'x')$q$, :'pb6'), 'forbidden', 'verifier tidak bisa menolak usulan');
select t.login(t.uad());
select t.throws(format($q$select public.reject_permanent_ban(%L, null)$q$, :'pb6'), 'reason_required', 'penolakan usulan wajib beralasan');
select t.lives(format($q$select public.reject_permanent_ban(%L, 'Bukti belum cukup')$q$, :'pb6'), 'admin utama menolak usulan blokir');
select t.logout();
select t.ok(not private.account_restricted(t.c(6)) and (select count(*) from public.blacklist_entries where user_id = t.c(6)) = 0, 'usulan ditolak: tanpa pembatasan dan tanpa blacklist');
select t.login(t.c(6));
select t.ok(t.count('select 1 from public.sanctions') = 0, 'usulan yang ditolak tidak terlihat pengguna');

-- is_email_blacklisted hanya untuk backend tepercaya
select t.logout();
set role service_role;
select t.ok(public.is_email_blacklisted('c4@example.test'), 'is_email_blacklisted: email terblokir terdeteksi');
select t.ok(public.is_email_blacklisted('  C4+baru@Example.TEST '), 'varian huruf besar/+alias terdeteksi');
select t.ok(not public.is_email_blacklisted('orang-lain@example.test'), 'email lain tidak terblokir');
select t.throws('select 1 from public.blacklist_entries', '42501', 'service_role tidak bisa membaca blacklist langsung');
reset role;
select t.login(t.ub());
select t.throws($q$select public.is_email_blacklisted('c4@example.test')$q$, '42501', 'pengguna login tidak bisa memanggil is_email_blacklisted (anti-enumerasi)');
select t.anon();
select t.throws($q$select public.is_email_blacklisted('c4@example.test')$q$, '42501', 'anon tidak bisa memanggil is_email_blacklisted');
select t.logout();

-- akses blacklist: hanya admin utama (D10)
select t.login(t.um());
select t.ok(t.count('select 1 from public.blacklist_entries') = 0, 'moderator tidak melihat blacklist');
select t.login(t.uv());
select t.ok(t.count('select 1 from public.blacklist_entries') = 0, 'verifier tidak melihat blacklist');
select t.login(t.c(4));
select t.ok(t.count('select 1 from public.blacklist_entries') = 0, 'pengguna yang diblacklist tidak melihat entrinya');
select t.anon();
select t.throws('select 1 from public.blacklist_entries', '42501', 'anon ditolak membaca blacklist');
select t.login(t.uad());
select t.throws(format($q$insert into public.blacklist_entries (user_id, sanction_id, email_fingerprint, reason, created_by) values (%L, %L, repeat('a', 64), 'x', %L)$q$, t.c(4), :'pb', t.uad()), '42501', 'admin utama tidak bisa menulis blacklist langsung (hanya RPC)');
select t.throws(format($q$update public.sanctions set status = 'lifted' where id = %L$q$, :'pb'), '42501', 'admin utama tidak bisa mengubah sanksi langsung');
select t.logout();

-- ===== 6. Banding dan verifier yang tidak terlibat (D7) =====
select t.pend('sr', t.ua());
select t.login(t.uv());
select public.start_review(t.rid('sr')) as rsr \gset
select public.submit_review(:'rsr'::uuid, 'recommend_verified', 'Rekomendasi uji');
select t.login(t.um());
select public.open_forum(t.rid('sr'), 'Forum dasar sanksi') as fsr \gset
select t.save('fsr', :'fsr'::uuid);
select public.add_forum_participant(:'fsr'::uuid, t.v2());
select t.login(t.v2());
select public.cast_vote(t.rid('fsr'), 'reject');
select t.login(t.um());
select t.ok((select status = 'closed' from public.decision_forums where id = t.rid('fsr')), 'prasyarat: forum dasar sanksi selesai');
select public.impose_sanction(t.c(7), 'temporary_suspension', 'Laporan palsu berulang', now() + interval '30 days', t.rid('sr'), t.rid('fsr')) as ss \gset
select t.save('ss', :'ss'::uuid);
select t.throws(format($q$select public.impose_sanction(%L, 'warning', 'x', null, %L, %L)$q$, t.c(7), t.rid('sr'), t.rid('o2')), 'forum dasar', 'forum untuk laporan lain ditolak sebagai dasar sanksi');
select t.logout();
select t.ok(private.account_restricted(t.c(7)), 'prasyarat: c7 sedang dibatasi');

select t.login(t.c(2));
select t.throws(format($q$select public.file_appeal(%L, 'bukan sanksi saya')$q$, t.rid('ss')), 'sanction_not_found', 'pengguna lain tidak bisa mengajukan banding atas sanksi orang');
select t.login(t.c(6));
select t.throws(format($q$select public.file_appeal(%L, 'x')$q$, t.rid('pb6')), 'sanction_not_found', 'usulan yang ditolak tidak dapat dibanding');
select t.anon();
select t.throws(format($q$select public.file_appeal(%L, 'x')$q$, t.rid('ss')), '42501', 'anon tidak bisa mengajukan banding');
select t.login(t.c(7));
select t.throws(format($q$select public.file_appeal(%L, '  ')$q$, t.rid('ss')), 'reason_required', 'alasan banding wajib');
select public.file_appeal(t.rid('ss'), 'Saya tidak membuat laporan itu') as ap1 \gset
select t.save('ap1', :'ap1'::uuid);
select t.throws(format($q$select public.file_appeal(%L, 'dobel')$q$, t.rid('ss')), '23505', 'satu banding terbuka per sanksi');
select t.ok(t.count('select 1 from public.appeals') = 1, 'pemohon yang sedang dibatasi tetap dapat banding dan melihat bandingnya');
select t.throws(format($q$update public.appeals set status = 'granted' where id = %L$q$, t.rid('ap1')), '42501', 'pemohon tidak bisa mengubah banding langsung');
select t.login(t.c(2));
select t.ok(t.count('select 1 from public.appeals') = 0, 'pengguna lain tidak melihat banding');

select t.login(t.um());
select t.throws(format($q$select public.assign_appeal_reviewer(%L, %L)$q$, t.rid('ap1'), t.v2()), 'forbidden', 'moderator tidak bisa menugaskan peninjau banding');
select t.login(t.uad());
select t.throws(format($q$select public.assign_appeal_reviewer(%L, %L)$q$, t.rid('ap1'), t.uv()), 'verifier_involved', 'D7: verifier yang memeriksa laporan dasar tidak bisa ditugaskan');
select t.throws(format($q$select public.assign_appeal_reviewer(%L, %L)$q$, t.rid('ap1'), t.v2()), 'verifier_involved', 'D7: peserta forum yang memutus sanksi tidak bisa ditugaskan');
select t.throws(format($q$select public.assign_appeal_reviewer(%L, %L)$q$, t.rid('ap1'), t.um()), 'not_verifier', 'peninjau harus verifier aktif');
select t.throws(format($q$select public.assign_appeal_reviewer(%L, %L)$q$, t.rid('ap1'), t.ub()), 'not_verifier', 'pengguna biasa tidak bisa jadi peninjau');
select t.throws(format($q$select public.assign_appeal_reviewer(%L, %L)$q$, gen_random_uuid(), t.v4()), 'appeal_not_found', 'banding tidak ada');
select t.logout();
select t.ok(not private.appeal_verifier_uninvolved(t.rid('ss'), t.um()), 'D7: moderator penjatuh sanksi terlibat');
select t.ok(not private.appeal_verifier_uninvolved(t.rid('ss'), t.c(7)), 'D7: terhukum sendiri tidak boleh meninjau');
select t.ok(not private.appeal_verifier_uninvolved(t.rid('pb'), t.uad()), 'D7: penyetuju blokir terlibat');
select t.ok(private.appeal_verifier_uninvolved(t.rid('ss'), t.v4()), 'D7: verifier lain yang tidak terlibat sah');
-- jalur pemilik DB: trigger tetap menolak peninjau terlibat
select t.throws(format($q$insert into public.appeals (sanction_id, user_id, reason, status, admin_reviewer_id, verifier_reviewer_id) values (%L, %L, 'uji', 'under_review', %L, %L)$q$, t.rid('pb'), t.c(4), t.uad(), t.um()), 'verifier_involved', 'trigger D7 menolak peninjau terlibat walau lewat pemilik DB');

select t.login(t.uad());
select t.lives(format($q$select public.assign_appeal_reviewer(%L, %L)$q$, t.rid('ap1'), t.v4()), 'admin utama menugaskan verifier yang tidak terlibat');
select t.throws(format($q$select public.assign_appeal_reviewer(%L, %L)$q$, t.rid('ap1'), t.v4()), 'invalid_state', 'penugasan tidak bisa diulang');
select t.throws(format($q$select public.decide_appeal(%L, true, 'langsung')$q$, t.rid('ap1')), 'recommendation_required', 'admin tidak bisa memutus sebelum ada rekomendasi verifier');
select t.logout();
select t.ok((select status = 'under_review' and admin_reviewer_id = t.uad() and verifier_reviewer_id = t.v4() from public.appeals where id = t.rid('ap1')), 'banding under_review dengan admin dan verifier tercatat');
select t.ok(private.account_restricted(t.c(7)), 'FR-33: sanksi tetap berlaku selama banding berjalan');

-- rekomendasi verifier
select t.login(t.uv());
select t.throws(format($q$select public.recommend_appeal(%L, 'grant', 'x')$q$, t.rid('ap1')), 'appeal_not_found', 'verifier yang tidak ditugaskan tidak bisa merekomendasikan');
select t.ok(t.count('select 1 from public.appeals') = 0 and t.count('select 1 from public.sanctions') = 0, 'verifier yang tidak ditugaskan tidak melihat banding maupun sanksi');
select t.login(t.um());
select t.throws(format($q$select public.recommend_appeal(%L, 'grant', 'x')$q$, t.rid('ap1')), 'forbidden', 'moderator tidak bisa merekomendasikan banding');
select t.login(t.v4());
select t.ok(t.count(format('select 1 from public.appeals where id = %L', t.rid('ap1'))) = 1 and t.count(format('select 1 from public.sanctions where id = %L', t.rid('ss'))) = 1, 'verifier yang ditugaskan melihat banding dan sanksinya');
select t.throws(format($q$select public.recommend_appeal(%L, 'mungkin', 'x')$q$, t.rid('ap1')), 'invalid_result', 'rekomendasi harus grant/deny');
select t.throws(format($q$select public.recommend_appeal(%L, 'deny', '  ')$q$, t.rid('ap1')), 'reason_required', 'rekomendasi wajib bercatatan');
select t.lives(format($q$select public.recommend_appeal(%L, 'deny', 'Bukti sanksi kuat, banding tidak meyakinkan')$q$, t.rid('ap1')), 'verifier merekomendasikan menolak banding');
select t.throws(format($q$select public.recommend_appeal(%L, 'grant', 'ganti')$q$, t.rid('ap1')), 'already_recommended', 'rekomendasi tidak bisa diubah');
select t.throws(format($q$update public.appeals set verifier_notes = 'x' where id = %L$q$, t.rid('ap1')), '42501', 'verifier tidak bisa mengubah banding langsung');
select t.throws(format($q$select public.decide_appeal(%L, true, 'x')$q$, t.rid('ap1')), 'forbidden', 'verifier tidak bisa memutus banding');
select t.login(t.um());
select t.throws(format($q$select public.decide_appeal(%L, true, 'x')$q$, t.rid('ap1')), 'forbidden', 'moderator tidak bisa memutus banding');

-- keputusan: tolak (sanksi tetap), sanksi yang ditangguhkan kembali aktif
select t.login(t.uad());
select t.lives(format($q$select public.suspend_sanction(%L, 'Ditangguhkan selama banding')$q$, t.rid('ss')), 'admin menangguhkan sanksi selama banding');
select t.logout();
select t.ok(not private.account_restricted(t.c(7)), 'selama ditangguhkan akun tidak dibatasi');
select t.login(t.uad());
select t.throws(format($q$select public.decide_appeal(%L, true, null)$q$, t.rid('ap1')), 'reason_required', 'keputusan banding wajib beralasan');
select t.throws(format($q$select public.decide_appeal(%L, null, 'x')$q$, t.rid('ap1')), 'invalid_result', 'keputusan banding harus tegas (true/false)');
select t.lives(format($q$select public.decide_appeal(%L, false, 'Sanksi dipertahankan')$q$, t.rid('ap1')), 'admin utama menolak banding');
select t.throws(format($q$select public.decide_appeal(%L, true, 'ulang')$q$, t.rid('ap1')), 'invalid_state', 'banding yang diputuskan tidak bisa diputuskan lagi');
select t.throws(format($q$update public.appeals set reason = 'x' where id = %L$q$, t.rid('ap1')), '42501', 'admin tidak bisa mengubah banding langsung');
select t.logout();
select t.ok(private.account_restricted(t.c(7)) and (select status = 'active' from public.sanctions where id = t.rid('ss')), 'banding ditolak: sanksi yang ditangguhkan kembali aktif');
select t.throws($q$update public.appeals set reason = 'ubah'$q$, 'sudah diputuskan', 'banding yang diputuskan tidak bisa diubah (pemilik DB)');
select t.throws($q$delete from public.appeals$q$, 'permanen', 'banding tidak bisa dihapus');

-- banding kedua dikabulkan
select t.login(t.c(7));
select public.file_appeal(t.rid('ss'), 'Ada bukti baru bahwa akun saya diretas') as ap2 \gset
select t.save('ap2', :'ap2'::uuid);
select t.login(t.uad());
select public.assign_appeal_reviewer(t.rid('ap2'), t.v4());
select t.login(t.v4());
select public.recommend_appeal(t.rid('ap2'), 'grant', 'Bukti peretasan meyakinkan');
select t.login(t.uad());
select t.lives(format($q$select public.decide_appeal(%L, true, 'Bukti peretasan diterima')$q$, t.rid('ap2')), 'admin utama mengabulkan banding');
select t.logout();
select t.ok((select status = 'lifted' and status_note like 'Banding dikabulkan%' and status_by = t.uad() from public.sanctions where id = t.rid('ss')), 'banding dikabulkan: sanksi menjadi lifted dengan catatan');
select t.ok(not private.account_restricted(t.c(7)), 'banding dikabulkan: akun tidak lagi dibatasi');
select t.login(t.c(7));
select t.ok(t.count(format('select 1 from public.sanctions where id = %L and status = ''lifted''', t.rid('ss'))) = 1, 'pengguna melihat sanksinya berstatus lifted');
select t.throws(format($q$select public.file_appeal(%L, 'lagi')$q$, t.rid('ss')), 'sanction_not_found', 'sanksi yang sudah dicabut tidak bisa dibanding lagi');
select t.logout();

-- banding atas blokir permanen: dikabulkan memperbarui sanksi DAN blacklist
select t.login(t.c(4));
select public.file_appeal(t.rid('pb'), 'Akun saya disalahgunakan pihak lain') as ap3 \gset
select t.save('ap3', :'ap3'::uuid);
select t.login(t.uad());
select public.assign_appeal_reviewer(t.rid('ap3'), t.v4());
select t.login(t.v4());
select public.recommend_appeal(t.rid('ap3'), 'grant', 'Terbukti disalahgunakan');
select t.login(t.uad());
select public.decide_appeal(t.rid('ap3'), true, 'Blokir dicabut');
select t.ok(t.count(format('select 1 from public.blacklist_entries where user_id = %L and status = ''lifted'' and lifted_at is not null', t.c(4))) = 1
        and t.count(format('select 1 from public.blacklist_entries where user_id = %L and status = ''active''', t.c(4))) = 0, 'banding dikabulkan: entri blacklist menjadi lifted');
select t.logout();
select t.ok(not private.account_restricted(t.c(4)), 'blokir permanen dicabut: akun tidak dibatasi');
set role service_role;
select t.ok(not public.is_email_blacklisted('c4@example.test'), 'email yang blacklist-nya dicabut tidak lagi terdeteksi');
reset role;

-- ===== 7. Hak tulis langsung dan visibilitas umum =====
select t.login(t.um());
select t.ok(t.count('select 1 from public.sanctions') >= 6 and t.count('select 1 from public.appeals') = 3, 'moderator melihat semua sanksi dan banding');
select t.throws(format($q$update public.sanctions set status = 'lifted' where id = %L$q$, t.rid('sf')), '42501', 'moderator tidak bisa mengubah sanksi langsung');
select t.login(t.uad());
select t.ok(t.count('select 1 from public.sanctions') >= 6 and t.count('select 1 from public.appeals') = 3, 'admin utama melihat semua sanksi dan banding');
select t.login(t.ub());
select t.throws($q$insert into public.sanctions (user_id, moderator_id, sanction_type, reason, proposed_by) values (t.ub(), t.ub(), 'warning', 'x', t.ub())$q$, '42501', 'pengguna tidak bisa menyisipkan sanksi langsung');
select t.throws($q$insert into public.appeals (sanction_id, user_id, reason) values (gen_random_uuid(), t.ub(), 'x')$q$, '42501', 'pengguna tidak bisa menyisipkan banding langsung');
select t.anon();
select t.throws('select 1 from public.sanctions', '42501', 'anon ditolak membaca sanksi');
select t.throws('select 1 from public.appeals', '42501', 'anon ditolak membaca banding');
select t.logout();

-- ===== 8. Audit dan rantai =====
select t.ok((select count(*) from public.audit_logs where action = 'sanction.imposed') >= 2
        and (select count(*) from public.audit_logs where action = 'sanction.proposed_permanent') >= 2
        and (select count(*) from public.audit_logs where action = 'sanction.permanent_approved') >= 1
        and (select count(*) from public.audit_logs where action = 'sanction.permanent_rejected') >= 1
        and (select count(*) from public.audit_logs where action = 'sanction.suspended') >= 2
        and (select count(*) from public.audit_logs where action = 'appeal.filed') >= 3
        and (select count(*) from public.audit_logs where action = 'appeal.assigned') >= 3
        and (select count(*) from public.audit_logs where action = 'appeal.recommended') >= 3
        and (select count(*) from public.audit_logs where action = 'appeal.decided') >= 3,
        'aksi sanksi dan banding tercatat di audit');
select t.ok((select count(*) from public.audit_logs where action = 'appeal.decided' and reason = 'Blokir dicabut' and (new_data ->> 'granted')::boolean) = 1, 'audit keputusan banding memuat alasan dan hasil');
select t.login(t.uad());
select t.ok((select ok from public.verify_audit_chain()), 'rantai audit utuh setelah uji Tahap 6');
select t.logout();
select t.summary();
