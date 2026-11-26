-- 0002: Fondasi Fase 1 (Tahap 1)
--   skema private, profiles, user_roles, audit_logs (append-only, berantai hash),
--   fungsi bantu peran, RPC admin_set_role / admin_revoke_role / verify_audit_chain.
-- Aman dijalankan ulang (idempoten). Tidak ada secret di berkas ini.
-- Rujukan SRS: FR-25 (peran), 5.1 (keamanan), 5.5 (auditabilitas), BR-05/14.
-- Rancangan: docs/RANCANGAN_DB_FASE_1.md

-- ---------------------------------------------------------------------------
-- 0. Pra-pemeriksaan: jangan merusak tabel lama dari skema deprecated.
-- ---------------------------------------------------------------------------
do $$
begin
  if to_regclass('public.reports') is not null
     and not exists (
       select 1 from information_schema.columns
       where table_schema = 'public' and table_name = 'reports' and column_name = 'user_id')
  then
    raise exception
      'Tabel public.reports lama (supabase_schema.sql, deprecated) terdeteksi. Migrasi dihentikan agar data tidak rusak. Ekspor lalu ganti nama tabel lama terlebih dahulu (lihat PANDUAN_DEPLOY.md).'
      using errcode = '55000';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 1. Skema private (tidak diekspos PostgREST) untuk fungsi bantu internal.
-- ---------------------------------------------------------------------------
create schema if not exists private;
revoke all on schema private from public;
grant usage on schema private to authenticated;

-- ---------------------------------------------------------------------------
-- 2. profiles (SRS A.2 USERS). Email TIDAK disalin; tetap di auth.users.
-- ---------------------------------------------------------------------------
create table if not exists public.profiles (
  id           uuid primary key references auth.users (id) on delete restrict,
  display_name text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  constraint profiles_display_name_len
    check (display_name is null or char_length(btrim(display_name)) between 1 and 50)
);

create or replace function private.touch_updated_at()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists profiles_touch on public.profiles;
create trigger profiles_touch before update on public.profiles
  for each row execute function private.touch_updated_at();

-- Profil dibuat otomatis saat akun Auth dibuat.
create or replace function private.handle_new_user()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id) values (new.id) on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function private.handle_new_user();

-- Isi ulang untuk akun yang sudah ada sebelum migrasi ini.
insert into public.profiles (id) select id from auth.users on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- 3. user_roles. Tanpa baris aktif = peran 'user'. Riwayat penunjukan disimpan.
-- ---------------------------------------------------------------------------
create table if not exists public.user_roles (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references public.profiles (id) on delete restrict,
  role          public.app_role not null,
  reason        text not null,
  granted_by    uuid references public.profiles (id) on delete restrict,
  granted_at    timestamptz not null default now(),
  revoked_at    timestamptz,
  revoked_by    uuid references public.profiles (id) on delete restrict,
  revoke_reason text,
  constraint user_roles_role_not_user check (role <> 'user'::public.app_role),
  constraint user_roles_reason_nonblank check (btrim(reason) <> ''),
  constraint user_roles_revoke_consistent check (
    (revoked_at is null and revoked_by is null and revoke_reason is null)
    or (revoked_at is not null and revoke_reason is not null
        and btrim(revoke_reason) <> '' and revoked_at >= granted_at)
  )
);

-- Maksimal satu peran aktif per pengguna (keputusan D6).
create unique index if not exists user_roles_one_active
  on public.user_roles (user_id) where revoked_at is null;

-- Riwayat peran tidak boleh diubah/dihapus; hanya boleh dicabut sekali.
create or replace function private.user_roles_guard()
returns trigger language plpgsql set search_path = '' as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'user_roles tidak boleh dihapus' using errcode = '42501';
  end if;
  if tg_op = 'TRUNCATE' then
    raise exception 'user_roles tidak boleh di-truncate' using errcode = '42501';
  end if;
  if (new.id, new.user_id, new.role, new.reason, new.granted_by, new.granted_at)
     is distinct from
     (old.id, old.user_id, old.role, old.reason, old.granted_by, old.granted_at) then
    raise exception 'kolom penunjukan peran tidak boleh diubah' using errcode = '42501';
  end if;
  if old.revoked_at is not null then
    raise exception 'peran yang sudah dicabut tidak boleh diubah' using errcode = '42501';
  end if;
  return new;
