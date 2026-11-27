-- Fase 1 Tahap 4: pemeriksaan verifier, temuan, indikasi duplikasi, keberatan, penarikan,
-- konflik kepentingan, dan RPC aksi petugas. Prasyarat: 0001-0004. Idempoten.
--
-- Asumsi yang tercatat (bukan dari SRS, lihat docs/RANCANGAN_DB_FASE_1.md):
--  * Pelapor yang juga petugas dianggap berkonflik atas laporannya sendiri.
--  * Rekomendasi verifier wajib bercatatan; keputusan moderator wajib berasal dari rekomendasi
--    yang dibuat SETELAH laporan terakhir masuk Under Review (per siklus pemeriksaan).
--  * Nilai finding_type/assessment/basis dibatasi daftar kecil yang dapat diperluas.

-- ---------------------------------------------------------------------------
-- 1. Tabel
-- ---------------------------------------------------------------------------
create table if not exists public.conflict_declarations (
  id          uuid primary key default gen_random_uuid(),
  report_id   uuid not null references public.reports(id) on delete restrict,
  staff_id    uuid not null references public.profiles(id) on delete restrict,
  reason      text not null check (btrim(reason) <> ''),
  declared_at timestamptz not null default now(),
  constraint conflict_declarations_unique unique (report_id, staff_id)
);

create table if not exists public.verification_reviews (
  id          uuid primary key default gen_random_uuid(),
  report_id   uuid not null references public.reports(id) on delete restrict,
  verifier_id uuid not null references public.profiles(id) on delete restrict,
  result      text not null default 'in_progress'
                check (result in ('in_progress', 'recommend_verified', 'recommend_rejected', 'needs_revision', 'abandoned')),
  notes       text check (notes is null or char_length(notes) <= 2000),
  started_at  timestamptz not null default now(),
  reviewed_at timestamptz,
  constraint verification_reviews_reviewed_consistency
    check ((result = 'in_progress') = (reviewed_at is null))
);
create unique index if not exists verification_reviews_one_open
  on public.verification_reviews (report_id) where result = 'in_progress';
create index if not exists verification_reviews_report_idx on public.verification_reviews (report_id, started_at desc);
create index if not exists verification_reviews_verifier_idx on public.verification_reviews (verifier_id);

create table if not exists public.verification_findings (
  id            uuid primary key default gen_random_uuid(),
  review_id     uuid not null references public.verification_reviews(id) on delete restrict,
  evidence_type public.evidence_type,
  finding_type  text not null check (finding_type in ('evidence_quality', 'consistency', 'location', 'timeline', 'other')),
  description   text not null check (btrim(description) <> '' and char_length(description) <= 1000),
  assessment    text not null check (assessment in ('supports', 'inconclusive', 'contradicts')),
  created_at    timestamptz not null default now()
);
create index if not exists verification_findings_review_idx on public.verification_findings (review_id);

create table if not exists public.duplicate_indications (
  id              uuid primary key default gen_random_uuid(),
  report_id       uuid not null references public.reports(id) on delete restrict,
  duplicate_of_id uuid not null references public.reports(id) on delete restrict,
  review_id       uuid not null references public.verification_reviews(id) on delete restrict,
  basis           text[] not null,
  notes           text check (notes is null or char_length(notes) <= 1000),
  created_at      timestamptz not null default now(),
  constraint duplicate_not_self check (report_id <> duplicate_of_id),
  -- BR-08: kesamaan lokasi saja bukan dasar yang cukup.
  constraint duplicate_basis_valid check (
    cardinality(basis) >= 1
    and basis <@ array['location', 'time', 'story', 'evidence']::text[]
    and basis <> array['location']::text[])
);
create index if not exists duplicate_indications_report_idx on public.duplicate_indications (report_id);

