-- Fase 1 Tahap 6: sanksi, banding, blacklist privat, dan pembatasan akun nyata.
-- Prasyarat: 0001-0006. Pepper fingerprint blacklist HARUS ada di Supabase Vault
-- (nama 'blacklist_pepper'; lihat PANDUAN_DEPLOY.md). Tanpa pepper, persetujuan blokir permanen gagal tertutup.
-- Idempoten.
--
-- Asumsi tercatat (bukan dari SRS; lihat lampiran docs/RANCANGAN_DB_FASE_1.md):
--  * Moderator menjatuhkan warning/feature_restriction/temporary_suspension; blokir permanen diusulkan
--    moderator dan disetujui Admin Utama (BR-13). Petugas aktif tidak dapat disanksi lewat fungsi ini.
--  * Sanksi tetap berlaku selama banding sampai Admin Utama menangguhkannya (FR-33).
--  * Banding dikabulkan: sanksi menjadi lifted dan entri blacklist terkait menjadi lifted.
--    Banding ditolak: sanksi yang ditangguhkan kembali aktif.
--  * Email dinormalisasi (huruf kecil, buang +alias) sebelum di-HMAC; titik pada Gmail tidak dinormalisasi.

-- ---------------------------------------------------------------------------
-- 1. Tabel
-- ---------------------------------------------------------------------------
create table if not exists public.sanctions (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references public.profiles(id) on delete restrict,
  moderator_id   uuid not null references public.profiles(id) on delete restrict,
  sanction_type  public.sanction_type not null,
  reason         text not null check (btrim(reason) <> '' and char_length(reason) <= 1000),
  report_id      uuid references public.reports(id) on delete restrict,
  forum_id       uuid references public.decision_forums(id) on delete restrict,
  starts_at      timestamptz not null default now(),
  ends_at        timestamptz,
  status         text not null default 'active'
                   check (status in ('proposed', 'active', 'suspended', 'lifted', 'rejected')),
  proposed_by    uuid not null references public.profiles(id) on delete restrict,
  approved_by    uuid references public.profiles(id) on delete restrict,
  approved_at    timestamptz,
  status_note    text,
  status_by      uuid references public.profiles(id) on delete restrict,
  status_at      timestamptz,
  created_at     timestamptz not null default now(),
  constraint sanctions_not_self check (user_id <> moderator_id),
  constraint sanctions_proposer_is_moderator check (proposed_by = moderator_id),
  constraint sanctions_duration check (
    (sanction_type in ('feature_restriction', 'temporary_suspension') and ends_at is not null and ends_at > starts_at)
    or (sanction_type in ('warning', 'permanent_ban') and ends_at is null)),
  -- BR-13: blokir permanen berlaku hanya setelah disetujui orang lain dari pengusul.
  constraint sanctions_permanent_needs_approval check (
    sanction_type <> 'permanent_ban' or status in ('proposed', 'rejected')
    or (approved_by is not null and approved_at is not null and approved_by <> proposed_by)),
  constraint sanctions_nonpermanent_flow check (
    sanction_type = 'permanent_ban' or (approved_by is null and status not in ('proposed', 'rejected'))),
  constraint sanctions_status_note check (
    status in ('proposed', 'active') or (status_note is not null and btrim(status_note) <> ''
                                         and status_by is not null and status_at is not null))
);
create index if not exists sanctions_user_idx on public.sanctions (user_id);
create index if not exists sanctions_user_active_idx on public.sanctions (user_id) where status = 'active';

