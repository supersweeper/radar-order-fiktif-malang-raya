-- Fase 1 Tahap 5: forum keputusan, peserta, suara. Prasyarat: 0001-0005. Idempoten.
--
-- Keputusan desain (D8, disetujui): forum menutup otomatis setelah SEMUA peserta yang berhak
-- (tanpa konflik atas laporan itu) memberi suara atau abstain; suara bersifat final dan
-- tersembunyi dari siapa pun (kecuali pemiliknya) sampai forum tidak lagi berstatus open.
-- Asumsi tercatat: suara seri (termasuk 0-0) ditentukan Admin Utama (resolve_tie);
-- hasil forum bersifat rujukan dan baru berlaku lewat decide_report(..., p_forum_id).

create table if not exists public.decision_forums (
  id                 uuid primary key default gen_random_uuid(),
  report_id          uuid not null references public.reports(id) on delete restrict,
  objection_id       uuid references public.objections(id) on delete restrict,
  question           text not null check (btrim(question) <> '' and char_length(question) <= 1000),
  status             text not null default 'open' check (status in ('open', 'tied', 'closed')),
  decision           text check (decision in ('approve', 'reject')),
  decided_by_tiebreak boolean not null default false,
  minutes            text check (minutes is null or char_length(minutes) <= 5000),
  opened_by          uuid not null references public.profiles(id) on delete restrict,
  decided_at         timestamptz,
  created_at         timestamptz not null default now(),
  constraint forum_status_consistency check (
    (status in ('open', 'tied') and decision is null and decided_at is null and not decided_by_tiebreak)
    or (status = 'closed' and decision is not null and decided_at is not null)),
  constraint forum_tiebreak_needs_minutes check (not decided_by_tiebreak or (minutes is not null and btrim(minutes) <> ''))
);
create unique index if not exists decision_forums_one_active_per_report
  on public.decision_forums (report_id) where status in ('open', 'tied');
create index if not exists decision_forums_report_idx on public.decision_forums (report_id);

create table if not exists public.forum_participants (
  id           uuid primary key default gen_random_uuid(),
  forum_id     uuid not null references public.decision_forums(id) on delete restrict,
  user_id      uuid not null references public.profiles(id) on delete restrict,
  role_at_time public.app_role not null check (role_at_time <> 'user'),
  added_by     uuid not null references public.profiles(id) on delete restrict,
  added_at     timestamptz not null default now(),
  constraint forum_participants_unique unique (forum_id, user_id)
);
create index if not exists forum_participants_user_idx on public.forum_participants (user_id);

create table if not exists public.forum_votes (
  id        uuid primary key default gen_random_uuid(),
  forum_id  uuid not null references public.decision_forums(id) on delete restrict,
  voter_id  uuid not null references public.profiles(id) on delete restrict,
  vote      text not null check (vote in ('approve', 'reject', 'abstain')),
  reason    text check (reason is null or char_length(reason) <= 1000),
  voted_at  timestamptz not null default now(),
  constraint forum_votes_one_per_voter unique (forum_id, voter_id)
);

-- ---------------------------------------------------------------------------
-- Fungsi bantu
-- ---------------------------------------------------------------------------
create or replace function private.is_forum_participant(p_forum_id uuid, p_user_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.forum_participants where forum_id = p_forum_id and user_id = p_user_id)
$$;

-- Suara terlihat bagi pemiliknya sendiri; bagi peserta dan moderator/admin hanya setelah voting selesai.
create or replace function private.can_see_forum_votes(p_forum_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.decision_forums f
     where f.id = p_forum_id and f.status <> 'open'
       and (private.is_forum_participant(f.id, (select auth.uid()))
            or private.has_role(array['moderator', 'admin_utama']::public.app_role[])))
$$;

