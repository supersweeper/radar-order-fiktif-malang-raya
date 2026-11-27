-- Tahap 2: laporan, riwayat, mesin transisi, RPC pelapor.
-- Melanjutkan fixture 10_stage1.test.sql (pengguna t.ua()..t.uu(), peran verifier/moderator/admin).
-- HANYA UNTUK PENGUJIAN LOKAL (database rof_*).

select t.logout();
select t.ok((select count(*) from public.user_roles
              where revoked_at is null and user_id in (t.uv(), t.um(), t.uad())) = 3,
            'prasyarat: fixture peran dari 10_stage1 tersedia');

-- ===== Helper tes =====
create table if not exists t.ids (name text primary key, id uuid not null);
grant all on t.ids to public;
create or replace function t.rid(p text) returns uuid language sql stable as $$ select id from t.ids where name = p $$;
create or replace function t.save(p text, p_id uuid) returns void language sql as
  $$ insert into t.ids values (p, p_id) on conflict (name) do update set id = excluded.id $$;

create or replace function t.mk(p_name text, p_user uuid, p_complete boolean default true) returns uuid
language plpgsql as $$
declare v uuid;
begin
  if p_complete then
    insert into public.reports (user_id, region, district, location_general, incident_type, story,
                                incident_at, lat, lng, app_name, service_category, loss_amount)
    values (p_user, 'Kota Malang', 'Klojen', 'Sekitar Alun-alun', 'Order fiktif',
            'Pelanggan tidak dapat dihubungi dan alamat tujuan tidak ada.',
            now() - interval '1 hour', -7.966612, 112.632611, 'Gojek', 'Food', 25000)
    returning id into v;
  else
    insert into public.reports (user_id, region) values (p_user, 'Kota Malang') returning id into v;
  end if;
  perform t.save(p_name, v);
  return v;
end $$;

-- Membuat laporan lengkap berstatus tertentu lewat jalur impor (GUC mesin), hanya untuk fixture.
create or replace function t.mk_status(p_status text, p_user uuid) returns uuid
language plpgsql as $$
declare v uuid;
begin
  perform set_config('app.report_transition', 'on', true);
  insert into public.reports (user_id, region, district, location_general, incident_type, story,
                              incident_at, status, submitted_at, verified_at)
  values (p_user, 'Kota Malang', 'Klojen', 'Alun-alun', 'Order fiktif',
          'Cerita uji yang cukup panjang untuk lolos batas minimal.', now() - interval '1 day',
          p_status::public.report_status,
          case when p_status <> 'draft' then now() end,
          case when p_status = 'verified' then now() end)
  returning id into v;
  perform set_config('app.report_transition', 'off', true);
  return v;
end $$;

-- ===== 1. Struktur, constraint, relasi (sebagai pemilik DB) =====
select t.throws($q$insert into public.reports (user_id, region) values (t.ua(), 'Surabaya')$q$, '23514', 'region di luar Malang Raya ditolak');
select t.throws($q$insert into public.reports (user_id, story) values (t.ua(), 'terlalu pendek')$q$, '23514', 'story < 20 karakter ditolak');
select t.throws($q$insert into public.reports (user_id, story) values (t.ua(), repeat('x', 701))$q$, '23514', 'story > 700 karakter ditolak');
select t.throws($q$insert into public.reports (user_id, lat) values (t.ua(), -7.9)$q$, '23514', 'lat tanpa lng ditolak (keduanya terisi atau kosong)');
select t.throws($q$insert into public.reports (user_id, lat, lng) values (t.ua(), 91, 112)$q$, '23514', 'lat di luar rentang ditolak');
select t.throws($q$insert into public.reports (user_id, lat, lng) values (t.ua(), -7.9, 181)$q$, '23514', 'lng di luar rentang ditolak');
select t.throws($q$insert into public.reports (user_id, loss_amount) values (t.ua(), -1)$q$, '23514', 'kerugian negatif ditolak');
select t.throws($q$insert into public.reports (user_id, district) values (t.ua(), '  ')$q$, '23514', 'district kosong ditolak');
select t.throws($q$insert into public.reports (user_id, incident_at) values (t.ua(), now() + interval '1 hour')$q$, '22007', 'waktu kejadian di masa depan ditolak');
select t.lives($q$insert into public.reports (user_id, incident_at) values (t.ua(), now() + interval '1 minute')$q$, 'selisih jam perangkat 1 menit masih ditoleransi');
select t.throws($q$insert into public.reports (user_id, region) values (gen_random_uuid(), 'Kota Malang')$q$, 'foreign key', 'reports: FK ke profiles menolak yatim');
select t.throws($q$insert into public.reports (user_id, status) values (t.ua(), 'pending')$q$, 'hanya boleh berstatus draft', 'insert langsung berstatus selain draft ditolak');
select t.throws($q$insert into public.reports (user_id, status) values (t.ua(), 'verified')$q$, 'hanya boleh berstatus draft', 'insert langsung berstatus verified ditolak');
select set_config('app.report_transition', 'on', false);
select t.throws($q$insert into public.reports (user_id, status, region) values (t.ua(), 'pending', 'Kota Malang')$q$, '23514', 'status non-draft wajib lengkap (bahkan lewat jalur impor)');
select set_config('app.report_transition', 'off', false);