create table if not exists public.objections (
  id              uuid primary key default gen_random_uuid(),
  report_id       uuid not null references public.reports(id) on delete restrict,
  user_id         uuid not null default auth.uid() references public.profiles(id) on delete restrict,
  reason          text not null check (btrim(reason) <> '' and char_length(reason) <= 1000),
  status          text not null default 'open' check (status in ('open', 'under_review', 'accepted', 'rejected')),
  outcome         text check (outcome in ('reject_objection', 'reopen', 'reject_report')),
  reviewer_id     uuid references public.profiles(id) on delete restrict,
  review_notes    text check (review_notes is null or char_length(review_notes) <= 2000),
  decided_by      uuid references public.profiles(id) on delete restrict,
  decision_reason text,
  decided_at      timestamptz,
  created_at      timestamptz not null default now(),
  constraint objections_decision_consistency check (
    (status in ('open', 'under_review') and decided_by is null and decided_at is null and outcome is null and decision_reason is null)
    or (status in ('accepted', 'rejected') and decided_by is not null and decided_at is not null
        and outcome is not null and decision_reason is not null and btrim(decision_reason) <> ''))
);
create unique index if not exists objections_one_open_per_user
  on public.objections (report_id, user_id) where status in ('open', 'under_review');
create index if not exists objections_report_idx on public.objections (report_id);

create table if not exists public.withdrawal_requests (
  id              uuid primary key default gen_random_uuid(),
  report_id       uuid not null references public.reports(id) on delete restrict,
  requested_by    uuid not null references public.profiles(id) on delete restrict,
  reason          text not null check (btrim(reason) <> '' and char_length(reason) <= 1000),
  status          text not null default 'open' check (status in ('open', 'approved', 'rejected')),
  decided_by      uuid references public.profiles(id) on delete restrict,
  decision_reason text,
  decided_at      timestamptz,
  created_at      timestamptz not null default now(),
  constraint withdrawal_decision_consistency check (
    (status = 'open' and decided_by is null and decided_at is null and decision_reason is null)
    or (status in ('approved', 'rejected') and decided_by is not null and decided_at is not null
        and decision_reason is not null and btrim(decision_reason) <> ''))
);
create unique index if not exists withdrawal_one_open_per_report
  on public.withdrawal_requests (report_id) where status = 'open';

-- ---------------------------------------------------------------------------
-- 2. Fungsi bantu
-- ---------------------------------------------------------------------------
-- Konflik kepentingan: pelapor sendiri, atau petugas yang menyatakannya (FR-22, BR-10).
create or replace function private.has_conflict(p_report_id uuid, p_staff_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.reports r where r.id = p_report_id and r.user_id = p_staff_id)
      or exists (select 1 from public.conflict_declarations c where c.report_id = p_report_id and c.staff_id = p_staff_id)
$$;

-- Menggantikan versi Tahap 3: verifier boleh membuka file bukti HANYA setelah start_review (D5).
create or replace function private.can_view_evidence(p_report_id uuid)
returns boolean language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := (select auth.uid()); r public.reports;
begin
  if v_uid is null or p_report_id is null then return false; end if;
  select * into r from public.reports where id = p_report_id;
  if not found then return false; end if;
  if r.user_id = v_uid then return true; end if;
  if r.status <> 'draft' and private.has_role(array['moderator', 'admin_utama']::public.app_role[])
     and not private.has_conflict(p_report_id, v_uid) then
    return true;
  end if;
  if private.has_role(array['verifier']::public.app_role[])
     and exists (select 1 from public.verification_reviews v where v.report_id = p_report_id and v.verifier_id = v_uid)
     and not private.has_conflict(p_report_id, v_uid) then
    return true;
  end if;
  return false;
end $$;

-- Saat terakhir laporan masuk Under Review (batas siklus pemeriksaan).
create or replace function private.last_review_cycle_start(p_report_id uuid)
returns timestamptz language sql stable security definer set search_path = '' as $$
  select max(created_at) from public.report_histories where report_id = p_report_id and new_status = 'under_review'
