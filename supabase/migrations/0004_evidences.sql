-- Fase 1 Tahap 3: bukti (evidences), versi bukti, bucket Storage privat, kebijakan Storage,
-- RPC add_evidence / replace_evidence_version, dan syarat EV-01 saat kirim laporan (D2).
-- Prasyarat: 0001-0003 dan Storage Supabase aktif (skema storage).
-- Idempoten: aman dijalankan ulang.

do $$ begin
  if to_regclass('storage.objects') is null or to_regclass('storage.buckets') is null then
    raise exception 'Skema storage tidak ditemukan. Aktifkan Storage di project Supabase sebelum migrasi ini.'
      using errcode = '55000';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 1. Tabel
-- ---------------------------------------------------------------------------
create table if not exists public.evidences (
  id                         uuid primary key default gen_random_uuid(),
  report_id                  uuid not null references public.reports(id) on delete restrict,
  evidence_type              public.evidence_type not null,
  declared_three_calls       boolean not null default false,
  declared_single_screenshot boolean not null default false,
  created_at                 timestamptz not null default now(),
  -- Satu item per jenis bukti per laporan; mengganti file = versi baru (asumsi tercatat).
  constraint evidences_one_per_type unique (report_id, evidence_type),
  -- BR-66/FR-52: klaim tiga panggilan harus disertai pernyataan satu screenshot utuh.
  constraint evidences_three_calls_need_single
    check (not declared_three_calls or declared_single_screenshot)
);