select t.mk('own_complete', t.ua());
select t.mk('own_incomplete', t.ua(), false);
select t.throws($q$update public.reports set status = 'verified' where id = t.rid('own_complete')$q$, 'fungsi transisi', 'status tidak bisa diubah langsung (pemilik DB)');
select t.throws($q$update public.reports set user_id = t.ub() where id = t.rid('own_complete')$q$, 'tidak boleh diubah', 'user_id tidak bisa diubah');
select t.throws($q$update public.reports set created_at = now() where id = t.rid('own_complete')$q$, 'tidak boleh diubah', 'created_at tidak bisa diubah');
select t.throws($q$update public.reports set submitted_at = now() where id = t.rid('own_complete')$q$, 'mesin transisi', 'submitted_at tidak bisa diubah langsung');
select t.throws($q$delete from public.reports where id = t.rid('own_complete')$q$, '23503', 'laporan berriwayat tidak bisa dihapus bahkan oleh pemilik DB (FK restrict)');

select t.throws($q$insert into public.report_histories (report_id, actor_role, new_status, action, reason) values (gen_random_uuid(), 'x', 'pending', 'a', 'b')$q$, 'foreign key', 'histories: FK ke reports menolak yatim');
select t.throws($q$insert into public.report_histories (report_id, actor_role, new_status, action, reason) values (t.rid('own_complete'), 'x', 'pending', 'a', '  ')$q$, '23514', 'alasan riwayat wajib');
select t.throws($q$insert into public.report_histories (report_id, actor_role, old_status, new_status, action, reason) values (t.rid('own_complete'), 'x', 'draft', 'draft', 'a', 'b')$q$, '23514', 'riwayat harus mencatat perubahan status');
select t.throws($q$update public.report_histories set reason = 'x'$q$, 'append-only', 'UPDATE riwayat diblokir (pemilik DB)');
select t.throws($q$delete from public.report_histories$q$, 'append-only', 'DELETE riwayat diblokir (pemilik DB)');
select t.throws($q$truncate public.report_histories$q$, 'append-only', 'TRUNCATE riwayat diblokir (pemilik DB)');
select t.ok((select count(*) from public.report_histories where report_id = t.rid('own_complete') and action = 'created' and old_status is null and new_status = 'draft') = 1,
            'riwayat "created" otomatis saat laporan dibuat');
select t.ok((select count(*) from pg_indexes where schemaname = 'public' and indexname in
              ('reports_user_idx','reports_status_submitted_idx','reports_verified_feed_idx','reports_verified_coords_idx','report_histories_report_idx')) = 5,
            'kelima indeks Tahap 2 ada');

-- Hak akses
select t.ok(not has_column_privilege('authenticated', 'public.reports', 'status', 'insert')
            and not has_column_privilege('authenticated', 'public.reports', 'status', 'update')
            and not has_column_privilege('authenticated', 'public.reports', 'submitted_at', 'update')
            and not has_column_privilege('authenticated', 'public.reports', 'verified_at', 'update')
            and not has_column_privilege('authenticated', 'public.reports', 'user_id', 'update')
            and has_column_privilege('authenticated', 'public.reports', 'story', 'update')
            and has_column_privilege('authenticated', 'public.reports', 'user_id', 'insert'),
            'authenticated: kolom status/waktu/user_id tidak bisa ditulis; kolom isi bisa');