$$;

-- ---------------------------------------------------------------------------
-- 3. Trigger perlindungan
-- ---------------------------------------------------------------------------
create or replace function private.reviews_guard()
returns trigger language plpgsql set search_path = '' as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'verification_reviews bersifat permanen' using errcode = '55000';
  end if;
  if tg_op = 'INSERT' then
    if new.result <> 'in_progress' then
      raise exception 'review baru harus berstatus in_progress' using errcode = '23514';
    end if;
    return new;
  end if;
  if old.result <> 'in_progress' then
    raise exception 'review yang sudah selesai tidak dapat diubah' using errcode = '55000';
  end if;
  if new.id <> old.id or new.report_id <> old.report_id or new.verifier_id <> old.verifier_id
     or new.started_at <> old.started_at then
    raise exception 'kolom identitas review tidak boleh diubah' using errcode = '55000';
  end if;
  if (new.result <> old.result or new.reviewed_at is distinct from old.reviewed_at)
     and coalesce(current_setting('app.review_close', true), '') <> 'on' then
    raise exception 'hasil review hanya dapat diisi lewat fungsi submit_review/return_for_revision' using errcode = '55000';
  end if;
  return new;
end $$;
drop trigger if exists reviews_guard_trg on public.verification_reviews;
create trigger reviews_guard_trg before insert or update or delete on public.verification_reviews
  for each row execute function private.reviews_guard();

-- Temuan dan indikasi duplikasi hanya bisa ditulis selama review milik penulis masih in_progress.
create or replace function private.review_children_guard()
returns trigger language plpgsql set search_path = '' as $$
declare v_result text; v_report uuid; v_dup_status public.report_status;
begin
  if tg_op = 'DELETE' then
    raise exception '% bersifat permanen: tidak boleh dihapus', tg_table_name using errcode = '55000';
  end if;
  select result, report_id into v_result, v_report from public.verification_reviews where id = new.review_id;
  if v_result is distinct from 'in_progress' then
    raise exception 'temuan hanya dapat ditulis saat review in_progress' using errcode = '55000';
  end if;
  if tg_op = 'UPDATE' and new.review_id <> old.review_id then
    raise exception 'review_id tidak boleh diubah' using errcode = '55000';
  end if;
  if tg_table_name = 'duplicate_indications' then
    if new.report_id <> v_report then
      raise exception 'indikasi duplikasi harus untuk laporan yang sedang diperiksa' using errcode = '23514';
    end if;
    select status into v_dup_status from public.reports where id = new.duplicate_of_id;
    if v_dup_status is null or v_dup_status = 'draft' then
      raise exception 'laporan pembanding tidak valid' using errcode = '23514';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists findings_guard_trg on public.verification_findings;
create trigger findings_guard_trg before insert or update or delete on public.verification_findings
  for each row execute function private.review_children_guard();
drop trigger if exists duplicates_guard_trg on public.duplicate_indications;
create trigger duplicates_guard_trg before insert or update or delete on public.duplicate_indications
  for each row execute function private.review_children_guard();

-- Keputusan keberatan/penarikan tidak dapat diubah setelah diputuskan; tidak ada DELETE.
create or replace function private.decision_rows_guard()
returns trigger language plpgsql set search_path = '' as $$
begin
  if tg_op = 'DELETE' then
    raise exception '% bersifat permanen: tidak boleh dihapus', tg_table_name using errcode = '55000';
  end if;
  if tg_op = 'UPDATE' then
    if old.status in ('accepted', 'rejected', 'approved') then
      raise exception '% yang sudah diputuskan tidak dapat diubah', tg_table_name using errcode = '55000';
    end if;
    if new.id <> old.id or new.report_id <> old.report_id or new.reason <> old.reason
       or new.created_at <> old.created_at then
      raise exception 'isi permintaan tidak boleh diubah' using errcode = '55000';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists objections_guard_trg on public.objections;