end $$;

drop trigger if exists user_roles_guard_row on public.user_roles;
create trigger user_roles_guard_row before update or delete on public.user_roles
  for each row execute function private.user_roles_guard();
drop trigger if exists user_roles_guard_truncate on public.user_roles;
create trigger user_roles_guard_truncate before truncate on public.user_roles
  for each statement execute function private.user_roles_guard();

-- ---------------------------------------------------------------------------
-- 4. audit_logs: append-only, berantai hash (keputusan K-05 / SRS 5.5).
--    Pencegahan: tanpa hak tulis API + trigger penolak UPDATE/DELETE/TRUNCATE.
--    Deteksi   : rantai hash + verify_audit_chain().
--    Batas     : pemilik database masih bisa menonaktifkan trigger; rantai hash
--                hanya mendeteksi, dan pemotongan ekor perlu jangkar eksternal
--                (simpan head_hash secara berkala di luar database).
-- ---------------------------------------------------------------------------
create table if not exists public.audit_logs (
  id          bigint generated always as identity primary key,
  occurred_at timestamptz not null default clock_timestamp(),
  actor_id    uuid,
  actor_role  text,
  action      text not null,
  object_type text not null,
  object_id   text not null,
  reason      text,
  old_data    jsonb,
  new_data    jsonb,
  prev_hash   text not null,
  row_hash    text not null
);

create or replace function private.audit_row_hash(r public.audit_logs)
returns text language sql stable set search_path = '' as $$
  select encode(sha256(convert_to(jsonb_build_array(
    r.prev_hash, r.id,
    to_char(r.occurred_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
    r.actor_id, r.actor_role, r.action, r.object_type, r.object_id,
    r.reason, r.old_data, r.new_data)::text, 'UTF8')), 'hex')
$$;

-- Hash dihitung di server; nilai yang dikirim penulis selalu ditimpa.
create or replace function private.audit_chain_before_insert()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_prev text;
begin
  perform pg_advisory_xact_lock(7243001);
  select row_hash into v_prev from public.audit_logs order by id desc limit 1;
  new.prev_hash   := coalesce(v_prev, repeat('0', 64));
  new.occurred_at := clock_timestamp();
  new.row_hash    := private.audit_row_hash(new);
  return new;
end $$;

drop trigger if exists audit_logs_chain on public.audit_logs;
create trigger audit_logs_chain before insert on public.audit_logs
  for each row execute function private.audit_chain_before_insert();

create or replace function private.audit_logs_block()
returns trigger language plpgsql set search_path = '' as $$
begin
  raise exception 'audit_logs bersifat append-only (% ditolak)', tg_op using errcode = '42501';
end $$;

drop trigger if exists audit_logs_immutable on public.audit_logs;
create trigger audit_logs_immutable before update or delete on public.audit_logs
  for each row execute function private.audit_logs_block();
drop trigger if exists audit_logs_no_truncate on public.audit_logs;
create trigger audit_logs_no_truncate before truncate on public.audit_logs
  for each statement execute function private.audit_logs_block();

-- Satu-satunya jalur penulisan audit untuk kode aplikasi.
-- Kunci diambil SEBELUM insert agar urutan id sama dengan urutan rantai.
create or replace function private.write_audit(
  p_action text, p_object_type text, p_object_id text, p_reason text,
  p_old jsonb, p_new jsonb)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform pg_advisory_xact_lock(7243001);
  insert into public.audit_logs
    (actor_id, actor_role, action, object_type, object_id, reason,
     old_data, new_data, prev_hash, row_hash)
  values
    ((select auth.uid()), coalesce(private.current_app_role()::text, 'system'),
     p_action, p_object_type, p_object_id, p_reason, p_old, p_new, '', '');
end $$;

-- ---------------------------------------------------------------------------
-- 5. Fungsi bantu peran (dipakai kebijakan RLS; tidak diekspos API).
-- ---------------------------------------------------------------------------
create or replace function private.current_app_role()
returns public.app_role language sql stable security definer set search_path = '' as $$
  select case
    when (select auth.uid()) is null then null
    else coalesce(
      (select ur.role from public.user_roles ur
        where ur.user_id = (select auth.uid()) and ur.revoked_at is null),
      'user'::public.app_role)
  end
$$;

create or replace function private.has_role(p_roles public.app_role[])
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce(private.current_app_role() = any (p_roles), false)
$$;

create or replace function private.is_staff()
returns boolean language sql stable security definer set search_path = '' as $$
  select private.has_role(array['verifier', 'moderator', 'admin_utama']::public.app_role[])
$$;

-- BR-03/BR-04: hanya membuktikan akses ke email, bukan identitas.
create or replace function private.email_verified()
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select u.email_confirmed_at is not null from auth.users u where u.id = (select auth.uid())),
    false)
