-- Tahap 1: struktur, constraint, RLS per peran, eskalasi, perubahan peran, audit log.
-- HANYA UNTUK PENGUJIAN LOKAL (database rof_*). Dijalankan setelah migrasi 0001-0002.

-- Pengguna uji
create or replace function t.ua()  returns uuid language sql immutable as $$ select '00000000-0000-0000-0000-0000000000a1'::uuid $$; -- user A (email terverifikasi)
create or replace function t.ub()  returns uuid language sql immutable as $$ select '00000000-0000-0000-0000-0000000000a2'::uuid $$; -- user B
create or replace function t.uv()  returns uuid language sql immutable as $$ select '00000000-0000-0000-0000-0000000000a3'::uuid $$; -- verifier
create or replace function t.um()  returns uuid language sql immutable as $$ select '00000000-0000-0000-0000-0000000000a4'::uuid $$; -- moderator
create or replace function t.uad() returns uuid language sql immutable as $$ select '00000000-0000-0000-0000-0000000000a5'::uuid $$; -- admin utama
create or replace function t.uu()  returns uuid language sql immutable as $$ select '00000000-0000-0000-0000-0000000000a6'::uuid $$; -- email BELUM terverifikasi
create or replace function t.ux()  returns uuid language sql immutable as $$ select '00000000-0000-0000-0000-0000000000a7'::uuid $$; -- target penunjukan peran

select t.logout();

-- ===== Fixture (sebagai superuser) =====
insert into auth.users (id, email, email_confirmed_at) values
  (t.ua(),  'a@example.test',  now()),
  (t.ub(),  'b@example.test',  now()),
  (t.uv(),  'v@example.test',  now()),
  (t.um(),  'm@example.test',  now()),
  (t.uad(), 'ad@example.test', now()),
  (t.uu(),  'u@example.test',  null),
  (t.ux(),  'x@example.test',  now());

select t.ok((select count(*) from public.profiles) = 7, 'profil dibuat otomatis untuk setiap akun Auth baru');

-- Penunjukan awal (bootstrap oleh pemilik DB, tanpa auth.uid())
insert into public.user_roles (user_id, role, reason) values
  (t.uv(),  'verifier',    'bootstrap uji'),
  (t.um(),  'moderator',   'bootstrap uji'),
  (t.uad(), 'admin_utama', 'bootstrap uji');

-- ===== 1. Struktur dan hak default =====
select t.ok((select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
              where n.nspname = 'public' and c.relkind in ('r','p') and not c.relrowsecurity) = 0,
            'semua tabel public mengaktifkan RLS');
select t.ok((select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
              where n.nspname = 'public' and c.relkind in ('r','p')
                and has_table_privilege('anon', c.oid, 'select,insert,update,delete,truncate,references,trigger')) = 0,
            'anon tidak punya hak apa pun pada tabel public');
select t.ok((select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname in ('public','private') and has_function_privilege('anon', p.oid, 'execute')) = 0,
            'anon tidak dapat mengeksekusi fungsi public/private mana pun');
select t.ok(not has_table_privilege('authenticated', 'public.profiles', 'insert,delete,truncate'),
            'authenticated tidak bisa insert/delete/truncate profiles');
select t.ok(has_column_privilege('authenticated', 'public.profiles', 'display_name', 'update')
            and not has_column_privilege('authenticated', 'public.profiles', 'id', 'update')
            and not has_column_privilege('authenticated', 'public.profiles', 'updated_at', 'update'),
            'authenticated hanya boleh update kolom display_name');
select t.ok(has_table_privilege('authenticated', 'public.user_roles', 'select')
            and not has_table_privilege('authenticated', 'public.user_roles', 'insert,update,delete,truncate'),
            'user_roles: authenticated hanya select');
select t.ok(has_table_privilege('authenticated', 'public.audit_logs', 'select')
            and not has_table_privilege('authenticated', 'public.audit_logs', 'insert,update,delete,truncate')
            and not has_table_privilege('service_role', 'public.audit_logs', 'insert,update,delete,truncate'),
            'audit_logs: authenticated dan service_role tidak punya hak tulis');
select t.ok(not has_sequence_privilege('authenticated', 'public.audit_logs_id_seq', 'usage,select,update'),
            'sekuens audit_logs tertutup untuk authenticated');
select t.ok(not has_function_privilege('authenticated', 'private.write_audit(text,text,text,text,jsonb,jsonb)', 'execute')
            and not has_function_privilege('authenticated', 'private.handle_new_user()', 'execute')
            and not has_function_privilege('authenticated', 'private.audit_row_hash(public.audit_logs)', 'execute'),
            'fungsi internal (audit/trigger) tidak dapat dieksekusi authenticated');