create trigger objections_guard_trg before update or delete on public.objections
  for each row execute function private.decision_rows_guard();
drop trigger if exists withdrawals_guard_trg on public.withdrawal_requests;
create trigger withdrawals_guard_trg before update or delete on public.withdrawal_requests
  for each row execute function private.decision_rows_guard();

create or replace function private.conflicts_guard()
returns trigger language plpgsql set search_path = '' as $$
begin
  raise exception 'conflict_declarations bersifat append-only' using errcode = '55000';
end $$;
drop trigger if exists conflicts_guard_trg on public.conflict_declarations;
create trigger conflicts_guard_trg before update or delete on public.conflict_declarations
  for each row execute function private.conflicts_guard();

create or replace function private.phase4_no_truncate()
returns trigger language plpgsql set search_path = '' as $$
begin raise exception 'tabel ini permanen: TRUNCATE ditolak' using errcode = '55000'; end $$;
do $$ declare t text; begin
  foreach t in array array['conflict_declarations','verification_reviews','verification_findings',
                           'duplicate_indications','objections','withdrawal_requests'] loop
    execute format('drop trigger if exists %I on public.%I', t || '_no_truncate_trg', t);
    execute format('create trigger %I before truncate on public.%I for each statement execute function private.phase4_no_truncate()',
                   t || '_no_truncate_trg', t);
  end loop;
end $$;

-- Audit atomik untuk tulisan langsung verifier (temuan, duplikasi).
create or replace function private.review_children_audit()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform private.write_audit(tg_table_name || '.' || lower(tg_op), tg_table_name, new.id::text, null,
    case when tg_op = 'UPDATE' then to_jsonb(old) end, to_jsonb(new));
  return null;
end $$;
drop trigger if exists findings_audit_trg on public.verification_findings;
create trigger findings_audit_trg after insert or update on public.verification_findings
  for each row execute function private.review_children_audit();
drop trigger if exists duplicates_audit_trg on public.duplicate_indications;
create trigger duplicates_audit_trg after insert or update on public.duplicate_indications
  for each row execute function private.review_children_audit();

-- ---------------------------------------------------------------------------
-- 4. RPC petugas
-- ---------------------------------------------------------------------------
create or replace function private.lock_report_for_staff(p_report_id uuid, p_roles public.app_role[])
returns public.reports language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := (select auth.uid()); r public.reports;
begin
  if v_uid is null or not private.has_role(p_roles) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into r from public.reports where id = p_report_id for update;
  if not found or r.status = 'draft' then
    raise exception 'report_not_found' using errcode = 'P0002';
  end if;
  if private.has_conflict(p_report_id, v_uid) then
    raise exception 'conflict_of_interest' using errcode = '42501';
  end if;
  return r;
end $$;

create or replace function public.declare_conflict(p_report_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := (select auth.uid()); r public.reports;
begin
  if v_uid is null or not private.is_staff() then raise exception 'forbidden' using errcode = '42501'; end if;
  select * into r from public.reports where id = p_report_id;
  if not found or r.status = 'draft' then raise exception 'report_not_found' using errcode = 'P0002'; end if;
  if p_reason is null or btrim(p_reason) = '' then raise exception 'reason_required' using errcode = '22023'; end if;
  insert into public.conflict_declarations (report_id, staff_id, reason) values (p_report_id, v_uid, p_reason);
  perform private.write_audit('conflict.declared', 'reports', p_report_id::text, p_reason, null,
    jsonb_build_object('staff_id', v_uid));
end $$;

create or replace function public.start_review(p_report_id uuid)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid()); r public.reports; o public.verification_reviews;
  v_cycle timestamptz; v_id uuid;
