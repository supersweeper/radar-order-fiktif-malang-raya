-- 0003: Fase 1 Tahap 2 — laporan, riwayat status, mesin transisi, RPC pelapor.
-- Rujukan SRS: FR-07..09, FR-18, FR-39..46, FR-58, BR-02, BR-57..59, 4.2, 5.5.
-- Alur transisi = usulan Bagian 4 docs/RANCANGAN_DB_FASE_1.md (disetujui, D1-D2).
-- Aman dijalankan ulang (idempoten).

-- ---------------------------------------------------------------------------
-- 1. reports
--    Draf boleh belum lengkap; status selain 'draft' wajib lengkap (constraint).
--    Koordinat GPS/pin presisi (keputusan K-04): numeric(9,6), keduanya terisi atau kosong.
-- ---------------------------------------------------------------------------
create table if not exists public.reports (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid not null default auth.uid() references public.profiles (id) on delete restrict,
  region           text,
  district         text,
  location_general text,
  incident_type    text,
  story            text,
  incident_at      timestamptz,
  lat              numeric(9,6),
  lng              numeric(9,6),
  app_name         text,
  service_category text,
  loss_amount      numeric(14,0),
  status           public.report_status not null default 'draft',
  submitted_at     timestamptz,
  verified_at      timestamptz,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint reports_region_valid
    check (region is null or region in ('Kota Malang', 'Kabupaten Malang', 'Kota Batu')),
  constraint reports_story_len
    check (story is null or char_length(story) between 20 and 700),
  constraint reports_text_nonblank
    check ((district is null or btrim(district) <> '')
       and (location_general is null or btrim(location_general) <> '')
       and (incident_type is null or btrim(incident_type) <> '')),
  constraint reports_lat_range check (lat is null or lat between -90 and 90),
  constraint reports_lng_range check (lng is null or lng between -180 and 180),
  constraint reports_coords_pair check ((lat is null) = (lng is null)),
  constraint reports_loss_nonneg check (loss_amount is null or loss_amount >= 0),
  constraint reports_complete_unless_draft check (
    status = 'draft'
    or (region is not null and district is not null and location_general is not null
        and incident_type is not null and story is not null and incident_at is not null)
  )
);

create index if not exists reports_user_idx on public.reports (user_id);
create index if not exists reports_status_submitted_idx on public.reports (status, submitted_at);
create index if not exists reports_verified_feed_idx
  on public.reports (verified_at desc, id) where status = 'verified';
create index if not exists reports_verified_coords_idx
  on public.reports (lat, lng) where status = 'verified' and lat is not null;

drop trigger if exists reports_touch on public.reports;
create trigger reports_touch before update on public.reports
  for each row execute function private.touch_updated_at();

-- ---------------------------------------------------------------------------
-- 2. report_histories (append-only). Alasan wajib pada setiap perubahan (FR-18).
-- ---------------------------------------------------------------------------
create table if not exists public.report_histories (
  id         bigint generated always as identity primary key,
  report_id  uuid not null references public.reports (id) on delete restrict,
  actor_id   uuid references public.profiles (id) on delete restrict,
  actor_role text not null,
  old_status public.report_status,
  new_status public.report_status not null,
  action     text not null,
  reason     text not null,
  created_at timestamptz not null default now(),
  constraint report_histories_reason_nonblank check (btrim(reason) <> ''),
  constraint report_histories_changed check (old_status is null or old_status <> new_status)
);

create index if not exists report_histories_report_idx
  on public.report_histories (report_id, created_at);

create or replace function private.report_histories_block()
returns trigger language plpgsql set search_path = '' as $$
begin
  raise exception 'report_histories bersifat append-only (% ditolak)', tg_op using errcode = '42501';
end $$;

drop trigger if exists report_histories_immutable on public.report_histories;
create trigger report_histories_immutable before update or delete on public.report_histories
  for each row execute function private.report_histories_block();
drop trigger if exists report_histories_no_truncate on public.report_histories;
create trigger report_histories_no_truncate before truncate on public.report_histories
  for each statement execute function private.report_histories_block();

-- Setiap baris riwayat otomatis tercatat di audit_logs (atomik, satu transaksi).
create or replace function private.report_histories_audit()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform private.write_audit('report.' || new.action, 'reports', new.report_id::text, new.reason,
    jsonb_build_object('status', new.old_status),
    jsonb_build_object('status', new.new_status, 'actor_role', new.actor_role));
  return null;