-- ===== 2. Relasi dan constraint =====
select t.throws($q$insert into public.profiles (id) values (gen_random_uuid())$q$, 'foreign key', 'profiles: FK ke auth.users menolak yatim');
select t.throws($q$delete from auth.users where id = t.ua()$q$, 'foreign key', 'akun Auth dengan profil tidak bisa dihapus (RESTRICT)');
select t.throws($q$update public.profiles set display_name = '   ' where id = t.ua()$q$, '23514', 'display_name kosong ditolak');
select t.throws($q$update public.profiles set display_name = repeat('x', 51) where id = t.ua()$q$, '23514', 'display_name > 50 karakter ditolak');
select t.throws($q$insert into public.user_roles (user_id, role, reason) values (gen_random_uuid(), 'verifier', 'x')$q$, 'foreign key', 'user_roles: FK menolak user yatim');
select t.throws($q$insert into public.user_roles (user_id, role, reason) values (t.ub(), 'user', 'x')$q$, '23514', 'peran user biasa tidak disimpan sebagai penunjukan');
select t.throws($q$insert into public.user_roles (user_id, role, reason) values (t.ub(), 'verifier', '  ')$q$, '23514', 'alasan penunjukan wajib');
select t.throws($q$insert into public.user_roles (user_id, role, reason) values (t.uv(), 'moderator', 'dobel')$q$, '23505', 'maks. satu peran aktif per pengguna');
select t.throws($q$update public.user_roles set revoked_at = now() where user_id = t.uv()$q$, '23514', 'pencabutan tanpa alasan ditolak');
select t.throws($q$update public.user_roles set role = 'admin_utama' where user_id = t.uv()$q$, 'tidak boleh diubah', 'kolom penunjukan peran tidak bisa diubah (bahkan oleh pemilik DB)');
select t.throws($q$delete from public.user_roles where user_id = t.uv()$q$, 'tidak boleh dihapus', 'user_roles tidak bisa dihapus');
select t.throws($q$truncate public.user_roles$q$, 'tidak boleh di-truncate', 'user_roles tidak bisa di-truncate');

-- ===== 3. RLS: profiles =====
select t.login(t.ua());
select t.ok(t.count('select 1 from public.profiles') = 1, 'user A hanya melihat profil sendiri');
select t.ok(t.affected($q$update public.profiles set display_name = 'Andi' where id = t.ua()$q$) = 1, 'user A dapat mengubah display_name sendiri');
select t.ok(t.affected($q$update public.profiles set display_name = 'Hack' where id = t.ub()$q$) = 0, 'user A tidak dapat mengubah profil user B (0 baris)');
select t.throws($q$update public.profiles set id = gen_random_uuid() where id = t.ua()$q$, '42501', 'user tidak bisa mengubah kolom id');
select t.throws($q$insert into public.profiles (id) values (t.ua())$q$, '42501', 'user tidak bisa insert profil');
select t.throws($q$delete from public.profiles where id = t.ua()$q$, '42501', 'user tidak bisa menghapus profil');
select t.ok((select private.email_verified()), 'email_verified() benar untuk user A');
select t.ok(not (select private.is_staff()) and (select private.current_app_role()) = 'user', 'user A berperan user, bukan petugas');

select t.login(t.uu());
select t.ok(not (select private.email_verified()), 'email_verified() salah untuk email yang belum terverifikasi');

select t.login(t.uv());
select t.ok(t.count('select 1 from public.profiles') = 7, 'verifier melihat seluruh profil');
select t.ok((select private.is_staff()) and (select private.current_app_role()) = 'verifier', 'verifier terdeteksi sebagai petugas');
select t.login(t.um());
select t.ok(t.count('select 1 from public.profiles') = 7, 'moderator melihat seluruh profil');
select t.login(t.uad());
select t.ok(t.count('select 1 from public.profiles') = 7, 'admin utama melihat seluruh profil');
select t.anon();
select t.throws('select 1 from public.profiles', '42501', 'anon ditolak membaca profiles');

-- ===== 4. RLS: user_roles dan eskalasi =====
select t.login(t.ua());
select t.ok(t.count('select 1 from public.user_roles') = 0, 'user biasa tidak melihat daftar peran petugas');
select t.throws($q$insert into public.user_roles (user_id, role, reason) values (t.ua(), 'admin_utama', 'naik sendiri')$q$, '42501', 'user tidak bisa memberi dirinya peran (INSERT)');
select t.throws($q$update public.user_roles set revoked_at = now()$q$, '42501', 'user tidak bisa mengubah user_roles (UPDATE)');
select t.throws($q$delete from public.user_roles$q$, '42501', 'user tidak bisa menghapus user_roles (DELETE)');
select t.throws($q$select public.admin_set_role(t.ua(), 'admin_utama', 'naik sendiri')$q$, 'forbidden', 'user tidak bisa memanggil admin_set_role');
select t.throws($q$select public.admin_revoke_role(t.uv(), 'sabotase')$q$, 'forbidden', 'user tidak bisa memanggil admin_revoke_role');
select t.throws($q$select public.verify_audit_chain()$q$, 'forbidden', 'user tidak bisa memanggil verify_audit_chain');
select t.throws($q$select private.write_audit('x','y','z',null,null,null)$q$, '42501', 'user tidak bisa memalsukan audit lewat write_audit');