select t.ok(not has_table_privilege('authenticated', 'public.reports', 'delete,truncate')
            and not has_table_privilege('authenticated', 'public.report_histories', 'insert,update,delete,truncate')
            and not has_table_privilege('service_role', 'public.report_histories', 'insert,update,delete,truncate')
            and has_table_privilege('authenticated', 'public.report_histories', 'select'),
            'reports tanpa delete; report_histories hanya select (juga untuk service_role)');
select t.ok(not has_function_privilege('authenticated', 'private.transition_report(uuid,public.report_status,text,text,text)', 'execute')
            and not has_function_privilege('authenticated', 'private.report_submit_checks(uuid)', 'execute')
            and has_function_privilege('authenticated', 'public.submit_report(uuid)', 'execute')
            and has_function_privilege('authenticated', 'public.cancel_report(uuid,text)', 'execute')
            and not has_function_privilege('anon', 'public.submit_report(uuid)', 'execute'),
            'mesin transisi tertutup; RPC pelapor hanya untuk authenticated');
select t.ok(not private.account_restricted(t.ua()), 'PLACEHOLDER account_restricted() = false sampai Tahap 6 (sanksi)');

-- Mesin transisi dipanggil langsung (sebagai pemilik DB)
select t.throws($q$select private.transition_report(gen_random_uuid(), 'pending', 'x', 'owner', 'x')$q$, 'report_not_found', 'mesin: laporan tak ditemukan');
select t.throws($q$select private.transition_report(t.rid('own_complete'), 'pending', '   ', 'owner', 'x')$q$, 'reason_required', 'mesin: alasan wajib');

-- ===== 2. Matriks transisi penuh: 7 x 7 status x 4 jenis pelaku =====
create or replace function t.run_matrix() returns jsonb language plpgsql as $$
declare
  statuses text[] := array['draft','pending','under_review','needs_revision','verified','rejected','cancelled'];
  kinds    text[] := array['owner','verifier','moderator','system'];
  expected text[] := array[
    'draft>pending:owner','draft>cancelled:owner','pending>cancelled:owner',
    'pending>under_review:verifier','under_review>needs_revision:verifier',
    'needs_revision>pending:owner','under_review>verified:moderator',
    'under_review>rejected:moderator','under_review>cancelled:moderator',
    'verified>under_review:moderator','verified>rejected:moderator'];
  o text; n text; k text; v uuid; v_ok boolean; v_key text;
  mism text := ''; succ int := 0; total int := 0;
begin
  foreach o in array statuses loop
    foreach n in array statuses loop
      foreach k in array kinds loop
        total := total + 1;
        v := t.mk_status(o, t.ua());
        v_key := o || '>' || n || ':' || k;
        begin
          perform private.transition_report(v, n::public.report_status, 'uji matriks', k, 'matrix');
          v_ok := true;
        exception when others then
          v_ok := false;
        end;
        if v_ok then succ := succ + 1; end if;
        if v_ok <> (v_key = any (expected)) then mism := mism || v_key || ' '; end if;
      end loop;
    end loop;
  end loop;
  return jsonb_build_object('mismatch', mism, 'success', succ, 'total', total);
end $$;

select t.run_matrix() as m \gset
select t.ok((:'m'::jsonb ->> 'total')::int = 196, 'matriks: 196 kombinasi diuji');
select t.ok((:'m'::jsonb ->> 'success')::int = 11, 'matriks: tepat 11 transisi sah yang berhasil');
select t.ok((:'m'::jsonb ->> 'mismatch') = '', 'matriks: tidak ada transisi yang menyimpang dari tabel SRS/rancangan [' || (:'m'::jsonb ->> 'mismatch') || ']');

-- Efek samping transisi: submitted_at, verified_at, riwayat
select t.mk_status('under_review', t.ua()) as rv \gset
select private.transition_report(:'rv'::uuid, 'verified', 'Bukti konsisten', 'moderator', 'decided');
select t.ok((select verified_at is not null and status = 'verified' from public.reports where id = :'rv'::uuid), 'verified_at terisi saat Verified');
select private.transition_report(:'rv'::uuid, 'under_review', 'Keberatan diterima', 'moderator', 'objection_accepted');
select t.ok((select verified_at is not null and status = 'under_review' from public.reports where id = :'rv'::uuid), 'verified_at dipertahankan saat diperiksa ulang');
select t.ok((select count(*) from public.report_histories where report_id = :'rv'::uuid and action in ('created','decided','objection_accepted')) = 3
            and (select actor_role from public.report_histories where report_id = :'rv'::uuid and action = 'decided') = 'moderator',
            'riwayat mencatat created, decided, objection_accepted beserta peran pelaku');