end $$;

drop trigger if exists report_histories_audit_trg on public.report_histories;
create trigger report_histories_audit_trg after insert on public.report_histories
  for each row execute function private.report_histories_audit();

-- ---------------------------------------------------------------------------
-- 3. Matriks transisi (satu-satunya sumber kebenaran). Pelaku: owner/verifier/moderator.
-- ---------------------------------------------------------------------------
create or replace function private.report_transition_kinds(
  p_old public.report_status, p_new public.report_status)
returns text[] language sql immutable set search_path = '' as $$
  select coalesce((
    select v.kinds
      from (values
        ('draft',          'pending',        array['owner']),
        ('draft',          'cancelled',      array['owner']),
        ('pending',        'cancelled',      array['owner']),
        ('pending',        'under_review',   array['verifier']),
        ('under_review',   'needs_revision', array['verifier']),
        ('needs_revision', 'pending',        array['owner']),
        ('under_review',   'verified',       array['moderator']),
        ('under_review',   'rejected',       array['moderator']),
        ('under_review',   'cancelled',      array['moderator']),
        ('verified',       'under_review',   array['moderator']),
        ('verified',       'rejected',       array['moderator'])
      ) as v(o, n, kinds)
     where v.o = p_old::text and v.n = p_new::text
  ), array[]::text[])
$$;

-- Penjaga data: status hanya berubah lewat mesin transisi; isi laporan beku setelah dikirim.
create or replace function private.reports_guard()
returns trigger language plpgsql set search_path = '' as $$
declare
  v_engine boolean := coalesce(current_setting('app.report_transition', true), '') = 'on';
begin
  if new.incident_at is not null and new.incident_at > now() + interval '5 minutes' then
    raise exception 'incident_at tidak boleh di masa depan' using errcode = '22007';
  end if;

  if tg_op = 'INSERT' then
    if not v_engine and (new.status <> 'draft' or new.submitted_at is not null or new.verified_at is not null) then
      raise exception 'laporan baru hanya boleh berstatus draft' using errcode = '42501';
    end if;
    return new;
  end if;

  if new.user_id <> old.user_id or new.created_at <> old.created_at then
    raise exception 'user_id dan created_at tidak boleh diubah' using errcode = '42501';
  end if;

  if new.status is distinct from old.status then
    if not v_engine then
      raise exception 'status hanya dapat diubah lewat fungsi transisi' using errcode = '42501';
    end if;
    if cardinality(private.report_transition_kinds(old.status, new.status)) = 0 then
      raise exception 'transisi % -> % tidak sah', old.status, new.status using errcode = '55000';
    end if;
  elsif not v_engine and (new.submitted_at is distinct from old.submitted_at
                       or new.verified_at  is distinct from old.verified_at) then
    raise exception 'submitted_at/verified_at hanya diubah oleh mesin transisi' using errcode = '42501';
  end if;

  if old.status not in ('draft', 'needs_revision')
     and (new.region, new.district, new.location_general, new.incident_type, new.story,
          new.incident_at, new.lat, new.lng, new.app_name, new.service_category, new.loss_amount)
         is distinct from
         (old.region, old.district, old.location_general, old.incident_type, old.story,
          old.incident_at, old.lat, old.lng, old.app_name, old.service_category, old.loss_amount) then
    raise exception 'isi laporan beku pada status %', old.status using errcode = '55000';
  end if;
  return new;
end $$;

drop trigger if exists reports_guard_trg on public.reports;
create trigger reports_guard_trg before insert or update on public.reports
  for each row execute function private.reports_guard();

-- Riwayat 'created' otomatis saat laporan dibuat.
create or replace function private.reports_after_insert()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.report_histories (report_id, actor_id, actor_role, old_status, new_status, action, reason)
  values (new.id, (select auth.uid()), coalesce(private.current_app_role()::text, 'system'),
          null, new.status, 'created', 'Laporan dibuat');
  return null;
end $$;

drop trigger if exists reports_after_insert_trg on public.reports;
create trigger reports_after_insert_trg after insert on public.reports
  for each row execute function private.reports_after_insert();