create table if not exists public.evidence_versions (
  id                uuid primary key default gen_random_uuid(),
  evidence_id       uuid not null references public.evidences(id) on delete restrict,
  version_number    integer not null check (version_number >= 1),
  uploaded_by       uuid not null references public.profiles(id) on delete restrict,
  private_file_path text not null unique
                      check (private_file_path ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[A-Za-z0-9._-]{1,120}$'),
  mime_type         text not null check (mime_type in ('image/jpeg', 'image/png', 'image/webp')),
  size_bytes        bigint not null check (size_bytes between 1 and 5242880),
  sha256            text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  description       text check (description is null or char_length(description) <= 500),
  replace_reason    text,
  version_status    text not null default 'current' check (version_status in ('current', 'superseded')),
  uploaded_at       timestamptz not null default now(),
  constraint evidence_versions_unique_number unique (evidence_id, version_number),
  constraint evidence_versions_reason_for_replacement
    check (version_number = 1 or (replace_reason is not null and btrim(replace_reason) <> ''))
);
create unique index if not exists evidence_versions_one_current
  on public.evidence_versions (evidence_id) where version_status = 'current';
create index if not exists evidences_report_idx on public.evidences (report_id);
create index if not exists evidence_versions_evidence_idx on public.evidence_versions (evidence_id);

-- ---------------------------------------------------------------------------
-- 2. Trigger perlindungan
-- ---------------------------------------------------------------------------
-- Bukti hanya boleh ditambah saat laporan draft/needs_revision (berlaku juga untuk pemilik DB).
create or replace function private.evidences_guard()
returns trigger language plpgsql set search_path = '' as $$
declare v_status public.report_status;
begin
  if tg_op in ('DELETE') then
    raise exception 'evidences bersifat permanen: tidak boleh dihapus' using errcode = '55000';
  end if;
  if tg_op = 'UPDATE' then
    if new.report_id is distinct from old.report_id or new.evidence_type is distinct from old.evidence_type
       or new.created_at is distinct from old.created_at then
      raise exception 'report_id, evidence_type, created_at tidak boleh diubah' using errcode = '55000';
    end if;
  end if;
  select status into v_status from public.reports where id = new.report_id;
  if v_status is null or v_status not in ('draft', 'needs_revision') then
    raise exception 'bukti hanya dapat diubah saat laporan draft atau needs_revision' using errcode = '55000';
  end if;
  return new;
end $$;
drop trigger if exists evidences_guard_trg on public.evidences;
create trigger evidences_guard_trg before insert or update or delete on public.evidences
  for each row execute function private.evidences_guard();

create or replace function private.evidences_no_truncate()
returns trigger language plpgsql set search_path = '' as $$
begin raise exception 'tabel ini permanen: TRUNCATE ditolak' using errcode = '55000'; end $$;
drop trigger if exists evidences_no_truncate_trg on public.evidences;
create trigger evidences_no_truncate_trg before truncate on public.evidences
  for each statement execute function private.evidences_no_truncate();
drop trigger if exists evidence_versions_no_truncate_trg on public.evidence_versions;
create trigger evidence_versions_no_truncate_trg before truncate on public.evidence_versions
  for each statement execute function private.evidences_no_truncate();

-- evidence_versions: append-only. Satu-satunya UPDATE sah: current -> superseded oleh RPC ganti versi.
create or replace function private.evidence_versions_guard()
returns trigger language plpgsql set search_path = '' as $$
declare v_status public.report_status; v_report uuid; v_prev int;
begin
  if tg_op = 'DELETE' then
    raise exception 'evidence_versions bersifat append-only: tidak boleh dihapus' using errcode = '55000';
  end if;
  select e.report_id, r.status into v_report, v_status
    from public.evidences e join public.reports r on r.id = e.report_id
   where e.id = new.evidence_id;
  if tg_op = 'UPDATE' then
    if (to_jsonb(new) - 'version_status') is distinct from (to_jsonb(old) - 'version_status')
       or old.version_status <> 'current' or new.version_status <> 'superseded'
       or coalesce(current_setting('app.evidence_replace', true), '') <> 'on' then
      raise exception 'evidence_versions bersifat append-only (hanya current->superseded lewat RPC)' using errcode = '55000';
    end if;
    return new;
  end if;
  -- INSERT
  if v_status is null or v_status not in ('draft', 'needs_revision') then
    raise exception 'versi bukti hanya dapat ditambah saat laporan draft atau needs_revision' using errcode = '55000';
  end if;
  if new.private_file_path not like v_report::text || '/%' then
    raise exception 'path file harus berada di folder laporan' using errcode = '23514';
  end if;
  select max(version_number) into v_prev from public.evidence_versions where evidence_id = new.evidence_id;
  if new.version_number <> coalesce(v_prev, 0) + 1 then
    raise exception 'version_number harus berurutan' using errcode = '23514';
  end if;
  if new.version_status <> 'current' then
    raise exception 'versi baru harus berstatus current' using errcode = '23514';
  end if;
  return new;
end $$;
drop trigger if exists evidence_versions_guard_trg on public.evidence_versions;
create trigger evidence_versions_guard_trg before insert or update or delete on public.evidence_versions
  for each row execute function private.evidence_versions_guard();

-- Audit atomik: bukti ditambah / diganti.
create or replace function private.evidence_versions_audit()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_report uuid; v_type public.evidence_type;
begin
  if tg_op <> 'INSERT' then return null; end if;
  select report_id, evidence_type into v_report, v_type from public.evidences where id = new.evidence_id;
  perform private.write_audit(
    case when new.version_number = 1 then 'evidence.added' else 'evidence.replaced' end,
    'evidences', new.evidence_id::text, new.replace_reason,
    case when new.version_number > 1 then jsonb_build_object('version_number', new.version_number - 1) end,
    jsonb_build_object('report_id', v_report, 'evidence_type', v_type, 'version_number', new.version_number,
                       'sha256', new.sha256, 'mime_type', new.mime_type, 'size_bytes', new.size_bytes));
  return null;
end $$;
drop trigger if exists evidence_versions_audit_trg on public.evidence_versions;
create trigger evidence_versions_audit_trg after insert on public.evidence_versions
  for each row execute function private.evidence_versions_audit();

-- ---------------------------------------------------------------------------
-- 3. Fungsi bantu
-- ---------------------------------------------------------------------------
-- Folder pertama nama objek = id laporan. NULL bila bentuknya tidak valid (tanpa error cast).
create or replace function private.evidence_path_report(p_name text)
returns uuid language sql immutable set search_path = '' as $$
  select case when p_name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[A-Za-z0-9._-]{1,120}$'
              then split_part(p_name, '/', 1)::uuid end
$$;

-- Siapa boleh membuka FILE bukti (bukan metadata). Aturan D5:
-- pemilik: laporannya sendiri; moderator/admin utama: laporan non-draft;
-- verifier: DITOLAK sampai Tahap 4 (butuh start_review pada laporan itu; fungsi ini diganti di sana).
create or replace function private.can_view_evidence(p_report_id uuid)
returns boolean language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := (select auth.uid()); r public.reports;
begin
  if v_uid is null or p_report_id is null then return false; end if;
  select * into r from public.reports where id = p_report_id;
  if not found then return false; end if;
  if r.user_id = v_uid then return true; end if;
  if r.status <> 'draft' and private.has_role(array['moderator', 'admin_utama']::public.app_role[]) then
    return true;
  end if;
  return false;
end $$;

-- Pemilik boleh mengunggah ke folder laporannya (draft/needs_revision, email OK, tidak dibatasi).
create or replace function private.can_upload_evidence(p_report_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.reports r
     where r.id = p_report_id
       and r.user_id = (select auth.uid())
       and r.status in ('draft', 'needs_revision')
       and private.email_verified()
       and not private.account_restricted(r.user_id))
$$;

-- ---------------------------------------------------------------------------
-- 4. Syarat kirim: EV-01 wajib (D2, BR-63). Menggantikan fungsi Tahap 2.
-- ---------------------------------------------------------------------------
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
    case when r.incident_at      is null then 'incident_at' end,
    case when not exists (
      select 1 from public.evidences e
        join public.evidence_versions v on v.evidence_id = e.id and v.version_status = 'current'
       where e.report_id = r.id and e.evidence_type = 'EV-01') then 'evidence:EV-01' end], null);
  if cardinality(v_miss) > 0 then
    raise exception 'report_incomplete: %', array_to_string(v_miss, ', ') using errcode = '22023';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 5. RPC pelapor