$$;

-- Audit otomatis untuk penunjukan/pencabutan peran.
create or replace function private.audit_user_roles()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    perform private.write_audit('role.granted', 'user_roles', new.id::text,
      new.reason, null, to_jsonb(new));
  elsif tg_op = 'UPDATE' and old.revoked_at is null and new.revoked_at is not null then
    perform private.write_audit('role.revoked', 'user_roles', new.id::text,
      new.revoke_reason, to_jsonb(old), to_jsonb(new));
  end if;
  return null;
end $$;

drop trigger if exists user_roles_audit on public.user_roles;
create trigger user_roles_audit after insert or update on public.user_roles
  for each row execute function private.audit_user_roles();

-- ---------------------------------------------------------------------------
-- 6. RPC publik (SECURITY DEFINER; semua pemeriksaan ulang di dalam fungsi).
-- ---------------------------------------------------------------------------
create or replace function public.admin_set_role(
  p_user_id uuid, p_role public.app_role, p_reason text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := (select auth.uid());
  v_cur   public.user_roles;
  v_new   uuid;
begin
  if v_actor is null or private.current_app_role() is distinct from 'admin_utama'::public.app_role then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'reason_required' using errcode = '22023';
  end if;
  if p_role is null or p_role = 'user'::public.app_role then
    raise exception 'invalid_role (gunakan admin_revoke_role untuk mencabut)' using errcode = '22023';
  end if;
  if p_user_id is null or p_user_id = v_actor then
    raise exception 'cannot_change_own_role' using errcode = '42501';
  end if;
  if not exists (select 1 from public.profiles where id = p_user_id) then
    raise exception 'user_not_found' using errcode = 'P0002';
  end if;

  select * into v_cur from public.user_roles
   where user_id = p_user_id and revoked_at is null for update;
  if found then
    if v_cur.role = p_role then
      raise exception 'role_already_assigned' using errcode = '23505';
    end if;
    update public.user_roles
       set revoked_at = now(), revoked_by = v_actor,
           revoke_reason = 'diganti ke ' || p_role::text || ': ' || btrim(p_reason)
     where id = v_cur.id;
  end if;

  insert into public.user_roles (user_id, role, reason, granted_by)
  values (p_user_id, p_role, btrim(p_reason), v_actor)
  returning id into v_new;
  return v_new;
end $$;

create or replace function public.admin_revoke_role(p_user_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := (select auth.uid());
begin
  if v_actor is null or private.current_app_role() is distinct from 'admin_utama'::public.app_role then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'reason_required' using errcode = '22023';
  end if;
  if p_user_id is null or p_user_id = v_actor then
    raise exception 'cannot_change_own_role' using errcode = '42501';
  end if;
  update public.user_roles
     set revoked_at = now(), revoked_by = v_actor, revoke_reason = btrim(p_reason)
   where user_id = p_user_id and revoked_at is null;
  if not found then
    raise exception 'no_active_role' using errcode = 'P0002';
  end if;
end $$;

-- Verifikasi rantai audit. head_hash dapat diekspor berkala sebagai jangkar.
create or replace function public.verify_audit_chain()
returns table (ok boolean, checked bigint, first_bad_id bigint, head_hash text)
language plpgsql security definer set search_path = '' as $$
declare
  r      public.audit_logs;
  v_prev text := repeat('0', 64);
  n      bigint := 0;
begin
  if private.current_app_role() is distinct from 'admin_utama'::public.app_role then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  for r in select * from public.audit_logs order by id loop
    n := n + 1;
    if r.prev_hash <> v_prev or r.row_hash <> private.audit_row_hash(r) then
      return query select false, n, r.id, v_prev;
      return;
    end if;
    v_prev := r.row_hash;
  end loop;
  return query select true, n, null::bigint, v_prev;
end $$;

-- ---------------------------------------------------------------------------
-- 7. RLS dan hak akses (deny by default).
--    Supabase memberi hak penuh ke tabel/fungsi baru; semuanya dicabut dulu.
-- ---------------------------------------------------------------------------
alter table public.profiles   enable row level security;
alter table public.user_roles enable row level security;
alter table public.audit_logs enable row level security;

revoke all on table public.profiles   from public, anon, authenticated;
revoke all on table public.user_roles from public, anon, authenticated;
revoke all on table public.audit_logs from public, anon, authenticated;
revoke all on sequence public.audit_logs_id_seq from public, anon, authenticated;
-- service_role (server-side) tidak boleh menulis/menghapus audit.
revoke insert, update, delete, truncate on table public.audit_logs from service_role;

grant select on public.profiles   to authenticated;
grant update (display_name) on public.profiles to authenticated;
grant select on public.user_roles to authenticated;
grant select on public.audit_logs to authenticated;

drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select to authenticated
  using (id = (select auth.uid()) or (select private.is_staff()));

drop policy if exists profiles_update_own on public.profiles;
create policy profiles_update_own on public.profiles for update to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()));