create table if not exists public.appeals (
  id                    uuid primary key default gen_random_uuid(),
  sanction_id           uuid not null references public.sanctions(id) on delete restrict,
  user_id               uuid not null references public.profiles(id) on delete restrict,
  reason                text not null check (btrim(reason) <> '' and char_length(reason) <= 1000),
  status                text not null default 'open' check (status in ('open', 'under_review', 'granted', 'denied')),
  admin_reviewer_id     uuid references public.profiles(id) on delete restrict,
  verifier_reviewer_id  uuid references public.profiles(id) on delete restrict,
  verifier_recommendation text check (verifier_recommendation in ('grant', 'deny')),
  verifier_notes        text check (verifier_notes is null or char_length(verifier_notes) <= 2000),
  decision_reason       text,
  decided_at            timestamptz,
  created_at            timestamptz not null default now(),
  constraint appeals_review_consistency check (
    (status = 'open' and verifier_reviewer_id is null and verifier_recommendation is null)
    or (status <> 'open' and verifier_reviewer_id is not null and admin_reviewer_id is not null)),
  constraint appeals_decision_consistency check (
    (status in ('open', 'under_review') and decided_at is null and decision_reason is null)
    or (status in ('granted', 'denied') and decided_at is not null and decision_reason is not null
        and btrim(decision_reason) <> '' and verifier_recommendation is not null)),
  constraint appeals_recommendation_needs_notes check (
    verifier_recommendation is null or (verifier_notes is not null and btrim(verifier_notes) <> ''))
);
create unique index if not exists appeals_one_open_per_sanction
  on public.appeals (sanction_id) where status in ('open', 'under_review');
create index if not exists appeals_verifier_idx on public.appeals (verifier_reviewer_id);

create table if not exists public.blacklist_entries (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null references public.profiles(id) on delete restrict,
  sanction_id       uuid not null references public.sanctions(id) on delete restrict,
  email_fingerprint text not null check (email_fingerprint ~ '^[0-9a-f]{64}$'),
  status            text not null default 'active' check (status in ('active', 'lifted')),
  reason            text not null check (btrim(reason) <> ''),
  created_by        uuid not null references public.profiles(id) on delete restrict,
  created_at        timestamptz not null default now(),
  lifted_at         timestamptz,
  constraint blacklist_lifted_consistency check ((status = 'lifted') = (lifted_at is not null))
);
create unique index if not exists blacklist_one_active_per_fingerprint
  on public.blacklist_entries (email_fingerprint) where status = 'active';
create index if not exists blacklist_sanction_idx on public.blacklist_entries (sanction_id);

-- ---------------------------------------------------------------------------
-- 2. Fungsi bantu: pembatasan akun, fingerprint, definisi "tidak terlibat" (D7)
-- ---------------------------------------------------------------------------
-- MENGGANTIKAN penampung Tahap 2: akun dibatasi bila ada sanksi aktif yang sedang berlaku.
-- warning tidak membatasi. Kedaluwarsa diturunkan dari ends_at (tidak ada status tersimpan yang bisa selisih).
create or replace function private.account_restricted(p_user_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.sanctions s
     where s.user_id = p_user_id
       and s.status = 'active'
       and s.sanction_type in ('feature_restriction', 'temporary_suspension', 'permanent_ban')
       and s.starts_at <= now()
       and (s.ends_at is null or s.ends_at > now()))
$$;