-- ===== 3. Alur pelapor lewat API =====
select t.login(t.ua());
insert into public.reports (region, district, location_general, incident_type, story, incident_at)
values ('Kota Malang', 'Klojen', 'Dekat stasiun', 'Order fiktif',
        'Pesanan dari alamat yang tidak ada dan pelanggan tidak menjawab telepon.', now() - interval '2 hours')
returning id as api_id \gset
select t.save('api', :'api_id'::uuid);
select t.ok((select count(*) from public.reports where id = t.rid('api') and status = 'draft' and user_id = t.ua()) = 1,
            'user A membuat draf lewat API (user_id default = auth.uid())');
select t.ok(t.count('select 1 from public.report_histories where report_id = t.rid(''api'') and action = ''created''') = 1,
            'pemilik melihat riwayat created laporannya');
select t.throws($q$insert into public.reports (region, status) values ('Kota Malang', 'pending')$q$, '42501', 'pemilik tidak bisa menyisipkan status pending');
select t.throws($q$insert into public.reports (region, status) values ('Kota Malang', 'verified')$q$, '42501', 'pemilik tidak bisa menyisipkan status verified');
select t.throws($q$insert into public.reports (user_id, region) values (t.ub(), 'Kota Malang')$q$, '42501', 'user A tidak bisa membuat laporan atas nama user B');
select t.throws($q$insert into public.reports (region, lat) values ('Kota Malang', -7.9)$q$, '23514', 'API: lat tanpa lng ditolak');
select t.ok(t.affected($q$update public.reports set lat = -7.977800, lng = 112.634100, app_name = 'Grab' where id = t.rid('api')$q$) = 1,
            'pemilik dapat mengubah isi draf (koordinat presisi tersimpan apa adanya)');
select t.ok((select lat = -7.977800 and lng = 112.634100 from public.reports where id = t.rid('api')), 'koordinat tersimpan presisi 6 desimal, tidak dibulatkan');
select t.throws($q$update public.reports set status = 'verified' where id = t.rid('api')$q$, '42501', 'pemilik tidak bisa mengubah status');
select t.throws($q$update public.reports set submitted_at = now() where id = t.rid('api')$q$, '42501', 'pemilik tidak bisa mengubah submitted_at');
select t.throws($q$update public.reports set user_id = t.ub() where id = t.rid('api')$q$, '42501', 'pemilik tidak bisa memindahkan laporan ke user lain');
select t.throws($q$select public.submit_report(t.rid('own_incomplete'))$q$, 'report_incomplete', 'kirim draf tidak lengkap ditolak dengan daftar kolom');

select t.lives($q$select public.submit_report(t.rid('api'))$q$, 'pemilik dapat mengirim laporan lengkap');
select t.ok((select status = 'pending' and submitted_at is not null from public.reports where id = t.rid('api')), 'status menjadi Pending dan submitted_at terisi');
select t.ok(t.count('select 1 from public.report_histories where report_id = t.rid(''api'') and old_status = ''draft'' and new_status = ''pending'' and action = ''submitted'' and actor_role = ''owner'' and actor_id = t.ua()') = 1,
            'riwayat draft->pending: aktor, peran, waktu, alasan');
select t.ok(t.affected($q$update public.reports set story = 'diubah setelah dikirim tanpa izin' where id = t.rid('api')$q$) = 0,
            'isi laporan tidak bisa diubah pemilik saat Pending (0 baris)');
select t.throws($q$delete from public.reports where id = t.rid('api')$q$, '42501', 'pemilik tidak bisa menghapus laporan');

-- Pengguna lain tidak melihat / tidak bisa menyentuh
select t.login(t.ub());
select t.ok(t.count('select 1 from public.reports where id = t.rid(''api'')') = 0, 'user B tidak melihat laporan user A');
select t.ok(t.count('select 1 from public.report_histories where report_id = t.rid(''api'')') = 0, 'user B tidak melihat riwayat laporan user A');
select t.throws($q$select public.submit_report(t.rid('api'))$q$, 'report_not_found', 'user B tidak bisa mengirim laporan user A');
select t.throws($q$select public.cancel_report(t.rid('api'), 'iseng')$q$, 'report_not_found', 'user B tidak bisa membatalkan laporan user A');
select t.ok(t.affected($q$update public.reports set story = 'dibajak oleh user B untuk laporan orang lain' where id = t.rid('api')$q$) = 0, 'user B tidak bisa mengubah laporan user A');

