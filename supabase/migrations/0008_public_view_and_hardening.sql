-- Fase 1 Tahap 7: view publik laporan Verified, pengerasan hak akses, indeks FK. Prasyarat: 0001-0007. Idempoten.

-- ---------------------------------------------------------------------------
-- 1. View publik. HANYA kolom aman dan HANYA laporan Verified (keputusan K-04: koordinat presisi;
--    D3: story dan loss_amount ikut). user_id, status, riwayat, bukti, dan data internal TIDAK ada di sini.
--    View berjalan dengan hak pemilik (melewati RLS tabel reports) secara SENGAJA; pembatasan ada pada
--    daftar kolom dan filter status di bawah. Linter Supabase akan menandai 'security definer view': diharapkan.
-- ---------------------------------------------------------------------------
create or replace view public.public_reports
  with (security_invoker = false, security_barrier = true) as
select r.id, r.region, r.district, r.location_general, r.incident_type, r.app_name, r.service_category,
       r.lat, r.lng, r.incident_at, r.verified_at, r.story, r.loss_amount
  from public.reports r
 where r.status = 'verified';

revoke all on public.public_reports from public, anon, authenticated, service_role;
grant select on public.public_reports to anon, authenticated, service_role;

comment on view public.public_reports is
  'Satu-satunya jalur baca publik (anon) ke laporan: hanya status Verified dan kolom aman. Koordinat presisi sengaja ditampilkan (K-04).';

-- ---------------------------------------------------------------------------
-- 2. Pengerasan hak: service_role tidak perlu hak tulis langsung (stage sebelumnya sudah mencabutnya
--    di tabel lain; profiles, reports, user_roles tertinggal). Perubahan dari backend lewat RPC / migrasi.
-- ---------------------------------------------------------------------------
revoke insert, update, delete, truncate on public.profiles, public.reports, public.user_roles from service_role;
revoke references, trigger on all tables in schema public from anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. Indeks untuk setiap kolom FK yang belum punya indeks berawalan kolom itu.
-- ---------------------------------------------------------------------------
do $$
declare r record;
begin
  for r in
    select c.conrelid::regclass::text as tbl, c.conrelid as relid, a.attname as col
      from pg_constraint c
      join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
     where c.contype = 'f' and c.connamespace = 'public'::regnamespace
       and not exists (select 1 from pg_index i where i.indrelid = c.conrelid and i.indkey[0] = c.conkey[1])
  loop
    execute format('create index if not exists %I on %s (%I)',
                   replace(r.tbl, 'public.', '') || '_' || r.col || '_fk_idx', r.tbl, r.col);
  end loop;
end $$;

-- Hak default Supabase pada objek baru tidak diwarisi: tidak ada tabel/fungsi baru di migrasi ini.