select t.login(t.uv());
select t.ok(t.count('select 1 from public.user_roles') = 1, 'verifier hanya melihat peran sendiri');
select t.throws($q$select public.admin_set_role(t.uv(), 'admin_utama', 'naik sendiri')$q$, 'forbidden', 'verifier tidak bisa menaikkan diri');
select t.login(t.um());
select t.ok(t.count('select 1 from public.user_roles') = 3, 'moderator melihat daftar petugas');
select t.throws($q$select public.admin_set_role(t.ub(), 'verifier', 'x')$q$, 'forbidden', 'moderator tidak bisa menunjuk peran');
select t.throws($q$select public.admin_set_role(t.um(), 'admin_utama', 'naik sendiri')$q$, 'forbidden', 'moderator tidak bisa menaikkan diri');
select t.anon();
select t.throws($q$select public.admin_set_role(t.ub(), 'verifier', 'x')$q$, '42501', 'anon tidak dapat mengeksekusi admin_set_role');

-- ===== 5. Perubahan peran oleh Admin Utama =====
select t.login(t.uad());
select t.ok(t.count('select 1 from public.user_roles') = 3, 'admin melihat semua peran');
select t.throws($q$select public.admin_set_role(t.ux(), 'verifier', '  ')$q$, 'reason_required', 'alasan wajib saat menunjuk peran');
select t.throws($q$select public.admin_set_role(t.ux(), 'user', 'x')$q$, 'invalid_role', 'peran user ditolak (gunakan revoke)');
select t.throws($q$select public.admin_set_role(t.uad(), 'moderator', 'x')$q$, 'cannot_change_own_role', 'admin tidak bisa mengubah perannya sendiri');
select t.throws($q$select public.admin_revoke_role(t.uad(), 'x')$q$, 'cannot_change_own_role', 'admin tidak bisa mencabut perannya sendiri');
select t.throws($q$select public.admin_set_role(gen_random_uuid(), 'verifier', 'x')$q$, 'user_not_found', 'target tak dikenal ditolak');
select t.lives($q$select public.admin_set_role(t.ux(), 'verifier', 'penunjukan uji')$q$, 'admin dapat menunjuk verifier');
select t.ok(t.count('select 1 from public.user_roles where user_id = t.ux() and revoked_at is null and role = ''verifier''') = 1, 'ux kini verifier aktif');
select t.throws($q$select public.admin_set_role(t.ux(), 'verifier', 'x')$q$, 'role_already_assigned', 'peran yang sama tidak bisa ditunjuk dua kali');
select t.lives($q$select public.admin_set_role(t.ux(), 'moderator', 'naik jabatan uji')$q$, 'admin dapat mengganti peran');
select t.ok(t.count('select 1 from public.user_roles where user_id = t.ux() and revoked_at is null') = 1
            and t.count('select 1 from public.user_roles where user_id = t.ux() and role = ''verifier'' and revoke_reason like ''diganti ke moderator%''') = 1,
            'penggantian: peran lama dicabut dengan alasan, tepat satu peran aktif');
select t.login(t.ux());
select t.ok((select private.current_app_role()) = 'moderator', 'ux kini bertindak sebagai moderator');
select t.login(t.uad());
select t.lives($q$select public.admin_revoke_role(t.ux(), 'dicabut uji')$q$, 'admin dapat mencabut peran');
select t.throws($q$select public.admin_revoke_role(t.ux(), 'lagi')$q$, 'no_active_role', 'mencabut tanpa peran aktif ditolak');
select t.login(t.ux());
select t.ok((select private.current_app_role()) = 'user', 'setelah dicabut, ux kembali menjadi user');
select t.throws($q$select public.admin_set_role(t.ub(), 'verifier', 'x')$q$, 'forbidden', 'peran yang dicabut tidak lagi punya kewenangan');
select t.login(t.uad());
select t.ok(t.count('select 1 from public.user_roles where user_id = t.ux()') = 2, 'riwayat peran ux tetap tersimpan (2 baris)');

-- ===== 6. Audit log =====
select t.logout();
select t.ok((select count(*) from public.audit_logs where action = 'role.granted' and actor_id is null and actor_role = 'system') = 3,
            'bootstrap tercatat sebagai aktor system');
