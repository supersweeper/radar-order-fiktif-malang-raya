-- HANYA UNTUK PENGUJIAN LOKAL. JANGAN dijalankan di project Supabase asli.
-- Meniru bagian Supabase yang dibutuhkan migrasi: peran, skema auth, auth.uid(),
-- dan HAK DEFAULT yang diberikan Supabase ke tabel/fungsi baru (supaya pencabutan
-- hak di migrasi benar-benar teruji).

do $$ begin
  if current_database() not like 'rof\_%' then
    raise exception 'Stub uji hanya boleh dijalankan pada database bernama rof_*';
  end if;
end $$;

do $$ begin
  create role anon nologin;
exception when duplicate_object then null; end $$;
do $$ begin
  create role authenticated nologin;
exception when duplicate_object then null; end $$;
do $$ begin
  create role service_role nologin bypassrls;
exception when duplicate_object then null; end $$;

create schema if not exists extensions;
create schema if not exists auth;

create table if not exists auth.users (
  id                 uuid primary key default gen_random_uuid(),
  email              text unique,
  email_confirmed_at timestamptz
);

create or replace function auth.uid() returns uuid language sql stable as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'
  )::uuid
$$;

grant usage on schema public, auth, extensions to anon, authenticated, service_role;
grant execute on function auth.uid() to anon, authenticated, service_role;

-- Hak default Supabase: semua tabel/fungsi/sekuens baru di public terbuka.
alter default privileges in schema public grant all on tables    to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Stub Storage (Tahap 3): tabel buckets/objects dengan RLS aktif, dan hak luas
-- seperti di Supabase (RLS yang menjaga). Tiruan sederhana, bukan Storage asli.
-- ---------------------------------------------------------------------------
create schema if not exists storage;
create table if not exists storage.buckets (
  id                 text primary key,
  name               text not null unique,
  public             boolean not null default false,
  file_size_limit    bigint,
  allowed_mime_types text[]
);
create table if not exists storage.objects (
  id         uuid primary key default gen_random_uuid(),
  bucket_id  text references storage.buckets(id),
  name       text,
  owner      uuid default auth.uid(),
  metadata   jsonb,
  created_at timestamptz default now(),
  unique (bucket_id, name)
);
alter table storage.objects enable row level security;
grant usage on schema storage to anon, authenticated, service_role;
grant all on storage.buckets, storage.objects to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Stub Vault dan peran Auth (Tahap 6). Nilai pepper di bawah HANYA nilai uji lokal.
-- ---------------------------------------------------------------------------
do $$ begin
  create role supabase_auth_admin nologin;
exception when duplicate_object then null; end $$;
create schema if not exists vault;
create table if not exists vault.decrypted_secrets (
  id               uuid primary key default gen_random_uuid(),
  name             text unique,
  decrypted_secret text
);
insert into vault.decrypted_secrets (name, decrypted_secret)
values ('blacklist_pepper', 'pepper-uji-lokal-bukan-rahasia-0123456789')
on conflict (name) do nothing;