-- Perbaikan isi saat Needs Revision dicatat ke audit (data lama dan baru), karena
-- verifier perlu tahu apa yang berubah (FR-19, 5.5).
create or replace function private.reports_after_update_revision()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if old.status = 'needs_revision' and new.status = 'needs_revision'
     and (new.region, new.district, new.location_general, new.incident_type, new.story,
          new.incident_at, new.lat, new.lng, new.app_name, new.service_category, new.loss_amount)
         is distinct from
         (old.region, old.district, old.location_general, old.incident_type, old.story,
          old.incident_at, old.lat, old.lng, old.app_name, old.service_category, old.loss_amount) then
    perform private.write_audit('report.revised', 'reports', new.id::text,
      'Pelapor memperbaiki isi laporan',
      jsonb_build_object('region', old.region, 'district', old.district,
        'location_general', old.location_general, 'incident_type', old.incident_type,
        'story', old.story, 'incident_at', old.incident_at, 'lat', old.lat, 'lng', old.lng,
        'app_name', old.app_name, 'service_category', old.service_category, 'loss_amount', old.loss_amount),
      jsonb_build_object('region', new.region, 'district', new.district,
        'location_general', new.location_general, 'incident_type', new.incident_type,
        'story', new.story, 'incident_at', new.incident_at, 'lat', new.lat, 'lng', new.lng,
        'app_name', new.app_name, 'service_category', new.service_category, 'loss_amount', new.loss_amount));
  end if;
  return null;
end $$;

drop trigger if exists reports_after_update_revision_trg on public.reports;
create trigger reports_after_update_revision_trg after update on public.reports
  for each row execute function private.reports_after_update_revision();