create or replace function private.can_see_forum(p_forum_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select private.has_role(array['moderator', 'admin_utama']::public.app_role[])
      or private.is_forum_participant(p_forum_id, (select auth.uid()))
$$;

-- ---------------------------------------------------------------------------
-- Trigger perlindungan
-- ---------------------------------------------------------------------------
create or replace function private.forum_votes_guard()
returns trigger language plpgsql set search_path = '' as $$
declare v_status text; v_report uuid;
begin
  if tg_op <> 'INSERT' then
    raise exception 'suara bersifat final (append-only)' using errcode = '55000';
  end if;
  select status, report_id into v_status, v_report from public.decision_forums where id = new.forum_id;
  if v_status is distinct from 'open' then
    raise exception 'forum tidak lagi menerima suara' using errcode = '55000';
  end if;
  if not exists (select 1 from public.forum_participants where forum_id = new.forum_id and user_id = new.voter_id) then
    raise exception 'pemilih bukan peserta forum' using errcode = '42501';
  end if;
  if private.has_conflict(v_report, new.voter_id) then
    raise exception 'conflict_of_interest: peserta berkonflik tidak boleh memilih' using errcode = '42501';
  end if;
  return new;
end $$;
drop trigger if exists forum_votes_guard_trg on public.forum_votes;
create trigger forum_votes_guard_trg before insert or update or delete on public.forum_votes
  for each row execute function private.forum_votes_guard();

create or replace function private.forum_participants_guard()
returns trigger language plpgsql set search_path = '' as $$
declare v_status text; v_report uuid;
begin
  if tg_op <> 'INSERT' then
    raise exception 'forum_participants bersifat append-only' using errcode = '55000';
  end if;
  select status, report_id into v_status, v_report from public.decision_forums where id = new.forum_id;
  if v_status is distinct from 'open' then
    raise exception 'peserta hanya dapat ditambah saat forum open' using errcode = '55000';
  end if;
  if private.has_conflict(v_report, new.user_id) then
    raise exception 'conflict_of_interest: petugas berkonflik tidak boleh menjadi peserta' using errcode = '42501';
  end if;
  return new;
end $$;
drop trigger if exists forum_participants_guard_trg on public.forum_participants;
create trigger forum_participants_guard_trg before insert or update or delete on public.forum_participants
  for each row execute function private.forum_participants_guard();

-- Forum: identitas tetap, tidak dihapus, keputusan tidak berubah setelah closed.
create or replace function private.forums_guard()
returns trigger language plpgsql set search_path = '' as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'decision_forums bersifat permanen' using errcode = '55000';
  end if;
  if tg_op = 'INSERT' then
    if new.status <> 'open' then raise exception 'forum baru harus berstatus open' using errcode = '23514'; end if;
    if new.objection_id is not null and not exists
       (select 1 from public.objections o where o.id = new.objection_id and o.report_id = new.report_id) then
      raise exception 'keberatan tidak sesuai dengan laporan forum' using errcode = '23514';
    end if;
    return new;
  end if;
  if old.status = 'closed' then
    raise exception 'forum yang sudah ditutup tidak dapat diubah' using errcode = '55000';
  end if;
  if new.id <> old.id or new.report_id <> old.report_id or new.opened_by <> old.opened_by
     or new.objection_id is distinct from old.objection_id or new.question <> old.question
     or new.created_at <> old.created_at then
    raise exception 'identitas forum tidak boleh diubah' using errcode = '55000';
  end if;
  if coalesce(current_setting('app.forum_close', true), '') <> 'on' then
    raise exception 'status forum hanya berubah lewat fungsi forum' using errcode = '55000';
  end if;
  return new;
end $$;
drop trigger if exists forums_guard_trg on public.decision_forums;
create trigger forums_guard_trg before insert or update or delete on public.decision_forums
  for each row execute function private.forums_guard();

create or replace function private.phase5_no_truncate()
returns trigger language plpgsql set search_path = '' as $$
begin raise exception 'tabel ini permanen: TRUNCATE ditolak' using errcode = '55000'; end $$;
do $$ declare t text; begin
  foreach t in array array['decision_forums', 'forum_participants', 'forum_votes'] loop
    execute format('drop trigger if exists %I on public.%I', t || '_no_truncate_trg', t);
    execute format('create trigger %I before truncate on public.%I for each statement execute function private.phase5_no_truncate()',
                   t || '_no_truncate_trg', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- RPC
-- ---------------------------------------------------------------------------
-- Menutup forum bila semua peserta berhak sudah memilih. Mengembalikan status akhir.
create or replace function private.forum_try_close(p_forum_id uuid)
returns text language plpgsql security definer set search_path = '' as $$
declare f public.decision_forums; v_pending int; v_eligible int; v_a int; v_r int; v_ab int;
begin
  select * into f from public.decision_forums where id = p_forum_id for update;
  if not found then raise exception 'forum_not_found' using errcode = 'P0002'; end if;
  if f.status <> 'open' then return f.status; end if;
  select count(*) filter (where not exists (select 1 from public.forum_votes v where v.forum_id = f.id and v.voter_id = p.user_id)),
         count(*)
    into v_pending, v_eligible
    from public.forum_participants p
   where p.forum_id = f.id and not private.has_conflict(f.report_id, p.user_id);
  if v_eligible = 0 or v_pending > 0 then return 'open'; end if;
  select count(*) filter (where vote = 'approve'), count(*) filter (where vote = 'reject'), count(*) filter (where vote = 'abstain')
    into v_a, v_r, v_ab
    from public.forum_votes where forum_id = f.id;
  perform set_config('app.forum_close', 'on', true);
  if v_a = v_r then
    update public.decision_forums set status = 'tied' where id = f.id;
    perform private.write_audit('forum.tied', 'decision_forums', f.id::text, null, null,
      jsonb_build_object('report_id', f.report_id, 'approve', v_a, 'reject', v_r, 'abstain', v_ab));
    perform set_config('app.forum_close', 'off', true);
    return 'tied';
  end if;
  update public.decision_forums
     set status = 'closed', decision = case when v_a > v_r then 'approve' else 'reject' end, decided_at = now()
   where id = f.id;
  perform private.write_audit('forum.closed', 'decision_forums', f.id::text, null, null,
    jsonb_build_object('report_id', f.report_id, 'approve', v_a, 'reject', v_r, 'abstain', v_ab,
                       'decision', case when v_a > v_r then 'approve' else 'reject' end));
  perform set_config('app.forum_close', 'off', true);
  return 'closed';
end $$;

create or replace function public.open_forum(p_report_id uuid, p_question text, p_objection_id uuid default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := (select auth.uid()); r public.reports; v_id uuid;
begin
  r := private.lock_report_for_staff(p_report_id, array['moderator', 'admin_utama']::public.app_role[]);
  if p_question is null or btrim(p_question) = '' then raise exception 'reason_required' using errcode = '22023'; end if;
  insert into public.decision_forums (report_id, objection_id, question, opened_by)
  values (p_report_id, p_objection_id, p_question, v_uid) returning id into v_id;
  perform private.write_audit('forum.opened', 'decision_forums', v_id::text, p_question, null,
    jsonb_build_object('report_id', p_report_id, 'objection_id', p_objection_id));
  return v_id;
end $$;

create or replace function public.add_forum_participant(p_forum_id uuid, p_user_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := (select auth.uid()); f public.decision_forums; v_role public.app_role;
begin
  if v_uid is null or not private.has_role(array['moderator', 'admin_utama']::public.app_role[]) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into f from public.decision_forums where id = p_forum_id for update;
  if not found then raise exception 'forum_not_found' using errcode = 'P0002'; end if;
  select role into v_role from public.user_roles where user_id = p_user_id and revoked_at is null;
  if v_role is null then raise exception 'not_staff: peserta harus petugas aktif' using errcode = '22023'; end if;
  insert into public.forum_participants (forum_id, user_id, role_at_time, added_by)
  values (p_forum_id, p_user_id, v_role, v_uid);
  perform private.write_audit('forum.participant_added', 'decision_forums', p_forum_id::text, null, null,
    jsonb_build_object('user_id', p_user_id, 'role', v_role));
end $$;

create or replace function public.cast_vote(p_forum_id uuid, p_vote text, p_reason text default null)
returns text language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := (select auth.uid()); f public.decision_forums;
begin
  if v_uid is null or not private.is_staff() then raise exception 'forbidden' using errcode = '42501'; end if;
  select * into f from public.decision_forums where id = p_forum_id for update;
  if not found or not private.is_forum_participant(p_forum_id, v_uid) then
    raise exception 'forum_not_found' using errcode = 'P0002';
  end if;
  if f.status <> 'open' then raise exception 'forum_closed' using errcode = '55000'; end if;
  if p_vote is null or p_vote not in ('approve', 'reject', 'abstain') then
    raise exception 'invalid_vote' using errcode = '22023';
  end if;
  insert into public.forum_votes (forum_id, voter_id, vote, reason) values (p_forum_id, v_uid, p_vote, p_reason);
  -- Audit TIDAK memuat pilihan: kerahasiaan suara sampai forum selesai (juga terhadap admin).
  perform private.write_audit('forum.voted', 'decision_forums', p_forum_id::text, null, null,
    jsonb_build_object('voter_id', v_uid));
  return private.forum_try_close(p_forum_id);
end $$;

-- Dipakai bila konflik yang dinyatakan setelah penambahan peserta mengubah jumlah peserta berhak.
create or replace function public.close_forum(p_forum_id uuid)
returns text language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := (select auth.uid()); v_status text;
begin
  if v_uid is null or not private.has_role(array['moderator', 'admin_utama']::public.app_role[]) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  v_status := private.forum_try_close(p_forum_id);
  if v_status = 'open' then
    raise exception 'votes_pending: masih ada peserta berhak yang belum memilih (atau tidak ada peserta berhak)' using errcode = '55000';
  end if;
  return v_status;
end $$;

create or replace function public.resolve_tie(p_forum_id uuid, p_decision text, p_minutes text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := (select auth.uid()); f public.decision_forums;
begin
  if v_uid is null or not private.has_role(array['admin_utama']::public.app_role[]) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into f from public.decision_forums where id = p_forum_id for update;
  if not found then raise exception 'forum_not_found' using errcode = 'P0002'; end if;
  if f.status <> 'tied' then raise exception 'not_tied' using errcode = '55000'; end if;
  if p_decision is null or p_decision not in ('approve', 'reject') then
    raise exception 'invalid_vote' using errcode = '22023';
  end if;
  if p_minutes is null or btrim(p_minutes) = '' then raise exception 'reason_required' using errcode = '22023'; end if;
  perform set_config('app.forum_close', 'on', true);
  update public.decision_forums
     set status = 'closed', decision = p_decision, decided_by_tiebreak = true, minutes = p_minutes, decided_at = now()
   where id = p_forum_id;
  perform set_config('app.forum_close', 'off', true);
  perform private.write_audit('forum.tiebreak', 'decision_forums', p_forum_id::text, p_minutes, null,
    jsonb_build_object('report_id', f.report_id, 'decision', p_decision));
end $$;

-- decide_report menerima rujukan forum (opsional). Menggantikan versi Tahap 4.
drop function if exists public.decide_report(uuid, text, text);
create or replace function public.decide_report(
  p_report_id uuid, p_decision text, p_reason text, p_forum_id uuid default null)
returns void language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := (select auth.uid()); r public.reports; v public.verification_reviews; f public.decision_forums;
begin
  r := private.lock_report_for_staff(p_report_id, array['moderator']::public.app_role[]);
  if p_decision not in ('verified', 'rejected') then raise exception 'invalid_result' using errcode = '22023'; end if;
  if r.status <> 'under_review' then
    raise exception 'invalid_transition: % -> %', r.status, p_decision using errcode = '55000';
  end if;
  select * into v from public.verification_reviews where report_id = p_report_id
   order by started_at desc, id desc limit 1;
  if not found or v.result not in ('recommend_verified', 'recommend_rejected')
     or v.reviewed_at <= coalesce(private.last_review_cycle_start(p_report_id), '-infinity') then
    raise exception 'recommendation_required: belum ada rekomendasi verifier pada siklus pemeriksaan ini' using errcode = '55000';
  end if;
  if v.verifier_id = v_uid then raise exception 'conflict_of_interest' using errcode = '42501'; end if;
  if p_forum_id is not null then
    select * into f from public.decision_forums where id = p_forum_id;
    if not found or f.report_id <> p_report_id then raise exception 'forum_not_found' using errcode = 'P0002'; end if;
    if f.status <> 'closed' then raise exception 'forum_not_closed' using errcode = '55000'; end if;
    if (f.decision = 'approve') <> (p_decision = 'verified') then
      raise exception 'forum_decision_mismatch: keputusan tidak sama dengan hasil forum' using errcode = '55000';
    end if;
    perform private.write_audit('report.forum_referenced', 'reports', p_report_id::text, p_reason, null,
      jsonb_build_object('forum_id', p_forum_id, 'forum_decision', f.decision));
  end if;
  perform private.transition_report(p_report_id, p_decision::public.report_status, p_reason, 'moderator',
    case p_decision when 'verified' then 'decided_verified' else 'decided_rejected' end);
end $$;

-- ---------------------------------------------------------------------------
-- RLS dan hak akses
-- ---------------------------------------------------------------------------
alter table public.decision_forums    enable row level security;
alter table public.forum_participants enable row level security;
alter table public.forum_votes        enable row level security;
revoke all on table public.decision_forums, public.forum_participants, public.forum_votes
  from public, anon, authenticated, service_role;
grant select on public.decision_forums, public.forum_participants to authenticated, service_role;
-- Suara: service_role sengaja tanpa SELECT (kerahasiaan sampai forum selesai).
grant select on public.forum_votes to authenticated;

drop policy if exists forums_select on public.decision_forums;
create policy forums_select on public.decision_forums for select to authenticated
  using ((select private.can_see_forum(id)));
drop policy if exists forum_participants_select on public.forum_participants;
create policy forum_participants_select on public.forum_participants for select to authenticated
  using ((select private.can_see_forum(forum_id)));
drop policy if exists forum_votes_select on public.forum_votes;
create policy forum_votes_select on public.forum_votes for select to authenticated
  using (voter_id = (select auth.uid()) or (select private.can_see_forum_votes(forum_id)));

do $$ declare f text; begin
  foreach f in array array[
    'public.open_forum(uuid,text,uuid)', 'public.add_forum_participant(uuid,uuid)',
    'public.cast_vote(uuid,text,text)', 'public.close_forum(uuid)', 'public.resolve_tie(uuid,text,text)',
    'public.decide_report(uuid,text,text,uuid)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
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