select t.ok((select count(*) from public.audit_logs where action = 'role.granted' and actor_id = t.uad()
              and actor_role = 'admin_utama' and reason = 'penunjukan uji'
              and new_data ->> 'user_id' = t.ux()::text and new_data ->> 'role' = 'verifier') = 1,
            'penunjukan peran tercatat: aktor, peran aktor, alasan, data baru');
select t.ok((select count(*) from public.audit_logs where action = 'role.revoked' and actor_id = t.uad()
              and reason = 'dicabut uji' and old_data is not null and new_data ->> 'revoked_at' is not null) = 1,
            'pencabutan peran tercatat dengan data lama dan baru');
select t.ok((select count(*) from public.audit_logs where action = 'role.revoked' and reason like 'diganti ke moderator%') = 1,
            'penggantian peran tercatat sebagai pencabutan');

select t.login(t.uad());
select t.ok(t.count('select 1 from public.audit_logs') = 7, 'admin membaca audit_logs: tepat 7 baris (3 bootstrap, 1 penunjukan, 2 penggantian, 1 pencabutan)');
select t.throws($q$insert into public.audit_logs (action, object_type, object_id, prev_hash, row_hash) values ('x','y','z','','')$q$, '42501', 'admin pun tidak bisa INSERT langsung ke audit_logs');
select t.login(t.um());
select t.ok(t.count('select 1 from public.audit_logs') = 0, 'moderator tidak melihat audit_logs');
select t.login(t.uv());
select t.ok(t.count('select 1 from public.audit_logs') = 0, 'verifier tidak melihat audit_logs');
select t.login(t.ua());
select t.ok(t.count('select 1 from public.audit_logs') = 0, 'user tidak melihat audit_logs');
select t.throws($q$update public.audit_logs set reason = 'x'$q$, '42501', 'user tidak bisa UPDATE audit_logs');
select t.throws($q$delete from public.audit_logs$q$, '42501', 'user tidak bisa DELETE audit_logs');
select t.anon();
select t.throws('select 1 from public.audit_logs', '42501', 'anon ditolak membaca audit_logs');

select t.logout();
select t.throws($q$update public.audit_logs set reason = 'tamper'$q$, 'append-only', 'UPDATE diblokir trigger (pemilik DB)');
select t.throws($q$delete from public.audit_logs$q$, 'append-only', 'DELETE diblokir trigger (pemilik DB)');
select t.throws($q$truncate public.audit_logs$q$, 'append-only', 'TRUNCATE diblokir trigger (pemilik DB)');

-- Nilai hash kiriman penulis selalu ditimpa server.
insert into public.audit_logs (action, object_type, object_id, prev_hash, row_hash)
values ('forge.attempt', 'test', '1', 'palsu', 'palsu');
select t.ok((select prev_hash <> 'palsu' and row_hash <> 'palsu' and length(row_hash) = 64
               from public.audit_logs where action = 'forge.attempt'), 'hash palsu kiriman penulis ditimpa server');

select t.login(t.uad());
select t.ok((select ok from public.verify_audit_chain()), 'rantai audit utuh');
select t.ok((select checked from public.verify_audit_chain()) = (select count(*) from public.audit_logs), 'verify memeriksa seluruh baris');

-- Perusakan oleh superuser (trigger dimatikan) HARUS terdeteksi. Hasil ditangkap lewat \gset
-- karena ROLLBACK membuang catatan t.results yang ditulis di dalam transaksi.
select t.logout();
begin;
alter table public.audit_logs disable trigger audit_logs_immutable;
update public.audit_logs set reason = 'dirusak' where id = (select min(id) from public.audit_logs);
select t.login(t.uad());
select (select not ok from public.verify_audit_chain()) as tamper_update_detected,
       (select first_bad_id from public.verify_audit_chain()) = (select min(id) from public.audit_logs) as tamper_first_id_ok \gset
rollback;
select t.logout();
select t.ok(:'tamper_update_detected'::boolean, 'perubahan isi baris audit terdeteksi verify_audit_chain');
select t.ok(:'tamper_first_id_ok'::boolean, 'verify melaporkan id baris pertama yang rusak');

begin;
alter table public.audit_logs disable trigger audit_logs_immutable;
delete from public.audit_logs where id = (select id from public.audit_logs order by id offset 3 limit 1);
select t.login(t.uad());
select (select not ok from public.verify_audit_chain()) as tamper_delete_detected \gset
rollback;
select t.logout();
select t.ok(:'tamper_delete_detected'::boolean, 'penghapusan baris di tengah rantai terdeteksi');

select t.login(t.uad());
select t.ok((select ok from public.verify_audit_chain()), 'rantai kembali utuh setelah rollback uji perusakan');

select t.logout();
select t.summary();