drop policy if exists user_roles_select on public.user_roles;
create policy user_roles_select on public.user_roles for select to authenticated
  using (
    user_id = (select auth.uid())
    or (select private.has_role(array['moderator', 'admin_utama']::public.app_role[]))
  );

drop policy if exists audit_logs_select_admin on public.audit_logs;
create policy audit_logs_select_admin on public.audit_logs for select to authenticated
  using ((select private.has_role(array['admin_utama']::public.app_role[])));

-- Fungsi: cabut eksekusi default, beri hanya yang diperlukan.
revoke all on function public.admin_set_role(uuid, public.app_role, text)  from public, anon, authenticated;
revoke all on function public.admin_revoke_role(uuid, text)                from public, anon, authenticated;
revoke all on function public.verify_audit_chain()                         from public, anon, authenticated;
grant execute on function public.admin_set_role(uuid, public.app_role, text) to authenticated;
grant execute on function public.admin_revoke_role(uuid, text)               to authenticated;
grant execute on function public.verify_audit_chain()                        to authenticated;

-- Semua fungsi private (termasuk fungsi trigger) ditutup; hanya bantu-RLS yang dibuka.
revoke all on all functions in schema private from public, anon, authenticated;
grant execute on function private.current_app_role()              to authenticated;
grant execute on function private.has_role(public.app_role[])     to authenticated;
grant execute on function private.is_staff()                      to authenticated;
grant execute on function private.email_verified()                to authenticated;

comment on table public.audit_logs is
  'Log audit append-only berantai hash. Tulis hanya lewat private.write_audit(); baca hanya admin_utama.';
comment on table public.user_roles is
  'Penunjukan peran petugas. Tidak ada baris aktif = user. Ubah hanya via admin_set_role/admin_revoke_role.';