-- Pembatalan
select t.login(t.ua());
select t.throws($q$select public.cancel_report(t.rid('api'), null)$q$, 'reason_required', 'pembatalan wajib beralasan (null)');
select t.throws($q$select public.cancel_report(t.rid('api'), '   ')$q$, 'reason_required', 'pembatalan wajib beralasan (kosong)');
select t.lives($q$select public.cancel_report(t.rid('api'), 'Salah memasukkan lokasi kejadian')$q$, 'pemilik dapat membatalkan laporan Pending dengan alasan');
select t.ok((select status = 'cancelled' from public.reports where id = t.rid('api')), 'status menjadi Cancelled');
select t.ok(t.count('select 1 from public.report_histories where report_id = t.rid(''api'') and new_status = ''cancelled'' and reason = ''Salah memasukkan lokasi kejadian''') = 1,
            'alasan pembatalan tersimpan di riwayat');
select t.ok(t.count('select 1 from public.reports where id = t.rid(''api'')') = 1, 'laporan Cancelled tetap tersimpan dan terlihat pemiliknya');
select t.throws($q$select public.submit_report(t.rid('api'))$q$, 'invalid_transition', 'Cancelled tidak bisa dikirim ulang');
select t.throws($q$select public.cancel_report(t.rid('api'), 'lagi')$q$, 'invalid_transition', 'Cancelled tidak bisa dibatalkan lagi');
select t.lives($q$select public.cancel_report(t.rid('own_complete'), 'Draf tidak jadi dikirim')$q$, 'draf dapat dibatalkan dengan alasan (asumsi tercatat di rancangan)');

-- Email belum terverifikasi dan anon
select t.logout();
select t.mk('unverified', t.uu());
select t.login(t.uu());
select t.throws($q$insert into public.reports (region) values ('Kota Malang')$q$, '42501', 'email belum terverifikasi tidak bisa membuat laporan');
select t.throws($q$select public.submit_report(t.rid('unverified'))$q$, 'email_not_verified', 'email belum terverifikasi tidak bisa mengirim laporan');
select t.anon();
select t.throws('select 1 from public.reports', '42501', 'anon ditolak membaca reports');
select t.throws('select 1 from public.report_histories', '42501', 'anon ditolak membaca report_histories');
select t.throws($q$select public.submit_report(gen_random_uuid())$q$, '42501', 'anon tidak dapat memanggil submit_report');
select t.throws($q$select public.cancel_report(gen_random_uuid(), 'x')$q$, '42501', 'anon tidak dapat memanggil cancel_report');

-- ===== 4. Visibilitas petugas dan status langsung =====
select t.logout();
select t.mk('vis_draft', t.ua());
select t.mk('vis_pending', t.ua());
select t.login(t.ua());
select public.submit_report(t.rid('vis_pending'));

select t.login(t.uv());
select t.ok(t.count('select 1 from public.reports where id = t.rid(''vis_draft'')') = 0, 'verifier tidak melihat draf');
select t.ok(t.count('select 1 from public.reports where id = t.rid(''vis_pending'')') = 1, 'verifier melihat laporan Pending');
select t.ok(t.count('select 1 from public.report_histories where report_id = t.rid(''vis_pending'')') = 2, 'verifier melihat riwayat laporan non-draft');
select t.ok(t.count('select 1 from public.report_histories where report_id = t.rid(''vis_draft'')') = 0, 'verifier tidak melihat riwayat draf');
select t.throws($q$update public.reports set status = 'verified' where id = t.rid('vis_pending')$q$, '42501', 'verifier tidak bisa mengubah status langsung');
select t.ok(t.affected($q$update public.reports set story = 'verifier mengubah isi laporan orang lain' where id = t.rid('vis_pending')$q$) = 0, 'verifier tidak bisa mengubah isi laporan orang lain');
select t.login(t.um());
select t.ok(t.count('select 1 from public.reports where id = t.rid(''vis_draft'')') = 0
        and t.count('select 1 from public.reports where id = t.rid(''vis_pending'')') = 1, 'moderator: non-draft saja');
select t.throws($q$update public.reports set status = 'verified' where id = t.rid('vis_pending')$q$, '42501', 'moderator tidak bisa mengubah status langsung');
select t.throws($q$select private.transition_report(t.rid('vis_pending'), 'verified', 'x', 'moderator', 'x')$q$, '42501', 'moderator tidak bisa memanggil mesin transisi secara langsung');
select t.login(t.uad());
select t.ok(t.count('select 1 from public.reports where id = t.rid(''vis_draft'')') = 0
        and t.count('select 1 from public.reports where id = t.rid(''vis_pending'')') = 1, 'admin utama: non-draft saja');