begin
  r := private.lock_report_for_staff(p_report_id, array['verifier']::public.app_role[]);
  if r.status = 'pending' then
    perform private.transition_report(p_report_id, 'under_review', 'Pemeriksaan dimulai oleh verifier', 'verifier', 'review_started');
  elsif r.status = 'under_review' then
    select * into o from public.verification_reviews where report_id = p_report_id and result = 'in_progress';
    if found then
      if not private.has_conflict(p_report_id, o.verifier_id) then
        raise exception 'review_in_progress' using errcode = '55000';
      end if;
      -- Verifier sebelumnya menyatakan konflik: review dilepas agar tidak buntu.
      perform set_config('app.review_close', 'on', true);
      update public.verification_reviews set result = 'abandoned', reviewed_at = now() where id = o.id;
      perform set_config('app.review_close', 'off', true);
    end if;
    v_cycle := private.last_review_cycle_start(p_report_id);
    if exists (select 1 from public.verification_reviews
                where report_id = p_report_id and result in ('recommend_verified', 'recommend_rejected')
                  and reviewed_at > v_cycle) then
      raise exception 'review_already_completed' using errcode = '55000';
    end if;
  else
    raise exception 'invalid_transition: review tidak dapat dimulai pada status %', r.status using errcode = '55000';
  end if;
  insert into public.verification_reviews (report_id, verifier_id) values (p_report_id, v_uid) returning id into v_id;
  perform private.write_audit('review.started', 'verification_reviews', v_id::text, null, null,
    jsonb_build_object('report_id', p_report_id, 'verifier_id', v_uid));
  return v_id;
end $$;