-- ---------------------------------------------------------------------------
-- 4. Mesin transisi. Hanya dipanggil fungsi RPC yang sudah memeriksa kewenangan.
--    p_as = kewenangan yang dipakai pelaku (owner/verifier/moderator).
-- ---------------------------------------------------------------------------
create or replace function private.transition_report(
  p_report_id uuid, p_new public.report_status, p_reason text, p_as text, p_action text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  r        public.reports;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  select * into r from public.reports where id = p_report_id for update;
  if not found then
    raise exception 'report_not_found' using errcode = 'P0002';
  end if;
  if not (p_as = any (private.report_transition_kinds(r.status, p_new))) then
    raise exception 'invalid_transition: % -> % (oleh %)', r.status, p_new, p_as using errcode = '55000';
  end if;
  if v_reason is null then
    raise exception 'reason_required' using errcode = '22023';
  end if;

  perform set_config('app.report_transition', 'on', true);
  update public.reports
     set status       = p_new,
         submitted_at = case when p_new = 'pending'  then now() else submitted_at end,
         verified_at  = case when p_new = 'verified' then now() else verified_at end
   where id = p_report_id;
  insert into public.report_histories (report_id, actor_id, actor_role, old_status, new_status, action, reason)
  values (p_report_id, (select auth.uid()), p_as, r.status, p_new, p_action, v_reason);
  perform set_config('app.report_transition', 'off', true);
end $$;

-- Pemeriksaan kelayakan kirim. Tahap 3 menambahkan syarat EV-01 (keputusan D2)
-- dengan 'create or replace' pada fungsi ini.
create or replace function private.report_submit_checks(p_report_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  r       public.reports;
  v_miss  text[];
begin
  select * into r from public.reports where id = p_report_id;
  if not found then
    raise exception 'report_not_found' using errcode = 'P0002';
  end if;
  v_miss := array_remove(array[
    case when r.region           is null then 'region' end,
    case when r.district         is null then 'district' end,
    case when r.location_general is null then 'location_general' end,
    case when r.incident_type    is null then 'incident_type' end,
    case when r.story            is null then 'story' end,
    case when r.incident_at      is null then 'incident_at' end], null);
  if cardinality(v_miss) > 0 then
    raise exception 'report_incomplete: %', array_to_string(v_miss, ', ') using errcode = '22023';
  end if;
end $$;

-- PLACEHOLDER sampai Tahap 6 (sanksi): belum ada tabel sanctions, jadi selalu false.
-- Tahap 6 mengganti isi fungsi ini; kebijakan RLS dan RPC di bawah sudah memanggilnya.
create or replace function private.account_restricted(p_user_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select false
$$;

-- ---------------------------------------------------------------------------
-- 5. RPC pelapor
-- ---------------------------------------------------------------------------
create or replace function public.submit_report(p_report_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_actor  uuid := (select auth.uid());
  v_owner  uuid;
  v_status public.report_status;
begin
  if v_actor is null then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select user_id, status into v_owner, v_status from public.reports where id = p_report_id;
  if not found or v_owner <> v_actor then
    raise exception 'report_not_found' using errcode = 'P0002';
  end if;
  if not private.email_verified() then
    raise exception 'email_not_verified' using errcode = '42501';
  end if;
  if private.account_restricted(v_actor) then
    raise exception 'account_restricted' using errcode = '42501';
  end if;
  perform private.report_submit_checks(p_report_id);
  if v_status = 'needs_revision' then
    perform private.transition_report(p_report_id, 'pending',
      'Laporan diperbaiki dan dikirim ulang oleh pelapor', 'owner', 'resubmitted');
  else
    perform private.transition_report(p_report_id, 'pending',
      'Laporan dikirim oleh pelapor', 'owner', 'submitted');
  end if;
end $$;

create or replace function public.cancel_report(p_report_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := (select auth.uid());
  v_owner uuid;
begin
  if v_actor is null then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select user_id into v_owner from public.reports where id = p_report_id;
  if not found or v_owner <> v_actor then
    raise exception 'report_not_found' using errcode = 'P0002';
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'reason_required' using errcode = '22023';
  end if;
  perform private.transition_report(p_report_id, 'cancelled', p_reason, 'owner', 'cancelled');
end $$;

-- ---------------------------------------------------------------------------
-- 6. RLS dan hak akses (deny by default)
-- ---------------------------------------------------------------------------
alter table public.reports          enable row level security;
alter table public.report_histories enable row level security;

revoke all on table public.reports          from public, anon, authenticated;
revoke all on table public.report_histories from public, anon, authenticated;
revoke all on sequence public.report_histories_id_seq from public, anon, authenticated;
revoke insert, update, delete, truncate on table public.report_histories from service_role;

grant select on public.reports, public.report_histories to authenticated;
-- 'status' dan kolom waktu sengaja TIDAK diberi hak tulis: hanya mesin transisi.
grant insert (user_id, region, district, location_general, incident_type, story, incident_at,
              lat, lng, app_name, service_category, loss_amount) on public.reports to authenticated;
grant update (region, district, location_general, incident_type, story, incident_at,
              lat, lng, app_name, service_category, loss_amount) on public.reports to authenticated;

drop policy if exists reports_select on public.reports;
create policy reports_select on public.reports for select to authenticated
  using (
    user_id = (select auth.uid())
    or ((select private.is_staff()) and status <> 'draft')
  );

drop policy if exists reports_insert_own on public.reports;
create policy reports_insert_own on public.reports for insert to authenticated
  with check (
    user_id = (select auth.uid())
    and status = 'draft'
    and (select private.email_verified())
    and not (select private.account_restricted((select auth.uid())))
  );

drop policy if exists reports_update_own on public.reports;
create policy reports_update_own on public.reports for update to authenticated
  using (user_id = (select auth.uid()) and status in ('draft', 'needs_revision'))
  with check (user_id = (select auth.uid()) and status in ('draft', 'needs_revision'));

-- Riwayat terlihat bila laporannya terlihat (pemilik: semua status; petugas: non-draft).
drop policy if exists report_histories_select on public.report_histories;
create policy report_histories_select on public.report_histories for select to authenticated
  using (exists (select 1 from public.reports r where r.id = report_histories.report_id));

revoke all on function public.submit_report(uuid)         from public, anon, authenticated;
revoke all on function public.cancel_report(uuid, text)   from public, anon, authenticated;
grant execute on function public.submit_report(uuid)       to authenticated;
grant execute on function public.cancel_report(uuid, text) to authenticated;

-- Fungsi private baru ditutup; hanya yang dipakai kebijakan RLS yang dibuka.
revoke all on all functions in schema private from public, anon, authenticated;
grant execute on function private.current_app_role()           to authenticated;
grant execute on function private.has_role(public.app_role[])  to authenticated;
grant execute on function private.is_staff()                   to authenticated;
grant execute on function private.email_verified()             to authenticated;
grant execute on function private.account_restricted(uuid)     to authenticated;

comment on table public.reports is
  'Laporan inti. Status hanya berubah lewat private.transition_report (RPC); isi beku setelah dikirim.';
comment on table public.report_histories is
  'Riwayat status append-only. Terlihat oleh pemilik laporan dan petugas (non-draft).';