-- HMAC-SHA256 murni SQL (tanpa ekstensi) berdasarkan sha256() bawaan PostgreSQL.
create or replace function private.hmac_sha256(p_key bytea, p_msg bytea)
returns bytea language plpgsql immutable set search_path = '' as $$
declare k bytea := p_key; ipad bytea; opad bytea; i int; b int;
begin
  if length(k) > 64 then k := sha256(k); end if;
  k := k || decode(repeat('00', 64 - length(k)), 'hex');
  ipad := k; opad := k;
  for i in 0..63 loop
    b := get_byte(k, i);
    ipad := set_byte(ipad, i, b # 54);
    opad := set_byte(opad, i, b # 92);
  end loop;
  return sha256(opad || sha256(ipad || p_msg));
end $$;

create or replace function private.normalize_email(p_email text)
returns text language plpgsql immutable set search_path = '' as $$
declare v text;
begin
  v := regexp_replace(lower(btrim(coalesce(p_email, ''))), '\+[^@]*@', '@');
  if v !~ '^[^@[:space:]]+@[^@[:space:]]+$' then
    raise exception 'invalid_email' using errcode = '22023';
  end if;
  return v;
end $$;

-- Pepper dari Supabase Vault. Gagal tertutup bila tidak ada.
create or replace function private.blacklist_pepper()
returns text language plpgsql stable security definer set search_path = '' as $$
declare v text;
begin
  begin
    execute 'select decrypted_secret from vault.decrypted_secrets where name = ''blacklist_pepper'' limit 1' into v;
  exception when undefined_table or invalid_schema_name or insufficient_privilege then
    v := null;
  end;
  if v is null or char_length(btrim(v)) < 16 then
    raise exception 'pepper_missing: rahasia blacklist_pepper belum diset di Vault (min. 16 karakter)' using errcode = '55000';
  end if;
  return v;
end $$;

create or replace function private.email_fingerprint(p_email text)
returns text language sql stable security definer set search_path = '' as $$
  select encode(private.hmac_sha256(convert_to(private.blacklist_pepper(), 'UTF8'),
                                    convert_to(private.normalize_email(p_email), 'UTF8')), 'hex')
$$;

-- D7: verifier "tidak terlibat" pada banding sebuah sanksi.
create or replace function private.appeal_verifier_uninvolved(p_sanction_id uuid, p_verifier_id uuid)
returns boolean language plpgsql stable security definer set search_path = '' as $$
declare s public.sanctions;
begin
  select * into s from public.sanctions where id = p_sanction_id;
  if not found then return false; end if;
  if p_verifier_id in (s.user_id, s.moderator_id, s.proposed_by) or p_verifier_id = s.approved_by then
    return false;
  end if;
  if s.forum_id is not null and exists
     (select 1 from public.forum_participants fp where fp.forum_id = s.forum_id and fp.user_id = p_verifier_id) then
    return false;
  end if;
  if s.report_id is not null and exists
     (select 1 from public.verification_reviews v where v.report_id = s.report_id and v.verifier_id = p_verifier_id) then
    return false;
  end if;
  return true;
end $$;

create or replace function private.is_assigned_verifier(p_sanction_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.appeals a
                  where a.sanction_id = p_sanction_id and a.verifier_reviewer_id = (select auth.uid()))
$$;

-- ---------------------------------------------------------------------------
-- 3. Trigger perlindungan
-- ---------------------------------------------------------------------------
create or replace function private.sanctions_guard()
returns trigger language plpgsql set search_path = '' as $$
declare v_forum public.decision_forums; v_rstatus public.report_status;
begin
  if tg_op = 'DELETE' then
    raise exception 'sanctions bersifat permanen: tidak boleh dihapus' using errcode = '55000';
  end if;
  if tg_op = 'INSERT' then
    if (new.sanction_type = 'permanent_ban' and new.status <> 'proposed')
       or (new.sanction_type <> 'permanent_ban' and new.status <> 'active') then
      raise exception 'status awal sanksi tidak sah (permanent_ban: proposed; lainnya: active)' using errcode = '23514';
    end if;
    if new.report_id is not null then
      select status into v_rstatus from public.reports where id = new.report_id;
      if v_rstatus is null or v_rstatus = 'draft' then
        raise exception 'laporan dasar sanksi tidak valid' using errcode = '23514';
      end if;
    end if;
    if new.forum_id is not null then
      select * into v_forum from public.decision_forums where id = new.forum_id;
      if v_forum.status <> 'closed' or (new.report_id is not null and v_forum.report_id <> new.report_id) then
        raise exception 'forum dasar sanksi harus sudah selesai dan untuk laporan yang sama' using errcode = '23514';
      end if;
    end if;
    return new;
  end if;
  -- UPDATE
  if new.id <> old.id or new.user_id <> old.user_id or new.moderator_id <> old.moderator_id
     or new.sanction_type <> old.sanction_type or new.reason <> old.reason
     or new.report_id is distinct from old.report_id or new.forum_id is distinct from old.forum_id
     or new.starts_at <> old.starts_at or new.ends_at is distinct from old.ends_at
     or new.proposed_by <> old.proposed_by or new.created_at <> old.created_at then
    raise exception 'isi sanksi tidak boleh diubah' using errcode = '55000';
  end if;
  if coalesce(current_setting('app.sanction_change', true), '') <> 'on' then
    raise exception 'status sanksi hanya berubah lewat fungsi sanksi' using errcode = '55000';
  end if;
  if not ((old.status = 'proposed' and new.status in ('active', 'rejected'))
       or (old.status = 'active' and new.status in ('suspended', 'lifted'))
       or (old.status = 'suspended' and new.status in ('active', 'lifted'))) then
    raise exception 'transisi status sanksi tidak sah: % -> %', old.status, new.status using errcode = '55000';
  end if;
  return new;
end $$;
drop trigger if exists sanctions_guard_trg on public.sanctions;
create trigger sanctions_guard_trg before insert or update or delete on public.sanctions
  for each row execute function private.sanctions_guard();

create or replace function private.appeals_guard()
returns trigger language plpgsql set search_path = '' as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'appeals bersifat permanen' using errcode = '55000';
  end if;
  if tg_op = 'UPDATE' then
    if old.status in ('granted', 'denied') then
      raise exception 'banding yang sudah diputuskan tidak dapat diubah' using errcode = '55000';
    end if;
    if new.id <> old.id or new.sanction_id <> old.sanction_id or new.user_id <> old.user_id
       or new.reason <> old.reason or new.created_at <> old.created_at then
      raise exception 'isi banding tidak boleh diubah' using errcode = '55000';
    end if;
    if coalesce(current_setting('app.appeal_change', true), '') <> 'on' then
      raise exception 'banding hanya berubah lewat fungsi banding' using errcode = '55000';
    end if;
  end if;
  -- D7: berlaku untuk jalur mana pun (termasuk pemilik DB).
  if new.verifier_reviewer_id is not null
     and (tg_op = 'INSERT' or new.verifier_reviewer_id is distinct from old.verifier_reviewer_id)
     and not private.appeal_verifier_uninvolved(new.sanction_id, new.verifier_reviewer_id) then
    raise exception 'verifier_involved: verifier terlibat dalam keputusan sanksi awal' using errcode = '55000';
  end if;
  return new;
end $$;
drop trigger if exists appeals_guard_trg on public.appeals;
create trigger appeals_guard_trg before insert or update or delete on public.appeals
  for each row execute function private.appeals_guard();

create or replace function private.blacklist_guard()
returns trigger language plpgsql set search_path = '' as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'blacklist_entries bersifat permanen' using errcode = '55000';
  end if;
  if tg_op = 'UPDATE' then
    if old.status <> 'active' or new.status <> 'lifted'
       or new.email_fingerprint <> old.email_fingerprint or new.user_id <> old.user_id
       or new.sanction_id <> old.sanction_id or new.reason <> old.reason
       or coalesce(current_setting('app.blacklist_change', true), '') <> 'on' then
      raise exception 'blacklist hanya dapat dicabut (active -> lifted) lewat fungsi banding' using errcode = '55000';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists blacklist_guard_trg on public.blacklist_entries;
create trigger blacklist_guard_trg before insert or update or delete on public.blacklist_entries
  for each row execute function private.blacklist_guard();

create or replace function private.phase6_no_truncate()
returns trigger language plpgsql set search_path = '' as $$
begin raise exception 'tabel ini permanen: TRUNCATE ditolak' using errcode = '55000'; end $$;
do $$ declare t text; begin
  foreach t in array array['sanctions', 'appeals', 'blacklist_entries'] loop
    execute format('drop trigger if exists %I on public.%I', t || '_no_truncate_trg', t);
    execute format('create trigger %I before truncate on public.%I for each statement execute function private.phase6_no_truncate()',
                   t || '_no_truncate_trg', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 4. RPC sanksi
-- ---------------------------------------------------------------------------
create or replace function private.sanction_target_check(p_user_id uuid, p_actor uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if p_user_id = p_actor then raise exception 'cannot_sanction_self' using errcode = '22023'; end if;
  if not exists (select 1 from public.profiles where id = p_user_id) then
    raise exception 'user_not_found' using errcode = 'P0002';
  end if;
  if exists (select 1 from public.user_roles where user_id = p_user_id and revoked_at is null) then
    raise exception 'target_is_staff: cabut peran petugas lebih dulu' using errcode = '55000';
  end if;
end $$;

create or replace function public.impose_sanction(
  p_user_id uuid, p_type public.sanction_type, p_reason text,
  p_ends_at timestamptz default null, p_report_id uuid default null, p_forum_id uuid default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := (select auth.uid()); v_id uuid;
begin
  if v_uid is null or not private.has_role(array['moderator']::public.app_role[]) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_type = 'permanent_ban' then
    raise exception 'use_propose_permanent_ban: blokir permanen harus diusulkan dan disetujui Admin Utama' using errcode = '55000';
  end if;
  perform private.sanction_target_check(p_user_id, v_uid);
  if p_reason is null or btrim(p_reason) = '' then raise exception 'reason_required' using errcode = '22023'; end if;
  insert into public.sanctions (user_id, moderator_id, sanction_type, reason, report_id, forum_id, ends_at, proposed_by)
  values (p_user_id, v_uid, p_type, p_reason, p_report_id, p_forum_id, p_ends_at, v_uid)
  returning id into v_id;
  perform private.write_audit('sanction.imposed', 'sanctions', v_id::text, p_reason, null,
    jsonb_build_object('user_id', p_user_id, 'type', p_type, 'ends_at', p_ends_at));
  return v_id;
end $$;

create or replace function public.propose_permanent_ban(
  p_user_id uuid, p_reason text, p_report_id uuid default null, p_forum_id uuid default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := (select auth.uid()); v_id uuid;
begin
  if v_uid is null or not private.has_role(array['moderator']::public.app_role[]) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  perform private.sanction_target_check(p_user_id, v_uid);
  if p_reason is null or btrim(p_reason) = '' then raise exception 'reason_required' using errcode = '22023'; end if;
  insert into public.sanctions (user_id, moderator_id, sanction_type, reason, report_id, forum_id, status, proposed_by)
  values (p_user_id, v_uid, 'permanent_ban', p_reason, p_report_id, p_forum_id, 'proposed', v_uid)
  returning id into v_id;
  perform private.write_audit('sanction.proposed_permanent', 'sanctions', v_id::text, p_reason, null,
    jsonb_build_object('user_id', p_user_id));
  return v_id;
end $$;

create or replace function public.approve_permanent_ban(p_sanction_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := (select auth.uid()); s public.sanctions; v_email text;
begin
  if v_uid is null or not private.has_role(array['admin_utama']::public.app_role[]) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into s from public.sanctions where id = p_sanction_id for update;
  if not found then raise exception 'sanction_not_found' using errcode = 'P0002'; end if;
  if s.sanction_type <> 'permanent_ban' or s.status <> 'proposed' then
    raise exception 'not_proposed' using errcode = '55000';
  end if;
  if s.proposed_by = v_uid then raise exception 'self_approval_not_allowed' using errcode = '42501'; end if;
  select email into v_email from auth.users where id = s.user_id;
  if v_email is null then raise exception 'email_missing: akun tanpa email tidak dapat diblacklist' using errcode = '55000'; end if;
  perform set_config('app.sanction_change', 'on', true);
  update public.sanctions set status = 'active', approved_by = v_uid, approved_at = now() where id = s.id;
  perform set_config('app.sanction_change', 'off', true);
  -- Gagal tertutup bila pepper tidak ada: seluruh persetujuan dibatalkan.
  insert into public.blacklist_entries (user_id, sanction_id, email_fingerprint, reason, created_by)
  values (s.user_id, s.id, private.email_fingerprint(v_email), s.reason, v_uid)
  on conflict (email_fingerprint) where status = 'active' do nothing;
  perform private.write_audit('sanction.permanent_approved', 'sanctions', s.id::text, s.reason, null,
    jsonb_build_object('user_id', s.user_id, 'approved_by', v_uid));
end $$;

create or replace function public.reject_permanent_ban(p_sanction_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := (select auth.uid()); s public.sanctions;
begin
  if v_uid is null or not private.has_role(array['admin_utama']::public.app_role[]) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into s from public.sanctions where id = p_sanction_id for update;
  if not found then raise exception 'sanction_not_found' using errcode = 'P0002'; end if;
  if s.sanction_type <> 'permanent_ban' or s.status <> 'proposed' then raise exception 'not_proposed' using errcode = '55000'; end if;
  if p_reason is null or btrim(p_reason) = '' then raise exception 'reason_required' using errcode = '22023'; end if;
  perform set_config('app.sanction_change', 'on', true);
  update public.sanctions set status = 'rejected', status_note = p_reason, status_by = v_uid, status_at = now() where id = s.id;
  perform set_config('app.sanction_change', 'off', true);
  perform private.write_audit('sanction.permanent_rejected', 'sanctions', s.id::text, p_reason, null,
    jsonb_build_object('user_id', s.user_id));
end $$;

create or replace function public.suspend_sanction(p_sanction_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := (select auth.uid()); s public.sanctions;
begin
  if v_uid is null or not private.has_role(array['admin_utama']::public.app_role[]) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into s from public.sanctions where id = p_sanction_id for update;
  if not found then raise exception 'sanction_not_found' using errcode = 'P0002'; end if;
  if s.status <> 'active' then raise exception 'invalid_state' using errcode = '55000'; end if;
  if p_reason is null or btrim(p_reason) = '' then raise exception 'reason_required' using errcode = '22023'; end if;
  perform set_config('app.sanction_change', 'on', true);
  update public.sanctions set status = 'suspended', status_note = p_reason, status_by = v_uid, status_at = now() where id = s.id;
  perform set_config('app.sanction_change', 'off', true);
  perform private.write_audit('sanction.suspended', 'sanctions', s.id::text, p_reason, null,
    jsonb_build_object('user_id', s.user_id));
end $$;

-- ---------------------------------------------------------------------------
-- 5. RPC banding
-- ---------------------------------------------------------------------------
create or replace function public.file_appeal(p_sanction_id uuid, p_reason text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := (select auth.uid()); s public.sanctions; v_id uuid;
begin
  if v_uid is null then raise exception 'forbidden' using errcode = '42501'; end if;
  select * into s from public.sanctions where id = p_sanction_id;
  if not found or s.user_id <> v_uid or s.status not in ('active', 'suspended') then
    raise exception 'sanction_not_found' using errcode = 'P0002';
  end if;
  if not private.email_verified() then raise exception 'email_not_verified' using errcode = '42501'; end if;
  if p_reason is null or btrim(p_reason) = '' then raise exception 'reason_required' using errcode = '22023'; end if;
  -- Pengguna yang sedang dibatasi tetap boleh banding (tidak memeriksa account_restricted).
  insert into public.appeals (sanction_id, user_id, reason) values (p_sanction_id, v_uid, p_reason) returning id into v_id;
  perform private.write_audit('appeal.filed', 'appeals', v_id::text, p_reason, null,
    jsonb_build_object('sanction_id', p_sanction_id));
  return v_id;
end $$;

create or replace function public.assign_appeal_reviewer(p_appeal_id uuid, p_verifier_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := (select auth.uid()); a public.appeals;
begin
  if v_uid is null or not private.has_role(array['admin_utama']::public.app_role[]) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into a from public.appeals where id = p_appeal_id for update;
  if not found then raise exception 'appeal_not_found' using errcode = 'P0002'; end if;
  if a.status <> 'open' then raise exception 'invalid_state' using errcode = '55000'; end if;
  if not exists (select 1 from public.user_roles where user_id = p_verifier_id and role = 'verifier' and revoked_at is null) then
    raise exception 'not_verifier' using errcode = '22023';
  end if;
  perform set_config('app.appeal_change', 'on', true);
  update public.appeals set verifier_reviewer_id = p_verifier_id, admin_reviewer_id = v_uid, status = 'under_review'
   where id = a.id;                               -- trigger D7 menolak verifier yang terlibat
  perform set_config('app.appeal_change', 'off', true);
  perform private.write_audit('appeal.assigned', 'appeals', a.id::text, null, null,
    jsonb_build_object('verifier_id', p_verifier_id));
end $$;

create or replace function public.recommend_appeal(p_appeal_id uuid, p_recommendation text, p_notes text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := (select auth.uid()); a public.appeals;
begin
  if v_uid is null or not private.has_role(array['verifier']::public.app_role[]) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into a from public.appeals where id = p_appeal_id for update;
  if not found or a.verifier_reviewer_id is distinct from v_uid then raise exception 'appeal_not_found' using errcode = 'P0002'; end if;
  if a.status <> 'under_review' then raise exception 'invalid_state' using errcode = '55000'; end if;
  if a.verifier_recommendation is not null then raise exception 'already_recommended' using errcode = '55000'; end if;
  if p_recommendation is null or p_recommendation not in ('grant', 'deny') then raise exception 'invalid_result' using errcode = '22023'; end if;
  if p_notes is null or btrim(p_notes) = '' then raise exception 'reason_required' using errcode = '22023'; end if;
  perform set_config('app.appeal_change', 'on', true);
  update public.appeals set verifier_recommendation = p_recommendation, verifier_notes = p_notes where id = a.id;
  perform set_config('app.appeal_change', 'off', true);
  perform private.write_audit('appeal.recommended', 'appeals', a.id::text, p_notes, null,
    jsonb_build_object('recommendation', p_recommendation));
end $$;

create or replace function public.decide_appeal(p_appeal_id uuid, p_grant boolean, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := (select auth.uid()); a public.appeals; s public.sanctions;
begin
  if v_uid is null or not private.has_role(array['admin_utama']::public.app_role[]) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into a from public.appeals where id = p_appeal_id for update;
  if not found then raise exception 'appeal_not_found' using errcode = 'P0002'; end if;
  if a.status <> 'under_review' then raise exception 'invalid_state' using errcode = '55000'; end if;
  if a.verifier_recommendation is null then raise exception 'recommendation_required' using errcode = '55000'; end if;
  if p_grant is null then raise exception 'invalid_result' using errcode = '22023'; end if;
  if p_reason is null or btrim(p_reason) = '' then raise exception 'reason_required' using errcode = '22023'; end if;
  select * into s from public.sanctions where id = a.sanction_id for update;
  perform set_config('app.appeal_change', 'on', true);
  update public.appeals set status = case when p_grant then 'granted' else 'denied' end,
         decision_reason = p_reason, decided_at = now() where id = a.id;
  perform set_config('app.appeal_change', 'off', true);
  perform set_config('app.sanction_change', 'on', true);
  if p_grant then
    update public.sanctions set status = 'lifted', status_note = 'Banding dikabulkan: ' || p_reason,
           status_by = v_uid, status_at = now() where id = s.id;
    perform set_config('app.blacklist_change', 'on', true);
    update public.blacklist_entries set status = 'lifted', lifted_at = now()
     where sanction_id = s.id and status = 'active';
    perform set_config('app.blacklist_change', 'off', true);
  elsif s.status = 'suspended' then
    update public.sanctions set status = 'active', status_note = 'Banding ditolak: ' || p_reason,
           status_by = v_uid, status_at = now() where id = s.id;
  end if;
  perform set_config('app.sanction_change', 'off', true);
  perform private.write_audit('appeal.decided', 'appeals', a.id::text, p_reason, null,
    jsonb_build_object('sanction_id', s.id, 'granted', p_grant));
end $$;

-- Untuk Auth Hook / backend tepercaya saja. TIDAK untuk anon/authenticated (mencegah enumerasi blacklist).
create or replace function public.is_email_blacklisted(p_email text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.blacklist_entries b
                  where b.status = 'active' and b.email_fingerprint = private.email_fingerprint(p_email))
$$;

-- ---------------------------------------------------------------------------
-- 6. RLS dan hak akses
-- ---------------------------------------------------------------------------
alter table public.sanctions         enable row level security;
alter table public.appeals           enable row level security;
alter table public.blacklist_entries enable row level security;
revoke all on table public.sanctions, public.appeals, public.blacklist_entries
  from public, anon, authenticated, service_role;
grant select on public.sanctions, public.appeals to authenticated, service_role;
grant select on public.blacklist_entries to authenticated;   -- dibatasi policy: hanya Admin Utama (D10)

drop policy if exists sanctions_select on public.sanctions;
create policy sanctions_select on public.sanctions for select to authenticated
  using (
    (user_id = (select auth.uid()) and status in ('active', 'suspended', 'lifted'))
    or (select private.has_role(array['moderator', 'admin_utama']::public.app_role[]))
    or (select private.is_assigned_verifier(id)));
drop policy if exists appeals_select on public.appeals;
create policy appeals_select on public.appeals for select to authenticated
  using (
    user_id = (select auth.uid())
    or verifier_reviewer_id = (select auth.uid())
    or (select private.has_role(array['moderator', 'admin_utama']::public.app_role[])));
drop policy if exists blacklist_select_admin on public.blacklist_entries;
create policy blacklist_select_admin on public.blacklist_entries for select to authenticated
  using ((select private.has_role(array['admin_utama']::public.app_role[])));

do $$ declare f text; begin
  foreach f in array array[
    'public.impose_sanction(uuid,public.sanction_type,text,timestamptz,uuid,uuid)',
    'public.propose_permanent_ban(uuid,text,uuid,uuid)', 'public.approve_permanent_ban(uuid)',
    'public.reject_permanent_ban(uuid,text)', 'public.suspend_sanction(uuid,text)',
    'public.file_appeal(uuid,text)', 'public.assign_appeal_reviewer(uuid,uuid)',
    'public.recommend_appeal(uuid,text,text)', 'public.decide_appeal(uuid,boolean,text)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
  revoke all on function public.is_email_blacklisted(text) from public, anon, authenticated;
  grant execute on function public.is_email_blacklisted(text) to service_role;
  if exists (select 1 from pg_roles where rolname = 'supabase_auth_admin') then
    grant execute on function public.is_email_blacklisted(text) to supabase_auth_admin;
  end if;
end $$;

revoke all on all functions in schema private from public, anon, authenticated;
grant execute on function private.current_app_role()           to authenticated;
grant execute on function private.has_role(public.app_role[])  to authenticated;
grant execute on function private.is_staff()                   to authenticated;
grant execute on function private.email_verified()             to authenticated;
grant execute on function private.account_restricted(uuid)     to authenticated;
grant execute on function private.evidence_path_report(text)   to authenticated;
grant execute on function private.can_view_evidence(uuid)      to authenticated;
grant execute on function private.can_upload_evidence(uuid)    to authenticated;
grant execute on function private.has_conflict(uuid, uuid)     to authenticated;
grant execute on function private.is_forum_participant(uuid, uuid) to authenticated;
grant execute on function private.can_see_forum(uuid)          to authenticated;
grant execute on function private.can_see_forum_votes(uuid)    to authenticated;
grant execute on function private.is_assigned_verifier(uuid)   to authenticated;