create or replace function public.submit_review(p_review_id uuid, p_result text, p_notes text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := (select auth.uid()); v public.verification_reviews;
begin
  if v_uid is null or not private.has_role(array['verifier']::public.app_role[]) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into v from public.verification_reviews where id = p_review_id for update;
  if not found or v.verifier_id <> v_uid then raise exception 'review_not_found' using errcode = 'P0002'; end if;
  if v.result <> 'in_progress' then raise exception 'review_closed' using errcode = '55000'; end if;
  if private.has_conflict(v.report_id, v_uid) then raise exception 'conflict_of_interest' using errcode = '42501'; end if;
  if p_result is null or p_result not in ('recommend_verified', 'recommend_rejected') then
    raise exception 'invalid_result' using errcode = '22023';
  end if;
  if p_notes is null or btrim(p_notes) = '' then raise exception 'reason_required' using errcode = '22023'; end if;
  perform set_config('app.review_close', 'on', true);
  update public.verification_reviews set result = p_result, notes = p_notes, reviewed_at = now() where id = p_review_id;
  perform set_config('app.review_close', 'off', true);
  perform private.write_audit('review.submitted', 'verification_reviews', p_review_id::text, p_notes, null,
    jsonb_build_object('report_id', v.report_id, 'result', p_result));
end $$;

create or replace function public.return_for_revision(p_report_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := (select auth.uid()); r public.reports; o public.verification_reviews;
begin
  r := private.lock_report_for_staff(p_report_id, array['verifier']::public.app_role[]);
  select * into o from public.verification_reviews
   where report_id = p_report_id and result = 'in_progress' and verifier_id = v_uid for update;
  if not found then raise exception 'review_not_found' using errcode = 'P0002'; end if;
  perform private.transition_report(p_report_id, 'needs_revision', p_reason, 'verifier', 'revision_requested');
  perform set_config('app.review_close', 'on', true);
  update public.verification_reviews set result = 'needs_revision', reviewed_at = now(),
         notes = coalesce(notes, p_reason) where id = o.id;
  perform set_config('app.review_close', 'off', true);
end $$;

create or replace function public.decide_report(p_report_id uuid, p_decision text, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := (select auth.uid()); r public.reports; v public.verification_reviews;
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
  perform private.transition_report(p_report_id, p_decision::public.report_status, p_reason, 'moderator',
    case p_decision when 'verified' then 'decided_verified' else 'decided_rejected' end);
end $$;

-- Penarikan (FR-44/45)
create or replace function public.request_withdrawal(p_report_id uuid, p_reason text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := (select auth.uid()); r public.reports; v_id uuid;
begin
  if v_uid is null then raise exception 'forbidden' using errcode = '42501'; end if;
  select * into r from public.reports where id = p_report_id for update;
  if not found or r.user_id <> v_uid then raise exception 'report_not_found' using errcode = 'P0002'; end if;
  if not private.email_verified() then raise exception 'email_not_verified' using errcode = '42501'; end if;
  if r.status <> 'under_review' then raise exception 'invalid_transition: penarikan hanya saat Under Review' using errcode = '55000'; end if;
  if p_reason is null or btrim(p_reason) = '' then raise exception 'reason_required' using errcode = '22023'; end if;
  insert into public.withdrawal_requests (report_id, requested_by, reason) values (p_report_id, v_uid, p_reason)
  returning id into v_id;
  perform private.write_audit('withdrawal.requested', 'withdrawal_requests', v_id::text, p_reason, null,
    jsonb_build_object('report_id', p_report_id));
  return v_id;
end $$;

create or replace function public.decide_withdrawal(p_request_id uuid, p_approve boolean, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := (select auth.uid()); w public.withdrawal_requests; r public.reports;
begin
  select * into w from public.withdrawal_requests where id = p_request_id for update;
  if not found then
    if v_uid is null or not private.has_role(array['moderator']::public.app_role[]) then
      raise exception 'forbidden' using errcode = '42501';
    end if;
    raise exception 'request_not_found' using errcode = 'P0002';
  end if;
  r := private.lock_report_for_staff(w.report_id, array['moderator']::public.app_role[]);
  if w.status <> 'open' then raise exception 'already_decided' using errcode = '55000'; end if;
  if p_reason is null or btrim(p_reason) = '' then raise exception 'reason_required' using errcode = '22023'; end if;
  if p_approve then
    perform private.transition_report(w.report_id, 'cancelled', p_reason, 'moderator', 'withdrawn');
  end if;
  update public.withdrawal_requests
     set status = case when p_approve then 'approved' else 'rejected' end,
         decided_by = v_uid, decision_reason = p_reason, decided_at = now()
   where id = p_request_id;
  perform private.write_audit('withdrawal.decided', 'withdrawal_requests', p_request_id::text, p_reason, null,
    jsonb_build_object('report_id', w.report_id, 'approved', p_approve));
end $$;

-- Keberatan atas laporan Verified (FR-20). Laporan tetap publik selama diperiksa (D4).
create or replace function public.file_objection(p_report_id uuid, p_reason text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := (select auth.uid()); v_status public.report_status; v_id uuid;
begin
  if v_uid is null then raise exception 'forbidden' using errcode = '42501'; end if;
  if not private.email_verified() then raise exception 'email_not_verified' using errcode = '42501'; end if;
  if private.account_restricted(v_uid) then raise exception 'account_restricted' using errcode = '42501'; end if;
  select status into v_status from public.reports where id = p_report_id;
  if not found or v_status <> 'verified' then raise exception 'report_not_found' using errcode = 'P0002'; end if;
  if p_reason is null or btrim(p_reason) = '' then raise exception 'reason_required' using errcode = '22023'; end if;
  insert into public.objections (report_id, user_id, reason) values (p_report_id, v_uid, p_reason) returning id into v_id;
  perform private.write_audit('objection.filed', 'objections', v_id::text, p_reason, null,
    jsonb_build_object('report_id', p_report_id));
  return v_id;
end $$;

create or replace function public.add_objection_notes(p_objection_id uuid, p_notes text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := (select auth.uid()); o public.objections;
begin
  select * into o from public.objections where id = p_objection_id for update;
  if not found then
    if v_uid is null or not private.has_role(array['verifier']::public.app_role[]) then
      raise exception 'forbidden' using errcode = '42501';
    end if;
    raise exception 'objection_not_found' using errcode = 'P0002';
  end if;
  perform private.lock_report_for_staff(o.report_id, array['verifier']::public.app_role[]);
  if o.status not in ('open', 'under_review') then raise exception 'already_decided' using errcode = '55000'; end if;
  if o.reviewer_id is not null and o.reviewer_id <> v_uid then raise exception 'objection_assigned' using errcode = '55000'; end if;
  if p_notes is null or btrim(p_notes) = '' then raise exception 'reason_required' using errcode = '22023'; end if;
  update public.objections set reviewer_id = v_uid, review_notes = p_notes, status = 'under_review' where id = p_objection_id;
  perform private.write_audit('objection.reviewed', 'objections', p_objection_id::text, p_notes, null,
    jsonb_build_object('report_id', o.report_id));
end $$;

create or replace function public.decide_objection(p_objection_id uuid, p_outcome text, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := (select auth.uid()); o public.objections;
begin
  select * into o from public.objections where id = p_objection_id for update;
  if not found then
    if v_uid is null or not private.has_role(array['moderator']::public.app_role[]) then
      raise exception 'forbidden' using errcode = '42501';
    end if;
    raise exception 'objection_not_found' using errcode = 'P0002';
  end if;
  perform private.lock_report_for_staff(o.report_id, array['moderator']::public.app_role[]);
  if o.status not in ('open', 'under_review') then raise exception 'already_decided' using errcode = '55000'; end if;
  if p_outcome is null or p_outcome not in ('reject_objection', 'reopen', 'reject_report') then
    raise exception 'invalid_result' using errcode = '22023';
  end if;
  if p_reason is null or btrim(p_reason) = '' then raise exception 'reason_required' using errcode = '22023'; end if;
  if p_outcome = 'reopen' then
    perform private.transition_report(o.report_id, 'under_review', p_reason, 'moderator', 'objection_accepted');
  elsif p_outcome = 'reject_report' then
    perform private.transition_report(o.report_id, 'rejected', p_reason, 'moderator', 'objection_rejected_report');
  end if;
  update public.objections
     set status = case when p_outcome = 'reject_objection' then 'rejected' else 'accepted' end,
         outcome = p_outcome, decided_by = v_uid, decision_reason = p_reason, decided_at = now()
   where id = p_objection_id;
  perform private.write_audit('objection.decided', 'objections', p_objection_id::text, p_reason, null,
    jsonb_build_object('report_id', o.report_id, 'outcome', p_outcome));
end $$;

-- ---------------------------------------------------------------------------
-- 5. RLS dan hak akses
-- ---------------------------------------------------------------------------
alter table public.conflict_declarations enable row level security;
alter table public.verification_reviews  enable row level security;
alter table public.verification_findings enable row level security;
alter table public.duplicate_indications enable row level security;
alter table public.objections            enable row level security;
alter table public.withdrawal_requests   enable row level security;

revoke all on table public.conflict_declarations, public.verification_reviews, public.verification_findings,
  public.duplicate_indications, public.objections, public.withdrawal_requests
  from public, anon, authenticated, service_role;
grant select on public.conflict_declarations, public.verification_reviews, public.verification_findings,
  public.duplicate_indications, public.objections, public.withdrawal_requests to authenticated;
grant select on public.conflict_declarations, public.verification_reviews, public.verification_findings,
  public.duplicate_indications, public.objections, public.withdrawal_requests to service_role;
-- Tulis langsung (dengan RLS) hanya untuk catatan verifier selama review berjalan.
grant update (notes) on public.verification_reviews to authenticated;
grant insert (review_id, evidence_type, finding_type, description, assessment) on public.verification_findings to authenticated;
grant update (evidence_type, finding_type, description, assessment) on public.verification_findings to authenticated;
grant insert (report_id, duplicate_of_id, review_id, basis, notes) on public.duplicate_indications to authenticated;
grant update (duplicate_of_id, basis, notes) on public.duplicate_indications to authenticated;

drop policy if exists conflicts_select on public.conflict_declarations;
create policy conflicts_select on public.conflict_declarations for select to authenticated
  using (staff_id = (select auth.uid()) or (select private.has_role(array['moderator', 'admin_utama']::public.app_role[])));

drop policy if exists reviews_select on public.verification_reviews;
create policy reviews_select on public.verification_reviews for select to authenticated
  using (verifier_id = (select auth.uid()) or (select private.has_role(array['moderator', 'admin_utama']::public.app_role[])));
drop policy if exists reviews_update_notes on public.verification_reviews;
create policy reviews_update_notes on public.verification_reviews for update to authenticated
  using (verifier_id = (select auth.uid()) and result = 'in_progress'
         and not (select private.has_conflict(report_id, (select auth.uid()))))
  with check (verifier_id = (select auth.uid()) and result = 'in_progress');

drop policy if exists findings_select on public.verification_findings;
create policy findings_select on public.verification_findings for select to authenticated
  using (exists (select 1 from public.verification_reviews v where v.id = verification_findings.review_id));
drop policy if exists findings_write on public.verification_findings;
create policy findings_write on public.verification_findings for insert to authenticated
  with check (exists (select 1 from public.verification_reviews v
                       where v.id = review_id and v.verifier_id = (select auth.uid()) and v.result = 'in_progress'
                         and not (select private.has_conflict(v.report_id, (select auth.uid())))));
drop policy if exists findings_update on public.verification_findings;
create policy findings_update on public.verification_findings for update to authenticated
  using (exists (select 1 from public.verification_reviews v
                  where v.id = review_id and v.verifier_id = (select auth.uid()) and v.result = 'in_progress'));

drop policy if exists duplicates_select on public.duplicate_indications;
create policy duplicates_select on public.duplicate_indications for select to authenticated
  using (exists (select 1 from public.verification_reviews v where v.id = duplicate_indications.review_id));
drop policy if exists duplicates_write on public.duplicate_indications;
create policy duplicates_write on public.duplicate_indications for insert to authenticated
  with check (exists (select 1 from public.verification_reviews v
                       where v.id = review_id and v.verifier_id = (select auth.uid()) and v.result = 'in_progress'
                         and not (select private.has_conflict(v.report_id, (select auth.uid())))));
drop policy if exists duplicates_update on public.duplicate_indications;
create policy duplicates_update on public.duplicate_indications for update to authenticated
  using (exists (select 1 from public.verification_reviews v
                  where v.id = review_id and v.verifier_id = (select auth.uid()) and v.result = 'in_progress'));

-- Pemilik melihat keberatan miliknya; petugas (verifier/moderator/admin) melihat semuanya.
drop policy if exists objections_select on public.objections;
create policy objections_select on public.objections for select to authenticated
  using (user_id = (select auth.uid()) or (select private.is_staff()));
drop policy if exists withdrawals_select on public.withdrawal_requests;
create policy withdrawals_select on public.withdrawal_requests for select to authenticated
  using (requested_by = (select auth.uid())
         or (select private.has_role(array['moderator', 'admin_utama']::public.app_role[])));

-- ---------------------------------------------------------------------------
-- 6. Hak fungsi
-- ---------------------------------------------------------------------------
do $$ declare f text; begin
  foreach f in array array[
    'public.declare_conflict(uuid,text)', 'public.start_review(uuid)', 'public.submit_review(uuid,text,text)',
    'public.return_for_revision(uuid,text)', 'public.decide_report(uuid,text,text)',
    'public.request_withdrawal(uuid,text)', 'public.decide_withdrawal(uuid,boolean,text)',
    'public.file_objection(uuid,text)', 'public.add_objection_notes(uuid,text)', 'public.decide_objection(uuid,text,text)'] loop
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