-- ---------------------------------------------------------------------------
create or replace function private.evidence_register(
  p_report_id uuid, p_evidence_id uuid, p_path text, p_mime text, p_size bigint,
  p_sha256 text, p_description text, p_reason text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := (select auth.uid());
  v_obj   record;
  v_next  int;
  v_id    uuid;
begin
  if private.evidence_path_report(p_path) is distinct from p_report_id then
    raise exception 'invalid_path: path harus <id-laporan>/<nama-file>' using errcode = '22023';
  end if;
  -- File harus benar-benar ada di bucket dan diunggah oleh pemanggil; ukuran/tipe dicocokkan.
  select o.owner, o.metadata into v_obj
    from storage.objects o where o.bucket_id = 'evidence' and o.name = p_path;
  if not found then
    raise exception 'file_not_uploaded: unggah file ke bucket evidence terlebih dahulu' using errcode = 'P0002';
  end if;
  if v_obj.owner is distinct from v_actor then
    raise exception 'forbidden: file bukan diunggah oleh Anda' using errcode = '42501';
  end if;
  if v_obj.metadata ? 'size' and (v_obj.metadata ->> 'size')::bigint <> p_size then
    raise exception 'metadata_mismatch: ukuran tidak sama dengan file di Storage' using errcode = '22023';
  end if;
  if v_obj.metadata ? 'mimetype' and (v_obj.metadata ->> 'mimetype') <> p_mime then
    raise exception 'metadata_mismatch: tipe tidak sama dengan file di Storage' using errcode = '22023';
  end if;
  select coalesce(max(version_number), 0) + 1 into v_next from public.evidence_versions where evidence_id = p_evidence_id;
  if v_next > 1 then
    perform set_config('app.evidence_replace', 'on', true);
    update public.evidence_versions set version_status = 'superseded'
     where evidence_id = p_evidence_id and version_status = 'current';
    perform set_config('app.evidence_replace', 'off', true);
  end if;
  insert into public.evidence_versions
    (evidence_id, version_number, uploaded_by, private_file_path, mime_type, size_bytes, sha256, description, replace_reason)
  values (p_evidence_id, v_next, v_actor, p_path, p_mime, p_size, p_sha256, p_description, p_reason)
  returning id into v_id;
  return v_id;
end $$;

create or replace function public.add_evidence(
  p_report_id uuid, p_type public.evidence_type, p_path text, p_mime text, p_size bigint,
  p_sha256 text, p_description text default null,
  p_three_calls boolean default false, p_single_screenshot boolean default false)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := (select auth.uid());
  v_owner uuid; v_status public.report_status; v_ev uuid;
begin
  if v_actor is null then raise exception 'forbidden' using errcode = '42501'; end if;
  select user_id, status into v_owner, v_status from public.reports where id = p_report_id for update;
  if not found or v_owner <> v_actor then raise exception 'report_not_found' using errcode = 'P0002'; end if;
  if not private.email_verified() then raise exception 'email_not_verified' using errcode = '42501'; end if;
  if private.account_restricted(v_actor) then raise exception 'account_restricted' using errcode = '42501'; end if;
  if v_status not in ('draft', 'needs_revision') then
    raise exception 'report_locked: bukti hanya dapat diubah saat draft atau needs_revision' using errcode = '55000';
  end if;
  insert into public.evidences (report_id, evidence_type, declared_three_calls, declared_single_screenshot)
  values (p_report_id, p_type, coalesce(p_three_calls, false), coalesce(p_single_screenshot, false))
  returning id into v_ev;
  perform private.evidence_register(p_report_id, v_ev, p_path, p_mime, p_size, p_sha256, p_description, null);
  return v_ev;
end $$;

create or replace function public.replace_evidence_version(
  p_evidence_id uuid, p_path text, p_mime text, p_size bigint, p_sha256 text,
  p_reason text, p_description text default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := (select auth.uid());
  v_report uuid; v_owner uuid; v_status public.report_status;
begin
  if v_actor is null then raise exception 'forbidden' using errcode = '42501'; end if;
  select e.report_id into v_report from public.evidences e where e.id = p_evidence_id;
  if not found then raise exception 'evidence_not_found' using errcode = 'P0002'; end if;
  select user_id, status into v_owner, v_status from public.reports where id = v_report for update;
  if v_owner <> v_actor then raise exception 'evidence_not_found' using errcode = 'P0002'; end if;
  if not private.email_verified() then raise exception 'email_not_verified' using errcode = '42501'; end if;
  if private.account_restricted(v_actor) then raise exception 'account_restricted' using errcode = '42501'; end if;
  if v_status not in ('draft', 'needs_revision') then
    raise exception 'report_locked: bukti hanya dapat diubah saat draft atau needs_revision' using errcode = '55000';
  end if;
  if p_reason is null or btrim(p_reason) = '' then raise exception 'reason_required' using errcode = '22023'; end if;
  return private.evidence_register(v_report, p_evidence_id, p_path, p_mime, p_size, p_sha256, p_description, p_reason);
end $$;

-- ---------------------------------------------------------------------------
-- 6. RLS tabel
-- ---------------------------------------------------------------------------
alter table public.evidences         enable row level security;
alter table public.evidence_versions enable row level security;
revoke all on table public.evidences, public.evidence_versions from public, anon, authenticated, service_role;
grant select on public.evidences, public.evidence_versions to authenticated;
grant select on public.evidences, public.evidence_versions to service_role;

-- Metadata terlihat bila laporannya terlihat (pemilik semua status; petugas non-draft).
-- Menulis HANYA lewat RPC (tidak ada hak INSERT/UPDATE untuk API).
drop policy if exists evidences_select on public.evidences;
create policy evidences_select on public.evidences for select to authenticated
  using (exists (select 1 from public.reports r where r.id = evidences.report_id));
drop policy if exists evidence_versions_select on public.evidence_versions;
create policy evidence_versions_select on public.evidence_versions for select to authenticated
  using (exists (select 1 from public.evidences e where e.id = evidence_versions.evidence_id));

-- ---------------------------------------------------------------------------
-- 7. Bucket privat dan kebijakan Storage
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('evidence', 'evidence', false, 5242880, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update
  set public = false, file_size_limit = 5242880,
      allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp'];

drop policy if exists evidence_objects_insert on storage.objects;
create policy evidence_objects_insert on storage.objects for insert to authenticated
  with check (
    bucket_id = 'evidence'
    and private.can_upload_evidence(private.evidence_path_report(name))
  );

drop policy if exists evidence_objects_select on storage.objects;
create policy evidence_objects_select on storage.objects for select to authenticated
  using (
    bucket_id = 'evidence'
    and private.can_view_evidence(private.evidence_path_report(name))
  );
-- Tanpa kebijakan UPDATE/DELETE: file bukti tidak dapat ditimpa atau dihapus lewat API (FR-41/BR-06).

-- ---------------------------------------------------------------------------
-- 8. Hak fungsi
-- ---------------------------------------------------------------------------
revoke all on function public.add_evidence(uuid, public.evidence_type, text, text, bigint, text, text, boolean, boolean) from public, anon, authenticated;
revoke all on function public.replace_evidence_version(uuid, text, text, bigint, text, text, text) from public, anon, authenticated;
grant execute on function public.add_evidence(uuid, public.evidence_type, text, text, bigint, text, text, boolean, boolean) to authenticated;
grant execute on function public.replace_evidence_version(uuid, text, text, bigint, text, text, text) to authenticated;

revoke all on all functions in schema private from public, anon, authenticated;
grant execute on function private.current_app_role()           to authenticated;
grant execute on function private.has_role(public.app_role[])  to authenticated;
grant execute on function private.is_staff()                   to authenticated;
grant execute on function private.email_verified()             to authenticated;
grant execute on function private.account_restricted(uuid)     to authenticated;
grant execute on function private.evidence_path_report(text)   to authenticated;
grant execute on function private.can_view_evidence(uuid)      to authenticated;
grant execute on function private.can_upload_evidence(uuid)    to authenticated;

comment on table public.evidences is 'Item bukti per laporan (satu per jenis). Tulis hanya lewat RPC add_evidence.';
comment on table public.evidence_versions is 'Versi file bukti, append-only. File ada di bucket privat evidence; akses lewat signed URL.';
