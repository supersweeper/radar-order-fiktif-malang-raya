-- DEPRECATED (SRS v0.1): skema awal, TIDAK sesuai SRS dan membolehkan insert anonim
-- (bertentangan dengan BR-03). Jangan dijalankan untuk produksi baru.
-- Pengganti: supabase/migrations/ (bertahap, lihat ANALISIS_GAP_SRS_v0.1.md).
-- Dipertahankan sementara sebagai referensi sampai migrasi Fase 1-2 selesai.

-- Jalankan di Supabase SQL Editor.
create table if not exists public.reports (
  id uuid primary key default gen_random_uuid(),
  region text not null check (region in ('Kota Malang','Kabupaten Malang','Kota Batu')),
  district text not null,
  location_general text not null,
  incident_type text not null,
  story text not null check (char_length(story) between 20 and 700),
  incident_at timestamptz,
  status text not null default 'pending' check (status in ('pending','verified','rejected')),
  created_at timestamptz not null default now()
);

alter table public.reports enable row level security;

-- Publik dapat membaca laporan yang sudah diverifikasi.
create policy "public read verified reports"
on public.reports for select
to anon, authenticated
using (status = 'verified');

-- Publik dapat mengirim laporan baru. Status selalu pending dari default.
create policy "public submit pending reports"
on public.reports for insert
to anon, authenticated
with check (
  status = 'pending'
  and region in ('Kota Malang','Kabupaten Malang','Kota Batu')
  and char_length(story) between 20 and 700
);

-- Jangan membuat policy UPDATE/DELETE publik.
-- Moderator mengubah status melalui Supabase Dashboard atau backend admin
-- yang terautentikasi dengan role khusus.