select t.throws($q$update public.reports set status = 'verified' where id = t.rid('vis_pending')$q$, '42501', 'admin utama tidak bisa mengubah status langsung');

-- ===== 5. Perbaikan saat Needs Revision =====
select t.logout();
select t.mk_status('needs_revision', t.ua()) as nr \gset
select t.save('rev', :'nr'::uuid);
select t.login(t.ua());
select t.ok(t.affected($q$update public.reports set story = 'Kronologi diperbaiki: pelanggan menolak menjawab tiga kali panggilan.' where id = t.rid('rev')$q$) = 1,
            'pemilik dapat memperbaiki isi saat Needs Revision');
select t.throws($q$update public.reports set story = null where id = t.rid('rev')$q$, '23514', 'perbaikan tidak boleh mengosongkan kolom wajib');
select t.throws($q$update public.reports set incident_at = now() + interval '2 hours' where id = t.rid('rev')$q$, '22007', 'perbaikan tidak boleh memakai waktu masa depan');
select t.logout();
select t.ok((select count(*) from public.audit_logs where action = 'report.revised' and object_id = t.rid('rev')::text
              and old_data ->> 'story' <> new_data ->> 'story' and new_data ->> 'story' like 'Kronologi diperbaiki%') = 1,
            'perbaikan isi tercatat di audit dengan data lama dan baru');
select t.login(t.ua());
select t.lives($q$select public.submit_report(t.rid('rev'))$q$, 'pemilik dapat mengirim ulang laporan yang diperbaiki');
select t.ok((select status = 'pending' from public.reports where id = t.rid('rev'))
        and t.count('select 1 from public.report_histories where report_id = t.rid(''rev'') and old_status = ''needs_revision'' and new_status = ''pending'' and action = ''resubmitted''') = 1,
            'status kembali Pending, riwayat "resubmitted" tercatat');
select t.ok(t.affected($q$update public.reports set story = 'diubah lagi setelah dikirim ulang ke antrean' where id = t.rid('rev')$q$) = 0,
            'isi beku lagi setelah dikirim ulang (RLS)');
select t.logout();
select t.throws($q$update public.reports set story = 'diubah lewat jalur pemilik DB saat Pending' where id = t.rid('rev')$q$, 'isi laporan beku', 'isi beku juga di tingkat trigger (pemilik DB)');

-- ===== 6. Audit atomik dan rantai =====
select t.ok((select count(*) from public.audit_logs where action = 'report.created') >= 5, 'pembuatan laporan tercatat di audit');
select t.ok((select count(*) from public.audit_logs where action = 'report.submitted' and object_id = t.rid('vis_pending')::text
              and actor_id = t.ua() and actor_role = 'user'
              and old_data ->> 'status' = 'draft' and new_data ->> 'status' = 'pending'
              and new_data ->> 'actor_role' = 'owner' and reason = 'Laporan dikirim oleh pelapor') = 1,
            'audit transisi: aktor, status lama/baru, pelaku, alasan');
select t.ok((select count(*) from public.audit_logs where action = 'report.cancelled' and reason = 'Salah memasukkan lokasi kejadian') = 1,
            'pembatalan tercatat di audit dengan alasan');

-- Transaksi yang gagal tidak boleh meninggalkan riwayat/audit.
select count(*) as h0 from public.report_histories \gset
select count(*) as a0 from public.audit_logs \gset
select t.mk_status('under_review', t.ua()) as ur \gset
select count(*) as h1 from public.report_histories \gset
select count(*) as a1 from public.audit_logs \gset
select t.throws(format($q$select private.transition_report(%L, 'pending', 'x', 'owner', 'x')$q$, :'ur'), 'invalid_transition', 'transisi tidak sah ditolak');
select t.ok((select count(*) from public.report_histories) = :'h1'::bigint and (select count(*) from public.audit_logs) = :'a1'::bigint,
            'transisi yang gagal tidak meninggalkan riwayat maupun audit');

select t.login(t.uad());
select t.ok((select ok from public.verify_audit_chain()), 'rantai audit utuh setelah seluruh uji Tahap 2');

select t.logout();
select t.summary();
